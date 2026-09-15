import Foundation

struct SwiftRuntimeFailure: Error {
    var message: String
    var location: SourceLocation
}

public struct SwiftLimits {
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int

    public init(maximumSteps: Int = 5_000_000, maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 400) {
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
    }

    public static let `default` = SwiftLimits()
}

/// 変数のスコープ。
final class SwiftEnvironment {
    private var values: [String: SwiftValue] = [:]
    private var constants: Set<String> = []
    let parent: SwiftEnvironment?
    /// メソッドの中の `self`。
    var selfValue: SwiftValue?
    var typeName: String?

    init(parent: SwiftEnvironment?) {
        self.parent = parent
        self.selfValue = parent?.selfValue
        self.typeName = parent?.typeName
    }

    func define(_ name: String, _ value: SwiftValue, isConstant: Bool) {
        values[name] = value
        if isConstant { constants.insert(name) } else { constants.remove(name) }
    }

    func lookup(_ name: String) -> SwiftValue? {
        values[name] ?? parent?.lookup(name)
    }

    func has(_ name: String) -> Bool {
        values[name] != nil || (parent?.has(name) ?? false)
    }

    @discardableResult
    func assign(_ name: String, _ value: SwiftValue) -> Bool {
        if values[name] != nil {
            values[name] = value
            return true
        }
        return parent?.assign(name, value) ?? false
    }

    func isConstant(_ name: String) -> Bool {
        if values[name] != nil { return constants.contains(name) }
        return parent?.isConstant(name) ?? false
    }
}

/// 構文木をたどって実行する Swift インタプリタ。
public final class SwiftInterpreter {
    private struct BreakSignal: Error {}
    private struct ContinueSignal: Error {}
    private struct ReturnSignal: Error { var value: SwiftValue }

    private var globals: SwiftEnvironment
    private var functions: [String: [SwiftFunctionDeclaration]] = [:]
    private(set) var types: [String: SwiftTypeDeclaration] = [:]
    /// 型ごとの static プロパティ。
    private var staticStorage: [String: [String: SwiftValue]] = [:]
    private var output = Data()
    private var outputOverflowed = false
    private var steps = 0
    private var callDepth = 0
    private let limits: SwiftLimits
    private var inputLines: [String]
    private var inputIndex = 0

    public init(limits: SwiftLimits = .default, input: String = "") {
        self.limits = limits
        self.globals = SwiftEnvironment(parent: nil)
        self.inputLines = input.isEmpty ? [] : input.components(separatedBy: "\n")
    }

    public func run(_ statements: [SwiftStmt]) -> (output: String, error: String?) {
        hoist(statements, in: globals)
        do {
            try execute(statements, in: globals)
            return (outputText, nil)
        } catch let failure as SwiftRuntimeFailure {
            let position = failure.location.line > 0 ? " (\(failure.location.line) 行目)" : ""
            return (outputText, "エラー: \(failure.message)\(position)")
        } catch is ReturnSignal {
            return (outputText, nil)
        } catch {
            return (outputText, "エラー: \(error)")
        }
    }

    private var outputText: String {
        var text = String(decoding: output, as: UTF8.self)
        if outputOverflowed { text += "\n…出力が上限に達したので打ち切りました。" }
        return text
    }

    func write(_ text: String) {
        guard !outputOverflowed else { return }
        let bytes = Data(text.utf8)
        if output.count + bytes.count > limits.maximumOutputBytes {
            output.append(bytes.prefix(max(0, limits.maximumOutputBytes - output.count)))
            outputOverflowed = true
            return
        }
        output.append(bytes)
    }

    func readLine() -> SwiftValue {
        guard inputIndex < inputLines.count else { return .none }
        let line = inputLines[inputIndex]
        inputIndex += 1
        return .string(line)
    }

    private func hoist(_ statements: [SwiftStmt], in environment: SwiftEnvironment) {
        for statement in statements {
            switch statement {
            case .functionDeclaration(let declaration):
                functions[declaration.name, default: []].append(declaration)
            case .typeDeclaration(let declaration):
                types[declaration.name] = declaration
            default:
                break
            }
        }
    }

    private func countStep(at location: SourceLocation) throws {
        steps += 1
        if steps > limits.maximumSteps {
            throw SwiftRuntimeFailure(message: "実行が長すぎます (\(limits.maximumSteps) 手を超えました)。"
                                      + "無限ループかもしれません。", location: location)
        }
    }

    // MARK: - 文

    private func execute(_ statements: [SwiftStmt], in environment: SwiftEnvironment) throws {
        for statement in statements {
            try execute(statement, in: environment)
        }
    }

