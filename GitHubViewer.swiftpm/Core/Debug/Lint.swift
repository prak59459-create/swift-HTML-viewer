import Foundation

// MARK: - 147. 簡易 Lint

/// Lint の 1 件。
public struct LintFinding: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var ruleID: String
    public var line: Int
    /// 行の中の位置 (UTF-16)。分からなければ 0。
    public var column: Int
    public var message: String
    public var level: SourceHint.Level

    public init(id: UUID = UUID(), ruleID: String, line: Int, column: Int = 0,
                message: String, level: SourceHint.Level = .style) {
        self.id = id
        self.ruleID = ruleID
        self.line = line
        self.column = column
        self.message = message
        self.level = level
    }
}

/// Lint の設定。
public struct LintOptions: Equatable, Sendable {
    /// 1 行の長さの上限。
    public var maximumLineLength: Int
    /// 使わない規則。
    public var disabledRules: Set<String>
    /// 関数の行数の上限。
    public var maximumFunctionLines: Int
    /// 入れ子の深さの上限。
    public var maximumNestingDepth: Int

    public init(maximumLineLength: Int = 100, disabledRules: Set<String> = [],
                maximumFunctionLines: Int = 60, maximumNestingDepth: Int = 5) {
        self.maximumLineLength = maximumLineLength
        self.disabledRules = disabledRules
        self.maximumFunctionLines = maximumFunctionLines
        self.maximumNestingDepth = maximumNestingDepth
    }

    public static let `default` = LintOptions()
}

/// 行の見た目を中心にした、軽い検査。
///
/// 文法まで踏み込まないぶん、どの言語にも同じようにかけられる。
/// 中身の判断が要るものは `CommonMistakes` に任せる。
public enum Lint {

