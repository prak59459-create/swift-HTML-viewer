import Foundation

/// 内蔵の Lisp 処理系 (Common Lisp 寄り)。
///
/// S 式を読み込んでから共通の中間表現に組み替える。特殊形式 (`defun` /
/// `let` / `cond` など) はここで中間表現の文や式に直し、それ以外は
/// すべて関数呼び出しとして扱う。
public enum MiniLisp: MiniLangEngine {
    public static var languageID: String { "lisp" }
    public static var displayName: String { "内蔵 Lisp 処理系" }

    /// 構文木だけを組み立てる (実行はしない)。
    ///
    /// 構文木ビューアやトークン一覧など、見せるための機能から使う。
    public static func parse(source: String,
                             diagnostics: DiagnosticBag) throws -> MLProgram {
        let forms = try LispReader(source: source, diagnostics: diagnostics).readAll()
        return try LispCompiler(diagnostics: diagnostics).compile(forms)
    }

    public static func execute(source: String, input: String,
                               limits: MiniLangLimits) -> MiniLangExecution {
        MiniLangRunner.run {
            let diagnostics = DiagnosticBag(source: source)
            let reader = LispReader(source: source, diagnostics: diagnostics)
            let program: MLProgram
            do {
                let forms = try reader.readAll()
                let compiler = LispCompiler(diagnostics: diagnostics)
                program = try compiler.compile(forms)
            } catch {
                if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
                return MiniLangExecution(parsed: false,
                                         diagnosticsText: "S 式を読めませんでした",
                                         errorCount: 1, exitCode: 1)
            }
            if let failure = diagnostics.failureIfNeeded() { return .syntaxError(failure) }
            let interpreter = MLInterpreter(semantics: LispSemantics(), limits: limits,
                                            input: input)
            return interpreter.run(program)
        }
    }
}

/// 読み込んだ S 式。
indirect enum LispForm {
    case symbol(String, SourceLocation)
    case integer(Int64, SourceLocation)
    case real(Double, SourceLocation)
    case text(String, SourceLocation)
    case character(Character, SourceLocation)
    case list([LispForm], SourceLocation)
    case quoted(LispForm, SourceLocation)

    var location: SourceLocation {
        switch self {
        case .symbol(_, let l), .integer(_, let l), .real(_, let l), .text(_, let l),
             .character(_, let l), .list(_, let l), .quoted(_, let l):
            return l
        }
    }

    var symbolName: String? {
        if case .symbol(let name, _) = self { return name }
        return nil
    }

    var items: [LispForm]? {
        if case .list(let items, _) = self { return items }
        return nil
    }
}

/// S 式の読み取り。
final class LispReader {
    private let characters: [Character]
    private var position = 0
    private var line = 1
    private var column = 1
    private let diagnostics: DiagnosticBag

    init(source: String, diagnostics: DiagnosticBag) {
        self.characters = Array(source)
        self.diagnostics = diagnostics
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }
    private var isAtEnd: Bool { position >= characters.count }

    private func peek(_ offset: Int = 0) -> Character? {
        let index = position + offset
        return index < characters.count ? characters[index] : nil
    }

    @discardableResult
    private func advance() -> Character? {
        guard position < characters.count else { return nil }
        let character = characters[position]
        position += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return character
    }

    private func skipIgnorable() {
        while !isAtEnd {
            if let character = peek(), character.isWhitespace {
                advance()
                continue
            }
            if peek() == ";" {
                while let character = peek(), character != "\n" { advance() }
                continue
            }
            // `#|` … `|#` の塊コメント。
            if peek() == "#", peek(1) == "|" {
                advance(); advance()
                while !isAtEnd, !(peek() == "|" && peek(1) == "#") { advance() }
                advance(); advance()
                continue
            }
            break
        }
    }

    func readAll() throws -> [LispForm] {
        var forms: [LispForm] = []
        while true {
            skipIgnorable()
            if isAtEnd { break }
            forms.append(try read())
        }
        return forms
    }

