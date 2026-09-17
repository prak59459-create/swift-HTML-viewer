import Foundation

/// 色分けの種類。表示側はこれを見て色を決める。
public enum HighlightKind: String, Equatable, CaseIterable, Sendable {
    case plain
    case keyword
    case type
    case function
    case number
    case string
    case character
    case comment
    case documentationComment
    case operatorSymbol
    case punctuation
    case preprocessor
    case attribute
    case variable
    case constant
    case invalid
}

/// 色を付ける範囲 1 つぶん。
///
/// `location` と `length` は UTF-16 の単位。`UITextView` の `NSRange` に
/// そのまま渡せるようにしてある。
public struct HighlightSpan: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: HighlightKind

    public init(location: Int, length: Int, kind: HighlightKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }

    public var endLocation: Int { location + length }
}

/// ソースコードの色分け。
///
/// 各言語の `MLLanguageProfile` (コメントの書き方・文字列の書き方・予約語) を
/// そのまま使うので、内蔵処理系が対応している言語はすべて色が付く。
/// 対応していない言語も、C 風の既定値でそれなりに色が付く。
public enum SyntaxHighlighter {

    /// 言語 ID から色分け用の情報を引く。
    public static func profile(for languageID: String?) -> MLLanguageProfile {
        guard let languageID else { return fallbackProfile }
        switch languageID {
        case "java": return JavaProfile.profile
        case "csharp": return CSharpProfile.profile
        case "kotlin": return KotlinProfile.profile
        case "cpp": return CppProfile.profile
        case "go": return GoProfile.profile
        case "rust": return RustProfile.profile
        case "javascript", "typescript": return JSProfile.profile
        case "dart": return DartProfile.profile
        case "groovy": return GroovyProfile.profile
        case "d": return DProfile.profile
        case "objectivec": return ObjCProfile.profile
        case "zig": return ZigProfile.profile
        case "julia": return JuliaProfile.profile
        case "crystal": return CrystalProfile.profile
        case "nim": return NimProfile.profile
        case "pascal": return PascalProfile.profile
        case "perl": return PerlProfile.profile
        case "r": return RProfile.profile
        case "elixir": return ElixirProfile.profile
        case "erlang": return ErlangProfile.profile
        case "ocaml": return OCamlProfile.profile
        case "haskell": return HaskellProfile.profile
        case "shell", "bash": return ShellProfile.profile
        case "lisp": return lispProfile
        case "c": return cProfile
        case "php": return phpProfile
        case "swift": return swiftProfile
        case "scala": return scalaProfile
        case "python": return pythonProfile
        case "ruby": return rubyProfile
        case "lua": return luaProfile
        case "sql": return sqlProfile
        case "html", "xml": return htmlProfile
        case "css": return cssProfile
        case "json": return jsonProfile
        case "yaml": return yamlProfile
        case "markdown": return markdownProfile
        default: return fallbackProfile
        }
    }

    /// 色分けの範囲を求める。
    ///
    /// - Parameters:
    ///   - source: ソースコード全体。
    ///   - languageID: `LanguageCatalog` の言語 ID。
    ///   - limit: 何文字まで色を付けるか (巨大なファイルで固まらないように)。
    public static func spans(for source: String, languageID: String?,
                             limit: Int = 200_000) -> [HighlightSpan] {
        let profile = profile(for: languageID)
        return spans(for: source, profile: profile, limit: limit)
    }

    /// プロファイルを直接渡す版。
    public static func spans(for source: String, profile: MLLanguageProfile,
                             limit: Int = 200_000) -> [HighlightSpan] {
        var scanner = Scanner(source: source, profile: profile, limit: limit)
        return scanner.scan()
    }

