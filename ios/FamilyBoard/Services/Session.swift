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
    private let readCache: ReadCache
    private var cacheAvailable = true
    private var readRevision = UUID()
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
        }, onMutation: { [weak self] in
            guard let self, self.generation == generation else { return }
            self.clearReadCache()
        })
    }

    init(defaults: UserDefaults = .standard,
         credentialStore: any CredentialStore = KeychainStore(),
         networkSession: URLSession = .shared,
         readCache: ReadCache? = nil) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.networkSession = networkSession
        self.readCache = readCache ?? ReadCache()
        if let s = defaults.string(forKey: "serverURL") { serverURL = APIClient.normalize(s) }
        do {
            if let saved = try credentialStore.get("session") {
                let restored = try JSONDecoder().decode(SavedSession.self, from: Data(saved.utf8))
                if restored.serverURL == serverURL {
                    token = restored.token
                    user = restored.user
                } else {
                    clearReadCache()
                    try clearCredentials()
                    errorMessage = "Your saved sign-in belongs to a different server. Please sign in again."
                }
            } else if try credentialStore.get("token") != nil {
                clearReadCache()
                try clearCredentials()
                errorMessage = "Please sign in again to restore your account details."
            }
        } catch { errorMessage = error.localizedDescription }
        if !isLoggedIn { clearReadCache() }
    }

    func connect(to input: String) async throws {
        guard let url = APIClient.normalize(input) else { throw APIError.invalidURL }
        let attempt = generation
        try await APIClient(baseURL: url, session: networkSession).checkCompatibility()
        guard generation == attempt else { throw CancellationError() }
        if url != serverURL {
            clearReadCache()
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
        clearReadCache()
        generation = UUID()
        token = res.token
        user = res.user
    }

    @discardableResult
    func logout() -> Bool {
        generation = UUID()
        token = nil
        user = nil
        clearReadCache()
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

    func read<Value: Codable>(path: String, query: [URLQueryItem] = [],
                              fetch: () async throws -> Value) async throws -> CachedRead<Value> {
        guard let client, token != nil, let user else { throw APIError.unauthorized }
        let attempt = generation
        let revision = readRevision
        let key = try ReadCache.key(client: client, userID: user.id, path: path, query: query)
        let value: Value
        do {
            value = try await fetch()
        } catch {
            guard generation == attempt, readRevision == revision, !Task.isCancelled else { throw CancellationError() }
            guard cacheAvailable, ReadCache.allowsFallback(for: error) else { throw error }
            if let cached = try readCache.load(Value.self, key: key) { return cached }
            throw error
        }
        guard generation == attempt, readRevision == revision, !Task.isCancelled else { throw CancellationError() }
        var status = ReadCacheStatus(savedAt: Date(), isStale: false)
        if cacheAvailable {
            do { try readCache.save(value, key: key, at: status.savedAt) }
            catch { status.warning = "Couldn't save offline data: \(error.localizedDescription)" }
        } else {
            status.warning = "Offline storage is unavailable. Sign out and retry to clear it."
        }
        return CachedRead(value: value, status: status)
    }

    private func clearReadCache() {
        readRevision = UUID()
        do {
            try readCache.clear()
            cacheAvailable = true
        } catch {
            // Fail closed: do not read or write snapshots after failed invalidation.
            cacheAvailable = false
            errorMessage = "Couldn't clear offline data: \(error.localizedDescription)"
        }
    }
}
