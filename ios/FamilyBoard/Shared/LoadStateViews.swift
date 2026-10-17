import SwiftUI

struct LoadingStateView: View {
    var title = "Loading..."

    var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(title)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () async -> Void
    @State private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Unable to load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(retrying ? "Retrying..." : "Try again") {
                Task {
                    retrying = true
                    await retry()
                    retrying = false
                }
            }
            .disabled(retrying)
        }
    }
}
