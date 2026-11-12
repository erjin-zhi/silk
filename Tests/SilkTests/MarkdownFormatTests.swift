import AppKit
import Testing
@testable import Silk

/// 格式菜单（Typora 快捷键）背后的文本变换。
@MainActor
struct MarkdownFormatTests {
    /// 用 | 标光标，[ ] 标选区，跑一次变换，再把结果画回同样的记号。
    private func run(_ marked: String, _ op: (NSString, NSRange) -> MarkdownEdit) -> String {
        var text = marked
        var selection = NSRange(location: 0, length: 0)
        if let caret = text.range(of: "|") {
            selection.location = NSRange(caret, in: text).location
            text.removeSubrange(caret)
        } else if let open = text.range(of: "["), let close = text.range(of: "]", range: open.upperBound..<text.endIndex) {
            let start = NSRange(open, in: text).location
            let end = NSRange(close, in: text).location - 1
            text.removeSubrange(close)
            text.removeSubrange(open)
            selection = NSRange(location: start, length: end - start)
        }
        let ns = NSMutableString(string: text)
        let edit = op(ns, selection)
        ns.replaceCharacters(in: edit.range, with: edit.replacement)
        if edit.selection.length == 0 {
            ns.insert("|", at: edit.selection.location)
        } else {
            ns.insert("]", at: NSMaxRange(edit.selection))
            ns.insert("[", at: edit.selection.location)
        }
        return ns as String
    }

    @Test func 设标题再按一次变回正文() {
        #expect(run("你好|", { MarkdownFormat.setHeading($0, $1, level: 2) }) == "## 你好|")
        #expect(run("## 你好|", { MarkdownFormat.setHeading($0, $1, level: 2) }) == "你好|")
        #expect(run("## 你好|", { MarkdownFormat.setHeading($0, $1, level: 1) }) == "# 你好|")
        #expect(run("### 你好|", { MarkdownFormat.setHeading($0, $1, level: 0) }) == "你好|")
        #expect(run("|你好", { MarkdownFormat.setHeading($0, $1, level: 3) }) == "### |你好")
        #expect(run("前\n中|\n后", { MarkdownFormat.setHeading($0, $1, level: 1) }) == "前\n# 中|\n后")
    }

    @Test func 提升降低标题级别() {
        #expect(run("正文|", { MarkdownFormat.shiftHeading($0, $1, promote: true) }) == "###### 正文|")
        #expect(run("## 二|", { MarkdownFormat.shiftHeading($0, $1, promote: true) }) == "# 二|")
        #expect(run("# 一|", { MarkdownFormat.shiftHeading($0, $1, promote: true) }) == "# 一|")
        #expect(run("# 一|", { MarkdownFormat.shiftHeading($0, $1, promote: false) }) == "## 一|")
        #expect(run("###### 六|", { MarkdownFormat.shiftHeading($0, $1, promote: false) }) == "六|")
    }

