import SwiftUI

struct InventoryEditorView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let item: InventoryItem?
    let units: InventoryUnitOptions
    let categories: [String]
    let onPhotoChanged: (InventoryItem) -> Void
    let save: (InventoryDraft) async throws -> Void
    @State private var draft: InventoryDraft
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @State private var changed = false
    @State private var captureBusy = false
    @State private var showingBarcode = false

    init(item: InventoryItem?, units: InventoryUnitOptions, categories: [String],
         onPhotoChanged: @escaping (InventoryItem) -> Void,
         save: @escaping (InventoryDraft) async throws -> Void) {
        self.item = item
        self.units = units
        self.categories = categories
        self.onPhotoChanged = onPhotoChanged
        self.save = save
        _draft = State(initialValue: InventoryDraft(item: item))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).accessibilityLabel("Error: \(errorMessage)") }
                }
                if item == nil {
                    Section {
                        Button("Look up a barcode", systemImage: "barcode.viewfinder") { showingBarcode = true }
                        TextField("Barcode (optional)", text: $draft.barcode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Lookup fills the name, category and unit below for review. Nothing is added until you tap Save.")
                    }
                } else if !draft.barcode.isEmpty {
                    Section("Barcode") { Text(draft.barcode).textSelection(.enabled) }
                }
                Section("Item") {
                    TextField("Name", text: $draft.name)
                    TextField("Quantity", text: $draft.quantity).keyboardType(.decimalPad)
                    TextField("Unit (optional)", text: $draft.unit)
                    if !units.commonUnits.isEmpty {
                        Menu("Choose a unit") {
                            Button("No unit") { draft.unit = "" }
                            ForEach(Array(Set(units.commonUnits)).sorted(), id: \.self) { unit in
                                Button(unit) { draft.unit = unit }
                            }
                        }
                    }
                    if let preferred = units.preferredUnit(for: draft.name), preferred != draft.unit {
                        Button("Use preferred unit: \(preferred)") { draft.unit = preferred }
                    }
                    TextField("Category", text: $draft.category)
                    if !categories.isEmpty {
                        Menu("Choose a category") {
                            ForEach(categories, id: \.self) { category in
                                Button(category) { draft.category = category }
                            }
                        }
                    }
                    TextField("Storage location", text: $draft.location)
                    Menu("Choose a storage location") {
                        ForEach(InventoryDraft.locations, id: \.self) { location in
                            Button(location) { draft.location = location }
                        }
                    }
                }
                Section {
                    TextField("Par level (optional)", text: $draft.parLevel).keyboardType(.decimalPad)
                } header: {
                    Text("Running low")
                } footer: {
                    Text("An item is running low when its quantity is at or below its par level. Leave blank to disable.")
                }
                Section("Dates") {
                    DatePicker("Purchased", selection: $draft.purchaseDate, displayedComponents: .date)
                    Toggle("Track expiration", isOn: $draft.trackExpiration)
                    if draft.trackExpiration {
                        Toggle("Set expiration date", isOn: $draft.hasExpirationDate)
                        if draft.hasExpirationDate {
                            DatePicker("Expires", selection: $draft.expirationDate, displayedComponents: .date)
                        }
                        if item == nil && !draft.hasExpirationDate {
                            Text("The server will suggest an expiration date for this category.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let item {
                    InventoryPhotoEditor(item: item, busy: $captureBusy, onChanged: onPhotoChanged)
                } else {
                    Section("Photo") {
                        Text("Save the new item, then open it to attach a library or camera photo.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let validation = draft.validationMessage {
                    Section { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .disabled(saving || captureBusy)
            .sheet(isPresented: $showingBarcode) {
                InventoryBarcodeView { product in draft.apply(product) }
                    .environmentObject(session)
            }
            .onChange(of: draft) { _, _ in changed = true }
            .navigationTitle(item == nil ? "Add inventory" : "Edit inventory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if changed { confirmDiscard = true } else { dismiss() }
                    }.disabled(saving || captureBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if saving { ProgressView("Saving") } else { Text("Save") }
                    }
                    .disabled(saving || captureBusy || draft.validationMessage != nil)
                }
            }
            .interactiveDismissDisabled(changed || saving || captureBusy)
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }

    @MainActor private func submit() async {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await save(draft)
            dismiss()
        } catch APIError.unauthorized {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
