import SwiftUI

@MainActor
final class ReceiptScanModel: ObservableObject {
    enum Activity { case idle, loadingImage, scanning, saving }

    @Published var image: ReceiptImage?
    @Published var items: [ReceiptReviewItem] = []
    @Published var location = "Pantry"
    @Published var method: String?
    @Published var error: String?
    @Published private(set) var activity = Activity.idle
    @Published private(set) var savedCount: Int?

    let service: ReceiptService

    init(client: APIClient) {
        service = ReceiptService(client: client)
    }

    var busy: Bool { activity != .idle }
    var selectedCount: Int { items.filter(\.selected).count }
    var validationMessage: String? {
        do {
            _ = try ReceiptImport(review: items, location: location)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func loadImage(_ load: () async throws -> ReceiptImage) async {
        guard !busy, savedCount == nil else { return }
        activity = .loadingImage
        error = nil
        defer { activity = .idle }
        do {
            let loaded = try await load()
            try Task.checkCancellation()
            image = loaded
            items = []
            method = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func scan() async {
        guard !busy, savedCount == nil, let image else { return }
        activity = .scanning
        error = nil
        defer { activity = .idle }
        do {
            let result = try await service.scan(image)
            try Task.checkCancellation()
            items = result.items.map(ReceiptReviewItem.init)
            method = result.method
            if items.isEmpty {
                error = "No items detected. Choose a clearer receipt image and scan again."
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func save() async {
        guard !busy, savedCount == nil else { return }
        let payload: ReceiptImport
        do {
            payload = try ReceiptImport(review: items, location: location)
        } catch {
            self.error = error.localizedDescription
            return
        }
        activity = .saving
        error = nil
        defer { activity = .idle }
        do {
            try await service.save(payload)
            savedCount = payload.items.count
        } catch {
            self.error = error.localizedDescription +
                " Some items may already have been added. Check inventory before trying again to avoid duplicates."
        }
    }
}
