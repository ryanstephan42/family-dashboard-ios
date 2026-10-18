import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var session: Session
    @State private var tasks: [BoardTask] = []
    @State private var users: [User] = []
    @State private var filter = TaskFilter.family
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var editor: TaskEditorSelection?
    @State private var deleting: BoardTask?
    @State private var cacheStatus: ReadCacheStatus?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Task board", selection: $filter) {
                    ForEach(TaskFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(working)
                if let cacheStatus { CachedReadBanner(status: cacheStatus) }
                if let error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await load() } }
                    }
                    .padding()
                    .accessibilityElement(children: .contain)
                }
                if loading {
                    ProgressView("Loading tasks").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    taskList
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New task", systemImage: "plus") { editor = TaskEditorSelection(task: nil) }
                        .disabled(working || loading || cacheStatus?.isStale == true)
                }
            }
            .overlay(alignment: .bottom) {
                if working { ProgressView("Updating task").padding().background(.regularMaterial, in: Capsule()) }
            }
            .task(id: filter) { await load() }
            .sheet(item: $editor) { selection in
                TaskEditorView(task: selection.task, filter: filter) { await load() }
                    .environmentObject(session)
            }
            .confirmationDialog("Delete task?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                if let task = deleting {
                    Button("Delete \"\(task.title)\"", role: .destructive) {
                        Task { await mutate { try await $0.delete(taskID: task.id) } }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the task and its steps.")
            }
        }
    }

    private var taskList: some View {
        List {
            if tasks.isEmpty && error == nil {
                ContentUnavailableView {
                    Label("No tasks", systemImage: filter == .archive ? "archivebox" : "checklist")
                } description: {
                    Text(filter == .archive ? "Completed tasks appear here." : "There are no tasks on this board.")
                } actions: {
                    Button("New task") { editor = TaskEditorSelection(task: nil) }
                }
                .listRowBackground(Color.clear)
            } else if filter == .family {
                ForEach(TaskAssignmentGroup.make(tasks: tasks, users: users)) { group in
                    Section {
                        if group.tasks.isEmpty { Text("No tasks").foregroundStyle(.secondary) }
                        ForEach(group.tasks) { row($0) }
                    } header: { Text("\(group.name) (\(group.tasks.count))") }
                }
            } else {
                ForEach(tasks) { row($0) }
            }
        }
        .disabled(working || cacheStatus?.isStale == true)
        .refreshable { await load() }
    }

    private func row(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(task.title).font(.headline).strikethrough(task.status == "DONE")
                Spacer()
                Menu {
                    Button("Edit task", systemImage: "pencil") { editor = TaskEditorSelection(task: task) }
                    ForEach(TaskStatus.allCases) { status in
                        Button(status.title, systemImage: task.status == status.rawValue ? "checkmark.circle.fill" : "circle") {
                            Task { await mutate { try await $0.setStatus(status, task: task) } }
                        }
                    }
                    Button("Delete task", systemImage: "trash", role: .destructive) { deleting = task }
                } label: {
                    Image(systemName: "ellipsis.circle").padding(4)
                }
                .accessibilityLabel("Actions for \(task.title)")
            }
            if let description = task.description, !description.isEmpty { Text(description) }
            Text("\(task.priority.capitalized) priority · \(TaskStatus(rawValue: task.status)?.title ?? task.status)")
                .font(.subheadline).foregroundStyle(.secondary)
            Label(task.assignee?.name ?? "Unassigned", systemImage: "person")
                .font(.caption).foregroundStyle(.secondary)
            if let date = task.dueDate {
                Label("Due \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(date < Calendar.current.startOfDay(for: Date()) && task.status != "DONE" ? .red : .secondary)
            }
            if task.isRepeating {
                Label("Repeats \((task.repeatFrequency ?? "unspecified").lowercased())", systemImage: "repeat")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(task.steps) { step in
                Button {
                    Task { await mutate { try await $0.setStep(taskID: task.id, stepID: step.id, completed: !step.completed) } }
                } label: {
                    Label(step.content, systemImage: step.completed ? "checkmark.circle.fill" : "circle")
                        .strikethrough(step.completed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .disabled(task.status == "DONE")
                .accessibilityLabel("\(step.content), \(step.completed ? "completed" : "not completed")")
                .accessibilityHint("Double tap to \(step.completed ? "uncheck" : "complete") step")
            }
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        guard let client = session.client else {
            loading = false
            error = "Connect to a server and sign in to load tasks."
            return
        }
        let requestedFilter = filter
        loading = true
        error = nil
        defer { if requestedFilter == filter { loading = false } }
        do {
            let service = TaskService(client: client)
            let result = try await session.read(path: requestedFilter.path) {
                async let fetchedTasks = service.tasks(filter: requestedFilter)
                async let fetchedUsers = service.users()
                return try await TaskSnapshot(tasks: fetchedTasks, users: fetchedUsers)
            }
            guard !Task.isCancelled, requestedFilter == filter else { return }
            tasks = result.value.tasks
            users = result.value.users
            cacheStatus = result.status
            error = nil
        } catch is CancellationError {
            return
        } catch APIError.unauthorized {
            return
        } catch {
            guard !Task.isCancelled, requestedFilter == filter else { return }
            tasks = []
            users = []
            cacheStatus = nil
            self.error = error.localizedDescription
        }
    }

    private func mutate(_ operation: (TaskService) async throws -> Void) async {
        guard !working, cacheStatus?.isStale != true, let client = session.client else { return }
        working = true
        defer { working = false }
        do {
            try await operation(TaskService(client: client))
            await load()
        } catch APIError.unauthorized {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TaskSnapshot: Codable {
    let tasks: [BoardTask]
    let users: [User]
}

private struct TaskEditorSelection: Identifiable {
    let id = UUID()
    let task: BoardTask?
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
