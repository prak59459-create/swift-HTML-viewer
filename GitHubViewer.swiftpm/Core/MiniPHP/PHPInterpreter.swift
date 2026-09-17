import Foundation

/// PHP の実行時エラー。
struct PHPRuntimeFailure: Error {
    var message: String
    var location: SourceLocation
}

/// 実行の制限。
public struct PHPLimits {
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int

    public init(maximumSteps: Int = 5_000_000,
                maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 512) {
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
    }

    public static let `default` = PHPLimits()
}

/// AST をそのまま実行するインタプリタ。
public final class PHPInterpreter {
    // 制御の流れを表すシグナル
    private struct BreakSignal: Error { var levels: Int }
    private struct ContinueSignal: Error { var levels: Int }
    private struct ReturnSignal: Error { var value: PHPValue }
    private struct ExitSignal: Error { var code: Int32 }

    /// 1 回の関数呼び出し分の変数。
    private final class Frame {
        var variables: [String: PHPValue] = [:]
        var globalNames: Set<String> = []
        var thisObject: PHPObject?
        /// メソッドを定義しているクラス (self:: が指す方)。
        var className: String?
        /// 実際に呼ばれたクラス (static:: が指す方 = 遅延静的束縛)。
        var staticClassName: String?
    }

    private var globals: [String: PHPValue] = [:]
    private var functions: [String: PHPFunctionDeclaration] = [:]
    private var classes: [String: PHPClassDeclaration] = [:]
    private var frames: [Frame] = []
    private var output = Data()
    private var outputOverflowed = false
    private var steps = 0
    private let limits: PHPLimits
    private var input: [Character]
    private var inputPosition = 0
    private(set) var randomState: UInt64 = 0x2545_F491_4F6C_DD1D

    public init(limits: PHPLimits = .default, input: String = "") {
        self.limits = limits
        self.input = Array(input)
    }

    // MARK: - 実行

    public func run(_ statements: [PHPStmt]) -> (output: String, error: String?, exitCode: Int32) {
        // 関数とクラスは先に登録する (定義より前で呼べる)
        hoist(statements)
        do {
            try execute(statements)
            return (outputText, nil, 0)
        } catch let signal as ExitSignal {
            return (outputText, nil, signal.code)
        } catch let signal as ReturnSignal {
            _ = signal
            return (outputText, nil, 0)
        } catch let failure as PHPRuntimeFailure {
            let position = failure.location.line > 0 ? " (\(failure.location.line) 行目)" : ""
            return (outputText, "エラー: \(failure.message)\(position)", 255)
        } catch is BreakSignal {
            return (outputText, "エラー: break がループの外で使われています。", 255)
        } catch is ContinueSignal {
            return (outputText, "エラー: continue がループの外で使われています。", 255)
        } catch {
            return (outputText, "エラー: \(error)", 255)
        }
    }

    private var outputText: String {
        var text = String(decoding: output, as: UTF8.self)
        if outputOverflowed {
            text += "\n…出力が上限に達したので打ち切りました。"
        }
        return text
    }

    private func hoist(_ statements: [PHPStmt]) {
        for statement in statements {
            switch statement {
            case .functionDeclaration(let declaration):
                functions[declaration.name.lowercased()] = declaration
            case .classDeclaration(let declaration):
                classes[declaration.name.lowercased()] = declaration
            case .block(let inner, _):
                hoist(inner)
            default:
                break
            }
        }
    }

    private func execute(_ statements: [PHPStmt]) throws {
        for statement in statements {
            try execute(statement)
        }
    }

    private func countStep(at location: SourceLocation) throws {
        steps += 1
        if steps > limits.maximumSteps {
            throw PHPRuntimeFailure(message: "実行が長すぎます (\(limits.maximumSteps) 手を超えました)。"
                                    + "無限ループかもしれません。", location: location)
        }
    }

    // MARK: - 文

