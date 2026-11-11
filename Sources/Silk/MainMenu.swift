import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Silk")
        menu.addItem(item("关于 Silk", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(item("检查更新…", #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("设为默认 Markdown 打开方式", #selector(AppDelegate.makeDefaultMarkdownApp(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "服务")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("隐藏 Silk", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("退出 Silk", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "文件")
        menu.addItem(item("新建草稿", #selector(AppDelegate.newDraft(_:)), "n"))
        menu.addItem(item("打开…", #selector(AppDelegate.openDocument(_:)), "o"))

        // 带 clearRecentDocuments: 的子菜单会被 NSDocumentController 自动填充。
        let recent = NSMenu(title: "打开最近使用")
        recent.addItem(item("清除菜单", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "打开最近使用", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)

        menu.addItem(item("快速打开…", #selector(WorkspaceWindowController.quickOpen(_:)), "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("存储", #selector(WorkspaceWindowController.saveDocument(_:)), "s"))
        menu.addItem(item("与磁盘版本比较…", #selector(WorkspaceWindowController.compareWithDisk(_:))))
        menu.addItem(item("在 Finder 中显示", #selector(WorkspaceWindowController.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        let export = NSMenu(title: "导出")
        export.addItem(item("PDF…", #selector(WorkspaceWindowController.exportPDF(_:)), "e", [.command, .shift]))
        export.addItem(item("HTML…", #selector(WorkspaceWindowController.exportHTML(_:))))
        let exportItem = NSMenuItem(title: "导出", action: nil, keyEquivalent: "")
        exportItem.submenu = export
        menu.addItem(exportItem)
        menu.addItem(item("打印…", #selector(WorkspaceWindowController.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        menu.addItem(item("撤销", Selector(("undo:")), "z"))
        menu.addItem(item("重做", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("剪切", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("拷贝", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("粘贴并匹配样式", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "查找")
        let action = #selector(NSResponder.performTextFinderAction(_:))
        find.addItem(item("查找…", action, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item("查找并替换…", action, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        find.addItem(item("查找下一个", action, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item("查找上一个", action, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item("用所选内容查找", action, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(.separator())
        find.addItem(item("在文件夹中搜索…", #selector(WorkspaceWindowController.findInFolder(_:)), "f", [.command, .shift]))
        let findItem = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "显示")
        // ⌘1–⌘6 留给标题（同 Typora），模式切换用 ⌃⌘。
        menu.addItem(item("阅读", #selector(WorkspaceWindowController.showReadMode(_:)), "1", [.command, .control]))
        menu.addItem(item("对照", #selector(WorkspaceWindowController.showSplitMode(_:)), "2", [.command, .control]))
        menu.addItem(item("源码", #selector(WorkspaceWindowController.showSourceMode(_:)), "3", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("显示侧栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        // ⌘= / ⌘- / ⌘0 留给标题级别和正文（同 Typora），整体缩放用 ⇧⌘= / ⇧⌘- / ⇧⌘0。
        // 带 ⇧ 的符号键要写成按出来的字符（+ _ )），写成 "=" 加 ⇧ 对不上键盘事件。
        menu.addItem(item("放大", #selector(WorkspaceWindowController.zoomIn(_:)), "+"))
        menu.addItem(item("缩小", #selector(WorkspaceWindowController.zoomOut(_:)), "_"))
        menu.addItem(item("实际大小", #selector(WorkspaceWindowController.zoomReset(_:)), ")"))

        let font = NSMenu(title: "编辑器字号")
        font.addItem(item("增大", #selector(WorkspaceWindowController.editorFontBigger(_:)), "=", [.command, .option]))
        font.addItem(item("减小", #selector(WorkspaceWindowController.editorFontSmaller(_:)), "-", [.command, .option]))
        font.addItem(item("恢复默认", #selector(WorkspaceWindowController.editorFontReset(_:))))
        let fontItem = NSMenuItem(title: "编辑器字号", action: nil, keyEquivalent: "")
        fontItem.submenu = font
        menu.addItem(fontItem)
        menu.addItem(.separator())
        menu.addItem(item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// 格式菜单，菜单栏和编辑器右键菜单共用。快捷键沿用 Typora。
    static func formatMenu() -> NSMenu {
        typealias T = MarkdownTextView
        let menu = NSMenu(title: "格式")
        for level in 1...6 {
            menu.addItem(item("标题 \(level)", #selector(T.formatHeading(_:)), "\(level)", tag: level))
        }
        menu.addItem(item("正文", #selector(T.formatHeading(_:)), "0", tag: 0))
        menu.addItem(item("提升标题级别", #selector(T.formatPromoteHeading(_:)), "="))
        menu.addItem(item("降低标题级别", #selector(T.formatDemoteHeading(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("粗体", #selector(T.formatBold(_:)), "b"))
        menu.addItem(item("斜体", #selector(T.formatItalic(_:)), "i"))
        menu.addItem(item("下划线", #selector(T.formatUnderline(_:)), "u"))
        // ⌃⇧`：写成 "`" 加 ⇧ 会连 ⌃` 一起吞掉，要写成按出来的 ~。
        menu.addItem(item("删除线", #selector(T.formatStrikethrough(_:)), "~", .control))
        menu.addItem(item("行内代码", #selector(T.formatInlineCode(_:)), "`", .control))
        menu.addItem(item("链接", #selector(T.formatLink(_:)), "k"))
        menu.addItem(item("图片", #selector(T.formatImage(_:)), "i", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("引用", #selector(T.formatQuote(_:)), "q", [.command, .option]))
        menu.addItem(item("有序列表", #selector(T.formatOrderedList(_:)), "o", [.command, .option]))
        menu.addItem(item("无序列表", #selector(T.formatBulletList(_:)), "u", [.command, .option]))
        menu.addItem(item("任务列表", #selector(T.formatTaskList(_:)), "x", [.command, .option]))
        menu.addItem(item("代码块", #selector(T.formatCodeBlock(_:)), "c", [.command, .option]))
        menu.addItem(item("表格", #selector(T.formatTable(_:)), "t", [.command, .option]))
        menu.addItem(item("分隔线", #selector(T.formatHorizontalRule(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "窗口")
        menu.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("缩放", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