    private func execute(_ statement: SwiftStmt, in environment: SwiftEnvironment) throws {
        try countStep(at: statement.location)

        switch statement {
        case .expression(let expression, _):
            _ = try evaluate(expression, in: environment)

        case .variableDeclaration(let name, let typeName, let valueExpression, let isConstant, let location):
            var value = try valueExpression.map { try evaluate($0, in: environment) } ?? .none
            if let typeName {
                value = coerce(value, to: typeName, at: location)
            }
            environment.define(name, value, isConstant: isConstant)

        case .ifStmt(let conditions, let body, let elseBody, _):
            let scope = SwiftEnvironment(parent: environment)
            if try evaluateConditions(conditions, in: scope) {
                try execute(body, in: SwiftEnvironment(parent: scope))
            } else if let elseBody {
                try execute(elseBody, in: SwiftEnvironment(parent: environment))
            }

        case .guardStmt(let conditions, let elseBody, _):
            // guard で束縛した変数は、その後も使えるように現在のスコープへ入れる
            if try !evaluateConditions(conditions, in: environment) {
                try execute(elseBody, in: SwiftEnvironment(parent: environment))
            }

        case .whileStmt(let condition, let body, let location):
            while try evaluate(condition, in: environment).asBool {
                try countStep(at: location)
                do {
                    try execute(body, in: SwiftEnvironment(parent: environment))
                } catch is BreakSignal {
                    break
                } catch is ContinueSignal {
                    continue
                }
            }

        case .whileLet(let conditions, let body, let location):
            while true {
                try countStep(at: location)
                let scope = SwiftEnvironment(parent: environment)
                if try !evaluateConditions(conditions, in: scope) { break }
                do {
                    try execute(body, in: SwiftEnvironment(parent: scope))
                } catch is BreakSignal {
                    break
                } catch is ContinueSignal {
                    continue
                }
            }

        case .repeatWhile(let body, let condition, let location):
            repeat {
                try countStep(at: location)
                do {
                    try execute(body, in: SwiftEnvironment(parent: environment))
                } catch is BreakSignal {
                    break
                } catch is ContinueSignal {
                    continue
                }
            } while try evaluate(condition, in: environment).asBool

        case .forIn(let variable, let sequenceExpression, let whereClause, let body, let location):
            let sequence = try evaluate(sequenceExpression, in: environment)
            let names = variable.components(separatedBy: ",")
            for element in sequence.asArray {
                try countStep(at: location)
                let scope = SwiftEnvironment(parent: environment)
                if names.count > 1, case .tuple(let items) = element {
                    for (position, name) in names.enumerated() where name != "_" {
                        scope.define(name, position < items.count ? items[position].value : .none,
                                     isConstant: true)
                    }
                } else if variable != "_" {
                    scope.define(variable, element, isConstant: true)
                }
                if let whereClause, try !evaluate(whereClause, in: scope).asBool { continue }
                do {
                    try execute(body, in: SwiftEnvironment(parent: scope))
                } catch is BreakSignal {
                    break
                } catch is ContinueSignal {
                    continue
                }
            }

        case .switchStmt(let subjectExpression, let cases, let location):
            let subject = try evaluate(subjectExpression, in: environment)
            for switchCase in cases {
                let scope = SwiftEnvironment(parent: environment)
                let matched = switchCase.isDefault ? true : try matches(subject, switchCase, in: scope)
                if matched {
                    if let whereClause = switchCase.whereClause,
                       try !evaluate(whereClause, in: scope).asBool {
                        continue
                    }
                    do {
                        try execute(switchCase.body, in: scope)
                    } catch is BreakSignal {
                        // Swift の switch は自動で抜けるので、break は何もしない
                    }
                    return
                }
            }
            _ = location

        case .breakStmt:
            throw BreakSignal()

        case .continueStmt:
            throw ContinueSignal()

        case .returnStmt(let expression, _):
            throw ReturnSignal(value: try expression.map { try evaluate($0, in: environment) } ?? .none)

        case .functionDeclaration(let declaration):
            if functions[declaration.name]?.contains(where: { $0 === declaration }) != true {
                functions[declaration.name, default: []].append(declaration)
            }

        case .typeDeclaration(let declaration):
            types[declaration.name] = declaration

        case .block(let body, _):
            try execute(body, in: SwiftEnvironment(parent: environment))
        }
    }

    private func evaluateConditions(_ conditions: [SwiftCondition],
                                    in environment: SwiftEnvironment) throws -> Bool {
        for condition in conditions {
            switch condition {
            case .expression(let expression):
                if try !evaluate(expression, in: environment).asBool { return false }
            case .optionalBinding(let name, let valueExpression, let isConstant):
                let value = try evaluate(valueExpression, in: environment)
                if value.isNil { return false }
                environment.define(name, value, isConstant: isConstant)
            }
        }
        return true
    }

    private func matches(_ subject: SwiftValue, _ switchCase: SwiftSwitchCase,
                         in environment: SwiftEnvironment) throws -> Bool {
        for pattern in switchCase.patterns {
            switch pattern {
            case .wildcard:
                return true
            case .binding(let name):
                environment.define(name, subject, isConstant: true)
                return true
            case .enumCase(let caseName, let binding):
                if case .enumeration(_, let actual, let rawValue) = subject, actual == caseName {
                    if let binding { environment.define(binding, rawValue ?? .none, isConstant: true) }
                    return true
                }
            case .expression(let expression):
                let value = try evaluate(expression, in: environment)
                if case .range(let lower, let upper, let isClosed) = value {
                    let number = subject.asInt
                    if isClosed ? (number >= lower && number <= upper) : (number >= lower && number < upper) {
                        return true
                    }
                    continue
                }
                if SwiftOperations.equals(subject, value) { return true }
            }
        }
        return false
    }

