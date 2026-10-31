import AppKit
import WebKit

/// 开发用：设置环境变量 SILK_DEBUG=1 启动后，可以用分布式通知让 App 截图、打开文件、切模式。
/// 不需要录屏权限，正式使用时不会启用。
///
///   通知名 com.erjinzhi.silk.debug，userInfo：
///   {"action": "snapshot", "path": "/tmp/a.png"}
///   {"action": "open", "path": "/some/file.md"}
///   {"action": "mode", "mode": "split"}
///   {"action": "previewScroll", "y": "1200"}  模拟用户滚预览
///   {"action": "editorScroll", "y": "800"}    模拟用户滚编辑器
///   {"action": "type", "text": "hello"}    在编辑器光标处输入
@MainActor
enum DebugHooks {
    /// 进程启动到现在的秒数。
    static var sinceLaunch: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1e6
    }

    static var enabled: Bool { ProcessInfo.processInfo.environment["SILK_DEBUG"] == "1" }

    static func log(_ message: String) {
        guard enabled else { return }
        let line = String(format: "[%.3f] ", sinceLaunch) + message + "\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/silk-debug.log") {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: "/tmp/silk-debug.log", atomically: true, encoding: .utf8)
        }
    }

    static func installIfNeeded() {
        guard enabled else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.erjinzhi.silk.debug"), object: nil, queue: .main
        ) { note in
            let info = (note.userInfo as? [String: String]) ?? [:]
            MainActor.assumeIsolated { handle(info) }
        }
    }

    private static func handle(_ info: [String: String]) {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        let window = candidates.first { $0.windowController is WorkspaceWindowController && $0.isVisible }
        let controller = window?.windowController as? WorkspaceWindowController
        switch info["action"] {
        case "snapshot":
            guard let window, let path = info["path"] else { return }
            Task { await snapshot(window, to: path) }
        case "open":
            if let path = info["path"] { (NSApp.delegate as? AppDelegate)?.open(URL(fileURLWithPath: path)) }
        case "mode":
            switch info["mode"] {
            case "read": controller?.showReadMode(nil)
            case "split": controller?.showSplitMode(nil)
            case "source": controller?.showSourceMode(nil)
            default: break
            }
        case "previewScroll":
            // 模拟用户滚预览：直接改滚动位置，不走 silk.scrollToLine 的防回环。
            if let y = info["y"], let web = findWebView(in: window?.contentView) {
                web.evaluateJavaScript("window.scrollTo(0, \(Double(y) ?? 0))")
            }
        case "editorScroll":
            // 模拟用户滚编辑器。
            if let y = info["y"], let editor = findEditor(in: window?.contentView) {
                editor.contentView.scroll(to: NSPoint(x: 0, y: Double(y) ?? 0))
                editor.reflectScrolledClipView(editor.contentView)
            }
        case "type":
            if let text = info["text"], let tv = findEditor(in: window?.contentView)?.textView {
                let started = CACurrentMediaTime()
                tv.insertText(text, replacementRange: tv.selectedRange())
                tv.layoutManager?.ensureLayout(forCharacterRange: tv.selectedRange())
                tv.displayIfNeeded()
                log(String(format: "原生按键处理：%.2f ms", (CACurrentMediaTime() - started) * 1000))
            }
        case "sidebarSnapshot":
            guard let path = info["path"], let outline = findOutline(in: window?.contentView),
                  let scroll = outline.enclosingScrollView,
                  let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return }
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "autosave":
            // 和切走窗口、App 进后台时一样的自动保存。
            controller?.saveIfNeeded()
        case "quickopen":
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            controller?.quickOpen(nil)
        case "quickopenType":
            // 在快速打开的输入框里输入并回车。
            guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
                  let field = panel.firstResponder as? NSTextView else { return }
            field.insertText(info["text"] ?? "", replacementRange: field.selectedRange())
            if info["enter"] == "1" { field.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        case "windows":
            guard let path = info["path"] else { return }
            let list = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow) title=\($0.title) frame=\($0.frame)" }
            try? list.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        case "dump":
            guard let window, let path = info["path"] else { return }
            dump(window, js: info["js"], to: path)
        default:
            break
        }
    }

    /// 把窗口状态写成文本：标题、工具栏、侧栏、编辑器、预览（可附带一段 JS 的结果）。
    private static func dump(_ window: NSWindow, js: String?, to path: String) {
        var lines: [String] = []
        lines.append("title: \(window.title) | subtitle: \(window.subtitle) | edited: \(window.isDocumentEdited)")
        lines.append("frame: \(window.frame) safeTop: \(window.contentView?.safeAreaInsets.top ?? -1)")
        for item in window.toolbar?.items ?? [] {
            var line = "toolbar: \(item.itemIdentifier.rawValue) label=\(item.label) visible=\(item.isVisible)"
            if let group = item as? NSToolbarItemGroup { line += " selected=\(group.selectedIndex)" }
            lines.append(line)
        }
        func walk(_ view: NSView, depth: Int) {
            if let outline = view as? NSOutlineView {
                lines.append("sidebar rows: \(outline.numberOfRows) frame=\(outline.window.map { _ in outline.convert(outline.bounds, to: nil) } ?? .zero)")
                for row in 0..<min(outline.numberOfRows, 40) {
                    if let node = outline.item(atRow: row) as? FileNode {
                        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
                        if row == 0 {
                            lines.append("  [cell frame=\(cell?.frame ?? .zero) text=\(cell?.textField?.frame ?? .zero) col=\(outline.tableColumns.first?.width ?? -1) appearance=\(outline.effectiveAppearance.name.rawValue)]")
                        }
                        lines.append("  \(String(repeating: "  ", count: outline.level(forRow: row)))\(cell?.textField?.stringValue ?? node.name)\(outline.selectedRow == row ? "  ← 选中" : "")")
                    }
                }
            }
            if let text = view as? NSTextView, text.isEditable || text.string.count > 0, view.enclosingScrollView is EditorView {
                let scroll = view.enclosingScrollView!
                lines.append("editor: hidden=\(scroll.isHiddenOrHasHiddenAncestor) width=\(Int(scroll.frame.width)) chars=\(text.string.count) topLine=\(String(format: "%.2f", (scroll as! EditorView).topLine)) insetTop=\(scroll.contentInsets.top)")
            }
            if let banner = view as? ChangeBanner {
                var texts: [String] = []
                func collect(_ v: NSView) {
                    if let button = v as? NSButton { if !button.isHidden { texts.append("[\(button.title)]") } }
                    else if let field = v as? NSTextField { texts.append(field.stringValue) }
                    v.subviews.forEach(collect)
                }
                collect(banner)
                lines.append("banner: hidden=\(banner.isHidden) \(texts.joined(separator: " "))")
            }
            if let web = view as? WKWebView {
                lines.append("preview: hidden=\(web.isHiddenOrHasHiddenAncestor) width=\(Int(web.frame.width)) obscuredTop=\(web.obscuredContentInsets.top)")
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        if let root = window.contentView { walk(root, depth: 0) }

        let finish: (String) -> Void = { extra in
            lines.append(extra)
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard let web = findWebView(in: window.contentView) else { return finish("") }
        let script = js ?? "JSON.stringify({scrollY, blocks: document.querySelectorAll('.blk').length, topLine: silk.topLine(), firstTop: document.querySelector('.blk')?.getBoundingClientRect().top})"
        web.evaluateJavaScript(script) { result, error in
            MainActor.assumeIsolated { finish("js: \(result.map { "\($0)" } ?? "nil") \(error.map { "error: \($0)" } ?? "")") }
        }
    }

    private static func findOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews { if let found = findOutline(in: sub) { return found } }
        return nil
    }

    private static func findEditor(in view: NSView?) -> EditorView? {
        guard let view else { return nil }
        if let editor = view as? EditorView { return editor }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private static func findWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0 { return web }
        for sub in view.subviews { if let found = findWebView(in: sub) { return found } }
        return nil
    }

    private static func snapshot(_ window: NSWindow, to path: String) async {
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)

        // 网页内容在另一个进程里，cacheDisplay 画不出来，单独截了贴上去。
        var overlays: [(NSImage, NSRect)] = []
        if let web = findWebView(in: window.contentView), let image = try? await web.takeSnapshot(configuration: nil) {
            overlays.append((image, web.convert(web.bounds, to: frameView)))
        }
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(false)
        rep.draw(in: bounds)
        for (snap, rect) in overlays { snap.draw(in: rect) }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
