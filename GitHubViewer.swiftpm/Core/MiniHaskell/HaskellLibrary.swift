import Foundation

/// Haskell らしい振る舞い。
final class HaskellSemantics: MLSemantics {
    override var languageID: String { "haskell" }
    override var displayName: String { "内蔵 Haskell 処理系" }
    override var requiresDefinitionBeforeUse: Bool { true }
    override var assignmentDefinesNewVariables: Bool { true }
    /// 整数の割り算は負の無限大方向に丸める (`div`)。
    override var integerDivisionTruncatesTowardZero: Bool { false }
    /// `/` は常に小数。整数どうしは `div`。
    override var divisionAlwaysProducesDouble: Bool { true }
    /// 引数が足りなければ部分適用になる。
    override var curriesByDefault: Bool { true }
    /// 構成子は型名なしで書ける。
    override var exposesEnumCasesGlobally: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool: return "Bool"
        case .int: return "Int"
        case .double: return "Double"
        case .string: return "String"
        case .char: return "Char"
        case .array: return "[a]"
        case .tuple: return "tuple"
        case .map: return "Map"
        case .function: return "function"
        case .object(let object): return object.typeName
        default: return "a"
        }
    }

    /// `putStrLn` はそのまま、`show` は引用符つき。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool(let flag): return flag ? "True" : "False"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { inspect($0) }.joined(separator: ",") + "]"
        case .tuple(let items):
            return "(" + items.map { inspect($0) }.joined(separator: ",") + ")"
        case .map(let map):
            return "fromList [" + map.pairs.map { "(\(inspect($0.key.asValue)),\(inspect($0.value)))" }
                .joined(separator: ",") + "]"
        case .object(let object):
            guard let caseName = object.caseName else { return object.typeName }
            if object.payload.isEmpty { return caseName }
            return caseName + " " + object.payload.map { inspect($0) }
                .joined(separator: " ")
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "'\(character)'"
        case .object(let object) where object.payload.count > 0:
            return "(" + display(value) + ")"
        default: return display(value)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value)) + ".0"
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "++":
            if let left = lhs.asString, let right = rhs.asString {
                return .string(left + right)
            }
            var elements = lhs.asArray?.elements ?? [lhs.forced]
            elements += rhs.asArray?.elements ?? [rhs.forced]
            return .array(MLArray(elements))
        case ":":
            if let text = rhs.asString, case .char(let character) = lhs.forced {
                return .string(String(character) + text)
            }
            var elements = [lhs.forced]
            elements += rhs.asArray?.elements ?? []
            return .array(MLArray(elements))
        case "/=":
            return .bool(!MLOperations.strictEquals(lhs, rhs, semantics: self))
        case "!!":
            let elements = lhs.asArray?.elements ?? []
            let index = Int(rhs.asInt ?? 0)
            guard index >= 0, index < elements.count else {
                throw MLError.runtime("Prelude.!!: index too large")
            }
            return elements[index]
        case "$":
            // `f $ x` は `f x`。
            guard let function = lhs.asFunction else { return nil }
            return try interpreter.callFunction(function, arguments: [rhs],
                                                location: .unknown)
        case ".":
            // 関数合成。
            guard let outer = lhs.asFunction, let inner = rhs.asFunction else { return nil }
            return .function(.native("composed", 1...1) { context in
                let middle = try context.interpreter.callFunction(
                    inner, arguments: context.arguments, location: context.location)
                return try context.interpreter.callFunction(
                    outer, arguments: [middle], location: context.location)
            })
        case "^":
            let base = lhs.asDouble ?? Double(lhs.asInt ?? 0)
            let power = rhs.asDouble ?? Double(rhs.asInt ?? 0)
            let result = Foundation.pow(base, power)
            if lhs.asInt != nil, rhs.asInt != nil, result == result.rounded() {
                return .int(Int64(result))
            }
            return .double(result)
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        HaskellLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }
}