    public static func check(_ source: String, languageID: String?,
                             options: LintOptions = .default) -> [LintFinding] {
        var findings: [LintFinding] = []
        let rawLines = source.components(separatedBy: "\n")
        let stripped = SyntaxHighlighter
            .strippingCommentsAndStrings(source, languageID: languageID)
            .components(separatedBy: "\n")

        func allowed(_ rule: String) -> Bool { !options.disabledRules.contains(rule) }

        // 行ごとの検査。
        for (index, line) in rawLines.enumerated() {
            let number = index + 1

            if allowed("line-length"), line.count > options.maximumLineLength {
                findings.append(LintFinding(
                    ruleID: "line-length", line: number,
                    message: "1 行が長すぎます (\(line.count) 文字 / "
                        + "上限 \(options.maximumLineLength))。"))
            }

            if allowed("trailing-whitespace"),
               line.hasSuffix(" ") || line.hasSuffix("\t") {
                findings.append(LintFinding(
                    ruleID: "trailing-whitespace", line: number,
                    message: "行末に空白があります。"))
            }

            if allowed("mixed-indent") {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                if indent.contains(" "), indent.contains("\t") {
                    findings.append(LintFinding(
                        ruleID: "mixed-indent", line: number,
                        message: "字下げに空白とタブが混ざっています。",
                        level: .caution))
                }
            }

            if allowed("todo"), line.contains("TODO") || line.contains("FIXME") {
                findings.append(LintFinding(
                    ruleID: "todo", line: number, message: "やり残しの印があります。"))
            }
        }

        if allowed("trailing-newline"), !source.isEmpty, !source.hasSuffix("\n") {
            findings.append(LintFinding(
                ruleID: "trailing-newline", line: rawLines.count,
                message: "ファイルの終わりに改行がありません。"))
        }

        if allowed("blank-lines") {
            var run = 0
            for (index, line) in rawLines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    run += 1
                    if run == 3 {
                        findings.append(LintFinding(
                            ruleID: "blank-lines", line: index + 1,
                            message: "空行が 3 行以上続いています。"))
                    }
                } else {
                    run = 0
                }
            }
        }

        if allowed("nesting") {
            findings += nestingFindings(stripped, limit: options.maximumNestingDepth)
        }

        if allowed("function-length") {
            findings += functionLengthFindings(source, languageID: languageID,
                                               limit: options.maximumFunctionLines)
        }

        if allowed("unused-variable") {
            findings += unusedVariableFindings(source, languageID: languageID)
        }

        return findings.sorted { ($0.line, $0.ruleID) < ($1.line, $1.ruleID) }
    }

    /// 入れ子が深すぎるところ。
    static func nestingFindings(_ lines: [String], limit: Int) -> [LintFinding] {
        var findings: [LintFinding] = []
        var depth = 0
        var reported = false
        for (index, line) in lines.enumerated() {
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            depth += opens
            if depth > limit, !reported, opens > 0 {
                findings.append(LintFinding(
                    ruleID: "nesting", line: index + 1,
                    message: "入れ子が深すぎます (\(depth) 段 / 上限 \(limit))。"
                        + "関数に切り出すと読みやすくなります。",
                    level: .caution))
                reported = true
            }
            depth = Swift.max(0, depth - closes)
            if depth <= limit { reported = false }
        }
        return findings
    }

    /// 長すぎる関数。
    static func functionLengthFindings(_ source: String, languageID: String?,
                                       limit: Int) -> [LintFinding] {
        let symbols = CodeStructure.symbols(in: source, languageID: languageID ?? "")
        let ranges = CodeStructure.foldableRanges(in: source,
                                                  languageID: languageID ?? "")
        var findings: [LintFinding] = []
        for symbol in symbols where symbol.kind == .function || symbol.kind == .method {
            guard let range = ranges.first(where: { $0.startLine == symbol.line })
            else { continue }
            let length = range.endLine - range.startLine + 1
            guard length > limit else { continue }
            findings.append(LintFinding(
                ruleID: "function-length", line: symbol.line,
                message: "\(symbol.name) が長すぎます (\(length) 行 / 上限 \(limit))。",
                level: .caution))
        }
        return findings
    }

    /// 宣言したのに一度も使っていない変数。
    ///
    /// 宣言の書き方がはっきりしている言語だけを見る。
    static func unusedVariableFindings(_ source: String,
                                       languageID: String?) -> [LintFinding] {
        let keywords = declarationKeywords(for: languageID)
        guard !keywords.isEmpty else { return [] }

        let text = SyntaxHighlighter.strippingCommentsAndStrings(source,
                                                                 languageID: languageID)
        let lines = text.components(separatedBy: "\n")
        var declarations: [(name: String, line: Int)] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for keyword in keywords {
                guard trimmed.hasPrefix(keyword + " ") else { continue }
                let rest = trimmed.dropFirst(keyword.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty, name.first?.isNumber != true else { continue }
                declarations.append((name, index + 1))
                break
            }
        }

        var findings: [LintFinding] = []
        for declaration in declarations {
            var uses = 0
            for (index, line) in lines.enumerated() {
                uses += occurrences(of: declaration.name, in: line)
                // 宣言した行の 1 回は数えない。
                if index + 1 == declaration.line { uses -= 1 }
            }
            guard uses <= 0 else { continue }
            findings.append(LintFinding(
                ruleID: "unused-variable", line: declaration.line,
                message: "\(declaration.name) は宣言されていますが、使われていません。",
                level: .caution))
        }
        return findings
    }

    /// 単語として現れる回数。
    static func occurrences(of name: String, in line: String) -> Int {
        let characters = Array(line)
        let target = Array(name)
        guard !target.isEmpty, characters.count >= target.count else { return 0 }
        var count = 0
        var index = 0
        while index + target.count <= characters.count {
            if Array(characters[index..<(index + target.count)]) == target {
                let before = index > 0 ? characters[index - 1] : " "
                let afterIndex = index + target.count
                let after = afterIndex < characters.count ? characters[afterIndex] : " "
                let isWord = { (character: Character) in
                    character.isLetter || character.isNumber || character == "_"
                }
                if !isWord(before), !isWord(after) { count += 1 }
                index += target.count
                continue
            }
            index += 1
        }
        return count
    }

    /// 変数宣言の目印になるキーワード。
    static func declarationKeywords(for languageID: String?) -> [String] {
        switch languageID {
        case "javascript", "typescript": return ["let", "const", "var"]
        case "swift", "kotlin", "scala": return ["let", "var", "val"]
        case "go": return ["var"]
        case "rust": return ["let"]
        case "nim": return ["var", "let", "const"]
        case "dart", "groovy": return ["var", "final"]
        default: return []
        }
    }
}
