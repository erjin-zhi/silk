import AppKit

/// 与磁盘原文的差异对照：以表单形式盖在窗口上，红色是磁盘上有、编辑器里没有的，绿色是编辑器里新写的。
/// 看完可以直接决定留哪一边。
@MainActor
final class DiffSheet: NSViewController {
    enum Choice { case close, keepMine, loadDisk }

    private let fileName: String
    /// 磁盘上的内容；nil 表示文件被删除或移走了。
    private let disk: String?
    private let mine: String
    private let onChoice: (Choice) -> Void
    private(set) var lines: [LineDiff.Line] = []
    let textView = NSTextView()

    init(fileName: String, disk: String?, mine: String, onChoice: @escaping (Choice) -> Void) {
        self.fileName = fileName
        self.disk = disk
        self.mine = mine
        self.onChoice = onChoice
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        lines = LineDiff.lines(old: disk ?? "", new: mine)
        let (added, removed) = LineDiff.stats(lines)
        let changed = added + removed > 0

        let title = NSTextField(labelWithString: "「\(fileName)」与磁盘上的版本")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        if disk == nil {
            subtitle.stringValue = "磁盘上的文件已被删除或移走，下面是编辑器里的全部内容"
        } else if changed {
            subtitle.stringValue = "编辑器里新增 \(added) 行（绿色）、删掉 \(removed) 行（红色）"
        } else {
            subtitle.stringValue = "编辑器里的内容和磁盘上的文件一致"
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(render())
        textView.setAccessibilityLabel("差异")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        let loadDisk = NSButton(title: "载入磁盘版本", target: self, action: #selector(loadDiskTapped))
        loadDisk.isEnabled = disk != nil && changed
        loadDisk.toolTip = "放弃编辑器里的修改，换成磁盘上的内容"
        let keep = NSButton(title: disk == nil ? "重新存储" : "存储我的修改", target: self, action: #selector(keepTapped))
        keep.isEnabled = disk == nil || changed
        keep.keyEquivalent = "\r"
        keep.toolTip = "用编辑器里的内容覆盖磁盘上的文件"

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [close, NSView(), loadDisk, keep])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        for view in [header, scroll, buttons] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root
        preferredContentSize = NSSize(width: 780, height: 560)
    }

    /// 差异渲染成带底色的等宽文字：左边是磁盘、编辑器里的行号，没变的行只留上下文。
    private func render() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        let hunks = LineDiff.hunks(lines)
        if hunks.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 40
            out.append(NSAttributedString(string: disk == nil ? "（空文档）" : "没有差异", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            return out
        }
        let digits = max(3, String(lines.count).count)
        let gutterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits * 2 + 4)

        func block(for kind: LineDiff.Kind) -> NSTextBlock {
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            switch kind {
            case .added: block.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16)
            case .removed: block.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16)
            case .same: block.backgroundColor = nil
            }
            return block
        }

        for (index, hunk) in hunks.enumerated() {
            if index > 0 || (hunk.lines.first?.old ?? hunk.lines.first?.new ?? 1) > 1 {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 4
                style.paragraphSpacing = 4
                style.firstLineHeadIndent = gutterWidth
                let first = hunk.lines.first
                let label = "⋯ 第 \(first?.new ?? first?.old ?? 1) 行"
                out.append(NSAttributedString(string: label + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
                ]))
            }
            // 同一种的连续几行共用一个底色块，看着是一整片。
            var runKind: LineDiff.Kind?
            var runBlock = NSTextBlock()
            for line in hunk.lines {
                if line.kind != runKind {
                    runKind = line.kind
                    runBlock = block(for: line.kind)
                }
                let style = NSMutableParagraphStyle()
                style.headIndent = gutterWidth
                style.lineBreakMode = .byCharWrapping
                style.textBlocks = [runBlock]
                let number = { (n: Int?) in n.map { String($0) } ?? "" }
                let pad = { (s: String) in String(repeating: " ", count: max(0, digits - s.count)) + s }
                let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                let gutter = "\(pad(number(line.old))) \(pad(number(line.new))) \(sign)  "
                let color: NSColor = line.kind == .same ? .secondaryLabelColor : .labelColor
                out.append(NSAttributedString(string: gutter, attributes: [
                    .font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
                ]))
                out.append(NSAttributedString(string: line.text + "\n", attributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: style,
                ]))
            }
        }
        return out
    }

    private func finish(_ choice: Choice) {
        dismiss(nil)
        onChoice(choice)
    }

    @objc private func closeTapped() { finish(.close) }
    @objc private func keepTapped() { finish(.keepMine) }
    @objc private func loadDiskTapped() { finish(.loadDisk) }
}