    // MARK: - 式

    func evaluate(_ expression: SwiftExpr, in environment: SwiftEnvironment) throws -> SwiftValue {
        try countStep(at: expression.location)

        switch expression {
        case .literal(let value, _):
            return value

        case .interpolation(let parts, _):
            var text = ""
            for part in parts {
                text += try evaluate(part, in: environment).displayText
            }
            return .string(text)

        case .identifier(let name, let location):
            if let value = environment.lookup(name) { return value }
            // メソッドの中では self のプロパティを名前だけで参照できる
            if let selfValue = environment.selfValue {
                switch selfValue {
                case .structure(_, let properties):
                    if let value = properties[name] { return value }
                case .object(let object):
                    if let value = object.properties[name] { return value }
                default:
                    break
                }
                if let typeName = environment.typeName ?? userTypeName(of: selfValue),
                   findMethod(named: name, startingAt: typeName) != nil {
                    return .tuple([(label: "method", value: selfValue), (label: "name", value: .string(name))])
                }
            }
            if types[name] != nil { return .metatype(name) }
            if functions[name] != nil {
                let declaration = functions[name]![0]
                return .closure(SwiftClosure(declaration: declaration, captured: [:]))
            }
            if SwiftBuiltins.isGlobalFunction(name) { return .metatype(name) }
            throw SwiftRuntimeFailure(message: "知らない名前です: \(name)", location: location)

        case .selfExpression(let location):
            guard let value = environment.selfValue else {
                throw SwiftRuntimeFailure(message: "self はメソッドの中でしか使えません。", location: location)
            }
            return value

        case .arrayLiteral(let items, _):
            return .array(try items.map { try evaluate($0, in: environment) })

        case .dictionaryLiteral(let pairs, _):
            var result: [(key: SwiftValue, value: SwiftValue)] = []
            for pair in pairs {
                let key = try evaluate(pair.key, in: environment)
                let value = try evaluate(pair.value, in: environment)
                if let existing = result.firstIndex(where: { SwiftOperations.equals($0.key, key) }) {
                    result[existing].value = value
                } else {
                    result.append((key, value))
                }
            }
            return .dictionary(result)

        case .tupleLiteral(let items, _):
            return .tuple(try items.map { (label: $0.label, value: try evaluate($0.value, in: environment)) })

        case .rangeExpression(let lowerExpression, let upperExpression, let isClosed, _):
            let lower = try evaluate(lowerExpression, in: environment).asInt
            let upper = try evaluate(upperExpression, in: environment).asInt
            return .range(lower: lower, upper: upper, isClosed: isClosed)

        case .unary(let op, let operand, let location):
            let value = try evaluate(operand, in: environment)
            switch op {
            case "!": return .boolean(!value.asBool)
            case "&": return value
            case "-":
                if case .double(let number) = value { return .double(-number) }
                return .integer(-value.asInt)
            default:
                throw SwiftRuntimeFailure(message: "知らない演算子です: \(op)", location: location)
            }

        case .binary(let op, let leftExpression, let rightExpression, let location):
            if op == "&&" {
                return .boolean(try evaluate(leftExpression, in: environment).asBool
                                && (try evaluate(rightExpression, in: environment).asBool))
            }
            if op == "||" {
                return .boolean(try evaluate(leftExpression, in: environment).asBool
                                || (try evaluate(rightExpression, in: environment).asBool))
            }
            if op == "??" {
                let left = try evaluate(leftExpression, in: environment)
                return left.isNil ? try evaluate(rightExpression, in: environment) : left
            }
            let left = try evaluate(leftExpression, in: environment)
            let right = try evaluate(rightExpression, in: environment)
            return try SwiftOperations.binary(op, left, right, location)

        case .ternary(let condition, let then, let otherwise, _):
            return try evaluate(condition, in: environment).asBool
                ? try evaluate(then, in: environment)
                : try evaluate(otherwise, in: environment)

        case .forceUnwrap(let inner, let location):
            let value = try evaluate(inner, in: environment)
            if value.isNil {
                throw SwiftRuntimeFailure(message: "nil を強制アンラップしました。", location: location)
            }
            return value

        case .assign(let op, let target, let valueExpression, let location):
            var value = try evaluate(valueExpression, in: environment)
            if op != "=" {
                let existing = try evaluate(target, in: environment)
                value = try SwiftOperations.binary(String(op.dropLast()), existing, value, location)
            }
            try assign(value, to: target, in: environment)
            return .none

        case .closure(let declaration, _):
            return .closure(SwiftClosure(declaration: declaration, captured: [:],
                                         boundSelf: environment.selfValue, environment: environment))

        case .member(let baseExpression, let name, let isOptional, let location):
            let base = try evaluate(baseExpression, in: environment)
            if isOptional, base.isNil { return .none }
            return try member(name, of: base, at: location, in: environment)

        case .implicitMember(let name, let location):
            // `.caseName` — 文脈の型が分からないので、名前だけで列挙を探す
            for (typeName, declaration) in types where declaration.kind == .enumeration {
                if let enumCase = declaration.enumCases.first(where: { $0.name == name }) {
                    let rawValue = try enumCase.rawValue.map { try evaluate($0, in: globals) }
                    return .enumeration(typeName: typeName, caseName: name, rawValue: rawValue)
                }
            }
            throw SwiftRuntimeFailure(message: "どの型の .\(name) か分かりません。", location: location)

        case .index(let baseExpression, let indexExpression, let location):
            let base = try evaluate(baseExpression, in: environment)
            let index = try evaluate(indexExpression, in: environment)
            return try subscriptValue(base, index, at: location)

        case .typeCheck(let inner, let typeName, _):
            let value = try evaluate(inner, in: environment)
            return .boolean(isInstance(value, of: typeName))

        case .typeCast(let inner, let typeName, let isOptional, let location):
            let value = try evaluate(inner, in: environment)
            if isOptional {
                return isInstance(value, of: typeName) ? value : .none
            }
            return coerce(value, to: typeName, at: location)

        case .call(let calleeExpression, let arguments, let location):
            return try evaluateCall(calleeExpression, arguments, at: location, in: environment)
        }
    }

