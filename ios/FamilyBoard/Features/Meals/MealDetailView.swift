import SwiftUI

struct MealDetailView: View {
    let slug: String
    let onChange: () async -> Void
    @EnvironmentObject private var session: Session
    @State private var detail: MealMatchDetail?
    @State private var loading = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var linking: MealLinkSelection?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry loading recipe") { Task { await load() } }
                        .disabled(loading || busy)
                }
            }
            if loading { ProgressView("Checking ingredients") }
            if let detail {
                Section {
                    Text(detail.canMake ? "Ready to cook" : "\(detail.missingCount) ingredients missing")
                    Text("Matches check items on hand, not recipe quantities.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ingredients") {
                    ForEach(Array(detail.matches.enumerated()), id: \.offset) { _, match in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(match.originalText.isEmpty ? match.ingredient : match.originalText,
                                  systemImage: match.haveIt ? "checkmark.circle" : "xmark.circle")
                            if let item = match.matchedItem {
                                Text("Matched: \(item.name) (\(item.quantity.formatted())\(item.unit.map { " " + $0 } ?? ""))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if match.isManualLink {
                                Text("Manual link").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Link inventory item") {
                                    linking = MealLinkSelection(ingredient: match.ingredient)
                                }
                                if match.isManualLink {
                                    Spacer()
                                    Button("Remove link", role: .destructive) {
                                        Task { await unlink(match.ingredient) }
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .disabled(loading || busy)
                    }
                }
                if let url = detail.recipe.externalURL {
                    Section {
                        Link(destination: url) {
                            Label("Open full recipe in Mealie", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
        .navigationTitle(detail?.recipe.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $linking) { selection in
            MealInventoryLinkView(slug: slug, ingredient: selection.ingredient) {
                await load()
                await onChange()
            }
        }
    }

    @MainActor private func load() async {
        guard !loading, !busy else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            detail = try await MealsService(client: client).detail(slug: slug)
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func unlink(_ ingredient: String) async {
        guard !busy, !loading else { return }
        busy = true
        errorMessage = nil
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            try await MealsService(client: client).unlink(slug: slug, ingredient: ingredient)
        } catch {
            busy = false
            errorMessage = error.localizedDescription
            return
        }
        busy = false
        await load()
        await onChange()
    }
}

private struct MealLinkSelection: Identifiable {
    let id = UUID()
    let ingredient: String
}

private struct MealInventoryLinkView: View {
    let slug: String
    let ingredient: String
    let onSave: () async -> Void
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var items: [InventoryItem] = []
    @State private var search = ""
    @State private var loading = false
    @State private var busy = false
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the inventory item for \(ingredient).")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry inventory") { Task { await load() } }
                        .disabled(loading || busy)
                }
                if loading { ProgressView("Loading inventory") }
                if loaded && items.isEmpty {
                    Text("No inventory items. Add food in Inventory first.")
                }
                ForEach(items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in
                    Button {
                        Task { await save(item.name) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text("\(item.quantity.formatted()) \(item.unit ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(busy || loading)
                }
                if busy { ProgressView("Saving link") }
            }
            .navigationTitle("Link ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search inventory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
            .task { await load() }
            .interactiveDismissDisabled(busy)
        }
    }

    @MainActor private func load() async {
        guard !loading, !busy else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            items = try await InventoryService(client: client).items()
            loaded = true
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func save(_ name: String) async {
        guard !busy, !loading else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            try await MealsService(client: client).link(slug: slug, ingredient: ingredient, inventoryItemName: name)
            await onSave()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
