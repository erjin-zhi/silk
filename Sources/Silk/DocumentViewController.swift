import AppKit

/// 右侧文档区：源码编辑器 + 预览，三种模式，滚动对照，读写文件。
@MainActor
final class DocumentViewController: NSViewController, NSTextViewDelegate {
    private let split = NSSplitViewController()
    private var editorItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private let editor: EditorView
    private let preview = PreviewController()
    private let banner = ChangeBanner()

    /// 当前文档和磁盘的关系（编码、冲突、能不能自动保存）。
    private var session: DocumentSession?
    var fileURL: URL? { session?.url }
    private(set) var isDirty = false {
        didSet { onDirtyChange?(isDirty) }
    }
    private(set) var mode: ViewMode
    private var zoom: CGFloat

    /// 预览顶部所在的行，切模式和回到这个文件时用。
    private var previewTopLine: Double = 0
    /// 每个文件上次看到的位置。
    private var positions: [URL: Double] = [:]
    /// 最近一次用户在操作哪一边，避免两边互相推着滚。
    private var editorDrivingUntil: TimeInterval = 0

    var onDirtyChange: ((Bool) -> Void)?
    var onModeChange: ((ViewMode) -> Void)?
    var onOpenLink: ((URL, String?) -> Void)?
    /// 文件被删除、保存失败等需要告诉窗口的状态变化。
    var onSessionChange: (() -> Void)?

    private static let modeKey = "viewMode"
    private static let zoomKey = "zoom"

