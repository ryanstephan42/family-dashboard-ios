import Combine
import Foundation

@MainActor
final class Session: ObservableObject {
    @Published var serverURL: URL?
    @Published var token: String?
    @Published var user: User?
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStore
    private let networkSession: URLSession
    private var generation = UUID()

    private struct SavedSession: Codable {
        let serverURL: URL
        let token: String
        let user: User
    }

    var isLoggedIn: Bool { token != nil }

    var client: APIClient? {
        guard let serverURL else { return nil }
        let generation = generation
        return APIClient(baseURL: serverURL, token: token, session: networkSession,
                         onUnauthorized: { [weak self] in
            guard let self, self.generation == generation, self.isLoggedIn else { return }
            self.logout()
            if self.errorMessage == nil { self.errorMessage = APIError.unauthorized.localizedDescription }
        })
    }

    init(defaults: UserDefaults = .standard,
         credentialStore: any CredentialStore = KeychainStore(),
         networkSession: URLSession = .shared) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.networkSession = networkSession
        if let s = defaults.string(forKey: "serverURL") { serverURL = APIClient.normalize(s) }
        do {
            if let saved = try credentialStore.get("session") {
                let restored = try JSONDecoder().decode(SavedSession.self, from: Data(saved.utf8))
                if restored.serverURL == serverURL {
                    token = restored.token
                    user = restored.user
                } else {
                    try clearCredentials()
                    errorMessage = "Your saved sign-in belongs to a different server. Please sign in again."
                }
            } else if try credentialStore.get("token") != nil {
                try clearCredentials()
                errorMessage = "Please sign in again to restore your account details."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func connect(to input: String) async throws {
        guard let url = APIClient.normalize(input) else { throw APIError.invalidURL }
        let attempt = generation
        try await APIClient(baseURL: url, session: networkSession).checkCompatibility()
        guard generation == attempt else { throw CancellationError() }
        if url != serverURL {
            try clearCredentials()
            token = nil
            user = nil
            generation = UUID()
        }
        defaults.set(url.absoluteString, forKey: "serverURL")
        serverURL = url
    }

    func login(username: String, password: String) async throws {
        guard let client, let serverURL else { throw APIError.invalidURL }
        let attempt = generation
        let res: LoginResponse = try await client.request(
            "POST", "/users/login", body: ["username": username, "password": password])
        guard generation == attempt else { throw CancellationError() }
        let saved = SavedSession(serverURL: serverURL, token: res.token, user: res.user)
        let data = try JSONEncoder().encode(saved)
        try credentialStore.set(String(decoding: data, as: UTF8.self), for: "session")
        generation = UUID()
        token = res.token
        user = res.user
    }

    @discardableResult
    func logout() -> Bool {
        generation = UUID()
        token = nil
        user = nil
        do {
            try clearCredentials()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func changeServer() {
        guard logout() else { return }
        defaults.removeObject(forKey: "serverURL")
        serverURL = nil
    }

    private func clearCredentials() throws {
        try credentialStore.delete("session")
        try credentialStore.delete("token")
    }
}
