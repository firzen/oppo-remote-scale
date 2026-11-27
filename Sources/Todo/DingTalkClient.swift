import Foundation
import Darwin

struct DingTalkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TokenData: Codable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

@MainActor
protocol TokenStorage {
    func load() throws -> TokenData?
    func save(_ token: TokenData) throws
    func clear() throws
}

@MainActor
struct FileTokenStorage: TokenStorage {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DingTodoBar/credentials.json")
    }

    func load() throws -> TokenData? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(TokenData.self, from: Data(contentsOf: fileURL))
    }

    func save(_ token: TokenData) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".credentials-" + UUID().uuidString)
        let data = try JSONEncoder().encode(token)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DingTalkError(message: "无法保存本机授权凭证。")
        }
        defer { try? manager.removeItem(at: temporary) }
        // 同一目录内原子替换，保留临时文件的 0600 权限。
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw DingTalkError(message: "无法更新本机授权凭证。")
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

struct DeviceAuthorization {
    let clientID: String
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let flowID: String?
    let deadline: Date
    let interval: Double
}

struct TodoPage {
    let cards: [[String: Any]]
    let hasMore: Bool?
}

struct TodoSnapshot {
    let cards: [[String: Any]]
    let pages: Int
    let status: String?

    var titles: [String] {
        cards.compactMap { card in
            // 保留相同标题的不同任务，不再按窗口文本去重。
            let title = (card["subject"] as? String) ?? (card["title"] as? String)
            return title?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tool": "get_user_todos", "scope": "cross_organization",
            "roleTypes": ["executor"], "todoStatus": status as Any? ?? NSNull(),
            "pages": pages, "count": cards.count, "todoCards": cards
        ], options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }
}

/// 所有请求直接访问钉钉服务，不启动钉钉 CLI。协议依据见 README 中固定版本的源码链接。
@MainActor
final class DingTalkClient {
    static let mcpBase = "https://mcp.dingtalk.com"
    static let todoEndpoint = "https://mcp-gw.dingtalk.com/server/0f51140eddcd913106c5821a4d0cd577b2d1a0b6cb452dd0e51ab41facf3a83c"
    private let session: URLSession
    private let storage: any TokenStorage
    private var sessionID: String?
    private var protocolVersion = "2024-11-05"
    private var rpcID = 0

