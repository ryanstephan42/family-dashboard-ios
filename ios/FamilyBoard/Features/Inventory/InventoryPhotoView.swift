import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO

struct InventoryPhotoView: View {
    let path: String?
    let server: URL

    var body: some View {
        if let path {
            if let url = InventoryPhoto.url(path, server: server) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView("Loading photo")
                    case .success(let image):
                        image.resizable().scaledToFit().accessibilityLabel("Inventory item photo")
                    case .failure:
                        Label("Photo could not be loaded", systemImage: "photo.badge.exclamationmark")
                    @unknown default:
                        Label("Photo unavailable", systemImage: "photo")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 200)
            } else {
                Label("Photo address is not a valid server upload", systemImage: "photo.badge.exclamationmark")
            }
        }
    }
}

struct InventoryPhotoEditor: View {
    @EnvironmentObject private var session: Session
    let item: InventoryItem
    let onChanged: (InventoryItem) -> Void
    @State private var photoPath: String?
    @State private var selection: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var confirmDelete = false
    @Binding var busy: Bool
    @State private var errorMessage: String?

    init(item: InventoryItem, busy: Binding<Bool>, onChanged: @escaping (InventoryItem) -> Void) {
        self.item = item
        self.onChanged = onChanged
        _busy = busy
        _photoPath = State(initialValue: item.photoUrl)
    }

    var body: some View {
        Section {
            if let server = session.client?.baseURL {
                InventoryPhotoView(path: photoPath, server: server)
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
            }
            Button {
                Task { await openCamera() }
            } label: {
                Label("Take photo", systemImage: "camera")
            }
            if photoPath != nil {
                Button("Remove photo", role: .destructive) { confirmDelete = true }
            }
            if busy { ProgressView("Updating photo") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } header: {
            Text("Photo")
        } footer: {
            Text("Photo changes save immediately, independently of the item Save button. Photos are resized before uploading.")
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onChange(of: selection) { _, selected in
            guard let selected else { return }
            Task { await load(selected) }
        }
        .sheet(isPresented: $showingCamera) {
            InventoryCameraPicker { image in
                showingCamera = false
                if let image { Task { await upload(image) } }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Remove this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove photo", role: .destructive) {
                Task {
                    await change { service in try await service.deletePhoto(id: item.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor private func openCamera() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                throw InventoryValidationError(message: "This device has no available camera. Choose a photo from your library instead.")
            }
            try await InventoryCameraAccess.authorize()
            showingCamera = true
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func load(_ selected: PhotosPickerItem) async {
        await change { service in
            guard let data = try await selected.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048
                  ] as CFDictionary) else {
                throw InventoryValidationError(message: "The selected photo could not be read. Choose another image.")
            }
            return try await service.uploadPhoto(id: item.id, data: Self.jpeg(UIImage(cgImage: thumbnail)))
        }
        selection = nil
    }

    @MainActor private func upload(_ image: UIImage) async {
        await change { service in
            try await service.uploadPhoto(id: item.id, data: Self.jpeg(image))
        }
    }

    @MainActor private static func jpeg(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw InventoryValidationError(message: "The photo has invalid dimensions.")
        }
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8) else {
            throw InventoryValidationError(message: "The photo could not be prepared for upload.")
        }
        return data
    }

    @MainActor private func change(_ operation: (InventoryService) async throws -> InventoryItem) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            let updated = try await operation(InventoryService(client: client))
            photoPath = updated.photoUrl
            onChanged(updated)
        } catch APIError.unauthorized {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum InventoryCameraAccess {
    static func authorize() async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else {
            throw InventoryValidationError(
                message: "Camera access is unavailable. Enable Camera in Settings, choose a library photo, or enter a barcode manually."
            )
        }
    }
}

struct InventoryCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }
    }
}
