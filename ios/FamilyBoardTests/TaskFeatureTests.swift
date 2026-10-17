import XCTest
@testable import FamilyBoard

final class TaskFeatureTests: XCTestCase {
    private var session: URLSession!
    private var service: TaskService!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskURLProtocol.self]
        session = URLSession(configuration: configuration)
        service = TaskService(client: APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            token: "test-token", session: session
        ))
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        service = nil
        TaskURLProtocol.handler = nil
        super.tearDown()
    }

    func testEveryFilterUsesServerQueryContract() async throws {
        let expected: [(TaskFilter, String, String)] = [
            (.mine, "assignedToMe", "true"), (.family, "type", "FAMILY"),
            (.chores, "type", "CHORE"), (.privateTasks, "type", "PRIVATE"),
            (.maintenance, "type", "MAINTENANCE"), (.gifts, "type", "GIFT"),
            (.travel, "type", "TRAVEL"), (.archive, "status", "DONE")
        ]
        XCTAssertEqual(expected.count, TaskFilter.allCases.count)
        for (filter, key, value) in expected {
            TaskURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/tasks")
                let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                XCTAssertEqual(components.queryItems, [URLQueryItem(name: key, value: value)])
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                return (200, "[]")
            }
            let tasks = try await service.tasks(filter: filter)
            XCTAssertTrue(tasks.isEmpty)
        }
    }

    func testCreationUsesStringStepsAndOptionalSchedule() async throws {
        var draft = TaskDraft(filter: .mine, currentUserID: "user-1", task: nil)
        draft.title = "  Dishes  "
        draft.steps = [" Load ", " ", "Run"]
        draft.hasDueDate = true
        draft.dueDate = Date(timeIntervalSince1970: 1_792_454_400)
        draft.isRepeating = true
        draft.repeatFrequency = "DAILY"
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/tasks")
            let body = try Self.body(request)
            XCTAssertEqual(body["title"] as? String, "Dishes")
            XCTAssertEqual(body["type"] as? String, "FAMILY")
            XCTAssertEqual(body["assigneeId"] as? String, "user-1")
            XCTAssertEqual(body["steps"] as? [String], ["Load", "Run"])
            XCTAssertEqual(body["dueDate"] as? String, "2026-10-20T00:00:00Z")
            XCTAssertEqual(body["repeatFrequency"] as? String, "DAILY")
            return (201, #"{"id":"created","steps":[]}"#)
        }
        // Create responses intentionally need not contain list relationships.
        try await service.save(draft, taskID: nil)
    }

    func testUpdateUnassignsAndOmitsUnsupportedStepAndTypeEdits() async throws {
        var draft = TaskDraft(filter: .family, currentUserID: nil, task: nil)
        draft.title = "Dishes"
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/tasks/task-1")
            let body = try Self.body(request)
            XCTAssertTrue(body["assigneeId"] is NSNull)
            XCTAssertTrue(body["dueDate"] is NSNull)
            XCTAssertTrue(body["repeatFrequency"] is NSNull)
            XCTAssertEqual(body["isRepeating"] as? Bool, false)
            XCTAssertNil(body["steps"])
            XCTAssertNil(body["type"])
            return (200, #"{"id":"task-1"}"#)
        }
        try await service.save(draft, taskID: "task-1")
    }

    func testStatusPreservesRepeatingScheduleAndStepAndDeleteRoutes() async throws {
        let task = try decodeTask()
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/tasks/task-1")
            let body = try Self.body(request)
            XCTAssertEqual(body["status"] as? String, "DONE")
            XCTAssertEqual(body["isRepeating"] as? Bool, true)
            XCTAssertEqual(body["repeatFrequency"] as? String, "WEEKLY")
            return (200, #"{"id":"task-1"}"#)
        }
        try await service.setStatus(.done, task: task)
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/tasks/task-1/steps/step-1")
            XCTAssertEqual(try Self.body(request)["completed"] as? Bool, true)
            return (200, #"{"id":"step-1","completed":true}"#)
        }
        try await service.setStep(taskID: "task-1", stepID: "step-1", completed: true)
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/tasks/task-1")
            return (200, #"{"message":"Task deleted"}"#)
        }
        try await service.delete(taskID: "task-1")
    }

    func testAssignmentEndpointAndServerErrors() async throws {
        TaskURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/users")
            return (200, #"[{"id":"user-1","name":"Family member","username":"member"}]"#)
        }
        let users = try await service.users()
        XCTAssertEqual(users.first?.id, "user-1")
        TaskURLProtocol.handler = { _ in (400, #"{"error":"Failed to delete task"}"#) }
        do {
            try await service.delete(taskID: "task-1")
            XCTFail("Expected server error")
        } catch APIError.server(_, let message) {
            XCTAssertEqual(message, "Failed to delete task")
        }
    }

    func testDraftDefaultsValidationAndExistingAssignment() throws {
        let mine = TaskDraft(filter: .mine, currentUserID: "user-1", task: nil)
        XCTAssertEqual(mine.assigneeID, "user-1")
        let privateTask = TaskDraft(filter: .privateTasks, currentUserID: "user-1", task: nil)
        XCTAssertEqual(privateTask.type, "PRIVATE")
        XCTAssertEqual(privateTask.assigneeID, "user-1")
        XCTAssertEqual(TaskDraft(filter: .archive, currentUserID: "user-1", task: nil).type, "FAMILY")
        var existing = TaskDraft(filter: .family, currentUserID: "other", task: try decodeTask())
        XCTAssertEqual(existing.assigneeID, "user-1")
        XCTAssertTrue(existing.hasDueDate)
        XCTAssertTrue(existing.isRepeating)
        XCTAssertEqual(existing.steps, ["Load"])
        existing.title = " \n "
        XCTAssertFalse(existing.isValid)
    }

    func testGroupingPreservesUnknownAssigneesAndUnassignedTasks() throws {
        let assigned = try decodeTask()
        let unassigned = try decodeTask(assignee: "null")
        let groups = TaskAssignmentGroup.make(tasks: [assigned, unassigned], users: [])
        XCTAssertEqual(groups.first?.name, "Unassigned")
        XCTAssertEqual(groups.first?.tasks.count, 1)
        XCTAssertEqual(groups.last?.id, "user-1")
        XCTAssertEqual(groups.last?.name, "Family member")
        XCTAssertEqual(groups.flatMap(\.tasks).count, 2)
        let users = [User(id: "user-1", username: "member", name: "Family member")]
        XCTAssertEqual(TaskAssignmentGroup.make(tasks: [assigned], users: users).count, 2)
    }

    private func decodeTask(assignee: String = #"{"id":"user-1","name":"Family member"}"#) throws -> BoardTask {
        let json = """
        {"id":"task-1","title":"Dishes","description":null,"status":"TODO","type":"FAMILY",
        "priority":"MEDIUM","dueDate":"2026-10-20T00:00:00Z","isRepeating":true,
        "repeatFrequency":"WEEKLY","steps":[{"id":"step-1","content":"Load","completed":false}],
        "assignee":\(assignee),"creator":null}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BoardTask.self, from: Data(json.utf8))
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class TaskURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
