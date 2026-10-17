import SwiftUI

struct TaskEditorView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask?
    let filter: TaskFilter
    let onSaved: () async -> Void
    @State private var draft: TaskDraft
    @State private var users: [User] = []
    @State private var loadingUsers = true
    @State private var usersError: String?
    @State private var error: String?
    @State private var saving = false
    @State private var initialized = false
    @State private var confirmDiscard = false

    init(task: BoardTask?, filter: TaskFilter, onSaved: @escaping () async -> Void) {
        self.task = task
        self.filter = filter
        self.onSaved = onSaved
        _draft = State(initialValue: TaskDraft(filter: filter, currentUserID: nil, task: task))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $draft.title)
                    TextField("Description", text: $draft.description, axis: .vertical).lineLimit(3...8)
                    LabeledContent("Board", value: task?.type.capitalized ?? filter.title)
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(["LOW", "MEDIUM", "HIGH"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Assignment") {
                    if draft.type == "PRIVATE" {
                        Text("Private tasks belong to their creator.")
                    } else if loadingUsers {
                        ProgressView("Loading family members")
                    } else if let usersError {
                        Text(usersError).foregroundStyle(.red)
                        Button("Retry loading family members") { Task { await loadUsers() } }
                    } else {
                        Picker("Assign to", selection: $draft.assigneeID) {
                            Text("Anyone").tag("")
                            ForEach(users) { Text($0.name).tag($0.id) }
                            if !draft.assigneeID.isEmpty && !users.contains(where: { $0.id == draft.assigneeID }) {
                                Text(task?.assignee?.name ?? "Current assignee").tag(draft.assigneeID)
                            }
                        }
                    }
                }
                Section {
                    if task?.dueDate == nil {
                        Toggle("Due date", isOn: $draft.hasDueDate)
                    }
                    if draft.hasDueDate {
                        DatePicker("Due", selection: $draft.dueDate, displayedComponents: .date)
                    }
                    Toggle("Repeating task", isOn: $draft.isRepeating)
                    if draft.isRepeating {
                        Picker("Repeat frequency", selection: $draft.repeatFrequency) {
                            ForEach(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"], id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if task?.dueDate != nil {
                        Text("The server supports changing this due date, but not removing it.")
                    }
                }
                Section {
                    if task == nil {
                        ForEach(draft.steps.indices, id: \.self) { index in
                            HStack {
                                TextField("Step \(index + 1)", text: $draft.steps[index])
                                Button("Remove step \(index + 1)", systemImage: "minus.circle", role: .destructive) {
                                    draft.steps.remove(at: index)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add step", systemImage: "plus") { draft.steps.append("") }
                    } else {
                        ForEach(task?.steps ?? []) { step in
                            Label(step.content, systemImage: step.completed ? "checkmark.circle" : "circle")
                        }
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    if task != nil {
                        Text("Check off steps on the task board. The server only supports adding steps when creating a task.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if saving { ProgressView("Saving task") }
            }
            .disabled(saving)
            .navigationTitle(task == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !draft.isValid || (draft.type != "PRIVATE" && (loadingUsers || usersError != nil)))
                }
            }
            .interactiveDismissDisabled()
            .confirmationDialog("Discard task changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .task {
                if !initialized {
                    draft = TaskDraft(filter: filter, currentUserID: session.user?.id, task: task)
                    initialized = true
                }
                await loadUsers()
            }
        }
    }

    private func loadUsers() async {
        guard let client = session.client else {
            loadingUsers = false
            usersError = "Sign in to load family members."
            return
        }
        loadingUsers = true
        defer { loadingUsers = false }
        do {
            users = try await TaskService(client: client).users()
            usersError = nil
        } catch APIError.unauthorized {
            session.logout()
        } catch {
            usersError = error.localizedDescription
        }
    }

    private func save() async {
        guard !saving, draft.isValid, let client = session.client else { return }
        saving = true
        defer { saving = false }
        do {
            try await TaskService(client: client).save(draft, taskID: task?.id)
            dismiss()
            await onSaved()
        } catch APIError.unauthorized {
            session.logout()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
