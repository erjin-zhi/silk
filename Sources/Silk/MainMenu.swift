import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
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
        menu.addItem(item("关于 Silk", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
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
        menu.addItem(item("在 Finder 中显示", #selector(WorkspaceWindowController.revealInFinder(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
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
        let findItem = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "显示")
        menu.addItem(item("阅读", #selector(WorkspaceWindowController.showReadMode(_:)), "1"))
        menu.addItem(item("对照", #selector(WorkspaceWindowController.showSplitMode(_:)), "2"))
        menu.addItem(item("源码", #selector(WorkspaceWindowController.showSourceMode(_:)), "3"))
        menu.addItem(.separator())
        menu.addItem(item("显示侧栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("放大", #selector(WorkspaceWindowController.zoomIn(_:)), "+"))
        menu.addItem(item("缩小", #selector(WorkspaceWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("实际大小", #selector(WorkspaceWindowController.zoomReset(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
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