    private func execute(_ statement: PHPStmt) throws {
        try countStep(at: statement.location)

        switch statement {
        case .inlineHTML(let html, _):
            write(html)

        case .echo(let values, _):
            for value in values {
                write(try evaluate(value).asString)
            }

        case .expression(let expression, _):
            _ = try evaluate(expression)

        case .block(let body, _):
            try execute(body)

        case .ifStmt(let branches, let elseBody, _):
            for branch in branches where try evaluate(branch.condition).asBool {
                try execute(branch.body)
                return
            }
            if let elseBody { try execute(elseBody) }

        case .whileStmt(let condition, let body, let location):
            while try evaluate(condition).asBool {
                try countStep(at: location)
                do {
                    try execute(body)
                } catch let signal as BreakSignal {
                    if signal.levels > 1 { throw BreakSignal(levels: signal.levels - 1) }
                    break
                } catch let signal as ContinueSignal {
                    if signal.levels > 1 { throw ContinueSignal(levels: signal.levels - 1) }
                    continue
                }
            }

        case .doWhile(let body, let condition, let location):
            repeat {
                try countStep(at: location)
                do {
                    try execute(body)
                } catch let signal as BreakSignal {
                    if signal.levels > 1 { throw BreakSignal(levels: signal.levels - 1) }
                    break
                } catch let signal as ContinueSignal {
                    if signal.levels > 1 { throw ContinueSignal(levels: signal.levels - 1) }
                    continue
                }
            } while try evaluate(condition).asBool

        case .forStmt(let initial, let condition, let step, let body, let location):
            for expression in initial { _ = try evaluate(expression) }
            while true {
                try countStep(at: location)
                var keepGoing = true
                for expression in condition { keepGoing = try evaluate(expression).asBool }
                if !condition.isEmpty, !keepGoing { break }
                do {
                    try execute(body)
                } catch let signal as BreakSignal {
                    if signal.levels > 1 { throw BreakSignal(levels: signal.levels - 1) }
                    break
                } catch let signal as ContinueSignal {
                    if signal.levels > 1 { throw ContinueSignal(levels: signal.levels - 1) }
                }
                for expression in step { _ = try evaluate(expression) }
            }

        case .foreachStmt(let subject, let keyVariable, let valueVariable, let byReference, let body, let location):
            let collection = try evaluate(subject)
            let array = collection.asArray
            for key in array.keys {
                try countStep(at: location)
                guard let value = array[key] else { continue }
                if let keyVariable { setVariable(keyVariable, key.asValue) }
                setVariable(valueVariable, value)
                do {
                    try execute(body)
                } catch let signal as BreakSignal {
                    if signal.levels > 1 { throw BreakSignal(levels: signal.levels - 1) }
                    break
                } catch let signal as ContinueSignal {
                    if signal.levels > 1 { throw ContinueSignal(levels: signal.levels - 1) }
                    continue
                }
                if byReference {
                    // 参照で回している場合は、書き換えた値を配列に戻す
                    var updated = try evaluate(subject).asArray
                    updated[key] = lookupVariable(valueVariable)
                    try assign(to: subject, value: .array(updated))
                }
            }

        case .switchStmt(let subject, let cases, _):
            let value = try evaluate(subject)
            var matched = false
            do {
                for switchCase in cases {
                    if !matched {
                        if let caseValue = switchCase.value {
                            if try PHPOperations.looseEquals(value, try evaluate(caseValue)) { matched = true }
                        } else {
                            matched = true
                        }
                    }
                    if matched {
                        try execute(switchCase.body)
                    }
                }
            } catch let signal as BreakSignal {
                if signal.levels > 1 { throw BreakSignal(levels: signal.levels - 1) }
            }

        case .breakStmt(let levels, _):
            throw BreakSignal(levels: levels)

        case .continueStmt(let levels, _):
            throw ContinueSignal(levels: levels)

        case .returnStmt(let value, _):
            throw ReturnSignal(value: try value.map { try evaluate($0) } ?? .null)

        case .functionDeclaration(let declaration):
            functions[declaration.name.lowercased()] = declaration

        case .classDeclaration(let declaration):
            classes[declaration.name.lowercased()] = declaration

        case .globalStmt(let names, _):
            guard let frame = frames.last else { return }
            for name in names {
                frame.globalNames.insert(name)
            }

        case .unsetStmt(let targets, _):
            for target in targets {
                try unset(target)
            }
        }
    }

