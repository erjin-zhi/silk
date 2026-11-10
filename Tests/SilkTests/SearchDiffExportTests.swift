import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Silk

/// 文件夹搜索、与磁盘版本比较、导出 HTML 的纯逻辑部分。
@Suite struct FolderSearchTests {
    @Test func findsMatchesAcrossFilesWithLineNumbers() {
        let dir = TempDir()
        let a = dir.write("a.md", "# 标题\n\n第一处丝绸\n没有\n又一处丝绸。")
        let b = dir.write("sub/b.md", "SILK and silk")
        dir.write("c.md", "无关")
        let result = FolderSearch.search("丝绸", in: [a, b, dir.url.appending(path: "c.md")])
        #expect(result.fileCount == 1)
        #expect(result.matches.map(\.line) == [2, 4])
        #expect(result.matches[0].snippet == "第一处丝绸")
        #expect((result.matches[0].snippet as NSString).substring(with: result.matches[0].highlight) == "丝绸")

        // 不分大小写；range 指向全文里的位置。
        let latin = FolderSearch.search("silk", in: [b])
        #expect(latin.matches.count == 2)
        #expect(latin.matches.map(\.range.location) == [0, 9])
    }

    @Test func longLinesKeepTheMatchVisible() {
        let line = String(repeating: "很长的一句话", count: 30) + "关键词" + "结尾"
        let match = FolderSearch.matches(of: "关键词", in: "  " + line, url: URL(fileURLWithPath: "/x.md"))[0]
        #expect(match.snippet.hasPrefix("…"))
        #expect((match.snippet as NSString).substring(with: match.highlight) == "关键词")
    }

    @Test func stopsAtTheLimit() {
        let dir = TempDir()
        let file = dir.write("a.md", String(repeating: "x\n", count: 50))
        let result = FolderSearch.search("x", in: [file], limit: 10)
        #expect(result.matches.count == 10)
        #expect(result.truncated)
    }

    @Test func perFileCapIsReportedAsTruncated() {
        let dir = TempDir()
        let a = dir.write("a.md", String(repeating: "x\n", count: 5))
        let b = dir.write("b.md", "x")
        let result = FolderSearch.search("x", in: [a, b], limit: 100, perFile: 3)
        #expect(result.matches.count == 4)
        #expect(result.fileCount == 2)
        #expect(result.truncated)
    }

    @Test func exactlyAtTheLimitIsNotTruncated() {
        let dir = TempDir()
        let a = dir.write("a.md", String(repeating: "x\n", count: 10))
        let b = dir.write("b.md", "无关")
        let result = FolderSearch.search("x", in: [a, b], limit: 10)
        #expect(result.matches.count == 10)
        #expect(!result.truncated)
    }

    @Test func emptyQueryFindsNothing() {
        let dir = TempDir()
        let file = dir.write("a.md", "abc")
        #expect(FolderSearch.search("", in: [file]).matches.isEmpty)
    }
}

@Suite struct LineDiffTests {
    @Test func marksRemovedAndAddedLinesWithNumbers() {
        let lines = LineDiff.lines(old: "a\nb\nc\nd", new: "a\nB\nc\nd\ne")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .same, .added])
        #expect(lines[1] == LineDiff.Line(kind: .removed, text: "b", old: 2, new: nil))
        #expect(lines[2] == LineDiff.Line(kind: .added, text: "B", old: nil, new: 2))
        #expect(lines.last == LineDiff.Line(kind: .added, text: "e", old: nil, new: 5))
        #expect(LineDiff.stats(lines) == (2, 1))
    }

    @Test func lineEndingsAloneAreNotDifferences() {
        let lines = LineDiff.lines(old: "a\r\nb\r\nc", new: "a\nb\nc")
        #expect(lines.count == 3)
        #expect(LineDiff.hunks(lines).isEmpty)
    }

    @Test func hunksKeepOnlyContextAroundChanges() {
        let old = (1...30).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n5\n", with: "\nfive\n").replacingOccurrences(of: "\n25\n", with: "\n")
        let hunks = LineDiff.hunks(LineDiff.lines(old: old, new: new), context: 2)
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.first?.old == 3)
        #expect(hunks[1].lines.contains { $0.kind == .removed && $0.text == "25" })
    }
}

