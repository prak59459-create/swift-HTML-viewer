import Foundation

/// 言語の「見た目」を表で持つ。
///
/// 中括弧を使う言語はだいたい同じ形をしているので、
/// 違うところだけこの表に書き、字句解析と構文解析の本体は共有する。
public struct MLLanguageProfile {
    public enum CommentStyle {
        case line(String)
        case block(open: String, close: String, nesting: Bool)
        /// 行頭の特定文字から行末まで (シェルの `#` など)。
        case lineFromColumn(String, column: Int)
    }

    /// 文字列リテラルの書き方。
    public struct StringStyle {
        public var quote: Character
        /// 閉じ記号 (省略すると `quote` と同じ)。
        public var terminator: Character
        /// `\n` などのエスケープを解釈するか。
        public var allowsEscapes: Bool
        /// `\(expr)` / `${expr}` のような補間の開始記号。
        public var interpolationPrefix: String?
        /// `$name` のように括弧なしで書ける変数の印。
        public var simpleVariablePrefix: Character?
        /// `$name` の `$` を式の一部として残すか (Perl / PHP のように
        /// 記号まで含めて変数名になる言語で true)。
        public var keepsVariablePrefix: Bool
        /// この引用符は 1 文字の文字リテラルを作る。
        public var producesCharacter: Bool
        /// 三重引用符のような複数行リテラル。
        public var isMultiline: Bool

        public init(quote: Character, terminator: Character? = nil, allowsEscapes: Bool = true,
                    interpolationPrefix: String? = nil, simpleVariablePrefix: Character? = nil,
                    keepsVariablePrefix: Bool = false,
                    producesCharacter: Bool = false, isMultiline: Bool = false) {
            self.quote = quote
            self.terminator = terminator ?? quote
            self.allowsEscapes = allowsEscapes
            self.interpolationPrefix = interpolationPrefix
            self.simpleVariablePrefix = simpleVariablePrefix
            self.keepsVariablePrefix = keepsVariablePrefix
            self.producesCharacter = producesCharacter
            self.isMultiline = isMultiline
        }
    }

    /// 関数宣言の書き方。
    public enum FunctionSyntax {
        /// `int f(int x) { }` のように戻り値の型が先に来る。
        case typeFirst
        /// `func f(x: Int) -> Int { }` のようにキーワードで始まる。
        case keyword
        /// どちらも許す。
        case both
    }

    public var languageID: String
    public var comments: [CommentStyle]
    public var strings: [StringStyle]
    public var keywords: Set<String>
    /// 長いものから順に照合する演算子・区切り記号。
    public var operators: [String]
    /// 改行が文の区切りになるか (Go / Kotlin / Swift など)。
    public var newlineTerminatesStatement: Bool
    /// `;` を文の区切りとして受け付けるか。
    public var usesSemicolons: Bool
    /// 識別子に使える追加の文字 (`!` や `?` を許す言語がある)。
    public var identifierExtras: Set<Character>
    /// 数値リテラルで `_` を桁区切りに使えるか。
    public var allowsNumericSeparators: Bool

    public var functionSyntax: FunctionSyntax
    /// 関数宣言を始めるキーワード。
    public var functionKeywords: Set<String>
    /// 変数宣言を始めるキーワードと、それが定数かどうか。
    public var variableKeywords: [String: Bool]
    /// 型宣言のキーワードと種類。
    public var typeKeywords: [String: MLTypeDecl.Kind]
    /// 無視してよい修飾子 (`public` / `final` / `@Override` など)。
    public var ignorableModifiers: Set<String>
    /// ラムダの矢印 (`->` / `=>`)。
    public var lambdaArrows: [String]
    /// `nil` に相当する語。
    public var nullLiterals: Set<String>
    public var trueLiterals: Set<String>
    public var falseLiterals: Set<String>
    /// `self` に相当する語。
    public var selfKeywords: Set<String>
    /// 代入演算子の一覧 (複合代入を含む)。
    public var assignmentOperators: Set<String>

