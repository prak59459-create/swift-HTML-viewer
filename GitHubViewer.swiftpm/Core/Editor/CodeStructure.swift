import Foundation

/// 折りたためる範囲。
public struct FoldableRange: Equatable, Sendable {
    /// 折りたたみを始める行 (1 始まり)。この行自体は残る。
    public var startLine: Int
    /// 折りたたみの終わりの行。
    public var endLine: Int
    /// 入れ子の深さ。
    public var depth: Int

    public init(startLine: Int, endLine: Int, depth: Int) {
        self.startLine = startLine
        self.endLine = endLine
        self.depth = depth
    }

    public var lineCount: Int { endLine - startLine }
}

/// ソースの中の目印 (関数・クラスなど)。
public struct CodeSymbol: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case function
        case method
        case type
        case property
        case variable
        case constant
        case enumCase
        case module
        case heading
        case other

        /// SF Symbols の名前 (表示側で使う)。
        public var systemImageName: String {
            switch self {
            case .function, .method: return "function"
            case .type: return "cube"
            case .property, .variable: return "shippingbox"
            case .constant: return "lock"
            case .enumCase: return "circle.grid.2x2"
            case .module: return "folder"
            case .heading: return "number"
            case .other: return "questionmark"
            }
        }
    }

    public var id: String { "\(line):\(name)" }
    public var name: String
    public var kind: Kind
    public var line: Int
    /// 入れ子の深さ (0 が一番外側)。
    public var depth: Int
    /// 宣言の行そのもの (表示に使う)。
    public var detail: String

    public init(name: String, kind: Kind, line: Int, depth: Int, detail: String = "") {
        self.name = name
        self.kind = kind
        self.line = line
        self.depth = depth
        self.detail = detail
    }
}

/// ソースコードの構造を字下げと予約語から読み取る。
///
/// 本物の構文解析ではなく、行の見た目から目印を拾う軽い方法。
/// どの言語でもそこそこ動き、巨大なファイルでも速い。
public enum CodeStructure {

    /// 折りたためる範囲を求める。
    ///
    /// 中括弧を使う言語は括弧の対応で、字下げの言語は字下げの深さで決める。
    public static func foldableRanges(in text: String, languageID: String?)
        -> [FoldableRange] {
        let profile = SyntaxHighlighter.profile(for: languageID)
        let lines = text.components(separatedBy: "\n")
        let usesBraces = profile.operators.contains("{")
            && !["python", "haskell", "nim", "yaml"].contains(languageID ?? "")
        return usesBraces ? braceRanges(lines) : indentRanges(lines)
    }

    /// 中括弧の対応で折りたたみ範囲を求める。
    static func braceRanges(_ lines: [String]) -> [FoldableRange] {
        var stack: [(line: Int, depth: Int)] = []
        var ranges: [FoldableRange] = []
        var depth = 0
        for (index, line) in lines.enumerated() {
            let stripped = strippingLiterals(line)
            var opened = false
            for character in stripped {
                if character == "{" {
                    stack.append((index + 1, depth))
                    depth += 1
                    opened = true
                }
                if character == "}" {
                    depth = Swift.max(0, depth - 1)
                    guard let start = stack.popLast() else { continue }
                    if index + 1 > start.line {
                        ranges.append(FoldableRange(startLine: start.line,
                                                    endLine: index + 1,
                                                    depth: start.depth))
                    }
                }
            }
            _ = opened
        }
        return ranges.sorted { $0.startLine < $1.startLine }
    }

    /// 字下げで折りたたみ範囲を求める。
    static func indentRanges(_ lines: [String]) -> [FoldableRange] {
        func indent(_ line: String) -> Int? {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }
        var ranges: [FoldableRange] = []
        for (index, line) in lines.enumerated() {
            guard let base = indent(line) else { continue }
            var last = index
            var cursor = index + 1
            while cursor < lines.count {
                guard let width = indent(lines[cursor]) else {
                    cursor += 1
                    continue
                }
                if width <= base { break }
                last = cursor
                cursor += 1
            }
            if last > index {
                ranges.append(FoldableRange(startLine: index + 1, endLine: last + 1,
                                            depth: base))
            }
        }
        return ranges
    }