    init(session: URLSession? = nil, storage: any TokenStorage = FileTokenStorage()) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
        self.storage = storage
    }

    func beginAuthorization() async throws -> DeviceAuthorization {
        let client = try await json(Self.mcpBase + "/cli/clientId")
        guard client["success"] as? Bool == true, let clientID = client["result"] as? String, !clientID.isEmpty else {
            throw DingTalkError(message: "钉钉未提供设备授权客户端，独立接入尚不可用。")
        }
        let response = try await form("https://login.dingtalk.com/oauth2/device/code.json",
                                      ["client_id": clientID, "scope": "openid corpid"])
        guard response["success"] as? Bool == true, let result = response["result"] as? [String: Any],
              let device = result["deviceCode"] as? String, !device.isEmpty,
              let userCode = result["userCode"] as? String,
              let link = (result["verificationUriComplete"] as? String) ?? (result["verificationUri"] as? String),
              let url = URL(string: link), url.scheme == "https",
              let host = url.host, host == "dingtalk.com" || host.hasSuffix(".dingtalk.com") else {
            throw DingTalkError(message: "设备授权失败或返回无效授权链接，请稍后重试。")
        }
        let interval = (result["interval"] as? Double) ?? 5
        let lifetime = (result["expiresIn"] as? Double) ?? 900
        return DeviceAuthorization(clientID: clientID, deviceCode: device, userCode: userCode,
                                   verificationURL: url, flowID: result["flowId"] as? String,
                                   deadline: Date().addingTimeInterval(min(max(lifetime, 1), 960)),
                                   interval: interval > 0 && interval <= 30 ? interval : 5)
    }

    func finishAuthorization(_ authorization: DeviceAuthorization) async throws {
        var interval = authorization.interval
        while Date() < authorization.deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            var code: String?
            if let flow = authorization.flowID, !flow.isEmpty {
                let response = try await json(Self.mcpBase + "/cli/oauth/device/poll?flowId=" + Self.escape(flow))
                let data = response["data"] as? [String: Any] ?? [:]
                let result = (data["status"] as? String)?.isEmpty == false ? data : (response["result"] as? [String: Any] ?? data)
                switch result["status"] as? String {
                case "APPROVED": code = result["authCode"] as? String
                case "PENDING": continue
                case "REJECTED": throw DingTalkError(message: "授权已拒绝，请重新授权。")
                case "EXPIRED": throw DingTalkError(message: "授权链接已过期，请重新授权。")
                default: throw DingTalkError(message: "设备授权状态异常，请重新授权。")
                }
            } else {
                let response = try await form("https://login.dingtalk.com/oauth2/device/token.json", [
                    "client_id": authorization.clientID, "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])
                guard response["success"] as? Bool == true, let result = response["result"] as? [String: Any] else {
                    throw DingTalkError(message: "设备授权轮询失败，请重新授权。")
                }
                switch result["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval = min(interval + 5, 30); continue
                case .some: throw DingTalkError(message: "设备授权失效或已拒绝，请重新授权。")
                case nil: code = result["authCode"] as? String
                }
            }
            guard let code, !code.isEmpty else { throw DingTalkError(message: "授权未返回有效授权码。") }
            let response = try await json(Self.mcpBase + "/oauth2/getToken", body: [
                "clientId": authorization.clientID, "authCode": code, "grantType": "authorization_code"
            ])
            let token = try Self.parseToken(response, clientID: authorization.clientID)
            try storage.save(token)
            return
        }
        throw DingTalkError(message: "授权链接已过期，请重新授权。")
    }

    func forgetAuthorization() throws { try storage.clear() }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let token = try storage.load() else { throw DingTalkError(message: "尚未授权，请先点击「授权钉钉」。") }
        if !forceRefresh && token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
        guard !token.refreshToken.isEmpty else { throw DingTalkError(message: "缺少刷新令牌，请重新授权。") }
        let response = try await json(Self.mcpBase + "/oauth2/refreshToken", body: [
            "clientId": token.clientID, "refreshToken": token.refreshToken, "grantType": "refresh_token"
        ])
        let updated = try Self.parseToken(response, clientID: token.clientID, previousRefresh: token.refreshToken)
        try storage.save(updated)
        return updated.accessToken
    }

    static func parseToken(_ response: [String: Any], clientID: String, previousRefresh: String = "") throws -> TokenData {
        guard (response["errorCode"] as? String ?? "").isEmpty, (response["errorMsg"] as? String ?? "").isEmpty,
              let access = response["accessToken"] as? String, !access.isEmpty else {
            throw DingTalkError(message: "钉钉令牌交换或刷新失败，请重新授权；若持续失败，可能是接入权限受限。")
        }
        let expiry = (response["expiresIn"] as? Double) ?? 7200
        let refresh = (response["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefresh
        return TokenData(clientID: clientID, accessToken: access, refreshToken: refresh,
                         expiresAt: Date().addingTimeInterval(expiry > 0 ? expiry : 7200))
    }

    func readTodos(status: String? = "false", pageSize: Int = 20, maxPages: Int = 500) async throws -> TodoSnapshot {
        guard (1...20).contains(pageSize), maxPages > 0,
              status == nil || status == "false" || status == "true" else {
            throw DingTalkError(message: "无效查询参数。")
        }
        var token = try await accessToken()
        // 只在明确的 HTTP 401 时刷新并完整重读一次，避免无限重试。
        for attempt in 0...1 {
            do { return try await fetchTodos(token: token, status: status, pageSize: pageSize, maxPages: maxPages) }
            catch HTTPFailure.unauthorized where attempt == 0 { token = try await accessToken(forceRefresh: true) }
        }
        throw DingTalkError(message: "授权已失效，请重新授权。")
    }

    private func fetchTodos(token: String, status: String?, pageSize: Int, maxPages: Int) async throws -> TodoSnapshot {
        sessionID = nil
        let initialized = try await rpc("initialize", params: [
            "protocolVersion": "2024-11-05", "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "DingTodoBar", "version": "0.2.0"]
        ], token: token)
        if let version = initialized["protocolVersion"] as? String { protocolVersion = version }
        _ = try await rpc("notifications/initialized", params: [:], token: token, notification: true)
        var cards: [[String: Any]] = []
        var seenPages = Set<Data>()
        for page in 1...maxPages {
            try Task.checkCancellation()
            var arguments: [String: Any] = ["pageNum": String(page), "pageSize": String(pageSize), "roleTypes": ["executor"]]
            if let status { arguments["todoStatus"] = status }
            let result = try await rpc("tools/call", params: ["name": "get_user_todos", "arguments": arguments], token: token)
            let parsed = try Self.parsePage(result)
            if !parsed.cards.isEmpty {
                let fingerprint = try JSONSerialization.data(withJSONObject: parsed.cards, options: [.sortedKeys])
                guard seenPages.insert(fingerprint).inserted else {
                    throw DingTalkError(message: "钉钉返回重复分页，已停止读取；未使用不完整结果。")
                }
            }
            cards.append(contentsOf: parsed.cards)
            if parsed.hasMore == false || (parsed.hasMore == nil && parsed.cards.count < pageSize) {
                return TodoSnapshot(cards: cards, pages: page, status: status)
            }
            if parsed.cards.isEmpty { throw DingTalkError(message: "分页返回空数据但仍标记有下一页，请稍后重试。") }
        }
        throw DingTalkError(message: "待办分页超过安全上限，未使用不完整结果。")
    }

    static func parsePage(_ tool: [String: Any]) throws -> TodoPage {
        guard tool["isError"] as? Bool != true else {
            throw DingTalkError(message: "钉钉 MCP 拒绝待办查询，请检查授权及组织接入权限。")
        }
        var payload = tool["structuredContent"] as? [String: Any]
        if payload == nil, let content = tool["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String, let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    payload = object
                    break
                }
            }
        }
        guard let payload, payload["success"] as? Bool != false, (payload["errorCode"] as? String ?? "").isEmpty,
              let result = payload["result"] as? [String: Any],
              let cards = result["todoCards"] as? [[String: Any]] else {
            throw DingTalkError(message: "待办返回结构不符合预期，需要核对实际 MCP 字段；未将异常结果当作空列表。")
        }
        return TodoPage(cards: cards, hasMore: result["hasMore"] as? Bool)
    }

    private func rpc(_ method: String, params: [String: Any], token: String, notification: Bool = false) async throws -> [String: Any] {
        rpcID += 1
        let id = rpcID
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = URLRequest(url: URL(string: Self.todoEndpoint)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "x-user-access-token")
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await send(request)
        if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        if notification { return [:] }
        let envelope = try Self.decodeRPC(data, id: id)
        guard envelope["error"] == nil, let result = envelope["result"] as? [String: Any] else {
            throw DingTalkError(message: "MCP 请求失败（\(method)），请检查授权及服务权限。")
        }
        return result
    }

    static func decodeRPC(_ data: Data, id: Int) throws -> [String: Any] {
        var candidates = [data]
        if let text = String(data: data, encoding: .utf8), text.contains("data:") {
            candidates = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { event in
                let lines = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                return lines.isEmpty ? nil : lines.joined(separator: "\n").data(using: .utf8)
            }
        }
        for candidate in candidates {
            if let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
               object["jsonrpc"] as? String == "2.0", object["id"] as? Int == id { return object }
        }
        throw DingTalkError(message: "MCP 返回了无效或不匹配的 JSON-RPC 响应。")
    }

    private func json(_ url: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DingTalkError(message: "钉钉返回了无效 JSON。")
        }
        return object
    }

    private func form(_ url: String, _ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters.sorted { $0.key < $1.key }.map { Self.escape($0.key) + "=" + Self.escape($0.value) }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DingTalkError(message: "设备授权返回了无效 JSON。")
        }
        return object
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DingTalkError(message: "无效 HTTP 响应。") }
        if http.statusCode == 401 { throw HTTPFailure.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw DingTalkError(message: "钉钉请求失败（HTTP \(http.statusCode)）；请检查网络、授权或接入权限。")
        }
        guard data.count <= 10 * 1024 * 1024 else { throw DingTalkError(message: "钉钉响应超过大小限制。") }
        return (data, http)
    }
}

private enum HTTPFailure: LocalizedError {
    case unauthorized
    var errorDescription: String? { "授权已失效，请重新授权。" }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 授权和 MCP 请求不跟随重定向，避免凭证转发到其他主机。
        completionHandler(nil)
    }
}