    public init(languageID: String,
                comments: [CommentStyle] = [.line("//"),
                                            .block(open: "/*", close: "*/", nesting: false)],
                strings: [StringStyle] = [StringStyle(quote: "\""),
                                          StringStyle(quote: "'", producesCharacter: true)],
                keywords: Set<String> = [],
                operators: [String] = MLLanguageProfile.cStyleOperators,
                newlineTerminatesStatement: Bool = false,
                usesSemicolons: Bool = true,
                identifierExtras: Set<Character> = [],
                allowsNumericSeparators: Bool = true,
                functionSyntax: FunctionSyntax = .keyword,
                functionKeywords: Set<String> = ["func"],
                variableKeywords: [String: Bool] = ["var": false, "let": true],
                typeKeywords: [String: MLTypeDecl.Kind] = ["class": .classType,
                                                           "struct": .structType,
                                                           "enum": .enumType,
                                                           "interface": .interfaceType],
                ignorableModifiers: Set<String> = [],
                lambdaArrows: [String] = ["->"],
                nullLiterals: Set<String> = ["null", "nil", "None"],
                trueLiterals: Set<String> = ["true"],
                falseLiterals: Set<String> = ["false"],
                selfKeywords: Set<String> = ["self", "this"],
                assignmentOperators: Set<String> = MLLanguageProfile.cStyleAssignments) {
        self.languageID = languageID
        self.comments = comments
        self.strings = strings
        self.keywords = keywords
        self.operators = operators.sorted { $0.count > $1.count }
        self.newlineTerminatesStatement = newlineTerminatesStatement
        self.usesSemicolons = usesSemicolons
        self.identifierExtras = identifierExtras
        self.allowsNumericSeparators = allowsNumericSeparators
        self.functionSyntax = functionSyntax
        self.functionKeywords = functionKeywords
        self.variableKeywords = variableKeywords
        self.typeKeywords = typeKeywords
        self.ignorableModifiers = ignorableModifiers
        self.lambdaArrows = lambdaArrows
        self.nullLiterals = nullLiterals
        self.trueLiterals = trueLiterals
        self.falseLiterals = falseLiterals
        self.selfKeywords = selfKeywords
        self.assignmentOperators = assignmentOperators
    }

    public static let cStyleOperators: [String] = [
        ">>>=", "<=>", "...", "<<=", ">>=", "**=", "&&=", "||=", "??=", ">>>", "..<",
        "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=",
        "/=", "%=", "&=", "|=", "^=", "<<", ">>", "::", "??", "?.", "?:", "..", "**",
        "===", "!==", "|>", "<-",
        "+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~", "?", ":",
        ";", ",", ".", "(", ")", "[", "]", "{", "}", "@", "#", "$", "\\"
    ]

    public static let cStyleAssignments: Set<String> = [
        "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=",
        "**=", "&&=", "||=", "??="
    ]
}

/// 表にしたがって字句に切り分ける汎用の字句解析器。
open class MLProfileLexer: MLLexerBase {
    public let profile: MLLanguageProfile

    public init(source: String, profile: MLLanguageProfile, diagnostics: DiagnosticBag) {
        self.profile = profile
        super.init(source: source, diagnostics: diagnostics)
    }

    /// 全部まとめて切り出す。
    open func tokenize() -> [MLToken] {
        var tokens: [MLToken] = []
        var sawNewline = false
        while true {
            let skipped = skipIgnorable()
            sawNewline = sawNewline || skipped
            guard !isAtEnd else { break }
            guard var token = nextToken() else { continue }
            token.precededByNewline = sawNewline
            sawNewline = false
            tokens.append(token)
        }
        tokens.append(MLToken(kind: .endOfFile, text: "", location: location,
                              precededByNewline: sawNewline))
        return tokens
    }