    @Test func 加粗包住和去掉() {
        let bold: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleWrap($0, $1, open: "**", close: "**") }
        #expect(run("一[段]话", bold) == "一**[段]**话")
        #expect(run("一**[段]**话", bold) == "一[段]话")
        #expect(run("一[**段**]话", bold) == "一[段]话")
        #expect(run("一|话", bold) == "一**|**话")
    }

    @Test func 斜体不把粗体当成自己的标记() {
        let italic: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleWrap($0, $1, open: "*", close: "*") }
        #expect(run("[**粗**]", italic) == "*[**粗**]*")
        #expect(run("[*斜*]", italic) == "[斜]")
    }

    @Test func 链接和图片() {
        #expect(run("看[这里]吧", { MarkdownFormat.insertLink($0, $1) }) == "看[这里](|)吧")
        #expect(run("[https://a.com]", { MarkdownFormat.insertLink($0, $1) }) == "[|](https://a.com)")
        #expect(run("|", { MarkdownFormat.insertLink($0, $1) }) == "[|]()")
        #expect(run("|", { MarkdownFormat.insertLink($0, $1, image: true) }) == "![|]()")
    }

    @Test func 列表和引用() {
        let bullet: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleLinePrefix($0, $1, .bullet) }
        let ordered: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleLinePrefix($0, $1, .ordered) }
        let task: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleLinePrefix($0, $1, .task) }
        let quote: (NSString, NSRange) -> MarkdownEdit = { MarkdownFormat.toggleLinePrefix($0, $1, .quote) }
        #expect(run("[甲\n\n乙]", bullet) == "[- 甲\n\n- 乙]")
        #expect(run("[- 甲\n- 乙]", bullet) == "[甲\n乙]")
        #expect(run("[- 甲\n- 乙]", ordered) == "[1. 甲\n2. 乙]")
        #expect(run("- 甲|", task) == "- [ ] 甲|")
        #expect(run("- [ ] 甲|", task) == "甲|")
        #expect(run("- [ ] 甲|", bullet) == "- 甲|")
        #expect(run("  - 甲|", ordered) == "  1. 甲|")
        #expect(run("话|", quote) == "> 话|")
        #expect(run("> 话|", quote) == "话|")
        // 选区停在下一行开头，不算那一行。
        #expect(run("[甲\n]乙", bullet) == "[- 甲]\n乙")
    }

    @Test func 代码块表格分隔线() {
        #expect(run("|", { MarkdownFormat.codeBlock($0, $1) }) == "```|\n\n```")
        #expect(run("[a\nb]", { MarkdownFormat.codeBlock($0, $1) }) == "```|\na\nb\n```")
        #expect(run("话|", { MarkdownFormat.codeBlock($0, $1) }) == "话\n\n```|\n\n```")
        #expect(run("|", { MarkdownFormat.table($0, $1) }) == "| [列 1] | 列 2 |\n| --- | --- |\n|  |  |")
        #expect(run("话|", { MarkdownFormat.horizontalRule($0, $1) }) == "话\n\n---\n|")
    }

    @Test func 文本视图里改完能撤销() {
        let editor = EditorView(fontSize: 15)
        editor.setText("你好")
        let tv = editor.textView
        tv.isEditable = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        let item = NSMenuItem(title: "", action: #selector(MarkdownTextView.formatHeading(_:)), keyEquivalent: "")
        item.tag = 2
        #expect(tv.validateUserInterfaceItem(item))
        tv.formatHeading(item)
        #expect(tv.string == "## 你好")
        #expect(item.state == .off)
        _ = tv.validateUserInterfaceItem(item)
        #expect(item.state == .on)
        tv.undoManager?.undo()
        #expect(tv.string == "你好")
    }

    /// 着色不能把光标挤到段尾：行内代码里连续打字都留在 ` 里面，行中间打字、删字光标不动。
    @Test func 行中间打字光标不跳到段尾() {
        let editor = EditorView(fontSize: 15)
        editor.setText("")
        let tv = editor.textView
        tv.isEditable = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        tv.formatInlineCode(nil)
        for c in ["i", "m", "p"] { tv.insertText(c, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(tv.string == "`imp`")
        #expect(tv.selectedRange() == NSRange(location: 4, length: 0))
        // 着色照常生效。
        #expect(tv.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .systemPink)

        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.selectedRange() == NSRange(location: 3, length: 0))
        tv.deleteBackward(nil)
        #expect(tv.string == "`imp`")
        #expect(tv.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func 编辑器字号单独调且有上下限() {
        let doc = DocumentViewController()
        doc.changeEditorFontSize(by: 0)
        #expect(doc.editorFontSize == 15)
        doc.changeEditorFontSize(by: 1)
        #expect(doc.editorFontSize == 16)
        for _ in 0..<40 { doc.changeEditorFontSize(by: 1) }
        #expect(doc.editorFontSize == DocumentViewController.editorFontSizeRange.upperBound)
        for _ in 0..<40 { doc.changeEditorFontSize(by: -1) }
        #expect(doc.editorFontSize == DocumentViewController.editorFontSizeRange.lowerBound)
        #expect(DocumentViewController().editorFontSize == DocumentViewController.editorFontSizeRange.lowerBound)
        doc.changeEditorFontSize(by: 0)
    }

    /// 快捷键按真实键盘事件匹配：⇧ 组合键送来的字符是 + _ ) ~，要能对上菜单。
    @Test(arguments: [
        ("=", 24, NSEvent.ModifierFlags([.command, .shift]), "+", "放大"),
        ("-", 27, NSEvent.ModifierFlags.command, "-", "降低标题级别"),
        ("0", 29, NSEvent.ModifierFlags.command, "0", "正文"),
        ("-", 27, NSEvent.ModifierFlags([.command, .shift]), "_", "缩小"),
        ("0", 29, NSEvent.ModifierFlags([.command, .shift]), ")", "实际大小"),
        ("=", 24, NSEvent.ModifierFlags([.command, .option]), "≠", "增大"),
        ("=", 24, NSEvent.ModifierFlags.command, "=", "提升标题级别"),
        ("`", 50, NSEvent.ModifierFlags([.control, .shift]), "~", "删除线"),
        ("`", 50, NSEvent.ModifierFlags.control, "`", "行内代码"),
        ("1", 18, NSEvent.ModifierFlags([.command, .control]), "1", "阅读"),
        ("1", 18, NSEvent.ModifierFlags.command, "1", "标题 1"),
    ])
    func 快捷键能对上菜单(key: String, code: UInt16, flags: NSEvent.ModifierFlags, chars: String, title: String) throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let recorder = Recorder()
        func wire(_ m: NSMenu) {
            for item in m.items {
                if let sub = item.submenu { wire(sub) } else if item.action != nil {
                    item.target = recorder
                    item.action = #selector(Recorder.hit(_:))
                }
            }
        }
        wire(menu)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: flags.contains(.shift) ? chars : key,
            isARepeat: false, keyCode: code
        ))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(recorder.titles == [title])
    }
}

@MainActor
private final class Recorder: NSObject {
    var titles: [String] = []
    @objc func hit(_ sender: NSMenuItem) { titles.append(sender.title) }
}