    // MARK: - 代入

    private func assign(_ value: SwiftValue, to target: SwiftExpr,
                        in environment: SwiftEnvironment) throws {
        switch target {
        case .identifier(let name, let location):
            if environment.has(name) {
                if environment.isConstant(name) {
                    throw SwiftRuntimeFailure(message: "let で宣言した \(name) は変更できません。",
                                              location: location)
                }
                environment.assign(name, value)
                return
            }
            // メソッドの中で self のプロパティに代入する場合
            if let selfValue = environment.selfValue {
                switch selfValue {
                case .structure(let typeName, var properties):
                    if properties[name] != nil {
                        properties[name] = value
                        environment.selfValue = .structure(typeName: typeName, properties: properties)
                        return
                    }
                case .object(let object):
                    if object.properties[name] != nil {
                        object.properties[name] = value
                        return
                    }
                default:
                    break
                }
            }
            environment.define(name, value, isConstant: false)

        case .member(let baseExpression, let name, _, let location):
            let base = try evaluate(baseExpression, in: environment)
            switch base {
            case .object(let object):
                object.properties[name] = value
            case .structure(let typeName, var properties):
                properties[name] = value
                try assign(.structure(typeName: typeName, properties: properties),
                           to: baseExpression, in: environment)
            default:
                throw SwiftRuntimeFailure(message: "プロパティを設定できません (\(base.typeName))。",
                                          location: location)
            }

        case .index(let baseExpression, let indexExpression, let location):
            let base = try evaluate(baseExpression, in: environment)
            let index = try evaluate(indexExpression, in: environment)
            switch base {
            case .array(var values):
                let position = index.asInt
                guard position >= 0, position < values.count else {
                    throw SwiftRuntimeFailure(message: "配列の範囲外です (添字 \(position)、要素数 \(values.count))。",
                                              location: location)
                }
                values[position] = value
                try assign(.array(values), to: baseExpression, in: environment)
            case .dictionary(var pairs):
                if let existing = pairs.firstIndex(where: { SwiftOperations.equals($0.key, index) }) {
                    if value.isNil {
                        pairs.remove(at: existing)
                    } else {
                        pairs[existing].value = value
                    }
                } else if !value.isNil {
                    pairs.append((index, value))
                }
                try assign(.dictionary(pairs), to: baseExpression, in: environment)
            case .object(let object):
                object.properties[index.displayText] = value
            default:
                throw SwiftRuntimeFailure(message: "添字で代入できない型です (\(base.typeName))。",
                                          location: location)
            }

        case .selfExpression:
            environment.selfValue = value

        default:
            throw SwiftRuntimeFailure(message: "この式には代入できません。", location: target.location)
        }
    }

    // MARK: - メンバーと添字

    private func member(_ name: String, of base: SwiftValue, at location: SourceLocation,
                        in environment: SwiftEnvironment) throws -> SwiftValue {
        switch base {
        case .structure(let typeName, let properties):
            if let value = properties[name] { return value }
            if let declaration = types[typeName],
               let property = declaration.properties.first(where: { $0.name == name }),
               let getter = property.getter {
                return try runGetter(getter, selfValue: base, typeName: typeName)
            }
        case .object(let object):
            if let value = object.properties[name] { return value }
            var typeName: String? = object.typeName
            while let currentName = typeName, let declaration = types[currentName] {
                if let property = declaration.properties.first(where: { $0.name == name }),
                   let getter = property.getter {
                    return try runGetter(getter, selfValue: base, typeName: currentName)
                }
                typeName = declaration.parentName
            }
        case .enumeration(let typeName, _, let rawValue):
            if name == "rawValue" { return rawValue ?? .none }
            _ = typeName
        case .metatype(let typeName):
            if let stored = staticStorage[typeName]?[name] { return stored }
            if let declaration = types[typeName] {
                if let enumCase = declaration.enumCases.first(where: { $0.name == name }) {
                    let rawValue = try enumCase.rawValue.map { try evaluate($0, in: globals) }
                    return .enumeration(typeName: typeName, caseName: name, rawValue: rawValue)
                }
                if let property = declaration.properties.first(where: { $0.name == name && $0.isStatic }),
                   let defaultValue = property.defaultValue {
                    let value = try evaluate(defaultValue, in: globals)
                    staticStorage[typeName, default: [:]][name] = value
                    return value
                }
            }
        default:
            break
        }

        // 標準の型のプロパティ (count など)
        if let value = try SwiftBuiltins.property(name, of: base, interpreter: self, location: location) {
            return value
        }
        // メソッドを値として取り出す場合 (map の引数など)
        return .tuple([(label: "method", value: base), (label: "name", value: .string(name))])
    }