    /// 文字列とコメントを空白に置き換えた本文。
    ///
    /// 行と桁の位置はそのままなので、行ごとの検査 (Lint など) に使える。
    /// 改行は残す。
    public static func strippingCommentsAndStrings(_ source: String,
                                                   languageID: String?) -> String {
        let spans = spans(for: source, languageID: languageID)
        guard !spans.isEmpty else { return source }

        var units = Array(source.utf16)
        let space = UInt16(32)
        let newline = UInt16(10)
        for span in spans {
            switch span.kind {
            case .string, .character, .comment, .documentationComment:
                let end = Swift.min(units.count, span.location + span.length)
                guard span.location < end else { continue }
                for index in span.location..<end where units[index] != newline {
                    units[index] = space
                }
            default:
                continue
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: 走査

    private struct Scanner {
        let characters: [Character]
        let profile: MLLanguageProfile
        let limit: Int
        var index = 0
        var utf16Offset = 0
        var spans: [HighlightSpan] = []

        init(source: String, profile: MLLanguageProfile, limit: Int) {
            self.characters = Array(source.prefix(limit))
            self.profile = profile
            self.limit = limit
        }

        var isAtEnd: Bool { index >= characters.count }

        func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        mutating func advance() {
            guard index < characters.count else { return }
            utf16Offset += characters[index].utf16.count
            index += 1
        }

        func matches(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let needle = Array(text)
            guard index + needle.count <= characters.count else { return false }
            for (offset, character) in needle.enumerated()
            where characters[index + offset] != character {
                return false
            }
            return true
        }

        mutating func skip(_ text: String) {
            for _ in 0..<text.count { advance() }
        }

        mutating func emit(from start: Int, kind: HighlightKind) {
            guard utf16Offset > start, kind != .plain else { return }
            spans.append(HighlightSpan(location: start, length: utf16Offset - start,
                                       kind: kind))
        }

        mutating func scan() -> [HighlightSpan] {
            while !isAtEnd {
                guard let character = peek() else { break }
                if character.isWhitespace {
                    advance()
                    continue
                }
                if scanComment() { continue }
                if scanString() { continue }
                if scanNumber() { continue }
                if scanIdentifier() { continue }
                if scanOperator() { continue }
                advance()
            }
            return spans
        }

        mutating func scanComment() -> Bool {
            for style in profile.comments {
                switch style {
                case .line(let marker):
                    guard matches(marker) else { continue }
                    let start = utf16Offset
                    // `///` や `//!` は説明コメントとして別扱いにする。
                    let isDocumentation = matches(marker + "/") || matches(marker + "!")
                    while !isAtEnd, peek() != "\n" { advance() }
                    emit(from: start, kind: isDocumentation ? .documentationComment : .comment)
                    return true
                case .block(let open, let close, let nesting):
                    guard matches(open) else { continue }
                    let start = utf16Offset
                    let isDocumentation = matches(open + "*") || matches(open + "!")
                    skip(open)
                    var depth = 1
                    while !isAtEnd, depth > 0 {
                        if nesting, matches(open) {
                            depth += 1
                            skip(open)
                            continue
                        }
                        if matches(close) {
                            depth -= 1
                            skip(close)
                            continue
                        }
                        advance()
                    }
                    emit(from: start, kind: isDocumentation ? .documentationComment : .comment)
                    return true
                case .lineFromColumn(let marker, _):
                    guard matches(marker) else { continue }
                    let start = utf16Offset
                    while !isAtEnd, peek() != "\n" { advance() }
                    emit(from: start, kind: .comment)
                    return true
                }
            }
            return false
        }

        mutating func scanString() -> Bool {
            guard let character = peek() else { return false }
            for style in profile.strings where character == style.quote {
                let start = utf16Offset
                advance()
                // 三重引用符。
                if style.isMultiline, peek() == style.quote, peek(1) == style.quote {
                    advance()
                    advance()
                    while !isAtEnd {
                        if peek() == style.terminator, peek(1) == style.terminator,
                           peek(2) == style.terminator {
                            advance(); advance(); advance()
                            break
                        }
                        advance()
                    }
                    emit(from: start, kind: .string)
                    return true
                }
                while !isAtEnd {
                    if style.allowsEscapes, peek() == "\\" {
                        advance()
                        advance()
                        continue
                    }
                    if peek() == style.terminator {
                        advance()
                        break
                    }
                    // 行をまたがない文字列は、改行で打ち切って壊れた表示を防ぐ。
                    if peek() == "\n", !style.isMultiline { break }
                    advance()
                }
                emit(from: start, kind: style.producesCharacter ? .character : .string)
                return true
            }
            return false
        }

        mutating func scanNumber() -> Bool {
            guard let character = peek(), character.isNumber else { return false }
            let start = utf16Offset
            // 16 進数・2 進数。
            if character == "0", let next = peek(1),
               "xXbBoO".contains(next) {
                advance()
                advance()
                while let digit = peek(), digit.isHexDigit || digit == "_" { advance() }
                emit(from: start, kind: .number)
                return true
            }
            while let digit = peek(), digit.isNumber || digit == "_" { advance() }
            if peek() == ".", let next = peek(1), next.isNumber {
                advance()
                while let digit = peek(), digit.isNumber || digit == "_" { advance() }
            }
            if let exponent = peek(), exponent == "e" || exponent == "E" {
                let sign = peek(1)
                let digit = (sign == "+" || sign == "-") ? peek(2) : sign
                if let digit, digit.isNumber {
                    advance()
                    if let sign, sign == "+" || sign == "-" { advance() }
                    while let digit = peek(), digit.isNumber { advance() }
                }
            }
            // 型を表す接尾辞 (`10L` / `1.5f` / `3u`)。
            while let suffix = peek(), suffix.isLetter { advance() }
            emit(from: start, kind: .number)
            return true
        }

        mutating func scanIdentifier() -> Bool {
            guard let character = peek() else { return false }
            // `@State` / `#include` / `$var` のような印つきの名前。
            if character == "@" || character == "#" {
                if let next = peek(1), next.isLetter || next == "_" {
                    let start = utf16Offset
                    advance()
                    while let inner = peek(), inner.isLetter || inner.isNumber
                            || inner == "_" {
                        advance()
                    }
                    emit(from: start, kind: character == "#" ? .preprocessor : .attribute)
                    return true
                }
            }
            if character == "$" || character == "%" || character == "&" {
                if let next = peek(1), next.isLetter || next == "_" {
                    let start = utf16Offset
                    advance()
                    while let inner = peek(), inner.isLetter || inner.isNumber
                            || inner == "_" {
                        advance()
                    }
                    emit(from: start, kind: .variable)
                    return true
                }
            }
            guard character.isLetter || character == "_" else { return false }

            let start = utf16Offset
            var text = ""
            while let inner = peek(),
                  inner.isLetter || inner.isNumber || inner == "_"
                    || profile.identifierExtras.contains(inner) {
                text.append(inner)
                advance()
            }
            emit(from: start, kind: kind(for: text))
            return true
        }

        /// 名前の種類を決める。
        func kind(for text: String) -> HighlightKind {
            if profile.keywords.contains(text) { return .keyword }
            if profile.trueLiterals.contains(text) || profile.falseLiterals.contains(text)
                || profile.nullLiterals.contains(text) {
                return .constant
            }
            if profile.selfKeywords.contains(text) { return .keyword }
            if profile.typeKeywords[text] != nil { return .keyword }
            if profile.functionKeywords.contains(text) { return .keyword }
            if profile.variableKeywords[text] != nil { return .keyword }
            // 次に `(` が来れば関数呼び出し。
            var cursor = index
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            if cursor < characters.count, characters[cursor] == "(" { return .function }
            // 大文字で始まる名前は型とみなす。
            if let first = text.first, first.isUppercase { return .type }
            // 全部大文字なら定数。
            if text.count > 1, text.allSatisfy({ !$0.isLowercase }) { return .constant }
            return .plain
        }

        mutating func scanOperator() -> Bool {
            for op in profile.operators where matches(op) {
                let start = utf16Offset
                skip(op)
                let isPunctuation = op.count == 1 && "()[]{},;".contains(op)
                emit(from: start, kind: isPunctuation ? .punctuation : .operatorSymbol)
                return true
            }
            return false
        }
    }

    // MARK: 内蔵処理系が無い言語のためのプロファイル

    static let fallbackProfile = MLLanguageProfile(
        languageID: "text",
        keywords: ["if", "else", "for", "while", "return", "function", "class", "var",
                   "let", "const", "def", "end", "do", "then", "switch", "case", "break",
                   "continue", "import", "export", "new", "try", "catch", "finally",
                   "throw", "public", "private", "protected", "static", "void", "int",
                   "float", "double", "bool", "string", "true", "false", "null"],
        variableKeywords: [:], typeKeywords: [:])

    static let cProfile = MLLanguageProfile(
        languageID: "c",
        keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do",
                   "double", "else", "enum", "extern", "float", "for", "goto", "if",
                   "inline", "int", "long", "register", "restrict", "return", "short",
                   "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                   "unsigned", "void", "volatile", "while", "_Bool", "NULL"],
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: ["struct": .structType, "union": .structType, "enum": .enumType],
        nullLiterals: ["NULL"], trueLiterals: ["true"], falseLiterals: ["false"],
        selfKeywords: [])

    static let phpProfile = MLLanguageProfile(
        languageID: "php",
        comments: [.line("//"), .line("#"),
                   .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", simpleVariablePrefix: "$",
                                                keepsVariablePrefix: true),
                  MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false)],
        keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                   "class", "clone", "const", "continue", "declare", "default", "do",
                   "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                   "endif", "endswitch", "endwhile", "enum", "extends", "final", "finally",
                   "fn", "for", "foreach", "function", "global", "goto", "if", "implements",
                   "include", "instanceof", "insteadof", "interface", "isset", "list",
                   "match", "namespace", "new", "or", "print", "private", "protected",
                   "public", "readonly", "require", "return", "static", "switch", "throw",
                   "trait", "try", "unset", "use", "var", "while", "xor", "yield"],
        variableKeywords: [:],
        typeKeywords: ["class": .classType, "interface": .interfaceType,
                       "trait": .interfaceType, "enum": .enumType],
        nullLiterals: ["null", "NULL"], trueLiterals: ["true", "TRUE"],
        falseLiterals: ["false", "FALSE"], selfKeywords: ["this", "self"])

