import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var session: Session
    @State private var tasks: [FamilyTask] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.headline)
                    HStack {
                        Text(task.priority.capitalized)
                        if let a = task.assignee { Text("· \(a.name)") }
                        if let d = task.dueDate { Text("· \(d.formatted(date: .abbreviated, time: .omitted))") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay { if let error { Text(error).foregroundStyle(.red) } }
            .navigationTitle("Tasks")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            tasks = try await client.request("GET", "/tasks")
            error = nil
        } catch APIError.unauthorized {
            session.logout()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Server", value: session.serverURL?.absoluteString ?? "-")
                Button("Sign out") { session.logout() }
                Button("Change server", role: .destructive) { session.changeServer() }
            }
            .navigationTitle("Settings")
        }
    }
}
