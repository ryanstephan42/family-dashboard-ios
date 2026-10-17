import SwiftUI

struct GroceryListView: View {
    @EnvironmentObject private var session: Session
    @State private var items: [GroceryItem] = []
    @State private var preferences: [GroceryCategoryPreference] = []
    @State private var suggestions: [GrocerySuggestion] = []
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var operationError: String?
    @State private var showingAddSheet = false
    @State private var showingClearConfirmation = false
    @State private var pendingDelete: GroceryItem?
    @State private var bulkInput = ""
    @State private var editingItem: GroceryItem?
    @State private var editName = ""
    @State private var editQuantity = ""
    @State private var editCategory = ""
    @State private var editDetails = ""

    private var groceryAPI: GroceryAPI? {
        session.client.map { GroceryAPI(client: $0) }
    }

    private var groupedItems: [(category: String, items: [GroceryItem])] {
        Dictionary(grouping: items) { item in
            let category = item.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            return category.flatMap { $0.isEmpty ? nil : $0 } ?? "General"
        }
        .map { (category: $0.key, items: $0.value) }
        .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    private var completedItems: [GroceryItem] {
        items.filter(\.completed)
    }

    var body: some View {
        NavigationStack {
            List {
                listContents
            }
            .overlay(alignment: .bottom) {
                if isMutating {
                    ProgressView("Saving")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .accessibilityLiveRegion(.polite)
                }
            }
            .navigationTitle("Groceries")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !completedItems.isEmpty {
                        Button("Clear completed", systemImage: "trash") {
                            showingClearConfirmation = true
                        }
                        .disabled(isMutating)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bulkInput = ""
                        showingAddSheet = true
                    } label: {
                        Label("Add groceries", systemImage: "plus")
                    }
                    .disabled(isMutating)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showingAddSheet) {
                addSheet
            }
            .sheet(item: $editingItem) { _ in
                editSheet
            }
            .confirmationDialog(
                "Delete this grocery item?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let item = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await delete(item) }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete?.name ?? "")
            }
            .confirmationDialog(
                "Clear \(completedItems.count) completed items?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear completed", role: .destructive) {
                    Task { await clearCompleted() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes completed items from the grocery list.")
            }
            .alert("Grocery action failed", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("OK", role: .cancel) { operationError = nil }
            } message: {
                Text(operationError ?? "")
            }
        }
    }

    @ViewBuilder
    private func groceryRow(_ item: GroceryItem) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await toggle(item) }
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.completed ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.completed ? "Mark \(item.name) incomplete" : "Mark \(item.name) complete")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .strikethrough(item.completed)
                    .foregroundStyle(item.completed ? .secondary : .primary)
                if let quantity = item.quantity, !quantity.isEmpty {
                    Text(quantity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let details = item.details, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if item.completed {
                    Button("Add to inventory", systemImage: "shippingbox") {
                        Task { await purchase(item) }
                    }
                }
                Button("Edit", systemImage: "pencil") {
                    beginEditing(item)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDelete = item
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(isMutating)
            .accessibilityLabel("Actions for \(item.name)")
        }
        .padding(.vertical, 4)
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("Items") {
                    TextField("Milk, eggs, bread...", text: $bulkInput, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Grocery items")
                    Text("Separate items with commas or new lines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add groceries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await addItemsFromInput() } }
                        .disabled(parsedNames.isEmpty || isMutating)
                }
            }
        }
    }

    private var suggestionsSection: some View {
        Section("Running low") {
            ForEach(suggestions, id: \.name) { suggestion in
                suggestionRow(suggestion)
            }

            @ViewBuilder
            private var listContents: some View {
                if isLoading && items.isEmpty && loadError == nil {
                    HStack {
                        Spacer()
                        ProgressView("Loading groceries")
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                } else if let loadError {
                    loadErrorSection(loadError)
                } else {
                    loadedListContents
                }
            }

            private func loadErrorSection(_ message: String) -> some View {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Couldn't load groceries", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await load() }
                        }
                        .accessibilityHint("Try loading the grocery list again")
                    }
                    .padding(.vertical, 8)
                }
            }

            @ViewBuilder
            private var loadedListContents: some View {
                if !suggestions.isEmpty {
                    suggestionsSection
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        "No groceries yet",
                        systemImage: "cart",
                        description: Text("Add an item or choose a low-stock suggestion.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    groceryItemSections
                }
            }

            private var groceryItemSections: some View {
                ForEach(groupedItems, id: \.category) { group in
                    groceryCategorySection(group)
                }
            }

            private func groceryCategorySection(
                _ group: (category: String, items: [GroceryItem])
            ) -> some View {
                Section(group.category) {
                    ForEach(group.items) { item in
                        groceryRow(item)
                    }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: GrocerySuggestion) -> some View {
        Button {
            Task { await addSuggestion(suggestion) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.name)
                        .foregroundStyle(.primary)
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isMutating)
        .accessibilityHint("Add this low-stock item to the grocery list")
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $editName)
                    TextField("Quantity", text: $editQuantity)
                    TextField("Category", text: $editCategory)
                    TextField("Details", text: $editDetails, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Edit grocery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingItem = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveEdit() } }
                        .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isMutating)
                }
            }
        }
    }

    private var parsedNames: [String] {
        bulkInput
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func load() async {
        guard let groceryAPI else {
            loadError = APIError.invalidURL.localizedDescription
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            async let loadedItems = groceryAPI.fetchItems()
            async let loadedPreferences = groceryAPI.fetchPreferences()
            async let loadedSuggestions = groceryAPI.fetchSuggestions()
            let (items, preferences, suggestions) = try await (
                loadedItems, loadedPreferences, loadedSuggestions
            )
            self.items = items
            self.preferences = preferences
            self.suggestions = suggestions
        } catch {
            handle(error, loading: true)
        }
        isLoading = false
    }

    private func addItemsFromInput() async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        let inputs = parsedNames.map { name in
            GroceryItemInput(
                name: name,
                quantity: nil,
                details: nil,
                category: preferredCategory(for: name) ?? "General"
            )
        }
        await performMutation {
            try await groceryAPI.createItems(inputs)
        }
        if operationError == nil {
            showingAddSheet = false
        }
    }

    private func addSuggestion(_ suggestion: GrocerySuggestion) async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        let category = suggestion.category
            ?? preferredCategory(for: suggestion.name)
            ?? "General"
        await performMutation {
            try await groceryAPI.createItems([
                GroceryItemInput(
                    name: suggestion.name,
                    quantity: suggestion.quantity,
                    details: nil,
                    category: category
                )
            ])
        }
    }

    private func toggle(_ item: GroceryItem) async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        var updated = item
        updated.completed.toggle()
        await performMutation { try await groceryAPI.update(updated) }
    }

    private func delete(_ item: GroceryItem) async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        await performMutation { try await groceryAPI.delete(id: item.id) }
    }

    private func purchase(_ item: GroceryItem) async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        await performMutation { try await groceryAPI.purchase(id: item.id) }
    }

    private func clearCompleted() async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        let toDelete = completedItems
        await performMutation {
            for item in toDelete {
                try await groceryAPI.delete(id: item.id)
            }
        }
    }

    private func beginEditing(_ item: GroceryItem) {
        editName = item.name
        editQuantity = item.quantity ?? ""
        editCategory = item.category ?? ""
        editDetails = item.details ?? ""
        editingItem = item
    }

    private func saveEdit() async {
        guard let groceryAPI else {
            operationError = APIError.invalidURL.localizedDescription
            return
        }
        guard let original = editingItem else { return }
        var updated = original
        updated.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.quantity = editQuantity.isEmpty ? nil : editQuantity
        updated.category = editCategory.isEmpty ? nil : editCategory
        updated.details = editDetails.isEmpty ? nil : editDetails
        await performMutation { try await groceryAPI.update(updated) }
        if operationError == nil {
            editingItem = nil
        }
    }

    private func performMutation(_ operation: () async throws -> Void) async {
        guard !isMutating else { return }
        isMutating = true
        operationError = nil
        do {
            try await operation()
            await load()
        } catch {
            handle(error, loading: false)
        }
        isMutating = false
    }

    private func handle(_ error: Error, loading: Bool) {
        if case APIError.unauthorized = error {
            return
        } else if loading {
            loadError = error.localizedDescription
        } else {
            operationError = error.localizedDescription
        }
    }

    private func preferredCategory(for name: String) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return preferences.first {
            $0.itemName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }?.category
    }
}
