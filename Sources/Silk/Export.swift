import AppKit
import UniformTypeIdentifiers
import WebKit

/// 导出 HTML / PDF、打印共用：把预览里渲染好的正文拼成一个独立的 HTML 文件。
/// 样式、公式字体、本地图片都嵌在文件里，拷到哪儿、用哪个浏览器打开都一样。一律用浅色。
enum HTMLExport {
    /// 预览页交出来的正文。
    struct Body {
        var html: String
        /// 正文里第一个一级标题，没有就是空。
        var title: String
        /// 有没有公式（有才带上 KaTeX 的样式和字体）。
        var math: Bool
    }

    /// destination：导出的 HTML 要存到哪个文件。给了就把没嵌进去的本地文件（链接、太大的图片）写成相对它的地址，
    /// 文件夹整体搬走也还能点开；不给（打印、PDF）就写成绝对的 file:// 地址。
    static func document(
        _ body: Body, fallbackTitle: String, resources: URL? = Resources.previewDirectory, destination: URL? = nil
    ) -> String {
        let title = body.title.isEmpty ? fallbackTitle : body.title
        var styles: [String] = []
        if body.math, let resources, let katex = try? String(contentsOf: resources.appending(path: "katex/katex.min.css"), encoding: .utf8) {
            styles.append(embedFonts(in: katex, base: resources.appending(path: "katex")))
        }
        if let resources, let css = try? String(contentsOf: resources.appending(path: "style.css"), encoding: .utf8) {
            styles.append(lightStylesheet(css))
        }
        styles.append(extraCSS)
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Silk">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <title>\(escape(title))</title>
        \(styles.map { "<style>\n\($0)\n</style>" }.joined(separator: "\n"))
        </head>
        <body data-mode="read">
        <main class="markdown-body">
        \(embedLocalFiles(in: body.html, destination: destination))
        </main>
        </body>
        </html>

        """
    }

    /// 导出的页面不运行任何脚本：正文里作者写的 <script>、onerror= 之类在浏览器里打开时都不执行。
    /// 样式、图片、字体照常加载。
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; "
        + "style-src 'unsafe-inline'; font-src data:; img-src * data: blob: file:; media-src * data: blob: file:"

    /// 导出页额外的样式：底部不用留半屏空白，打印时代码自动换行、标题不落在页底。
    static let extraCSS = """
    :root { color-scheme: light; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .markdown-body { padding: 48px 48px 72px; }
    .copy-btn { display: none; }
    @media print {
      .markdown-body { padding: 0; }
      h1, h2, h3, h4, h5, h6, .blk-h { break-after: avoid; }
      pre { white-space: pre-wrap; overflow: visible; }
      table { overflow: visible; }
      .katex-display { overflow: visible; }
    }
    """

    // MARK: - 样式

    /// 预览样式用的是 WebKit 才认的系统颜色（-apple-system-label 等），会跟着深浅色变。
    /// 导出时换成浅色下的具体颜色，去掉深色规则，别的浏览器打开也一样。
    static func lightStylesheet(_ css: String) -> String {
        var names: [String] = []
        let replaced = css.replacing(/-apple-system-([a-z][a-z-]*)/) { match in
            let name = String(match.1)
            if !names.contains(name) { names.append(name) }
            return "var(--sys-\(name))"
        }
        let variables = names.map { "  --sys-\($0): \(lightColor(named: $0));" }.joined(separator: "\n")
        return ":root {\n\(variables)\n}\n" + removingDarkRules(replaced)
    }

    /// 去掉 @media (prefers-color-scheme: dark) { … } 整段。
    static func removingDarkRules(_ css: String) -> String {
        var result = css
        while let start = result.range(of: "@media (prefers-color-scheme: dark)") {
            guard let open = result[start.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            var end: String.Index?
            while index < result.endIndex {
                if result[index] == "{" { depth += 1 }
                if result[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = result.index(after: index); break }
                }
                index = result.index(after: index)
            }
            guard let end else { break }
            result.removeSubrange(start.lowerBound..<end)
        }
        return result
    }

    private static func lightColor(named name: String) -> String {
        let colors: [String: NSColor] = [
            "label": .labelColor, "secondary-label": .secondaryLabelColor, "tertiary-label": .tertiaryLabelColor,
            "quaternary-label": .quaternaryLabelColor, "text-background": .textBackgroundColor, "text": .textColor,
            "separator": .separatorColor, "link": .linkColor, "control-accent": .systemBlue,
            "blue": .systemBlue, "green": .systemGreen, "purple": .systemPurple, "orange": .systemOrange,
            "red": .systemRed, "teal": .systemTeal, "indigo": .systemIndigo, "gray": .systemGray,
            "yellow": .systemYellow, "pink": .systemPink, "brown": .systemBrown, "mint": .systemMint, "cyan": .systemCyan,
        ]
        guard let color = colors[name] else { return "currentColor" }
        var css = "currentColor"
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let r = Int((rgb.redComponent * 255).rounded())
            let g = Int((rgb.greenComponent * 255).rounded())
            let b = Int((rgb.blueComponent * 255).rounded())
            css = rgb.alphaComponent >= 0.999
                ? String(format: "#%02x%02x%02x", r, g, b)
                : String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, rgb.alphaComponent)
        }
        return css
    }

    /// KaTeX 样式里的 woff2 字体换成 data: 地址。
    private static func embedFonts(in css: String, base: URL) -> String {
        css.replacing(/url\((fonts\/[A-Za-z0-9_\-]+\.woff2)\)/) { match in
            guard let data = try? Data(contentsOf: base.appending(path: String(match.1))) else { return String(match.0) }
            return "url(data:font/woff2;base64,\(data.base64EncodedString()))"
        }
    }

    // MARK: - 图片

    /// 正文里 silk-file:///… 的本地文件：图片换成 data: 地址嵌进去；链接和太大的图片改成指向原文件的地址
    /// （给了 destination 就是相对导出文件的路径，否则是 file:// 绝对地址）。
    static func embedLocalFiles(in html: String, maxSize: Int = 25 << 20, destination: URL? = nil) -> String {
        html.replacing(/(src|href)="silk-file:\/\/([^"]*)"/) { match in
            let attribute = String(match.1)
            let raw = String(match.2).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: "silk-file://" + raw), !url.path.isEmpty else { return String(match.0) }
            let file = URL(fileURLWithPath: url.path)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
            guard attribute == "src", size <= maxSize, let data = try? Data(contentsOf: file) else {
                var address = destination.map { relativePath(from: $0.deletingLastPathComponent(), to: file) }
                    ?? file.absoluteString
                if let query = url.query(percentEncoded: true) { address += "?" + query }
                if let fragment = url.fragment(percentEncoded: true) { address += "#" + fragment }
                return "\(attribute)=\"\(escape(address))\""
            }
            let mime = UTType(filenameExtension: file.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
            return "\(attribute)=\"data:\(mime);base64,\(data.base64EncodedString())\""
        }
    }

    /// 从 directory 到 file 的相对路径（URL 编码过，可以直接放进 href / src）。
    static func relativePath(from directory: URL, to file: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        let parts = Array(repeating: "..", count: from.count - common)
            + to[common...].map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// 在一个不显示的 WKWebView 里排版导出的 HTML，再交给系统打印或存成 PDF。
/// 和屏幕上的预览分开：不受深色模式、大文档占位和对照模式的影响，分页也由 WebKit 按纸张来。
@MainActor
final class PrintRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, any Error>?
    /// 打印结束后调用（总在主线程）。
    var finished: ((Bool) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        // 导出的正文里可能有作者写的 <script>，排版不需要运行它。
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 1100), configuration: config)
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    /// 载入 HTML，等字体和图片都就绪。
    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        _ = try? await webView.callAsyncJavaScript(
            "await document.fonts.ready; await Promise.all([...document.images].map((i) => i.decode().catch(() => {}))); return true",
            contentWorld: .defaultClient
        )
    }

    /// 打印或存成 PDF。pdf 不为空时直接写到那个文件，不弹打印面板。
    func run(for window: NSWindow, pdf: URL?, done: @escaping (Bool) -> Void) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 48
        info.bottomMargin = 48
        info.leftMargin = 48
        info.rightMargin = 48
        info.isVerticallyCentered = false
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.jobTitle = window.title
        if pdf != nil {
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
        }
        finished = done
        operation.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
        )
    }

    /// 打印面板点了「打印」后，系统在后台线程跑完打印，也在那个线程回调这里。
    /// 不能假设在主线程（假设了会被 Swift 的线程检查直接终止），切回主线程再处理。
    @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.finished?(success)
                self.finished = nil
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // 只载入自己给的那一页，不跟着链接跳走。
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