    private func runGetter(_ body: [SwiftStmt], selfValue: SwiftValue, typeName: String) throws -> SwiftValue {
        let scope = SwiftEnvironment(parent: globals)
        scope.selfValue = selfValue
        scope.typeName = typeName
        do {
            try execute(body, in: scope)
        } catch let signal as ReturnSignal {
            return signal.value
        }
        return .none
    }

    private func subscriptValue(_ base: SwiftValue, _ index: SwiftValue,
                                at location: SourceLocation) throws -> SwiftValue {
        switch base {
        case .array(let values):
            if case .range(let lower, let upper, let isClosed) = index {
                let end = isClosed ? upper + 1 : upper
                guard lower >= 0, end <= values.count, lower <= end else {
                    throw SwiftRuntimeFailure(message: "配列の範囲外です。", location: location)
                }
                return .array(Array(values[lower..<end]))
            }
            let position = index.asInt
            guard position >= 0, position < values.count else {
                throw SwiftRuntimeFailure(message: "配列の範囲外です (添字 \(position)、要素数 \(values.count))。",
                                          location: location)
            }
            return values[position]
        case .dictionary(let pairs):
            return pairs.first { SwiftOperations.equals($0.key, index) }?.value ?? .none
        case .string(let text):
            let characters = Array(text)
            let position = index.asInt
            guard position >= 0, position < characters.count else {
                throw SwiftRuntimeFailure(message: "文字列の範囲外です。", location: location)
            }
            return .character(characters[position])
        case .structure(_, let properties):
            return properties[index.displayText] ?? .none
        case .object(let object):
            return object.properties[index.displayText] ?? .none
        default:
            throw SwiftRuntimeFailure(message: "添字を使えない型です (\(base.typeName))。", location: location)
        }
    }

    // MARK: - 呼び出し