    func read() throws -> LispForm {
        skipIgnorable()
        let start = location
        guard let character = peek() else {
            diagnostics.error("S 式が途中で終わりました", at: start)
            throw AbortCompilation()
        }
        if character == "(" || character == "[" {
            advance()
            let close: Character = character == "(" ? ")" : "]"
            var items: [LispForm] = []
            while true {
                skipIgnorable()
                guard let next = peek() else {
                    diagnostics.error("閉じ括弧がありません", at: start)
            throw AbortCompilation()
                }
                if next == close || next == ")" || next == "]" {
                    advance()
                    break
                }
                items.append(try read())
            }
            return .list(items, start)
        }
        if character == "'" {
            advance()
            return .quoted(try read(), start)
        }
        if character == "`" || character == "," {
            // 準引用は単純な引用として扱う。
            advance()
            if peek() == "@" { advance() }
            return try read()
        }
        if character == "\"" {
            advance()
            var text = ""
            while let next = peek(), next != "\"" {
                if next == "\\" {
                    advance()
                    switch advance() {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "r": text.append("\r")
                    case let other?: text.append(other)
                    default: break
                    }
                    continue
                }
                text.append(next)
                advance()
            }
            advance()
            return .text(text, start)
        }
        if character == "#" {
            advance()
            // `#\a` は文字、`#'f` は関数、`#(...)` はベクタ。
            if peek() == "\\" {
                advance()
                var name = ""
                while let next = peek(), !next.isWhitespace, next != ")", next != "(" {
                    name.append(next)
                    advance()
                }
                if name.count == 1 { return .character(name.first ?? " ", start) }
                switch name.lowercased() {
                case "space": return .character(" ", start)
                case "newline": return .character("\n", start)
                case "tab": return .character("\t", start)
                default: return .character(name.first ?? " ", start)
                }
            }
            if peek() == "'" {
                advance()
                return try read()
            }
            if peek() == "(" {
                return try read()
            }
            // `#xFF` などは読み飛ばして数として読む。
            return try read()
        }

        // 数か記号。
        var text = ""
        while let next = peek(), !next.isWhitespace, !"()[]';\"`,".contains(next) {
            text.append(next)
            advance()
        }
        if text.isEmpty {
            advance()
            diagnostics.error("読めない字があります", at: start)
            throw AbortCompilation()
        }
        if let number = Int64(text) { return .integer(number, start) }
        if text.count > 1 || text.first?.isNumber == true,
           let number = Double(text), text.contains(where: { $0.isNumber }) {
            return .real(number, start)
        }
        return .symbol(text.lowercased(), start)
    }
}

/// S 式を共通の中間表現に組み替える。
final class LispCompiler {
    private let diagnostics: DiagnosticBag

    init(diagnostics: DiagnosticBag) {
        self.diagnostics = diagnostics
    }

    func compile(_ forms: [LispForm]) throws -> MLProgram {
        var statements: [MLStmt] = []
        for form in forms {
            statements.append(contentsOf: try statement(form))
        }
        return MLProgram(statements: statements)
    }

    /// 1 つの S 式を文に直す (宣言はそのまま、それ以外は式の文)。
    private func statement(_ form: LispForm) throws -> [MLStmt] {
        if let items = form.items, let head = items.first?.symbolName {
            switch head {
            case "defun":
                return [.funcDecl(try functionDeclaration(items, name: nil))]
            case "defmacro":
                // マクロは関数として扱う (単純な使い方なら動く)。
                return [.funcDecl(try functionDeclaration(items, name: nil))]
            case "defvar", "defparameter", "defconstant":
                guard items.count >= 2, let name = items[1].symbolName else { break }
                let value = items.count > 2 ? try expression(items[2])
                                            : MLExpr.literal(.unit, form.location)
                return [.varDecl(pattern: .binding(name), typeName: nil, value: value,
                                 isConstant: head == "defconstant", form.location)]
            case "progn", "prog1":
                return try items.dropFirst().flatMap { try statement($0) }
            default:
                break
            }
        }
        return [.expression(try expression(form), form.location)]
    }

    private func functionDeclaration(_ items: [LispForm],
                                     name overrideName: String?) throws -> MLFunctionDecl {
        let location = items.first?.location ?? .unknown
        guard items.count >= 3, let name = overrideName ?? items[1].symbolName else {
            diagnostics.error("defun の書き方が違います", at: location)
            throw AbortCompilation()
        }
        let parameters = try parameterList(items[2])
        let body = try items.dropFirst(3).flatMap { try statement($0) }
        return MLFunctionDecl(name: name, parameters: parameters,
                              body: liftedReturn(body), location: location)
    }

    private func parameterList(_ form: LispForm) throws -> [MLParameter] {
        guard let items = form.items else { return [] }
        var parameters: [MLParameter] = []
        var isOptional = false
        for item in items {
            if let name = item.symbolName {
                if name == "&optional" || name == "&key" {
                    isOptional = true
                    continue
                }
                if name == "&rest" || name == "&body" { continue }
                parameters.append(MLParameter(
                    name: name,
                    defaultValue: isOptional ? .literal(.unit, item.location) : nil))
                continue
            }
            // `(x 0)` のように既定値つきで書くこともある。
            if let pair = item.items, let name = pair.first?.symbolName {
                let defaultValue = pair.count > 1 ? try expression(pair[1])
                                                  : MLExpr.literal(.unit, item.location)
                parameters.append(MLParameter(name: name, defaultValue: defaultValue))
            }
        }
        return parameters
    }

