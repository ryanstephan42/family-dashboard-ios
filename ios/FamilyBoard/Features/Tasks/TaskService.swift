import Foundation

struct TaskService {
    let client: APIClient

    func tasks(filter: TaskFilter) async throws -> [BoardTask] {
        try await client.request("GET", filter.path)
    }

    func users() async throws -> [User] {
        try await client.request("GET", "/users")
    }

    func save(_ draft: TaskDraft, taskID: String?) async throws {
        _ = try await client.send(taskID == nil ? "POST" : "PUT",
                                  taskID.map(Self.path) ?? "/tasks",
                                  body: draft.payload(creating: taskID == nil))
    }

    func setStatus(_ status: TaskStatus, task: BoardTask) async throws {
        // The server clears repeatFrequency when isRepeating is omitted on PUT.
        _ = try await client.send("PUT", Self.path(task.id), body: StatusPayload(
            status: status.rawValue, isRepeating: task.isRepeating, repeatFrequency: task.repeatFrequency
        ))
    }

    func setStep(taskID: String, stepID: String, completed: Bool) async throws {
        _ = try await client.send("PATCH", "\(Self.path(taskID))/steps/\(Self.component(stepID))",
                                  body: ["completed": completed])
    }

    func delete(taskID: String) async throws {
        _ = try await client.send("DELETE", Self.path(taskID))
    }

    private static func path(_ id: String) -> String { "/tasks/\(component(id))" }

    private static func component(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    private struct StatusPayload: Encodable {
        let status: String
        let isRepeating: Bool
        let repeatFrequency: String?
    }
}
