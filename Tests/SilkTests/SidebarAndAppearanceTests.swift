import AppKit
import Testing
import WebKit
@testable import Silk

@MainActor
@Suite(.serialized) struct SidebarAndAppearanceTests {
    @Test func 修改时间的显示() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15, minute: 0))!
        func label(_ c: DateComponents) -> String {
            SidebarViewController.timeLabel(for: calendar.date(from: c)!, now: now, calendar: calendar)
        }
        #expect(SidebarViewController.timeLabel(for: now.addingTimeInterval(-20), now: now, calendar: calendar) == "刚刚")
        #expect(SidebarViewController.timeLabel(for: now.addingTimeInterval(-5 * 60), now: now, calendar: calendar) == "5 分钟前")
        #expect(label(DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 5)).contains("09:05") || label(DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 5)).contains("9:05"))
        #expect(label(DateComponents(year: 2026, month: 11, day: 1, hour: 23)) == "昨天")
        #expect(label(DateComponents(year: 2026, month: 10, day: 28, hour: 8)) == "10月28日")
        #expect(label(DateComponents(year: 2025, month: 3, day: 4, hour: 8)) == "2025/3/4")
    }

    @Test func 系统在浅色和深色之间切换时_预览顶部的底色跟着变() {
        let web = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        func brightness() -> CGFloat { web.underPageBackgroundColor.usingColorSpace(.sRGB)!.brightnessComponent }
        web.appearance = NSAppearance(named: .aqua)
        web.applyBackground()
        let light = brightness()
        web.appearance = NSAppearance(named: .darkAqua)
        web.viewDidChangeEffectiveAppearance()
        let dark = brightness()
        #expect(light > 0.8)
        #expect(dark < 0.3)
    }

    @Test func 侧栏文件行显示修改时间() throws {
        let dir = TempDir()
        let file = dir.write("notes/plan.md", "# 计划")
        let old = Date().addingTimeInterval(-3 * 86400 * 30)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        let window = WorkspaceWindowController(root: dir.url.appending(path: "notes"), initialFile: file)
        window.window?.layoutIfNeeded()
        let sidebar = try #require(window.contentViewController?.children.first as? SidebarViewController)
        sidebar.setTree(FileNode.scan(dir.url.appending(path: "notes")), scanned: true)
        func outline(_ v: NSView) -> NSOutlineView? { if let o = v as? NSOutlineView { return o }; for s in v.subviews { if let f = outline(s) { return f } }; return nil }
        let table = try #require(outline(sidebar.view))
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let texts = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("plan"))
        #expect(texts.contains(SidebarViewController.timeLabel(for: old)))
        window.window?.close()
    }

    @Test func 侧栏的新建_从文件夹窗口新建的草稿默认存回那个文件夹() throws {
        let dir = TempDir()
        dir.write("notes/a.md", "# A")
        let suite = "silk-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let app = AppDelegate(defaults: UserDefaults(suiteName: suite)!, drafts: DraftStore(directory: dir.url.appending(path: "Drafts")))
        let notes = dir.url.appending(path: "notes")
        app.open(notes)
        let folder = try #require(app.windows.first { !$0.isDraft })
        let sidebar = try #require(folder.contentViewController?.children.first as? SidebarViewController)
        func button(_ v: NSView) -> NSButton? { if let b = v as? NSButton, b.title == "新建" { return b }; for s in v.subviews { if let f = button(s) { return f } }; return nil }
        try #require(button(sidebar.view)).performClick(nil)

        let draft = try #require(app.windows.first { $0.isDraft })
        #expect(draft.saveDirectory?.standardizedFileURL.path == notes.standardizedFileURL.path)
        app.windows.forEach { $0.window?.close() }
    }
}