    // MARK: - 変数

    private func lookupVariable(_ name: String) -> PHPValue {
        if let frame = frames.last {
            if frame.globalNames.contains(name) { return globals[name] ?? .null }
            return frame.variables[name] ?? .null
        }
        return globals[name] ?? .null
    }

    private func variableExists(_ name: String) -> Bool {
        if let frame = frames.last {
            if frame.globalNames.contains(name) { return globals[name] != nil }
            return frame.variables[name] != nil
        }
        return globals[name] != nil
    }

    func setVariable(_ name: String, _ value: PHPValue) {
        if let frame = frames.last {
            if frame.globalNames.contains(name) {
                globals[name] = value
            } else {
                frame.variables[name] = value
            }
            return
        }
        globals[name] = value
    }

    private func removeVariable(_ name: String) {
        if let frame = frames.last, !frame.globalNames.contains(name) {
            frame.variables.removeValue(forKey: name)
            return
        }
        globals.removeValue(forKey: name)
    }

    // MARK: - 出力と入力

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

    /// 標準入力から 1 行読む (fgets(STDIN) 相当)。
    func readLine() -> PHPValue {
        guard inputPosition < input.count else { return .boolean(false) }
        var text = ""
        while inputPosition < input.count {
            let character = input[inputPosition]
            inputPosition += 1
            text.append(character)
            if character == "\n" { break }
        }
        return .text(text)
    }

    func nextRandom(_ lower: Int64, _ upper: Int64) -> Int64 {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let span = upper >= lower ? UInt64(upper - lower) + 1 : 1
        return lower + Int64((randomState >> 33) % span)
    }

    // MARK: - 式

