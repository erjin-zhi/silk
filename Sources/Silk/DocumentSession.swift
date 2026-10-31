import Foundation

/// 打开的文档和磁盘之间的关系：什么时候能放心自动保存，什么时候磁盘被别人改了、要用户拿主意。
/// 不碰界面，界面层（DocumentViewController）根据返回结果弹提示。
final class DocumentSession {
    enum Conflict: Equatable {
        /// 磁盘上的文件被别的程序改了，附带磁盘上现在的内容。
        case modified(String)
        /// 磁盘上的文件被删除或移走了。
        case deleted
    }

    enum SaveResult: Equatable {
        case saved
        case unchanged
        case conflict(Conflict)
        case failed(String)

        var isDone: Bool { self == .saved || self == .unchanged }
    }

    enum DiskChange: Equatable {
        case none
        /// 这边没有未保存的修改，已经换成磁盘上的新内容。
        case reloaded(String)
        case conflict(Conflict)
    }

    let url: URL
    private(set) var format: TextFile
    /// 磁盘上最近一次确认过的内容：读进来的，或者我们自己写进去的。
    private(set) var diskText: String
    /// 还没被用户处理的冲突。有冲突时自动保存一律不写盘。
    private(set) var conflict: Conflict?

    init(url: URL) throws {
        self.url = url
        format = try TextFile.read(url)
        diskText = format.text
    }

    var text: String { diskText }

    /// 自动保存、切换文件前的保存。磁盘被别人改过或删了就不写，报冲突。
    func save(_ text: String) -> SaveResult {
        if let conflict { return .conflict(conflict) }
        guard text != diskText else { return .unchanged }
        // 写之前再看一眼磁盘：FSEvents 有延迟，不能只靠它通知。
        switch checkDisk() {
        case .same:
            return write(text)
        case .changed(let conflict):
            self.conflict = conflict
            return .conflict(conflict)
        case .unreadable(let message):
            // 文件在但读不出来（没有读权限、iCloud 还没下载下来……）：看不到磁盘上是什么，就不能放心覆盖。
            return .failed("读不到磁盘上的文件，为了不覆盖别人的修改，先不存储（\(message)）")
        }
    }

    /// 用户明确选了「保留我的修改」：覆盖磁盘上的版本。
    func overwrite(with text: String) -> SaveResult {
        let result = write(text)
        if result == .saved { conflict = nil }
        return result
    }

    /// 用户选了「载入磁盘版本」。文件读不到时返回 nil，冲突保留。
    func takeDiskVersion() -> String? {
        guard let disk = try? TextFile.read(url) else { return nil }
        format = disk
        diskText = disk.text
        conflict = nil
        return disk.text
    }

    /// 用户选了「放弃我的修改」：冲突作废，返回编辑器该显示的内容。
    /// 磁盘读得到就用磁盘上现在的版本；读不到（被删了、没权限）就退回最近一次确认过的版本。
    func discardChanges() -> String {
        conflict = nil
        if let disk = try? TextFile.read(url) {
            format = disk
            diskText = disk.text
        }
        return diskText
    }

    /// 磁盘上的文件有动静。isDirty：编辑器里有没有没存的修改。
    func diskDidChange(editorText: String, isDirty: Bool) -> DiskChange {
        // 读不到可能是别的程序正在原子替换，等下一次事件；真被删了，保存时会发现。
        guard let disk = try? TextFile.read(url) else { return .none }
        if disk.text == diskText { return .none }  // 我们自己写的，或者内容没变
        if disk.text == editorText {
            // 外面改成了和这边一模一样。
            format = disk
            diskText = disk.text
            conflict = nil
            return .none
        }
        if !isDirty {
            format = disk
            diskText = disk.text
            return .reloaded(disk.text)
        }
        let conflict = Conflict.modified(disk.text)
        self.conflict = conflict
        return .conflict(conflict)
    }

    private enum DiskState {
        case same
        case changed(Conflict)
        case unreadable(String)
    }

    private func checkDisk() -> DiskState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .changed(.deleted) }
        do {
            let disk = try TextFile.read(url)
            return disk.text == diskText ? .same : .changed(.modified(disk.text))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    private func write(_ text: String) -> SaveResult {
        do {
            format = try format.write(text, to: url)
            diskText = text
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
