import AppKit

/// 编辑器里的 Markdown 语法着色。
/// 打字时只重算改动的段落；代码块的范围单独维护，只有改到 ``` 这一行才整篇重算。
@MainActor
final class MarkdownHighlighter {
    private(set) var fontSize: CGFloat
    /// 代码块：start 是开头围栏行的位置，close 是结尾围栏行的位置（没闭合为 nil），end 是代码块结束位置。
    struct Fence: Equatable {
        var start: Int
        var close: Int?
        var end: Int
    }

    private var fences: [Fence] = []
    private var fullPassGeneration = 0

    private var font = NSFont()
    private var boldFont = NSFont()
    private var italicFont = NSFont()
    let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.18
        style.paragraphSpacing = 2
        return style
    }()

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        makeFonts()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        makeFonts()
    }

    private func makeFonts() {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    // MARK: - 规则

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fenceLine = regex(#"^ {0,3}(`{3,}|~{3,})"#)
    private static let heading = regex(#"^(#{1,6})[ \t].*$"#)
    private static let quote = regex(#"^ {0,3}(>[ >]*).*$"#)
    private static let listMarker = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t])?"#)
    private static let rule = regex(#"^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = regex(#"(!?\[)([^\]\n]*)(\]\([^)\n]*\))"#)
    private static let wiki = regex(#"!?\[\[[^\]\n]+\]\]"#)
    private static let autolink = regex(#"<?https?://[^\s<>)]+>?"#)
    private static let html = regex(#"</?[A-Za-z][^>\n]*>"#)
    private static let math = regex(#"\$[^$\n]+\$|\\\(.+?\\\)"#)

    // MARK: - 整篇

    /// 整篇着色。前一段同步做完（首屏立刻有颜色），剩下的分批在后面的循环里做，不卡打开。
    func highlightAll(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        fences = Self.findFences(in: text)
        fullPassGeneration += 1
        let generation = fullPassGeneration
        let chunk = 120_000

        func pass(from start: Int) {
            guard generation == fullPassGeneration else { return }
            let length = storage.length
            guard start < length else { return }
            let text = storage.string as NSString
            let end = min(length, start + chunk)
            let range = text.paragraphRange(for: NSRange(location: start, length: end - start))
            storage.beginEditing()
            apply(storage, in: range)
            storage.endEditing()
            if NSMaxRange(range) < length {
                DispatchQueue.main.async { MainActor.assumeIsolated { pass(from: NSMaxRange(range)) } }
            }
        }

        if storage.length == 0 {
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: 0))
            return
        }
        pass(from: 0)
    }

    // MARK: - 增量

    /// 在 NSTextStorage 处理编辑时调用：editedRange 是改动后的范围，delta 是长度变化。
    func textDidEdit(_ storage: NSTextStorage, editedRange: NSRange, delta: Int) {
        let text = storage.string as NSString
        let oldEditEnd = editedRange.location + editedRange.length - delta
        let paragraph = text.paragraphRange(for: editedRange)

        // 改动碰到了围栏行开头（``` 所在处），或者新写出了 ```，整篇重算代码块。
        let edit = NSRange(location: editedRange.location, length: max(1, oldEditEnd - editedRange.location))
        let touchesFence = fences.contains { fence in
            NSIntersectionRange(edit, NSRange(location: fence.start, length: 8)).length > 0
                || fence.close.map { NSIntersectionRange(edit, NSRange(location: $0, length: 8)).length > 0 } ?? false
        }
        let writesFence = Self.fenceLine.firstMatch(in: text as String, range: paragraph) != nil

        if touchesFence || writesFence {
            let old = fences
            fences = Self.findFences(in: text)
            if old.count != fences.count || zip(old, fences).contains(where: { $0.start != $1.start || ($0.close == nil) != ($1.close == nil) }) {
                // 代码块结构变了：从改动处往后整段重新着色。
                let start = text.paragraphRange(for: NSRange(location: min(editedRange.location, text.length), length: 0)).location
                apply(storage, in: NSRange(location: start, length: text.length - start))
                return
            }
        } else {
            // 只平移代码块范围。
            fences = fences.map { fence in
                var f = fence
                if f.start >= oldEditEnd { f.start += delta }
                if let close = f.close, close >= oldEditEnd { f.close = close + delta }
                if f.end >= oldEditEnd { f.end += delta }
                return f
            }
        }
        apply(storage, in: paragraph)
    }

    // MARK: - 着色

    private func apply(_ storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0 else { return }
        storage.setAttributes(baseAttributes, range: range)
        let text = storage.string as NSString
        let string = storage.string
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = NSRange(location: line.location, length: lineContentLength(text, line))
            if let fence = fence(containing: line.location) {
                // 代码块：围栏行淡色，内容用次要文字色。
                let isFenceLine = line.location == fence.start || line.location == fence.close
                storage.addAttribute(.foregroundColor, value: isFenceLine ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor, range: content)
            } else {
                styleLine(storage, string, content)
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
    }

    private func lineContentLength(_ text: NSString, _ line: NSRange) -> Int {
        var length = line.length
        while length > 0 {
            let c = text.character(at: line.location + length - 1)
            if c == 0x0A || c == 0x0D { length -= 1 } else { break }
        }
        return length
    }

    private func styleLine(_ storage: NSTextStorage, _ string: String, _ range: NSRange) {
        guard range.length > 0 else { return }
        let marker = NSColor.tertiaryLabelColor
        let accent = NSColor.controlAccentColor

        if let m = Self.heading.firstMatch(in: string, range: range) {
            storage.addAttribute(.font, value: boldFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
            return
        }
        if Self.rule.firstMatch(in: string, range: range) != nil {
            storage.addAttribute(.foregroundColor, value: marker, range: range)
            return
        }
        if let m = Self.quote.firstMatch(in: string, range: range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
        }
        if let m = Self.listMarker.firstMatch(in: string, range: range) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
            if m.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 2))
            }
        }

        for m in Self.bold.matches(in: string, range: range) {
            storage.addAttribute(.font, value: boldFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        for m in Self.italic.matches(in: string, range: range) {
            storage.addAttribute(.font, value: italicFont, range: m.range(at: 2))
        }
        for m in Self.strike.matches(in: string, range: range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
        }
        for m in Self.html.matches(in: string, range: range) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: m.range)
        }
        for m in Self.link.matches(in: string, range: range) {
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 3))
        }
        for regex in [Self.wiki, Self.autolink] {
            for m in regex.matches(in: string, range: range) {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
            }
        }
        for m in Self.math.matches(in: string, range: range) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: m.range)
        }
        // 行内代码最后上色，覆盖里面误判的强调和链接。
        for m in Self.code.matches(in: string, range: range) {
            storage.addAttributes([.font: font, .foregroundColor: NSColor.systemPink], range: m.range)
            storage.removeAttribute(.strikethroughStyle, range: m.range)
        }
    }

    // MARK: - 代码块

    private func fence(containing location: Int) -> Fence? {
        var lo = 0
        var hi = fences.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = fences[mid]
            if location < f.start { hi = mid - 1 }
            else if location >= f.end { lo = mid + 1 }
            else { return f }
        }
        return nil
    }

    /// 找出所有 ``` / ~~~ 代码块（含围栏行）。没闭合的代码块延续到文末。
    static func findFences(in text: NSString) -> [Fence] {
        var result: [Fence] = []
        var open: (start: Int, char: unichar, count: Int)?
        var location = 0
        let length = text.length
        while location < length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var i = line.location
            var indent = 0
            while i < NSMaxRange(line), indent < 4, text.character(at: i) == 0x20 { i += 1; indent += 1 }
            if indent < 4, i < NSMaxRange(line) {
                let c = text.character(at: i)
                if c == 0x60 || c == 0x7E {  // ` ~
                    var n = 0
                    while i + n < NSMaxRange(line), text.character(at: i + n) == c { n += 1 }
                    if n >= 3 {
                        if let o = open {
                            if c == o.char && n >= o.count {
                                result.append(Fence(start: o.start, close: line.location, end: NSMaxRange(line)))
                                open = nil
                            }
                        } else {
                            open = (line.location, c, n)
                        }
                    }
                }
            }
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if let o = open { result.append(Fence(start: o.start, close: nil, end: length)) }
        return result
    }
}