    func evaluate(_ expression: PHPExpr) throws -> PHPValue {
        try countStep(at: expression.location)

        switch expression {
        case .literal(let value, _):
            return value

        case .interpolated(let parts, _):
            var text = ""
            for part in parts { text += try evaluate(part).asString }
            return .text(text)

        case .variable(let name, _):
            return lookupVariable(name)

        case .thisReference(let location):
            guard let object = frames.last?.thisObject else {
                throw PHPRuntimeFailure(message: "$this はメソッドの中でしか使えません。", location: location)
            }
            return .object(object)

        case .arrayLiteral(let items, _):
            var array = PHPArray()
            for item in items {
                let value = try evaluate(item.value)
                if let keyExpression = item.key {
                    array[try evaluate(keyExpression).asKey] = value
                } else {
                    array.append(value)
                }
            }
            return .array(array)

        case .index(let base, let indexExpression, let location):
            let container = try evaluate(base)
            guard let indexExpression else {
                throw PHPRuntimeFailure(message: "[] は代入のときだけ使えます。", location: location)
            }
            let key = try evaluate(indexExpression).asKey
            switch container {
            case .array(let array):
                return array[key] ?? .null
            case .text(let text):
                let characters = Array(text)
                let position = Int(key.asValue.asInt)
                guard position >= 0, position < characters.count else { return .text("") }
                return .text(String(characters[position]))
            case .object(let object):
                return object.properties[key] ?? .null
            default:
                return .null
            }

        case .property(let base, let name, _):
            let value = try evaluate(base)
            if case .object(let object) = value {
                return object.properties[.text(name)] ?? .null
            }
            return .null

        case .unary(let op, let operand, let location):
            let value = try evaluate(operand)
            switch op {
            case "!": return .boolean(!value.asBool)
            case "-":
                if case .integer(let number) = value { return .integer(0 &- number) }
                if case .number(let number) = value { return .number(-number) }
                let numeric = PHPValue.numericPrefix(value.asString)
                if case .integer(let number) = numeric { return .integer(0 &- number) }
                return .number(-numeric.asDouble)
            case "+": return value.isNumericValue ? PHPValue.numericPrefix(value.asString) : .integer(value.asInt)
            case "~": return .integer(~value.asInt)
            default:
                throw PHPRuntimeFailure(message: "知らない演算子です: \(op)", location: location)
            }

        case .binary(let op, let left, let right, let location):
            if op == "&&" {
                return .boolean(try evaluate(left).asBool && (try evaluate(right).asBool))
            }
            if op == "||" {
                return .boolean(try evaluate(left).asBool || (try evaluate(right).asBool))
            }
            if op == "instanceof" {
                let value = try evaluate(left)
                var className = ""
                if case .constant(let name, _) = right {
                    className = name
                } else {
                    let rightValue = try evaluate(right)
                    if case .object(let object) = rightValue { className = object.className }
                    else { className = rightValue.asString }
                }
                guard case .object(let object) = value else { return .boolean(false) }
                return .boolean(isInstance(object, of: className))
            }
            if op == "??" {
                let value = try evaluateQuietly(left)
                if case .null = value { return try evaluate(right) }
                return value
            }
            return try PHPOperations.binary(op, try evaluate(left), try evaluate(right), location)

        case .assign(let op, let target, let valueExpression, let location):
            var value = try evaluate(valueExpression)
            if op != "=" {
                let existing = try evaluateQuietly(target)
                if op == "??=" {
                    if case .null = existing {} else { return existing }
                } else {
                    let binaryOperator = String(op.dropLast())
                    value = try PHPOperations.binary(binaryOperator, existing, value, location)
                }
            }
            try assign(to: target, value: value)
            return value

        case .increment(let target, let isIncrement, let isPrefix, let location):
            let old = try evaluateQuietly(target)
            let delta: PHPValue = .integer(isIncrement ? 1 : -1)
            let updated: PHPValue
            if case .null = old, isIncrement {
                updated = .integer(1)
            } else {
                updated = try PHPOperations.binary("+", old, delta, location)
            }
            try assign(to: target, value: updated)
            return isPrefix ? updated : old

        case .ternary(let condition, let then, let otherwise, _):
            let value = try evaluate(condition)
            if let then {
                return value.asBool ? try evaluate(then) : try evaluate(otherwise)
            }
            return value.asBool ? value : try evaluate(otherwise)

        case .cast(let type, let operand, _):
            let value = try evaluate(operand)
            switch type {
            case "int", "integer": return .integer(value.asInt)
            case "float", "double": return .number(value.asDouble)
            case "string": return .text(value.asString)
            case "bool", "boolean": return .boolean(value.asBool)
            case "array": return .array(value.asArray)
            default: return value
            }

        case .issetCheck(let targets, _):
            for target in targets {
                let value = try evaluateQuietly(target)
                if case .null = value { return .boolean(false) }
            }
            return .boolean(true)

        case .emptyCheck(let target, _):
            return .boolean(!(try evaluateQuietly(target).asBool))

        case .constant(let name, let location):
            switch name.uppercased() {
            case "PHP_EOL": return .text("\n")
            case "PHP_INT_MAX": return .integer(Int64.max)
            case "PHP_INT_MIN": return .integer(Int64.min)
            case "PHP_INT_SIZE": return .integer(8)
            case "PHP_FLOAT_EPSILON": return .number(.ulpOfOne)
            case "M_PI": return .number(Double.pi)
            case "M_E": return .number(M_E)
            case "NAN": return .number(.nan)
            case "INF": return .number(.infinity)
            case "STDIN", "STDOUT", "STDERR": return .text(name.uppercased())
            case "SORT_STRING", "SORT_REGULAR", "SORT_NUMERIC", "SORT_FLAG_CASE": return .integer(0)
            case "STR_PAD_RIGHT": return .integer(1)
            case "STR_PAD_LEFT": return .integer(0)
            case "STR_PAD_BOTH": return .integer(2)
            case "ARRAY_FILTER_USE_KEY": return .integer(2)
            case "ARRAY_FILTER_USE_BOTH": return .integer(1)
            case "JSON_UNESCAPED_SLASHES": return .integer(64)
            case "JSON_UNESCAPED_UNICODE": return .integer(256)
            case "JSON_THROW_ON_ERROR": return .integer(4194304)
            case "E_ALL": return .integer(32767)
            case "E_USER_WARNING": return .integer(512)
            case "PHP_FLOAT_MAX": return .number(.greatestFiniteMagnitude)
            case "PHP_FLOAT_MIN": return .number(.leastNormalMagnitude)
            case "PHP_FLOAT_DIG": return .integer(15)
            case "PHP_VERSION": return .text("8.4.0")
            case "PHP_OS", "PHP_OS_FAMILY": return .text("Linux")
            case "M_SQRT2": return .number(2.0.squareRoot())
            case "MAX_INT": return .integer(Int64.max)
            case "COUNT_RECURSIVE": return .integer(1)
            case "JSON_PRETTY_PRINT": return .integer(128)
            default:
                // 定数が無ければ、PHP 8 未満のように名前そのものを返さずエラーにする
                throw PHPRuntimeFailure(message: "定数 \(name) は定義されていません。", location: location)
            }

        case .closure(let declaration, let captured, _):
            var captures: [String: PHPValue] = [:]
            for name in captured { captures[name] = lookupVariable(name) }
            // アロー関数 (fn) は外側の変数をそのまま見られるようにする
            if captured.isEmpty, declaration.name == "{closure}" {
                if let frame = frames.last {
                    captures = frame.variables
                } else {
                    captures = globals
                }
            }
            return .closure(PHPClosure(declaration: declaration, captured: captures,
                                       boundObject: frames.last?.thisObject))

        case .call(let name, let arguments, let location):
            return try callFunction(named: name, arguments: arguments, location: location)

        case .callValue(let calleeExpression, let arguments, let location):
            let callee = try evaluate(calleeExpression)
            let values = try arguments.map { try evaluate($0) }
            return try call(value: callee, arguments: values, location: location)

        case .methodCall(let objectExpression, let name, let arguments, let location):
            let target = try evaluate(objectExpression)
            let values = try arguments.map { try evaluate($0) }
            guard case .object(let object) = target else {
                if case .closure(let closure) = target, name.lowercased() == "call" {
                    return try invoke(closure: closure, arguments: values, location: location)
                }
                throw PHPRuntimeFailure(message: "オブジェクトではないものに -> を使いました。", location: location)
            }
            return try callMethod(on: object, named: name, arguments: values, location: location)

        case .newObject(let className, let arguments, let location):
            let values = try arguments.map { try evaluate($0) }
            return try instantiate(className: className, arguments: values, location: location)

        case .staticCall(let className, let methodName, let arguments, let location):
            let values = try arguments.map { try evaluate($0) }
            var resolved = className.lowercased()
            if resolved == "parent" {
                guard let currentClass = frames.last?.className,
                      let parent = classes[currentClass.lowercased()]?.parentName else {
                    throw PHPRuntimeFailure(message: "parent:: を使える場所ではありません。", location: location)
                }
                resolved = parent.lowercased()
            } else if resolved == "self" {
                resolved = (frames.last?.className ?? "").lowercased()
            } else if resolved == "static" {
                resolved = (frames.last?.staticClassName ?? frames.last?.className ?? "").lowercased()
            }
            guard let declaration = classes[resolved] else {
                throw PHPRuntimeFailure(message: "知らないクラスです: \(className)", location: location)
            }
            guard let method = findMethod(named: methodName, startingAt: declaration) else {
                throw PHPRuntimeFailure(message: "\(className) にメソッド \(methodName) がありません。",
                                        location: location)
            }
            return try invoke(function: method.function, arguments: values,
                              thisObject: frames.last?.thisObject, className: method.className,
                              captured: [:], location: location,
                              staticClassName: frames.last?.staticClassName ?? declaration.name)

        case .classConstant(let className, let constantName, let location):
            var resolved = className.lowercased()
            if resolved == "self" { resolved = (frames.last?.className ?? "").lowercased() }
            if resolved == "static" {
                resolved = (frames.last?.staticClassName ?? frames.last?.className ?? "").lowercased()
            }
            if resolved == "parent" {
                resolved = (frames.last?.className.flatMap { classes[$0.lowercased()]?.parentName } ?? "")
                    .lowercased()
            }
            guard let declaration = classes[resolved] else {
                throw PHPRuntimeFailure(message: "知らないクラスです: \(className)", location: location)
            }
            var currentClass: PHPClassDeclaration? = declaration
            while let cls = currentClass {
                if let constant = cls.constants.first(where: { $0.name == constantName }) {
                    return try evaluate(constant.value)
                }
                currentClass = cls.parentName.flatMap { classes[$0.lowercased()] }
            }
            throw PHPRuntimeFailure(message: "\(className)::\(constantName) は定義されていません。",
                                    location: location)
        }
    }

