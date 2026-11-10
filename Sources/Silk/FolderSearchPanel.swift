import AppKit

/// ⇧⌘F 在文件夹中搜索：输入文字，列出每一处命中的那一行，回车打开文件并跳到那里。
@MainActor
final class FolderSearchPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    private let field = NSTextField()
    private let searchIcon = NSImageView(image: NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)!)
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var files: [URL] = []
    private var matches: [FolderSearch.Match] = []
    private weak var workspace: Workspace?
    private var onPick: ((FolderSearch.Match, String) -> Void)?
    private var searchTask: Task<Void, Never>?
    /// 最近一次搜完的关键词（测试和调试用）。
    private(set) var lastQuery = ""

    var isVisible: Bool { panel?.isVisible ?? false }
    var results: [FolderSearch.Match] { matches }

    /// 打开面板。query 不为空时（比如编辑器里选中的文字）直接搜它，否则保留上次的关键词。
    func show(over window: NSWindow, workspace: Workspace, query: String?, onPick: @escaping (FolderSearch.Match, String) -> Void) {
        self.workspace = workspace
        self.files = workspace.files.map(\.url)
        self.onPick = onPick
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let query, !query.isEmpty { field.stringValue = query }

        let width: CGFloat = 640
        let height: CGFloat = 460
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - height, width: width, height: height), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        search()
    }

    /// 测试、调试用：直接输入关键词。
    func setQuery(_ query: String) {
        field.stringValue = query
        search()
    }

    func close() {
        searchTask?.cancel()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
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

        field.placeholderString = "在文件夹中搜索"
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
        field.setAccessibilityLabel("在文件夹中搜索")

        searchIcon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("match")))
        table.headerView = nil
        table.rowHeight = 44
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(pick)
        table.doubleAction = #selector(pick)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchIcon, field, separator, scroll, status] { content.addSubview(view) }
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
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        glass.contentView = content
        panel.contentView = glass
        return panel
    }

    @objc private func pick() {
        let row = table.selectedRow
        guard row >= 0, row < matches.count else { return }
        let match = matches[row]
        let query = lastQuery
        close()
        onPick?(match, query)
    }

    // MARK: - 搜索

    private func search() {
        searchTask?.cancel()
        let query = field.stringValue
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastQuery = ""
            show([], query: "", result: nil)
            return
        }
        let files = files
        status.stringValue = "正在搜索…"
        searchTask = Task { [weak self] in
            // 连续打字时等一下再搜，只搜最后一次。
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                FolderSearch.search(query, in: files) { Task.isCancelled }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.lastQuery = query
            self.show(result.matches, query: query, result: result)
        }
    }

    private func show(_ matches: [FolderSearch.Match], query: String, result: FolderSearch.Result?) {
        self.matches = matches
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        guard let result else {
            status.stringValue = files.isEmpty ? "这个文件夹里还没有 Markdown 文件" : "在 \(files.count) 个 Markdown 文件中搜索"
            return
        }
        if matches.isEmpty {
            status.stringValue = "没有找到「\(query)」"
        } else {
            status.stringValue = result.truncated
                ? "结果太多，只列出 \(result.fileCount) 个文件中的 \(matches.count) 处，换个更具体的词试试"
                : "\(result.fileCount) 个文件中共 \(matches.count) 处结果"
        }
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("match")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MatchCell ?? MatchCell(id)
        let match = matches[row]
        let snippet = NSMutableAttributedString(string: match.snippet, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        if NSMaxRange(match.highlight) <= snippet.length {
            snippet.addAttributes([
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.45),
            ], range: match.highlight)
        }
        cell.title.attributedStringValue = snippet
        let path = workspace?.relativePath(of: match.url) ?? match.url.lastPathComponent
        cell.subtitle.stringValue = "\(path) · 第 \(match.line + 1) 行"
        return cell
    }

    // MARK: - 键盘

    func controlTextDidChange(_ obj: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): pick()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

private final class MatchCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
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
