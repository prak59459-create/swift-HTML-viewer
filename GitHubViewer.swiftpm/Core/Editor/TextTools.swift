import Foundation

/// あいまい検索の結果。
public struct FuzzyMatch<Element>: Sendable where Element: Sendable {
    public var element: Element
    public var score: Int
    /// 一致した文字の位置 (強調表示に使う)。
    public var matchedIndices: [Int]

    public init(element: Element, score: Int, matchedIndices: [Int]) {
        self.element = element
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// ファイル名などのあいまい検索 (⌘P 相当)。
public enum FuzzySearch {

    /// 候補を絞り込んで、点数の高い順に返す。
    public static func search<Element: Sendable>(
        _ query: String, in items: [Element], limit: Int = 50,
        key: (Element) -> String) -> [FuzzyMatch<Element>] {
        guard !query.isEmpty else {
            return items.prefix(limit).map {
                FuzzyMatch(element: $0, score: 0, matchedIndices: [])
            }
        }
        var results: [FuzzyMatch<Element>] = []
        for item in items {
            guard let scored = score(query: query, candidate: key(item)) else { continue }
            results.append(FuzzyMatch(element: item, score: scored.score,
                                      matchedIndices: scored.indices))
        }
        results.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return key(left.element).count < key(right.element).count
        }
        return Array(results.prefix(limit))
    }

    /// 1 つの候補の点数。頭文字・連続・単語の先頭を高く評価する。
    public static func score(query: String, candidate: String)
        -> (score: Int, indices: [Int])? {
        let queryCharacters = Array(query.lowercased())
        let candidateCharacters = Array(candidate)
        let lowered = Array(candidate.lowercased())
        guard !queryCharacters.isEmpty, queryCharacters.count <= lowered.count else {
            return nil
        }

        var indices: [Int] = []
        var total = 0
        var queryIndex = 0
        var previousMatch = -2

        for (index, character) in lowered.enumerated() {
            guard queryIndex < queryCharacters.count else { break }
            guard character == queryCharacters[queryIndex] else { continue }

            var points = 1
            // 連続していれば高得点。
            if index == previousMatch + 1 { points += 5 }
            // 単語の先頭 (先頭・区切りのあと・大文字) も高得点。
            if index == 0 { points += 8 }
            else {
                let before = candidateCharacters[index - 1]
                if before == "/" || before == "_" || before == "-" || before == "."
                    || before == " " {
                    points += 6
                }
                if candidateCharacters[index].isUppercase, before.isLowercase {
                    points += 4
                }
            }
            total += points
            indices.append(index)
            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        // 短い候補ほど良い。
        total += Swift.max(0, 20 - candidateCharacters.count / 4)
        return (total, indices)
    }
}

/// 差分の 1 行。
public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case unchanged
        case added
        case removed
    }

    public var kind: Kind
    public var text: String
    /// 変更前の行番号 (追加行なら nil)。
    public var oldLine: Int?
    /// 変更後の行番号 (削除行なら nil)。
    public var newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

/// 差分のまとまり (変更のある場所とその周り)。
public struct DiffHunk: Equatable, Sendable {
    public var lines: [DiffLine]
    public var oldStart: Int
    public var newStart: Int

    public init(lines: [DiffLine], oldStart: Int, newStart: Int) {
        self.lines = lines
        self.oldStart = oldStart
        self.newStart = newStart
    }

    public var header: String {
        let oldCount = lines.filter { $0.kind != .added }.count
        let newCount = lines.filter { $0.kind != .removed }.count
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }
}

/// 差分の集計。
public struct DiffSummary: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var unchanged: Int

    public init(added: Int, removed: Int, unchanged: Int) {
        self.added = added
        self.removed = removed
        self.unchanged = unchanged
    }

    public var hasChanges: Bool { added > 0 || removed > 0 }

    public var description: String { "+\(added) -\(removed)" }
}

/// 行単位の差分。
public enum DiffEngine {

