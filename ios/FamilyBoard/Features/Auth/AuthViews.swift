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
                        .textContentType(.URL)
                        .disabled(busy)
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
                if busy { ProgressView("Checking server compatibility") }
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
                    .textContentType(.username)
                    .disabled(busy)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .disabled(busy)
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
                    .disabled(busy)
                if busy { ProgressView("Signing in") }
            }
            .navigationTitle("Sign in")
        }
    }
}
