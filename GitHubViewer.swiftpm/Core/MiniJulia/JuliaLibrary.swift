import Foundation

/// Julia らしい振る舞い。
final class JuliaSemantics: MLSemantics {
    override var languageID: String { "julia" }
    override var displayName: String { "内蔵 Julia 処理系" }
    /// Julia の添字は 1 から始まる。
    override var indexBase: Int { 1 }
    /// `/` は常に小数。
    override var divisionAlwaysProducesDouble: Bool { true }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// Julia は代入がそのまま変数の作成になる。
    override var requiresDefinitionBeforeUse: Bool { false }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("条件には Bool が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "Nothing"
        case .bool: return "Bool"
        case .int: return "Int64"
        case .double: return "Float64"
        case .char: return "Char"
        case .string: return "String"
        case .array: return "Vector"
        case .map: return "Dict"
        case .tuple: return "Tuple"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    /// Julia は整数値の Float64 を `1.0` と書く。
    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        if value == value.rounded(), Swift.abs(value) < 1e16 {
            return String(Int64(value)) + ".0"
        }
        return "\(value)"
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nothing"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { inspect($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            let items = map.pairs.map { "\(inspect($0.key.asValue)) => \(inspect($0.value))" }
            return "Dict(" + items.joined(separator: ", ") + ")"
        case .tuple(let items):
            if items.count == 1 { return "(" + inspect(items[0]) + ",)" }
            return "(" + items.map { inspect($0) }.joined(separator: ", ") + ")"
        case .range(let range):
            return "\(range.lower):\(range.isClosed ? range.upper : range.upper - 1)"
        case .object(let object):
            let items = object.fields.values.map { inspect($0) }
            return object.typeName + "(" + items.joined(separator: ", ") + ")"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// 入れ子の中では文字列に引用符が付く。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "'\(character)'"
        default: return display(value)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue { .unit }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["Float64", "Float32", "Float"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case ":":
            guard let low = lhs.asInt, let high = rhs.asInt else { return nil }
            return .range(MLRange(lower: low, upper: high, isClosed: true))
        case "÷":
            guard let left = lhs.asInt, let right = rhs.asInt, right != 0 else {
                throw MLError.runtime("0 で割ることはできません")
            }
            return .int(left / right)
        case "//":
            guard let left = lhs.asDouble, let right = rhs.asDouble, right != 0 else {
                throw MLError.runtime("0 で割ることはできません")
            }
            return .double(left / right)
        case "≤": return .bool((compare(lhs, rhs) ?? 1) <= 0)
        case "≥": return .bool((compare(lhs, rhs) ?? -1) >= 0)
        case "≠": return .bool(!areEqual(lhs, rhs))
        case "∈", "in":
            if let array = rhs.asArray {
                return .bool(array.elements.contains { areEqual($0, lhs) })
            }
            if case .range(let range) = rhs.forced, let number = lhs.asInt {
                return .bool(range.isClosed ? (number >= range.lower && number <= range.upper)
                                            : (number >= range.lower && number < range.upper))
            }
            return .bool(false)
        case "*":
            // Julia の `*` は文字列の連結にも使う。
            if case .string(let left) = lhs.forced, case .string(let right) = rhs.forced {
                return .string(left + right)
            }
            return nil
        case "^":
            return MLOperations.power(lhs.asDouble ?? 0, rhs.asDouble ?? 0,
                                      preferInteger: lhs.asInt != nil && (rhs.asInt ?? -1) >= 0)
        case "=>":
            // `"a" => 1` は組 (Pair)。
            return .tuple([lhs, rhs])
        case "|>":
            guard let function = rhs.asFunction else { return nil }
            return try interpreter.callFunction(function, arguments: [lhs])
        case "isa":
            guard let name = rhs.asString else { return .bool(false) }
            return .bool(interpreter.matchesType(lhs, name))
        default:
            // ブロードキャスト `.+` など。
            guard op.hasPrefix("."), op.count > 1 else { return nil }
            let inner = String(op.dropFirst())
            let leftItems = lhs.asArray?.elements
            let rightItems = rhs.asArray?.elements
            if leftItems == nil && rightItems == nil { return nil }
            let count = Swift.max(leftItems?.count ?? 0, rightItems?.count ?? 0)
            var results: [MLValue] = []
            for index in 0..<count {
                let left = leftItems.map { $0[index % Swift.max(1, $0.count)] } ?? lhs
                let right = rightItems.map { $0[index % Swift.max(1, $0.count)] } ?? rhs
                results.append(try interpreter.applyBinary(op: inner, lhs: left, rhs: right,
                                                           location: .unknown))
            }
            return .array(MLArray(results))
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        JuliaLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try MLStdlib.callMethod(on: value, name: name, context: context)
    }
}

/// Julia の標準関数。Julia はメソッドより関数が中心なので、大域に並べる。
enum JuliaLibrary {