    /// 最後の式を戻り値にする。
    private func liftedReturn(_ body: [MLStmt]) -> [MLStmt] {
        guard case .expression(let value, let location)? = body.last else { return body }
        return body.dropLast() + [.returnStmt(value, location)]
    }

    // MARK: 式

    func expression(_ form: LispForm) throws -> MLExpr {
        switch form {
        case .integer(let number, let location):
            return .literal(.int(number), location)
        case .real(let number, let location):
            return .literal(.double(number), location)
        case .text(let text, let location):
            return .literal(.string(text), location)
        case .character(let character, let location):
            return .literal(.char(character), location)
        case .symbol(let name, let location):
            if name == "nil" { return .literal(.unit, location) }
            if name == "t" { return .literal(.bool(true), location) }
            return .name(name, location)
        case .quoted(let inner, let location):
            return try quoted(inner, location: location)
        case .list(let items, let location):
            return try call(items, location: location)
        }
    }

    /// `'(1 2 3)` や `'foo` を値にする。
    private func quoted(_ form: LispForm, location: SourceLocation) throws -> MLExpr {
        switch form {
        case .symbol(let name, let symbolLocation):
            if name == "nil" { return .literal(.unit, symbolLocation) }
            if name == "t" { return .literal(.bool(true), symbolLocation) }
            return .literal(.symbol(name), symbolLocation)
        case .list(let items, let listLocation):
            return .listLiteral(try items.map { try quoted($0, location: listLocation) },
                                spreadIndices: [], listLocation)
        default:
            return try expression(form)
        }
    }

