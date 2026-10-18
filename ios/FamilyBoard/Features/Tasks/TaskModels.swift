import Foundation

enum TaskFilter: String, CaseIterable, Identifiable {
    case mine, family, chores, privateTasks, maintenance, gifts, travel, archive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mine: return "My Tasks"
        case .family: return "Family"
        case .chores: return "Chores"
        case .privateTasks: return "Private"
        case .maintenance: return "Maintenance"
        case .gifts: return "Gifts"
        case .travel: return "Travel"
        case .archive: return "Archive"
        }
    }
    var taskType: String {
        switch self {
        case .mine, .family, .archive: return "FAMILY"
        case .chores: return "CHORE"
        case .privateTasks: return "PRIVATE"
        case .maintenance: return "MAINTENANCE"
        case .gifts: return "GIFT"
        case .travel: return "TRAVEL"
        }
    }
    var path: String {
        switch self {
        case .mine: return "/tasks?assignedToMe=true"
        case .archive: return "/tasks?status=DONE"
        default: return "/tasks?type=\(taskType)"
        }
    }
}

enum TaskStatus: String, CaseIterable, Identifiable {
    case todo = "TODO", inProgress = "IN_PROGRESS", done = "DONE"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .done: return "Done"
        }
    }
}

struct BoardTask: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let type: String
    let priority: String
    let dueDate: Date?
    let isRepeating: Bool
    let repeatFrequency: String?
    let assigneeId: String?
    let creatorId: String?
    let steps: [TaskStep]
    let creator: UserRef?
    let assignee: UserRef?

    var assignmentID: String? { assigneeId ?? assignee?.id }
}

struct TaskAssignmentGroup: Identifiable {
    let id: String
    let name: String
    let tasks: [BoardTask]

    static func make(tasks: [BoardTask], users: [User]) -> [Self] {
        var groups = [Self(id: "unassigned", name: "Unassigned",
                           tasks: tasks.filter { $0.assignmentID == nil })]
        let knownIDs = Set(users.map(\.id))
        groups += users.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { user in
                Self(id: user.id, name: user.name, tasks: tasks.filter { $0.assignmentID == user.id })
            }
        let otherIDs = Set(tasks.compactMap(\.assignmentID)).subtracting(knownIDs)
        groups += otherIDs.sorted().map { id in
            let assigned = tasks.filter { $0.assignmentID == id }
            return Self(id: id, name: assigned.first?.assignee?.name ?? "Other assignee", tasks: assigned)
        }
        return groups
    }
}

struct TaskDraft {
    var title = ""
    var description = ""
    var type = "FAMILY"
    var priority = "MEDIUM"
    var assigneeID = ""
    var hasDueDate = false
    var dueDate = Date()
    var isRepeating = false
    var repeatFrequency = "WEEKLY"
    var steps: [String] = []

    init(filter: TaskFilter, currentUserID: String?, task: BoardTask?) {
        type = task?.type ?? filter.taskType
        assigneeID = task?.assignmentID ?? ((filter == .mine || type == "PRIVATE") ? currentUserID ?? "" : "")
        guard let task else { return }
        title = task.title
        description = task.description ?? ""
        priority = task.priority
        hasDueDate = task.dueDate != nil
        dueDate = task.dueDate ?? Date()
        isRepeating = task.isRepeating
        repeatFrequency = task.repeatFrequency ?? "WEEKLY"
        steps = task.steps.map(\.content)
    }

    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func payload(creating: Bool) -> TaskWritePayload {
        TaskWritePayload(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description, type: creating ? type : nil, priority: priority,
            assigneeId: assigneeID.isEmpty ? nil : assigneeID,
            dueDate: hasDueDate ? ISO8601DateFormatter().string(from: dueDate) : nil,
            isRepeating: isRepeating, repeatFrequency: isRepeating ? repeatFrequency : nil,
            steps: creating ? steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } : nil
        )
    }
}

struct TaskWritePayload: Encodable {
    let title: String
    let description: String
    let type: String?
    let priority: String
    let assigneeId: String?
    let dueDate: String?
    let isRepeating: Bool
    let repeatFrequency: String?
    let steps: [String]?

    enum CodingKeys: String, CodingKey {
        case title, description, type, priority, assigneeId, dueDate, isRepeating, repeatFrequency, steps
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encodeIfPresent(type, forKey: .type)
        try values.encode(priority, forKey: .priority)
        // Explicit null is required to unassign an existing task.
        try values.encode(assigneeId, forKey: .assigneeId)
        try values.encode(dueDate, forKey: .dueDate)
        try values.encode(isRepeating, forKey: .isRepeating)
        try values.encode(repeatFrequency, forKey: .repeatFrequency)
        try values.encodeIfPresent(steps, forKey: .steps)
    }
}
