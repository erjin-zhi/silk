import AppKit

/// 侧栏文件树：只显示 Markdown 文件和含有它们的文件夹。
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var root: FileNode?
    private var expanded: Set<URL> = []
    private var selected: URL?
    private var reloading = false

    var onSelect: ((URL) -> Void)?

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
        view.addSubview(scroll)

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
        ])
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
        cell.textField?.toolTip = node.name
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

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentTintColor = .secondaryLabelColor
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
