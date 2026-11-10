import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

/// Finder 里按空格预览 Markdown：和 App 里的阅读模式用同一个预览页（markdown-it、KaTeX、Mermaid）。
@objc(SilkPreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ResourceHandler(), forURLScheme: "silk")
        config.setURLSchemeHandler(LocalFileHandler(), forURLScheme: "silk-file")
        config.userContentController.add(WeakHandler(self), name: "silk")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        view = webView
        webView.load(URLRequest(url: URL(string: "silk://app/index.html")!))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        _ = view
        let text = try Self.read(url)
        await waitUntilReady()
        var base = url.deletingLastPathComponent().path
        if !base.hasSuffix("/") { base += "/" }
        var components = URLComponents()
        components.scheme = "silk-file"
        components.host = ""
        components.path = base
        _ = try? await webView.callAsyncJavaScript(
            "silk.setMode('read'); silk.setDocument(text, base, 0); return true",
            arguments: ["text": text, "base": components.url?.absoluteString ?? "silk-file:///"],
            contentWorld: .page
        )
    }

    /// 等预览页发来 ready；页面出了问题也最多等两秒，不让 Finder 一直转圈。
    private func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.markReady() }
            }
        }
    }

    private func markReady() {
        ready = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    /// 和 App 用同一套编码探测（TextFile.swift 是 App 那份的软链接），同一个文件在两边看到的字一样。
    static func read(_ url: URL) throws -> String {
        try TextFile.read(url).text
    }

    // MARK: - 网页

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            markReady()
        case "copy":
            // 预览页点「复制」后按钮马上显示「已复制」，这边得真的放进剪贴板。
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // 只显示自己的页面；预览里点链接不跳走。
        decisionHandler(navigationAction.request.url?.scheme == "silk" ? .allow : .cancel)
    }
}

/// WKUserContentController 强引用 handler，隔一层避免循环引用。
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// 预览页资源。扩展在沙盒里读不到外面 App 包里的文件，所以打包时在扩展里放了一份（不含体积大的 Mermaid）；
/// 扩展里没有的再试一下外面 App 里的那份（App 装在「应用程序」里时一般读得到），读不到图表就显示源码。
private final class ResourceHandler: NSObject, WKURLSchemeHandler {
    static let roots: [URL] = {
        // 扩展在 Silk.app/Contents/PlugIns/SilkQuickLook.appex
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return [Bundle.main.resourceURL?.appending(path: "Preview"), app.appending(path: "Resources/Preview")]
            .compactMap { $0?.standardizedFileURL }
    }()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        for root in Self.roots {
            let file = root.appending(path: url.path).standardizedFileURL
            guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else { continue }
            return respond(task, url: url, file: file, data: data)
        }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// 文档旁边的图片。沙盒里不一定读得到，读不到就不显示。
private final class LocalFileHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let data = try? Data(contentsOf: URL(fileURLWithPath: url.path), options: .mappedIfSafe) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        respond(task, url: url, file: URL(fileURLWithPath: url.path), data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

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
