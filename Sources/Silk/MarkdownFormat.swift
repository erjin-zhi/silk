import AppKit

/// 一次格式操作的结果：把 range 换成 replacement，之后选中 selection。
struct MarkdownEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// 格式菜单背后的纯文本变换（标题、加粗、列表……），快捷键沿用 Typora。
/// 只算出要怎么改，不碰文本视图，方便测试。
enum MarkdownFormat {
    // MARK: - 行

    /// 选区覆盖的整行范围（不含最后的换行）。选区刚好停在下一行开头时，不算那一行。
    static func lineRange(_ text: NSString, _ selection: NSRange) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length,
           text.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(selection.location, end), length: 0))
        var upper = NSMaxRange(last)
        if upper > first.location, upper <= text.length, text.character(at: upper - 1) == 0x0A { upper -= 1 }
        if upper > first.location, text.character(at: upper - 1) == 0x0D { upper -= 1 }
        return NSRange(location: first.location, length: max(0, upper - first.location))
    }

    private static func lines(_ text: NSString, _ range: NSRange) -> [String] {
        text.substring(with: range).components(separatedBy: "\n")
    }

    /// 对选中的每一行做变换，保持选区大致不动（落在整块改过的行上）。
    private static func mapLines(
        _ text: NSString, _ selection: NSRange, _ transform: ([String]) -> [String]
    ) -> MarkdownEdit {
        let range = lineRange(text, selection)
        let old = lines(text, range)
        let new = transform(old).joined(separator: "\n")
        let newLength = (new as NSString).length
        let selectionResult: NSRange
        if old.count == 1, selection.length == 0 {
            // 单行、没选中：光标跟着行尾走（前缀变了，光标相对行尾的位置不变）。
            let fromEnd = NSMaxRange(range) - selection.location
            selectionResult = NSRange(location: max(range.location, range.location + newLength - fromEnd), length: 0)
        } else {
            selectionResult = NSRange(location: range.location, length: newLength)
        }
        return MarkdownEdit(range: range, replacement: new, selection: selectionResult)
    }

    // MARK: - 标题

    private static let headingPrefix = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)

    /// 行首标题级别，0 表示正文。
    static func headingLevel(of line: String) -> Int {
        let ns = line as NSString
        guard let m = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        return m.range(at: 1).length
    }

    private static func stripHeading(_ line: String) -> String {
        let ns = line as NSString
        guard let m = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        return ns.substring(from: NSMaxRange(m.range))
    }

    private static func withHeading(_ line: String, _ level: Int) -> String {
        let body = stripHeading(line)
        return level == 0 ? body : String(repeating: "#", count: level) + " " + body
    }

    /// ⌘1–⌘6 设标题，⌘0 设正文；已经是这一级标题时再按一次变回正文（同 Typora）。
    static func setHeading(_ text: NSString, _ selection: NSRange, level: Int) -> MarkdownEdit {
        let current = lines(text, lineRange(text, selection))
        let allSame = level > 0 && current.allSatisfy { headingLevel(of: $0) == level }
        return mapLines(text, selection) { lines in
            lines.map { withHeading($0, allSame ? 0 : level) }
        }
    }

    /// ⌘= 提升（字变大）：正文 → 六级 → … → 一级。⌘- 降低：一级 → … → 六级 → 正文。
    static func shiftHeading(_ text: NSString, _ selection: NSRange, promote: Bool) -> MarkdownEdit {
        mapLines(text, selection) { lines in
            lines.map { line in
                let level = headingLevel(of: line)
                let next: Int
                if promote {
                    next = level == 0 ? 6 : max(1, level - 1)
                } else {
                    next = level == 0 ? 0 : (level == 6 ? 0 : level + 1)
                }
                return withHeading(line, next)
            }
        }
    }

    // MARK: - 行内包裹

    /// 加粗、斜体、行内代码等：有选区时包住或去掉两边的标记，没选区时插入一对标记、光标放中间。
    static func toggleWrap(_ text: NSString, _ selection: NSRange, open: String, close: String) -> MarkdownEdit {
        let o = (open as NSString).length
        let c = (close as NSString).length
        let selected = text.substring(with: selection)

        // 选中的文字自己带着标记：**粗体** → 粗体。
        if selection.length >= o + c, isWrapped(selected, open: open, close: close) {
            let inner = (selected as NSString).substring(with: NSRange(location: o, length: (selected as NSString).length - o - c))
            return MarkdownEdit(range: selection, replacement: inner,
                                selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        // 标记在选区外面紧挨着：**|粗体|** → 粗体。
        if selection.location >= o, NSMaxRange(selection) + c <= text.length {
            let outer = NSRange(location: selection.location - o, length: selection.length + o + c)
            if isWrapped(text.substring(with: outer), open: open, close: close) {
                return MarkdownEdit(range: outer, replacement: selected,
                                    selection: NSRange(location: outer.location, length: selection.length))
            }
        }
        return MarkdownEdit(range: selection, replacement: open + selected + close,
                            selection: NSRange(location: selection.location + o, length: selection.length))
    }

    private static func isWrapped(_ s: String, open: String, close: String) -> Bool {
        guard s.hasPrefix(open), s.hasSuffix(close), (s as NSString).length >= (open as NSString).length + (close as NSString).length else {
            return false
        }
        // 斜体的 * 不能把 **粗体** 当成自己的标记（***粗斜体*** 可以）。
        if open == "*" || open == "_" {
            let double = open + open
            if s.hasPrefix(double) && !s.hasPrefix(double + open) { return false }
        }
        return true
    }

    // MARK: - 链接和图片

    /// ⌘K：选中的是网址就放进括号、光标去写文字；否则选中文字当链接文字、光标去写网址。
    static func insertLink(_ text: NSString, _ selection: NSRange, image: Bool = false) -> MarkdownEdit {
        let selected = text.substring(with: selection)
        let bang = image ? "!" : ""
        let lead = (bang as NSString).length + 1
        if !selected.isEmpty, looksLikeURL(selected) {
            return MarkdownEdit(range: selection, replacement: "\(bang)[](\(selected))",
                                selection: NSRange(location: selection.location + lead, length: 0))
        }
        let replacement = "\(bang)[\(selected)]()"
        let urlAt = selection.location + lead + (selected as NSString).length + 2
        let caret = selected.isEmpty ? selection.location + lead : urlAt
        return MarkdownEdit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), !t.contains("\n") else { return false }
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("mailto:") || t.hasPrefix("./") || t.hasPrefix("/")
    }

    // MARK: - 行前缀（引用、列表）

    enum LinePrefix {
        case quote, bullet, ordered, task
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)
    private static let taskMarker = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[[ xX]\][ \t]+"#)
    private static let bulletMarker = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+(?!\[[ xX]\][ \t])"#)
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^[ \t]*\d{1,9}[.)][ \t]+"#)

    private static func match(_ re: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func has(_ prefix: LinePrefix, _ line: String) -> Bool {
        switch prefix {
        case .quote: match(quoteMarker, line) != nil
        case .bullet: match(bulletMarker, line) != nil
        case .ordered: match(orderedMarker, line) != nil
        case .task: match(taskMarker, line) != nil
        }
    }

    private static func strip(_ prefix: LinePrefix, _ line: String) -> String {
        let re = prefix == .quote ? quoteMarker : listMarker
        guard let m = match(re, line) else { return line }
        let ns = line as NSString
        let indent = prefix == .quote ? "" : ns.substring(with: m.range(at: 1))
        return indent + ns.substring(from: NSMaxRange(m.range))
    }

    /// ⌥⌘Q 引用、⌥⌘U 无序列表、⌥⌘O 有序列表、⌥⌘X 任务列表。
    /// 选中的行都已经是这种格式就去掉，否则加上（别的列表标记会被换掉）。多行时空行不动。
    static func toggleLinePrefix(_ text: NSString, _ selection: NSRange, _ prefix: LinePrefix) -> MarkdownEdit {
        let current = lines(text, lineRange(text, selection))
        let content = current.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !content.isEmpty && content.allSatisfy { has(prefix, $0) }
        return mapLines(text, selection) { lines in
            var number = 0
            return lines.map { line in
                if remove { return strip(prefix, line) }
                if lines.count > 1, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                switch prefix {
                case .quote:
                    return "> " + line
                case .bullet, .ordered, .task:
                    let base = strip(.bullet, line)
                    let indent = String(base.prefix { $0 == " " || $0 == "\t" })
                    let body = String(base.dropFirst(indent.count))
                    number += 1
                    let marker = prefix == .bullet ? "- " : prefix == .task ? "- [ ] " : "\(number). "
                    return indent + marker + body
                }
            }
        }
    }

    // MARK: - 块

    /// 在当前行插入一个独立的块：当前行是空行就放在这里，否则放到下一行，前面空一行。
    /// select 是块插入后的选区，相对块开头。
    private static func insertBlock(_ text: NSString, _ selection: NSRange, _ block: String, select: NSRange) -> MarkdownEdit {
        let line = lineRange(text, NSRange(location: selection.location, length: 0))
        let lineText = text.substring(with: line)
        if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
            return MarkdownEdit(range: line, replacement: block,
                                selection: NSRange(location: line.location + select.location, length: select.length))
        }
        let end = NSMaxRange(lineRange(text, selection))
        let lead = "\n\n"
        return MarkdownEdit(range: NSRange(location: end, length: 0), replacement: lead + block,
                            selection: NSRange(location: end + 2 + select.location, length: select.length))
    }

    /// ⌥⌘C 代码块：有选区时把选中的行包进围栏；没有选区时插入空代码块。光标停在开头 ``` 后面写语言。
    static func codeBlock(_ text: NSString, _ selection: NSRange) -> MarkdownEdit {
        if selection.length > 0 {
            let range = lineRange(text, selection)
            let body = text.substring(with: range)
            return MarkdownEdit(range: range, replacement: "```\n" + body + "\n```",
                                selection: NSRange(location: range.location + 3, length: 0))
        }
        return insertBlock(text, selection, "```\n\n```", select: NSRange(location: 3, length: 0))
    }

    /// ⌥⌘T 表格：插入两列的表格模板，选中第一个表头。
    static func table(_ text: NSString, _ selection: NSRange) -> MarkdownEdit {
        let block = "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |"
        return insertBlock(text, selection, block, select: NSRange(location: 2, length: ("列 1" as NSString).length))
    }

    /// 分隔线。前面一定空一行，否则 --- 会把上一行变成标题。
    static func horizontalRule(_ text: NSString, _ selection: NSRange) -> MarkdownEdit {
        let block = "---\n"
        return insertBlock(text, selection, block, select: NSRange(location: (block as NSString).length, length: 0))
    }
}

