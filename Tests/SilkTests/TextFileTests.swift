import Foundation
import Testing
@testable import Silk

@Suite struct TextFileTests {
    @Test func UTF8() {
        let file = TextFile.decode(Data("# 你好".utf8))
        #expect(file.text == "# 你好")
        #expect(file.encoding == .utf8)
        #expect(file.bom.isEmpty)
    }

    @Test func 偶数字节的Latin1不会被当成UTF16() {
        let data = "Café naïve".data(using: .isoLatin1)!
        #expect(data.count % 2 == 0)
        #expect(TextFile.decode(data).text == "Café naïve")
    }

    @Test func Windows1252的弯引号() {
        // “Hi” 加换行，6 个字节
        #expect(TextFile.decode(Data([0x93, 0x48, 0x69, 0x94, 0x0A, 0x41])).text == "\u{201C}Hi\u{201D}\nA")
    }

    @Test func GB18030中文() {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = "# 标题\n\n这是一段中文。".data(using: gb)!
        #expect(TextFile.decode(data).text == "# 标题\n\n这是一段中文。")
    }

    @Test func 带BOM的UTF16写回保留BOM() throws {
        let dir = TempDir()
        let url = dir.write("a.md", bytes: [0xFF, 0xFE] + Array("# a".data(using: .utf16LittleEndian)!))
        let file = try TextFile.read(url)
        #expect(file.text == "# a")
        try file.write("# 中文", to: url)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.starts(with: [0xFF, 0xFE]))
        #expect(try TextFile.read(url).text == "# 中文")
    }

    @Test func 没有BOM的UTF16() {
        let data = "# Title\nhello".data(using: .utf16LittleEndian)!
        let file = TextFile.decode(data)
        #expect(file.text == "# Title\nhello")
        #expect(file.encoding == .utf16LittleEndian)
    }

    @Test func 原编码写不下新内容时改用UTF8() throws {
        let dir = TempDir()
        let url = dir.write("a.md", bytes: Array("Café".data(using: .isoLatin1)!))
        let file = try TextFile.read(url)
        let written = try file.write("Café 中文", to: url)
        #expect(written.encoding == .utf8)
        #expect(dir.read("a.md") == "Café 中文")
    }

    @Test func 保存软链接写到目标文件_链接保持不变() throws {
        let dir = TempDir()
        let real = dir.write("real.md", "原文")
        let link = dir.url.appending(path: "link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try TextFile.read(link).write("新内容", to: link)

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(dir.read("real.md") == "新内容")
    }

    @Test func 保存后保留文件权限() throws {
        let dir = TempDir()
        let url = dir.write("a.md", "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try TextFile.read(url).write("b", to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    private static let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    @Test(arguments: [
        "# 這是繁體中文們的說明文件\n\n內容。",
        "# 简体里的 GBK 字：镕基、啰嗦、堃",
        "表情 😀 和生僻字 𠀀",
        "# 标题\n\n这是一段中文，带“引号”和——破折号。",
        "们",
    ])
    func GB18030各种中文都能读对(_ sample: String) {
        let data = sample.data(using: Self.gb)!
        let file = TextFile.decode(data)
        #expect(file.text == sample)
        #expect(file.encoding.rawValue == Self.gb.rawValue)
    }

    @Test(arguments: ["naïve résumé", "Café au lait", "Größe: 5 µm", "señor ñandú"])
    func 西文单字节文本不会被当成GB18030(_ sample: String) {
        let data = sample.data(using: .windowsCP1252)!
        #expect(TextFile.decode(data).text == sample)
    }
}