    static let swiftProfile = MLLanguageProfile(
        languageID: "swift",
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "\\(",
                                                isMultiline: true)],
        keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                   "func", "import", "init", "inout", "internal", "let", "open", "operator",
                   "private", "precedencegroup", "protocol", "public", "rethrows", "static",
                   "struct", "subscript", "typealias", "var", "break", "case", "catch",
                   "continue", "default", "defer", "do", "else", "fallthrough", "for",
                   "guard", "if", "in", "repeat", "return", "throw", "switch", "where",
                   "while", "as", "any", "await", "is", "nil", "some", "super", "self",
                   "Self", "throws", "try", "async", "lazy", "weak", "unowned", "mutating",
                   "nonmutating", "override", "required", "convenience", "indirect", "final"],
        identifierExtras: [],
        variableKeywords: ["var": false, "let": true],
        typeKeywords: ["class": .classType, "struct": .structType, "enum": .enumType,
                       "protocol": .interfaceType],
        nullLiterals: ["nil"], selfKeywords: ["self", "Self"])

    static let scalaProfile = MLLanguageProfile(
        languageID: "scala",
        keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "extends",
                   "final", "finally", "for", "forSome", "if", "implicit", "import",
                   "lazy", "match", "new", "object", "override", "package", "private",
                   "protected", "return", "sealed", "super", "this", "throw", "trait",
                   "try", "type", "val", "var", "while", "with", "yield", "given", "using",
                   "enum", "export", "extension", "then"],
        variableKeywords: ["val": true, "var": false],
        typeKeywords: ["class": .classType, "trait": .interfaceType, "object": .classType,
                       "enum": .enumType],
        nullLiterals: ["null", "None"], selfKeywords: ["this"])

    static let pythonProfile = MLLanguageProfile(
        languageID: "python",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", isMultiline: true),
                  MLLanguageProfile.StringStyle(quote: "'", isMultiline: true)],
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue",
                   "def", "del", "elif", "else", "except", "finally", "for", "from",
                   "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
                   "pass", "raise", "return", "try", "while", "with", "yield", "match",
                   "case", "self"],
        variableKeywords: [:],
        typeKeywords: ["class": .classType],
        nullLiterals: ["None"], trueLiterals: ["True"], falseLiterals: ["False"],
        selfKeywords: ["self"])

    static let rubyProfile = MLLanguageProfile(
        languageID: "ruby",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", interpolationPrefix: "#{"),
                  MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false)],
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?",
                   "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module",
                   "next", "not", "or", "redo", "rescue", "retry", "return", "self",
                   "super", "then", "undef", "unless", "until", "when", "while", "yield",
                   "attr_accessor", "attr_reader", "attr_writer", "require", "puts"],
        identifierExtras: ["?", "!"],
        variableKeywords: [:],
        typeKeywords: ["class": .classType, "module": .moduleType],
        nullLiterals: ["nil"], selfKeywords: ["self"])

    static let luaProfile = MLLanguageProfile(
        languageID: "lua",
        comments: [.line("--"), .block(open: "--[[", close: "]]", nesting: false)],
        keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for",
                   "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat",
                   "return", "then", "true", "until", "while"],
        variableKeywords: ["local": false],
        typeKeywords: [:],
        nullLiterals: ["nil"], selfKeywords: ["self"])

    static let sqlProfile = MLLanguageProfile(
        languageID: "sql",
        comments: [.line("--"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false),
                  MLLanguageProfile.StringStyle(quote: "\"", allowsEscapes: false)],
        keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                   "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "ADD", "INDEX", "VIEW",
                   "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON", "GROUP", "BY",
                   "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT", "AS",
                   "AND", "OR", "NOT", "NULL", "IS", "IN", "BETWEEN", "LIKE", "EXISTS",
                   "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT", "CHECK",
                   "INTEGER", "TEXT", "REAL", "BLOB", "BEGIN", "COMMIT", "ROLLBACK",
                   "select", "from", "where", "insert", "into", "values", "update", "set",
                   "delete", "create", "table", "drop", "join", "on", "group", "by",
                   "order", "having", "limit", "as", "and", "or", "not", "null"],
        variableKeywords: [:], typeKeywords: [:], selfKeywords: [])

    static let htmlProfile = MLLanguageProfile(
        languageID: "html",
        comments: [.block(open: "<!--", close: "-->", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\"", allowsEscapes: false),
                  MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false)],
        keywords: ["html", "head", "body", "div", "span", "script", "style", "link",
                   "meta", "title", "a", "p", "ul", "ol", "li", "table", "tr", "td", "th",
                   "form", "input", "button", "img", "canvas", "svg", "header", "footer",
                   "section", "article", "nav", "main", "aside", "h1", "h2", "h3", "h4",
                   "class", "id", "href", "src", "alt", "type", "value", "name"],
        variableKeywords: [:], typeKeywords: [:], selfKeywords: [])

    static let cssProfile = MLLanguageProfile(
        languageID: "css",
        comments: [.block(open: "/*", close: "*/", nesting: false)],
        keywords: ["color", "background", "margin", "padding", "border", "font", "display",
                   "position", "width", "height", "flex", "grid", "top", "left", "right",
                   "bottom", "transform", "transition", "animation", "opacity", "z-index",
                   "important", "media", "import", "keyframes", "root", "hover", "active"],
        variableKeywords: [:], typeKeywords: [:], selfKeywords: [])

    static let jsonProfile = MLLanguageProfile(
        languageID: "json",
        comments: [],
        strings: [MLLanguageProfile.StringStyle(quote: "\"")],
        keywords: [],
        variableKeywords: [:], typeKeywords: [:],
        nullLiterals: ["null"], selfKeywords: [])

    static let yamlProfile = MLLanguageProfile(
        languageID: "yaml",
        comments: [.line("#")],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", allowsEscapes: false)],
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        variableKeywords: [:], typeKeywords: [:], selfKeywords: [])

    static let markdownProfile = MLLanguageProfile(
        languageID: "markdown",
        comments: [],
        strings: [MLLanguageProfile.StringStyle(quote: "`", allowsEscapes: false)],
        keywords: [],
        variableKeywords: [:], typeKeywords: [:], selfKeywords: [])

    static let lispProfile = MLLanguageProfile(
        languageID: "lisp",
        comments: [.line(";")],
        strings: [MLLanguageProfile.StringStyle(quote: "\"")],
        keywords: ["defun", "defvar", "defparameter", "defconstant", "defmacro", "let",
                   "let*", "lambda", "if", "cond", "case", "when", "unless", "progn",
                   "loop", "dolist", "dotimes", "setq", "setf", "and", "or", "not",
                   "return", "return-from", "quote", "function", "t", "nil"],
        operators: ["(", ")", "'", "`", ",", "#"],
        variableKeywords: [:], typeKeywords: [:],
        nullLiterals: ["nil"], trueLiterals: ["t"], falseLiterals: ["nil"],
        selfKeywords: [])
}