    init() {
        mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .read
        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        zoom = savedZoom > 0 ? savedZoom : 1
        editor = EditorView(fontSize: 13 * zoom)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()

        let editorVC = NSViewController()
        editorVC.view = editor
        let previewVC = NSViewController()
        previewVC.view = preview.webView

        editorItem = NSSplitViewItem(viewController: editorVC)
        editorItem.canCollapse = true
        editorItem.minimumThickness = 240
        editorItem.holdingPriority = .init(260)
        previewItem = NSSplitViewItem(viewController: previewVC)
        previewItem.canCollapse = true
        previewItem.minimumThickness = 240
        previewItem.holdingPriority = .init(260)
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(editorItem)
        split.addSplitViewItem(previewItem)
        addChild(split)

        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        editor.textView.delegate = self
        editor.textView.isEditable = false
        editor.onScroll = { [weak self] line in self?.editorDidScroll(line) }
        preview.onScroll = { [weak self] line in self?.previewDidScroll(line) }
        preview.onClick = { [weak self] line in self?.previewDidClick(line) }
        preview.onLink = { [weak self] url, wiki in self?.onOpenLink?(url, wiki) }
        preview.setZoom(zoom)
        banner.onPrimary = { [weak self] in self?.bannerPrimary() }
        banner.onSecondary = { [weak self] in self?.bannerSecondary() }
        banner.onTertiary = { [weak self] in self?.onCompare?() }

        applyMode(animated: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 预览内容能滚到玻璃工具栏下面，但起始位置让开工具栏。
        let top = view.safeAreaInsets.top
        if preview.webView.obscuredContentInsets.top != top {
            preview.webView.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    }

    // MARK: - 文件

    /// 打开文件。当前文档有没存下来的修改时先保存；存不下来（失败或磁盘上有冲突）就问用户，
    /// 用户取消则不切换，completion 收到 false。
    func open(_ url: URL, fragment: String? = nil, completion: ((Bool) -> Void)? = nil) {
        if url.path == fileURL?.path {
            if let fragment { scrollToFragment(fragment) }
            completion?(true)
            return
        }
        // 差异对照还开着（比如在 Finder 里又双击了同一文件夹里的文件）：不换文档。
        // 换了的话，表单上的「存储我的修改」「载入磁盘版本」会落到另一份文件上。
        if comparing != nil {
            NSSound.beep()
            view.window?.makeKeyAndOrderFront(nil)
            completion?(false)
            return
        }
        confirmLeaving { [weak self] ok in
            guard let self, ok else {
                completion?(false)
                return
            }
            // 先载入再回调：写成 completion?(load(...)) 的话，没传 completion 时 load 根本不会执行。
            let loaded = self.load(url, fragment: fragment)
            completion?(loaded)
        }
    }

    /// 最近一次要求跳到的页内锚点（测试用来确认锚点有没有传到）。
    private(set) var lastFragment: String?

    private func load(_ url: URL, fragment: String?) -> Bool {
        guard let session = try? DocumentSession(url: url) else {
            NSSound.beep()
            return false
        }
        if let current = fileURL { positions[current] = previewTopLine }
        self.session = session
        isDirty = false
        hideBanner()
        editor.textView.isEditable = true
        editor.setText(session.text)
        let line = positions[url] ?? 0
        previewTopLine = line
        lastFragment = fragment
        preview.setDocument(session.text, base: url.deletingLastPathComponent(), line: line, hash: fragment)
        if mode != .read { editor.scrollToLine(line) }
        return true
    }

    func scrollToFragment(_ fragment: String) {
        lastFragment = fragment
        preview.scrollToId(fragment)
    }

    func showPlaceholder(_ message: String) {
        session = nil
        isDirty = false
        hideBanner()
        editor.setText("")
        editor.textView.isEditable = false
        preview.setDocument("> " + message, base: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - 保存

    /// 自动保存（切走窗口、App 进后台、⌘S）。存不下来时不打断用户，在顶部提示。
    func saveIfNeeded() {
        guard isDirty, comparing == nil, let session else { return }
        handle(session.save(editor.string))
    }

    /// 离开当前文档前（切换文件、关窗口、退出）：能存就存；存不下来就问用户，proceed 收到是否可以离开。
    func confirmLeaving(_ proceed: @escaping (Bool) -> Void) {
        guard isDirty, let session else { return proceed(true) }
        // 已经有一个确认框在等回答（比如 Finder 里又双击了一个文件）：不再排第二个框，这次请求作罢。
        // 排队的旧框答复时，当前文档可能已经换了，会把回答用到别的文件上。
        if leavePromptOpen {
            NSSound.beep()
            view.window?.makeKeyAndOrderFront(nil)
            return proceed(false)
        }
        let result = session.save(editor.string)
        handle(result)
        if result.isDone { return proceed(true) }
        askBeforeLeaving(result, about: session, proceed)
    }

    /// 是否有离开确认框正在等用户回答。
    private(set) var leavePromptOpen = false

    private func handle(_ result: DocumentSession.SaveResult) {
        switch result {
        case .saved, .unchanged:
            isDirty = false
            hideBanner()
        case .conflict(let conflict):
            showConflict(conflict)
        case .failed(let message):
            banner.show(message: "存储失败：\(message)", primary: "再试一次", secondary: nil)
            bannerState = .failed
        }
        onSessionChange?()
    }

    enum LeaveChoice { case retry, discard, cancel }

    /// 问用户怎么处理存不下来的修改。默认弹系统提示；测试里换成直接回答。
    lazy var promptForLeaving: (DocumentSession.SaveResult, @escaping (LeaveChoice) -> Void) -> Void = { [weak self] result, answer in
        self?.showLeaveAlert(result, answer)
    }

    private func askBeforeLeaving(
        _ result: DocumentSession.SaveResult, about session: DocumentSession, _ proceed: @escaping (Bool) -> Void
    ) {
        leavePromptOpen = true
        promptForLeaving(result) { [weak self] choice in
            guard let self else { return proceed(false) }
            self.leavePromptOpen = false
            // 回答只对弹框时问的那个文档有效；文档已经换了就什么都不做。
            guard self.session === session else { return proceed(false) }
            switch choice {
            case .retry:
                // 冲突时「再试」就是用户确认用自己的修改覆盖；保存失败时就是再存一次。
                let retry: DocumentSession.SaveResult
                if case .conflict = result { retry = session.overwrite(with: self.editor.string) } else { retry = session.save(self.editor.string) }
                self.handle(retry)
                if retry.isDone { proceed(true) } else { self.askBeforeLeaving(retry, about: session, proceed) }
            case .discard:
                // 编辑器也退回磁盘版本：接下来不一定真的离开（比如退出时另一个窗口选了取消），
                // 放弃了的修改不能还留在编辑器里，看着像存了，下次一改又会被写回去。
                let text = session.discardChanges()
                if text != self.editor.string {
                    self.editor.replaceKeepingPosition(with: text)
                    self.preview.update(text)
                }
                self.isDirty = false
                self.hideBanner()
                proceed(true)
            case .cancel:
                proceed(false)
            }
        }
    }

    private func showLeaveAlert(_ result: DocumentSession.SaveResult, _ answer: @escaping (LeaveChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(fileURL?.lastPathComponent ?? "文档")」的修改还没存下来"
        switch result {
        case .conflict(.modified):
            alert.informativeText = "文件在磁盘上被别的程序改过了。用你的修改覆盖它，还是放弃你的修改？"
            alert.addButton(withTitle: "用我的修改覆盖")
        case .conflict(.deleted):
            alert.informativeText = "文件在磁盘上被删除或移走了。要用你的内容重新存一份吗？"
            alert.addButton(withTitle: "重新存储")
        case .failed(let message):
            alert.informativeText = "存储失败：\(message)"
            alert.addButton(withTitle: "再试一次")
        default:
            return answer(.discard)
        }
        alert.addButton(withTitle: "放弃我的修改")
        alert.addButton(withTitle: "取消")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: answer(.retry)
            case .alertSecondButtonReturn: answer(.discard)
            default: answer(.cancel)
            }
        }
        if let window = view.window {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    // MARK: - 磁盘上的变化

    private enum BannerState { case hidden, conflict, failed }
    private var bannerState = BannerState.hidden

    /// 文件夹里有文件变了。
    func filesDidChange(_ paths: Set<String>) {
        guard let session, let url = fileURL, MarkdownFiles.paths(paths, mention: url) else { return }
        switch session.diskDidChange(editorText: editor.string, isDirty: isDirty) {
        case .none:
            if session.conflict == nil, bannerState == .conflict { hideBanner() }
            if !isDirty || session.text == editor.string { isDirty = false }
        case .reloaded(let text):
            editor.replaceKeepingPosition(with: text)
            isDirty = false
            preview.update(text)
        case .conflict(let conflict):
            showConflict(conflict)
        }
    }

    private func showConflict(_ conflict: DocumentSession.Conflict) {
        switch conflict {
        case .modified:
            banner.show(message: "文件在磁盘上被修改了，你的修改还没存", primary: "保留我的修改", secondary: "载入磁盘版本", tertiary: "比较…")
        case .deleted:
            banner.show(message: "文件在磁盘上被删除或移走了", primary: "重新存储", secondary: nil)
        }
        bannerState = .conflict
    }

    private func hideBanner() {
        banner.isHidden = true
        bannerState = .hidden
    }

    private func bannerPrimary() {
        guard let session else { return }
        switch bannerState {
        case .conflict: handle(session.overwrite(with: editor.string))
        case .failed: handle(session.save(editor.string))
        case .hidden: break
        }
    }

    private func bannerSecondary() {
        guard let session, bannerState == .conflict, let text = session.takeDiskVersion() else { return }
        editor.replaceKeepingPosition(with: text)
        isDirty = false
        hideBanner()
        preview.update(text)
    }

    // MARK: - 模式

    /// remember：是否记成以后打开文档的默认模式。草稿临时切到能编辑的模式时不记。
    func setMode(_ newMode: ViewMode, remember: Bool = true) {
        guard newMode != mode else { return }
        let old = mode
        mode = newMode
        if remember { UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey) }
        applyMode(animated: false)

        // 切过去时，让新露出来的那一边对齐到原来正在看的位置。
        if old == .read && newMode != .read {
            editor.scrollToLine(previewTopLine)
        } else if old == .source && newMode != .source {
            let line = editor.topLine
            previewTopLine = line
            preview.scrollToLine(line)
        }
        if newMode != .read {
            view.window?.makeFirstResponder(editor.textView)
            if newMode == .split { preview.highlightLine(editor.caretLine) }
        } else {
            view.window?.makeFirstResponder(preview.webView)
        }
        onModeChange?(newMode)
    }

    private func applyMode(animated: Bool) {
        editorItem.isCollapsed = mode == .read
        previewItem.isCollapsed = mode == .source
        preview.setMode(mode)
        if mode == .split {
            let width = split.splitView.bounds.width
            if width > 0 { split.splitView.setPosition(width / 2, ofDividerAt: 0) }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mode == .split {
            split.splitView.setPosition(split.splitView.bounds.width / 2, ofDividerAt: 0)
        }
    }

    // MARK: - 缩放

    func changeZoom(by step: Int) {
        let levels: [CGFloat] = [0.75, 0.85, 0.92, 1, 1.1, 1.2, 1.35, 1.5, 1.75, 2]
        let index = levels.firstIndex { $0 >= zoom - 0.001 } ?? 3
        zoom = step == 0 ? 1 : levels[max(0, min(levels.count - 1, index + step))]
        UserDefaults.standard.set(zoom, forKey: Self.zoomKey)
        preview.setZoom(zoom)
        editor.setFontSize(13 * zoom)
    }

    // MARK: - 打印与导出

    /// 正在打印 / 导出 PDF 时用的排版器，完成前要留着。
    private var printRenderer: PrintRenderer?

    /// 文档标题：正文没有一级标题时用文件名。
    private var exportFallbackTitle: String {
        fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? "未命名"
    }

    /// 生成完整的导出 HTML。destination 是要存到的文件，本地链接按它改成相对地址；打印、PDF 不给。
    func exportHTML(destination: URL? = nil, _ completion: @escaping (Result<String, any Error>) -> Void) {
        let fallback = exportFallbackTitle
        preview.exportBody { result in
            completion(result.map { HTMLExport.document($0, fallbackTitle: fallback, destination: destination) })
        }
    }

    /// 打印（pdf 为 nil）或直接存成 PDF。completion 收到是否成功（用户在打印面板里取消也算没成功）。
    func printDocument(toPDF pdf: URL? = nil, completion: ((Result<Bool, any Error>) -> Void)? = nil) {
        guard let window = view.window, printRenderer == nil else { return }
        exportHTML { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion?(.failure(error))
            case .success(let html):
                let renderer = PrintRenderer()
                self.printRenderer = renderer
                Task { @MainActor [weak self] in
                    do {
                        try await renderer.load(html)
                    } catch {
                        self?.printRenderer = nil
                        completion?(.failure(error))
                        return
                    }
                    renderer.run(for: window, pdf: pdf) { [weak self] ok in
                        self?.printRenderer = nil
                        completion?(.success(ok))
                    }
                }
            }
        }
    }

    // MARK: - 与磁盘版本比较

    /// 磁盘上现在的内容；读不到（被删了、没权限）时为 nil。
    func diskText() -> String? {
        guard let url = fileURL else { return nil }
        return try? TextFile.read(url).text
    }

    /// 用户看过差异后选了「存储我的修改」：用编辑器里的内容覆盖磁盘。
    func keepMyChanges() {
        guard let session else { return }
        handle(session.overwrite(with: editor.string))
    }

    /// 用户看过差异后选了「载入磁盘版本」。
    func loadDiskVersion() {
        guard let session else { return }
        guard let text = session.takeDiskVersion() else { return NSSound.beep() }
        editor.replaceKeepingPosition(with: text)
        isDirty = false
        hideBanner()
        preview.update(text)
    }

    /// 差异对照正开着的那份文档；nil 表示没在比较。
    /// 开着期间不自动保存（表单一盖上来窗口就失去焦点，会触发「切走窗口就存」，用户还没决定留哪一边，
    /// 磁盘原文就先被覆盖了），也不换文档。
    private var comparing: DocumentSession?
    var isComparing: Bool { comparing != nil }

    /// 打开差异对照前调用：记下比的是哪一份。
    func beginComparing() {
        comparing = session
    }

    /// 差异对照关了。用户的选择只用在当初比的那一份上；文档已经不是那一份了就不动。
    func finishComparing(_ choice: DiffSheet.Choice) {
        let compared = comparing
        comparing = nil
        guard let compared, compared === session else {
            if choice != .close { NSSound.beep() }
            return
        }
        switch choice {
        case .keepMine: keepMyChanges()
        case .loadDisk: loadDiskVersion()
        case .close: break
        }
    }

    /// 横幅上点了「比较」。
    var onCompare: (() -> Void)?

    // MARK: - 搜索结果

    /// 跳到搜索结果：预览滚过去闪一下；能编辑的模式下源码里选中命中的文字。
    func reveal(line: Int, range: NSRange) {
        if mode != .read {
            editor.select(range)
            view.window?.makeFirstResponder(editor.textView)
        }
        previewTopLine = Double(line)
        preview.reveal(line: line)
    }

    // MARK: - 对照

    private func editorDidScroll(_ line: Double) {
        editorDrivingUntil = ProcessInfo.processInfo.systemUptime + 0.2
        guard mode == .split else { return }
        previewTopLine = line
        preview.scrollToLine(line)
    }

    private func previewDidScroll(_ line: Double) {
        previewTopLine = line
        guard mode == .split, ProcessInfo.processInfo.systemUptime > editorDrivingUntil else { return }
        editor.scrollToLine(line)
    }

    private func previewDidClick(_ line: Int) {
        guard mode == .split else { return }
        editor.moveCaret(toLine: line)
        view.window?.makeFirstResponder(editor.textView)
    }

    /// 编辑器里现在的全文。
    var text: String { editor.string }

    /// 编辑器里选中的文字（阅读模式下没有）。
    var selectedText: String {
        guard mode != .read else { return "" }
        return (editor.string as NSString).substring(with: editor.textView.selectedRange())
    }

    /// 光标放进编辑器，可以直接打字。
    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    /// 打字停下一会儿就自动保存。草稿用：草稿没有「切走窗口才存」的习惯，崩溃时也不能丢。
    var autosaveWhileTyping = false
    private var autosaveWork: DispatchWorkItem?

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = true
        preview.update(editor.string)
        if autosaveWhileTyping {
            autosaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveIfNeeded() } }
            autosaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard mode == .split, fileURL != nil else { return }
        preview.highlightLine(editor.caretLine)
    }
}

/// 浮在顶部的提示：磁盘冲突、保存失败。
@MainActor
final class ChangeBanner: NSView {
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onTertiary: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let tertiary = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(primary, #selector(primaryTapped)), (secondary, #selector(secondaryTapped)), (tertiary, #selector(tertiaryTapped))] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.action = action
        }

        let stack = NSStackView(views: [label, tertiary, secondary, primary])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        glass.contentView = stack
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(message: String, primary primaryTitle: String, secondary secondaryTitle: String?, tertiary tertiaryTitle: String? = nil) {
        label.stringValue = message
        primary.title = primaryTitle
        secondary.title = secondaryTitle ?? ""
        secondary.isHidden = secondaryTitle == nil
        tertiary.title = tertiaryTitle ?? ""
        tertiary.isHidden = tertiaryTitle == nil
        isHidden = false
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func secondaryTapped() { onSecondary?() }
    @objc private func tertiaryTapped() { onTertiary?() }
}
