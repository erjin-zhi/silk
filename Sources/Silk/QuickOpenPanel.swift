import AppKit

/// ⇧⌘O 快速打开：输入几个字母模糊匹配文件路径，回车打开。
@MainActor
final class QuickOpenPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    // 用普通输入框加单独的放大镜图标：NSSearchField 去掉边框后，自带的放大镜会压在文字和光标上。
    private let field = NSTextField()
    private let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
    private let table = NSTableView()
    private var files: [FileNode] = []
    private var results: [(node: FileNode, path: String)] = []
    private var recent: [URL] = []
    private weak var workspace: Workspace?
    private var onPick: ((URL) -> Void)?

    func noteOpened(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        if recent.count > 20 { recent.removeLast() }
    }

    func show(over window: NSWindow, files: [FileNode], workspace: Workspace, onPick: @escaping (URL) -> Void) {
        self.files = files
        self.workspace = workspace
        self.onPick = onPick
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.stringValue = ""
        filter()

        let width: CGFloat = 560
        let frame = window.frame
        panel.setFrame(
            NSRect(x: frame.midX - width / 2, y: frame.maxY - 120 - 380, width: width, height: 380), display: false
        )
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let glass = NSGlassEffectView()
        glass.cornerRadius = 18

        let content = NSView()
        field.placeholderString = "按文件名或路径查找"
        field.font = .systemFont(ofSize: 17)
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("快速打开")

        searchIcon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        table.action = #selector(pick)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchIcon)
        content.addSubview(field)
        content.addSubview(separator)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        glass.contentView = content
        panel.contentView = glass
        return panel
    }

    private func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func pick() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let url = results[row].node.url
        close()
        onPick?(url)
    }

    // MARK: - 匹配

    private func filter() {
        guard let workspace else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = files.map { (node: $0, path: workspace.relativePath(of: $0.url)) }
        if query.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
            results = all.sorted {
                let a = order[$0.node.url] ?? Int.max
                let b = order[$1.node.url] ?? Int.max
                return a != b ? a < b : $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        } else {
            results = all
                .compactMap { item in Self.score(query, item.path.lowercased()).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(80)
                .map(\.0)
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    /// 子序列模糊匹配：连续命中、命中词头、命中文件名部分加分；路径越短越靠前。
    static func score(_ query: String, _ path: String) -> Int? {
        let q = Array(query.unicodeScalars)
        let p = Array(path.unicodeScalars)
        let nameStart = (path.lastIndex(of: "/").map { path.unicodeScalars.distance(from: path.unicodeScalars.startIndex, to: $0) + 1 }) ?? 0
        var score = 0
        var qi = 0
        var last = -2
        for (i, c) in p.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            var s = 1
            if i == last + 1 { s += 6 }
            if i == 0 || "/-_. ".unicodeScalars.contains(p[i - 1]) { s += 8 }
            if i >= nameStart { s += 3 }
            score += s
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 - p.count
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ResultCell ?? ResultCell(id)
        let item = results[row]
        cell.title.stringValue = item.node.name
        let folder = (item.path as NSString).deletingLastPathComponent
        cell.subtitle.stringValue = folder.isEmpty ? "/" : folder
        return cell
    }

    // MARK: - 键盘

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            pick()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ResultCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
