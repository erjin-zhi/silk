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
        // 可以用 window=标题 指定窗口，不指定就用当前窗口。
        let window = candidates.first {
            $0.windowController is WorkspaceWindowController && $0.isVisible && (info["window"] == nil || $0.title == info["window"])
        }
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
        case "key":
            // 按一次菜单快捷键：{"action": "key", "chars": "2", "flags": "cmd"}，flags 可含 cmd ctrl opt shift。
            // 调试实例一般不在前台、没有主窗口，所以自己找到菜单项，从这个窗口的第一响应者开始发。
            guard let chars = info["chars"], let window else { return }
            var flags: NSEvent.ModifierFlags = []
            let names = (info["flags"] ?? "cmd").split(separator: " ")
            if names.contains("cmd") { flags.insert(.command) }
            if names.contains("ctrl") { flags.insert(.control) }
            if names.contains("opt") { flags.insert(.option) }
            if names.contains("shift") { flags.insert(.shift) }
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if let hit = find(item.submenu) { return hit }
                    if item.keyEquivalent == chars, item.keyEquivalentModifierMask == flags { return item }
                }
                return nil
            }
            guard let item = find(NSApp.mainMenu), let action = item.action else { return log("快捷键 \(chars)：没对上") }
            // 调试实例不是活跃应用时第一响应者常常不是编辑器，格式命令直接交给编辑器。
            let editor = findEditor(in: window.contentView)?.textView
            if let editor, editor.responds(to: action) { window.makeFirstResponder(editor) }
            let done = window.firstResponder?.tryToPerform(action, with: item) == true
                || controller?.tryToPerform(action, with: item) == true
            log("快捷键 \(chars)（\(item.title)）：\(done ? "已处理" : "没人接")")
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
        case "ime":
            // 模拟输入法：先出拼音（marked text），再上屏成汉字。
            guard let tv = findEditor(in: window?.contentView)?.textView else { return }
            let pinyin = info["pinyin"] ?? "nihao"
            for i in 1...pinyin.count {
                tv.setMarkedText(String(pinyin.prefix(i)), selectedRange: NSRange(location: i, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            tv.insertText(info["text"] ?? "你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "editorState":
            guard let path = info["path"], let editor = findEditor(in: window?.contentView) else { return }
            let tv = editor.textView
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let used = tv.layoutManager.map { $0.usedRect(for: tv.textContainer!) } ?? .zero
            let glyphs = tv.layoutManager?.numberOfGlyphs ?? -1
            let attrs = tv.textStorage!.length > 0 ? tv.textStorage!.attributes(at: 0, effectiveRange: nil) : [:]
            let color = (attrs[.foregroundColor] as? NSColor).map { "\($0)" } ?? "nil"
            let extra = "glyphs=\(glyphs) color=\(color) container=\(tv.textContainer?.size ?? .zero) marked=\(tv.markedRange())"
            if let shot = info["shot"], let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
                editor.cacheDisplay(in: editor.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
            }
            let state = "string=[\(tv.string)] visible=\(editor.contentView.bounds) used=\(used) frame=\(tv.frame) topLine=\(editor.topLine) firstResponder=\(window?.firstResponder === tv) \(extra)"
            try? state.write(toFile: path, atomically: true, encoding: .utf8)
        case "appearance":
            // 切换外观，模拟系统在白天 / 夜间之间自动切换：{"action": "appearance", "mode": "dark"}
            NSApp.appearance = NSAppearance(named: info["mode"] == "dark" ? .darkAqua : .aqua)
        case "toggleSidebar":
            (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
        case "sidebarNew":
            // 点侧栏底部的「新建」。
            func find(_ v: NSView?) -> NSButton? {
                guard let v else { return nil }
                if let b = v as? NSButton, b.title == "新建" { return b }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            if let button = find(window?.contentView) {
                var chain: [String] = []
                var v: NSView? = button
                while let view = v { if view.isHidden { chain.append("\(type(of: view)) hidden") }; v = view.superview }
                log("侧栏新建按钮 window=\(button.window?.title ?? "-") frame=\(button.convert(button.bounds, to: nil)) hidden=\(button.isHiddenOrHasHiddenAncestor) \(chain)")
                button.performClick(nil)
            } else {
                log("没找到侧栏新建按钮")
            }
        case "toolbarClick":
            // 点一下工具栏按钮：{"action": "toolbarClick", "item": "newDraft"}
            guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == info["item"] }),
                  let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        case "terminate":
            NSApp.terminate(nil)
        case "search":
            // 在文件夹中搜索：{"action": "search", "query": "标题"}，加 "pick": "2" 直接打开第 2 处结果。
            guard let controller, let window else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            controller.findInFolder(nil)
            controller.searchPanel.setQuery(info["query"] ?? "")
            if let pick = info["pick"].flatMap(Int.init) {
                let files = controller.workspace.files.map(\.url)
                let result = FolderSearch.search(info["query"] ?? "", in: files)
                guard pick >= 1, pick <= result.matches.count else { return log("搜索：没有第 \(pick) 处结果") }
                controller.searchPanel.close()
                controller.openSearchResult(result.matches[pick - 1], query: info["query"] ?? "")
            }
        case "export":
            // 导出到指定位置，不弹存储面板：{"action": "export", "format": "pdf", "path": "/tmp/a.pdf"}
            guard let controller, let path = info["path"] else { return }
            let url = URL(fileURLWithPath: path)
            controller.chooseExportLocation = { _, done in done(url) }
            if info["format"] == "pdf" { controller.exportPDF(nil) } else { controller.exportHTML(nil) }
        case "compare":
            controller?.compareWithDisk(nil)
        case "about":
            AboutWindowController.shared.show()
        case "checkForUpdates":
            // {"action": "checkForUpdates", "background": "1", "autoDownload": "1"}
            if let auto = info["autoDownload"] { Updater.shared.automaticallyDownloads = auto == "1" }
            if info["background"] == "1" { Updater.shared.checkInBackground() } else { Updater.shared.checkForUpdates() }
        case "windowSnapshot":
            // 截表单或浮动面板（不含网页内容）：{"action": "windowSnapshot", "which": "sheet", "path": "/tmp/a.png"}
            guard let path = info["path"] else { return }
            let target = switch info["which"] {
            case "sheet": window?.attachedSheet
            case "about": AboutWindowController.shared.window
            // 最前面的非工作区窗口，比如 Sparkle 的更新窗口。
            case "front": NSApp.orderedWindows.first { $0.isVisible && !($0.windowController is WorkspaceWindowController) }
            default: NSApp.windows.first { $0 is NSPanel && $0.isVisible }
            }
            guard let view = target?.contentView?.superview ?? target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return log("没有可截的窗口") }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "quickopenLayout":
            // 快速打开面板里各部件的位置，检查有没有重叠。
            guard let path = info["path"], let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
                  let root = panel.contentView else { return }
            var lines: [String] = []
            func walk(_ v: NSView) {
                if v is NSImageView || v is NSTextField {
                    let frame = v.convert(v.bounds, to: nil)
                    let text = (v as? NSTextField).map { "text=\($0.stringValue) placeholder=\($0.placeholderString ?? "")" } ?? "image"
                    if frame.maxY > root.bounds.height - 70 { lines.append("\(type(of: v)) \(frame) \(text)") }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        case "quickopenType":
            // 在快速打开的输入框里输入并回车。
            guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
                  let field = panel.firstResponder as? NSTextView else { return }
            field.insertText(info["text"] ?? "", replacementRange: field.selectedRange())
            if info["enter"] == "1" { field.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        case "windows":
            guard let path = info["path"] else { return }
            let list = ["app hidden=\(NSApp.isHidden) active=\(NSApp.isActive)"] + NSApp.windows.map {
                "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow) title=\($0.title) frame=\($0.frame) mini=\($0.isMiniaturized) onScreen=\($0.isOnActiveSpace)"
            }
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
        if let split = window.contentViewController as? NSSplitViewController {
            lines.append("split items collapsed: \(split.splitViewItems.map(\.isCollapsed)) widths: \(split.splitViewItems.map { Int($0.viewController.view.frame.width) })")
        }
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
                        let date = (cell?.subviews ?? []).compactMap { $0 as? NSTextField }.filter { $0 !== cell?.textField }.map(\.stringValue).joined()
                        lines.append("  \(String(repeating: "  ", count: outline.level(forRow: row)))\(cell?.textField?.stringValue ?? node.name)\(date.isEmpty ? "" : "  ·  \(date)")\(outline.selectedRow == row ? "  ← 选中" : "")")
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
                let under = web.underPageBackgroundColor.usingColorSpace(.sRGB).map { String(format: "%.2f", $0.brightnessComponent) } ?? "?"
                lines.append("preview: hidden=\(web.isHiddenOrHasHiddenAncestor) width=\(Int(web.frame.width)) obscuredTop=\(web.obscuredContentInsets.top) underPageBrightness=\(under) appearance=\(web.effectiveAppearance.name.rawValue)")
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
