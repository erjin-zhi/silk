import Foundation

/// 每个测试一个临时目录，测完删掉。
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "silk-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // 测试里可能把目录设成了只读，先改回来才删得掉。
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let file = url.appending(path: relative)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    func write(_ relative: String, bytes: [UInt8]) -> URL {
        let file = url.appending(path: relative)
        try! Data(bytes).write(to: file)
        return file
    }

    func read(_ relative: String) -> String {
        try! String(contentsOf: url.appending(path: relative), encoding: .utf8)
    }

    /// 目录设成只读：里面的文件读得到，但原子写入建不了临时文件，保存一定失败。
    func makeReadOnly() {
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }
}
