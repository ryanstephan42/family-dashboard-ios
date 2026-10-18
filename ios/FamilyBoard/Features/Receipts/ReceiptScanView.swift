import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Push inside a NavigationStack, or present in a sheet wrapped in NavigationStack.
struct ReceiptScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReceiptScanModel
    @State private var photo: PhotosPickerItem?
    @State private var importingFile = false
    @State private var showingCamera = false
    @State private var openingCamera = false
    @State private var operation: Task<Void, Never>?
    let onImported: () -> Void

    init(client: APIClient, onImported: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: ReceiptScanModel(client: client))
        self.onImported = onImported
    }

    var body: some View {
        Form {
            if let count = model.savedCount {
                Section {
                    Label("Added \(count) items to inventory", systemImage: "checkmark.circle.fill")
                    Button("Done") { dismiss() }
                }
            } else {
                if model.items.isEmpty {
                    sourceSection
                } else {
                    reviewSection
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
                if model.busy {
                    Section {
                        ProgressView(activityLabel)
                        if model.activity != .saving {
                            Button("Cancel", role: .cancel) { operation?.cancel() }
                        } else {
                            Text("Please wait for confirmation before closing.")
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        .navigationTitle("Scan Receipt")
        .navigationBarBackButtonHidden(model.busy || openingCamera)
        .interactiveDismissDisabled(model.busy || openingCamera)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.disabled(model.busy || openingCamera)
            }
        }
        .onChange(of: photo) { _, selection in
            guard let selection else { return }
            operation = Task {
                await model.loadImage {
                    guard let data = try await selection.loadTransferable(type: Data.self) else {
                        throw ReceiptError.validation("The selected photo could not be opened.")
                    }
                    return try Self.receiptImage(data)
                }
                photo = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.jpeg, .png]) { result in
            switch result {
            case .success(let url):
                operation = Task {
                    await model.loadImage {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= ReceiptImage.maximumBytes else {
                            throw ReceiptError.validation("Choose an image smaller than 15 MB.")
                        }
                        return try Self.receiptImage(Data(contentsOf: url))
                    }
                }
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingCamera) {
            InventoryCameraPicker { image in
                showingCamera = false
                guard let image else { return }
                operation = Task {
                    await model.loadImage { try Self.receiptImage(image) }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: model.savedCount) { _, count in
            if count != nil { onImported() }
        }
        .onDisappear {
            if model.activity != .saving { operation?.cancel() }
        }
    }

    private var sourceSection: some View {
        Section {
            Button("Take Receipt Photo", systemImage: "camera") {
                operation = Task { await openCamera() }
            }
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .compatible) {
                Label("Choose Receipt Photo", systemImage: "photo")
            }
            Button("Choose JPEG or PNG File", systemImage: "doc") { importingFile = true }
            if let image = model.image {
                if let preview = UIImage(data: image.data) {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .frame(maxHeight: 240).accessibilityLabel("Selected receipt")
                }
                Button("Scan Receipt") {
                    operation = Task { await model.scan() }
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Select an image")
        } footer: {
            Text("Nothing uploads until you tap Scan Receipt. Your server may use a cloud AI service to read the image. Review all results before saving. PDF receipts are not supported.")
        }
        .disabled(model.busy || openingCamera)
    }

    private var reviewSection: some View {
        Group {
            Section {
                Text("Check names and quantities before saving. Only selected items will be added.")
                if let method = model.method {
                    Text(method == "cloud" ? "AI scan" : method == "local" ? "Local OCR" : "Receipt scan")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Storage location", selection: $model.location) {
                    ForEach(InventoryDraft.locations, id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach($model.items) { $item in
                Section {
                    Toggle("Include item", isOn: $item.selected)
                    TextField("Name", text: $item.name)
                        .accessibilityLabel("Item name")
                    TextField("Quantity", text: $item.quantity)
                        .keyboardType(.decimalPad).accessibilityLabel("Quantity")
                    TextField("Unit", text: $item.unit).accessibilityLabel("Unit")
                    TextField("Category", text: $item.category).accessibilityLabel("Category")
                }
            }
            Section {
                if let message = model.validationMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Add \(model.selectedCount) Selected Items to Inventory") {
                    operation = Task { await model.save() }
                }
                .disabled(model.validationMessage != nil)
                Button("Choose Another Receipt", role: .destructive) {
                    model.items = []
                    model.image = nil
                    model.method = nil
                    model.error = nil
                }
            }
        }
        .disabled(model.busy)
    }

    private var activityLabel: String {
        switch model.activity {
        case .idle: return ""
        case .loadingImage: return "Opening receipt..."
        case .scanning: return "Scanning receipt..."
        case .saving: return "Adding selected items..."
        }
    }

    private static func receiptImage(_ data: Data) throws -> ReceiptImage {
        guard data.count <= ReceiptImage.maximumBytes,
              let image = UIImage(data: data) else {
            throw ReceiptError.validation("Choose a readable receipt image smaller than 15 MB.")
        }
        return try receiptImage(image)
    }

    static func receiptImage(_ image: UIImage) throws -> ReceiptImage {
        guard image.size.width > 0, image.size.height > 0 else {
            throw ReceiptError.validation("The receipt image has invalid dimensions.")
        }
        let scale = min(1, 4096 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.85) else {
            throw ReceiptError.validation("The receipt could not be prepared for scanning.")
        }
        return try ReceiptImage(jpegData: jpeg)
    }

    @MainActor private func openCamera() async {
        guard !model.busy, !openingCamera else { return }
        openingCamera = true
        model.error = nil
        defer { openingCamera = false }
        do {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                throw ReceiptError.validation("This device has no available camera. Choose a receipt photo or file instead.")
            }
            try await InventoryCameraAccess.authorize()
            try Task.checkCancellation()
            showingCamera = true
        } catch {
            if !Task.isCancelled { model.error = error.localizedDescription }
        }
    }
}
