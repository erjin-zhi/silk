import Foundation

/// 草稿：还没存到自己选的位置的文档。每份草稿是 App 数据目录里的一个真文件，
/// 所以自动保存、冲突处理这些都和普通文件一样，退出后再打开也还在。
///
///   ~/Library/Application Support/Silk/Drafts/<UUID>/未命名.md
struct DraftStore {
    let directory: URL

    static let fileName = "未命名.md"

    static let standard = DraftStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Silk/Drafts", directoryHint: .isDirectory)
    )

    /// 新建一份空草稿，返回文件位置。
    func create() throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: Self.fileName)
        try Data().write(to: file)
        return file
    }

    /// 是不是草稿文件。
    func contains(_ url: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
    }

    /// 删掉一份草稿（连同它的文件夹）。
    func delete(_ url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 现有的草稿文件，旧的在前。
    func all() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .map { $0.appending(path: Self.fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { created($0) < created($1) }
    }

    /// 草稿里有没有写东西（只有空白也算空）。
    static func isEmpty(_ url: URL) -> Bool {
        // 读不出来时保留草稿，不能把暂时的读取失败当成空白并清理掉。
        guard let file = try? TextFile.read(url) else { return false }
        return file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 存储时建议的文件名：文件头里的 title，其次第一个标题，再其次第一行，都没有就叫「未命名」。
    static func suggestedName(for text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        var title: String?
        if lines.first == "---" || lines.first == "+++", let close = lines.dropFirst().firstIndex(of: lines[0]) {
            for line in lines[1..<close] {
                if let m = line.firstMatch(of: /^title\s*[:=]\s*(.+)$/) {
                    title = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
            lines.removeSubrange(0...close)
        }
        let heading = lines.first { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        var name = title ?? heading ?? lines.first ?? ""
        // 去掉文件名里不能用或不好看的字符，连续空白并成一个，太长的截断。
        name = name.replacingOccurrences(of: #"[/:\\\x00-\x1F*?"<>|`]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "未命名" : name) + ".md"
    }

    private func created(_ url: URL) -> Date {
        (try? url.deletingLastPathComponent().resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
