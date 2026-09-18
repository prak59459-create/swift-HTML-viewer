import Foundation

/// 内蔵の Objective-C 処理系。
///
/// C の文法に「角括弧のメッセージ送信」と `@interface` / `@implementation`、
/// `NSString` / `NSArray` / `NSDictionary` などの基本クラスを足した言語。
public enum MiniObjectiveC: MiniLangEngine {
    public static var languageID: String { "objectivec" }
    public static var displayName: String { "内蔵 Objective-C 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let tokens = ObjCLexer(source: source, diagnostics: diagnostics).tokenize()
        return try ObjCParser(tokens: tokens, diagnostics: diagnostics).parseProgram()
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let tokens = ObjCLexer(source: source, diagnostics: diagnostics).tokenize()
            let parser = ObjCParser(tokens: tokens, diagnostics: diagnostics)
            let program: MLProgram
            do {
                program = try parser.parseProgram()
            } catch {
                if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
                return MiniLangExecution(parsed: false,
                                         diagnosticsText: "構文を解析できませんでした",
                                         errorCount: 1, exitCode: 1)
            }
            if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
            let semantics = ObjCSemantics()
            let interpreter = MLInterpreter(semantics: semantics, limits: limits, input: input)
            return interpreter.run(program)
        }
    }
}

enum ObjCProfile {
    static let keywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "restrict", "return", "short", "signed", "sizeof", "static",
        "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
        "id", "self", "super", "nil", "Nil", "YES", "NO", "BOOL", "SEL", "IMP", "Class",
        "in", "out", "inout", "bycopy", "byref", "oneway", "instancetype", "NSInteger",
        "NSUInteger", "CGFloat", "true", "false"
    ]

    static let profile = MLLanguageProfile(
        languageID: "objectivec",
        comments: [.line("//"), .block(open: "/*", close: "*/", nesting: false)],
        strings: [MLLanguageProfile.StringStyle(quote: "\""),
                  MLLanguageProfile.StringStyle(quote: "'", producesCharacter: true)],
        keywords: keywords,
        operators: MLLanguageProfile.cStyleOperators,
        functionSyntax: .typeFirst,
        functionKeywords: [],
        variableKeywords: [:],
        typeKeywords: ["struct": .structType, "enum": .enumType, "union": .structType],
        ignorableModifiers: ["static", "const", "extern", "inline", "register",
                             "volatile", "__strong", "__weak", "__block", "unsigned",
                             "signed", "nonnull", "nullable", "_Nullable", "_Nonnull"],
        nullLiterals: ["nil", "Nil", "NULL"],
        trueLiterals: ["YES", "true"],
        falseLiterals: ["NO", "false"],
        selfKeywords: ["self"])
}

final class ObjCLexer: MLProfileLexer {
    init(source: String, diagnostics: DiagnosticBag) {
        super.init(source: source, profile: ObjCProfile.profile, diagnostics: diagnostics)
    }

    override func skipIgnorable() -> Bool {
        var sawNewline = super.skipIgnorable()
        // `#import` / `#include` などのプリプロセッサ行は読み飛ばす。
        while column == 1, peek() == "#" {
            skipLineComment()
            sawNewline = true
            sawNewline = super.skipIgnorable() || sawNewline
        }
        return sawNewline
    }

    override func nextToken() -> MLToken? {
        let start = location
        // `@"..."` は NSString リテラル。
        if peek() == "@", peek(1) == "\"" {
            advance()
            advance()
            let text = readSimpleString(terminator: "\"")
            return MLToken(kind: .stringLiteral, text: text, location: start,
                           stringValue: text)
        }
        // `@interface` などのディレクティブは 1 語として扱う。
        if peek() == "@", let next = peek(1), MLLexerBase.isIdentifierStart(next) {
            advance()
            let name = readIdentifier()
            return MLToken(kind: .keyword, text: "@" + name, location: start)
        }
        if let character = peek(), character.isNumber {
            let token = readNumber(allowsUnderscoreSeparator: false)
            while let suffix = peek(), "uUlLfF".contains(suffix) { advance() }
            return token
        }
        return super.nextToken()
    }
}