    private func call(_ items: [LispForm], location: SourceLocation) throws -> MLExpr {
        guard let first = items.first else { return .literal(.unit, location) }
        let arguments = Array(items.dropFirst())

        guard let head = first.symbolName else {
            // `((lambda (x) x) 1)` のような形。
            return .call(callee: try expression(first),
                         arguments: try arguments.map { MLArgument(value: try expression($0)) },
                         location)
        }

        switch head {
        case "quote":
            return try quoted(arguments.first ?? .symbol("nil", location), location: location)
        case "if":
            let condition = try expression(arguments[0])
            let then = try expression(arguments[1])
            let otherwise = arguments.count > 2 ? try expression(arguments[2])
                                                : MLExpr.literal(.unit, location)
            return .ifExpr(condition: condition, then: then, otherwise: otherwise, location)
        case "when", "unless":
            var condition = try expression(arguments[0])
            if head == "unless" {
                condition = .unary(op: "!", operand: condition, isPostfix: false, location)
            }
            let body = try arguments.dropFirst().flatMap { try statement($0) }
            return .ifExpr(condition: condition, then: .block(liftedValue(body), location),
                           otherwise: .literal(.unit, location), location)
        case "cond":
            return try condition(arguments, index: 0, location: location)
        case "case":
            return try caseForm(arguments, location: location)
        case "progn", "prog1", "block":
            let body = try arguments.flatMap { try statement($0) }
            return .block(liftedValue(body), location)
        case "let", "let*":
            var body: [MLStmt] = []
            if let bindings = arguments.first?.items {
                for binding in bindings {
                    if let name = binding.symbolName {
                        body.append(.varDecl(pattern: .binding(name), typeName: nil,
                                             value: .literal(.unit, location),
                                             isConstant: false, location))
                        continue
                    }
                    guard let pair = binding.items, let name = pair.first?.symbolName else {
                        continue
                    }
                    let value = pair.count > 1 ? try expression(pair[1])
                                               : MLExpr.literal(.unit, location)
                    body.append(.varDecl(pattern: .binding(name), typeName: nil, value: value,
                                         isConstant: false, location))
                }
            }
            body += try arguments.dropFirst().flatMap { try statement($0) }
            return .block(liftedValue(body), location)
        case "lambda":
            let parameters = try parameterList(arguments[0])
            let body = try arguments.dropFirst().flatMap { try statement($0) }
            return .lambda(MLFunctionDecl(name: "", parameters: parameters,
                                          body: liftedReturn(body), location: location),
                           location)
        case "setq", "setf", "set":
            return try assignment(arguments, location: location)
        case "incf", "decf":
            let target = try expression(arguments[0])
            let step = arguments.count > 1 ? try expression(arguments[1])
                                           : MLExpr.literal(.int(1), location)
            return .assign(op: head == "incf" ? "+=" : "-=", target: target, value: step,
                           location)
        case "push":
            let value = try expression(arguments[0])
            let target = try expression(arguments[1])
            return .call(callee: .name("#push", location),
                         arguments: [MLArgument(value: target), MLArgument(value: value)],
                         location)
        case "and":
            return try chain(arguments, op: "&&", empty: .bool(true), location: location)
        case "or":
            return try chain(arguments, op: "||", empty: .unit, location: location)
        case "not", "null":
            return .call(callee: .name("null", location),
                         arguments: [MLArgument(value: try expression(arguments[0]))],
                         location)
        case "dolist":
            guard let header = arguments.first?.items, let name = header.first?.symbolName
            else { break }
            let sequence = header.count > 1 ? try expression(header[1])
                                            : MLExpr.literal(.unit, location)
            let body = try arguments.dropFirst().flatMap { try statement($0) }
            return .block([.forIn(pattern: .binding(name), sequence: sequence, body: body,
                                  whereClause: nil, label: nil, location)], location)
        case "dotimes":
            guard let header = arguments.first?.items, let name = header.first?.symbolName
            else { break }
            let count = header.count > 1 ? try expression(header[1])
                                         : MLExpr.literal(.int(0), location)
            let sequence = MLExpr.range(lower: .literal(.int(0), location), upper: count,
                                        isClosed: false, step: nil, location)
            let body = try arguments.dropFirst().flatMap { try statement($0) }
            return .block([.forIn(pattern: .binding(name), sequence: sequence, body: body,
                                  whereClause: nil, label: nil, location)], location)
        case "loop":
            return try loopForm(arguments, location: location)
        case "return", "return-from":
            let value = arguments.last.map { try? expression($0) } ?? nil
            return .block([.returnStmt(value ?? .literal(.unit, location), location)],
                          location)
        case "funcall", "apply":
            guard let target = arguments.first else { break }
            var callArguments = try arguments.dropFirst()
                .map { MLArgument(value: try expression($0)) }
            if head == "apply", let last = callArguments.last {
                callArguments.removeLast()
                callArguments.append(MLArgument(value: last.value, isSpread: true))
            }
            return .call(callee: try expression(target), arguments: callArguments, location)
        case "function":
            guard let target = arguments.first else { break }
            return try expression(target)
        case "defun":
            let decl = try functionDeclaration([first] + arguments, name: nil)
            return .block([.funcDecl(decl)], location)
        case "+", "-", "*", "/", "=", "<", ">", "<=", ">=", "/=":
            return try arithmetic(head, arguments, location: location)
        default:
            break
        }

        return .call(callee: .name(head, location),
                     arguments: try arguments.map { MLArgument(value: try expression($0)) },
                     location)
    }

    /// `(cond (c1 e1) (c2 e2) (t e3))`
    private func condition(_ clauses: [LispForm], index: Int,
                           location: SourceLocation) throws -> MLExpr {
        guard index < clauses.count, let clause = clauses[index].items,
              let test = clause.first else {
            return .literal(.unit, location)
        }
        let body = try clause.dropFirst().flatMap { try statement($0) }
        let value = body.isEmpty ? try expression(test) : .block(liftedValue(body), location)
        if test.symbolName == "t" || test.symbolName == "otherwise" { return value }
        return .ifExpr(condition: try expression(test), then: value,
                       otherwise: try condition(clauses, index: index + 1,
                                                location: location),
                       location)
    }

    /// `(case x (1 "one") (t "other"))`
    private func caseForm(_ arguments: [LispForm],
                          location: SourceLocation) throws -> MLExpr {
        guard let subject = arguments.first else { return .literal(.unit, location) }
        var arms: [MLMatchArm] = []
        for clause in arguments.dropFirst() {
            guard let items = clause.items, let key = items.first else { continue }
            let body = try items.dropFirst().flatMap { try statement($0) }
            if key.symbolName == "t" || key.symbolName == "otherwise" {
                arms.append(MLMatchArm(patterns: [], body: liftedValue(body),
                                       isDefault: true))
                continue
            }
            var patterns: [MLPattern] = []
            if let keys = key.items {
                for option in keys { patterns.append(.expression(try quoted(option,
                                                                            location: location))) }
            } else {
                patterns.append(.expression(try quoted(key, location: location)))
            }
            arms.append(MLMatchArm(patterns: patterns, body: liftedValue(body)))
        }
        return .match(subject: try expression(subject), arms: arms, location)
    }

