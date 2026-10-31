import Foundation

/// 磁盘上的文本文件：读的时候认出编码和 BOM，写回时原样保留。
struct TextFile: Equatable {
    var text: String
    var encoding: String.Encoding
    var bom: Data

    static func read(_ url: URL) throws -> TextFile {
        decode(try Data(contentsOf: url))
    }

    // MARK: - 编码探测

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    )

    static func decode(_ data: Data) -> TextFile {
        let boms: [(Data, String.Encoding)] = [
            (Data([0xEF, 0xBB, 0xBF]), .utf8),
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian),
        ]
        for (bom, encoding) in boms where data.starts(with: bom) {
            if let text = String(data: data.dropFirst(bom.count), encoding: encoding) {
                return TextFile(text: text, encoding: encoding, bom: bom)
            }
        }
        // 没有 BOM 的 UTF-16 只在明显像的时候才认（ASCII 字符的另一半字节全是 0）。
        // 不能直接试着解码：偶数长度的任何字节几乎都能被「解」成 UTF-16 乱码。
        // 要排在 UTF-8 前面：夹着 0 字节的 ASCII 也是合法的 UTF-8。
        if let encoding = utf16WithoutBOM(data), let text = String(data: data, encoding: encoding) {
            return TextFile(text: text, encoding: encoding, bom: Data())
        }
        if let text = String(data: data, encoding: .utf8) {
            return TextFile(text: text, encoding: .utf8, bom: Data())
        }
        if looksLikeGB(data), let text = String(data: data, encoding: gb18030) {
            return TextFile(text: text, encoding: gb18030, bom: Data())
        }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return TextFile(text: text, encoding: encoding, bom: Data())
            }
        }
        return TextFile(text: String(decoding: data, as: UTF8.self), encoding: .utf8, bom: Data())
    }

    private static func utf16WithoutBOM(_ data: Data) -> String.Encoding? {
        guard data.count >= 4, data.count % 2 == 0 else { return nil }
        let sample = data.prefix(4096)
        var evenZeros = 0
        var oddZeros = 0
        for (i, byte) in sample.enumerated() where byte == 0 {
            if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = sample.count / 2
        if oddZeros * 10 >= pairs * 4 && evenZeros * 20 < pairs { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 4 && oddZeros * 20 < pairs { return .utf16BigEndian }
        return nil
    }

    /// 像不像 GB18030 中文。分两步：
    /// 1. 字节结构：单字节 00–7F；双字节 81–FE + 40–7E/80–FE；四字节 81–FE 30–39 81–FE 30–39。
    ///    西文单字节编码里常见「重音字母 + 空格 / 标点 / 结尾」，凑不成合法的双字节。
    /// 2. 解出来的非 ASCII 字符基本都是中日韩文字、全角标点或 emoji。
    /// 3. 短的西文片段也可能碰巧凑成合法双字节（比如 Größe 里的 öß）。中文字通常连着出现（词、全角标点），
    ///    西文的重音字母大多单个夹在 ASCII 字母中间。所以还要满足其一：有四字节序列；平均每段连续的多字节字符
    ///    不少于 1.5 个；或者绝大多数双字节的第二个字节在 A1–FE（GB2312 常用字都是这样，单个汉字也能认出来）。
    private static func looksLikeGB(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var pairs = 0
        var highTrail = 0
        var quads = 0
        var runs = 0
        var inRun = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 {
                inRun = false
                i += 1
                continue
            }
            if !inRun {
                runs += 1
                inRun = true
            }
            guard (0x81...0xFE).contains(b), i + 1 < bytes.count else { return false }
            let t = bytes[i + 1]
            if (0x30...0x39).contains(t) {
                guard i + 3 < bytes.count, (0x81...0xFE).contains(bytes[i + 2]), (0x30...0x39).contains(bytes[i + 3]) else {
                    return false
                }
                quads += 1
                i += 4
            } else if (0x40...0x7E).contains(t) || (0x80...0xFE).contains(t) {
                pairs += 1
                if t >= 0x80 { highTrail += 1 }
                i += 2
            } else {
                return false
            }
        }
        let chars = pairs + quads
        guard chars > 0 else { return false }
        let clustered = chars * 2 >= runs * 3
        let mostlyHighTrail = highTrail * 10 >= pairs * 8
        guard quads > 0 || clustered || mostlyHighTrail else { return false }

        guard let text = String(data: data, encoding: gb18030) else { return false }
        var nonASCII = 0
        var cjk = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            nonASCII += 1
            if isCJKLike(scalar.value) { cjk += 1 }
        }
        return nonASCII > 0 && cjk * 10 >= nonASCII * 9
    }

    private static func isCJKLike(_ v: UInt32) -> Bool {
        switch v {
        case 0x2E80...0x2FDF,  // 部首
             0x3000...0x303F,  // 中文标点
             0x3040...0x30FF,  // 假名
             0x3100...0x31BF,  // 注音
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // 汉字
             0xAC00...0xD7AF,  // 韩文
             0xFE30...0xFE4F, 0xFF00...0xFFEF,  // 全角
             0x2000...0x206F, 0x2100...0x27BF,  // 常见符号：破折号、引号、箭头、①、☆
             0x00B7, 0x00D7, 0x00F7,  // · × ÷
             0x1F000...0x1FAFF,  // emoji
             0x20000...0x3134F:  // 扩展汉字
            return true
        default:
            return false
        }
    }

    // MARK: - 写入

    /// 把新内容按原来的编码写回。原编码表示不了新内容（比如在 Latin-1 文件里打了中文）时改用 UTF-8。
    /// 返回实际使用的格式。
    @discardableResult
    func write(_ text: String, to url: URL) throws -> TextFile {
        var format = self
        format.text = text
        var body = text.data(using: encoding)
        if body == nil {
            format.encoding = .utf8
            format.bom = bom == Data([0xEF, 0xBB, 0xBF]) ? bom : Data()
            body = Data(text.utf8)
        }
        let data = format.bom + body!

        // 软链接写到它指向的文件上，链接本身保持不动；原子写入会生成新文件，权限照原来的设回去。
        let target = url.resolvingSymlinksInPath()
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return format
    }
}
