import AppKit

/// 一个窗口：左边文件树，右边文档。
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let workspace: Workspace
    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    let docView = DocumentViewController()
    private var modeGroup: NSToolbarItemGroup?
    private var initialFile: URL?
    private var scanned = false
    private lazy var quickOpenPanel = QuickOpenPanel()

    var onClose: (() -> Void)?

    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let quickOpenItem = NSToolbarItem.Identifier("quickOpen")

    init(root: URL, initialFile: URL?, fragment: String? = nil) {
        workspace = Workspace(root: root)
        self.initialFile = initialFile

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: docView)
        contentItem.minimumThickness = 360
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        let hasSavedSidebar = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames SilkSidebar") != nil
        splitController.splitView.autosaveName = "SilkSidebar"
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1180, height: 780))
        if !hasSavedSidebar { splitController.splitView.setPosition(250, ofDividerAt: 0) }

        let toolbar = NSToolbar(identifier: "SilkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.modeItem]
        window.toolbar = toolbar
        window.delegate = self

        if !window.setFrameUsingName("SilkWindow") { window.center() }
        window.setFrameAutosaveName("SilkWindow")

        sidebar.onSelect = { [weak self] url in self?.openFile(url) }
        docView.onDirtyChange = { [weak self] dirty in self?.window?.isDocumentEdited = dirty }
        docView.onModeChange = { [weak self] mode in self?.updateModeControl(mode) }
        docView.onOpenLink = { [weak self] url, wiki in self?.openLink(url, wiki: wiki) }

        workspace.onTreeChange = { [weak self] in self?.treeDidChange() }
        workspace.onFilesChange = { [weak self] paths in self?.docView.filesDidChange(paths) }
        workspace.start()

        updateTitle()
        if let initialFile { openFile(initialFile, fragment: fragment) }
        DebugHooks.log("窗口已创建")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 文件

    func openFile(_ url: URL, fragment: String? = nil) {
        docView.open(url, fragment: fragment) { [weak self] opened in
            guard let self else { return }
            // 没切过去（当前文档的修改存不下来、用户取消了）：侧栏选中项退回当前文件。
            guard opened else {
                if let current = self.docView.fileURL { self.sidebar.select(current) }
                return
            }
            self.sidebar.select(url)
            self.updateTitle()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.quickOpenPanel.noteOpened(url)
        }
    }

    /// 关窗口、退出前：当前文档的修改存得下来就直接放行，存不下来问用户。
    func confirmClosing(_ proceed: @escaping (Bool) -> Void) {
        docView.confirmLeaving(proceed)
    }

    func saveIfNeeded() {
        docView.saveIfNeeded()
    }

    private func treeDidChange() {
        let firstScan = !scanned
        scanned = true
        sidebar.setTree(workspace.tree, scanned: true)
        if firstScan, docView.fileURL == nil {
            if let file = workspace.defaultFile {
                openFile(file)
            } else {
                docView.showPlaceholder("这个文件夹里还没有 Markdown 文件。")
            }
        }
        if let file = docView.fileURL { sidebar.select(file) }
    }

    private func updateTitle() {
        guard let window else { return }
        if let file = docView.fileURL {
            window.title = file.lastPathComponent
            let folder = workspace.relativePath(of: file.deletingLastPathComponent())
            let rootName = workspace.root.lastPathComponent
            window.subtitle = workspace.contains(file.deletingLastPathComponent()) ? "\(rootName)/\(folder)" : rootName
            window.representedURL = file
        } else {
            window.title = workspace.root.lastPathComponent
            window.subtitle = ""
            window.representedURL = workspace.root
        }
    }

    private func openLink(_ url: URL, wiki: String?) {
        if let wiki {
            // [[#标题]]：当前文件里的标题。
            if wiki.isEmpty, let fragment = url.fragment(percentEncoded: false) {
                docView.scrollToFragment(fragment)
            } else if let target = workspace.resolveWikiLink(wiki, from: docView.fileURL) {
                openFile(target, fragment: url.fragment(percentEncoded: false))
            } else {
                NSSound.beep()
            }
            return
        }
        switch url.scheme {
        case "silk-file":
            let file = URL(fileURLWithPath: url.path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
                NSSound.beep()
                return
            }
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else if MarkdownFiles.isMarkdown(file) {
                if workspace.contains(file) {
                    openFile(file, fragment: url.fragment(percentEncoded: false))
                } else {
                    (NSApp.delegate as? AppDelegate)?.open(file, fragment: url.fragment(percentEncoded: false))
                }
            } else {
                NSWorkspace.shared.open(file)
            }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 菜单动作

    @objc func saveDocument(_ sender: Any?) { docView.saveIfNeeded() }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([docView.fileURL ?? workspace.root])
    }

    @objc func printDocument(_ sender: Any?) { docView.printPreview() }

    @objc func showReadMode(_ sender: Any?) { docView.setMode(.read) }
    @objc func showSplitMode(_ sender: Any?) { docView.setMode(.split) }
    @objc func showSourceMode(_ sender: Any?) { docView.setMode(.source) }

    @objc func zoomIn(_ sender: Any?) { docView.changeZoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { docView.changeZoom(by: -1) }
    @objc func zoomReset(_ sender: Any?) { docView.changeZoom(by: 0) }

    @objc func quickOpen(_ sender: Any?) {
        guard let window else { return }
        quickOpenPanel.show(over: window, files: workspace.files, workspace: workspace) { [weak self] url in
            self?.openFile(url)
        }
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) {
        let modes: [ViewMode] = [.read, .split, .source]
        docView.setMode(modes[max(0, sender.selectedIndex)])
    }

    private func updateModeControl(_ mode: ViewMode) {
        modeGroup?.selectedIndex = [ViewMode.read, .split, .source].firstIndex(of: mode) ?? 0
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showReadMode(_:)): menuItem.state = docView.mode == .read ? .on : .off
        case #selector(showSplitMode(_:)): menuItem.state = docView.mode == .split ? .on : .off
        case #selector(showSourceMode(_:)): menuItem.state = docView.mode == .source ? .on : .off
        case #selector(saveDocument(_:)): return docView.isDirty
        case #selector(printDocument(_:)): return docView.fileURL != nil
        default: break
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard docView.isDirty else { return true }
        var decided: Bool?
        docView.confirmLeaving { [weak self] ok in
            if decided == nil {
                decided = ok  // 当场就存下来了
            } else if ok {
                self?.window?.close()  // 问过用户之后才关
            }
        }
        if let decided { return decided }
        decided = false
        return false
    }

    func windowWillClose(_ notification: Notification) {
        docView.saveIfNeeded()
        workspace.stop()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        docView.saveIfNeeded()
    }

    // MARK: - 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem, .flexibleSpace, Self.quickOpenItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case Self.modeItem:
            let images = ["book", "rectangle.split.2x1", "chevron.left.forwardslash.chevron.right"].map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
            }
            let group = NSToolbarItemGroup(
                itemIdentifier: id, images: images, selectionMode: .selectOne,
                labels: ["阅读", "对照", "源码"], target: self, action: #selector(modeChanged(_:))
            )
            group.label = "模式"
            group.subitems[0].toolTip = "阅读（⌘1）"
            group.subitems[1].toolTip = "对照（⌘2）"
            group.subitems[2].toolTip = "源码（⌘3）"
            modeGroup = group
            updateModeControl(docView.mode)
            return group
        case Self.quickOpenItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "快速打开")
            item.label = "快速打开"
            item.toolTip = "快速打开（⇧⌘O）"
            item.target = self
            item.action = #selector(quickOpen(_:))
            return item
        default:
            return nil
        }
    }
}