    /// 文字列とコメントを空白に置き換える (括弧の数え間違いを防ぐ)。
    static func strippingLiterals(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    continue
                }
                if character == open { quote = nil }
                result.append(" ")
                index = line.index(after: index)
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                result.append(" ")
                index = line.index(after: index)
                continue
            }
            // 行コメント。
            if character == "/", line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "/" {
                break
            }
            if character == "#" { break }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

    /// ソースの中の目印を拾う。
    public static func symbols(in text: String, languageID: String?) -> [CodeSymbol] {
        if languageID == "markdown" { return markdownSymbols(in: text) }
        let profile = SyntaxHighlighter.profile(for: languageID)
        var symbols: [CodeSymbol] = []
        let lines = text.components(separatedBy: "\n")

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let depth = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let first = words.first else { continue }

            // 型の宣言。
            if let kind = typeKeyword(first, profile: profile) ?? typeKeyword(words.count > 1 ? words[1] : "", profile: profile) {
                if let name = declaredName(after: line, keywords: profile.typeKeywords.keys.map { $0 }) {
                    symbols.append(CodeSymbol(name: name, kind: kind, line: index + 1,
                                              depth: depth, detail: line))
                    continue
                }
            }
            // 関数の宣言。
            if profile.functionKeywords.contains(first)
                || (words.count > 1 && profile.functionKeywords.contains(words[1]))
                || (words.count > 2 && profile.functionKeywords.contains(words[2])) {
                if let name = declaredName(after: line,
                                           keywords: Array(profile.functionKeywords)) {
                    symbols.append(CodeSymbol(name: name,
                                              kind: depth > 0 ? .method : .function,
                                              line: index + 1, depth: depth, detail: line))
                    continue
                }
            }
            // 型を先に書く言語の関数 (`int main(void) {`)。
            if profile.functionSyntax != .keyword, line.contains("("), line.contains(")"),
               line.hasSuffix("{") || line.hasSuffix(")") {
                if let name = typeFirstFunctionName(line) {
                    symbols.append(CodeSymbol(name: name,
                                              kind: depth > 0 ? .method : .function,
                                              line: index + 1, depth: depth, detail: line))
                    continue
                }
            }
            // 変数の宣言 (外側だけ拾う)。
            if depth == 0, let isConstant = profile.variableKeywords[first] {
                if let name = declaredName(after: line,
                                           keywords: Array(profile.variableKeywords.keys)) {
                    symbols.append(CodeSymbol(name: name,
                                              kind: isConstant ? .constant : .variable,
                                              line: index + 1, depth: depth, detail: line))
                }
            }
        }
        return symbols
    }

    private static func typeKeyword(_ word: String, profile: MLLanguageProfile)
        -> CodeSymbol.Kind? {
        guard let kind = profile.typeKeywords[word] else { return nil }
        switch kind {
        case .moduleType: return .module
        case .enumType: return .type
        default: return .type
        }
    }

    /// キーワードの次に来る名前を取り出す。
    static func declaredName(after line: String, keywords: [String]) -> String? {
        let separators = CharacterSet(charactersIn: " \t(<:{=[,;*&")
        let words = line.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let keywordIndex = words.firstIndex(where: { keywords.contains($0) }) else {
            return nil
        }
        var cursor = keywordIndex + 1
        while cursor < words.count {
            let candidate = words[cursor]
            if isName(candidate) { return candidate }
            cursor += 1
        }
        return nil
    }

    /// `int main(void)` のような書き方から名前を取り出す。
    static func typeFirstFunctionName(_ line: String) -> String? {
        guard let parenthesis = line.firstIndex(of: "(") else { return nil }
        let head = String(line[line.startIndex..<parenthesis])
        let words = head.components(separatedBy: CharacterSet(charactersIn: " \t*&:"))
            .filter { !$0.isEmpty }
        guard let name = words.last, isName(name), words.count >= 2 else { return nil }
        // 制御構文は除く。
        guard !["if", "for", "while", "switch", "catch", "return", "else"].contains(name)
        else { return nil }
        return name
    }

    static func isName(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Markdown の見出しを目印にする。
    static func markdownSymbols(in text: String) -> [CodeSymbol] {
        var symbols: [CodeSymbol] = []
        var insideFence = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, line.hasPrefix("#") else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            guard level <= 6 else { continue }
            let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            symbols.append(CodeSymbol(name: title, kind: .heading, line: index + 1,
                                      depth: level - 1, detail: line))
        }
        return symbols
    }

    /// 見出しから Markdown の目次を作る。
    public static func tableOfContents(forMarkdown text: String) -> String {
        let symbols = markdownSymbols(in: text)
        guard !symbols.isEmpty else { return "" }
        return symbols.map { symbol in
            let indent = String(repeating: "  ", count: symbol.depth)
            return "\(indent)- [\(symbol.name)](#\(anchor(for: symbol.name)))"
        }.joined(separator: "\n")
    }

    /// 見出しから GitHub 風のアンカー名を作る。
    public static func anchor(for heading: String) -> String {
        var result = ""
        for character in heading.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == " " || character == "-" || character == "_" {
                result.append("-")
            }
        }
        return result
    }
}

