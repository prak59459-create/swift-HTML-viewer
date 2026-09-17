import Foundation

/// 編集操作の結果 (置き換える範囲と、置き換えたあとのカーソル位置)。
public struct EditResult: Equatable, Sendable {
    /// 置き換える範囲 (UTF-16)。
    public var location: Int
    public var length: Int
    /// 置き換えたあとの文字列。
    public var replacement: String
    /// 置き換えたあとに選ぶ範囲。
    public var selectionLocation: Int
    public var selectionLength: Int

    public init(location: Int, length: Int, replacement: String,
                selectionLocation: Int, selectionLength: Int) {
        self.location = location
        self.length = length
        self.replacement = replacement
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
    }

    /// 本文に適用する。
    public func applied(to text: String) -> String {
        let utf16 = Array(text.utf16)
        let start = Swift.min(Swift.max(0, location), utf16.count)
        let end = Swift.min(start + Swift.max(0, length), utf16.count)
        let head = String(decoding: utf16[0..<start], as: UTF16.self)
        let tail = String(decoding: utf16[end...], as: UTF16.self)
        return head + replacement + tail
    }
}

/// 検索の見つかった場所。
public struct SearchMatch: Equatable, Sendable {
    public var location: Int
    public var length: Int
    /// 正規表現の捕捉 (`$1` などの置換に使う)。
    public var groups: [String]

    public init(location: Int, length: Int, groups: [String] = []) {
        self.location = location
        self.length = length
        self.groups = groups
    }
}

/// 検索の設定。
public struct SearchOptions: Equatable, Sendable {
    public var isCaseSensitive: Bool
    public var isRegularExpression: Bool
    public var matchesWholeWord: Bool
    public var wrapsAround: Bool

    public init(isCaseSensitive: Bool = false, isRegularExpression: Bool = false,
                matchesWholeWord: Bool = false, wrapsAround: Bool = true) {
        self.isCaseSensitive = isCaseSensitive
        self.isRegularExpression = isRegularExpression
        self.matchesWholeWord = matchesWholeWord
        self.wrapsAround = wrapsAround
    }
}

/// 検索と置換。
public enum TextSearch {

    /// 本文の中から見つかる場所をすべて返す。
    public static func matches(of query: String, in text: String,
                               options: SearchOptions = SearchOptions()) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var pattern = options.isRegularExpression
            ? query : NSRegularExpression.escapedPattern(for: query)
        if options.matchesWholeWord { pattern = "\\b" + pattern + "\\b" }
        var regexOptions: NSRegularExpression.Options = []
        if !options.isCaseSensitive { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: regexOptions) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).map { result in
            var groups: [String] = []
            for index in 0..<result.numberOfRanges {
                let groupRange = result.range(at: index)
                guard groupRange.location != NSNotFound else {
                    groups.append("")
                    continue
                }
                groups.append((text as NSString).substring(with: groupRange))
            }
            return SearchMatch(location: result.range.location,
                               length: result.range.length, groups: groups)
        }
    }

    /// 今の位置より後ろで最初に見つかる場所。
    public static func next(of query: String, in text: String, after location: Int,
                            options: SearchOptions = SearchOptions()) -> SearchMatch? {
        let all = matches(of: query, in: text, options: options)
        if let found = all.first(where: { $0.location > location }) { return found }
        return options.wrapsAround ? all.first : nil
    }

    /// 今の位置より前で最後に見つかる場所。
    public static func previous(of query: String, in text: String, before location: Int,
                                options: SearchOptions = SearchOptions()) -> SearchMatch? {
        let all = matches(of: query, in: text, options: options)
        if let found = all.last(where: { $0.location < location }) { return found }
        return options.wrapsAround ? all.last : nil
    }

    /// 1 か所だけ置き換える。
    public static func replace(_ match: SearchMatch, with replacement: String,
                               in text: String,
                               options: SearchOptions = SearchOptions()) -> String {
        let expanded = options.isRegularExpression
            ? expand(replacement, groups: match.groups) : replacement
        let nsText = NSMutableString(string: text)
        nsText.replaceCharacters(in: NSRange(location: match.location, length: match.length),
                                 with: expanded)
        return nsText as String
    }

    /// すべて置き換える。置き換えた件数も返す。
    public static func replaceAll(of query: String, with replacement: String,
                                  in text: String,
                                  options: SearchOptions = SearchOptions())
        -> (text: String, count: Int) {
        let found = matches(of: query, in: text, options: options)
        guard !found.isEmpty else { return (text, 0) }
        let nsText = NSMutableString(string: text)
        // 後ろから置き換えると位置がずれない。
        for match in found.reversed() {
            let expanded = options.isRegularExpression
                ? expand(replacement, groups: match.groups) : replacement
            nsText.replaceCharacters(
                in: NSRange(location: match.location, length: match.length),
                with: expanded)
        }
        return (nsText as String, found.count)
    }

    /// `$1` を捕捉した文字列に置き換える。
    static func expand(_ template: String, groups: [String]) -> String {
        var result = ""
        var characters = Array(template)
        var index = 0
        while index < characters.count {
            if characters[index] == "$", index + 1 < characters.count,
               characters[index + 1].isNumber {
                var digits = ""
                var cursor = index + 1
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                let group = Int(digits) ?? 0
                result += group < groups.count ? groups[group] : ""
                index = cursor
                continue
            }
            if characters[index] == "\\", index + 1 < characters.count {
                switch characters[index + 1] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(characters[index + 1])
                }
                index += 2
                continue
            }
            result.append(characters[index])
            index += 1
        }
        characters = []
        return result
    }
}

