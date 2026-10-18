import SwiftUI

struct InventoryListView: View {
    @EnvironmentObject private var session: Session
    @State private var items: [InventoryItem] = []
    @State private var units = InventoryUnitOptions(commonUnits: [], preferences: [])
    @State private var filter = InventoryFilter()
    @State private var loading = false
    @State private var loaded = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var editor: InventoryEditorSelection?
    @State private var pendingDelete: InventoryItem?
    @State private var cacheStatus: ReadCacheStatus?

    private var visibleItems: [InventoryItem] {
        items.filter { filter.matches($0) }
    }

    private var locations: [String] {
        Array(Set(InventoryDraft.locations + items.map(\.location))).sorted()
    }

    private var categories: [String] {
        Array(Set(items.map(\.category))).sorted()
    }

    var body: some View {
        List {
            if let cacheStatus { CachedReadBanner(status: cacheStatus) }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry loading inventory") { Task { await load() } }
                        .disabled(loading || busy)
                }
            }
            Section("Filters") {
                Picker("Location", selection: $filter.location) {
                    Text("All locations").tag("")
                    ForEach(locations, id: \.self) { Text($0).tag($0) }
                }
                Picker("Category", selection: $filter.category) {
                    Text("All categories").tag("")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Running low (\(items.filter(\.isRunningLow).count))", isOn: $filter.runningLow)
                Picker("Expiration", selection: $filter.expiration) {
                    ForEach(InventoryExpirationFilter.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
            }
            if loading && !loaded {
                ProgressView("Loading inventory")
            } else if loaded && visibleItems.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? "No inventory yet" : "No matching items",
                    systemImage: "shippingbox",
                    description: Text(items.isEmpty ? "Add food to track your household stock." : "Try changing your search or filters.")
                )
            }
            ForEach(Array(Set(visibleItems.map(\.category))).sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(visibleItems.filter { $0.category == category }) { item in
                        row(item)
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingDelete = item }
                                Button("Edit") { editor = InventoryEditorSelection(item: item) }
                                    .tint(.blue)
                            }
                            .disabled(busy || loading || cacheStatus?.isStale == true)
                    }
                }
            }
        }
        .navigationTitle("Inventory")
        .searchable(text: $filter.search, prompt: "Name, category, location, notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = InventoryEditorSelection(item: nil)
                } label: {
                    Label("Add inventory item", systemImage: "plus")
                }
                .disabled(busy || loading || cacheStatus?.isStale == true)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editor) { selection in
            InventoryEditorView(item: selection.item, units: units, categories: categories, onPhotoChanged: replace) { draft in
                guard let client = session.client else { throw APIError.unauthorized }
                let service = InventoryService(client: client)
                if let item = selection.item {
                    let saved = try await service.update(id: item.id, draft: draft)
                    replace(saved)
                } else {
                    let saved = try await service.create(draft)
                    items.insert(contentsOf: saved, at: 0)
                }
                // The server learns explicit units; keep newly chosen units available immediately.
                let chosenUnit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !chosenUnit.isEmpty {
                    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    var preferences = units.preferences.filter { $0.itemName != name }
                    preferences.append(InventoryUnitPreference(itemName: name, unit: chosenUnit))
                    units = InventoryUnitOptions(
                        commonUnits: Array(Set(units.commonUnits + [chosenUnit])).sorted(),
                        preferences: preferences
                    )
                }
            }
            .environmentObject(session)
        }
        .confirmationDialog(
            "Remove \(pendingDelete?.name ?? "item") from inventory?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingDelete {
                Button("Remove item", role: .destructive) {
                    Task { await remove(item) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func row(_ item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { editor = InventoryEditorSelection(item: item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let server = session.client?.baseURL, item.photoUrl != nil {
                        InventoryPhotoView(path: item.photoUrl, server: server)
                    }
                    Text(item.name).font(.headline)
                    Text("\(item.quantity.formatted()) \(item.unit ?? "") • \(item.location)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if item.isRunningLow {
                        Label("Running low", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if item.trackExpiration, let expiration = item.expirationDate {
                        Text("Expires \(expiration.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(expiration < Calendar.current.startOfDay(for: Date()) ? .red : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit inventory item")
            HStack {
                Button {
                    if item.quantity <= 1 { pendingDelete = item }
                    else { Task { await adjust(item, delta: -1) } }
                } label: {
                    Label("Use one", systemImage: "minus.circle")
                }
                .accessibilityLabel("Use one \(item.name)")
                Spacer()
                Button { Task { await adjust(item, delta: 1) } } label: {
                    Label("Restock one", systemImage: "plus.circle")
                }
                .accessibilityLabel("Restock one \(item.name)")
            }
            .buttonStyle(.borderless)
        }
        .disabled(busy || loading || cacheStatus?.isStale == true)
    }

    @MainActor private func load() async {
        guard !loading, !busy else { return }
        guard let client = session.client else {
            errorMessage = APIError.unauthorized.localizedDescription
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let service = InventoryService(client: client)
            let result = try await session.read(path: "/inventory") {
                async let items = service.items()
                async let units = service.unitOptions()
                return try await InventorySnapshot(items: items, units: units)
            }
            items = result.value.items
            units = result.value.units
            cacheStatus = result.status
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            items = []
            loaded = false
            cacheStatus = nil
            handle(error)
        }
    }

    @MainActor private func adjust(_ item: InventoryItem, delta: Double) async {
        await mutate { service in
            let updated = try await service.adjust(id: item.id, delta: delta)
            replace(updated)
        }
    }

    @MainActor private func remove(_ item: InventoryItem) async {
        pendingDelete = nil
        await mutate { service in
            try await service.delete(id: item.id)
            items.removeAll { $0.id == item.id }
        }
    }

    @MainActor private func mutate(_ operation: (InventoryService) async throws -> Void) async {
        guard !busy, !loading, cacheStatus?.isStale != true else { return }
        guard let client = session.client else {
            handle(APIError.unauthorized)
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do { try await operation(InventoryService(client: client)) }
        catch { handle(error) }
    }

    private struct InventorySnapshot: Codable {
        let items: [InventoryItem]
        let units: InventoryUnitOptions
    }

    private func replace(_ item: InventoryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }

    @MainActor private func handle(_ error: Error) {
        if case APIError.unauthorized = error { return }
        errorMessage = error.localizedDescription
    }
}

private struct InventoryEditorSelection: Identifiable {
    let id = UUID()
    let item: InventoryItem?
}
