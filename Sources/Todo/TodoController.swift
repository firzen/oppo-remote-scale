import AppKit

@MainActor
@objc(TodoController)
public final class TodoController: NSObject {
    private let client: DingTalkClient
    private var operation: Task<Void, Never>?
    private var authorized = false
    private let scheduleItem = NSMenuItem()
    private let listItem = NSMenuItem()
    private let listMenu = NSMenu()
    private var reauthItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var stopped = false
    private var helper: Process?
    private var rotation: Timer?
    private var automaticSyncTimer: Timer?
    private var titles: [String] = []
    private var cursor = 0
    private var authorizationURL: URL?
    private weak var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "尚未同步待办", action: nil, keyEquivalent: "")
    private var hasSnapshot = false
    private var rotationTextWidth: CGFloat = 0
    private var syncItem: NSMenuItem!
    private var authItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var linkItem: NSMenuItem!
    private let defaults = UserDefaults.standard
    private var automaticSyncEnabled: Bool { defaults.bool(forKey: "TodoAutomaticSync") }
    private var rotates: Bool { defaults.bool(forKey: "TodoRotation") }
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
        authorized = (try? storage.load()) != nil
        super.init()
        if let migrationError { stateItem.title = "授权迁移失败：" + migrationError.localizedDescription }
    }

    @objc(attachToMenu:statusItem:)
    public func attach(to menu: NSMenu, statusItem: NSStatusItem) {
        self.statusItem = statusItem
        menu.addItem(stateItem)
        menu.addItem(scheduleItem)
        stateItem.isEnabled = false
        scheduleItem.isEnabled = false
        listMenu.autoenablesItems = false
        menu.addItem(listItem)
        listItem.submenu = listMenu
        rebuildList()
        syncItem = add("立即同步", #selector(sync), to: menu)
        authItem = add("授权钉钉", #selector(authorize), to: menu)
        linkItem = add("重新打开授权页面", #selector(openAuthorization), to: menu)
        linkItem.isHidden = true
        cancelItem = add("取消当前操作", #selector(cancel), to: menu)
        permissionItem = add("打开自动化设置", #selector(openAutomation), to: menu)
        permissionItem.isHidden = true
        menu.addItem(.separator())
        add("轮播待办标题", #selector(toggleRotation(_:)), to: menu).state = rotates ? .on : .off
        add("每半小时自动同步", #selector(toggleAutomaticSync(_:)), to: menu).state = automaticSyncEnabled ? .on : .off
        add("同步到备忘录", #selector(toggleNotes(_:)), to: menu).state = notesEnabled ? .on : .off
        reauthItem = add("重新授权", #selector(authorize), to: menu)
        add("打开钉钉待办同步文件夹", #selector(openNotes), to: menu)
        busy(false)
        configureAutomaticSync()
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
        syncItem.isEnabled = authorized && !value
        authItem.isHidden = authorized
        reauthItem.isHidden = !authorized
        reauthItem.isEnabled = !value
        cancelItem.isHidden = !value
        authItem.isEnabled = !value
        cancelItem.isEnabled = value
    }

    @objc private func rotate() {
        guard rotates else { return }
        if !titles.isEmpty {
            cursor = (cursor + 1) % titles.count
        }
        updateLabel()
    }

    private func updateLabel() {
        guard let item = statusItem else { return }
        guard let button = item.button else { return }
        guard rotates, !titles.isEmpty else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "远控分辨率 · " + stateItem.title
            return
        }
        let full = titles[cursor]
        let title = shortened(previewLine(full), width: rotationTextWidth, font: button.font ?? NSFont.menuBarFont(ofSize: 0))
        item.length = ceil(rotationTextWidth) + (button.image?.size.width ?? 0) + 18
        button.title = " " + title
        button.imagePosition = .imageLeading
        button.toolTip = full + "\n" + stateItem.title
    }

    private func previewLine(_ title: String) -> String {
        let lines = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: { $0.isNewline })
        guard let first = lines.first else { return "" }
        let line = first.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return lines.count > 1 ? line + "…" : line
    }

    private func shortened(_ title: String, width: CGFloat, font: NSFont) -> String {
        func fits(_ text: String) -> Bool {
            (text as NSString).size(withAttributes: [.font: font]).width <= width
        }
        guard !fits(title) else { return title }
        var prefix = ""
        for character in title {
            let candidate = prefix + String(character)
            guard fits(candidate + "…") else { break }
            prefix = candidate
        }
        return prefix + "…"
    }

    private func textWidth(_ text: String) -> CGFloat {
        let font = statusItem?.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        return (text as NSString).size(withAttributes: [.font: font]).width
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
        configureAutomaticSync(immediate: true)
    }

    private func rebuildList() {
        listItem.title = "待办列表（\(titles.count)）"
        listMenu.removeAllItems()
        for title in titles.isEmpty ? [hasSnapshot ? "暂无未完成待办" : "尚未读取待办"] : titles {
            let line = previewLine(title)
            let preview = shortened(line, width: 300, font: listMenu.font ?? NSFont.menuFont(ofSize: 0))
            let row = listMenu.addItem(withTitle: preview, action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.toolTip = preview == title ? nil : title
        }
    }

    private func configureAutomaticSync(immediate: Bool = false, afterAttempt: Bool = false) {
        automaticSyncTimer?.invalidate()
        automaticSyncTimer = nil
        let last = defaults.object(forKey: "TodoLastSuccess") as? Date
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let previous = last.map { "上次成功 " + clock.string(from: $0) } ?? "尚无成功记录"
        scheduleItem.title = previous + (automaticSyncEnabled ? " · 等待授权" : " · 自动同步已关闭")
        guard !stopped, automaticSyncEnabled, authorized else { return }
        let now = Date()
        let next = immediate ? now : (afterAttempt ? now.addingTimeInterval(1800) : max(now, last?.addingTimeInterval(1800) ?? now))
        scheduleItem.title = previous + " · 下次 " + clock.string(from: next)
        let timer = Timer(fireAt: next, interval: 0, target: self, selector: #selector(automaticSync), userInfo: nil, repeats: false)
        automaticSyncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func automaticSync() {
        guard automaticSyncEnabled, operation == nil else { return }
        sync()
    }

    @objc private func openAutomation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAuthorization() {
        if let authorizationURL { NSWorkspace.shared.open(authorizationURL) }
    }
    @objc private func authorize() {
        guard operation == nil else { return }
        busy(true)
        stateItem.title = "正在申请授权…"
        operation = Task {
            defer { operation = nil; busy(false); configureAutomaticSync(); updateLabel() }
            do {
                let auth = try await client.beginAuthorization()
                authorizationURL = auth.verificationURL
                linkItem.isHidden = false
                stateItem.title = "等待钉钉授权：" + auth.userCode
                openAuthorization()
                try await client.finishAuthorization(auth)
                authorized = true
                stateItem.title = "授权成功"
            } catch is CancellationError { stateItem.title = "授权已取消" }
            catch { stateItem.title = error.localizedDescription }
            authorizationURL = nil
            linkItem.isHidden = true
        }
    }
    @objc private func sync() {
        guard operation == nil else { return }
        busy(true)
        stateItem.toolTip = nil
        let writeNotes = notesEnabled
        stateItem.title = "正在读取待办…"
        operation = Task {
            defer { operation = nil; busy(false); configureAutomaticSync(afterAttempt: true); updateLabel() }
            do {
                let snapshot = try await client.readTodos()
                try Task.checkCancellation()
                titles = snapshot.titles
                cursor = 0
                hasSnapshot = true
                rotationTextWidth = min(136, titles.map { textWidth(previewLine($0)) }.max() ?? 0)
                rebuildList()
                updateLabel()
                if writeNotes {
                    stateItem.title = "已读取 \(titles.count) 条，正在写入备忘录…"
                    do {
                        stateItem.title = try await writeToNotes(snapshot)
                        permissionItem.isHidden = true
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        stateItem.title = "已读取 \(titles.count) 条 · 备忘录写入失败"
                        stateItem.toolTip = error.localizedDescription
                        return
                    }
                } else { stateItem.title = "已读取 \(titles.count) 条待办（未写入备忘录）" }
                defaults.set(Date(), forKey: "TodoLastSuccess")
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
        permissionItem.isHidden = status != 77
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
    @objc public func stop() { stopped = true; rotation?.invalidate(); automaticSyncTimer?.invalidate(); cancel() }
}
