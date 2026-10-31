import AppKit
import Testing
@testable import Silk

@MainActor
@Suite struct AppDelegateTests {
    @Test func 打开工作区外的Markdown文件时带上锚点_新开窗口() throws {
        let dir = TempDir()
        let a = dir.write("one/a.md", "见 [另一边](../two/b.md#第二节)")
        let b = dir.write("two/b.md", "## 第二节\n")
        let app = AppDelegate()
        app.open(a)
        app.open(b, fragment: "第二节")

        let window = app.windows.first { $0.workspace.contains(b) }
        #expect(window?.docView.fileURL == b)
        #expect(window?.docView.lastFragment == "第二节")
        app.windows.forEach { $0.window?.close() }
    }

    @Test func 打开已有窗口里的文件时带上锚点() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "#")
        let b = dir.write("b.md", "## 第二节\n")
        let app = AppDelegate()
        app.open(dir.url)
        app.open(a)
        app.open(b, fragment: "第二节")

        #expect(app.windows.count == 1)
        #expect(app.windows.first?.docView.fileURL == b)
        #expect(app.windows.first?.docView.lastFragment == "第二节")
        app.windows.forEach { $0.window?.close() }
    }
}