    /// `(loop for i from 1 to 5 do ...)` と `(loop for x in xs do ...)` に対応する。
    private func loopForm(_ arguments: [LispForm],
                          location: SourceLocation) throws -> MLExpr {
        var index = 0
        var variableName: String?
        var sequence: MLExpr?
        var collecting: MLExpr?
        var body: [MLStmt] = []

        while index < arguments.count {
            let word = arguments[index].symbolName
            switch word {
            case "for", "as":
                variableName = arguments[index + 1].symbolName
                index += 2
                if arguments[index].symbolName == "from" {
                    let lower = try expression(arguments[index + 1])
                    index += 2
                    var upper = MLExpr.literal(.int(0), location)
                    var isClosed = true
                    if arguments[index].symbolName == "to" {
                        upper = try expression(arguments[index + 1])
                        index += 2
                    } else if arguments[index].symbolName == "below" {
                        upper = try expression(arguments[index + 1])
                        isClosed = false
                        index += 2
                    }
                    sequence = .range(lower: lower, upper: upper, isClosed: isClosed,
                                      step: nil, location)
                } else if arguments[index].symbolName == "in"
                            || arguments[index].symbolName == "across" {
                    sequence = try expression(arguments[index + 1])
                    index += 2
                }
            case "do":
                index += 1
                while index < arguments.count,
                      !["finally", "collect", "into"].contains(arguments[index].symbolName
                                                                ?? "") {
                    body += try statement(arguments[index])
                    index += 1
                }
            case "collect":
                collecting = try expression(arguments[index + 1])
                index += 2
            default:
                index += 1
            }
        }

        guard let name = variableName, let source = sequence else {
            return .block(body, location)
        }
        if let collecting {
            return .comprehension(MLComprehension(
                element: collecting,
                clauses: [MLComprehension.Clause(pattern: .binding(name),
                                                 sequence: source)],
                filters: []), location)
        }
        return .block([.forIn(pattern: .binding(name), sequence: source, body: body,
                              whereClause: nil, label: nil, location)], location)
    }

    private func assignment(_ arguments: [LispForm],
                            location: SourceLocation) throws -> MLExpr {
        var result: MLExpr = .literal(.unit, location)
        var index = 0
        while index + 1 < arguments.count {
            let target = try expression(arguments[index])
            let value = try expression(arguments[index + 1])
            result = .assign(op: "=", target: target, value: value, location)
            index += 2
        }
        return result
    }

    private func chain(_ arguments: [LispForm], op: String, empty: MLValue,
                       location: SourceLocation) throws -> MLExpr {
        guard let first = arguments.first else { return .literal(empty, location) }
        var result = try expression(first)
        for argument in arguments.dropFirst() {
            result = .binary(op: op, lhs: result, rhs: try expression(argument), location)
        }
        return result
    }

    /// `(+ 1 2 3)` のように引数がいくつでも書ける演算。
    private func arithmetic(_ op: String, _ arguments: [LispForm],
                            location: SourceLocation) throws -> MLExpr {
        let values = try arguments.map { try expression($0) }
        switch op {
        case "=", "<", ">", "<=", ">=", "/=":
            guard values.count >= 2 else { return .literal(.bool(true), location) }
            let mapped = op == "=" ? "==" : (op == "/=" ? "!=" : op)
            var result = MLExpr.binary(op: mapped, lhs: values[0], rhs: values[1], location)
            for index in 1..<(values.count - 1) {
                result = .binary(op: "&&", lhs: result,
                                 rhs: .binary(op: mapped, lhs: values[index],
                                              rhs: values[index + 1], location),
                                 location)
            }
            return result
        case "-" where values.count == 1:
            return .unary(op: "-", operand: values[0], isPostfix: false, location)
        case "/" where values.count == 1:
            return .binary(op: "/", lhs: .literal(.int(1), location), rhs: values[0],
                           location)
        case "+" where values.isEmpty:
            return .literal(.int(0), location)
        case "*" where values.isEmpty:
            return .literal(.int(1), location)
        default:
            var result = values[0]
            for value in values.dropFirst() {
                result = .binary(op: op, lhs: result, rhs: value, location)
            }
            return result
        }
    }

    /// 文の並びの最後が式なら、その値をブロックの値にする。
    private func liftedValue(_ body: [MLStmt]) -> [MLStmt] { body }
}
