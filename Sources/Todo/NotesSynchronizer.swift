import AppKit
import Carbon

struct NotesSyncResult {
    let created: Int
    let updated: Int
    let removed: Int
    let synchronized: Int
}

/// 只维护带任务标识的同步笔记，保留文件夹中无法确认来源的笔记。
@MainActor
struct NotesSynchronizer {
    static let folderName = "钉钉待办同步"

    func synchronize(_ snapshot: TodoSnapshot) async throws -> NotesSyncResult {
        let entries = NSAppleEventDescriptor.list()
        var ids = Set<String>()
        for (index, card) in snapshot.cards.enumerated() {
            guard let id = card["taskId"] as? String, !id.isEmpty,
                  let title = card["subject"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(id).inserted else {
                throw DingTalkError(message: "待办缺少有效任务 ID、标题或存在重复任务，未写入备忘录。")
            }
            let marker = Self.marker(id)
            let entry = NSAppleEventDescriptor.list()
            entry.insert(NSAppleEventDescriptor(string: title.components(separatedBy: .newlines).first ?? title), at: 1)
            entry.insert(NSAppleEventDescriptor(string: marker), at: 2)
            entry.insert(NSAppleEventDescriptor(string: Self.body(title: title, marker: marker)), at: 3)
            entries.insert(entry, at: index + 1)
        }
        // AppleScript 隐式启动 Notes 时可能将其带到前台，先显式后台启动。
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
                throw DingTalkError(message: "未找到 macOS 备忘录应用。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        try Task.checkCancellation()
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: Self.folderName), at: 1)
        arguments.insert(entries, at: 2)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "synctodos"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        guard let script = NSAppleScript(source: Self.script) else { throw DingTalkError(message: "无法初始化备忘录同步脚本。") }
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw DingTalkError(message: "待办已读取，但未获准访问备忘录。请在系统设置 → 隐私与安全性 → 自动化中允许 OPPO 远控分辨率助手控制备忘录后重试。")
            }
            throw DingTalkError(message: "待办已读取，但备忘录写入失败（\(code)）。请确认备忘录已配置可写账号后重试。")
        }
        guard result.numberOfItems == 4,
              Int(result.atIndex(4)?.int32Value ?? -1) == snapshot.cards.count else {
            throw DingTalkError(message: "备忘录写入后的数量核验失败，请重新同步。")
        }
        return NotesSyncResult(created: Int(result.atIndex(1)!.int32Value), updated: Int(result.atIndex(2)!.int32Value),
                               removed: Int(result.atIndex(3)!.int32Value), synchronized: snapshot.cards.count)
    }

    static func marker(_ taskID: String) -> String { "DingTodoBar-Task-ID:" + taskID + ":END" }

    static func body(title: String, marker: String) -> String {
        let lines = title.components(separatedBy: .newlines)
        let heading = "<h1>" + escape(lines.first ?? title) + "</h1>"
        let details = lines.dropFirst().map { "<div>" + escape($0) + "</div>" }.joined()
        return heading + details + "<div>同步来源：钉钉待办</div><div>" + escape(marker) + "</div>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let script = #"""
    on syncTodos(folderName, taskEntries)
        tell application "Notes"
            set targetAccount to default account
            if not (exists folder folderName of targetAccount) then
                set targetFolder to make new folder at targetAccount with properties {name:folderName}
            else
                set targetFolder to folder folderName of targetAccount
            end if
            set createdCount to 0
            set updatedCount to 0
            set taskMarkers to {}
            repeat with taskEntry in taskEntries
                set taskTitle to item 1 of taskEntry as text
                set taskMarker to item 2 of taskEntry as text
                set taskBody to item 3 of taskEntry as text
                set end of taskMarkers to taskMarker
                set matchingNotes to every note of targetFolder whose body contains taskMarker
                if (count of matchingNotes) > 1 then error "Duplicate managed note" number 901
                if (count of matchingNotes) is 1 then
                    set targetNote to item 1 of matchingNotes
                    if (name of targetNote) is not taskTitle then
                        set body of targetNote to taskBody
                        set updatedCount to updatedCount + 1
                    end if
                else
                    -- 首次迁移可复用同名旧笔记，保留原文并追加同步标识。
                    set titleMatches to every note of targetFolder whose name is taskTitle
                    set targetNote to missing value
                    repeat with candidate in titleMatches
                        if (body of candidate) does not contain "DingTodoBar-Task-ID:" then
                            set targetNote to contents of candidate
                            exit repeat
                        end if
                    end repeat
                    if targetNote is missing value then
                        make new note at targetFolder with properties {body:taskBody}
                        set createdCount to createdCount + 1
                    else
                        set body of targetNote to (body of targetNote) & "<div>" & taskMarker & "</div>"
                        set updatedCount to updatedCount + 1
                    end if
                end if
            end repeat
            -- 仅清理本程序标记且已不在未完成列表中的笔记。
            set removedCount to 0
            set existingNotes to every note of targetFolder
            repeat with existingNote in existingNotes
                set existingBody to body of existingNote
                if existingBody contains "DingTodoBar-Task-ID:" then
                    set keepNote to false
                    repeat with taskMarker in taskMarkers
                        if existingBody contains (taskMarker as text) then set keepNote to true
                    end repeat
                    if not keepNote then
                        delete existingNote
                        set removedCount to removedCount + 1
                    end if
                end if
            end repeat
            set verifiedCount to 0
            repeat with taskMarker in taskMarkers
                set matches to every note of targetFolder whose body contains (taskMarker as text)
                if (count of matches) is not 1 then error "Notes verification failed" number 902
                set verifiedCount to verifiedCount + 1
            end repeat
        end tell
        return {createdCount, updatedCount, removedCount, verifiedCount}
    end syncTodos
    """#
}
