import Foundation

private final class MockHTTP: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) throws -> (Int, [String: String], [String: Any]))?
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.lock.unlock()
        do {
            let (status, headers, body) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
private final class MemoryTokens: TokenStorage {
    var token: TokenData?
    init(expired: Bool = false, empty: Bool = false) {
        token = empty ? nil : TokenData(clientID: "client", accessToken: "access", refreshToken: "refresh",
                                        expiresAt: Date().addingTimeInterval(expired ? -10 : 3600))
    }
    func load() throws -> TokenData? { token }
    func save(_ token: TokenData) throws { self.token = token }
    func clear() throws { token = nil }
}

final class DingTalkClientTests {
    @MainActor
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], [String: Any]), storage: MemoryTokens = MemoryTokens()) -> DingTalkClient {
        MockHTTP.state.lock.lock()
        MockHTTP.state.handler = handler
        MockHTTP.state.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return DingTalkClient(session: URLSession(configuration: config), storage: storage)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func rpc(_ request: URLRequest, result: [String: Any]) throws -> [String: Any] {
        let body = try body(request)
        return ["jsonrpc": "2.0", "id": body["id"] ?? 0, "result": result]
    }

    private static func page(_ cards: [[String: Any]], hasMore: Bool? = nil) throws -> [String: Any] {
        var result: [String: Any] = ["todoCards": cards]
        if let hasMore { result["hasMore"] = hasMore }
        let data = try JSONSerialization.data(withJSONObject: ["success": true, "result": result])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    @MainActor
    func testLocalCredentialFilePermissionsAndReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DingTodoBar-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileTokenStorage(fileURL: directory.appendingPathComponent("credentials.json"))
        XCTAssertNil(try storage.load())
        let first = TokenData(clientID: "test", accessToken: "first", refreshToken: "refresh", expiresAt: Date())
        try storage.save(first)
        XCTAssertEqual(try storage.load()?.accessToken, "first")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: storage.fileURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(directoryMode.intValue, 0o700)
        XCTAssertEqual(fileMode.intValue, 0o600)
        try storage.save(TokenData(clientID: "test", accessToken: "second", refreshToken: "rotated", expiresAt: Date()))
        XCTAssertEqual(try storage.load()?.accessToken, "second")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["credentials.json"])
        try storage.clear()
        XCTAssertNil(try storage.load())
    }

    @MainActor
    func testPaginationUsesCrossOrganizationToolAndSession() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.absoluteString, DingTalkClient.todoEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            let body = try Self.body(request)
            switch body["method"] as? String {
            case "initialize":
                return (200, ["Mcp-Session-Id": "session"], try Self.rpc(request, result: ["protocolVersion": "2024-11-05"]))
            case "notifications/initialized": return (202, [:], [:])
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "session")
                let params = try XCTUnwrap(body["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "get_user_todos")
                let args = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(args["todoStatus"] as? String, "false")
                XCTAssertEqual(args["roleTypes"] as? [String], ["executor"])
                let page = args["pageNum"] as? String
                let cards: [[String: Any]] = page == "1" ? [["taskId": "a", "subject": "同名"], ["taskId": "b", "subject": "同名"]] : [["taskId": "c", "subject": "第三条"]]
                return (200, [:], try Self.rpc(request, result: Self.page(cards)))
            }
        }
        let snapshot = try await client.readTodos(pageSize: 2)
        XCTAssertEqual(snapshot.pages, 2)
        XCTAssertEqual(snapshot.titles, ["同名", "同名", "第三条"])
    }

    @MainActor
    func testExpiredTokenRefreshesAndKeepsRefreshTokenIfNotRotated() async throws {
        let tokens = MemoryTokens(expired: true)
        let client = client({ request in
            if request.url?.path == "/oauth2/refreshToken" {
                let body = try Self.body(request)
                XCTAssertEqual(body["clientId"] as? String, "client")
                XCTAssertEqual(body["refreshToken"] as? String, "refresh")
                return (200, [:], ["accessToken": "new-access", "expiresIn": 7200])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-user-access-token"), "new-access")
            let method = try Self.body(request)["method"] as? String
            return (200, [:], try Self.rpc(request, result: method == "tools/call" ? Self.page([]) : [:]))
        }, storage: tokens)
        _ = try await client.readTodos()
        XCTAssertEqual(tokens.token?.accessToken, "new-access")
        XCTAssertEqual(tokens.token?.refreshToken, "refresh")
    }

    @MainActor
    func testHasMoreOverridesShortPageAndAllStatusOmitsFilter() async throws {
        let client = client { request in
            let body = try Self.body(request)
            if body["method"] as? String != "tools/call" { return (200, [:], try Self.rpc(request, result: [:])) }
            let args = (body["params"] as! [String: Any])["arguments"] as! [String: Any]
            XCTAssertNil(args["todoStatus"])
            let first = args["pageNum"] as? String == "1"
            return (200, [:], try Self.rpc(request, result: Self.page([["taskId": first ? "a" : "b", "subject": "标题"]], hasMore: first)))
        }
        let snapshot = try await client.readTodos(status: nil)
        XCTAssertEqual(snapshot.pages, 2)
        XCTAssertEqual(snapshot.cards.count, 2)
    }

    @MainActor
    func testRepeatedPageFailsInsteadOfReturningPartialData() async throws {
        let client = client { request in
            let method = try Self.body(request)["method"] as? String
            return (200, [:], try Self.rpc(request, result: method == "tools/call" ? Self.page([["taskId": "a"]], hasMore: true) : [:]))
        }
        do { _ = try await client.readTodos(); XCTFail("Should reject repeated page") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重复分页")) }
    }

    @MainActor
    func testDeviceAuthorizationExchangesCodeAndSavesRotatingToken() async throws {
        let tokens = MemoryTokens(empty: true)
        let client = client({ request in
            switch request.url?.path {
            case "/cli/clientId": return (200, [:], ["success": true, "result": "managed-client"])
            case "/oauth2/device/code.json":
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], ["success": true, "result": ["deviceCode": "device", "userCode": "user", "flowId": "flow", "interval": 0.001, "verificationUriComplete": "https://login.dingtalk.com/verify"]])
            case "/cli/oauth/device/poll": return (200, [:], ["success": true, "result": ["status": "APPROVED", "authCode": "approved-code"]])
            case "/oauth2/getToken":
                let body = try Self.body(request)
                XCTAssertEqual(body["authCode"] as? String, "approved-code")
                XCTAssertEqual(body["clientId"] as? String, "managed-client")
                return (200, [:], ["accessToken": "authorized-access", "refreshToken": "authorized-refresh", "expiresIn": 7200])
            default: throw DingTalkError(message: "Unexpected request")
            }
        }, storage: tokens)
        let authorization = try await client.beginAuthorization()
        try await client.finishAuthorization(authorization)
        XCTAssertEqual(tokens.token?.clientID, "managed-client")
        XCTAssertEqual(tokens.token?.refreshToken, "authorized-refresh")
    }

    @MainActor
    func testUnauthorizedRefreshesOnceAndRotatesRefreshToken() async throws {
        let tokens = MemoryTokens()
        let client = client({ request in
            if request.url?.path == "/oauth2/refreshToken" {
                return (200, [:], ["accessToken": "new-access", "refreshToken": "rotated-refresh", "expiresIn": 7200])
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access" { return (401, [:], [:]) }
            let method = try Self.body(request)["method"] as? String
            return (200, [:], try Self.rpc(request, result: method == "tools/call" ? Self.page([]) : [:]))
        }, storage: tokens)
        _ = try await client.readTodos()
        XCTAssertEqual(tokens.token?.refreshToken, "rotated-refresh")
    }

    @MainActor
    func testLegacyDevicePollingAndRejection() async throws {
        let client = client { request in
            switch request.url?.path {
            case "/cli/clientId": return (200, [:], ["success": true, "result": "client"])
            case "/oauth2/device/code.json":
                return (200, [:], ["success": true, "result": ["deviceCode": "device", "userCode": "user", "interval": 0.001, "verificationUriComplete": "https://login.dingtalk.com/verify"]])
            case "/oauth2/device/token.json":
                return (200, [:], ["success": true, "result": ["error": "access_denied"]])
            default: throw DingTalkError(message: "Unexpected request")
            }
        }
        let authorization = try await client.beginAuthorization()
        XCTAssertNil(authorization.flowID)
        do { try await client.finishAuthorization(authorization); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("拒绝")) }
    }

    @MainActor
    func testPageLimitFailsAndMissingAuthorizationMakesNoRequest() async throws {
        let paged = client { request in
            let method = try Self.body(request)["method"] as? String
            return (200, [:], try Self.rpc(request, result: method == "tools/call" ? Self.page([["taskId": "a"]], hasMore: true) : [:]))
        }
        do { _ = try await paged.readTodos(maxPages: 1); XCTFail("Expected page limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("上限")) }
        let empty = client({ _ in fatalError("No network request expected") }, storage: MemoryTokens(empty: true))
        do { _ = try await empty.readTodos(); XCTFail("Expected authorization error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未授权")) }
    }

    @MainActor
    func testMalformedAndBusinessErrorsAreNotEmptyLists() throws {
        XCTAssertThrowsError(try DingTalkClient.parsePage(["isError": true]))
        XCTAssertThrowsError(try DingTalkClient.parsePage(["structuredContent": ["success": false, "result": ["todoCards": []]]]))
        XCTAssertThrowsError(try DingTalkClient.parsePage(["structuredContent": ["result": [:]]]))
        XCTAssertEqual(try DingTalkClient.parsePage(Self.page([])).cards.count, 0)
        XCTAssertEqual(try DingTalkClient.parsePage(["structuredContent": ["success": true, "errorCode": "", "result": ["todoCards": []]]]).cards.count, 0)
        XCTAssertEqual(try DingTalkClient.parseToken(["accessToken": "token", "errorCode": "", "errorMsg": ""], clientID: "client").accessToken, "token")
    }

    @MainActor
    func testSSEAndMismatchedIDs() throws {
        let data = Data("event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\r\n\r\n".utf8)
        XCTAssertNotNil(try DingTalkClient.decodeRPC(data, id: 7)["result"])
        XCTAssertThrowsError(try DingTalkClient.decodeRPC(data, id: 8))
    }

    @MainActor
    func testRefreshFailureDoesNotEraseExistingCredentials() async throws {
        let tokens = MemoryTokens(expired: true)
        let client = client({ _ in (200, [:], ["errorCode": "invalid_grant", "errorMsg": "rejected"]) }, storage: tokens)
        do { _ = try await client.readTodos(); XCTFail("Should reject refresh") }
        catch { XCTAssertTrue(error.localizedDescription.contains("重新授权")) }
        XCTAssertEqual(tokens.token?.refreshToken, "refresh")
    }
}

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}
private func XCTAssertTrue(_ condition: Bool) { precondition(condition) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
private func XCTFail(_ message: String) { fatalError(message) }
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw DingTalkError(message: "Expected non-nil value") }
    return value
}
private func XCTAssertThrowsError<T>(_ operation: @autoclosure () throws -> T) {
    do { _ = try operation(); fatalError("Expected error") } catch { }
}

@main
struct TestRunner {
    @MainActor static func main() async throws {
        let tests = DingTalkClientTests()
        try await tests.testPaginationUsesCrossOrganizationToolAndSession()
        try await tests.testExpiredTokenRefreshesAndKeepsRefreshTokenIfNotRotated()
        try await tests.testHasMoreOverridesShortPageAndAllStatusOmitsFilter()
        try await tests.testRepeatedPageFailsInsteadOfReturningPartialData()
        try await tests.testDeviceAuthorizationExchangesCodeAndSavesRotatingToken()
        try tests.testMalformedAndBusinessErrorsAreNotEmptyLists()
        try tests.testSSEAndMismatchedIDs()
        try await tests.testRefreshFailureDoesNotEraseExistingCredentials()
        try await tests.testUnauthorizedRefreshesOnceAndRotatesRefreshToken()
        try await tests.testLegacyDevicePollingAndRejection()
        try await tests.testPageLimitFailsAndMissingAuthorizationMakesNoRequest()
        try tests.testLocalCredentialFilePermissionsAndReplacement()
        print("PASS: 12 Swift integration, parser and storage tests")
    }
}