// MARK: - 文本视图

/// 带 Markdown 格式命令的源码文本视图。格式菜单的命令沿响应链找到这里。
@MainActor
final class MarkdownTextView: NSTextView {
    /// 插入新文字用的属性（着色器会再改）。
    var baseAttributes: () -> [NSAttributedString.Key: Any] = { [:] }
    /// 每次改完文字、发出改动通知之前调用（编辑器在这里补着色）。
    var willFinishChange: () -> Void = {}

    override func didChangeText() {
        willFinishChange()
        super.didChangeText()
    }

    private var canFormat: Bool { isEditable && !isHiddenOrHasHiddenAncestor }

    private func perform(_ name: String, _ make: (NSString, NSRange) -> MarkdownEdit) {
        guard canFormat else {
            NSSound.beep()
            return
        }
        let edit = make(string as NSString, selectedRange())
        apply(edit, actionName: name)
    }

    func apply(_ edit: MarkdownEdit, actionName: String) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        breakUndoCoalescing()
        textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: baseAttributes()))
        didChangeText()
        undoManager?.setActionName(actionName)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    @objc func formatHeading(_ sender: NSMenuItem) {
        let level = sender.tag
        perform(level == 0 ? "正文" : "标题 \(level)") { MarkdownFormat.setHeading($0, $1, level: level) }
    }
    @objc func formatPromoteHeading(_ sender: Any?) { perform("提升标题级别") { MarkdownFormat.shiftHeading($0, $1, promote: true) } }
    @objc func formatDemoteHeading(_ sender: Any?) { perform("降低标题级别") { MarkdownFormat.shiftHeading($0, $1, promote: false) } }

    @objc func formatBold(_ sender: Any?) { perform("粗体") { MarkdownFormat.toggleWrap($0, $1, open: "**", close: "**") } }
    @objc func formatItalic(_ sender: Any?) { perform("斜体") { MarkdownFormat.toggleWrap($0, $1, open: "*", close: "*") } }
    @objc func formatUnderline(_ sender: Any?) { perform("下划线") { MarkdownFormat.toggleWrap($0, $1, open: "<u>", close: "</u>") } }
    @objc func formatStrikethrough(_ sender: Any?) { perform("删除线") { MarkdownFormat.toggleWrap($0, $1, open: "~~", close: "~~") } }
    @objc func formatInlineCode(_ sender: Any?) { perform("行内代码") { MarkdownFormat.toggleWrap($0, $1, open: "`", close: "`") } }
    @objc func formatLink(_ sender: Any?) { perform("链接") { MarkdownFormat.insertLink($0, $1) } }
    @objc func formatImage(_ sender: Any?) { perform("图片") { MarkdownFormat.insertLink($0, $1, image: true) } }

    @objc func formatQuote(_ sender: Any?) { perform("引用") { MarkdownFormat.toggleLinePrefix($0, $1, .quote) } }
    @objc func formatBulletList(_ sender: Any?) { perform("无序列表") { MarkdownFormat.toggleLinePrefix($0, $1, .bullet) } }
    @objc func formatOrderedList(_ sender: Any?) { perform("有序列表") { MarkdownFormat.toggleLinePrefix($0, $1, .ordered) } }
    @objc func formatTaskList(_ sender: Any?) { perform("任务列表") { MarkdownFormat.toggleLinePrefix($0, $1, .task) } }
    @objc func formatCodeBlock(_ sender: Any?) { perform("代码块") { MarkdownFormat.codeBlock($0, $1) } }
    @objc func formatTable(_ sender: Any?) { perform("表格") { MarkdownFormat.table($0, $1) } }
    @objc func formatHorizontalRule(_ sender: Any?) { perform("分隔线") { MarkdownFormat.horizontalRule($0, $1) } }

    static let formatActions: Set<Selector> = [
        #selector(formatHeading(_:)), #selector(formatPromoteHeading(_:)), #selector(formatDemoteHeading(_:)),
        #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatUnderline(_:)),
        #selector(formatStrikethrough(_:)), #selector(formatInlineCode(_:)), #selector(formatLink(_:)),
        #selector(formatImage(_:)), #selector(formatQuote(_:)), #selector(formatBulletList(_:)),
        #selector(formatOrderedList(_:)), #selector(formatTaskList(_:)), #selector(formatCodeBlock(_:)),
        #selector(formatTable(_:)), #selector(formatHorizontalRule(_:)),
    ]

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, Self.formatActions.contains(action) else {
            return super.validateUserInterfaceItem(item)
        }
        if action == #selector(formatHeading(_:)), let menuItem = item as? NSMenuItem {
            let text = string as NSString
            let line = text.substring(with: MarkdownFormat.lineRange(text, NSRange(location: selectedRange().location, length: 0)))
            menuItem.state = MarkdownFormat.headingLevel(of: line) == menuItem.tag ? .on : .off
        }
        return canFormat
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard isEditable else { return menu }
        let format = MainMenu.formatMenu()
        let item = NSMenuItem(title: format.title, action: nil, keyEquivalent: "")
        item.submenu = format
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}
