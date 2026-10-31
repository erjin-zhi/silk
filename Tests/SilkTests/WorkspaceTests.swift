import Foundation
import Testing
@testable import Silk

@Suite struct WikiLinkTests {
    private func resolve(_ name: String, from current: String?, in dir: TempDir, files: [String]) -> String? {
        let urls = files.map { dir.write($0, "#") }
        let currentURL = current.map { dir.url.appending(path: $0) }
        let found = Workspace.resolveWikiLink(name, from: currentURL, root: dir.url, files: urls)
        return found.map { String($0.standardizedFileURL.path.dropFirst(dir.url.standardizedFileURL.path.count + 1)) }
    }

    @Test func 不会把note匹配到subnote() {
        let dir = TempDir()
        #expect(resolve("note", from: "docs/a.md", in: dir, files: ["docs/subnote.md", "notes/note.md"]) == "notes/note.md")
    }

    @Test func 只有相似名字时找不到() {
        let dir = TempDir()
        #expect(resolve("note", from: nil, in: dir, files: ["subnote.md", "my-note.md"]) == nil)
    }

    @Test func 同名文件优先当前目录() {
        let dir = TempDir()
        #expect(resolve("README", from: "b/x.md", in: dir, files: ["a/README.md", "b/README.md"]) == "b/README.md")
    }

    @Test func 其次选路径短的() {
        let dir = TempDir()
        #expect(resolve("plan", from: "z/x.md", in: dir, files: ["a/b/plan.md", "c/plan.md"]) == "c/plan.md")
    }

    @Test func 支持带文件夹和扩展名的写法_不分大小写() {
        let dir = TempDir()
        let files = ["docs/Plan.md", "other/docs/plan.md", "xdocs/plan.md"]
        #expect(resolve("docs/plan", from: nil, in: dir, files: files) == "docs/Plan.md")
        #expect(resolve("Docs/Plan.md", from: nil, in: dir, files: files) == "docs/Plan.md")
    }
}

@Suite struct FileTreeTests {
    @Test func 依赖目录及其iCloud变体都不进文件树() {
        let dir = TempDir()
        for path in [
            "README.md",
            "docs/guide.md",
            "web/node_modules.nosync/pkg/README.md",
            "web/node_modules 2/pkg/README.md",
            "web/Node_Modules/pkg/README.md",
            "bower_components/x/README.md",
            "py/.venv/lib/README.md",
            "py/site-packages/x/README.md",
        ] {
            dir.write(path, "#")
        }
        let files = FileNode.scan(dir.url).allFiles.map { String($0.url.path.dropFirst(dir.url.path.count + 1)) }
        #expect(Set(files) == ["README.md", "docs/guide.md"])
    }

    @Test func 普通名字不被误伤() {
        #expect(!MarkdownFiles.isSkippedDirectory("modules"))
        #expect(!MarkdownFiles.isSkippedDirectory("node_modules_notes"))
        #expect(!MarkdownFiles.isSkippedDirectory("target 2025"))
        #expect(MarkdownFiles.isSkippedDirectory("target 2"))
    }
}

@Suite struct FileEventPathTests {
    @Test func tmp下的文件能对上FSEvents报的private路径() {
        let dir = TempDir()  // 在 /var/folders 下，真实路径是 /private/var/folders
        let file = dir.write("a.md", "#")
        let real = "/private" + file.path
        #expect(file.path.hasPrefix("/var/"))
        #expect(MarkdownFiles.paths([real], mention: file))
    }

    @Test func 软链接文档能对上目标文件的事件() throws {
        let dir = TempDir()
        let target = dir.write("real.md", "#")
        let link = dir.url.appending(path: "link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(MarkdownFiles.paths(["/private" + target.path], mention: link))
        #expect(!MarkdownFiles.paths(["/private" + dir.url.path + "/other.md"], mention: link))
    }
}
