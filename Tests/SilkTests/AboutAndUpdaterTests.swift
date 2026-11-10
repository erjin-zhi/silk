import AppKit
import Foundation
import Testing
@testable import Silk

@MainActor
@Suite struct AboutAndUpdaterTests {
    /// 造一个只有 Info.plist 的假 App 包。
    private func fakeBundle(_ dir: TempDir, name: String, info: [String: Any]) throws -> Bundle {
        let url = dir.url.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        return try #require(Bundle(url: url))
    }

    @Test func 版本号带上构建号() throws {
        let dir = TempDir()
        let bundle = try fakeBundle(dir, name: "A.app", info: ["CFBundleIdentifier": "a", "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"])
        #expect(AboutWindowController.versionText(bundle) == "版本 1.2.0（42）")
        let noBuild = try fakeBundle(dir, name: "B.app", info: ["CFBundleIdentifier": "b", "CFBundleShortVersionString": "1.2.0"])
        #expect(AboutWindowController.versionText(noBuild) == "版本 1.2.0")
    }

    @Test func 上次检查时间按今天昨天显示() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15)))
        #expect(AboutWindowController.lastCheckText(nil, now: now) == "还没有检查过更新")
        #expect(AboutWindowController.lastCheckText(now.addingTimeInterval(-3600), now: now).hasPrefix("上次检查：今天 "))
        #expect(AboutWindowController.lastCheckText(now.addingTimeInterval(-86400), now: now).hasPrefix("上次检查：昨天 "))
        #expect(!AboutWindowController.lastCheckText(now.addingTimeInterval(-86400 * 5), now: now).contains("今天"))
    }

    @Test func 不是从App包运行时不启动更新_关于窗口里按钮不可用() {
        // 测试进程的 main bundle 是 xctest，不是 .app。
        let updater = Updater()
        updater.start()
        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.unavailableReason == "从 Silk.app 运行时才能检查更新")

        let about = AboutWindowController(updater: updater)
        about.refresh()
        #expect(!about.checkButton.isEnabled)
        #expect(!about.autoCheckBox.isEnabled)
        #expect(about.statusLabel.stringValue == "从 Silk.app 运行时才能检查更新")
        about.window?.close()
    }

    @Test func 没配更新源时不启动更新() throws {
        let dir = TempDir()
        let bundle = try fakeBundle(dir, name: "NoFeed.app", info: ["CFBundleIdentifier": "com.example.nofeed", "CFBundleShortVersionString": "1.0"])
        let updater = Updater()
        updater.start(bundle: bundle)
        #expect(!updater.isAvailable)
        #expect(updater.unavailableReason == "这个版本没有配置更新源")
    }

    @Test func 正式包里配好了更新源和公钥() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"))
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test func 应用菜单里有关于和检查更新() {
        _ = NSApplication.shared
        let menu = MainMenu.make().items.first?.submenu
        #expect(menu?.items.first?.action == #selector(AppDelegate.showAbout(_:)))
        #expect(menu?.items.dropFirst().first?.action == #selector(AppDelegate.checkForUpdates(_:)))
    }
}