@Suite struct HTMLExportTests {
    @Test func systemColorsBecomeConcreteLightColors() {
        let css = """
        :root { --text: -apple-system-label; --bg: -apple-system-text-background; }
        body { font: 16px -apple-system, sans-serif; }
        @media (prefers-color-scheme: dark) {
          .a { color: #fff; }
          .b { color: #eee; }
        }
        .c { color: -apple-system-red; }
        """
        let out = HTMLExport.lightStylesheet(css)
        #expect(!out.contains("-apple-system-"))
        #expect(out.contains("-apple-system, sans-serif"))  // 字体名不动
        #expect(out.contains("--sys-text-background: #ffffff"))
        #expect(out.contains("color: var(--sys-red)"))
        #expect(!out.contains("prefers-color-scheme"))
        #expect(!out.contains("#eee"))
    }

    @Test func localImagesAreEmbedded() throws {
        let dir = TempDir()
        let image = dir.write("图 1.png", bytes: [0x89, 0x50, 0x4E, 0x47])
        var components = URLComponents()
        components.scheme = "silk-file"
        components.host = ""
        components.path = image.path
        let html = "<p><img src=\"\(components.url!.absoluteString)\" alt=\"x\"><img src=\"https://example.com/a.png\"></p>"
        let out = HTMLExport.embedLocalFiles(in: html)
        #expect(out.contains("src=\"data:image/png;base64,iVBORw==\""))
        #expect(out.contains("https://example.com/a.png"))
        #expect(!out.contains("silk-file:"))
    }

    @Test func localLinksBecomeRelativeToTheExportedFile() {
        let dir = TempDir()
        let doc = dir.write("notes/其他 文章.md", "x")
        var components = URLComponents()
        components.scheme = "silk-file"
        components.host = ""
        components.path = doc.path
        components.fragment = "小节"
        let html = "<a href=\"\(components.url!.absoluteString)\">x</a>"
        let out = HTMLExport.embedLocalFiles(in: html, destination: dir.url.appending(path: "export/a.html"))
        #expect(out.contains("href=\"../notes/%E5%85%B6%E4%BB%96%20%E6%96%87%E7%AB%A0.md#%E5%B0%8F%E8%8A%82\""))
        // 不给导出位置（打印、PDF）就用绝对地址。
        #expect(HTMLExport.embedLocalFiles(in: html).contains("href=\"file:///"))
    }

    @Test func exportedDocumentDoesNotRunScripts() {
        let doc = HTMLExport.document(HTMLExport.Body(html: "<p>x</p>", title: "", math: false), fallbackTitle: "x")
        #expect(doc.contains("Content-Security-Policy"))
        #expect(doc.contains("script-src 'none'"))
    }

    @Test func documentHasTitleAndStyles() {
        let body = HTMLExport.Body(html: "<h1>你好 & 再见</h1>", title: "你好 & 再见", math: false)
        let doc = HTMLExport.document(body, fallbackTitle: "文件")
        #expect(doc.contains("<title>你好 &amp; 再见</title>"))
        #expect(doc.contains("<h1>你好 & 再见</h1>"))
        #expect(doc.contains("color-scheme: light"))
        #expect(!doc.contains("KaTeX_"))
        let untitled = HTMLExport.document(HTMLExport.Body(html: "<p>x</p>", title: "", math: true), fallbackTitle: "文件")
        #expect(untitled.contains("<title>文件</title>"))
        #expect(untitled.contains("data:font/woff2;base64,"))
    }
}

@Suite struct DefaultAppTests {
    @Test func defaultAppTypesOnlyCoverMdAndMarkdown() {
        let types = MarkdownFiles.defaultAppTypes
        let expected = Set(["md", "markdown"].compactMap { UTType(filenameExtension: $0) }.filter { !$0.isDynamic })
        #expect(Set(types) == expected)
        #expect(types.contains { $0.identifier == "net.daringfireball.markdown" })
        #expect(!types.contains { $0.isDynamic })
        #expect(Set(types).count == types.count)
    }
}