    static func install(into environment: MLEnvironment, semantics: JuliaSemantics) {
        func define(_ name: String, _ arity: ClosedRange<Int>,
                    _ impl: @escaping MLFunction.MLNativeImpl) {
            environment.define(name, .function(.native(name, arity, impl)), isConstant: true)
        }

        func define(_ name: String, _ arity: Int,
                    _ impl: @escaping MLFunction.MLNativeImpl) {
            define(name, arity...arity, impl)
        }

        define("println", 0...16) { context in
            context.interpreter.write(
                context.arguments.map { semantics.display($0) }.joined() + "\n")
            return .unit
        }
        define("print", 0...16) { context in
            context.interpreter.write(context.arguments.map { semantics.display($0) }.joined())
            return .unit
        }
        define("@printf", 1...16) { context in
            let pattern = try context.requireString(0, "@printf")
            context.interpreter.write(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
            return .unit
        }
        define("@sprintf", 1...16) { context in
            let pattern = try context.requireString(0, "@sprintf")
            return .string(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
        }
        define("@show", 1...8) { context in
            context.interpreter.write(
                context.arguments.map { semantics.inspect($0) }.joined(separator: " ") + "\n")
            return .unit
        }
        define("@assert", 1...2) { context in
            if try !semantics.isTruthy(context.argument(0)) {
                throw MLError.runtime("assert: 条件が成り立ちません")
            }
            return .unit
        }
        define("string", 0...16) { context in
            .string(context.arguments.map { semantics.display($0) }.joined())
        }
        define("length", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
            if case .range(let range) = value { return .int(Int64(range.elements.count)) }
            if case .tuple(let items) = value { return .int(Int64(items.count)) }
            return .int(0)
        }
        define("push!", 1...16) { context in
            guard let array = context.argument(0).asArray else { return context.argument(0) }
            for value in context.arguments.dropFirst() { array.elements.append(value) }
            return .array(array)
        }
        define("pop!", 1) { context in
            guard let array = context.argument(0).asArray,
                  let last = array.elements.popLast() else {
                throw MLError.runtime("pop!: 空の配列です")
            }
            return last
        }
        define("append!", 2) { context in
            guard let array = context.argument(0).asArray,
                  let other = context.argument(1).asArray else { return context.argument(0) }
            array.elements.append(contentsOf: other.elements)
            return .array(array)
        }
        define("sum", 1...2) { context in
            try reduceNumbers(context, semantics: semantics, op: "+", initial: .int(0))
        }
        define("prod", 1...2) { context in
            try reduceNumbers(context, semantics: semantics, op: "*", initial: .int(1))
        }
        define("maximum", 1) { context in
            try MLStdlib.extreme(try MLOperations.iterate(context.argument(0),
                                                          semantics: semantics),
                                 semantics: semantics, smaller: false)
        }
        define("minimum", 1) { context in
            try MLStdlib.extreme(try MLOperations.iterate(context.argument(0),
                                                          semantics: semantics),
                                 semantics: semantics, smaller: true)
        }
        define("max", 1...16) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: false)
        }
        define("min", 1...16) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: true)
        }
        define("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            default: return .double(Swift.abs(context.argument(0).asDouble ?? 0))
            }
        }
        define("sort", 1...2) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            let sorted = try MLStdlib.stableSorted(items, interpreter: context.interpreter,
                                                   comparator: nil)
            // `rev=true` はラベル付き引数で来る。
            if let flag = context.argument(labeled: "rev"), try semantics.isTruthy(flag) {
                return .array(MLArray(sorted.reversed()))
            }
            return .array(MLArray(sorted))
        }
        define("sort!", 1...2) { context in
            guard let array = context.argument(0).asArray else { return context.argument(0) }
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: context.interpreter,
                                                       comparator: nil)
            return .array(array)
        }
        define("reverse", 1) { context in
            if let text = context.argument(0).asString { return .string(String(text.reversed())) }
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            return .array(MLArray(items.reversed()))
        }
        define("map", 2...8) { context in
            let transform = try context.requireFunction(0, "map")
            let items = try MLOperations.iterate(context.argument(1), semantics: semantics)
            var results: [MLValue] = []
            for element in items {
                results.append(try context.interpreter.callFunction(transform,
                                                                    arguments: [element]))
            }
            return .array(MLArray(results))
        }
        define("filter", 2) { context in
            let predicate = try context.requireFunction(0, "filter")
            let items = try MLOperations.iterate(context.argument(1), semantics: semantics)
            var results: [MLValue] = []
            for element in items
            where try semantics.isTruthy(context.interpreter.callFunction(predicate,
                                                                          arguments: [element])) {
                results.append(element)
            }
            return .array(MLArray(results))
        }
        define("reduce", 2...3) { context in
            let combine = try context.requireFunction(0, "reduce")
            let items = try MLOperations.iterate(context.argument(1), semantics: semantics)
            guard var accumulator = items.first else { return .unit }
            for element in items.dropFirst() {
                accumulator = try context.interpreter.callFunction(
                    combine, arguments: [accumulator, element])
            }
            return accumulator
        }
        define("collect", 1) { context in
            .array(MLArray(try MLOperations.iterate(context.argument(0),
                                                    semantics: semantics)))
        }
        define("enumerate", 1) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            // Julia の enumerate は 1 から始まる。
            return .array(MLArray(items.enumerated()
                .map { .tuple([.int(Int64($0.offset + 1)), $0.element]) }))
        }
        define("zip", 2...8) { context in
            var lists: [[MLValue]] = []
            for argument in context.arguments {
                lists.append(try MLOperations.iterate(argument, semantics: semantics))
            }
            let count = lists.map { $0.count }.min() ?? 0
            var results: [MLValue] = []
            for index in 0..<count {
                results.append(.tuple(lists.map { $0[index] }))
            }
            return .array(MLArray(results))
        }
        define("join", 1...2) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            let separator = context.optionalArgument(1)?.asString ?? ""
            return .string(items.map { semantics.display($0) }.joined(separator: separator))
        }
        define("split", 1...2) { context in
            let text = try context.requireString(0, "split")
            guard let separator = context.optionalArgument(1)?.asString else {
                return .array(MLArray(text.split(whereSeparator: { $0.isWhitespace })
                    .map { .string(String($0)) }))
            }
            return .array(MLArray(text.components(separatedBy: separator)
                .map { .string($0) }))
        }
        define("uppercase", 1) { context in
            .string(try context.requireString(0, "uppercase").uppercased())
        }
        define("lowercase", 1) { context in
            .string(try context.requireString(0, "lowercase").lowercased())
        }
        define("occursin", 2) { context in
            let needle = try context.requireString(0, "occursin")
            let text = try context.requireString(1, "occursin")
            return .bool(needle.isEmpty || text.contains(needle))
        }
        define("replace", 2...4) { context in
            let text = try context.requireString(0, "replace")
            // `replace(s, "a" => "b")` の形。
            if case .tuple(let pair) = context.argument(1).forced, pair.count >= 2 {
                return .string(text.replacingOccurrences(of: pair[0].asString ?? "",
                                                         with: pair[1].asString ?? ""))
            }
            return .string(text.replacingOccurrences(of: context.argument(1).asString ?? "",
                                                     with: context.argument(2).asString ?? ""))
        }
        define("parse", 2) { context in
            let text = try context.requireString(1, "parse").trimmingCharacters(in: .whitespaces)
            let typeName = context.argument(0).asString ?? "Int64"
            if typeName.hasPrefix("Float") {
                guard let value = Double(text) else {
                    throw MLError.runtime("parse: 数値に変換できません: \(text)")
                }
                return .double(value)
            }
            guard let value = Int64(text) else {
                throw MLError.runtime("parse: 数値に変換できません: \(text)")
            }
            return .int(value)
        }
        define("repeat", 2) { context in
            let count = Int(try context.requireInt(1, "repeat"))
            if let text = context.argument(0).asString {
                return .string(count > 0 ? String(repeating: text, count: count) : "")
            }
            guard let array = context.argument(0).asArray else { return context.argument(0) }
            var elements: [MLValue] = []
            for _ in 0..<Swift.max(0, count) { elements += array.elements }
            return .array(MLArray(elements))
        }
        define("first", 1...2) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            if let count = context.optionalArgument(1)?.asInt {
                return .array(MLArray(Array(items.prefix(Int(count)))))
            }
            return items.first ?? .unit
        }
        define("last", 1...2) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            if let count = context.optionalArgument(1)?.asInt {
                return .array(MLArray(Array(items.suffix(Int(count)))))
            }
            return items.last ?? .unit
        }
        define("isempty", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .bool(array.elements.isEmpty) }
            if let text = value.asString { return .bool(text.isEmpty) }
            if let map = value.asMap { return .bool(map.isEmpty) }
            return .bool(true)
        }
        define("haskey", 2) { context in
            guard let map = context.argument(0).asMap,
                  let key = MLKey.from(context.argument(1)) else { return .bool(false) }
            return .bool(map.contains(key))
        }
        define("keys", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.keys.map { $0.asValue }))
        }
        define("values", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.values))
        }
        define("get", 3) { context in
            guard let map = context.argument(0).asMap,
                  let key = MLKey.from(context.argument(1)) else {
                return context.argument(2)
            }
            return map[key] ?? context.argument(2)
        }
        define("Dict", 0...32) { context in
            let map = MLMap()
            for argument in context.arguments {
                guard case .tuple(let pair) = argument.forced, pair.count >= 2,
                      let key = MLKey.from(pair[0]) else { continue }
                map[key] = pair[1]
            }
            return .map(map)
        }
        define("Set", 0...1) { context in
            guard let array = context.argument(0).asArray else { return .array(MLArray()) }
            var unique: [MLValue] = []
            for value in array.elements
            where !unique.contains(where: { semantics.areEqual($0, value) }) {
                unique.append(value)
            }
            return .array(MLArray(unique))
        }
        define("#broadcast", 1...16) { context in
            guard let function = context.argument(0).asFunction else { return .unit }
            let items = try MLOperations.iterate(context.argument(1), semantics: semantics)
            var results: [MLValue] = []
            for element in items {
                results.append(try context.interpreter.callFunction(function,
                                                                    arguments: [element]))
            }
            return .array(MLArray(results))
        }
        define("typeof", 1) { context in .string(semantics.typeName(of: context.argument(0))) }
        define("error", 0...4) { context in
            throw MLError.runtime(context.arguments.map { semantics.display($0) }.joined())
        }
        define("throw", 1) { context in throw MLError.thrown(context.argument(0)) }
        define("readline", 0...1) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        }
        define("round", 1...2) { context in
            let value = try context.requireDouble(0, "round")
            if let digits = context.argument(labeled: "digits")?.asInt {
                let factor = Foundation.pow(10.0, Double(digits))
                return .double((value * factor).rounded() / factor)
            }
            return .double(value.rounded())
        }
        define("floor", 1...2) { context in
            .double(Foundation.floor(try context.requireDouble(0, "floor")))
        }
        define("ceil", 1...2) { context in
            .double(Foundation.ceil(try context.requireDouble(0, "ceil")))
        }
        define("div", 2) { context in
            let right = try context.requireInt(1, "div")
            guard right != 0 else { throw MLError.runtime("0 で割ることはできません") }
            return .int(try context.requireInt(0, "div") / right)
        }
        define("mod", 2) { context in
            let right = try context.requireInt(1, "mod")
            guard right != 0 else { throw MLError.runtime("0 で割ることはできません") }
            let remainder = try context.requireInt(0, "mod") % right
            return .int(remainder != 0 && (remainder < 0) != (right < 0)
                        ? remainder + right : remainder)
        }
        for (name, implementation) in MLStdlib.mathFunctions
        where !["round", "floor", "ceil"].contains(name) {
            define(name, 1...1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            }
        }
        environment.define("pi", .double(Double.pi), isConstant: true)
        environment.define("π", .double(Double.pi), isConstant: true)
        environment.define("ℯ", .double(M_E), isConstant: true)
        environment.define("Int", .string("Int64"), isConstant: true)
        environment.define("Int64", .string("Int64"), isConstant: true)
        environment.define("Float64", .string("Float64"), isConstant: true)
        environment.define("String", .string("String"), isConstant: true)
    }

    static func reduceNumbers(_ context: MLCallContext, semantics: JuliaSemantics,
                              op: String, initial: MLValue) throws -> MLValue {
        // `sum(f, xs)` の形にも対応する。
        var items: [MLValue]
        var transform: MLFunction?
        if context.arguments.count >= 2, let function = context.argument(0).asFunction {
            transform = function
            items = try MLOperations.iterate(context.argument(1), semantics: semantics)
        } else {
            items = try MLOperations.iterate(context.argument(0), semantics: semantics)
        }
        var total = initial
        for element in items {
            let value = transform.map {
                (try? context.interpreter.callFunction($0, arguments: [element])) ?? element
            } ?? element
            total = try MLOperations.arithmetic(op: op, lhs: total, rhs: value,
                                                semantics: semantics)
        }
        return total
    }
}
