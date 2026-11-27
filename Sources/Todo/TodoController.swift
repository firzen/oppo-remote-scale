import AppKit

@MainActor
@objc(TodoController)
public final class TodoController: NSObject {
    private let client: DingTalkClient
    private var operation: Task<Void, Never>?
    private var helper: Process?
    private var rotation: Timer?
    private var automaticSyncTimer: Timer?
    private var titles: [String] = []
    private var cursor = 0
    private var authorizationURL: URL?
    private weak var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "尚未同步待办", action: nil, keyEquivalent: "")
    private let titleItem = NSMenuItem(title: "暂无待办数据", action: nil, keyEquivalent: "")
    private var syncItem: NSMenuItem!
    private var authItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var linkItem: NSMenuItem!
    private let defaults = UserDefaults.standard
    private var automaticSyncEnabled: Bool { defaults.bool(forKey: "TodoAutomaticSync") }
    private var rotates: Bool { defaults.object(forKey: "TodoRotation") as? Bool ?? true }
    private var notesEnabled: Bool { defaults.object(forKey: "TodoNotesSync") as? Bool ?? true }

    public override init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OPPORemoteOptimize/credentials.json")
        let storage = FileTokenStorage(fileURL: url)
        var migrationError: Error?
        do {
            if !FileManager.default.fileExists(atPath: url.path), let old = try FileTokenStorage().load() {
                try storage.save(old)
            }
        } catch { migrationError = error }
        client = DingTalkClient(storage: storage)
        super.init()
        if let migrationError { stateItem.title = "授权迁移失败：" + migrationError.localizedDescription }
    }

    @objc(attachToMenu:statusItem:)
    public func attach(to menu: NSMenu, statusItem: NSStatusItem) {
        self.statusItem = statusItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "钉钉待办", action: nil, keyEquivalent: "").isEnabled = false
        stateItem.isEnabled = false
        titleItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(titleItem)
        syncItem = add("立即同步", #selector(sync), to: menu)
        authItem = add("授权钉钉", #selector(authorize), to: menu)
        linkItem = add("重新打开授权页面", #selector(openAuthorization), to: menu)
        linkItem.isHidden = true
        cancelItem = add("取消当前操作", #selector(cancel), to: menu)
        cancelItem.isEnabled = false
        add("打开钉钉待办同步文件夹", #selector(openNotes), to: menu)
        let rotationItem = add("轮播待办标题", #selector(toggleRotation(_:)), to: menu)
        rotationItem.state = rotates ? .on : .off
        let automaticItem = add("每半小时自动同步", #selector(toggleAutomaticSync(_:)), to: menu)
        automaticItem.state = automaticSyncEnabled ? .on : .off
        configureAutomaticSync()
        let notesItem = add("同步到备忘录", #selector(toggleNotes(_:)), to: menu)
        notesItem.state = notesEnabled ? .on : .off
        rotation = Timer(timeInterval: 6, target: self, selector: #selector(rotate), userInfo: nil, repeats: true)
        RunLoop.main.add(rotation!, forMode: .common)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func busy(_ value: Bool) {
        syncItem.isEnabled = !value
        authItem.isEnabled = !value
        cancelItem.isEnabled = value
    }

    @objc private func rotate() {
        if !titles.isEmpty {
            titleItem.title = titles[cursor % titles.count]
            cursor = (cursor + 1) % titles.count
        }
        updateLabel()
    }

    private func updateLabel() {
        guard let item = statusItem else { return }
        let title = rotates && !titles.isEmpty ? String(titleItem.title.prefix(24)) : ""
        item.length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        item.button?.title = title.isEmpty ? "" : " " + title
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = titles.isEmpty ? "远控分辨率 · " + stateItem.title : titleItem.title + "\n" + stateItem.title
    }

    @objc private func toggleRotation(_ sender: NSMenuItem) {
        defaults.set(!rotates, forKey: "TodoRotation")
        sender.state = rotates ? .on : .off
        updateLabel()
    }
    @objc private func toggleNotes(_ sender: NSMenuItem) {
        defaults.set(!notesEnabled, forKey: "TodoNotesSync")
        sender.state = notesEnabled ? .on : .off
    }
    @objc private func toggleAutomaticSync(_ sender: NSMenuItem) {
        defaults.set(!automaticSyncEnabled, forKey: "TodoAutomaticSync")
        sender.state = automaticSyncEnabled ? .on : .off
        configureAutomaticSync()
    }

    private func configureAutomaticSync() {
        automaticSyncTimer?.invalidate()
        automaticSyncTimer = nil
        guard automaticSyncEnabled else { return }
        let timer = Timer(timeInterval: 30 * 60, target: self,
                          selector: #selector(automaticSync), userInfo: nil, repeats: true)
        automaticSyncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func automaticSync() {
        guard automaticSyncEnabled, operation == nil else { return }
        sync()
    }

    @objc private func openAuthorization() {
        if let authorizationURL { NSWorkspace.shared.open(authorizationURL) }
    }
    @objc private func authorize() {
        guard operation == nil else { return }
        busy(true)
        stateItem.title = "正在申请授权…"
        operation = Task {
            defer { operation = nil; busy(false); updateLabel() }
            do {
                let auth = try await client.beginAuthorization()
                authorizationURL = auth.verificationURL
                linkItem.isHidden = false
                stateItem.title = "等待钉钉授权：" + auth.userCode
                openAuthorization()
                try await client.finishAuthorization(auth)
                stateItem.title = "授权成功，请点击「立即同步」"
            } catch is CancellationError { stateItem.title = "授权已取消" }
            catch { stateItem.title = error.localizedDescription }
            authorizationURL = nil
            linkItem.isHidden = true
        }
    }
    @objc private func sync() {
        guard operation == nil else { return }
        busy(true)
        let writeNotes = notesEnabled
        stateItem.title = "正在读取待办…"
        operation = Task {
            defer { operation = nil; busy(false); updateLabel() }
            do {
                let snapshot = try await client.readTodos()
                try Task.checkCancellation()
                titles = snapshot.titles
                cursor = 0
                titleItem.title = titles.first ?? "暂无未完成待办"
                updateLabel()
                if writeNotes {
                    stateItem.title = "已读取 \(titles.count) 条，正在写入备忘录…"
                    let result = try await writeToNotes(snapshot)
                    stateItem.title = result
                } else { stateItem.title = "已读取 \(titles.count) 条待办（未写入备忘录）" }
            } catch is CancellationError { stateItem.title = "操作已取消；备忘录可能已部分更新，可重新同步" }
            catch { stateItem.title = error.localizedDescription }
        }
    }
    private func writeToNotes(_ snapshot: TodoSnapshot) async throws -> String {
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TodoNotesHelper")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let data = try snapshot.jsonData()
        // Write through a private temporary file, avoiding pipe capacity deadlocks for large lists.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oppo-todos-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DingTalkError(message: "无法创建备忘录同步数据文件。")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        process.standardInput = handle
        helper = process
        defer { helper = nil }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard status == 0 else { throw DingTalkError(message: message.isEmpty ? "待办已读取，但备忘录写入失败。" : message) }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @objc private func cancel() {
        operation?.cancel()
        if let helper, helper.isRunning { helper.terminate() }
    }
    @objc private func openNotes() {
        let script = NSAppleScript(source: "tell application \"Notes\"\nactivate\nshow folder \"钉钉待办同步\" of default account\nend tell")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if error != nil { stateItem.title = "无法打开同步文件夹，请先完成一次备忘录同步。" }
    }
    @objc public func stop() { rotation?.invalidate(); automaticSyncTimer?.invalidate(); cancel() }
}
