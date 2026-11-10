import AppKit
import Testing
@testable import Silk

/// 首次打开是空白草稿；有上次的状态就恢复上次的状态。
@MainActor
@Suite struct DraftAndLaunchTests {
    /// 每个测试独立的偏好设置和草稿目录，不碰真实的。
    @MainActor final class Env {
        let dir = TempDir()
        let defaults: UserDefaults
        let drafts: DraftStore
        let suite = "silk-tests-\(UUID().uuidString)"

        init() {
            defaults = UserDefaults(suiteName: suite)!
            drafts = DraftStore(directory: dir.url.appending(path: "Drafts"))
        }

        func app() -> AppDelegate { AppDelegate(defaults: defaults, drafts: drafts) }

        isolated deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func type(_ text: String, into window: WorkspaceWindowController) {
        func find(_ v: NSView) -> EditorView? { if let e = v as? EditorView { return e }; for s in v.subviews { if let f = find(s) { return f } }; return nil }
        let textView = find(window.docView.view)!.textView
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        if textView.shouldChangeText(in: end, replacementString: text) {
            textView.replaceCharacters(in: end, with: text)
            textView.didChangeText()
        }
    }

    private func closeAll(_ app: AppDelegate) {
        for window in app.windows { window.window?.close() }
    }

    @Test func 首次打开是一份空白草稿_不弹打开面板() {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()

        #expect(app.windows.count == 1)
        let draft = app.windows[0]
        #expect(draft.isDraft)
        #expect(draft.docView.text.isEmpty)
        #expect(draft.docView.mode != .read)  // 能直接写
        #expect(draft.window?.title == "未命名")
        #expect(env.drafts.all().count == 1)
        closeAll(app)
    }

    /// 窗口位置、侧栏的记忆由系统按 autosave 名字存在全局偏好里，测试进程里别的测试的窗口也在写，
    /// 这里只测确定的部分：放到屏幕正中的算法、没选过模式时的默认模式。
    @Test func 第一次打开的窗口放在屏幕可用区域的正中() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        WorkspaceWindowController.centerOnScreen(window)
        let area = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        #expect(abs(window.frame.midX - area.midX) <= 1)
        #expect(abs(window.frame.midY - area.midY) <= 1)
    }

    @Test func 屏幕放不下默认大小时_缩到可用区域里再居中() throws {
        let area = try #require(NSScreen.main?.visibleFrame)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: area.width * 2, height: area.height * 2), styleMask: [.titled], backing: .buffered, defer: true)
        WorkspaceWindowController.centerOnScreen(window)
        #expect(window.frame.width <= area.width && window.frame.height <= area.height)
        #expect(abs(window.frame.midX - area.midX) <= 1)
    }

    @Test func 没选过模式时默认是对照模式() {
        let saved = UserDefaults.standard.string(forKey: "viewMode")
        UserDefaults.standard.removeObject(forKey: "viewMode")
        defer { UserDefaults.standard.set(saved, forKey: "viewMode") }
        #expect(DocumentViewController().mode == .split)
    }

    @Test func 有上次的状态就恢复上次打开的文件夹和文件_不开草稿() {
        let env = Env()
        env.dir.write("notes/a.md", "# A")
        let b = env.dir.write("notes/b.md", "# B")
        let single = env.dir.write("other/x.md", "# X")
        env.defaults.set([
            ["root": env.dir.url.appending(path: "notes").path, "file": b.path],
            ["root": single.deletingLastPathComponent().path, "file": single.path],
        ], forKey: AppDelegate.stateKey)

        let app = env.app()
        app.restoreLastSession()

        #expect(app.windows.map(\.isDraft) == [false, false])
        #expect(app.windows.map { $0.docView.fileURL?.lastPathComponent } == ["b.md", "x.md"])
        #expect(env.drafts.all().isEmpty)
        closeAll(app)
    }

    @Test func 上次的文件都不在了_就开空白草稿() {
        let env = Env()
        env.defaults.set([["root": "/不存在的目录", "file": "/不存在的目录/a.md"]], forKey: AppDelegate.stateKey)
        let app = env.app()
        app.restoreLastSession()
        #expect(app.windows.count == 1)
        #expect(app.windows[0].isDraft)
        closeAll(app)
    }

    @Test func 上次退出时开着的草稿_内容原样恢复() throws {
        let env = Env()
        let first = env.app()
        first.restoreLastSession()
        type("# 写到一半", into: first.windows[0])
        _ = first.applicationShouldTerminate(NSApplication.shared)  // 退出：存草稿、记状态

        let second = env.app()
        second.restoreLastSession()
        #expect(second.windows.count == 1)
        #expect(second.windows[0].isDraft)
        #expect(second.windows[0].docView.text == "# 写到一半")
        closeAll(first)
        closeAll(second)
    }

    @Test func 退出时窗口被一个个关掉_记下的仍是退出前开着的窗口() {
        let env = Env()
        let notes = env.dir.url.appending(path: "notes")
        let a = env.dir.write("notes/a.md", "# A")
        let first = env.app()
        first.restoreLastSession()
        type("草稿", into: first.windows[0])
        first.open(notes)

        #expect(first.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        closeAll(first)  // AppKit 退出时会这样关窗口

        let second = env.app()
        second.restoreLastSession()
        #expect(second.windows.count == 2)
        #expect(second.windows.contains { $0.isDraft && $0.docView.text == "草稿" })
        // 文件夹窗口：退出时文件夹还没扫完、没选中文件，恢复的是这个文件夹。
        #expect(second.windows.contains { !$0.isDraft && $0.workspace.root.path == notes.standardizedFileURL.path })
        _ = a
        closeAll(second)
    }