    private func evaluateCall(_ calleeExpression: SwiftExpr,
                              _ arguments: [(label: String?, value: SwiftExpr)],
                              at location: SourceLocation,
                              in environment: SwiftEnvironment) throws -> SwiftValue {
        // メソッド呼び出し
        if case .member(let baseExpression, let name, let isOptional, _) = calleeExpression {
            // super.method() / super.init(...) は base を評価せずに処理する
            if case .identifier("super", _) = baseExpression {
                guard let selfValue = environment.selfValue, let typeName = environment.typeName,
                      let parentName = types[typeName]?.parentName else {
                    throw SwiftRuntimeFailure(message: "super を使える場所ではありません。", location: location)
                }
                let values = try evaluateArguments(arguments, in: environment)
                if name == "init" {
                    guard let parent = types[parentName], let initializer = parent.initializers.first else {
                        // 親に init が無ければメンバーワイズ初期化と同じ扱い
                        return SwiftValue.none
                    }
                    let updated = try invoke(initializer, arguments: values, selfValue: selfValue,
                                             typeName: parentName, captured: [:], at: location)
                    environment.selfValue = updated
                    return SwiftValue.none
                }
                return try callMethod(named: name, on: selfValue, startingAt: parentName,
                                      arguments: values, at: location)
            }

            let base = try evaluate(baseExpression, in: environment)
            if isOptional, base.isNil { return .none }

            // 型に対する呼び出し (Type.method / Type(...))
            if case .metatype(let typeName) = base {
                let values = try evaluateArguments(arguments, in: environment)
                if let declaration = types[typeName],
                   let method = declaration.methods.first(where: { $0.name == name && $0.isStatic }) {
                    return try invoke(method, arguments: values, selfValue: nil, typeName: typeName,
                                      captured: [:], at: location)
                }
                if let result = try SwiftBuiltins.typeMethod(typeName: typeName, name: name,
                                                             arguments: values, interpreter: self,
                                                             location: location) {
                    return result
                }
            }

            let values = try evaluateArguments(arguments, in: environment)

            // ユーザー定義の型のメソッド
            if let typeName = userTypeName(of: base),
               let found = findMethod(named: name, startingAt: typeName) {
                let result = try invoke(found.method, arguments: values, selfValue: base,
                                        typeName: found.typeName, captured: [:], at: location,
                                        mutatingTarget: found.method.isMutating ? baseExpression : nil,
                                        environment: environment)
                return result
            }

            // 標準の型のメソッド
            if let result = try SwiftBuiltins.method(name: name, on: base, arguments: values,
                                                     interpreter: self, location: location,
                                                     mutate: { [weak self] updated in
                                                         guard let self else { return }
                                                         try self.assign(updated, to: baseExpression,
                                                                         in: environment)
                                                     }) {
                return result
            }

            // プロパティに入っているクロージャ
            let property = try member(name, of: base, at: location, in: environment)
            if case .closure(let closure) = property {
                return try invoke(closure.declaration, arguments: values, selfValue: closure.boundSelf,
                                  typeName: nil, captured: closure.captured, at: location,
                                  parentEnvironment: closure.environment)
            }
            throw SwiftRuntimeFailure(message: "\(base.typeName) に \(name) はありません。", location: location)
        }

        // 名前で呼ぶ
        if case .identifier(let name, _) = calleeExpression {
            // 変数に入っているクロージャを優先
            if let value = environment.lookup(name), case .closure(let closure) = value {
                let values = try evaluateArguments(arguments, in: environment)
                return try invoke(closure.declaration, arguments: values, selfValue: closure.boundSelf,
                                  typeName: nil, captured: closure.captured, at: location,
                                  parentEnvironment: closure.environment)
            }
            // 型の初期化
            if let declaration = types[name] {
                let values = try evaluateArguments(arguments, in: environment)
                return try instantiate(declaration, arguments: values, at: location)
            }
            if let candidates = functions[name] {
                let values = try evaluateArguments(arguments, in: environment)
                let declaration = selectOverload(candidates, arguments: values, labels: arguments.map(\.label))
                // inout 引数は、呼び出し後に元の変数へ書き戻す
                var inoutBindings: [(name: String, target: SwiftExpr)] = []
                for (position, parameter) in declaration.parameters.enumerated()
                where parameter.isInout && position < arguments.count {
                    var target = arguments[position].value
                    if case .unary("&", let inner, _) = target { target = inner }
                    inoutBindings.append((parameter.name, target))
                }
                return try invoke(declaration, arguments: values, selfValue: nil, typeName: nil,
                                  captured: [:], at: location, environment: environment,
                                  inoutBindings: inoutBindings)
            }
            // メソッドの中から、同じ型の別のメソッドを self なしで呼ぶ
            if let selfValue = environment.selfValue,
               let typeName = userTypeName(of: selfValue),
               findMethod(named: name, startingAt: typeName) != nil {
                let values = try evaluateArguments(arguments, in: environment)
                return try callMethod(named: name, on: selfValue, startingAt: typeName,
                                      arguments: values, at: location)
            }
            let values = try evaluateArguments(arguments, in: environment)
            if let result = try SwiftBuiltins.globalFunction(name: name, arguments: values,
                                                             interpreter: self, location: location) {
                return result
            }
            throw SwiftRuntimeFailure(message: "知らない関数です: \(name)", location: location)
        }

        // 式の結果 (クロージャ) を呼ぶ
        let callee = try evaluate(calleeExpression, in: environment)
        let values = try evaluateArguments(arguments, in: environment)
        if case .closure(let closure) = callee {
            return try invoke(closure.declaration, arguments: values, selfValue: closure.boundSelf,
                              typeName: nil, captured: closure.captured, at: location,
                              parentEnvironment: closure.environment)
        }
        if case .metatype(let name) = callee {
            if let declaration = types[name] {
                return try instantiate(declaration, arguments: values, at: location)
            }
            if let result = try SwiftBuiltins.globalFunction(name: name, arguments: values,
                                                             interpreter: self, location: location) {
                return result
            }
        }
        throw SwiftRuntimeFailure(message: "呼び出せない値です (\(callee.typeName))。", location: location)
    }

    private func evaluateArguments(_ arguments: [(label: String?, value: SwiftExpr)],
                                   in environment: SwiftEnvironment) throws
        -> [(label: String?, value: SwiftValue)] {
        try arguments.map { (label: $0.label, value: try evaluate($0.value, in: environment)) }
    }

    private func selectOverload(_ candidates: [SwiftFunctionDeclaration],
                                arguments: [(label: String?, value: SwiftValue)],
                                labels: [String?]) -> SwiftFunctionDeclaration {
        if candidates.count == 1 { return candidates[0] }
        // 引数の数とラベルが合うものを選ぶ
        for candidate in candidates where candidate.parameters.count == arguments.count {
            var matched = true
            for (position, parameter) in candidate.parameters.enumerated()
            where parameter.label != nil && labels[position] != nil && parameter.label != labels[position] {
                matched = false
            }
            if matched { return candidate }
        }
        return candidates[0]
    }

    private func userTypeName(of value: SwiftValue) -> String? {
        switch value {
        case .structure(let name, _): return types[name] != nil ? name : nil
        case .object(let object): return types[object.typeName] != nil ? object.typeName : nil
        case .enumeration(let name, _, _): return types[name] != nil ? name : nil
        default: return nil
        }
    }

    private struct FoundMethod {
        var method: SwiftFunctionDeclaration
        var typeName: String
    }

