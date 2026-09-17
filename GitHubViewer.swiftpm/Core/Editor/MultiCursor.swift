import Foundation

// MARK: - 13. 複数カーソル

/// 選択 1 つぶん (UTF-16 の位置)。長さ 0 ならただのカーソル。
public struct TextSelection: Identifiable, Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public var id: String { "\(location):\(length)" }

    public init(location: Int, length: Int = 0) {
        self.location = Swift.max(0, location)
        self.length = Swift.max(0, length)
    }

    public var end: Int { location + length }
    public var isCaret: Bool { length == 0 }

    public func overlaps(_ other: TextSelection) -> Bool {
        location < other.end && other.location < end
    }

    /// 2 つをつなげる。
    public func union(_ other: TextSelection) -> TextSelection {
        let start = Swift.min(location, other.location)
        return TextSelection(location: start,
                             length: Swift.max(end, other.end) - start)
    }
}

/// 複数のカーソルと選択をまとめて扱う。
public struct MultiSelection: Equatable, Sendable {
    /// 位置の小さい順に並び、重なりは 1 つにまとめてある。
    public private(set) var selections: [TextSelection]

    public init(_ selections: [TextSelection] = []) {
        self.selections = MultiSelection.normalize(selections)
    }

    public init(caretAt location: Int) {
        self.init([TextSelection(location: location)])
    }

    public var isEmpty: Bool { selections.isEmpty }
    public var count: Int { selections.count }
    public var primary: TextSelection? { selections.first }

    /// 重なりをまとめて、位置順に並べる。
    static func normalize(_ input: [TextSelection]) -> [TextSelection] {
        let sorted = input.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var result: [TextSelection] = []
        for selection in sorted {
            guard let last = result.last else {
                result.append(selection)
                continue
            }
            // 重なるか、隣り合うカーソルが同じ位置なら 1 つにする。
            if selection.location < last.end
                || (selection.isCaret && last.isCaret && selection.location == last.location) {
                result[result.count - 1] = last.union(selection)
                continue
            }
            result.append(selection)
        }
        return result
    }

    /// 足す。
    public func adding(_ selection: TextSelection) -> MultiSelection {
        MultiSelection(selections + [selection])
    }

    /// 消す。
    public func removing(at index: Int) -> MultiSelection {
        var copy = selections
        guard copy.indices.contains(index) else { return self }
        copy.remove(at: index)
        return MultiSelection(copy)
    }

    /// 1 つだけに戻す。
    public func collapsed() -> MultiSelection {
        guard let primary else { return self }
        return MultiSelection([primary])
    }

    /// すべてのカーソルに同じ文字を入れる。
    public func inserting(_ text: String, into source: String) -> MultiEditResult {
        replacingEach(in: source) { _, _ in text }
    }

    /// すべてのカーソルの手前を 1 文字消す (選択があればそれを消す)。
    public func deletingBackward(in source: String) -> MultiEditResult {
        var units = Array(source.utf16)
        let total = units.count
        var ranges: [(start: Int, end: Int)] = []

        for selection in selections {
            let start = Swift.min(selection.location, total)
            let end = Swift.min(selection.end, total)
            if start == end {
                ranges.append((Swift.max(0, start - 1), start))
            } else {
                ranges.append((start, end))
            }
        }

        // 位置は前から数え直し、本文は後ろから書き換える。
        var newSelections: [TextSelection] = []
        var delta = 0
        for range in ranges {
            newSelections.append(TextSelection(location: range.start + delta))
            delta -= range.end - range.start
        }
        for range in ranges.reversed() where range.start < range.end {
            units.removeSubrange(range.start..<range.end)
        }

        return MultiEditResult(text: String(decoding: units, as: UTF16.self),
                               selections: MultiSelection(newSelections))
    }

