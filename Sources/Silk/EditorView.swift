import AppKit

/// 源码编辑器：TextKit 1 的 NSTextView（大文件滚动稳定，行号和位置能精确换算）。
@MainActor
final class EditorView: NSScrollView, @preconcurrency NSTextStorageDelegate {
    let textView: MarkdownTextView
    let highlighter: MarkdownHighlighter

    /// 用户滚动编辑器时回调，参数是视口顶部对应的源码行（带小数）。
    var onScroll: ((Double) -> Void)?

    private var lineIndex = LineIndex()
    private var lineIndexStale = true
    private var programmaticScroll = false
    private var suppressHighlight = false
    /// 改过、还没重新着色的范围（随后续编辑平移）。
    private var pendingHighlight: NSRange?

    init(fontSize: CGFloat) {
        highlighter = MarkdownHighlighter(fontSize: fontSize)
        textView = MarkdownTextView(usingTextLayoutManager: false)
        super.init(frame: .zero)
        textView.baseAttributes = { [highlighter] in highlighter.baseAttributes }
        textView.willFinishChange = { [unowned self] in flushHighlight() }

        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder

        let tv = textView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 18, height: 22)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.typingAttributes = highlighter.baseAttributes
        tv.defaultParagraphStyle = highlighter.paragraphStyle
        tv.textStorage?.delegate = self
        tv.setAccessibilityLabel("Markdown 源码")

        documentView = tv
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var string: String { textView.string }

    // MARK: - 内容

