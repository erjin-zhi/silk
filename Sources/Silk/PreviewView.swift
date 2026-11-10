import AppKit
import UniformTypeIdentifiers
import WebKit

/// 预览：一个常驻的 WKWebView。打字时只发新文本，网页里按块增量更新。
@MainActor
final class PreviewController: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    var onScroll: ((Double) -> Void)?
    var onClick: ((Int) -> Void)?
    var onLink: ((URL, String?) -> Void)?

    private var ready = false
    private var pendingDocument: (text: String, base: URL, line: Double, hash: String?)?
    private var lastDocument: (text: String, base: URL)?
    private var mode: ViewMode = .read

    // 同一时间只有一次更新在路上，后来的只留最新一份。
    private var generation = 0
    private var updateInFlight = false
    private var pendingUpdate: String?
    /// 网页里现在的全文。打字时只把和它不同的那一段发过去，大文件不用每次传整篇。
    private var sentText: NSString?
    private var scrollInFlight = false
    private var pendingScroll: Double?

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "silk")
        config.setURLSchemeHandler(FileSchemeHandler(), forURLScheme: "silk-file")
        config.suppressesIncrementalRendering = false
        config.preferences.isElementFullscreenEnabled = false
        webView = PreviewWebView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(MessageProxy(self), name: "silk")
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Markdown 预览")
        webView.load(URLRequest(url: URL(string: "silk://app/index.html")!))
    }

    // MARK: - 给原生端用的接口

    func setDocument(_ text: String, base: URL, line: Double = 0, hash: String? = nil) {
        lastDocument = (text, base)
        generation += 1
        pendingUpdate = nil
        updateInFlight = false
        guard ready else {
            pendingDocument = (text, base, line, hash)
            return
        }
        sentText = text as NSString
        let started = CACurrentMediaTime()
        webView.callAsyncJavaScript(
            "const s = silk.setDocument(text, base, line); if (hash) silk.scrollToId(hash); return s.ms",
            arguments: ["text": text, "base": Self.baseURL(for: base), "line": line, "hash": hash ?? NSNull()],
            in: nil, in: .page
        ) { result in
            let js = (try? result.get() as? Double) ?? -1
            DebugHooks.log(String(format: "预览渲染：%d 字，JS %.1f ms，往返 %.1f ms", (text as NSString).length, js, (CACurrentMediaTime() - started) * 1000))
        }
    }

    func update(_ text: String) {
        lastDocument?.text = text
        guard ready else {
            pendingDocument?.text = text
            return
        }
        if updateInFlight {
            pendingUpdate = text
            return
        }
        updateInFlight = true
        let generation = generation
        let started = CACurrentMediaTime()
        let new = text as NSString
        let body: String
        let arguments: [String: Any]
        if let old = sentText, let edit = Self.difference(old, new) {
            body = "return silk.edit(start, removed, inserted).ms"
            arguments = ["start": edit.start, "removed": edit.removed, "inserted": new.substring(with: edit.inserted)]
        } else {
            body = "return silk.update(text).ms"
            arguments = ["text": text]
        }
        sentText = new
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
            if DebugHooks.enabled {
                let js = (try? result.get() as? Double) ?? -1
                DebugHooks.log(String(format: "增量更新：JS %.1f ms，往返 %.1f ms", js, (CACurrentMediaTime() - started) * 1000))
            }
            // 出错时网页里的全文可能和这边对不上了，下次整篇发。
            if case .failure = result { self?.sentText = nil }
            guard let self, generation == self.generation else { return }
            self.updateInFlight = false
            if let next = self.pendingUpdate {
                self.pendingUpdate = nil
                self.update(next)
            }
        }
    }

    /// 两段文字的差别：从 start 起，旧文本删掉 removed 个 UTF-16 单位，换成新文本里 inserted 这一段。
    nonisolated static func difference(_ old: NSString, _ new: NSString) -> (start: Int, removed: Int, inserted: NSRange)? {
        let oldLength = old.length
        let newLength = new.length
        let limit = min(oldLength, newLength)
        let chunk = 4096
        var a = [unichar](repeating: 0, count: chunk)
        var b = [unichar](repeating: 0, count: chunk)

        var prefix = 0
        scan: while prefix < limit {
            let n = min(chunk, limit - prefix)
            old.getCharacters(&a, range: NSRange(location: prefix, length: n))
            new.getCharacters(&b, range: NSRange(location: prefix, length: n))
            if memcmp(a, b, n * 2) == 0 {
                prefix += n
                continue
            }
            for i in 0..<n where a[i] != b[i] {
                prefix += i
                break scan
            }
        }
        if prefix == oldLength && prefix == newLength { return nil }

        var suffix = 0
        let maxSuffix = limit - prefix
        scan: while suffix < maxSuffix {
            let n = min(chunk, maxSuffix - suffix)
            old.getCharacters(&a, range: NSRange(location: oldLength - suffix - n, length: n))
            new.getCharacters(&b, range: NSRange(location: newLength - suffix - n, length: n))
            if memcmp(a, b, n * 2) == 0 {
                suffix += n
                continue
            }
            for i in stride(from: n - 1, through: 0, by: -1) where a[i] != b[i] {
                suffix += n - 1 - i
                break scan
            }
        }
        // 不要把一个字（代理对）从中间切开。
        if prefix > 0, prefix < newLength, CFStringIsSurrogateLowCharacter(new.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, newLength - suffix > prefix, CFStringIsSurrogateLowCharacter(new.character(at: newLength - suffix)) { suffix -= 1 }
        return (prefix, oldLength - prefix - suffix, NSRange(location: prefix, length: newLength - prefix - suffix))
    }

    func scrollToLine(_ line: Double) {
        guard ready else { return }
        if scrollInFlight {
            pendingScroll = line
            return
        }
        scrollInFlight = true
        call("silk.scrollToLine(line)", ["line": line]) { [weak self] in
            guard let self else { return }
            self.scrollInFlight = false
            if let next = self.pendingScroll {
                self.pendingScroll = nil
                self.scrollToLine(next)
            }
        }
    }

    func scrollToId(_ id: String) {
        guard ready else { return }
        call("silk.scrollToId(id)", ["id": id])
    }

    func highlightLine(_ line: Int) {
        guard ready else { return }
        call("silk.highlightLine(line)", ["line": line])
    }

    func setMode(_ mode: ViewMode) {
        self.mode = mode
        guard ready else { return }
        call("silk.setMode(mode)", ["mode": mode.rawValue])
    }

    /// 预览顶部当前是第几行。
    func topLine(_ completion: @escaping (Double) -> Void) {
        guard ready else { return completion(0) }
        webView.callAsyncJavaScript("return silk.topLine()", arguments: [:], in: nil, in: .page) { result in
            completion((try? result.get() as? Double) ?? 0)
        }
    }

    /// 打印前把大文档里还没填内容的块都填上。
    func prepareForPrint(_ completion: @escaping () -> Void) {
        guard ready else { return completion() }
        call("silk.materializeAll()", [:], completion: completion)
    }

    func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
    }

    private func call(_ body: String, _ arguments: [String: Any], completion: (() -> Void)? = nil) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("Silk preview: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private static func baseURL(for directory: URL) -> String {
        var components = URLComponents()
        components.scheme = "silk-file"
        components.host = ""
        components.path = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return components.url?.absoluteString ?? "silk-file:///"
    }

    // MARK: - 网页消息

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            DebugHooks.log("预览页就绪")
            ready = true
            setMode(mode)
            if let doc = pendingDocument {
                pendingDocument = nil
                setDocument(doc.text, base: doc.base, line: doc.line, hash: doc.hash)
            }
        case "scroll":
            if let line = message["line"] as? Double { onScroll?(line) }
        case "click":
            if let line = message["line"] as? Int { onClick?(line) }
        case "link":
            if let href = message["href"] as? String, let url = URL(string: href) {
                onLink?(url, message["wiki"] as? String)
            }
        case "copy":
            if let text = message["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // 只允许加载自己的页面；链接点击由网页拦下来交给原生端处理。
        let allowed = navigationAction.request.url?.scheme == "silk"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 网页进程崩了：重载页面，恢复当前文档。
        ready = false
        sentText = nil
        if let doc = lastDocument { pendingDocument = (doc.text, doc.base, 0, nil) }
        webView.reload()
    }
}

