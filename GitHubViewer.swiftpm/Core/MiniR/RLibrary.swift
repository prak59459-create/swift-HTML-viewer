import Foundation

/// R らしい振る舞い。
final class RSemantics: MLSemantics {
    override var languageID: String { "r" }
    override var displayName: String { "内蔵 R 処理系" }
    /// 添字は 1 から。
    override var indexBase: Int { 1 }
    override var divisionAlwaysProducesDouble: Bool { true }
    override var requiresDefinitionBeforeUse: Bool { true }
    /// `x <- 1` はその場で変数を作る。
    override var assignmentDefinesNewVariables: Bool { true }
    override var usesValueSemantics: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .string(let text): return text == "TRUE" || text == "T"
        case .array(let array):
            guard let first = array.elements.first else {
                throw MLError.runtime("argument is of length zero")
            }
            return try isTruthy(first)
        case .unit: return false
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "NULL"
        case .bool: return "logical"
        case .int: return "integer"
        case .double: return "numeric"
        case .string, .char: return "character"
        case .array: return "vector"
        case .map: return "list"
        case .function: return "function"
        case .object(let object): return object.typeName
        default: return "ANY"
        }
    }

    /// `cat` や `paste` が使う、要素 1 つぶんの書き方。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "NULL"
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array): return array.elements.map { display($0) }
            .joined(separator: " ")
        case .map(let map): return map.pairs.map { display($0.value) }
            .joined(separator: " ")
        default: return MLDisplay.plain(value, semantics: self)
        }
    }

    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        default: return display(value)
        }
    }

    /// R は既定で有効数字 7 桁。
    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.7g", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    /// 四則演算は要素ごとに働く。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case ":":
            // `1:5` は 1 から 5 までのベクトル。
            let from = lhs.asInt ?? Int64(lhs.asDouble ?? 0)
            let to = rhs.asInt ?? Int64(rhs.asDouble ?? 0)
            let step: Int64 = to >= from ? 1 : -1
            var elements: [MLValue] = []
            var current = from
            while (step > 0 && current <= to) || (step < 0 && current >= to) {
                elements.append(.int(current))
                current += step
            }
            return .array(MLArray(elements))
        case "%%":
            return try elementwise(lhs, rhs) { left, right in
                let a = left.asDouble ?? Double(left.asInt ?? 0)
                let b = right.asDouble ?? Double(right.asInt ?? 0)
                guard b != 0 else { return .double(.nan) }
                let result = a - b * (a / b).rounded(.down)
                if left.asInt != nil && right.asInt != nil { return .int(Int64(result)) }
                return .double(result)
            }
        case "%/%":
            return try elementwise(lhs, rhs) { left, right in
                let a = left.asDouble ?? Double(left.asInt ?? 0)
                let b = right.asDouble ?? Double(right.asInt ?? 0)
                guard b != 0 else { return .double(.infinity) }
                return .int(Int64((a / b).rounded(.down)))
            }
        case "%in%":
            let items = try MLOperations.iterate(rhs, semantics: self)
            return try elementwise(lhs, .unit) { left, _ in
                .bool(items.contains { MLOperations.strictEquals($0, left, semantics: self) })
            }
        case "^":
            return try elementwise(lhs, rhs) { left, right in
                .double(Foundation.pow(left.asDouble ?? Double(left.asInt ?? 0),
                                       right.asDouble ?? Double(right.asInt ?? 0)))
            }
        case "+", "-", "*", "/":
            // どちらかがベクトルなら要素ごとに計算する。
            guard lhs.asArray != nil || rhs.asArray != nil else {
                if op == "+", case .string(let left) = lhs.forced {
                    return .string(left + display(rhs))
                }
                return nil
            }
            return try elementwise(lhs, rhs) { left, right in
                try MLOperations.arithmetic(op: op, lhs: left, rhs: right, semantics: self)
            }
        case "==", "!=", "<", ">", "<=", ">=":
            guard lhs.asArray != nil || rhs.asArray != nil else { return nil }
            return try elementwise(lhs, rhs) { left, right in
                guard let order = self.compare(left, right) else {
                    return .bool(MLOperations.strictEquals(left, right, semantics: self))
                }
                switch op {
                case "==": return .bool(order == 0)
                case "!=": return .bool(order != 0)
                case "<": return .bool(order < 0)
                case ">": return .bool(order > 0)
                case "<=": return .bool(order <= 0)
                default: return .bool(order >= 0)
                }
            }
        default:
            return nil
        }
    }

    /// 長さの違うベクトルは短いほうを繰り返す (R のリサイクル規則)。
    private func elementwise(_ lhs: MLValue, _ rhs: MLValue,
                             _ body: (MLValue, MLValue) throws -> MLValue) rethrows
        -> MLValue {
        let left = lhs.asArray?.elements ?? [lhs.forced]
        let right = rhs.asArray?.elements ?? [rhs.forced]
        let count = Swift.max(left.count, right.count)
        guard count > 0 else { return .array(MLArray()) }
        var result: [MLValue] = []
        for index in 0..<count {
            result.append(try body(left[index % Swift.max(1, left.count)],
                                   right[index % Swift.max(1, right.count)]))
        }
        if lhs.asArray == nil && rhs.asArray == nil { return result[0] }
        return .array(MLArray(result))
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        RLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }

    /// `x[x > 3]` や `x[c(1, 3)]` のような、ベクトルによる取り出し。
    override func subscriptValue(of receiver: MLValue, index: MLValue,
                                 interpreter: MLInterpreter) throws -> MLValue? {
        // 名前で引く (`person$name` と同じ形)。
        if let map = receiver.asMap, let key = index.asString {
            return map[.string(key)] ?? .unit
        }
        guard let array = receiver.asArray, let selector = index.asArray else { return nil }
        // 論理ベクトルなら真の位置だけ残す。
        if selector.elements.allSatisfy({ if case .bool = $0.forced { return true }
                                          return false }) {
            var result: [MLValue] = []
            for (position, element) in array.elements.enumerated() {
                let keep = selector.elements[position % Swift.max(1, selector.count)]
                if try isTruthy(keep) { result.append(element) }
            }
            return .array(MLArray(result))
        }
        // 負の添字はその位置を除く。
        let numbers = selector.elements.compactMap { $0.asInt }
        if numbers.allSatisfy({ $0 < 0 }) {
            let dropped = Set(numbers.map { Int(-$0) - 1 })
            return .array(MLArray(array.elements.enumerated()
                .filter { !dropped.contains($0.offset) }.map { $0.element }))
        }
        var result: [MLValue] = []
        for number in numbers {
            let position = Int(number) - 1
            result.append(position >= 0 && position < array.count
                            ? array.elements[position] : .unit)
        }
        return .array(MLArray(result))
    }
}