    @Test func 状态里没记下的草稿_有内容的也打开_空的删掉() throws {
        let env = Env()
        let kept = try env.drafts.create()
        try "崩溃前写的".write(to: kept, atomically: true, encoding: .utf8)
        let empty = try env.drafts.create()

        let app = env.app()
        app.restoreLastSession()

        #expect(app.windows.count == 1)
        #expect(app.windows[0].docView.text == "崩溃前写的")
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        closeAll(app)
    }

    @Test func 状态里没记下的草稿_暂时读不出来时不清理() throws {
        let env = Env()
        let draft = try env.drafts.create()
        try "仍需保留的草稿".write(to: draft, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: draft.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draft.path) }
        try #require((try? TextFile.read(draft)) == nil)

        let app = env.app()
        defer { closeAll(app) }
        app.restoreLastSession()

        #expect(FileManager.default.fileExists(atPath: draft.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draft.path)
        #expect(try TextFile.read(draft).text == "仍需保留的草稿")
    }

    @Test func 从旧版本升级时用上次打开的路径恢复() {
        let env = Env()
        let a = env.dir.write("old/a.md", "# 旧")
        env.defaults.set(a.path, forKey: "lastOpenedPath")
        let app = env.app()
        app.restoreLastSession()
        #expect(app.windows.first?.docView.fileURL == a)
        #expect(app.windows.first?.isDraft == false)
        closeAll(app)
    }

    @Test func 草稿边写边自动保存_不用切走窗口() async throws {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        let draft = app.windows[0]
        type("# 想法", into: draft)
        try await Task.sleep(for: .milliseconds(1400))
        let saved = try? String(contentsOf: draft.docView.fileURL!, encoding: .utf8)
        #expect(saved == "# 想法")
        closeAll(app)
    }

    @Test func 存储草稿_写到选的位置_草稿删掉_改用普通窗口打开() {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        let draft = app.windows[0]
        let draftFile = draft.docView.fileURL!
        type("# 周报\n\n内容", into: draft)

        let target = env.dir.url.appending(path: "周报.md")
        var suggested: String?
        draft.chooseSaveLocation = { name, done in
            suggested = name
            done(target)
        }
        var saved: Bool?
        draft.saveDraftAs { saved = $0 }

        #expect(saved == true)
        #expect(suggested == "周报.md")
        #expect(env.dir.read("周报.md") == "# 周报\n\n内容")
        let folderGone = !FileManager.default.fileExists(atPath: draftFile.deletingLastPathComponent().path)
        #expect(folderGone)
        #expect(app.windows.count == 1)
        #expect(app.windows[0].isDraft == false)
        #expect(app.windows[0].docView.fileURL == target)
        closeAll(app)
    }

    @Test func 关闭空草稿直接关_草稿删掉() {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        let draft = app.windows[0]
        let file = draft.docView.fileURL!
        var asked = false
        draft.promptForDraft = { _ in asked = true }

        #expect(draft.windowShouldClose(draft.window!))
        draft.window?.close()
        #expect(!asked)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(app.windows.isEmpty)
    }

    @Test func 关闭写了东西的草稿要问_取消就留着_删除才删() {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        let draft = app.windows[0]
        let file = draft.docView.fileURL!
        type("重要的想法", into: draft)

        draft.promptForDraft = { answer in answer(.cancel) }
        #expect(!draft.windowShouldClose(draft.window!))
        #expect(app.windows.count == 1)
        let saved = try? String(contentsOf: file, encoding: .utf8)
        #expect(saved == "重要的想法")

        draft.promptForDraft = { answer in answer(.delete) }
        #expect(!draft.windowShouldClose(draft.window!))  // 回答之后由它自己关
        #expect(app.windows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func 打开文件时_没动过的空草稿顺手关掉_写了东西的保留() throws {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        app.newDraft(nil)
        type("保留我", into: app.windows[1])
        let a = env.dir.write("docs/a.md", "# A")

        app.open(a)

        #expect(app.windows.count == 2)
        #expect(app.windows.contains { $0.isDraft && $0.docView.text == "保留我" })
        #expect(app.windows.contains { !$0.isDraft && $0.docView.fileURL == a })
        #expect(env.drafts.all().count == 1)
        closeAll(app)
    }

    @Test func 别的文件不会开进草稿窗口里() throws {
        let env = Env()
        let app = env.app()
        app.restoreLastSession()
        type("草稿内容", into: app.windows[0])
        app.newDraft(nil)  // 第二份草稿也是自己的窗口
        #expect(app.windows.count == 2)
        #expect(!app.windows.contains { !$0.isDraft })
        #expect(app.windows[1].docView.text.isEmpty)
        closeAll(app)
    }

    @Test func 窗口都关了_点Dock图标开空白草稿() {
        let env = Env()
        let app = env.app()
        _ = app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(app.windows.count == 1)
        #expect(app.windows[0].isDraft)
        closeAll(app)
    }

    @Test(arguments: [
        ("# 周报 2026/11\n内容", "周报 2026 11.md"),
        ("第一行就是正文", "第一行就是正文.md"),
        ("---\ntitle: \"会议: 纪要\"\n---\n\n# 不用这个", "会议 纪要.md"),
        ("---\ntags: [a]\n---\n\n# 用标题", "用标题.md"),
        ("   \n\n", "未命名.md"),
    ])
    func 存储时建议的文件名(_ text: String, _ name: String) {
        #expect(DraftStore.suggestedName(for: text) == name)
    }
}