/// ミニマップに描くための、行ごとの濃さ。
public enum Minimap {
    /// 行ごとの「どれくらい文字が詰まっているか」(0〜1)。
    public static func density(of text: String, maximumLines: Int = 2000) -> [Double] {
        let lines = text.components(separatedBy: "\n").prefix(maximumLines)
        let widest = Swift.max(1, lines.map { $0.count }.max() ?? 1)
        return lines.map { line in
            let visible = line.trimmingCharacters(in: .whitespaces).count
            return Swift.min(1, Double(visible) / Double(widest))
        }
    }

    /// 行ごとの字下げの深さ (ミニマップの形を作るのに使う)。
    public static func indentDepths(of text: String, maximumLines: Int = 2000) -> [Int] {
        text.components(separatedBy: "\n").prefix(maximumLines).map { line in
            line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }
    }
}

/// 空白や改行を目に見える形にする。
public enum InvisibleCharacters {
    public static let space: Character = "·"
    public static let tab: Character = "→"
    public static let lineBreak: Character = "¬"

    /// 表示用に空白を置き換えた文字列。
    public static func reveal(_ text: String, showsSpaces: Bool = true,
                              showsTabs: Bool = true,
                              showsLineBreaks: Bool = false) -> String {
        var result = ""
        for character in text {
            switch character {
            case " " where showsSpaces: result.append(space)
            case "\t" where showsTabs: result.append(tab)
            case "\n" where showsLineBreaks:
                result.append(lineBreak)
                result.append("\n")
            default: result.append(character)
            }
        }
        return result
    }

    /// 空白・タブの位置 (UTF-16)。表示側で薄い点を重ねるのに使う。
    public static func positions(in text: String) -> (spaces: [Int], tabs: [Int]) {
        var spaces: [Int] = []
        var tabs: [Int] = []
        var offset = 0
        for character in text {
            if character == " " { spaces.append(offset) }
            if character == "\t" { tabs.append(offset) }
            offset += character.utf16.count
        }
        return (spaces, tabs)
    }
}

/// キーボードの上に出す記号バー。iPad で打ちにくい記号を並べる。
public enum SymbolBar {
    /// 言語に合わせた記号の並び。
    public static func keys(for languageID: String?) -> [String] {
        let common = ["(", ")", "{", "}", "[", "]", "<", ">", "\"", "'", ":", ";", ",",
                      ".", "=", "+", "-", "*", "/", "_", "|", "&", "!", "?", "#", "@",
                      "$", "%", "^", "~", "\\", "`"]
        guard let languageID else { return common }
        switch languageID {
        case "c", "cpp", "objectivec", "csharp", "java", "javascript", "typescript",
             "swift", "go", "rust", "kotlin", "scala", "dart", "groovy", "d", "zig",
             "php", "perl":
            return ["{", "}", "(", ")", "[", "]", ";", "\"", "'", "=", "=>", "->", "<",
                    ">", "&&", "||", "!", "+", "-", "*", "/", "%", ":", ",", ".", "_",
                    "#", "@", "$", "\\", "|", "&"]
        case "python", "ruby", "nim", "crystal", "elixir", "julia", "r":
            return [":", "(", ")", "[", "]", "{", "}", "\"", "'", "=", "==", "!=", "<",
                    ">", "+", "-", "*", "/", "%", ",", ".", "_", "#", "|", "&", "@",
                    "->", "=>", "..", "...", "**"]
        case "haskell", "ocaml", "erlang", "lisp":
            return ["(", ")", "[", "]", "{", "}", "->", "=>", "::", "|", "<-", "$", ".",
                    ",", ";", "\"", "'", "=", "==", "/=", "<", ">", "+", "-", "*", "/",
                    "++", "@", "_", "\\"]
        case "shell", "bash":
            return ["$", "\"", "'", "|", "&", ";", "(", ")", "{", "}", "[", "]", "<",
                    ">", ">>", "=", "-", "/", "*", "~", "`", "!", "#", "\\", "&&", "||"]
        case "html", "xml":
            return ["<", ">", "/", "=", "\"", "'", "-", "_", ":", ";", "{", "}", "(",
                    ")", "&", "#", "!", "?", ".", ","]
        case "sql":
            return ["*", ",", ";", "(", ")", "'", "\"", "=", "<", ">", "<>", ".", "_",
                    "%", "-", "+", "/"]
        default:
            return common
        }
    }

    /// よく使う組 (押すと 2 文字入って、間にカーソルが入る)。
    public static let pairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "<": ">"
    ]
}