/// R の標準関数。
enum RLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    /// 値をベクトルとして読む。
    static func items(_ value: MLValue) -> [MLValue] {
        if let array = value.asArray { return array.elements }
        if let map = value.asMap { return map.pairs.map { $0.value } }
        if value.isUnit { return [] }
        return [value.forced]
    }

    /// `print` が使う `[1] 1 2 3` の形。
    static func printed(_ value: MLValue, semantics: RSemantics) -> String {
        if let map = value.asMap {
            return map.pairs.map { pair -> String in
                "$" + (pair.key.asValue.asString ?? "") + "\n"
                    + printed(pair.value, semantics: semantics) + "\n"
            }.joined(separator: "\n")
        }
        let elements = items(value)
        if elements.isEmpty { return "NULL" }
        let texts = elements.map { semantics.inspect($0) }
        return "[1] " + texts.joined(separator: " ")
    }

    static func install(into environment: MLEnvironment, semantics: RSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)
        environment.define("pi", .double(Double.pi))
        environment.define("LETTERS", .array(MLArray(
            (65...90).map { .string(String(Character(Unicode.Scalar($0)!))) })))
        environment.define("letters", .array(MLArray(
            (97...122).map { .string(String(Character(Unicode.Scalar($0)!))) })))

        environment.define("c", function("c", 0...256) { context in
            var elements: [MLValue] = []
            var names: [String?] = []
            var hasNames = false
            for (index, value) in context.arguments.enumerated() {
                let label = index < context.labels.count ? context.labels[index] : nil
                if label != nil { hasNames = true }
                let inner = items(value)
                if inner.count == 1 || value.asArray == nil {
                    elements.append(value.forced)
                    names.append(label)
                } else {
                    elements += inner
                    names += Array(repeating: label, count: inner.count)
                }
            }
            guard hasNames else { return .array(MLArray(elements)) }
            let map = MLMap()
            for (index, element) in elements.enumerated() {
                let key = names[index] ?? String(index + 1)
                map[.string(key)] = element
            }
            return .map(map)
        })
        environment.define("list", function("list", 0...256) { context in
            let map = MLMap()
            for (index, value) in context.arguments.enumerated() {
                let label = index < context.labels.count ? context.labels[index] : nil
                map[.string(label ?? String(index + 1))] = value
            }
            return .map(map)
        })
        environment.define("vector", function("vector", 0...2) { _ in .array(MLArray()) })

        environment.define("print", function("print", 1...2) { context in
            context.interpreter.write(printed(context.argument(0), semantics: semantics)
                                        + "\n")
            return context.argument(0)
        })
        environment.define("cat", function("cat", 0...256) { context in
            var parts: [String] = []
            var separator = " "
            for (index, value) in context.arguments.enumerated() {
                if index < context.labels.count, context.labels[index] == "sep" {
                    separator = semantics.display(value)
                    continue
                }
                parts += items(value).map { semantics.display($0) }
            }
            context.interpreter.write(parts.joined(separator: separator))
            return .unit
        })
        environment.define("paste", function("paste", 0...256) { context in
            try joined(context, semantics: semantics, defaultSeparator: " ")
        })
        environment.define("paste0", function("paste0", 0...256) { context in
            try joined(context, semantics: semantics, defaultSeparator: "")
        })
        environment.define("sprintf", function("sprintf", 1...64) { context in
            let pattern = try context.requireString(0, "sprintf")
            return .string(try MLStdlib.format(pattern,
                                               arguments: Array(context.arguments.dropFirst()),
                                               semantics: semantics))
        })
        environment.define("format", function("format", 1...4) { context in
            .string(semantics.display(context.argument(0)))
        })
        environment.define("nchar", function("nchar", 1) { context in
            .int(Int64(semantics.display(context.argument(0)).count))
        })
        environment.define("toupper", function("toupper", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("tolower", function("tolower", 1) { context in
            .string(semantics.display(context.argument(0)).lowercased())
        })
        environment.define("substr", function("substr", 3) { context in
            let characters = Array(semantics.display(context.argument(0)))
            let start = Int(try context.requireInt(1, "substr")) - 1
            let stop = Int(try context.requireInt(2, "substr"))
            guard start >= 0, start < characters.count else { return .string("") }
            return .string(String(characters[start..<Swift.min(characters.count, stop)]))
        })
        environment.define("strsplit", function("strsplit", 2) { context in
            let text = semantics.display(context.argument(0))
            let separator = semantics.display(context.argument(1))
            let parts = separator.isEmpty ? text.map { String($0) }
                                          : text.components(separatedBy: separator)
            return .array(MLArray([.array(MLArray(parts.map { .string($0) }))]))
        })

        // ベクトルの道具。
        environment.define("length", function("length", 1) { context in
            .int(Int64(items(context.argument(0)).count))
        })
        environment.define("sum", function("sum", 0...64) { context in
            var total = 0.0
            var isInteger = true
            for value in context.arguments {
                for element in items(value) {
                    if let number = element.asInt { total += Double(number) }
                    else if let number = element.asDouble {
                        total += number
                        isInteger = false
                    }
                }
            }
            return isInteger ? .int(Int64(total)) : .double(total)
        })
        environment.define("prod", function("prod", 0...64) { context in
            var total = 1.0
            for value in context.arguments {
                for element in items(value) {
                    total *= element.asDouble ?? Double(element.asInt ?? 0)
                }
            }
            return total == total.rounded() ? .int(Int64(total)) : .double(total)
        })
        environment.define("mean", function("mean", 1) { context in
            let elements = items(context.argument(0))
            guard !elements.isEmpty else { return .double(.nan) }
            let total = elements.reduce(0.0) { $0 + ($1.asDouble ?? Double($1.asInt ?? 0)) }
            return .double(total / Double(elements.count))
        })
        environment.define("max", function("max", 1...64) { context in
            try extreme(context, keepLarger: true, semantics: semantics)
        })
        environment.define("min", function("min", 1...64) { context in
            try extreme(context, keepLarger: false, semantics: semantics)
        })
        environment.define("rev", function("rev", 1) { context in
            .array(MLArray(items(context.argument(0)).reversed()))
        })
        environment.define("sort", function("sort", 1...2) { context in
            let elements = items(context.argument(0))
            let sorted = try MLStdlib.stableSorted(elements,
                                                   interpreter: context.interpreter,
                                                   comparator: nil)
            if context.argument(labeled: "decreasing").flatMap({ try? semantics.isTruthy($0) })
                == true {
                return .array(MLArray(sorted.reversed()))
            }
            return .array(MLArray(sorted))
        })
        environment.define("seq", function("seq", 1...3) { context in
            let from = context.argument(0).asInt ?? 1
            let to = context.optionalArgument(1)?.asInt ?? from
            let step = context.optionalArgument(2)?.asInt ?? (to >= from ? 1 : -1)
            var elements: [MLValue] = []
            var current = from
            while (step > 0 && current <= to) || (step < 0 && current >= to) {
                elements.append(.int(current))
                current += step
            }
            return .array(MLArray(elements))
        })
        environment.define("seq_along", function("seq_along", 1) { context in
            .array(MLArray((1...Swift.max(1, items(context.argument(0)).count))
                .map { .int(Int64($0)) }))
        })
        environment.define("rep", function("rep", 2) { context in
            let elements = items(context.argument(0))
            let count = Int(context.argument(1).asInt ?? 0)
            var result: [MLValue] = []
            for _ in 0..<Swift.max(0, count) { result += elements }
            return .array(MLArray(result))
        })
        environment.define("which", function("which", 1) { context in
            var result: [MLValue] = []
            for (index, element) in items(context.argument(0)).enumerated() {
                if try semantics.isTruthy(element) { result.append(.int(Int64(index + 1))) }
            }
            return .array(MLArray(result))
        })
        environment.define("any", function("any", 1...64) { context in
            for value in context.arguments {
                for element in items(value) where try semantics.isTruthy(element) {
                    return .bool(true)
                }
            }
            return .bool(false)
        })
        environment.define("all", function("all", 1...64) { context in
            for value in context.arguments {
                for element in items(value) where try !semantics.isTruthy(element) {
                    return .bool(false)
                }
            }
            return .bool(true)
        })
        environment.define("sapply", function("sapply", 2) { context in
            let body = try context.requireFunction(1, "sapply")
            var result: [MLValue] = []
            for element in items(context.argument(0)) {
                result.append(try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location))
            }
            return .array(MLArray(result))
        })
        environment.define("lapply", function("lapply", 2) { context in
            let body = try context.requireFunction(1, "lapply")
            var result: [MLValue] = []
            for element in items(context.argument(0)) {
                result.append(try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location))
            }
            return .array(MLArray(result))
        })
        environment.define("Filter", function("Filter", 2) { context in
            let body = try context.requireFunction(0, "Filter")
            var result: [MLValue] = []
            for element in items(context.argument(1)) {
                let kept = try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location)
                if try semantics.isTruthy(kept) { result.append(element) }
            }
            return .array(MLArray(result))
        })
        environment.define("Reduce", function("Reduce", 2...3) { context in
            let body = try context.requireFunction(0, "Reduce")
            let elements = items(context.argument(1))
            var accumulator = context.optionalArgument(2) ?? elements.first ?? .unit
            let rest = context.optionalArgument(2) == nil ? Array(elements.dropFirst())
                                                          : elements
            for element in rest {
                accumulator = try context.interpreter.callFunction(
                    body, arguments: [accumulator, element], location: context.location)
            }
            return accumulator
        })
        environment.define("names", function("names", 1) { context in
            guard let map = context.argument(0).asMap else { return .unit }
            return .array(MLArray(map.pairs.map { $0.key.asValue }))
        })
        environment.define("is.null", function("is.null", 1) { context in
            .bool(context.argument(0).isUnit)
        })
        environment.define("is.numeric", function("is.numeric", 1) { context in
            let first = items(context.argument(0)).first ?? .unit
            return .bool(first.asInt != nil || first.asDouble != nil)
        })
        environment.define("as.integer", function("as.integer", 1) { context in
            let value = context.argument(0)
            if let number = value.asDouble { return .int(Int64(number)) }
            if let number = value.asInt { return .int(number) }
            return .int(Int64(semantics.display(value)) ?? 0)
        })
        environment.define("as.numeric", function("as.numeric", 1) { context in
            .double(context.argument(0).asDouble
                        ?? Double(context.argument(0).asInt ?? 0))
        })
        environment.define("as.character", function("as.character", 1) { context in
            .string(semantics.display(context.argument(0)))
        })
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(context.argument(0).asDouble
                                        ?? Double(context.argument(0).asInt ?? 0)))
        })
        environment.define("floor", function("floor", 1) { context in
            .double((context.argument(0).asDouble
                        ?? Double(context.argument(0).asInt ?? 0)).rounded(.down))
        })
        environment.define("ceiling", function("ceiling", 1) { context in
            .double((context.argument(0).asDouble
                        ?? Double(context.argument(0).asInt ?? 0)).rounded(.up))
        })
        environment.define("round", function("round", 1...2) { context in
            let number = context.argument(0).asDouble
                ?? Double(context.argument(0).asInt ?? 0)
            let digits = Int(context.optionalArgument(1)?.asInt ?? 0)
            let scale = Foundation.pow(10.0, Double(digits))
            return .double((number * scale).rounded() / scale)
        })
        environment.define("abs", function("abs", 1) { context in
            if let number = context.argument(0).asInt { return .int(Swift.abs(number)) }
            return .double(Swift.abs(context.argument(0).asDouble ?? 0))
        })
        environment.define("stop", function("stop", 0...64) { context in
            throw MLError.thrown(.string(context.arguments
                                            .map { semantics.display($0) }.joined()))
        })
        environment.define("readline", function("readline", 0...1) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })
        environment.define("return", function("return", 0...1) { context in
            throw MLControl.returnValue(context.optionalArgument(0) ?? .unit)
        })
    }

    private static func joined(_ context: MLCallContext, semantics: RSemantics,
                               defaultSeparator: String) throws -> MLValue {
        var separator = defaultSeparator
        var parts: [[String]] = []
        for (index, value) in context.arguments.enumerated() {
            if index < context.labels.count, context.labels[index] == "sep"
                || context.labels[index] == "collapse" {
                separator = semantics.display(value)
                continue
            }
            parts.append(items(value).map { semantics.display($0) })
        }
        let count = parts.map { $0.count }.max() ?? 0
        guard count > 1 else {
            return .string(parts.map { $0.first ?? "" }.joined(separator: separator))
        }
        var result: [MLValue] = []
        for index in 0..<count {
            let pieces = parts.map { $0.isEmpty ? "" : $0[index % $0.count] }
            result.append(.string(pieces.joined(separator: separator)))
        }
        return .array(MLArray(result))
    }

    private static func extreme(_ context: MLCallContext, keepLarger: Bool,
                                semantics: RSemantics) throws -> MLValue {
        var best: MLValue?
        for value in context.arguments {
            for element in items(value) {
                guard let current = best else {
                    best = element
                    continue
                }
                guard let order = semantics.compare(element, current) else { continue }
                if keepLarger ? order > 0 : order < 0 { best = element }
            }
        }
        return best ?? .unit
    }
}