    /// 空白とコメントを読み飛ばす。改行をまたいだら true。
    @discardableResult
    open func skipIgnorable() -> Bool {
        var sawNewline = false
        while !isAtEnd {
            if let character = peek(), character.isWhitespace {
                if character == "\n" { sawNewline = true }
                advance()
                continue
            }
            var matchedComment = false
            for style in profile.comments {
                switch style {
                case .line(let marker):
                    if lookahead(marker) {
                        _ = match(marker)
                        skipLineComment()
                        matchedComment = true
                    }
                case .block(let open, let close, let nesting):
                    if lookahead(open) {
                        _ = match(open)
                        skipBlockComment(open: open, close: close, allowsNesting: nesting)
                        matchedComment = true
                    }
                case .lineFromColumn(let marker, let requiredColumn):
                    if column == requiredColumn, lookahead(marker) {
                        _ = match(marker)
                        skipLineComment()
                        matchedComment = true
                    }
                }
                if matchedComment { break }
            }
            if matchedComment { continue }
            break
        }
        return sawNewline
    }

    /// 1 つぶん切り出す。言語ごとの特殊な記法はここを上書きして足す。
    open func nextToken() -> MLToken? {
        guard let character = peek() else { return nil }
        let start = location

        // 文字列。
        for style in profile.strings where character == style.quote {
            return readString(style: style, start: start)
        }

        // 数値。
        if character.isNumber {
            return readNumber(allowsUnderscoreSeparator: profile.allowsNumericSeparators)
        }
        // `.5` のような書き方。
        if character == ".", let next = peek(1), next.isNumber {
            return readNumber(allowsUnderscoreSeparator: profile.allowsNumericSeparators)
        }

        // 識別子・キーワード。
        if MLLexerBase.isIdentifierStart(character) {
            let text = readIdentifier(extraCharacters: profile.identifierExtras)
            let kind: MLTokenKind = profile.keywords.contains(text) ? .keyword : .identifier
            return MLToken(kind: kind, text: text, location: start)
        }

        // 演算子・区切り記号。
        for op in profile.operators where lookahead(op) {
            _ = match(op)
            return MLToken(kind: .punctuation, text: op, location: start)
        }

        // 知らない文字は 1 文字の記号として通し、後で構文解析側が文句を言う。
        advance()
        return MLToken(kind: .punctuation, text: String(character), location: start)
    }

    /// 文字列リテラルを読む。
    open func readString(style: MLLanguageProfile.StringStyle,
                         start: SourceLocation) -> MLToken {
        advance() // 開きの引用符

        // 三重引用符。
        if style.isMultiline, peek() == style.quote, peek(1) == style.quote {
            advance()
            advance()
            var text = ""
            while !isAtEnd {
                if peek() == style.terminator, peek(1) == style.terminator,
                   peek(2) == style.terminator {
                    advance(); advance(); advance()
                    break
                }
                if style.allowsEscapes, peek() == "\\" {
                    advance()
                    text += decodeEscape()
                    continue
                }
                if let character = advance() { text.append(character) }
            }
            return MLToken(kind: .stringLiteral, text: text, location: start, stringValue: text)
        }

        if let prefix = style.interpolationPrefix ?? style.simpleVariablePrefix.map({ String($0) }) {
            let pieces = readInterpolatedString(
                terminator: style.terminator,
                interpolationPrefix: style.interpolationPrefix ?? "",
                simpleVariablePrefix: style.simpleVariablePrefix,
                allowsEscapes: style.allowsEscapes,
                keepsVariablePrefix: style.keepsVariablePrefix)
            _ = prefix
            // 補間が無ければただの文字列として返す。
            if pieces.allSatisfy({ !$0.isExpression }) {
                let text = pieces.map { $0.text }.joined()
                if style.producesCharacter {
                    return MLToken(kind: .charLiteral, text: text, location: start,
                                   stringValue: text)
                }
                return MLToken(kind: .stringLiteral, text: text, location: start,
                               stringValue: text)
            }
            return MLToken(kind: .interpolatedString, text: "", location: start, pieces: pieces)
        }

        let text = readSimpleString(terminator: style.terminator,
                                    allowsEscapes: style.allowsEscapes)
        if style.producesCharacter {
            return MLToken(kind: .charLiteral, text: text, location: start, stringValue: text)
        }
        return MLToken(kind: .stringLiteral, text: text, location: start, stringValue: text)
    }
}