final class ObjCParser: MLProfileParser {
    private var insideFunctionBody = false
    /// `@implementation` を読んでいる間のクラス名。
    private var currentImplementation: String?

    init(tokens: [MLToken], diagnostics: DiagnosticBag) {
        super.init(tokens: tokens, profile: ObjCProfile.profile, diagnostics: diagnostics)
    }

    override func entryPointName() -> String? { "main" }

    override func parseProgram() throws -> MLProgram {
        var statements: [MLStmt] = []
        while !isAtEnd {
            skipStatementSeparators()
            if isAtEnd { break }
            let before = index
            if let statement = try parseStatement() { statements.append(statement) }
            if index == before { advance() }
        }
        let hasMain = statements.contains { statement in
            if case .funcDecl(let decl) = statement { return decl.name == "main" }
            return false
        }
        return MLProgram(statements: statements, entryPoint: hasMain ? "main" : nil)
    }

    override func parseStatement() throws -> MLStmt? {
        skipStatementSeparators()
        if isAtEnd { return nil }
        let location = current.location

        if check("@interface") { return try parseInterface() }
        if check("@implementation") { return try parseImplementation() }
        if check("@protocol") {
            advance()
            while !isAtEnd, !check("@end") { advance() }
            _ = match("@end")
            return .noop(location)
        }
        if check("@autoreleasepool") {
            advance()
            return .block(try parseBlock(), location)
        }
        if check("@synthesize") || check("@dynamic") || check("@class") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("@try") { return try parseObjCTry() }
        if check("@throw") {
            advance()
            let value = try parseExpression()
            consumeStatementEnd()
            return .throwStmt(value, location)
        }
        if check("typedef") {
            skipToStatementEnd()
            return .noop(location)
        }
        if check("for"), peek(1).is("("), looksLikeFastEnumeration() {
            return try parseFastEnumeration()
        }
        if looksLikeDeclaration() {
            return try parseDeclaration(consumesEnd: true)
        }
        return try super.parseStatement()
    }

    /// `for (NSString *s in array)` の形かどうか。
    private func looksLikeFastEnumeration() -> Bool {
        var offset = 2
        var depth = 1
        while depth > 0, !peek(offset).isEndOfFile {
            if peek(offset).is("(") { depth += 1 }
            if peek(offset).is(")") { depth -= 1 }
            if depth == 1, peek(offset).is(";") { return false }
            if depth == 1, peek(offset).is("in") { return true }
            offset += 1
        }
        return false
    }

    private func parseFastEnumeration() throws -> MLStmt {
        let location = current.location
        advance()
        try expect("(", "for の始まり")
        while profile.ignorableModifiers.contains(current.text) { advance() }
        _ = try? parseTypeName()
        while match("*") {}
        let name = try expectIdentifier("繰り返しの変数")
        try expect("in", "for ... in")
        let sequence = try parseExpression()
        try expect(")", "for の終わり")
        let body = try parseStatementAsBlock()
        return .forIn(pattern: .binding(name), sequence: sequence, body: body,
                      whereClause: nil, label: nil, location)
    }

    private func parseObjCTry() throws -> MLStmt {
        let location = current.location
        try expect("@try")
        let body = try parseBlock()
        var catches: [MLCatchClause] = []
        var finallyBody: [MLStmt]?
        while check("@catch") {
            advance()
            try expect("(", "@catch")
            var typeName: String?
            var binding: String?
            while profile.ignorableModifiers.contains(current.text) { advance() }
            if current.kind == .identifier || current.kind == .keyword {
                typeName = try parseTypeName()
                while match("*") {}
                if current.kind == .identifier { binding = advance().text }
            }
            try expect(")", "@catch")
            let clauseBody = try parseBlock()
            catches.append(MLCatchClause(typeName: typeName == "id" ? nil : typeName,
                                         binding: binding, body: clauseBody))
        }
        if check("@finally") {
            advance()
            finallyBody = try parseBlock()
        }
        return .tryStmt(body: body, catches: catches, finallyBody: finallyBody, location)
    }