    private func findMethod(named name: String, startingAt typeName: String) -> FoundMethod? {
        var current: String? = typeName
        while let currentName = current, let declaration = types[currentName] {
            if let method = declaration.methods.first(where: { $0.name == name }) {
                return FoundMethod(method: method, typeName: currentName)
            }
            current = declaration.parentName
        }
        return nil
    }

    func callMethod(named name: String, on value: SwiftValue, startingAt typeName: String,
                    arguments: [(label: String?, value: SwiftValue)],
                    at location: SourceLocation) throws -> SwiftValue {
        guard let found = findMethod(named: name, startingAt: typeName) else {
            throw SwiftRuntimeFailure(message: "\(typeName) に \(name) はありません。", location: location)
        }
        return try invoke(found.method, arguments: arguments, selfValue: value, typeName: found.typeName,
                          captured: [:], at: location)
    }

    /// クロージャを呼ぶ (map などの組み込みから使う)。
    func callClosure(_ value: SwiftValue, arguments: [SwiftValue],
                     at location: SourceLocation) throws -> SwiftValue {
        switch value {
        case .closure(let closure):
            return try invoke(closure.declaration, arguments: arguments.map { (label: nil, value: $0) },
                              selfValue: closure.boundSelf, typeName: nil, captured: closure.captured,
                              at: location, parentEnvironment: closure.environment)
        case .metatype(let name):
            if let candidates = functions[name] {
                return try invoke(candidates[0], arguments: arguments.map { (label: nil, value: $0) },
                                  selfValue: nil, typeName: nil, captured: [:], at: location)
            }
            if let result = try SwiftBuiltins.globalFunction(name: name,
                                                             arguments: arguments.map { (label: nil, value: $0) },
                                                             interpreter: self, location: location) {
                return result
            }
            if let declaration = types[name] {
                return try instantiate(declaration, arguments: arguments.map { (label: nil, value: $0) },
                                       at: location)
            }
            throw SwiftRuntimeFailure(message: "呼び出せません: \(name)", location: location)
        case .tuple(let items):
            // メソッド参照 (値.メソッド名)
            if items.count == 2, items[0].label == "method", case .string(let name)? = items.last?.value {
                let base = items[0].value
                if let typeName = userTypeName(of: base) {
                    return try callMethod(named: name, on: base, startingAt: typeName,
                                          arguments: arguments.map { (label: nil, value: $0) },
                                          at: location)
                }
                if let result = try SwiftBuiltins.method(name: name, on: base,
                                                         arguments: arguments.map { (label: nil, value: $0) },
                                                         interpreter: self, location: location,
                                                         mutate: { _ in }) {
                    return result
                }
            }
            throw SwiftRuntimeFailure(message: "呼び出せない値です。", location: location)
        default:
            throw SwiftRuntimeFailure(message: "呼び出せない値です (\(value.typeName))。", location: location)
        }
    }

    @discardableResult
    private func invoke(_ declaration: SwiftFunctionDeclaration,
                        arguments: [(label: String?, value: SwiftValue)],
                        selfValue: SwiftValue?, typeName: String?,
                        captured: [String: SwiftValue], at location: SourceLocation,
                        mutatingTarget: SwiftExpr? = nil,
                        environment: SwiftEnvironment? = nil,
                        parentEnvironment: SwiftEnvironment? = nil,
                        inoutBindings: [(name: String, target: SwiftExpr)] = []) throws -> SwiftValue {
        guard callDepth < limits.maximumCallDepth else {
            throw SwiftRuntimeFailure(message: "関数の呼び出しが深すぎます (\(limits.maximumCallDepth) 段)。",
                                      location: location)
        }
        callDepth += 1
        defer { callDepth -= 1 }

        let scope = SwiftEnvironment(parent: parentEnvironment ?? globals)
        for (name, value) in captured { scope.define(name, value, isConstant: false) }
        scope.selfValue = selfValue
        scope.typeName = typeName ?? scope.typeName

        // 引数を束縛する
        if declaration.usesShorthandArguments {
            for (position, argument) in arguments.enumerated() {
                scope.define("$\(position)", argument.value, isConstant: true)
            }
            if let first = arguments.first {
                scope.define("$0", first.value, isConstant: true)
            }
        } else {
            var position = 0
            for parameter in declaration.parameters {
                if parameter.isVariadic {
                    let rest = arguments[min(position, arguments.count)...].map(\.value)
                    scope.define(parameter.name, .array(Array(rest)), isConstant: true)
                    position = arguments.count
                    continue
                }
                if position < arguments.count {
                    var value = arguments[position].value
                    if let typeName = parameter.typeName {
                        value = coerce(value, to: typeName, at: location)
                    }
                    scope.define(parameter.name, value, isConstant: false)
                    position += 1
                } else if let defaultValue = parameter.defaultValue {
                    scope.define(parameter.name, try evaluate(defaultValue, in: globals), isConstant: true)
                } else {
                    scope.define(parameter.name, .none, isConstant: true)
                }
            }
        }

        var result = SwiftValue.none
        do {
            try execute(declaration.body, in: scope)
        } catch let signal as ReturnSignal {
            result = signal.value
        }

        // mutating メソッドは、変更した self を呼び出し元に書き戻す
        if let mutatingTarget, let environment, let updated = scope.selfValue {
            try assign(updated, to: mutatingTarget, in: environment)
        }
        // inout 引数を書き戻す
        if let environment {
            for binding in inoutBindings {
                try assign(scope.lookup(binding.name) ?? .none, to: binding.target, in: environment)
            }
        }

        if declaration.isInitializer {
            return scope.selfValue ?? .none
        }
        if let returnTypeName = declaration.returnTypeName {
            result = coerce(result, to: returnTypeName, at: location)
        }
        return result
    }

