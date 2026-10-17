import Combine
import Foundation

@MainActor
final class Session: ObservableObject {
    @Published var serverURL: URL?
    @Published var token: String?
    @Published var user: User?

    var isLoggedIn: Bool { token != nil }

    var client: APIClient? {
        serverURL.map { APIClient(baseURL: $0, token: token) }
    }

    init() {
        if let s = UserDefaults.standard.string(forKey: "serverURL") { serverURL = URL(string: s) }
        token = Keychain.get("token")
    }

    func connect(to input: String) async throws {
        guard let url = APIClient.normalize(input) else { throw APIError.invalidURL }
        try await APIClient(baseURL: url).checkCompatibility()
        UserDefaults.standard.set(url.absoluteString, forKey: "serverURL")
        serverURL = url
    }

    func login(username: String, password: String) async throws {
        guard let client else { throw APIError.invalidURL }
        let res: LoginResponse = try await client.request(
            "POST", "/users/login", body: ["username": username, "password": password])
        Keychain.set(res.token, for: "token")
        token = res.token
        user = res.user
    }

    func logout() {
        Keychain.delete("token")
        token = nil
        user = nil
    }

    func changeServer() {
        logout()
        UserDefaults.standard.removeObject(forKey: "serverURL")
        serverURL = nil
    }
}