    /// 换文件：整体替换，清掉撤销记录。
    func setText(_ text: String) {
        lineIndexStale = true
        let storage = textView.textStorage!
        // 大文件用非连续布局，打开不卡；小文件用连续布局，滚动对照更准。
        textView.layoutManager?.allowsNonContiguousLayout = (text as NSString).length > 400_000
        suppressHighlight = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: highlighter.baseAttributes))
        storage.endEditing()
        suppressHighlight = false
        pendingHighlight = nil
        highlighter.highlightAll(storage)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    /// 文件在外部被改了：只替换不同的那一段，光标和滚动位置尽量不动。
    func replaceKeepingPosition(with text: String) {
        let old = textView.string as NSString
        let new = text as NSString
        let oldLength = old.length
        let newLength = new.length
        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix
            && old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))

        let selection = textView.selectedRange()
        let origin = contentView.bounds.origin
        lineIndexStale = true
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        flushHighlight()
        textView.undoManager?.removeAllActions()
        let delta = newLength - oldLength
        var location = selection.location
        if location >= NSMaxRange(range) { location += delta } else if location > range.location { location = range.location }
        textView.setSelectedRange(NSRange(location: min(location, newLength), length: 0))
        programmaticScroll = true
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        programmaticScroll = false
    }

    func setFontSize(_ size: CGFloat) {
        highlighter.setFontSize(size)
        textView.typingAttributes = highlighter.baseAttributes
        if let storage = textView.textStorage { highlighter.highlightAll(storage) }
    }

    // 着色不放在这次编辑里做：在 willProcessEditing 改属性会把改动范围扩到整段，NSTextView 按改动范围的末尾放光标，
    // 行中间打字光标就跳到段尾（行内代码里打一个字就跑到 ` 外面）。
    // 也不能在 didProcessEditing 里改：排版器收不到失效通知，字在却显示不出来（从空文档开始打字时整行空白）。
    // 所以这里只记下范围，等 NSTextView 处理完这次输入（didChangeText）再单独做一次只改属性的编辑。
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndexStale = true
        guard !suppressHighlight else { return }
        let range = highlighter.textDidEdit(textStorage, editedRange: editedRange, delta: delta)
        if let pending = pendingHighlight {
            pendingHighlight = NSUnionRange(Self.shift(pending, by: editedRange, delta: delta), range)
        } else {
            pendingHighlight = range
            // 不经过 NSTextView 的改动（撤销、直接改文本存储）也要着色：兜底放到下一轮循环。
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushHighlight() } }
        }
    }

    /// 把之前记下的范围按这次编辑平移：editedRange 是改动后的范围，delta 是长度变化。
    private static func shift(_ range: NSRange, by editedRange: NSRange, delta: Int) -> NSRange {
        let oldEnd = NSMaxRange(editedRange) - delta
        func map(_ i: Int) -> Int {
            if i >= oldEnd { return i + delta }
            return min(i, NSMaxRange(editedRange))
        }
        let start = map(range.location)
        return NSRange(location: start, length: max(0, map(NSMaxRange(range)) - start))
    }

    /// 给改过的地方重新着色。
    func flushHighlight() {
        guard let range = pendingHighlight, let storage = textView.textStorage else { return }
        pendingHighlight = nil
        highlighter.restyle(storage, in: range)
    }

    // MARK: - 行号

    private var lines: LineIndex {
        if lineIndexStale {
            lineIndex = LineIndex(textView.string as NSString)
            lineIndexStale = false
        }
        return lineIndex
    }

    var caretLine: Int {
        lines.line(at: textView.selectedRange().location)
    }

    /// 某个字符所在的行片段（视觉上的一行）。
    private func fragmentRect(at index: Int) -> NSRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
        let length = textView.textStorage?.length ?? 0
        if length == 0 { return NSRect(x: 0, y: 0, width: 1, height: highlighter.fontSize * 1.4) }
        if index >= length {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 { return extra }
            let glyph = lm.glyphIndexForCharacter(at: length - 1)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let glyph = lm.glyphIndexForCharacter(at: index)
        lm.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        _ = tc
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// 源码行（带小数）在文本视图里的 y 坐标。
    private func y(forLine line: Double) -> CGFloat {
        let lines = self.lines
        let n = max(0, min(Int(line), lines.lineCount - 1))
        let range = lines.range(ofLine: n)
        let top = fragmentRect(at: range.location).minY
        let bottom = fragmentRect(at: max(range.location, NSMaxRange(range) - 1)).maxY
        let fraction = max(0, min(1, line - Double(n)))
        return top + CGFloat(fraction) * (bottom - top) + textView.textContainerInset.height
    }

    /// 视口顶部是第几行（带小数）。
    var topLine: Double {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, (textView.textStorage?.length ?? 0) > 0 else { return 0 }
        let y = contentView.bounds.minY + contentInsets.top - textView.textContainerInset.height
        if y <= 0 { return 0 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        let lines = self.lines
        let n = lines.line(at: char)
        let range = lines.range(ofLine: n)
        let top = fragmentRect(at: range.location).minY
        let bottom = fragmentRect(at: max(range.location, NSMaxRange(range) - 1)).maxY
        let fraction = bottom > top ? Double((y - top) / (bottom - top)) : 0
        return Double(n) + max(0, min(0.999, fraction))
    }

    /// 滚到某行（带小数）对齐视口顶部，不触发 onScroll。
    func scrollToLine(_ line: Double) {
        let maxY = max(0, textView.frame.height - contentView.bounds.height + contentInsets.bottom)
        let target = max(-contentInsets.top, min(y(forLine: line) - contentInsets.top, maxY))
        programmaticScroll = true
        contentView.scroll(to: NSPoint(x: 0, y: target))
        reflectScrolledClipView(contentView)
        programmaticScroll = false
    }

    /// 光标移到某行开头，必要时滚动让它可见。
    func moveCaret(toLine line: Int) {
        let range = lines.range(ofLine: line)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        let rect = fragmentRect(at: range.location).offsetBy(dx: 0, dy: textView.textContainerInset.height)
        let visible = contentView.bounds
        if rect.minY < visible.minY + contentInsets.top || rect.maxY > visible.maxY - 40 {
            programmaticScroll = true
            textView.scrollToVisible(rect.insetBy(dx: 0, dy: -visible.height / 3))
            programmaticScroll = false
        }
    }

    /// 选中一段文字（搜索结果），滚到视口上方三分之一处，并闪一下。
    func select(_ range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(range)
        let rect = fragmentRect(at: range.location).offsetBy(dx: 0, dy: textView.textContainerInset.height)
        let visible = contentView.bounds
        programmaticScroll = true
        textView.scrollToVisible(rect.insetBy(dx: 0, dy: -visible.height / 3))
        programmaticScroll = false
        if range.length > 0 { textView.showFindIndicator(for: range) }
    }

    @objc private func boundsDidChange() {
        guard !programmaticScroll else { return }
        onScroll?(topLine)
    }
}
