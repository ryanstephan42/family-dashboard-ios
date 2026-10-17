import SwiftUI
import WebKit

/// The shared Nextcloud calendar is intentionally remote and read-only here.
struct SharedCalendarView: View {
    @EnvironmentObject private var session: Session
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case configured(SharedCalendarLinks)
        case unconfigured
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading shared calendar...")
                case .configured(let links):
                    SharedCalendarContent(links: links)
                case .unconfigured:
                    ContentUnavailableView {
                        Label("Calendar not linked", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("Ask the server administrator to set NEXTCLOUD_CALENDAR_EMBED_URL to your Nextcloud calendar's public share/embed link.")
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't load calendar", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Family Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh calendar configuration", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task(id: session.serverURL) { await load() }
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @MainActor
    private func load() async {
        state = .loading
        guard let client = session.client else {
            state = .failed("Connect to your family server to load the shared calendar.")
            return
        }
        do {
            let links = try await SharedCalendarService(client: client).load()
            try Task.checkCancellation()
            state = links.map(LoadState.configured) ?? .unconfigured
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch APIError.unauthorized {
            session.logout()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct SharedCalendarContent: View {
    let links: SharedCalendarLinks
    @State private var loading = true
    @State private var error: String?
    @State private var reloadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your family's shared Nextcloud calendar. Add or edit events in Nextcloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Link(destination: links.nextcloudURL) {
                    Label("Open in Nextcloud", systemImage: "arrow.up.right.square")
                }
                .accessibilityHint("Opens the calendar outside Family Board")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            SharedCalendarWebView(url: links.embedURL, loading: $loading, error: $error)
                .id(reloadID)
                .opacity(error == nil ? 1 : 0)
                .accessibilityHidden(error != nil)
                .overlay {
                    if let error {
                        ContentUnavailableView {
                            Label("Couldn't display calendar", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry calendar") {
                                self.error = nil
                                loading = true
                                reloadID = UUID()
                            }
                        }
                    } else if loading {
                        ProgressView("Loading Nextcloud calendar...")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
    }
}

private struct SharedCalendarWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.accessibilityLabel = "Nextcloud family calendar"
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SharedCalendarWebView

        init(_ parent: SharedCalendarWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, SharedCalendarLinks.isSafeWebURL(url) else {
                decisionHandler(.cancel)
                parent.loading = false
                parent.error = SharedCalendarError.unsafeNavigation.localizedDescription
                return
            }
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(navigationAction.request)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.error = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                decisionHandler(.cancel)
                parent.loading = false
                parent.error = "Nextcloud returned an error (HTTP \(response.statusCode)). Try again or open the calendar in Nextcloud."
            } else {
                decisionHandler(.allow)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.loading = false
            parent.error = "The calendar stopped unexpectedly. Retry to reload it."
        }

        private func fail(_ error: Error) {
            guard (error as? URLError)?.code != .cancelled else { return }
            parent.loading = false
            parent.error = error.localizedDescription
        }
    }
}
