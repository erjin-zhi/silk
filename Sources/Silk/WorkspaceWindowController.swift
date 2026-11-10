import AppKit

/// 一个窗口：左边文件树，右边文档。草稿窗口没有文件树，打开就能写。
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let workspace: Workspace
    /// 草稿窗口：文档是 App 数据目录里的草稿，还没存到用户选的位置。
    let isDraft: Bool
    private let splitController = NSSplitViewController()
    private let sidebar = SidebarViewController()
    let docView = DocumentViewController()
    private var modeGroup: NSToolbarItemGroup?
    private var initialFile: URL?
    private var scanned = false
    private lazy var quickOpenPanel = QuickOpenPanel()
    private(set) lazy var searchPanel = FolderSearchPanel()

    var onClose: (() -> Void)?
    /// 窗口里打开的文件变了，App 记下来，下次启动恢复。
    var onStateChange: (() -> Void)?
    /// 草稿存到了新位置，交给 App 用普通窗口打开它。
    var onDraftSaved: ((URL) -> Void)?
    /// 侧栏点了「新建」，参数是从哪个窗口新建的。
    var onNewDraft: ((WorkspaceWindowController) -> Void)?

    enum DraftChoice { case save, delete, cancel }

    /// 关闭有内容的草稿时问用户。默认弹系统提示；测试里换成直接回答。
    lazy var promptForDraft: (@escaping (DraftChoice) -> Void) -> Void = { [weak self] answer in
        self?.showDraftAlert(answer)
    }

    /// 选草稿存到哪儿。默认弹存储面板；测试里换成直接给位置。
    lazy var chooseSaveLocation: (String, @escaping (URL?) -> Void) -> Void = { [weak self] name, done in
        self?.showSavePanel(suggestedName: name, done)
    }

    private let drafts: DraftStore
    /// 草稿存储时默认放到哪个文件夹：从哪个文件夹窗口新建的，就默认存回那里。
    var saveDirectory: URL?

    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let quickOpenItem = NSToolbarItem.Identifier("quickOpen")
    private static let newDraftItem = NSToolbarItem.Identifier("newDraft")

    init(root: URL, initialFile: URL?, fragment: String? = nil, draft: Bool = false, drafts: DraftStore = .standard) {
        workspace = Workspace(root: root)
        self.initialFile = initialFile
        self.isDraft = draft
        self.drafts = drafts

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
        // 草稿窗口收起侧栏，也不记侧栏状态（不然普通窗口的侧栏也跟着收起来）。
        if !draft { splitController.splitView.autosaveName = "SilkSidebar" }
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1180, height: 780))
        if draft {
            sidebarItem.isCollapsed = true
        } else if !hasSavedSidebar {
            splitController.splitView.setPosition(250, ofDividerAt: 0)
        }

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
        docView.onCompare = { [weak self] in self?.compareWithDisk(nil) }

        workspace.onTreeChange = { [weak self] in self?.treeDidChange() }
        workspace.onFilesChange = { [weak self] paths in
            self?.docView.filesDidChange(paths)
            self?.sidebar.filesDidChange(paths)
        }
        sidebar.onNew = { [weak self] in
            guard let self else { return }
            self.onNewDraft?(self)
        }
        workspace.start()

        updateTitle()
        if let initialFile { openFile(initialFile, fragment: fragment) }
        if draft {
            docView.autosaveWhileTyping = true
            // 草稿是用来写的：阅读模式下临时换成对照（不改掉用户平时的默认模式）。
            if docView.mode == .read { docView.setMode(.split, remember: false) }
        }
        DebugHooks.log("窗口已创建")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 文件

    /// then：真的打开了之后再做的事（比如跳到搜索结果那一行）。
    func openFile(_ url: URL, fragment: String? = nil, then: (() -> Void)? = nil) {
        docView.open(url, fragment: fragment) { [weak self] opened in
            guard let self else { return }
            // 没切过去（当前文档的修改存不下来、用户取消了）：侧栏选中项退回当前文件。
            guard opened else {
                if let current = self.docView.fileURL { self.sidebar.select(current) }
                return
            }
            self.sidebar.select(url)
            self.updateTitle()
            if !self.isDraft { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            self.quickOpenPanel.noteOpened(url)
            self.onStateChange?()
            then?()
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
        if isDraft {
            window.title = "未命名"
            window.subtitle = "草稿"
            window.representedURL = nil
        } else if let file = docView.fileURL {
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

    @objc func saveDocument(_ sender: Any?) {
        if isDraft { saveDraftAs() } else { docView.saveIfNeeded() }
    }

    // MARK: - 草稿

    /// 草稿里有没有写东西。
    var draftIsEmpty: Bool {
        docView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 把草稿存到用户选的位置，之后它就是普通文件，草稿删掉。completion 收到是否存成了。
    func saveDraftAs(completion: ((Bool) -> Void)? = nil) {
        guard isDraft else { return completion?(false) ?? () }
        docView.saveIfNeeded()
        let text = docView.text
        chooseSaveLocation(DraftStore.suggestedName(for: text)) { [weak self] url in
            guard let self, let url else { return completion?(false) ?? () }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                self.window.map { NSAlert(error: error).beginSheetModal(for: $0) }
                return completion?(false) ?? ()
            }
            if let draft = self.docView.fileURL { self.drafts.delete(draft) }
            self.closeWithoutAsking = true
            self.window?.close()
            self.onDraftSaved?(url)
            completion?(true)
        }
    }

    /// 草稿已经存走或删掉了，关窗口时不用再问。
    private var closeWithoutAsking = false

    private func showSavePanel(suggestedName: String, _ done: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.directoryURL = saveDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let window else { return done(nil) }
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.url : nil) }
    }

    private func showDraftAlert(_ answer: @escaping (DraftChoice) -> Void) {
        guard let window else { return answer(.cancel) }
        let alert = NSAlert()
        alert.messageText = "要存储这份草稿吗？"
        alert.informativeText = "不存储的话，草稿会被删除。"
        alert.addButton(withTitle: "存储…")
        alert.addButton(withTitle: "删除草稿")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.save)
            case .alertSecondButtonReturn: answer(.delete)
            default: answer(.cancel)
            }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([docView.fileURL ?? workspace.root])
    }

    @objc func printDocument(_ sender: Any?) {
        docView.printDocument { [weak self] result in
            if case .failure(let error) = result { self?.showError(error) }
        }
    }

    // MARK: - 导出

    @objc func exportHTML(_ sender: Any?) {
        chooseExportLocation("html") { [weak self] url in
            self?.docView.exportHTML { result in
                do {
                    try Data(result.get().utf8).write(to: url, options: .atomic)
                } catch {
                    self?.showError(error)
                }
            }
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        chooseExportLocation("pdf") { [weak self] url in
            self?.docView.printDocument(toPDF: url) { result in
                switch result {
                case .success(true): break
                case .success(false): self?.showError(CocoaError(.fileWriteUnknown))
                case .failure(let error): self?.showError(error)
                }
            }
        }
    }

    /// 选导出到哪儿。默认弹存储面板；测试里换成直接给位置。
    lazy var chooseExportLocation: (String, @escaping (URL) -> Void) -> Void = { [weak self] ext, done in
        self?.showExportPanel(extension: ext, done)
    }

    private func showExportPanel(extension ext: String, _ done: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = isDraft ? DraftStore.suggestedName(for: docView.text) : (docView.fileURL?.lastPathComponent ?? "未命名")
        panel.nameFieldStringValue = (base as NSString).deletingPathExtension + "." + ext
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.canCreateDirectories = true
        panel.directoryURL = isDraft
            ? (saveDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            : docView.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            done(url)
        }
    }

    private func showError(_ error: any Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - 与磁盘版本比较

    @objc func compareWithDisk(_ sender: Any?) {
        guard !isDraft, let url = docView.fileURL, let window, window.attachedSheet == nil else { return }
        let sheet = DiffSheet(fileName: url.lastPathComponent, disk: docView.diskText(), mine: docView.text) { [weak self] choice in
            switch choice {
            case .keepMine: self?.docView.keepMyChanges()
            case .loadDisk: self?.docView.loadDiskVersion()
            case .close: break
            }
        }
        window.contentViewController?.presentAsSheet(sheet)
    }

    // MARK: - 在文件夹中搜索

    @objc func findInFolder(_ sender: Any?) {
        guard !isDraft, let window else { return }
        // 编辑器里选了一小段（一行以内）就直接搜它。
        let selected = docView.selectedText
        let query = selected.count <= 200 && !selected.contains("\n") ? selected : nil
        searchPanel.show(over: window, workspace: workspace, query: query) { [weak self] match, query in
            self?.openSearchResult(match, query: query)
        }
    }

    func openSearchResult(_ match: FolderSearch.Match, query: String) {
        // 搜的词放进查找粘贴板，回到源码里按 ⌘G 就能接着找下一个。
        let find = NSPasteboard(name: .find)
        find.clearContents()
        find.setString(query, forType: .string)
        openFile(match.url) { [weak self] in
            self?.docView.reveal(line: match.line, range: match.range)
        }
    }

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
        case #selector(saveDocument(_:)):
            menuItem.title = isDraft ? "存储…" : "存储"
            return isDraft || docView.isDirty
        case #selector(revealInFinder(_:)): return !isDraft
        case #selector(printDocument(_:)), #selector(exportHTML(_:)), #selector(exportPDF(_:)): return docView.fileURL != nil
        case #selector(compareWithDisk(_:)): return !isDraft && docView.fileURL != nil
        case #selector(findInFolder(_:)): return !isDraft
        default: break
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isDraft && !closeWithoutAsking {
            // 空草稿直接关（关掉时删）；写了东西的问一下存不存。
            if draftIsEmpty { return true }
            docView.saveIfNeeded()
            promptForDraft { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .save:
                    self.saveDraftAs()
                case .delete:
                    if let draft = self.docView.fileURL { self.drafts.delete(draft) }
                    self.closeWithoutAsking = true
                    self.window?.close()
                case .cancel:
                    break
                }
            }
            return false
        }
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
        if isDraft, draftIsEmpty, let draft = docView.fileURL {
            drafts.delete(draft)
        } else if !closeWithoutAsking {
            docView.saveIfNeeded()
        }
        workspace.stop()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        docView.saveIfNeeded()
    }

    // MARK: - 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem, .flexibleSpace, Self.quickOpenItem, Self.newDraftItem]
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
        case Self.newDraftItem:
            // 和「备忘录」「邮件」的新建按钮同一个图标，一眼能看出是新建。
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "新建草稿")
            item.label = "新建"
            item.toolTip = "新建草稿（⌘N）"
            item.target = NSApp.delegate
            item.action = #selector(AppDelegate.newDraft(_:))
            return item
        default:
            return nil
        }
    }
}
