import Foundation

/// 按行比较两段文字：磁盘上的版本（old）和编辑器里的内容（new）。
enum LineDiff {
    enum Kind: Equatable { case same, removed, added }

    struct Line: Equatable {
        let kind: Kind
        let text: String
        /// 在旧文本里是第几行（从 1 开始）；新增的行没有。
        let old: Int?
        /// 在新文本里是第几行（从 1 开始）；删掉的行没有。
        let new: Int?
    }

    /// 一段连续显示的差异；两段之间省略了没变的行。
    struct Hunk: Equatable {
        let lines: [Line]
    }

    /// 按换行切开。Swift 把 \r\n 当成一个字符，按 "\n" 切不开 Windows 换行，所以按「是不是换行」切。
    static func split(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// 全部行，删掉的排在同一处新增的前面。
    static func lines(old: String, new: String) -> [Line] {
        let a = split(old)
        let b = split(new)
        // 先去掉相同的开头和结尾，只对中间变了的部分求差异，大文件也快。
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in midB.difference(from: midA) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Line] = []
        result.reserveCapacity(a.count + inserted.count)
        for k in 0..<prefix { result.append(Line(kind: .same, text: String(a[k]), old: k + 1, new: k + 1)) }
        var i = 0
        var j = 0
        while i < midA.count || j < midB.count {
            if i < midA.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: String(midA[i]), old: prefix + i + 1, new: nil))
                i += 1
            } else if j < midB.count, inserted.contains(j) {
                result.append(Line(kind: .added, text: String(midB[j]), old: nil, new: prefix + j + 1))
                j += 1
            } else {
                result.append(Line(kind: .same, text: String(midA[i]), old: prefix + i + 1, new: prefix + j + 1))
                i += 1
                j += 1
            }
        }
        for k in 0..<suffix {
            let oldIndex = a.count - suffix + k
            let newIndex = b.count - suffix + k
            result.append(Line(kind: .same, text: String(a[oldIndex]), old: oldIndex + 1, new: newIndex + 1))
        }
        return result
    }

    /// 只留变了的行和前后 context 行上下文。
    static func hunks(_ lines: [Line], context: Int = 3) -> [Hunk] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.kind != .same {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep[k] = true }
        }
        var hunks: [Hunk] = []
        var current: [Line] = []
        for (index, line) in lines.enumerated() {
            if keep[index] {
                current.append(line)
            } else if !current.isEmpty {
                hunks.append(Hunk(lines: current))
                current = []
            }
        }
        if !current.isEmpty { hunks.append(Hunk(lines: current)) }
        return hunks
    }

    static func stats(_ lines: [Line]) -> (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { count, line in
            if line.kind == .added { count.0 += 1 }
            if line.kind == .removed { count.1 += 1 }
        }
    }
}
