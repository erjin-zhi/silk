import AppKit
import Testing
@testable import Silk

/// 界面层：存不下来时不能把编辑器里的内容换掉。
@MainActor
@Suite struct DocumentViewControllerTests {
    private func makeController() -> DocumentViewController {
        let controller = DocumentViewController()
        _ = controller.view
        return controller
    }

    private func type(_ text: String, into controller: DocumentViewController) {
        // 走 NSTextView 的标准编辑流程（和用户打字一样会通知 delegate）。
        let textView = find(EditorView.self, in: controller.view)!.textView
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        if textView.shouldChangeText(in: end, replacementString: text) {
            textView.replaceCharacters(in: end, with: text)
            textView.didChangeText()
        }
    }

    private func editorText(_ controller: DocumentViewController) -> String {
        find(EditorView.self, in: controller.view)!.textView.string
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    @Test func 保存失败且用户取消时不切换文件_修改还在() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "另一个文件")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        #expect(controller.isDirty)
        dir.makeReadOnly()

        var asked: DocumentSession.SaveResult?
        controller.promptForLeaving = { result, answer in
            asked = result
            answer(.cancel)
        }
        var opened: Bool?
        controller.open(b) { opened = $0 }

        guard case .failed = asked else {
            Issue.record("应该问用户保存失败怎么办，实际是 \(String(describing: asked))")
            return
        }
        #expect(opened == false)
        #expect(controller.fileURL == a)
        #expect(editorText(controller) == "原文，我的修改")
        #expect(controller.isDirty)
    }

    @Test func 保存失败但用户选放弃修改时才切换() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "另一个文件")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        dir.makeReadOnly()

        controller.promptForLeaving = { _, answer in answer(.discard) }
        var opened: Bool?
        controller.open(b) { opened = $0 }

        #expect(opened == true)
        #expect(controller.fileURL == b)
        #expect(dir.read("a.md") == "原文")
    }

    @Test func 有外部修改冲突时自动保存不覆盖磁盘() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        dir.write("a.md", "AI 改的")
        controller.filesDidChange([a.path])  // 弹出冲突提示，用户还没选

        controller.saveIfNeeded()  // 切走窗口、App 进后台时的自动保存

        #expect(dir.read("a.md") == "AI 改的")
        #expect(editorText(controller) == "原文，我的修改")
        #expect(controller.isDirty)
    }

    @Test func 能保存时切换文件照常进行() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "另一个文件")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)

        var asked = false
        controller.promptForLeaving = { _, answer in
            asked = true
            answer(.cancel)
        }
        var opened: Bool?
        controller.open(b) { opened = $0 }

        #expect(!asked)
        #expect(opened == true)
        #expect(dir.read("a.md") == "原文，我的修改")
    }

    @Test func 确认框还没回答时又来一个打开请求_不排第二个框() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "B 原文")
        let c = dir.write("c.md", "C")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        dir.write("a.md", "AI 改了 a")  // 离开 a 时会报冲突

        var answers: [(DocumentViewController.LeaveChoice) -> Void] = []
        controller.promptForLeaving = { _, answer in answers.append(answer) }
        var openedB: Bool?
        var openedC: Bool?
        controller.open(b) { openedB = $0 }
        controller.open(c) { openedC = $0 }

        #expect(answers.count == 1)
        #expect(openedC == false)
        answers[0](.discard)
        #expect(openedB == true)
        #expect(controller.fileURL == b)
        #expect(dir.read("a.md") == "AI 改了 a")
        #expect(dir.read("b.md") == "B 原文")
    }

    @Test func 文档已经换掉时_旧确认框的回答不作用到新文档() throws {
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let b = dir.write("b.md", "B 原文")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        dir.write("a.md", "AI 改了 a")

        var pending: ((DocumentViewController.LeaveChoice) -> Void)?
        controller.promptForLeaving = { _, answer in pending = answer }
        var opened: Bool?
        controller.open(b) { opened = $0 }
        #expect(pending != nil)

        // 框还开着的时候，文档被别的途径换掉了（这里用占位页模拟），然后 b 被外部改了。
        controller.showPlaceholder("换掉了")
        dir.write("b.md", "AI 改了 b")
        pending?(.retry)  // 用户点「用我的修改覆盖」

        #expect(opened == false)
        #expect(dir.read("a.md") == "AI 改了 a")
        #expect(dir.read("b.md") == "AI 改了 b")
        #expect(!controller.leavePromptOpen)
    }

    @Test func 选了放弃修改但离开又被取消时_编辑器回到磁盘版本() throws {
        // 场景：两个窗口一起退出，第一个窗口选「放弃我的修改」，第二个窗口选「取消」，App 没退出。
        let dir = TempDir()
        let a = dir.write("a.md", "原文")
        let controller = makeController()
        controller.open(a)
        type("，我的修改", into: controller)
        dir.write("a.md", "AI 改了 a")

        controller.promptForLeaving = { _, answer in answer(.discard) }
        var left: Bool?
        controller.confirmLeaving { left = $0 }

        #expect(left == true)
        #expect(!controller.isDirty)
        // 放弃了的修改不能还留在编辑器里（看着像存了，下次一改又会被写回去）。
        #expect(editorText(controller) == "AI 改了 a")
        // 接着打字、自动保存，写进去的是在磁盘版本上的修改。
        type("，再改", into: controller)
        controller.saveIfNeeded()
        #expect(dir.read("a.md") == "AI 改了 a，再改")
    }
}