/// 预览用的 WKWebView。underPageBackgroundColor 设进去时就被换成了固定颜色，不会跟着系统深浅色变：
/// 白天以浅色打开、晚上系统自动切到深色后，顶部工具栏下面那条还是浅色。所以外观一变就按新外观重设一次。
final class PreviewWebView: WKWebView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
    }

    func applyBackground() {
        var color = NSColor.textBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        underPageBackgroundColor = color
    }
}

enum ViewMode: String {
    case read, split, source
}

/// WKUserContentController 会强引用 handler，用它隔开避免循环引用。
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: PreviewController?
    init(_ target: PreviewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}

// MARK: - 自定义 scheme

/// silk://app/… 读 App 自带的预览页资源。
@MainActor
private final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root = Resources.previewDirectory else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let file = root.appending(path: url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        respond(task, url: url, file: file, data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// silk-file:///绝对路径 读文档旁边的图片等本地文件。
@MainActor
private final class FileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = URL(fileURLWithPath: url.path)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        respond(task, url: url, file: file, data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
private func respond(_ task: any WKURLSchemeTask, url: URL, file: URL, data: Data) {
    let ext = file.pathExtension.lowercased()
    let mime: String
    switch ext {
    case "js": mime = "text/javascript"
    case "css": mime = "text/css"
    case "html": mime = "text/html"
    case "svg": mime = "image/svg+xml"
    case "woff2": mime = "font/woff2"
    default: mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
    let textual = mime.hasPrefix("text/") || mime == "image/svg+xml"
    let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": textual ? "\(mime); charset=utf-8" : mime, "Content-Length": "\(data.count)"]
    )!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
}

enum Resources {
    /// App 包里的 Contents/Resources/Preview；用 swift run 调试时退回到源码目录里的 Resources/Preview。
    static let previewDirectory: URL? = {
        if let url = Bundle.main.url(forResource: "Preview", withExtension: nil) { return url.standardizedFileURL }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Preview")
        return FileManager.default.fileExists(atPath: source.path) ? source.standardizedFileURL : nil
    }()
}
