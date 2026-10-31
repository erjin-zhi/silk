import Foundation

/// 每行开头在 UTF-16 里的位置，用来在字符位置和行号之间换算。
/// 行号从 0 开始，和预览端 markdown-it 的行号一致。
struct LineIndex {
    private(set) var starts: [Int] = [0]
    private(set) var length = 0

    init() {}

    init(_ string: NSString) {
        length = string.length
        var starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        let chunk = 1 << 16
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = 0
        while location < length {
            let n = min(chunk, length - location)
            buffer.withUnsafeMutableBufferPointer { ptr in
                string.getCharacters(ptr.baseAddress!, range: NSRange(location: location, length: n))
                for i in 0..<n where ptr[i] == 0x0A {
                    starts.append(location + i + 1)
                }
            }
            location += n
        }
        self.starts = starts
    }

    var lineCount: Int { starts.count }

    /// offset 所在的行。
    func line(at offset: Int) -> Int {
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 某行的字符范围（不含换行符）。
    func range(ofLine line: Int) -> NSRange {
        let line = max(0, min(line, starts.count - 1))
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }
}