    /// カーソルごとに違う文字を入れる (連番など)。
    ///
    /// `replacement` には「何番目か」と「いま選ばれている文字列」が渡る。
    public func replacingEach(in source: String,
                              replacement: (Int, String) -> String) -> MultiEditResult {
        guard !selections.isEmpty else {
            return MultiEditResult(text: source, selections: self)
        }
        let document = TextDocument(source)
        var units = Array(source.utf16)
        let total = units.count

        var texts: [[UInt16]] = []
        for (index, selection) in selections.enumerated() {
            let start = Swift.min(selection.location, total)
            let end = Swift.min(selection.end, total)
            let selected = document.substring(location: start, length: end - start)
            texts.append(Array(replacement(index, selected).utf16))
        }

        // 位置は前から数え直し、本文は後ろから書き換える。
        var newSelections: [TextSelection] = []
        var delta = 0
        for (index, selection) in selections.enumerated() {
            let start = Swift.min(selection.location, total)
            let end = Swift.min(selection.end, total)
            newSelections.append(TextSelection(location: start + delta + texts[index].count))
            delta += texts[index].count - (end - start)
        }
        for (index, selection) in selections.enumerated().reversed() {
            let start = Swift.min(selection.location, units.count)
            let end = Swift.min(selection.end, units.count)
            units.replaceSubrange(start..<end, with: texts[index])
        }

        return MultiEditResult(text: String(decoding: units, as: UTF16.self),
                               selections: MultiSelection(newSelections))
    }

    /// 選んだ文字列と同じものを次に見つけて、カーソルを足す (⌘D 相当)。
    public func addingNextOccurrence(in source: String) -> MultiSelection {
        guard let last = selections.last, !last.isCaret else { return self }
        let document = TextDocument(source)
        let word = document.substring(location: last.location, length: last.length)
        guard !word.isEmpty else { return self }

        var options = SearchOptions()
        options.isCaseSensitive = true
        let matches = TextSearch.matches(of: word, in: source, options: options)
        let taken = Set(selections.map(\.location))
        // いまの最後より後ろで、まだ選んでいないものを探す。
        if let next = matches.first(where: { $0.location > last.location
            && !taken.contains($0.location) }) {
            return adding(TextSelection(location: next.location, length: next.length))
        }
        // 見つからなければ先頭から探し直す。
        if let first = matches.first(where: { !taken.contains($0.location) }) {
            return adding(TextSelection(location: first.location, length: first.length))
        }
        return self
    }

    /// 選んだ文字列と同じものを全部選ぶ。
    public static func allOccurrences(of word: String, in source: String)
        -> MultiSelection {
        guard !word.isEmpty else { return MultiSelection() }
        var options = SearchOptions()
        options.isCaseSensitive = true
        return MultiSelection(TextSearch.matches(of: word, in: source, options: options)
            .map { TextSelection(location: $0.location, length: $0.length) })
    }

    /// 選んだ範囲の各行の行頭 (または行末) にカーソルを置く。
    public static func caretsOnEachLine(of source: String, location: Int, length: Int,
                                        atEnd: Bool = false) -> MultiSelection {
        let document = TextDocument(source)
        let lines = document.lineNumbers(in: location, length: length)
        var carets: [TextSelection] = []
        for line in lines {
            let range = document.lineRange(line)
            carets.append(TextSelection(location: atEnd ? range.location + range.length
                                                        : range.location))
        }
        return MultiSelection(carets)
    }
}

/// 複数のカーソルでまとめて編集した結果。
public struct MultiEditResult: Equatable, Sendable {
    /// 編集したあとの本文。
    public var text: String
    /// 編集したあとのカーソル。
    public var selections: MultiSelection

    public init(text: String, selections: MultiSelection) {
        self.text = text
        self.selections = selections
    }
}

// MARK: - 14. 矩形選択

/// 画面の上で四角く選んだ範囲を、行ごとの選択に直す。
public enum BlockSelection {

    /// 始めの位置と終わりの位置から、行ごとの選択を作る。
    ///
    /// 桁がその行の長さを超えていれば、行末までにする。
    public static func selections(in source: String, from start: TextPosition,
                                  to end: TextPosition) -> MultiSelection {
        let document = TextDocument(source)
        let firstLine = Swift.min(start.line, end.line)
        let lastLine = Swift.max(start.line, end.line)
        let leftColumn = Swift.min(start.column, end.column)
        let rightColumn = Swift.max(start.column, end.column)
        guard firstLine >= 1, lastLine <= document.lineCount else {
            return MultiSelection()
        }

        var result: [TextSelection] = []
        for line in firstLine...lastLine {
            let range = document.lineRange(line)
            let left = Swift.min(leftColumn - 1, range.length)
            let right = Swift.min(rightColumn - 1, range.length)
            result.append(TextSelection(location: range.location + left,
                                        length: Swift.max(0, right - left)))
        }
        return MultiSelection(result)
    }

    /// 矩形選択で選ばれている文字列 (行ごとに 1 行)。
    public static func text(in source: String,
                            selection: MultiSelection) -> String {
        let document = TextDocument(source)
        return selection.selections.map {
            document.substring(location: $0.location, length: $0.length)
        }.joined(separator: "\n")
    }
}
