import Foundation

struct User: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let name: String
}

struct LoginResponse: Codable {
    let token: String
    let user: User
}

struct ServerConfig: Codable {
    let apiVersion: Int?
    let minClientApiVersion: Int?
}

struct UserRef: Codable, Hashable {
    let id: String
    let name: String
}

struct TaskStep: Codable, Identifiable, Hashable {
    let id: String
    var content: String
    var completed: Bool
}

struct FamilyTask: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var description: String?
    var status: String
    var type: String
    var priority: String
    var dueDate: Date?
    var isRepeating: Bool
    var repeatFrequency: String?
    var steps: [TaskStep]
    var creator: UserRef?
    var assignee: UserRef?
}
