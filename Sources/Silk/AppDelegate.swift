import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windows: [WorkspaceWindowController] = []
    private var openedAtLaunch = false

    private static let lastOpenedKey = "lastOpenedPath"

    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugHooks.log("开始启动")
        NSApp.mainMenu = MainMenu.make()
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "窗口")?.submenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.installIfNeeded()
        DebugHooks.log("启动完成")
        // 从 Finder 双击打开时，application(_:open:) 会先于这里被调用。
        guard !openedAtLaunch, windows.isEmpty else { return }
        if let path = UserDefaults.standard.string(forKey: Self.lastOpenedKey),
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else {
            openDocument(nil)
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
        if !flag && windows.isEmpty { openDocument(nil) }
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
            if waiting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        step()
        if waiting { return .terminateLater }
        return cancelled ? .terminateCancel : .terminateNow
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

        if isDirectory.boolValue {
            if let existing = windows.first(where: { $0.workspace.root.path == url.path }) {
                existing.showWindow(nil)
            } else {
                makeWindow(root: url, file: nil)
            }
        } else if let existing = windows.first(where: { $0.workspace.contains(url) }) {
            existing.showWindow(nil)
            existing.openFile(url, fragment: fragment)
        } else {
            makeWindow(root: url.deletingLastPathComponent(), file: url, fragment: fragment)
        }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        UserDefaults.standard.set(url.path, forKey: Self.lastOpenedKey)
    }

    private func makeWindow(root: URL, file: URL?, fragment: String? = nil) {
        let controller = WorkspaceWindowController(root: root, initialFile: file, fragment: fragment)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
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
