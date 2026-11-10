import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windows: [WorkspaceWindowController] = []
    private var openedAtLaunch = false
    /// 确定要退出了。退出时 AppKit 还会把窗口一个个关掉，这时不能再改记下的状态，不然下次就恢复成空的了。
    private(set) var terminating = false
    private let defaults: UserDefaults
    let drafts: DraftStore

    /// 退出时开着的窗口，下次启动照原样打开。
    static let stateKey = "openWindows"
    /// 旧版本只记最后打开的一个路径，第一次升级时用它恢复。
    private static let lastOpenedKey = "lastOpenedPath"

    init(defaults: UserDefaults = .standard, drafts: DraftStore = .standard) {
        self.defaults = defaults
        self.drafts = drafts
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugHooks.log("开始启动")
        NSApp.mainMenu = MainMenu.make()
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "窗口")?.submenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.installIfNeeded()
        DebugHooks.log("启动完成")
        // 从 Finder 双击打开时，application(_:open:) 会先于这里被调用，就只打开那个文件。
        guard !openedAtLaunch, windows.isEmpty else { return }
        restoreLastSession()
    }

    // MARK: - 启动时恢复

    /// 恢复上次退出时开着的窗口（文件夹、文件、草稿）；没有可恢复的，就开一份空白草稿。
    /// 上次没存走、也没删掉的草稿（比如 App 崩溃了）也一并打开，写的东西不会丢。
    func restoreLastSession() {
        var entries = defaults.array(forKey: Self.stateKey) as? [[String: String]]
        if entries == nil, let path = defaults.string(forKey: Self.lastOpenedKey) {
            entries = [["path": path]]
        }
        for entry in entries ?? [] {
            if let path = entry["draft"] {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path), drafts.contains(url) { makeDraftWindow(url) }
            } else if let root = entry["root"] {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let file = entry["file"].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                makeWindow(root: URL(fileURLWithPath: root), file: file)
            } else if let path = entry["path"], FileManager.default.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path))
            }
        }

        let open = Set(windows.compactMap { $0.isDraft ? $0.docView.fileURL?.standardizedFileURL.path : nil })
        for draft in drafts.all() where !open.contains(draft.standardizedFileURL.path) {
            if DraftStore.isEmpty(draft) { drafts.delete(draft) } else { makeDraftWindow(draft) }
        }
        if windows.isEmpty { newDraft(nil) }
        saveState()
    }

    /// 把现在开着的窗口记下来。
    func saveState() {
        guard !terminating else { return }
        let entries: [[String: String]] = windows.compactMap { window in
            if window.isDraft {
                return window.docView.fileURL.map { ["draft": $0.path] }
            }
            var entry = ["root": window.workspace.root.path]
            if let file = window.docView.fileURL { entry["file"] = file.path }
            return entry
        }
        defaults.set(entries, forKey: Self.stateKey)
    }

    // MARK: - 草稿

    /// 新建一份空白草稿。
    /// 从文件夹窗口里新建的（侧栏按钮、工具栏按钮、⌘N），存储时默认存回那个文件夹。
    @objc func newDraft(_ sender: Any?) {
        let from = (sender as? WorkspaceWindowController)
            ?? windows.first { $0.window === NSApp.keyWindow || $0.window === NSApp.mainWindow }
        do {
            makeDraftWindow(try drafts.create(), saveDirectory: from?.isDraft == false ? from?.workspace.root : nil)
            saveState()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func makeDraftWindow(_ file: URL, saveDirectory: URL? = nil) {
        let controller = WorkspaceWindowController(
            root: file.deletingLastPathComponent(), initialFile: file, draft: true, drafts: drafts
        )
        controller.saveDirectory = saveDirectory
        controller.onDraftSaved = { [weak self] url in self?.open(url) }
        add(controller)
    }

    /// 打开了真正的文件后，没动过的空白草稿窗口就没用了，顺手关掉（和「文本编辑」一样）。
    private func closeUntouchedDrafts(except keep: WorkspaceWindowController?) {
        for window in windows where window.isDraft && window !== keep && window.draftIsEmpty {
            window.window?.close()
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        urls.forEach { open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 窗口都关了，点 Dock 图标：开一份空白草稿，而不是弹打开面板。
        if !flag && windows.isEmpty { newDraft(nil) }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        windows.forEach { $0.saveIfNeeded() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 逐个窗口确认：存得下来的直接存；存不下来的弹窗问用户，等回答再接着看下一个，有一个取消就不退出。
        var remaining = windows[...]
        var waiting = false
        var cancelled = false
        func step() {
            while let window = remaining.popFirst() {
                var answer: Bool?
                var asked = false
                window.confirmClosing { ok in
                    answer = ok
                    guard asked else { return }
                    if ok { step() } else { NSApp.reply(toApplicationShouldTerminate: false) }
                }
                if answer == nil {
                    asked = true
                    waiting = true
                    return
                }
                if answer == false {
                    if waiting { NSApp.reply(toApplicationShouldTerminate: false) }
                    cancelled = true
                    return
                }
            }
            if waiting {
                terminating = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        // 先记下开着的窗口：退出时窗口不会一个个关掉，记下的就是下次要恢复的。
        saveState()
        step()
        if waiting { return .terminateLater }
        if cancelled { return .terminateCancel }
        terminating = true
        return .terminateNow
    }

    // MARK: - 打开

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择 Markdown 文件或文件夹"
        panel.prompt = "打开"
        panel.allowedContentTypes = MarkdownFiles.contentTypes
        // 不用 runModal：面板开着时，从 Finder 拖进来或双击的文件也能正常打开。
        panel.begin { [weak self, weak panel] response in
            guard response == .OK, let urls = panel?.urls else { return }
            urls.forEach { self?.open($0) }
        }
    }

    func open(_ url: URL, fragment: String? = nil) {
        let url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }

        // 草稿窗口不算工作区：别的文件不会开进草稿窗口里。
        let folders = windows.filter { !$0.isDraft }
        let target: WorkspaceWindowController?
        if isDirectory.boolValue {
            if let existing = folders.first(where: { $0.workspace.root.path == url.path }) {
                existing.showWindow(nil)
                target = existing
            } else {
                target = makeWindow(root: url, file: nil)
            }
        } else if let existing = folders.first(where: { $0.workspace.contains(url) }) {
            existing.showWindow(nil)
            existing.openFile(url, fragment: fragment)
            target = existing
        } else {
            target = makeWindow(root: url.deletingLastPathComponent(), file: url, fragment: fragment)
        }

        closeUntouchedDrafts(except: target)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        saveState()
    }

    @discardableResult
    private func makeWindow(root: URL, file: URL?, fragment: String? = nil) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(root: root, initialFile: file, fragment: fragment, drafts: drafts)
        add(controller)
        return controller
    }

    private func add(_ controller: WorkspaceWindowController) {
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
            self?.saveState()
        }
        controller.onStateChange = { [weak self] in self?.saveState() }
        controller.onNewDraft = { [weak self] from in self?.newDraft(from) }
        windows.append(controller)
        controller.showWindow(nil)
        if controller.isDraft { controller.docView.focusEditor() }
    }
}

/// 让「打开最近使用」菜单走我们自己的打开逻辑（Silk 不用 NSDocument）。
final class SilkDocumentController: NSDocumentController {
    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.open(url)
        }
        completionHandler(nil, false, nil)
    }
}
