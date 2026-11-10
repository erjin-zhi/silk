import AppKit
import Testing
@testable import Silk

/// 编辑器收起（阅读模式）时载入的文字，展开后要能显示出来。
/// 以前草稿窗口一打开就从阅读切到对照，编辑器里的字明明在，却显示成一片空白。
/// 测试进程的 UserDefaults.standard 是测试自己的，不是 Silk 的，改 viewMode 不影响平时用的设置。
@MainActor
@Suite(.serialized) struct EditorLayoutTests {
    private func editor(in view: NSView) -> EditorView? {
        if let e = view as? EditorView { return e }
        for sub in view.subviews { if let found = editor(in: sub) { return found } }
        return nil
    }

    /// 编辑器里的字实际排出来的宽度。
    private func laidOutWidth(_ window: WorkspaceWindowController) -> CGFloat {
        window.window?.layoutIfNeeded()
        let textView = editor(in: window.docView.view)!.textView
        let layout = textView.layoutManager!
        layout.ensureLayout(for: textView.textContainer!)
        return layout.usedRect(for: textView.textContainer!).width
    }

    /// 打完字后实际排出来的宽度；highlight 为 false 时关掉语法着色，作为对照。
    private func typedWidth(startingWith initial: String, typing text: String, highlight: Bool = true) -> CGFloat {
        let editor = EditorView(fontSize: 13)
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        editor.setText(initial)
        if !highlight { editor.textView.textStorage?.delegate = nil }
        editor.textView.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
        let layout = editor.textView.layoutManager!
        layout.ensureLayout(for: editor.textView.textContainer!)
        return layout.usedRect(for: editor.textView.textContainer!).width
    }

    @Test(arguments: [("", "你好你好"), ("a", "你好你好"), ("# 标题", " 和正文"), ("", "**粗体** 和 `代码`")])
    func 新打的字和不着色时排得一样宽(_ initial: String, _ text: String) {
        let plain = typedWidth(startingWith: initial, typing: text, highlight: false)
        #expect(plain > 30)
        #expect(abs(typedWidth(startingWith: initial, typing: text) - plain) < 1)
    }

    @Test func 平时用阅读模式时_恢复的草稿里的字能显示出来() throws {
        let dir = TempDir()
        let suite = "silk-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        UserDefaults.standard.set("read", forKey: "viewMode")
        let drafts = DraftStore(directory: dir.url.appending(path: "Drafts"))
        let draft = try drafts.create()
        try "你好你好".write(to: draft, atomically: true, encoding: .utf8)

        let app = AppDelegate(defaults: defaults, drafts: drafts)
        app.restoreLastSession()
        let window = try #require(app.windows.first)
        #expect(window.isDraft)
        #expect(window.docView.text == "你好你好")
        // 4 个汉字的宽度远大于空行的 8 pt。
        #expect(laidOutWidth(window) > 30)
        window.window?.close()
    }

    @Test func 平时用阅读模式时_新草稿里打的字能显示出来() throws {
        let dir = TempDir()
        let suite = "silk-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        UserDefaults.standard.set("read", forKey: "viewMode")
        let app = AppDelegate(defaults: defaults, drafts: DraftStore(directory: dir.url.appending(path: "Drafts")))
        app.restoreLastSession()
        let window = try #require(app.windows.first)
        let textView = editor(in: window.docView.view)!.textView
        textView.insertText("你好你好", replacementRange: textView.selectedRange())
        #expect(window.docView.text == "你好你好")
        #expect(laidOutWidth(window) > 30)
        window.window?.close()
    }
}
