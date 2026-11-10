import AppKit
import Testing
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
    @Test func defaultAppTypesIncludeStandardMarkdownAndNoDynamicTypes() {
        let types = MarkdownFiles.defaultAppTypes
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
