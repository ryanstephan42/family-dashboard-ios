import SwiftUI

struct CachedReadBanner: View {
    let status: ReadCacheStatus

    var body: some View {
        if status.isStale || status.warning != nil {
            VStack(alignment: .leading, spacing: 4) {
                if status.isStale {
                    Label("Saved data - may be out of date", systemImage: "wifi.slash")
                        .font(.headline)
                    Text("Last loaded \(status.savedAt.formatted(date: .abbreviated, time: .shortened)). Refresh to reconnect. Changes are unavailable until refreshed.")
                        .font(.caption)
                }
                if let warning = status.warning {
                    Text(warning).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .accessibilityElement(children: .combine)
        }
    }
}
