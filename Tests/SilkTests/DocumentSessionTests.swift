import Foundation
import Testing
@testable import Silk

@Suite struct DocumentSessionTests {
    @Test func 保存失败时报错_磁盘和记录都不变() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.makeReadOnly()

        let result = session.save("我的修改")
        guard case .failed = result else {
            Issue.record("应该保存失败，实际是 \(result)")
            return
        }
        #expect(session.diskText == "原文")
        #expect(dir.read("a.md") == "原文")
    }

    @Test func 磁盘被外部改过时自动保存不覆盖() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")  // 还没收到 FSEvents 通知

        #expect(session.save("我的修改") == .conflict(.modified("AI 改的")))
        #expect(dir.read("a.md") == "AI 改的")
        // 冲突没处理之前，再怎么自动保存都不写。
        #expect(session.save("我的修改 2") == .conflict(.modified("AI 改的")))
        #expect(dir.read("a.md") == "AI 改的")
    }

    @Test func 收到外部修改通知后_有未保存修改就记成冲突() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")

        #expect(session.diskDidChange(editorText: "我的修改", isDirty: true) == .conflict(.modified("AI 改的")))
        #expect(session.save("我的修改") == .conflict(.modified("AI 改的")))
        #expect(dir.read("a.md") == "AI 改的")
    }

    @Test func 用户选保留我的修改才覆盖磁盘() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")
        _ = session.save("我的修改")

        #expect(session.overwrite(with: "我的修改") == .saved)
        #expect(dir.read("a.md") == "我的修改")
        #expect(session.conflict == nil)
    }

    @Test func 用户选载入磁盘版本() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")
        _ = session.save("我的修改")

        #expect(session.takeDiskVersion() == "AI 改的")
        #expect(session.conflict == nil)
        #expect(session.save("在新版本上接着改") == .saved)
    }

    @Test func 文件被删后保存报冲突() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        try FileManager.default.removeItem(at: url)

        #expect(session.save("我的修改") == .conflict(.deleted))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func 没有未保存修改时直接载入外部修改() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")

        #expect(session.diskDidChange(editorText: "原文", isDirty: false) == .reloaded("AI 改的"))
        #expect(session.diskText == "AI 改的")
    }

    @Test func 自己保存触发的文件通知不算外部修改() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        #expect(session.save("我的修改") == .saved)
        #expect(session.diskDidChange(editorText: "我的修改", isDirty: false) == .none)
    }

    @Test func 磁盘文件读不出来时不保存() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "原文")
        let session = try DocumentSession(url: url)
        dir.write("a.md", "AI 改的")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let result = session.save("我的修改")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        guard case .failed = result else {
            Issue.record("读不出来时不能保存，实际是 \(result)")
            return
        }
        #expect(dir.read("a.md") == "AI 改的")
        // 能读了以后，会发现磁盘被改过，报冲突而不是覆盖。
        #expect(session.save("我的修改") == .conflict(.modified("AI 改的")))
        #expect(dir.read("a.md") == "AI 改的")
    }
}