/// Haskell の Prelude (よく使うところ)。
enum HaskellLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func items(_ value: MLValue) -> [MLValue] {
        if let array = value.asArray { return array.elements }
        if let text = value.asString { return text.map { .char($0) } }
        if case .range(let range) = value.forced {
            var elements: [MLValue] = []
            var current = range.lower
            while range.isClosed ? current <= range.upper : current < range.upper {
                elements.append(.int(current))
                current += 1
            }
            return elements
        }
        if value.isUnit { return [] }
        return [value.forced]
    }

    static func install(into environment: MLEnvironment, semantics: HaskellSemantics,
                        interpreter: MLInterpreter) {
        environment.define("putStrLn", function("putStrLn", 1) { context in
            context.interpreter.write(semantics.display(context.argument(0)) + "\n")
            return .unit
        })
        environment.define("putStr", function("putStr", 1) { context in
            context.interpreter.write(semantics.display(context.argument(0)))
            return .unit
        })
        environment.define("print", function("print", 1) { context in
            context.interpreter.write(semantics.inspect(context.argument(0)) + "\n")
            return .unit
        })
        environment.define("getLine", function("getLine", 0...1) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })
        environment.define("show", function("show", 1) { context in
            .string(semantics.inspect(context.argument(0)))
        })
        environment.define("read", function("read", 1) { context in
            let text = semantics.display(context.argument(0))
            if let number = Int64(text) { return .int(number) }
            if let number = Double(text) { return .double(number) }
            return .string(text)
        })
        environment.define("error", function("error", 1) { context in
            throw MLError.thrown(.string(semantics.display(context.argument(0))))
        })
        environment.define("otherwise", .bool(true))
        environment.define("id", function("id", 1) { context in context.argument(0) })

        // リスト。
        environment.define("map", function("map", 2) { context in
            let body = try context.requireFunction(0, "map")
            var result: [MLValue] = []
            for element in items(context.argument(1)) {
                result.append(try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location))
            }
            return .array(MLArray(result))
        })
        environment.define("filter", function("filter", 2) { context in
            let body = try context.requireFunction(0, "filter")
            var result: [MLValue] = []
            for element in items(context.argument(1)) {
                let kept = try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location)
                if try semantics.isTruthy(kept) { result.append(element) }
            }
            return .array(MLArray(result))
        })
        environment.define("foldl", function("foldl", 3) { context in
            let body = try context.requireFunction(0, "foldl")
            var accumulator = context.argument(1)
            for element in items(context.argument(2)) {
                accumulator = try context.interpreter.callFunction(
                    body, arguments: [accumulator, element], location: context.location)
            }
            return accumulator
        })
        environment.define("foldr", function("foldr", 3) { context in
            let body = try context.requireFunction(0, "foldr")
            var accumulator = context.argument(1)
            for element in items(context.argument(2)).reversed() {
                accumulator = try context.interpreter.callFunction(
                    body, arguments: [element, accumulator], location: context.location)
            }
            return accumulator
        })
        environment.define("zipWith", function("zipWith", 3) { context in
            let body = try context.requireFunction(0, "zipWith")
            let left = items(context.argument(1))
            let right = items(context.argument(2))
            var result: [MLValue] = []
            for index in 0..<Swift.min(left.count, right.count) {
                result.append(try context.interpreter.callFunction(
                    body, arguments: [left[index], right[index]],
                    location: context.location))
            }
            return .array(MLArray(result))
        })
        environment.define("zip", function("zip", 2) { context in
            let left = items(context.argument(0))
            let right = items(context.argument(1))
            var result: [MLValue] = []
            for index in 0..<Swift.min(left.count, right.count) {
                result.append(.tuple([left[index], right[index]]))
            }
            return .array(MLArray(result))
        })
        environment.define("length", function("length", 1) { context in
            .int(Int64(items(context.argument(0)).count))
        })
        environment.define("sum", function("sum", 1) { context in
            var total = 0.0
            var isInteger = true
            for element in items(context.argument(0)) {
                if let number = element.asInt { total += Double(number) }
                else if let number = element.asDouble {
                    total += number
                    isInteger = false
                }
            }
            return isInteger ? .int(Int64(total)) : .double(total)
        })
        environment.define("product", function("product", 1) { context in
            var total = 1.0
            for element in items(context.argument(0)) {
                total *= element.asDouble ?? Double(element.asInt ?? 0)
            }
            return total == total.rounded() ? .int(Int64(total)) : .double(total)
        })
        environment.define("reverse", function("reverse", 1) { context in
            if let text = context.argument(0).asString {
                return .string(String(text.reversed()))
            }
            return .array(MLArray(items(context.argument(0)).reversed()))
        })
        environment.define("head", function("head", 1) { context in
            guard let first = items(context.argument(0)).first else {
                throw MLError.runtime("Prelude.head: empty list")
            }
            return first
        })
        environment.define("tail", function("tail", 1) { context in
            .array(MLArray(Array(items(context.argument(0)).dropFirst())))
        })
        environment.define("last", function("last", 1) { context in
            items(context.argument(0)).last ?? .unit
        })
        environment.define("init", function("init", 1) { context in
            .array(MLArray(Array(items(context.argument(0)).dropLast())))
        })
        environment.define("take", function("take", 2) { context in
            let count = Int(context.argument(0).asInt ?? 0)
            return .array(MLArray(Array(items(context.argument(1))
                .prefix(Swift.max(0, count)))))
        })
        environment.define("drop", function("drop", 2) { context in
            let count = Int(context.argument(0).asInt ?? 0)
            return .array(MLArray(Array(items(context.argument(1))
                .dropFirst(Swift.max(0, count)))))
        })
        environment.define("elem", function("elem", 2) { context in
            .bool(items(context.argument(1)).contains {
                MLOperations.strictEquals($0, context.argument(0), semantics: semantics)
            })
        })
        environment.define("null", function("null", 1) { context in
            .bool(items(context.argument(0)).isEmpty)
        })
        environment.define("concat", function("concat", 1) { context in
            var result: [MLValue] = []
            for element in items(context.argument(0)) { result += items(element) }
            return .array(MLArray(result))
        })
        environment.define("replicate", function("replicate", 2) { context in
            let count = Int(context.argument(0).asInt ?? 0)
            return .array(MLArray(Array(repeating: context.argument(1),
                                        count: Swift.max(0, count))))
        })
        environment.define("sort", function("sort", 1) { context in
            .array(MLArray(try MLStdlib.stableSorted(items(context.argument(0)),
                                                     interpreter: context.interpreter,
                                                     comparator: nil)))
        })
        environment.define("nub", function("nub", 1) { context in
            var result: [MLValue] = []
            for element in items(context.argument(0)) {
                if !result.contains(where: {
                    MLOperations.strictEquals($0, element, semantics: semantics)
                }) { result.append(element) }
            }
            return .array(MLArray(result))
        })
        environment.define("intercalate", function("intercalate", 2) { context in
            let separator = semantics.display(context.argument(0))
            return .string(items(context.argument(1))
                .map { semantics.display($0) }.joined(separator: separator))
        })
        environment.define("words", function("words", 1) { context in
            .array(MLArray(semantics.display(context.argument(0))
                .split(whereSeparator: { $0.isWhitespace }).map { .string(String($0)) }))
        })
        environment.define("unwords", function("unwords", 1) { context in
            .string(items(context.argument(0)).map { semantics.display($0) }
                .joined(separator: " "))
        })
        environment.define("lines", function("lines", 1) { context in
            .array(MLArray(semantics.display(context.argument(0))
                .components(separatedBy: "\n").map { .string($0) }))
        })
        environment.define("unlines", function("unlines", 1) { context in
            .string(items(context.argument(0)).map { semantics.display($0) + "\n" }.joined())
        })
        environment.define("mapM_", function("mapM_", 2) { context in
            let body = try context.requireFunction(0, "mapM_")
            for element in items(context.argument(1)) {
                _ = try context.interpreter.callFunction(body, arguments: [element],
                                                         location: context.location)
            }
            return .unit
        })
        environment.define("forM_", function("forM_", 2) { context in
            let body = try context.requireFunction(1, "forM_")
            for element in items(context.argument(0)) {
                _ = try context.interpreter.callFunction(body, arguments: [element],
                                                         location: context.location)
            }
            return .unit
        })
        environment.define("return", function("return", 1) { context in
            context.argument(0)
        })

        // 数と組。
        environment.define("div", function("div", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.runtime("divide by zero") }
            return .int(Int64((Double(left) / Double(right)).rounded(.down)))
        })
        environment.define("mod", function("mod", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.runtime("divide by zero") }
            let remainder = left % right
            return .int(remainder != 0 && (remainder < 0) != (right < 0)
                            ? remainder + right : remainder)
        })
        environment.define("abs", function("abs", 1) { context in
            if let number = context.argument(0).asInt { return .int(Swift.abs(number)) }
            return .double(Swift.abs(context.argument(0).asDouble ?? 0))
        })
        environment.define("even", function("even", 1) { context in
            .bool((context.argument(0).asInt ?? 0) % 2 == 0)
        })
        environment.define("odd", function("odd", 1) { context in
            .bool((context.argument(0).asInt ?? 0) % 2 != 0)
        })
        environment.define("max", function("max", 2) { context in
            guard let order = semantics.compare(context.argument(0), context.argument(1))
            else { return context.argument(0) }
            return order >= 0 ? context.argument(0) : context.argument(1)
        })
        environment.define("min", function("min", 2) { context in
            guard let order = semantics.compare(context.argument(0), context.argument(1))
            else { return context.argument(0) }
            return order <= 0 ? context.argument(0) : context.argument(1)
        })
        environment.define("maximum", function("maximum", 1) { context in
            try extreme(items(context.argument(0)), keepLarger: true, semantics: semantics)
        })
        environment.define("minimum", function("minimum", 1) { context in
            try extreme(items(context.argument(0)), keepLarger: false, semantics: semantics)
        })
        environment.define("fst", function("fst", 1) { context in
            guard case .tuple(let items) = context.argument(0).forced, !items.isEmpty else {
                return .unit
            }
            return items[0]
        })
        environment.define("snd", function("snd", 1) { context in
            guard case .tuple(let items) = context.argument(0).forced, items.count > 1 else {
                return .unit
            }
            return items[1]
        })
        environment.define("fromIntegral", function("fromIntegral", 1) { context in
            .double(Double(context.argument(0).asInt ?? 0))
        })
        environment.define("floor", function("floor", 1) { context in
            .int(Int64((context.argument(0).asDouble
                            ?? Double(context.argument(0).asInt ?? 0)).rounded(.down)))
        })
        environment.define("ceiling", function("ceiling", 1) { context in
            .int(Int64((context.argument(0).asDouble
                            ?? Double(context.argument(0).asInt ?? 0)).rounded(.up)))
        })
        environment.define("round", function("round", 1) { context in
            .int(Int64((context.argument(0).asDouble
                            ?? Double(context.argument(0).asInt ?? 0)).rounded()))
        })
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(context.argument(0).asDouble
                                        ?? Double(context.argument(0).asInt ?? 0)))
        })
        environment.define("toUpper", function("toUpper", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("toLower", function("toLower", 1) { context in
            .string(semantics.display(context.argument(0)).lowercased())
        })
    }

    private static func extreme(_ elements: [MLValue], keepLarger: Bool,
                                semantics: HaskellSemantics) throws -> MLValue {
        var best: MLValue?
        for element in elements {
            guard let current = best else {
                best = element
                continue
            }
            guard let order = semantics.compare(element, current) else { continue }
            if keepLarger ? order > 0 : order < 0 { best = element }
        }
        return best ?? .unit
    }
}