    /// 2 つの本文の差分を行単位で求める。
    public static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        return diff(oldLines: oldLines, newLines: newLines)
    }

    /// 行の配列から差分を求める (最長共通部分列)。
    public static func diff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        // 先頭と末尾の同じ部分は先に切り落として、表を小さくする。
        var head = 0
        while head < oldLines.count, head < newLines.count,
              oldLines[head] == newLines[head] {
            head += 1
        }
        var tail = 0
        while tail < oldLines.count - head, tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] {
            tail += 1
        }

        let oldMiddle = Array(oldLines[head..<(oldLines.count - tail)])
        let newMiddle = Array(newLines[head..<(newLines.count - tail)])

        var result: [DiffLine] = []
        for index in 0..<head {
            result.append(DiffLine(kind: .unchanged, text: oldLines[index],
                                   oldLine: index + 1, newLine: index + 1))
        }
        result += middleDiff(oldMiddle, newMiddle, oldOffset: head, newOffset: head)
        for index in 0..<tail {
            let oldIndex = oldLines.count - tail + index
            let newIndex = newLines.count - tail + index
            result.append(DiffLine(kind: .unchanged, text: oldLines[oldIndex],
                                   oldLine: oldIndex + 1, newLine: newIndex + 1))
        }
        return result
    }

    /// 真ん中の部分を最長共通部分列で比べる。
    private static func middleDiff(_ oldLines: [String], _ newLines: [String],
                                   oldOffset: Int, newOffset: Int) -> [DiffLine] {
        guard !oldLines.isEmpty || !newLines.isEmpty else { return [] }
        // 大きすぎるときは、まとめて「消して足した」ことにする (計算量を抑える)。
        let budget = 4_000_000
        if oldLines.count * newLines.count > budget {
            var result: [DiffLine] = oldLines.enumerated().map {
                DiffLine(kind: .removed, text: $0.element,
                         oldLine: oldOffset + $0.offset + 1, newLine: nil)
            }
            result += newLines.enumerated().map {
                DiffLine(kind: .added, text: $0.element, oldLine: nil,
                         newLine: newOffset + $0.offset + 1)
            }
            return result
        }

        let rows = oldLines.count
        let columns = newLines.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1),
                            count: rows + 1)
        if rows > 0, columns > 0 {
            for row in stride(from: rows - 1, through: 0, by: -1) {
                for column in stride(from: columns - 1, through: 0, by: -1) {
                    table[row][column] = oldLines[row] == newLines[column]
                        ? table[row + 1][column + 1] + 1
                        : Swift.max(table[row + 1][column], table[row][column + 1])
                }
            }
        }

        var result: [DiffLine] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if oldLines[row] == newLines[column] {
                result.append(DiffLine(kind: .unchanged, text: oldLines[row],
                                       oldLine: oldOffset + row + 1,
                                       newLine: newOffset + column + 1))
                row += 1
                column += 1
                continue
            }
            if table[row + 1][column] >= table[row][column + 1] {
                result.append(DiffLine(kind: .removed, text: oldLines[row],
                                       oldLine: oldOffset + row + 1, newLine: nil))
                row += 1
            } else {
                result.append(DiffLine(kind: .added, text: newLines[column],
                                       oldLine: nil,
                                       newLine: newOffset + column + 1))
                column += 1
            }
        }
        while row < rows {
            result.append(DiffLine(kind: .removed, text: oldLines[row],
                                   oldLine: oldOffset + row + 1, newLine: nil))
            row += 1
        }
        while column < columns {
            result.append(DiffLine(kind: .added, text: newLines[column], oldLine: nil,
                                   newLine: newOffset + column + 1))
            column += 1
        }
        return result
    }

    /// 変更のある場所だけを、前後の行を添えて取り出す。
    public static func hunks(_ lines: [DiffLine], context: Int = 3) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var current: [DiffLine] = []
        var pendingContext: [DiffLine] = []
        var trailing = 0

        func flush() {
            guard !current.isEmpty else { return }
            let oldStart = current.first(where: { $0.oldLine != nil })?.oldLine ?? 0
            let newStart = current.first(where: { $0.newLine != nil })?.newLine ?? 0
            hunks.append(DiffHunk(lines: current, oldStart: oldStart, newStart: newStart))
            current = []
        }

        for line in lines {
            if line.kind == .unchanged {
                if current.isEmpty {
                    pendingContext.append(line)
                    if pendingContext.count > context { pendingContext.removeFirst() }
                    continue
                }
                current.append(line)
                trailing += 1
                if trailing >= context * 2 {
                    // 後ろの余分な行は落とす。
                    current.removeLast(trailing - context)
                    flush()
                    trailing = 0
                }
                continue
            }
            if current.isEmpty {
                current = pendingContext
                pendingContext = []
            }
            current.append(line)
            trailing = 0
        }
        if trailing > context { current.removeLast(trailing - context) }
        flush()
        return hunks
    }

    /// 差分の集計。
    public static func summary(_ lines: [DiffLine]) -> DiffSummary {
        DiffSummary(added: lines.filter { $0.kind == .added }.count,
                    removed: lines.filter { $0.kind == .removed }.count,
                    unchanged: lines.filter { $0.kind == .unchanged }.count)
    }

    /// unified diff の形に整える。
    public static func unified(old: String, new: String, oldName: String = "a",
                               newName: String = "b", context: Int = 3) -> String {
        let lines = diff(old: old, new: new)
        let hunkList = hunks(lines, context: context)
        guard !hunkList.isEmpty else { return "" }
        var output = ["--- \(oldName)", "+++ \(newName)"]
        for hunk in hunkList {
            output.append(hunk.header)
            for line in hunk.lines {
                switch line.kind {
                case .unchanged: output.append(" " + line.text)
                case .added: output.append("+" + line.text)
                case .removed: output.append("-" + line.text)
                }
            }
        }
        return output.joined(separator: "\n")
    }

    /// 左右に並べて見せるための組。
    public static func sideBySide(_ lines: [DiffLine])
        -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(left: DiffLine?, right: DiffLine?)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .unchanged:
                rows.append((line, line))
                index += 1
            case .removed:
                // 続く追加行と組にする。
                var removed: [DiffLine] = []
                while index < lines.count, lines[index].kind == .removed {
                    removed.append(lines[index])
                    index += 1
                }
                var added: [DiffLine] = []
                while index < lines.count, lines[index].kind == .added {
                    added.append(lines[index])
                    index += 1
                }
                for offset in 0..<Swift.max(removed.count, added.count) {
                    rows.append((offset < removed.count ? removed[offset] : nil,
                                 offset < added.count ? added[offset] : nil))
                }
            case .added:
                rows.append((nil, line))
                index += 1
            }
        }
        return rows
    }
}