    /// 構造体・クラスのインスタンスを作る。
    func instantiate(_ declaration: SwiftTypeDeclaration,
                     arguments: [(label: String?, value: SwiftValue)],
                     at location: SourceLocation) throws -> SwiftValue {
        if declaration.kind == .enumeration {
            // Color(rawValue: "red") のような書き方
            if let first = arguments.first, first.label == "rawValue" {
                for enumCase in declaration.enumCases {
                    let rawValue = try enumCase.rawValue.map { try evaluate($0, in: globals) }
                    if let rawValue, SwiftOperations.equals(rawValue, first.value) {
                        return .enumeration(typeName: declaration.name, caseName: enumCase.name,
                                            rawValue: rawValue)
                    }
                }
                return .none
            }
            throw SwiftRuntimeFailure(message: "列挙型はそのままでは作れません。", location: location)
        }

        // 既定値でプロパティを埋める (親クラスの分も)
        var properties = SwiftProperties()
        var chain: [SwiftTypeDeclaration] = []
        var current: SwiftTypeDeclaration? = declaration
        while let type = current {
            chain.insert(type, at: 0)
            current = type.parentName.flatMap { types[$0] }
        }
        for type in chain {
            for property in type.properties where !property.isStatic && property.getter == nil {
                properties[property.name] = try property.defaultValue.map { try evaluate($0, in: globals) }
                    ?? .none
            }
        }

        let instance: SwiftValue = declaration.kind == .classType
            ? .object(SwiftObject(typeName: declaration.name, properties: properties))
            : .structure(typeName: declaration.name, properties: properties)

        // 明示的な init を探す
        var initializer: SwiftFunctionDeclaration?
        var initializerType = declaration.name
        var search: SwiftTypeDeclaration? = declaration
        while let type = search {
            if let found = type.initializers.first(where: { matchesArguments($0, arguments) })
                ?? type.initializers.first {
                initializer = found
                initializerType = type.name
                break
            }
            search = type.parentName.flatMap { types[$0] }
        }

        if let initializer {
            let result = try invoke(initializer, arguments: arguments, selfValue: instance,
                                    typeName: initializerType, captured: [:], at: location)
            return result
        }

        // メンバーワイズ初期化 (構造体)
        if declaration.kind == .structure {
            guard case .structure(let typeName, var storage) = instance else { return instance }
            let settable = chain.flatMap { $0.properties }.filter { !$0.isStatic && $0.getter == nil }
            for (position, argument) in arguments.enumerated() {
                if let label = argument.label {
                    storage[label] = argument.value
                } else if position < settable.count {
                    storage[settable[position].name] = argument.value
                }
            }
            return .structure(typeName: typeName, properties: storage)
        }
        return instance
    }

    private func matchesArguments(_ declaration: SwiftFunctionDeclaration,
                                  _ arguments: [(label: String?, value: SwiftValue)]) -> Bool {
        let required = declaration.parameters.filter { $0.defaultValue == nil }.count
        return arguments.count >= required && arguments.count <= declaration.parameters.count
    }

    // MARK: - 型

    func isInstance(_ value: SwiftValue, of typeName: String) -> Bool {
        let cleaned = typeName.replacingOccurrences(of: "?", with: "")
        switch cleaned {
        case "Int": if case .integer = value { return true }
        case "Double": if case .double = value { return true }
        case "String": if case .string = value { return true }
        case "Bool": if case .boolean = value { return true }
        case "Character": if case .character = value { return true }
        default: break
        }
        var current: String? = value.typeName
        while let name = current {
            if name == cleaned { return true }
            current = types[name]?.parentName
        }
        return false
    }

    /// 型注釈に合わせて値を寄せる (Int → Double など)。
    func coerce(_ value: SwiftValue, to typeName: String, at location: SourceLocation) -> SwiftValue {
        let cleaned = typeName.replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
        switch cleaned {
        case "Double", "Float":
            if case .integer(let number) = value { return .double(Double(number)) }
        case "Int":
            if case .double(let number) = value { return .integer(Int(number)) }
        case "String":
            if case .string = value { return value }
        case "[Double]":
            if case .array(let values) = value {
                return .array(values.map { item in
                    if case .integer(let number) = item { return .double(Double(number)) }
                    return item
                })
            }
        default:
            break
        }
        return value
    }

    var globalEnvironment: SwiftEnvironment { globals }
}
