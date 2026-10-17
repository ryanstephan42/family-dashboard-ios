import SwiftUI
import VisionKit

struct InventoryBarcodeView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let onReview: (InventoryBarcodeProduct) -> Void
    @State private var code = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var manualProductCode: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Look up a product, then review and edit its details before tapping Save. Lookup never adds inventory.")
                    if scanning {
                        InventoryBarcodeScanner { value in
                            code = value
                            scanning = false
                            Task { await lookup(value) }
                        } onError: { message in
                            scanning = false
                            errorMessage = message
                        }
                        .frame(height: 280)
                        .accessibilityLabel("Point the camera at a product barcode")
                        Button("Stop camera") { scanning = false }
                    } else {
                        Button("Scan with camera", systemImage: "barcode.viewfinder") {
                            Task { await startScanner() }
                        }
                    }
                    TextField("Barcode number", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: code) { _, _ in manualProductCode = nil }
                    Button("Look up barcode") {
                        scanning = false
                        Task { await lookup(code) }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if busy { ProgressView("Looking up product") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if let manualProductCode {
                        Button("Enter product details manually") {
                            review(InventoryBarcodeProduct(
                                barcode: manualProductCode, name: "", category: nil, unit: nil, source: nil
                            ))
                        }
                    }
                }
                .disabled(busy)
            }
            .navigationTitle("Barcode lookup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { scanning = false; dismiss() }
                }
            }
        }
    }

    @MainActor private func startScanner() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            guard DataScannerViewController.isSupported else {
                throw InventoryValidationError(message: "Barcode scanning is not supported on this device. Enter the barcode manually.")
            }
            try await InventoryCameraAccess.authorize()
            guard DataScannerViewController.isAvailable else {
                throw InventoryValidationError(message: "Barcode scanning is currently unavailable. Enter the barcode manually.")
            }
            scanning = true
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func lookup(_ value: String) async {
        guard !busy else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        errorMessage = nil
        manualProductCode = nil
        defer { busy = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            let product = try await InventoryService(client: client).lookupBarcode(value)
            review(product)
        } catch APIError.unauthorized {
            return
        } catch {
            errorMessage = "\(error.localizedDescription) You can retry or enter product details manually."
            if !value.isEmpty, value.count <= 128,
               value.rangeOfCharacter(from: .controlCharacters) == nil { manualProductCode = value }
        }
    }

    private func review(_ product: InventoryBarcodeProduct) {
        scanning = false
        onReview(product)
        dismiss()
    }
}

private struct InventoryBarcodeScanner: UIViewControllerRepresentable {
    let onBarcode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBarcode: onBarcode, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.start(controller)
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcode: (String) -> Void
        let onError: (String) -> Void
        var started = false
        var finished = false

        init(onBarcode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onBarcode = onBarcode
            self.onError = onError
        }
        func start(_ controller: DataScannerViewController) {
            guard !started else { return }
            started = true
            DispatchQueue.main.async {
                guard !self.finished else { return }
                do { try controller.startScanning() }
                catch { self.fail(controller) }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    finished = true
                    dataScanner.stopScanning()
                    onBarcode(value)
                    return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fail(dataScanner)
        }
        private func fail(_ controller: DataScannerViewController) {
            guard !finished else { return }
            finished = true
            controller.stopScanning()
            onError("The scanner could not start or became unavailable. Enter the barcode manually.")
        }
    }
}