    /// isset や ??= で使う、未定義でもエラーにしない評価。
    private func evaluateQuietly(_ expression: PHPExpr) throws -> PHPValue {
        switch expression {
        case .variable(let name, _):
            return variableExists(name) ? lookupVariable(name) : .null
        case .index(let base, let indexExpression, _):
            let container = try evaluateQuietly(base)
            guard let indexExpression else { return .null }
            let key = try evaluate(indexExpression).asKey
            if case .array(let array) = container { return array[key] ?? .null }
            if case .text(let text) = container {
                let characters = Array(text)
                let position = Int(key.asValue.asInt)
                return position >= 0 && position < characters.count ? .text(String(characters[position])) : .null
            }
            return .null
        case .property(let base, let name, _):
            let value = try evaluateQuietly(base)
            if case .object(let object) = value { return object.properties[.text(name)] ?? .null }
            return .null
        case .constant:
            return (try? evaluate(expression)) ?? .null
        default:
            return try evaluate(expression)
        }
    }

    // MARK: - 代入

    func assign(to target: PHPExpr, value: PHPValue) throws {
        switch target {
        case .variable(let name, _):
            setVariable(name, value)

        case .index(let base, let indexExpression, _):
            var array = try evaluateQuietly(base).asArray
            if let indexExpression {
                array[try evaluate(indexExpression).asKey] = value
            } else {
                array.append(value)
            }
            try assign(to: base, value: .array(array))

        case .property(let base, let name, let location):
            let container = try evaluate(base)
            guard case .object(let object) = container else {
                throw PHPRuntimeFailure(message: "オブジェクトではないものにプロパティを設定しています。",
                                        location: location)
            }
            object.properties[.text(name)] = value

        case .thisReference(let location):
            throw PHPRuntimeFailure(message: "$this には代入できません。", location: location)

        default:
            throw PHPRuntimeFailure(message: "この式には代入できません。", location: target.location)
        }
    }

