import Foundation

/// 改行コードの種類。
public enum LineEnding: String, Equatable, CaseIterable, Sendable {
    case lf
    case crlf
    case cr

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 本文から改行コードを推測する。
    public static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r") { return .cr }
        return .lf
    }
}

/// 本文の位置 (1 始まりの行と桁)。
public struct TextPosition: Equatable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

/// 選んでいる範囲の集計。
public struct SelectionSummary: Equatable, Sendable {
    public var characters: Int
    public var lines: Int
    public var words: Int

    public init(characters: Int, lines: Int, words: Int) {
        self.characters = characters
        self.lines = lines
        self.words = words
    }
}

/// 本文を行単位で扱うための索引。
///
/// `UITextView` の `NSRange` (UTF-16 の位置) と、行・桁を行き来する。
public struct TextDocument: Equatable, Sendable {
    public private(set) var text: String
    /// 各行の開始位置 (UTF-16)。
    public private(set) var lineStarts: [Int]
    /// 各行の長さ (改行を含まない、UTF-16)。
    public private(set) var lineLengths: [Int]
    public private(set) var lineEnding: LineEnding

    public init(_ text: String) {
        self.text = text
        self.lineEnding = LineEnding.detect(in: text)
        (self.lineStarts, self.lineLengths) = TextDocument.index(of: text)
    }

    /// 行の開始位置と長さを数える。
    ///
    /// Swift では `\r\n` が 1 つの `Character` になるので、そのまま
    /// 改行として扱えばよい。
    static func index(of text: String) -> ([Int], [Int]) {
        var starts: [Int] = [0]
        var lengths: [Int] = []
        var offset = 0
        var lineLength = 0

        for character in text {
            let width = character.utf16.count
            if character == "\n" || character == "\r\n" || character == "\r" {
                lengths.append(lineLength)
                offset += width
                starts.append(offset)
                lineLength = 0
                continue
            }
            offset += width
            lineLength += width
        }
        lengths.append(lineLength)
        return (starts, lengths)
    }

    public var lineCount: Int { lineLengths.count }

    public var characterCount: Int { text.count }

    /// 行 (1 始まり) の中身。
    public func line(_ number: Int) -> String {
        guard number >= 1, number <= lineCount else { return "" }
        let start = lineStarts[number - 1]
        let length = lineLengths[number - 1]
        return substring(location: start, length: length)
    }

    /// UTF-16 の位置から行と桁を求める。
    public func position(at location: Int) -> TextPosition {
        let clamped = Swift.max(0, location)
        var low = 0
        var high = lineStarts.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= clamped {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return TextPosition(line: found + 1, column: clamped - lineStarts[found] + 1)
    }

    /// 行と桁から UTF-16 の位置を求める。
    public func location(of position: TextPosition) -> Int {
        let line = Swift.min(Swift.max(1, position.line), Swift.max(1, lineCount))
        guard line - 1 < lineStarts.count else { return text.utf16.count }
        let start = lineStarts[line - 1]
        let length = line - 1 < lineLengths.count ? lineLengths[line - 1] : 0
        let column = Swift.min(Swift.max(1, position.column), length + 1)
        return start + column - 1
    }

    /// 行全体の範囲 (改行は含まない)。
    public func lineRange(_ number: Int) -> (location: Int, length: Int) {
        guard number >= 1, number <= lineCount else { return (0, 0) }
        return (lineStarts[number - 1], lineLengths[number - 1])
    }

    /// 範囲がまたぐ行の番号。
    public func lineNumbers(in location: Int, length: Int) -> ClosedRange<Int> {
        let first = position(at: location).line
        let last = position(at: location + Swift.max(0, length)).line
        return first...Swift.max(first, last)
    }

    /// 選択範囲の集計。
    public func summary(location: Int, length: Int) -> SelectionSummary {
        let selected = substring(location: location, length: length)
        let lines = selected.isEmpty ? 0
            : selected.components(separatedBy: .newlines).count
        let words = selected.split(whereSeparator: { $0.isWhitespace }).count
        return SelectionSummary(characters: selected.count, lines: lines, words: words)
    }

    /// UTF-16 の範囲を文字列で取り出す。
    public func substring(location: Int, length: Int) -> String {
        let utf16 = Array(text.utf16)
        let start = Swift.min(Swift.max(0, location), utf16.count)
        let end = Swift.min(start + Swift.max(0, length), utf16.count)
        guard start < end else { return "" }
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    /// 改行コードをそろえる。
    public func convertingLineEndings(to ending: LineEnding) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        guard ending != .lf else { return result }
        return result.replacingOccurrences(of: "\n", with: ending.text)
    }

    /// 行末の空白を落とす。
    public func trimmingTrailingWhitespace() -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var trimmed = line
            while let last = trimmed.last, last == " " || last == "\t" {
                trimmed.removeLast()
            }
            return trimmed
        }
        return lines.joined(separator: "\n")
    }
}

/// 文字コードまわりの情報。
public enum TextEncodingInfo {
    /// よく使う文字コード。
    public static let candidates: [(name: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16", .utf16),
        ("Shift_JIS", .shiftJIS),
        ("EUC-JP", .japaneseEUC),
        ("ISO-2022-JP", .iso2022JP),
        ("Latin-1", .isoLatin1),
        ("ASCII", .ascii)
    ]

    /// データから文字コードを推測して読む。
    public static func decode(_ data: Data) -> (text: String, name: String)? {
        for (name, encoding) in candidates {
            if let text = String(data: data, encoding: encoding) {
                // UTF-8 として読めるならそれを優先する。
                return (text, name)
            }
        }
        return nil
    }

    /// 本文が ASCII の範囲に収まっているか。
    public static func isPlainASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// バイト数を読みやすく整える。
    public static func humanReadableSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}
