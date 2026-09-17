import Foundation

// MARK: - 148. コードフォーマッタ

/// 整形の設定。
public struct FormatOptions: Equatable, Sendable {
    public var indent: IndentStyle
    /// 行末の空白を消すか。
    public var trimsTrailingWhitespace: Bool
    /// 終わりに改行を入れるか。
    public var insertsFinalNewline: Bool
    /// 3 行以上続く空行を 1 行にまとめるか。
    public var collapsesBlankLines: Bool
    /// `,` のうしろに空白を入れるか。
    public var spacesAfterCommas: Bool
    /// 二項演算子の左右に空白を入れるか。
    public var spacesAroundOperators: Bool

    public init(indent: IndentStyle = IndentStyle(usesSpaces: true, width: 4),
                trimsTrailingWhitespace: Bool = true,
                insertsFinalNewline: Bool = true,
                collapsesBlankLines: Bool = true,
                spacesAfterCommas: Bool = true,
                spacesAroundOperators: Bool = false) {
        self.indent = indent
        self.trimsTrailingWhitespace = trimsTrailingWhitespace
        self.insertsFinalNewline = insertsFinalNewline
        self.collapsesBlankLines = collapsesBlankLines
        self.spacesAfterCommas = spacesAfterCommas
        self.spacesAroundOperators = spacesAroundOperators
    }

    public static let `default` = FormatOptions()
}

/// ソースの見た目をそろえる。
///
/// 構文を組み替えることはせず、字下げと空白だけを整える。
/// そのぶん、どの言語にもかけられて、意味が変わる心配が小さい。
public enum CodeFormatter {

    public static func format(_ source: String, languageID: String?,
                              options: FormatOptions = .default) -> String {
        let usesBraces = !indentationLanguages.contains(languageID ?? "")
        var lines = source.components(separatedBy: "\n")

        if usesBraces {
            lines = reindent(lines, source: source, languageID: languageID,
                             options: options)
        }

        lines = lines.map { line in
            var updated = line
            if options.spacesAfterCommas {
                updated = spacingAfterCommas(updated, languageID: languageID)
            }
            if options.spacesAroundOperators {
                updated = spacingAroundOperators(updated, languageID: languageID)
            }
            if options.trimsTrailingWhitespace {
                while updated.hasSuffix(" ") || updated.hasSuffix("\t") {
                    updated.removeLast()
                }
            }
            return updated
        }

        if options.collapsesBlankLines { lines = collapseBlankLines(lines) }

        var text = lines.joined(separator: "\n")
        if options.insertsFinalNewline, !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }

    /// 字下げを行の深さに合わせて付け直す。
    static func reindent(_ lines: [String], source: String, languageID: String?,
                         options: FormatOptions) -> [String] {
        // 文字列やコメントの中の括弧は数えない。
        let stripped = SyntaxHighlighter
            .strippingCommentsAndStrings(source, languageID: languageID)
            .components(separatedBy: "\n")

        var result: [String] = []
        var depth = 0

        for (index, line) in lines.enumerated() {
            let body = line.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else {
                result.append("")
                continue
            }
            let code = index < stripped.count
                ? stripped[index].trimmingCharacters(in: .whitespaces) : body

            // 閉じ括弧で始まる行は、1 段浅くする。
            var lineDepth = depth
            if code.hasPrefix("}") || code.hasPrefix(")") || code.hasPrefix("]") {
                lineDepth = Swift.max(0, depth - 1)
            }
            // ラベルや case は 1 段浅く見せる言語が多い。
            if code.hasPrefix("case ") || code.hasPrefix("default:") {
                lineDepth = Swift.max(0, lineDepth - 1)
            }

            result.append(String(repeating: options.indent.unit, count: lineDepth) + body)

            let opens = code.filter { $0 == "{" || $0 == "(" || $0 == "[" }.count
            let closes = code.filter { $0 == "}" || $0 == ")" || $0 == "]" }.count
            depth = Swift.max(0, depth + opens - closes)
        }
        return result
    }

    /// `,` のうしろに空白を 1 つ入れる。
    static func spacingAfterCommas(_ line: String, languageID: String?) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        let characters = Array(line)

        for (index, character) in characters.enumerated() {
            result.append(character)
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != nil {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            guard character == "," else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if next != " ", next != "\n", next != ")" { result.append(" ") }
        }
        return result
    }

    /// `a+b` のような書き方に空白を入れる。
    ///
    /// 単項や記号の並び (`++` / `->` / `=>`) を壊さないよう、
    /// 前後に英数字がある 1 文字の演算子だけを対象にする。
    static func spacingAroundOperators(_ line: String, languageID: String?) -> String {
        let targets: Set<Character> = ["+", "-", "*", "/", "%", "<", ">", "="]
        let characters = Array(line)
        var result = ""
        var quote: Character?
        var escaped = false

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                result.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != nil {
                result.append(character)
                escaped = true
                index += 1
                continue
            }
            if let open = quote {
                result.append(character)
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                result.append(character)
                index += 1
                continue
            }
            guard targets.contains(character) else {
                result.append(character)
                index += 1
                continue
            }
            let previous = index > 0 ? characters[index - 1] : " "
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let isWord = { (value: Character) in
                value.isLetter || value.isNumber || value == "_" || value == ")"
                    || value == "]"
            }
            let nextIsWord = { (value: Character) in
                value.isLetter || value.isNumber || value == "_" || value == "("
                    || value == "["
            }
            // 記号が続くものはそのままにする (++ / -- / == / -> など)。
            guard isWord(previous), nextIsWord(next) else {
                result.append(character)
                index += 1
                continue
            }
            result.append(" ")
            result.append(character)
            result.append(" ")
            index += 1
        }
        return result
    }

    /// 3 行以上続く空行を 1 行にする。
    static func collapseBlankLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var run = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                run += 1
                if run <= 1 { result.append(line) }
                continue
            }
            run = 0
            result.append(line)
        }
        return result
    }

    /// 字下げで構造を決める言語 (括弧を数えても意味がない)。
    static let indentationLanguages: Set<String> = ["python", "nim", "haskell", "yaml",
                                                     "markdown", "elixir"]
}