    /// `@interface Foo : NSObject ... @end`
    private func parseInterface() throws -> MLStmt {
        let location = current.location
        try expect("@interface")
        let name = try expectIdentifier("クラス名")
        var superclassName: String?
        if match(":") { superclassName = try expectIdentifier("親クラス名") }
        if check("(") { skipBalanced(open: "(", close: ")") }   // カテゴリ
        if check("<") { skipGenericParameters() }               // プロトコル

        var properties: [MLPropertyDecl] = []
        // インスタンス変数のブロック。
        if check("{") {
            advance()
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                while profile.ignorableModifiers.contains(current.text) { advance() }
                guard (try? parseTypeName()) != nil else {
                    advance()
                    continue
                }
                while match("*") {}
                repeat {
                    guard current.kind == .identifier else { break }
                    properties.append(MLPropertyDecl(name: advance().text))
                } while match(",")
                consumeStatementEnd()
            }
            try expect("}", "インスタンス変数の終わり")
        }
        // メソッド宣言とプロパティ宣言は、実装側で本体を読むので名前だけ拾う。
        while !isAtEnd, !check("@end") {
            skipStatementSeparators()
            if check("@end") { break }
            if check("@property") {
                advance()
                if check("(") { skipBalanced(open: "(", close: ")") }
                while profile.ignorableModifiers.contains(current.text) { advance() }
                _ = try? parseTypeName()
                while match("*") {}
                if current.kind == .identifier {
                    properties.append(MLPropertyDecl(name: advance().text))
                }
                consumeStatementEnd()
                continue
            }
            // `- (void)foo;` などの宣言は読み飛ばす。
            skipToStatementEnd()
        }
        _ = match("@end")
        return .typeDecl(MLTypeDecl(kind: .classType, name: name,
                                    superclassName: superclassName == "NSObject"
                                        ? nil : superclassName,
                                    properties: properties, location: location))
    }

    /// `@implementation Foo ... @end`
    private func parseImplementation() throws -> MLStmt {
        let location = current.location
        try expect("@implementation")
        let name = try expectIdentifier("クラス名")
        if check("(") { skipBalanced(open: "(", close: ")") }
        let saved = currentImplementation
        currentImplementation = name
        defer { currentImplementation = saved }

        var methods: [MLFunctionDecl] = []
        var properties: [MLPropertyDecl] = []
        if check("{") {
            advance()
            while !isAtEnd, !check("}") {
                skipStatementSeparators()
                if check("}") { break }
                while profile.ignorableModifiers.contains(current.text) { advance() }
                guard (try? parseTypeName()) != nil else {
                    advance()
                    continue
                }
                while match("*") {}
                repeat {
                    guard current.kind == .identifier else { break }
                    properties.append(MLPropertyDecl(name: advance().text))
                } while match(",")
                consumeStatementEnd()
            }
            try expect("}", "インスタンス変数の終わり")
        }

        while !isAtEnd, !check("@end") {
            skipStatementSeparators()
            if check("@end") { break }
            if check("@synthesize") || check("@dynamic") {
                skipToStatementEnd()
                continue
            }
            if check("-") || check("+") {
                methods.append(try parseMethodDefinition())
                continue
            }
            let before = index
            _ = try parseStatement()
            if index == before { advance() }
        }
        _ = match("@end")
        return .typeDecl(MLTypeDecl(kind: .classType, name: name, properties: properties,
                                    methods: methods, location: location))
    }

    /// `- (NSString *)greet:(NSString *)name times:(int)n { ... }`
    ///
    /// Objective-C のセレクタ名は `greet:times:` になるが、呼び出し側でも
    /// 同じ規則で組み立てるので一致する。
    private func parseMethodDefinition() throws -> MLFunctionDecl {
        let location = current.location
        let isStatic = current.text == "+"
        advance()
        // 戻り値の型。
        if check("(") { skipBalanced(open: "(", close: ")") }

        var selector = ""
        var parameters: [MLParameter] = []
        while !isAtEnd, !check("{"), !check(";") {
            guard current.kind == .identifier || current.kind == .keyword else { break }
            let part = advance().text
            if match(":") {
                selector += part + ":"
                if check("(") { skipBalanced(open: "(", close: ")") }
                let name = try expectIdentifier("引数名")
                parameters.append(MLParameter(name: name))
            } else {
                selector += part
                break
            }
        }
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        var body: [MLStmt] = []
        if check("{") { body = try parseBlock() } else { consumeStatementEnd() }
        // `init` は普通のメソッドとして扱う (`[[Foo alloc] init]` の形で呼ばれるため)。
        return MLFunctionDecl(name: selector, parameters: parameters, body: body,
                              isStatic: isStatic, isInitializer: false,
                              location: location)
    }

    override func isFunctionDeclarationStart() -> Bool {
        insideFunctionBody ? false : super.isFunctionDeclarationStart()
    }

    override func parseFunctionDeclaration() throws -> MLFunctionDecl {
        let saved = insideFunctionBody
        insideFunctionBody = true
        defer { insideFunctionBody = saved }
        return try super.parseFunctionDeclaration()
    }

    private func looksLikeDeclaration() -> Bool {
        var offset = 0
        while profile.ignorableModifiers.contains(peek(offset).text) { offset += 1 }
        let start = peek(offset)
        guard start.kind == .identifier || start.kind == .keyword else { return false }
        guard !nonTypeKeywords.contains(start.text) else { return false }
        if start.kind == .identifier, start.text.first?.isUppercase != true,
           !isKnownTypeName(start.text) { return false }
        offset += 1
        while peek(offset).is("*") { offset += 1 }
        if peek(offset).is("<") {
            var depth = 0
            repeat {
                if peek(offset).is("<") { depth += 1 }
                if peek(offset).is(">") { depth -= 1 }
                offset += 1
            } while depth > 0 && !peek(offset).isEndOfFile
            while peek(offset).is("*") { offset += 1 }
        }
        guard peek(offset).kind == .identifier else { return false }
        let next = peek(offset + 1).text
        return next == "=" || next == ";" || next == "," || next == "["
    }

    private func isKnownTypeName(_ text: String) -> Bool {
        ["int", "long", "short", "char", "float", "double", "void", "id", "BOOL",
         "NSInteger", "NSUInteger", "CGFloat", "unsigned", "signed", "SEL", "Class",
         "instancetype", "size_t"].contains(text)
    }

    private func parseDeclaration(consumesEnd: Bool) throws -> MLStmt {
        let location = current.location
        while profile.ignorableModifiers.contains(current.text) { advance() }
        var typeName = try parseTypeName()
        if check("<") {
            skipGenericParameters()
        }
        while match("*") { typeName = "Pointer<\(typeName)>" }
        var declarations: [MLStmt] = []
        repeat {
            while match("*") {}
            let name = try expectIdentifier("変数名")
            var fullType = typeName
            var arraySize: MLExpr?
            while check("["), !peek(1).is("]") || true {
                guard check("[") else { break }
                advance()
                if !check("]") { arraySize = try parseExpression() }
                try expect("]", "配列の宣言")
                fullType = "Array<\(fullType)>"
                break
            }
            var value: MLExpr?
            if match("=") {
                value = check("{") ? .listLiteral(try parseArrayInitializer(),
                                                  spreadIndices: [], location)
                                   : try parseExpression()
            } else if let arraySize {
                value = .call(callee: .name("#newArray", location),
                              arguments: [MLArgument(value: arraySize),
                                          MLArgument(value: .literal(.string(typeName),
                                                                     location))],
                              location)
            }
            declarations.append(.varDecl(pattern: .binding(name), typeName: fullType,
                                          value: value, isConstant: false, location))
        } while match(",")
        if consumesEnd { consumeStatementEnd() }
        return declarations.count == 1 ? declarations[0] : .group(declarations, location)
    }

    override func parseForInitializerDeclaration() throws -> MLStmt? {
        guard looksLikeDeclaration() else { return nil }
        return try parseDeclaration(consumesEnd: false)
    }

    /// `(int)expr` のような C 形式のキャスト。
    override func parseUnary(stopAtBrace: Bool) throws -> MLExpr {
        guard check("(") else { return try super.parseUnary(stopAtBrace: stopAtBrace) }
        let location = current.location
        let saved = index
        advance()
        if current.kind == .identifier || current.kind == .keyword {
            diagnostics.beginSuppression()
            let parsed = try? parseTypeName()
            diagnostics.endSuppression()
            if let typeName = parsed {
                while match("*") {}
                if check("<") { skipGenericParameters(); while match("*") {} }
                if check(")"), startsExpression(peek(1)) {
                    advance()
                    let operand = try parseUnary(stopAtBrace: stopAtBrace)
                    return .cast(operand, typeName: typeName, isOptional: false, location)
                }
            }
        }
        index = saved
        return try super.parseUnary(stopAtBrace: stopAtBrace)
    }

    /// その字句から式が始まりうるか。
    private func startsExpression(_ token: MLToken) -> Bool {
        switch token.kind {
        case .identifier, .integerLiteral, .floatLiteral, .stringLiteral,
             .charLiteral, .interpolatedString:
            return true
        case .keyword:
            return !["if", "else", "while", "for", "return", "switch", "case"]
                .contains(token.text)
        default:
            return ["(", "[", "-", "!", "~", "@", "*", "&", "^"].contains(token.text)
        }
    }

    /// `[receiver message:arg1 with:arg2]` と `@[...]` / `@{...}` / `@(...)`。
    override func parsePrimary(stopAtBrace: Bool) throws -> MLExpr {
        let location = current.location
        if check("[") {
            return try parseMessageSend()
        }
        if check("@") {
            // `@[ ... ]` / `@{ ... }` / `@(expr)` / `@123`
            advance()
            if check("[") {
                advance()
                var items: [MLExpr] = []
                while !isAtEnd, !check("]") {
                    items.append(try parseExpression())
                    if !match(",") { break }
                }
                try expect("]", "配列リテラル")
                return .listLiteral(items, spreadIndices: [], location)
            }
            if check("{") {
                advance()
                var pairs: [(key: MLExpr, value: MLExpr)] = []
                while !isAtEnd, !check("}") {
                    let key = try parseExpression()
                    try expect(":", "辞書リテラル")
                    pairs.append((key: key, value: try parseExpression()))
                    if !match(",") { break }
                }
                try expect("}", "辞書リテラル")
                return .mapLiteral(pairs, location)
            }
            if check("(") {
                advance()
                let value = try parseExpression()
                try expect(")", "@() の終わり")
                return value
            }
            return try parsePrimary(stopAtBrace: stopAtBrace)
        }
        if check("^") {
            // ブロック `^(int x) { return x; }`
            advance()
            if check("(") {
                let parameters = try parseParameterList()
                let body = try parseBlock()
                return .lambda(MLFunctionDecl(name: "", parameters: parameters, body: body,
                                              location: location), location)
            }
            let body = try parseBlock()
            return .lambda(MLFunctionDecl(name: "", parameters: [], body: body,
                                          location: location), location)
        }
        return try super.parsePrimary(stopAtBrace: stopAtBrace)
    }

    /// `[obj doThis:a andThat:b]`
    private func parseMessageSend() throws -> MLExpr {
        let location = current.location
        try expect("[", "メッセージ送信")
        let receiver = try parseExpression()
        var selector = ""
        var arguments: [MLArgument] = []
        while !isAtEnd, !check("]") {
            guard current.kind == .identifier || current.kind == .keyword else { break }
            let part = advance().text
            if match(":") {
                selector += part + ":"
                arguments.append(MLArgument(value: try parseExpression()))
                // 可変長引数 `arrayWithObjects:a, b, nil`
                while match(",") {
                    arguments.append(MLArgument(value: try parseExpression()))
                }
            } else {
                selector += part
                break
            }
        }
        try expect("]", "メッセージ送信の終わり")
        return .call(callee: .member(receiver, selector, isOptional: false, location),
                     arguments: arguments, location)
    }

    override func makeLexer(for text: String) -> MLProfileLexer {
        ObjCLexer(source: text, diagnostics: diagnostics)
    }

    override func makeSubParser(tokens: [MLToken]) -> MLProfileParser {
        ObjCParser(tokens: tokens, diagnostics: diagnostics)
    }
}