    private func unset(_ target: PHPExpr) throws {
        switch target {
        case .variable(let name, _):
            removeVariable(name)
        case .index(let base, let indexExpression, _):
            guard let indexExpression else { return }
            var array = try evaluateQuietly(base).asArray
            array.removeValue(forKey: try evaluate(indexExpression).asKey)
            try assign(to: base, value: .array(array))
        case .property(let base, let name, _):
            if case .object(let object) = try evaluate(base) {
                object.properties.removeValue(forKey: .text(name))
            }
        default:
            break
        }
    }

    // MARK: - 呼び出し

    private func callFunction(named name: String, arguments: [PHPExpr],
                              location: SourceLocation) throws -> PHPValue {
        let lowered = name.lowercased()

        // ユーザー定義関数
        if let declaration = functions[lowered] {
            var values: [PHPValue] = []
            for (position, argument) in arguments.enumerated() {
                // 参照渡しの引数は、呼び出し後に書き戻す
                _ = position
                values.append(try evaluate(argument))
            }
            let result = try invoke(function: declaration, arguments: values, thisObject: nil,
                                    className: nil, captured: [:], location: location)
            try writeBackReferences(declaration: declaration, arguments: arguments, location: location)
            return result
        }

        // 変数に入ったクロージャ
        if variableExists(name), case .closure = lookupVariable(name) {
            let values = try arguments.map { try evaluate($0) }
            return try call(value: lookupVariable(name), arguments: values, location: location)
        }

        // 組み込み関数 (一部は引数の式そのものが必要)
        if let result = try PHPBuiltins.callSpecial(name: lowered, arguments: arguments,
                                                    interpreter: self, location: location) {
            return result
        }
        let values = try arguments.map { try evaluate($0) }
        if let result = try PHPBuiltins.call(name: lowered, arguments: values,
                                             interpreter: self, location: location) {
            return result
        }
        throw PHPRuntimeFailure(message: "知らない関数です: \(name)()", location: location)
    }

