import Foundation

/// 文件夹全文搜索：在一批 Markdown 文件里找一段文字，不分大小写、全半角。不碰界面，可以在后台跑。
enum FolderSearch {
    struct Match: Sendable, Equatable {
        let url: URL
        /// 第几行，从 0 开始（和编辑器、预览的行号一致）。
        let line: Int
        /// 命中的文字在全文里的位置（UTF-16）。
        let range: NSRange
        /// 给列表显示的那一行（太长时截掉命中处之前的一部分）。
        let snippet: String
        /// 命中的文字在 snippet 里的位置。
        let highlight: NSRange
    }

    struct Result: Sendable {
        var matches: [Match] = []
        var fileCount = 0
        /// 结果太多，有命中没列出来（总数到顶，或某个文件超过了单个文件的上限）。
        /// 这时 matches.count、fileCount 都只是列出来的部分，不是实际总数。
        var truncated = false
    }

    static let options: NSString.CompareOptions = [.caseInsensitive, .widthInsensitive]

    /// 在 files 里找 query。一个文件最多列 perFile 处，总共最多 limit 处；isCancelled 返回 true 时尽快停下。
    static func search(
        _ query: String, in files: [URL], limit: Int = 1000, perFile: Int = 200,
        isCancelled: () -> Bool = { false }
    ) -> Result {
        var result = Result()
        let query = query.trimmingCharacters(in: .newlines)
        guard !query.isEmpty else { return result }
        for url in files {
            if isCancelled() { break }
            // 太大的不是给人看的 Markdown（日志、导出的数据），不进去找。
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= 20 << 20, let text = try? TextFile.read(url).text else { continue }
            // 多找一处：找到的比要的多，就说明这里还有没列出来的。
            let wanted = min(perFile, limit - result.matches.count)
            let found = matches(of: query, in: text, url: url, max: wanted + 1)
            if found.count > wanted { result.truncated = true }
            let kept = found.prefix(wanted)
            if !kept.isEmpty {
                result.fileCount += 1
                result.matches += kept
            }
            // 总数到顶了，后面的文件不用再看。
            if result.truncated, result.matches.count >= limit { break }
        }
        return result
    }

    /// 一篇文字里的命中处。
    static func matches(of query: String, in text: String, url: URL, max: Int = .max) -> [Match] {
        let ns = text as NSString
        var lines: LineIndex?
        var found: [Match] = []
        var location = 0
        while location < ns.length, found.count < max {
            let range = ns.range(of: query, options: options, range: NSRange(location: location, length: ns.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if lines == nil { lines = LineIndex(ns) }
            let line = lines!.line(at: range.location)
            let lineRange = lines!.range(ofLine: line)
            let (snippet, highlight) = makeSnippet(ns, line: lineRange, match: range)
            found.append(Match(url: url, line: line, range: range, snippet: snippet, highlight: highlight))
            location = NSMaxRange(range)
        }
        return found
    }

    /// 命中所在的那一行，去掉行首空白；命中太靠后时，前面只留一小段，保证列表里看得到命中的字。
    private static func makeSnippet(_ text: NSString, line: NSRange, match: NSRange) -> (String, NSRange) {
        var start = line.location
        let end = NSMaxRange(line)
        while start < match.location, let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) {
            start += 1
        }
        var prefix = ""
        let lead = 24
        if match.location - start > lead {
            start = match.location - lead
            // 不要从一个字（代理对）中间切开。
            if CFStringIsSurrogateLowCharacter(text.character(at: start)) { start -= 1 }
            prefix = "…"
        }
        // 太长的行只留前面一段，列表里一行也显示不下。
        let length = min(end - start, 400)
        var snippet = prefix + text.substring(with: NSRange(location: start, length: max(0, length)))
        snippet = snippet.replacingOccurrences(of: "\t", with: " ")
        if snippet.hasSuffix("\r") { snippet.removeLast() }
        let offset = (prefix as NSString).length + match.location - start
        let visible = max(0, min(match.length, (snippet as NSString).length - offset))
        return (snippet, NSRange(location: offset, length: visible))
    }
}