/// 括弧の組を扱う。
public enum BracketMatcher {
    public static let pairs: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}")
    ]

    /// 自動で閉じる記号。
    public static let autoClosing: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"
    ]

    /// 指定の位置にある括弧に対応する括弧の位置を探す。
    ///
    /// カーソルの直前と直後の両方を見て、括弧があればその相手を返す。
    public static func match(in text: String, at location: Int) -> (Int, Int)? {
        let characters = Array(text.utf16)
        func character(at index: Int) -> Character? {
            guard index >= 0, index < characters.count else { return nil }
            guard let scalar = Unicode.Scalar(characters[index]) else { return nil }
            return Character(scalar)
        }
        for offset in [0, -1] {
            let index = location + offset
            guard let current = character(at: index) else { continue }
            if let close = pairs.first(where: { $0.open == current })?.close {
                if let partner = forward(in: characters, from: index, open: current,
                                         close: close) {
                    return (index, partner)
                }
            }
            if let open = pairs.first(where: { $0.close == current })?.open {
                if let partner = backward(in: characters, from: index, open: open,
                                          close: current) {
                    return (partner, index)
                }
            }
        }
        return nil
    }

    private static func forward(in characters: [UInt16], from index: Int,
                                open: Character, close: Character) -> Int? {
        let openCode = open.utf16.first ?? 0
        let closeCode = close.utf16.first ?? 0
        var depth = 0
        var cursor = index
        while cursor < characters.count {
            if characters[cursor] == openCode { depth += 1 }
            if characters[cursor] == closeCode {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    private static func backward(in characters: [UInt16], from index: Int,
                                 open: Character, close: Character) -> Int? {
        let openCode = open.utf16.first ?? 0
        let closeCode = close.utf16.first ?? 0
        var depth = 0
        var cursor = index
        while cursor >= 0 {
            if characters[cursor] == closeCode { depth += 1 }
            if characters[cursor] == openCode {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor -= 1
        }
        return nil
    }

    /// 開き記号を打ったときに閉じ記号を足すか。
    public static func shouldAutoClose(_ character: Character, before next: Character?)
        -> Bool {
        guard autoClosing[character] != nil else { return false }
        guard let next else { return true }
        // 文字や数字の直前では閉じない (単語の途中に挟まらないように)。
        return !(next.isLetter || next.isNumber)
    }
}

/// 字下げの決まり。
public struct IndentStyle: Equatable, Sendable {
    public var usesSpaces: Bool
    public var width: Int

    public init(usesSpaces: Bool = true, width: Int = 4) {
        self.usesSpaces = usesSpaces
        self.width = width
    }

    public var unit: String {
        usesSpaces ? String(repeating: " ", count: width) : "\t"
    }

    /// 本文から字下げの流儀を推測する。
    public static func detect(in text: String, default fallback: IndentStyle = IndentStyle())
        -> IndentStyle {
        var tabCount = 0
        var spaceWidths: [Int: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let first = line.first else { continue }
            if first == "\t" {
                tabCount += 1
                continue
            }
            guard first == " " else { continue }
            let width = line.prefix(while: { $0 == " " }).count
            guard width > 0 else { continue }
            spaceWidths[width, default: 0] += 1
        }
        let spaceCount = spaceWidths.values.reduce(0, +)
        if tabCount > spaceCount { return IndentStyle(usesSpaces: false, width: fallback.width) }
        guard spaceCount > 0 else { return fallback }
        // よく出てくる幅の最大公約数を字下げ幅とみなす。
        let widths = spaceWidths.filter { $0.value >= 2 }.map { $0.key }
        guard let smallest = widths.min() else { return fallback }
        let candidates = [2, 4, 8].filter { smallest % $0 == 0 }
        return IndentStyle(usesSpaces: true, width: candidates.max() ?? smallest)
    }
}

/// 字下げ・コメント切り替えなどの編集。
public enum TextEditing {

    /// 選んでいる行をまとめて字下げする。
    public static func indent(_ document: TextDocument, location: Int, length: Int,
                              style: IndentStyle) -> EditResult {
        let lines = document.lineNumbers(in: location, length: length)
        let first = document.lineRange(lines.lowerBound)
        let last = document.lineRange(lines.upperBound)
        let start = first.location
        let end = last.location + last.length
        let block = document.substring(location: start, length: end - start)
        let replaced = block.components(separatedBy: "\n")
            .map { style.unit + $0 }.joined(separator: "\n")
        return EditResult(location: start, length: end - start, replacement: replaced,
                          selectionLocation: start,
                          selectionLength: (replaced as NSString).length)
    }

    /// 選んでいる行の字下げをまとめて減らす。
    public static func outdent(_ document: TextDocument, location: Int, length: Int,
                               style: IndentStyle) -> EditResult {
        let lines = document.lineNumbers(in: location, length: length)
        let first = document.lineRange(lines.lowerBound)
        let last = document.lineRange(lines.upperBound)
        let start = first.location
        let end = last.location + last.length
        let block = document.substring(location: start, length: end - start)
        let replaced = block.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var trimmed = line
            var removed = 0
            while removed < style.width, trimmed.first == " " {
                trimmed.removeFirst()
                removed += 1
            }
            return trimmed
        }.joined(separator: "\n")
        return EditResult(location: start, length: end - start, replacement: replaced,
                          selectionLocation: start,
                          selectionLength: (replaced as NSString).length)
    }

    /// 選んでいる行のコメントを切り替える。
    public static func toggleComment(_ document: TextDocument, location: Int, length: Int,
                                     languageID: String?) -> EditResult {
        let profile = SyntaxHighlighter.profile(for: languageID)
        let marker = lineCommentMarker(for: profile) ?? "//"
        let lines = document.lineNumbers(in: location, length: length)
        let first = document.lineRange(lines.lowerBound)
        let last = document.lineRange(lines.upperBound)
        let start = first.location
        let end = last.location + last.length
        let block = document.substring(location: start, length: end - start)
        let rows = block.components(separatedBy: "\n")

        // 空でない行がすべてコメントなら外す。
        let meaningful = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }

        let replaced = rows.map { row -> String in
            if row.trimmingCharacters(in: .whitespaces).isEmpty { return row }
            if allCommented {
                guard let range = row.range(of: marker) else { return row }
                var result = row
                result.removeSubrange(range)
                if result.hasPrefix(" ") , row[range.upperBound...].hasPrefix(" ") {
                    result.removeFirst()
                }
                return result
            }
            let indent = row.prefix(while: { $0 == " " || $0 == "\t" })
            return indent + marker + " " + row.dropFirst(indent.count)
        }.joined(separator: "\n")

        return EditResult(location: start, length: end - start, replacement: replaced,
                          selectionLocation: start,
                          selectionLength: (replaced as NSString).length)
    }

    /// 言語の行コメント記号。
    public static func lineCommentMarker(for profile: MLLanguageProfile) -> String? {
        for style in profile.comments {
            if case .line(let marker) = style { return marker }
            if case .lineFromColumn(let marker, _) = style { return marker }
        }
        return nil
    }

    /// 改行したときに足す字下げ。
    public static func newlineIndent(_ document: TextDocument, at location: Int,
                                     style: IndentStyle,
                                     languageID: String?) -> String {
        let position = document.position(at: location)
        let line = document.line(position.line)
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        // 直前が開き括弧なら 1 段深くする。
        let before = line.prefix(Swift.max(0, position.column - 1))
            .trimmingCharacters(in: .whitespaces)
        if let last = before.last, "([{:".contains(last) {
            return indent + style.unit
        }
        // `end` で閉じる言語の `do` / `then`。
        let profile = SyntaxHighlighter.profile(for: languageID)
        if profile.keywords.contains("end") {
            let words = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let last = words.last, ["do", "then", "else", "begin"].contains(last) {
                return indent + style.unit
            }
        }
        return indent
    }

    /// 行を上下に動かす。
    public static func moveLines(_ document: TextDocument, location: Int, length: Int,
                                 up: Bool) -> EditResult? {
        let lines = document.lineNumbers(in: location, length: length)
        let target = up ? lines.lowerBound - 1 : lines.upperBound + 1
        guard target >= 1, target <= document.lineCount else { return nil }

        let blockFirst = document.lineRange(lines.lowerBound)
        let blockLast = document.lineRange(lines.upperBound)
        let blockStart = blockFirst.location
        let blockEnd = blockLast.location + blockLast.length
        let block = document.substring(location: blockStart, length: blockEnd - blockStart)
        let neighbour = document.lineRange(target)
        let neighbourText = document.substring(location: neighbour.location,
                                               length: neighbour.length)

        if up {
            let start = neighbour.location
            let replacement = block + "\n" + neighbourText
            return EditResult(location: start, length: blockEnd - start,
                              replacement: replacement, selectionLocation: start,
                              selectionLength: (block as NSString).length)
        }
        let end = neighbour.location + neighbour.length
        let replacement = neighbourText + "\n" + block
        let newBlockStart = blockStart + (neighbourText as NSString).length + 1
        return EditResult(location: blockStart, length: end - blockStart,
                          replacement: replacement, selectionLocation: newBlockStart,
                          selectionLength: (block as NSString).length)
    }

    /// 行を複製する。
    public static func duplicateLines(_ document: TextDocument, location: Int,
                                      length: Int) -> EditResult {
        let lines = document.lineNumbers(in: location, length: length)
        let first = document.lineRange(lines.lowerBound)
        let last = document.lineRange(lines.upperBound)
        let start = first.location
        let end = last.location + last.length
        let block = document.substring(location: start, length: end - start)
        let replacement = block + "\n" + block
        return EditResult(location: start, length: end - start, replacement: replacement,
                          selectionLocation: end + 1,
                          selectionLength: (block as NSString).length)
    }

    /// 行を消す。
    public static func deleteLines(_ document: TextDocument, location: Int,
                                   length: Int) -> EditResult {
        let lines = document.lineNumbers(in: location, length: length)
        let first = document.lineRange(lines.lowerBound)
        let last = document.lineRange(lines.upperBound)
        let start = first.location
        var end = last.location + last.length
        // 行末の改行も一緒に消す。
        if lines.upperBound < document.lineCount { end += 1 }
        return EditResult(location: start, length: end - start, replacement: "",
                          selectionLocation: start, selectionLength: 0)
    }
}

/// 元に戻す / やり直しの履歴。
public final class UndoHistory {
    /// 1 つぶんの状態。
    public struct Snapshot: Equatable {
        public var text: String
        public var selectionLocation: Int
        public var selectionLength: Int

        public init(text: String, selectionLocation: Int, selectionLength: Int) {
            self.text = text
            self.selectionLocation = selectionLocation
            self.selectionLength = selectionLength
        }
    }

    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canUndo: Bool { past.count > 1 }
    public var canRedo: Bool { !future.isEmpty }
    public var current: Snapshot? { past.last }

    /// 状態を記録する。同じ内容なら記録しない。
    public func record(_ snapshot: Snapshot) {
        if let last = past.last, last.text == snapshot.text {
            past[past.count - 1] = snapshot
            return
        }
        past.append(snapshot)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    public func undo() -> Snapshot? {
        guard past.count > 1 else { return nil }
        let removed = past.removeLast()
        future.append(removed)
        return past.last
    }

    public func redo() -> Snapshot? {
        guard let snapshot = future.popLast() else { return nil }
        past.append(snapshot)
        return snapshot
    }

    public func reset(to snapshot: Snapshot) {
        past = [snapshot]
        future.removeAll()
    }
}