    /// 参照渡し (&$x) の引数を呼び出し後に書き戻す。
    private func writeBackReferences(declaration: PHPFunctionDeclaration, arguments: [PHPExpr],
                                     location: SourceLocation) throws {
        for (position, parameter) in declaration.parameters.enumerated()
        where parameter.byReference && position < arguments.count {
            if let updated = lastCallReferenceValues[parameter.name] {
                try assign(to: arguments[position], value: updated)
            }
        }
        lastCallReferenceValues.removeAll()
    }

    private var lastCallReferenceValues: [String: PHPValue] = [:]

    func call(value: PHPValue, arguments: [PHPValue], location: SourceLocation) throws -> PHPValue {
        switch value {
        case .closure(let closure):
            return try invoke(closure: closure, arguments: arguments, location: location)
        case .text(let name):
            if let declaration = functions[name.lowercased()] {
                return try invoke(function: declaration, arguments: arguments, thisObject: nil,
                                  className: nil, captured: [:], location: location)
            }
            if let result = try PHPBuiltins.call(name: name.lowercased(), arguments: arguments,
                                                 interpreter: self, location: location) {
                return result
            }
            throw PHPRuntimeFailure(message: "知らない関数です: \(name)()", location: location)
        case .array(let array):
            // [$object, 'method'] 形式
            if array.count == 2, case .object(let object)? = array[.integer(0)],
               let methodName = array[.integer(1)]?.asString {
                return try callMethod(on: object, named: methodName, arguments: arguments, location: location)
            }
            throw PHPRuntimeFailure(message: "呼び出せない値です。", location: location)
        default:
            throw PHPRuntimeFailure(message: "呼び出せない値です (\(value.typeName))。", location: location)
        }
    }

    func invoke(closure: PHPClosure, arguments: [PHPValue], location: SourceLocation) throws -> PHPValue {
        try invoke(function: closure.declaration, arguments: arguments, thisObject: closure.boundObject,
                   className: nil, captured: closure.captured, location: location)
    }

    private func invoke(function: PHPFunctionDeclaration, arguments: [PHPValue],
                        thisObject: PHPObject?, className: String?,
                        captured: [String: PHPValue], location: SourceLocation,
                        staticClassName: String? = nil) throws -> PHPValue {
        guard frames.count < limits.maximumCallDepth else {
            throw PHPRuntimeFailure(message: "関数の呼び出しが深すぎます (\(limits.maximumCallDepth) 段)。",
                                    location: location)
        }

        let frame = Frame()
        frame.thisObject = thisObject
        frame.className = className
        frame.staticClassName = staticClassName ?? thisObject?.className ?? className
        for (name, value) in captured { frame.variables[name] = value }

        for (position, parameter) in function.parameters.enumerated() {
            if parameter.isVariadic {
                var rest = PHPArray()
                if position < arguments.count {
                    for value in arguments[position...] { rest.append(value) }
                }
                frame.variables[parameter.name] = .array(rest)
                break
            }
            if position < arguments.count {
                frame.variables[parameter.name] = arguments[position]
            } else if let defaultValue = parameter.defaultValue {
                frame.variables[parameter.name] = try evaluate(defaultValue)
            } else {
                frame.variables[parameter.name] = .null
            }
        }

        frames.append(frame)
        defer {
            // 参照渡しの引数は、呼び出し元が書き戻せるように残しておく
            lastCallReferenceValues = [:]
            for parameter in function.parameters where parameter.byReference {
                lastCallReferenceValues[parameter.name] = frame.variables[parameter.name] ?? .null
            }
            frames.removeLast()
        }

        do {
            try execute(function.body)
        } catch let signal as ReturnSignal {
            return signal.value
        }
        return .null
    }

