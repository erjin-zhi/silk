import AppKit

/// 「关于 Silk」窗口：图标、版本、更新设置和致谢。替代系统标准的关于面板，好把更新选项放在一起。
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    /// 致谢的开源项目，和预览页、更新用到的依赖对应。
    static let credits: [(name: String, url: String)] = [
        ("markdown-it", "https://github.com/markdown-it/markdown-it"),
        ("KaTeX", "https://katex.org"),
        ("Mermaid", "https://mermaid.js.org"),
        ("highlight.js", "https://highlightjs.org"),
        ("Sparkle", "https://sparkle-project.org"),
    ]

    private let updater: Updater
    private let bundle: Bundle
    let versionLabel = NSTextField(labelWithString: "")
    let autoCheckBox = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    let autoDownloadBox = NSButton(checkboxWithTitle: "自动下载并安装更新", target: nil, action: nil)
    let checkButton = NSButton(title: "检查更新…", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private var observer: (any NSObjectProtocol)?

    init(updater: Updater = .shared, bundle: Bundle = .main) {
        self.updater = updater
        self.bundle = bundle
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "关于 Silk"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        observer = NotificationCenter.default.addObserver(forName: Updater.didFinishCheck, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 文字

    /// 「版本 0.1.0（42）」，构建号是打包时的提交数。
    static func versionText(_ bundle: Bundle) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else {
            return "版本 \(version)"
        }
        return "版本 \(version)（\(build)）"
    }

    static func lastCheckText(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "还没有检查过更新" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "上次检查：今天 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "上次检查：昨天 \(time)"
        }
        return "上次检查：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - 界面

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let name = NSTextField(labelWithString: "Silk")
        name.font = .systemFont(ofSize: 26, weight: .semibold)

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true

        let tagline = NSTextField(labelWithString: "Markdown, smooth as silk.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor

        let header = NSStackView(views: [icon, name, versionLabel, tagline])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 4
        header.setCustomSpacing(12, after: icon)
        header.setCustomSpacing(8, after: versionLabel)

        autoCheckBox.target = self
        autoCheckBox.action = #selector(toggleAutoCheck(_:))
        autoDownloadBox.target = self
        autoDownloadBox.action = #selector(toggleAutoDownload(_:))
        checkButton.target = self
        checkButton.action = #selector(checkForUpdates(_:))
        checkButton.bezelStyle = .push
        checkButton.controlSize = .large
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center

        let boxes = NSStackView(views: [autoCheckBox, autoDownloadBox])
        boxes.orientation = .vertical
        boxes.alignment = .leading
        boxes.spacing = 6

        let updates = NSStackView(views: [checkButton, statusLabel, boxes])
        updates.orientation = .vertical
        updates.alignment = .centerX
        updates.spacing = 6
        updates.setCustomSpacing(12, after: statusLabel)

        let credits = NSTextField(labelWithAttributedString: Self.creditsText())
        credits.isSelectable = true
        credits.allowsEditingTextAttributes = true
        credits.alignment = .center
        credits.maximumNumberOfLines = 0
        credits.preferredMaxLayoutWidth = 300

        let stack = NSStackView(views: [header, separator(), updates, separator(), credits])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 30, bottom: 24, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 360),
        ])
        return content
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return line
    }

    private static func creditsText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "感谢 ", attributes: base)
        for (index, credit) in credits.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: index == credits.count - 1 ? " 和 " : "、", attributes: base)) }
            var link = base
            link[.link] = URL(string: credit.url)
            text.append(NSAttributedString(string: credit.name, attributes: link))
        }
        text.append(NSAttributedString(string: " 等开源项目", attributes: base))
        return text
    }

    // MARK: - 状态

    func refresh() {
        versionLabel.stringValue = Self.versionText(bundle)
        let available = updater.isAvailable
        checkButton.isEnabled = available && updater.canCheckForUpdates
        autoCheckBox.isEnabled = available
        autoCheckBox.state = updater.automaticallyChecks ? .on : .off
        autoDownloadBox.isHidden = available && !updater.allowsAutomaticDownloads
        autoDownloadBox.isEnabled = available && updater.automaticallyChecks
        autoDownloadBox.state = updater.automaticallyDownloads ? .on : .off
        statusLabel.stringValue = available
            ? Self.lastCheckText(updater.lastCheckDate)
            : (updater.unavailableReason ?? "无法检查更新")
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
        refresh()
    }

    @objc private func toggleAutoCheck(_ sender: NSButton) {
        updater.automaticallyChecks = sender.state == .on
        refresh()
    }

    @objc private func toggleAutoDownload(_ sender: NSButton) {
        updater.automaticallyDownloads = sender.state == .on
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }
}
