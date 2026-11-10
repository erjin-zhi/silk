import AppKit

/// 侧栏文件树：只显示 Markdown 文件和含有它们的文件夹。每个文件右边标着修改时间，底部有「新建」。
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var root: FileNode?
    private var expanded: Set<URL> = []
    private var selected: URL?
    private var reloading = false
    private let newButton = NSButton()
    /// 文件的修改时间，只查屏幕上显示到的行；文件变了就清掉重查。
    private var modified: [String: Date] = [:]
    private var clock: Timer?

    var onSelect: ((URL) -> Void)?
    /// 点「新建」。
    var onNew: (() -> Void)?

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: .init("name"))
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 13
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.setAccessibilityLabel("文件")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 底部给「新建」按钮让出位置，最后一行不会被它挡住。
        scroll.automaticallyAdjustsContentInsets = true
        view.addSubview(scroll)

        newButton.title = "新建"
        newButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.imageHugsTitle = true
        newButton.bezelStyle = .glass
        newButton.controlSize = .large
        newButton.toolTip = "新建草稿（⌘N）"
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newButton)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            newButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            newButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        scroll.contentInsets.bottom = 56

        // 「3 分钟前」这类时间每分钟刷新一次。
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleDates() }
        }
    }

    @objc private func newTapped() { onNew?() }

    /// 文件夹里有文件变了：清掉这些文件的修改时间，重新显示。
    func filesDidChange(_ paths: Set<String>) {
        var changed = false
        for path in paths {
            if modified.removeValue(forKey: path) != nil { changed = true }
            if path.hasPrefix("/private/"), modified.removeValue(forKey: String(path.dropFirst("/private".count))) != nil { changed = true }
        }
        if changed { refreshVisibleDates() }
    }

    private func refreshVisibleDates() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: [0])
    }

    private func modificationDate(_ url: URL) -> Date? {
        if let date = modified[url.path] { return date }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let date { modified[url.path] = date }
        return date
    }

    /// 侧栏里显示的时间：刚刚、5 分钟前、14:32、昨天、10月28日、2025/10/28。
    nonisolated static func timeLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        if parts.year == calendar.component(.year, from: now) { return "\(parts.month!)月\(parts.day!)日" }
        return "\(parts.year!)/\(parts.month!)/\(parts.day!)"
    }

    /// 换上新的文件树，保留展开状态和选中项。
    func setTree(_ tree: FileNode, scanned: Bool) {
        let first = root == nil || root?.url != tree.url
        root = tree
        reloading = true
        outline.reloadData()
        if first {
            // 第一次打开：顶层文件夹不多时直接展开。
            if tree.children.filter(\.isDirectory).count <= 6 {
                for node in tree.children where node.isDirectory { expanded.insert(node.url) }
            }
        }
        restoreExpansion(tree.children)
        reloading = false
        if let selected { select(selected) }
        emptyLabel.stringValue = "这个文件夹里没有 Markdown 文件"
        emptyLabel.isHidden = !(scanned && tree.children.isEmpty)
    }

    private func restoreExpansion(_ nodes: [FileNode]) {
        for node in nodes where node.isDirectory && expanded.contains(node.url) {
            outline.expandItem(node)
            restoreExpansion(node.children)
        }
    }

    /// 选中某个文件，展开它所在的文件夹。
    func select(_ url: URL) {
        selected = url
        guard let root, let path = findPath(to: url, in: root.children) else {
            outline.deselectAll(nil)
            return
        }
        reloading = true
        for node in path.dropLast() {
            expanded.insert(node.url)
            outline.expandItem(node)
        }
        let row = outline.row(forItem: path.last)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        reloading = false
    }

    private func findPath(to url: URL, in nodes: [FileNode]) -> [FileNode]? {
        for node in nodes {
            if node.url.path == url.path { return [node] }
            if node.isDirectory, url.path.hasPrefix(node.url.path + "/"),
               let rest = findPath(to: url, in: node.children) {
                return [node] + rest
            }
        }
        return nil
    }

    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, node.isDirectory else { return }
        // 点文件夹这一行就展开 / 收起。
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: - 数据源

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        cell.textField?.stringValue = node.isDirectory ? node.name : displayName(node.name)
        let dateLabel = (cell as? FileCell)?.date
        if !node.isDirectory, let date = modificationDate(node.url) {
            dateLabel?.stringValue = Self.timeLabel(for: date)
            cell.toolTip = "\(node.name)\n修改于 \(date.formatted(date: .long, time: .shortened))"
        } else {
            dateLabel?.stringValue = ""
            cell.toolTip = node.name
        }
        cell.imageView?.image = NSImage(
            systemSymbolName: node.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil
        )
        return cell
    }

    /// 常见的 .md 扩展名不显示，名字更干净。
    private func displayName(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in [".md", ".markdown"] where lower.hasSuffix(ext) && lower.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    private final class FileCell: NSTableCellView {
        let date = NSTextField(labelWithString: "")
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = FileCell()
        cell.identifier = id
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentTintColor = .secondaryLabelColor
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        let date = cell.date
        date.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        date.textColor = .secondaryLabelColor
        date.alignment = .right
        date.translatesAutoresizingMaskIntoConstraints = false
        // 窄的时候先截文件名，时间完整显示。
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.addSubview(date)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            date.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            date.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            date.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
        ])
        return cell
    }

    // MARK: - 选择和展开

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory else { return }
        selected = node.url
        onSelect?(node.url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode { expanded.insert(node.url) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !reloading, let node = notification.userInfo?["NSObject"] as? FileNode { expanded.remove(node.url) }
    }
}
