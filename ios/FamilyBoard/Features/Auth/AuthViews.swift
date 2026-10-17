import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject var session: Session
    @State private var address = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server address") {
                    TextField("family.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(busy ? "Connecting…" : "Connect") {
                    Task {
                        busy = true; error = nil
                        do { try await session.connect(to: address) }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(address.isEmpty || busy)
            }
            .navigationTitle("Connect")
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var session: Session
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                if let error { Text(error).foregroundStyle(.red) }
                Button(busy ? "Signing in…" : "Sign in") {
                    Task {
                        busy = true; error = nil
                        do { try await session.login(username: username, password: password) }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(username.isEmpty || password.isEmpty || busy)
                Button("Change server", role: .destructive) { session.changeServer() }
            }
            .navigationTitle("Sign in")
        }
    }
}