    // MARK: - クラス

    private struct FoundMethod {
        var function: PHPFunctionDeclaration
        var className: String
    }

    private func findMethod(named name: String, startingAt declaration: PHPClassDeclaration) -> FoundMethod? {
        var current: PHPClassDeclaration? = declaration
        while let cls = current {
            if let method = cls.methods[name.lowercased()] {
                return FoundMethod(function: method, className: cls.name)
            }
            current = cls.parentName.flatMap { classes[$0.lowercased()] }
        }
        return nil
    }

    func callMethod(on object: PHPObject, named name: String, arguments: [PHPValue],
                    location: SourceLocation) throws -> PHPValue {
        guard let declaration = classes[object.className.lowercased()] else {
            throw PHPRuntimeFailure(message: "知らないクラスです: \(object.className)", location: location)
        }
        guard let method = findMethod(named: name, startingAt: declaration) else {
            // プロパティに入ったクロージャも呼べるようにする
            if case .closure(let closure)? = object.properties[.text(name)] {
                return try invoke(closure: closure, arguments: arguments, location: location)
            }
            throw PHPRuntimeFailure(message: "\(object.className) にメソッド \(name) がありません。",
                                    location: location)
        }
        return try invoke(function: method.function, arguments: arguments, thisObject: object,
                          className: method.className, captured: [:], location: location,
                          staticClassName: object.className)
    }

    func instantiate(className: String, arguments: [PHPValue], location: SourceLocation) throws -> PHPValue {
        guard let declaration = classes[className.lowercased()] else {
            throw PHPRuntimeFailure(message: "知らないクラスです: \(className)", location: location)
        }
        let object = PHPObject(className: declaration.name)

        // 親から順にプロパティの既定値を入れる
        var chain: [PHPClassDeclaration] = []
        var current: PHPClassDeclaration? = declaration
        while let cls = current {
            chain.insert(cls, at: 0)
            current = cls.parentName.flatMap { classes[$0.lowercased()] }
        }
        for cls in chain {
            for property in cls.properties {
                object.properties[.text(property.name)] = try property.defaultValue.map { try evaluate($0) } ?? .null
            }
        }

        if let constructor = findMethod(named: "__construct", startingAt: declaration) {
            _ = try invoke(function: constructor.function, arguments: arguments, thisObject: object,
                           className: constructor.className, captured: [:], location: location,
                           staticClassName: object.className)
        }
        return .object(object)
    }

    /// オブジェクトが指定したクラス (または親クラス) のものか。
    func isInstance(_ object: PHPObject, of className: String) -> Bool {
        var current: PHPClassDeclaration? = classes[object.className.lowercased()]
        while let cls = current {
            if cls.name.lowercased() == className.lowercased() { return true }
            current = cls.parentName.flatMap { classes[$0.lowercased()] }
        }
        return false
    }

    /// クラスが定義されているか (class_exists 用)。
    func hasClass(_ name: String) -> Bool { classes[name.lowercased()] != nil }

    /// 関数が定義されているか (function_exists 用)。
    func hasFunction(_ name: String) -> Bool {
        functions[name.lowercased()] != nil || PHPBuiltins.names.contains(name.lowercased())
    }

    /// オブジェクトのメソッド有無 (method_exists 用)。
    func hasMethod(_ object: PHPObject, _ name: String) -> Bool {
        guard let declaration = classes[object.className.lowercased()] else { return false }
        return findMethod(named: name, startingAt: declaration) != nil
    }

    func throwFailure(_ message: String, at location: SourceLocation) -> PHPRuntimeFailure {
        PHPRuntimeFailure(message: message, location: location)
    }

    /// 組み込み関数から評価が必要なとき用。
    func evaluateExpression(_ expression: PHPExpr) throws -> PHPValue {
        try evaluate(expression)
    }

    func assignTo(_ expression: PHPExpr, _ value: PHPValue) throws {
        try assign(to: expression, value: value)
    }
}