@MainActor
@Suite struct PrintRendererTests {
    /// 带打印面板打印时，系统在后台线程回调打印结束；不能因为不在主线程就崩溃，结果要回到主线程。
    @Test func finishCallbackFromBackgroundThreadComesBackOnMain() async {
        let renderer = PrintRenderer()
        let operation = NSPrintOperation(view: NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            renderer.finished = { ok in
                #expect(ok)
                #expect(Thread.isMainThread)
                done.resume()
            }
            Thread.detachNewThread {
                renderer.printOperationDidRun(operation, success: true, contextInfo: nil)
            }
        }
        #expect(renderer.finished == nil)
    }
}


@MainActor
@Suite struct CompareWithDiskTests {
    /// 打开差异对照时窗口会失去焦点；这时的自动保存不能把磁盘原文换成编辑器内容。
    @Test func openingTheDiffDoesNotOverwriteTheDisk() throws {
        let dir = TempDir()
        let file = dir.write("a.md", "原文")
        let controller = WorkspaceWindowController(root: dir.url, initialFile: file)
        defer { controller.window?.close() }
        let textView = try #require(controller.docView.view.firstSubview(of: EditorView.self)).textView
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        if textView.shouldChangeText(in: end, replacementString: "，我的修改") {
            textView.replaceCharacters(in: end, with: "，我的修改")
            textView.didChangeText()
        }
        #expect(controller.docView.isDirty)

        controller.compareWithDisk(nil)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        controller.saveIfNeeded()  // App 进后台
        #expect(dir.read("a.md") == "原文")

        // 退出时也不能替用户存。
        var answer: Bool?
        controller.confirmClosing { answer = $0 }
        #expect(answer == false)
        #expect(dir.read("a.md") == "原文")

        // 看完选「存储我的修改」才写盘，之后自动保存恢复。
        let sheet = try #require(controller.contentViewController?.presentedViewControllers?.first as? DiffSheet)
        let keep = try #require(sheet.view.firstSubview(of: NSButton.self) { $0.title == "存储我的修改" })
        keep.performClick(nil)
        #expect(dir.read("a.md") == "原文，我的修改")
        #expect(!controller.docView.isComparing)
    }

    /// 对照开着时从 Finder 打开同一文件夹里的另一份文件：不换文档，旧表单的选择也落不到别的文件上。
    @Test func staleDiffCannotTouchAnotherFile() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "另一份")
        let controller = WorkspaceWindowController(root: dir.url, initialFile: a)
        defer { controller.window?.close() }
        let textView = try #require(controller.docView.view.firstSubview(of: EditorView.self)).textView
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        if textView.shouldChangeText(in: end, replacementString: "，我的修改") {
            textView.replaceCharacters(in: end, with: "，我的修改")
            textView.didChangeText()
        }
        controller.compareWithDisk(nil)

        var opened: Bool?
        controller.docView.open(b) { opened = $0 }
        #expect(opened == false)
        #expect(controller.docView.fileURL?.path == a.path)
        #expect(dir.read("a.md") == "原文")

        // 表单上的选择只落在 a 上，b 不受影响。
        let sheet = try #require(controller.contentViewController?.presentedViewControllers?.first as? DiffSheet)
        try #require(sheet.view.firstSubview(of: NSButton.self) { $0.title == "存储我的修改" }).performClick(nil)
        #expect(dir.read("a.md") == "原文，我的修改")
        #expect(dir.read("b.md") == "另一份")

        // 表单关了，照常能换文档。
        controller.openFile(b)
        #expect(controller.docView.fileURL?.path == b.path)
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type, where match: (T) -> Bool = { _ in true }) -> T? {
        if let view = self as? T, match(view) { return view }
        for sub in subviews { if let found = sub.firstSubview(of: type, where: match) { return found } }
        return nil
    }
}
