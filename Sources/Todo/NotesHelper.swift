import AppKit

@main
struct NotesHelper {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--read-check") {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OPPORemoteOptimize/credentials.json")
                let snapshot = try await DingTalkClient(storage: FileTokenStorage(fileURL: url)).readTodos()
                print("MCP 读取成功：\(snapshot.cards.count) 条，\(snapshot.pages) 页；未写入备忘录。")
                return
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cards = object["todoCards"] as? [[String: Any]] else {
                throw DingTalkError(message: "备忘录同步数据无效。")
            }
            let snapshot = TodoSnapshot(cards: cards, pages: object["pages"] as? Int ?? 0, status: "false")
            let result = try await NotesSynchronizer().synchronize(snapshot)
            print("同步完成：\(result.synchronized) 条，新建 \(result.created)、更新 \(result.updated)、移除 \(result.removed) 篇")
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }
}
