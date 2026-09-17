import Foundation

/// Crystal らしい振る舞い (Ruby にとても近い)。
final class CrystalSemantics: MLSemantics {
    override var languageID: String { "crystal" }
    override var displayName: String { "内蔵 Crystal 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { false }
    override var allowsNegativeIndexing: Bool { true }
    override var outOfBoundsIsError: Bool { false }
    /// 代入がそのまま変数の作成になる。
    override var requiresDefinitionBeforeUse: Bool { false }
    /// `xs.sort` のように括弧を省いてもメソッド呼び出しになる。
    override var autoCallsZeroArgumentMembers: Bool { true }

    /// `nil` と `false` 以外は真。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "Nil"
        case .bool: return "Bool"
        case .int: return "Int32"
        case .double: return "Float64"
        case .char: return "Char"
        case .string: return "String"
        case .array: return "Array"
        case .map: return "Hash"
        case .tuple: return "Tuple"
        case .symbol: return "Symbol"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), Swift.abs(value) < 1e16 {
            return String(Int64(value)) + ".0"
        }
        return "\(value)"
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .symbol(let name): return name
        case .array(let array):
            return "[" + array.elements.map { inspect($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(inspect($0.key.asValue)) => \(inspect($0.value))" }
                .joined(separator: ", ") + "}"
        case .tuple(let items):
            return "{" + items.map { inspect($0) }.joined(separator: ", ") + "}"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("to_s") != nil,
               let result = try? interpreter.callMethod(on: value, name: "to_s",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            let items = object.fields.pairs.map { pair -> String in
                "@\(pair.key.asValue.asString ?? "")=\(inspect(pair.value))"
            }
            if items.isEmpty { return "#<\(object.typeName)>" }
            return "#<\(object.typeName):" + items.joined(separator: ", ") + ">"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "'\(character)'"
        case .symbol(let name): return ":" + name
        case .unit: return "nil"
        default: return display(value)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue { .unit }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "+":
            if case .string(let left) = lhs.forced { return .string(left + display(rhs)) }
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
            return nil
        case "*":
            if case .string(let text) = lhs.forced, let count = rhs.asInt {
                return .string(count > 0 ? String(repeating: text, count: Int(count)) : "")
            }
            if let array = lhs.asArray, let count = rhs.asInt {
                var elements: [MLValue] = []
                for _ in 0..<Swift.max(0, count) { elements += array.elements }
                return .array(MLArray(elements))
            }
            return nil
        case "<=>":
            guard let order = compare(lhs, rhs) else { return .unit }
            return .int(Int64(order))
        case "===":
            return .bool(areEqual(lhs, rhs))
        case "..":
            guard let low = lhs.asInt, let high = rhs.asInt else { return nil }
            return .range(MLRange(lower: low, upper: high, isClosed: true))
        case "...":
            guard let low = lhs.asInt, let high = rhs.asInt else { return nil }
            return .range(MLRange(lower: low, upper: high, isClosed: false))
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        CrystalLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        // `@name` はインスタンス変数。
        guard name.hasPrefix("@") else { return nil }
        guard let object = value.asObject else { return nil }
        return object.fields[.string(String(name.dropFirst()))] ?? .unit
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try CrystalLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

enum CrystalLibrary {
    static func install(into environment: MLEnvironment, semantics: CrystalSemantics) {
        func define(_ name: String, _ arity: ClosedRange<Int>,
                    _ impl: @escaping MLFunction.MLNativeImpl) {
            environment.define(name, .function(.native(name, arity, impl)), isConstant: true)
        }

        define("puts", 0...16) { context in
            if context.arguments.isEmpty {
                context.interpreter.write("\n")
                return .unit
            }
            for argument in context.arguments {
                // 配列を渡すと 1 要素ずつ書き出す。
                if let array = argument.asArray {
                    for element in array.elements {
                        context.interpreter.write(semantics.display(element) + "\n")
                    }
                    continue
                }
                context.interpreter.write(semantics.display(argument) + "\n")
            }
            return .unit
        }
        define("print", 0...16) { context in
            context.interpreter.write(context.arguments.map { semantics.display($0) }.joined())
            return .unit
        }
        define("p", 0...16) { context in
            context.interpreter.write(
                context.arguments.map { semantics.inspect($0) }.joined(separator: " ") + "\n")
            return .unit
        }
        define("pp", 0...16) { context in
            context.interpreter.write(
                context.arguments.map { semantics.inspect($0) }.joined(separator: " ") + "\n")
            return .unit
        }
        define("printf", 1...16) { context in
            let pattern = try context.requireString(0, "printf")
            context.interpreter.write(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
            return .unit
        }
        define("sprintf", 1...16) { context in
            let pattern = try context.requireString(0, "sprintf")
            return .string(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
        }
        define("gets", 0...1) { context in
            guard let line = context.interpreter.input.nextLine() else { return .unit }
            return .string(line)
        }
        define("raise", 0...2) { context in
            throw MLError.runtime(context.arguments.map { semantics.display($0) }.joined())
        }
        define("rand", 0...1) { context in
            if let limit = context.optionalArgument(0)?.asInt, limit > 0 {
                return .int(Int64.random(in: 0..<limit))
            }
            return .double(Double.random(in: 0..<1))
        }
        define("typeof", 1...1) { context in
            .string(semantics.typeName(of: context.argument(0)))
        }
        define("Exception", 0...1) { context in
            let object = MLObject(typeName: "Exception")
            object.fields[.string("message")] =
                .string(context.optionalArgument(0)?.asString ?? "")
            object.fields[.string("#types")] = .array(MLArray([.string("Exception")]))
            return .object(object)
        }

        let math = MLObject(typeName: "Math")
        math.fields[.string("PI")] = .double(Double.pi)
        math.fields[.string("E")] = .double(M_E)
        for (name, implementation) in MLStdlib.mathFunctions {
            math.fields[.string(name)] = .function(.native(name, 1...1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            })
        }
        environment.define("Math", .object(math), isConstant: true)

        for name in ["Array", "Hash", "String", "Int32", "Int64", "Float64", "Bool",
                     "Symbol", "Char", "Nil"] {
            environment.define(name, .string(name), isConstant: true)
        }
    }

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: CrystalSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch name {
        case "to_s", "to_str":
            return .string(semantics.display(receiver))
        case "inspect":
            return .string(semantics.inspect(receiver))
        case "nil?": return .bool(receiver.isUnit)
        case "is_a?", "isa?":
            guard let typeName = context.argument(0).asString else { return .bool(false) }
            return .bool(interpreter.matchesType(receiver, typeName)
                         || semantics.typeName(of: receiver) == typeName)
        case "class": return .string(semantics.typeName(of: receiver))
        case "hash": return .int(Int64(semantics.display(receiver).hashValue & 0x7fffffff))
        case "==": return .bool(semantics.areEqual(receiver, context.argument(0)))
        case "dup", "clone": return receiver.deepCopy()
        default:
            break
        }

        switch receiver.forced {
        case .array(let array):
            switch name {
            case "each":
                let body = try context.requireFunction(0, "each")
                for element in array.elements {
                    _ = try interpreter.callFunction(body, arguments: [element])
                }
                return receiver
            case "each_with_index":
                let body = try context.requireFunction(0, "each_with_index")
                for (index, element) in array.elements.enumerated() {
                    _ = try interpreter.callFunction(body,
                                                     arguments: [element, .int(Int64(index))])
                }
                return receiver
            case "map":
                return try MLStdlib.callMethod(on: .array(array), name: "map", context: context)
            case "select":
                return try MLStdlib.callMethod(on: .array(array), name: "filter",
                                               context: context)
            case "reject":
                return try MLStdlib.callMethod(on: .array(array), name: "reject",
                                               context: context)
            case "reduce", "inject":
                return try MLStdlib.callMethod(on: .array(array), name: "reduce",
                                               context: context)
            case "size", "length": return .int(Int64(array.count))
            case "push", "<<":
                array.elements.append(context.argument(0))
                return .array(array)
            case "sort":
                return .array(MLArray(try MLStdlib.stableSorted(
                    array.elements, interpreter: interpreter,
                    comparator: context.optionalArgument(0)?.asFunction)))
            case "sort!":
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: interpreter,
                    comparator: context.optionalArgument(0)?.asFunction)
                return .array(array)
            case "sort_by":
                let key = try context.requireFunction(0, "sort_by")
                return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                                interpreter: interpreter,
                                                                comparator: key,
                                                                byKey: true)))
            case "includes?":
                let target = context.argument(0)
                return .bool(array.elements.contains { semantics.areEqual($0, target) })
            case "empty?": return .bool(array.elements.isEmpty)
            case "any?":
                guard context.arguments.isEmpty == false else {
                    return .bool(!array.elements.isEmpty)
                }
                return try MLStdlib.callMethod(on: .array(array), name: "any",
                                               context: context)
            case "all?":
                return try MLStdlib.callMethod(on: .array(array), name: "all",
                                               context: context)
            case "sum", "join", "first", "last", "min", "max", "reverse", "uniq",
                 "flatten", "index", "count", "zip", "compact":
                if name == "uniq" {
                    return try MLStdlib.callMethod(on: .array(array), name: "distinct",
                                                   context: context)
                }
                if name == "index" {
                    return try MLStdlib.callMethod(on: .array(array), name: "indexOf",
                                                   context: context)
                }
                if name == "compact" {
                    return .array(MLArray(array.elements.filter { !$0.isUnit }))
                }
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            default:
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            }
        case .map(let map):
            switch name {
            case "each":
                let body = try context.requireFunction(0, "each")
                for (key, value) in map.pairs {
                    _ = try interpreter.callFunction(body, arguments: [key.asValue, value])
                }
                return receiver
            case "size", "length": return .int(Int64(map.count))
            case "has_key?":
                guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
                return .bool(map.contains(key))
            case "keys": return .array(MLArray(map.keys.map { $0.asValue }))
            case "values": return .array(MLArray(map.values))
            case "empty?": return .bool(map.isEmpty)
            case "fetch":
                guard let key = MLKey.from(context.argument(0)) else {
                    return context.optionalArgument(1) ?? .unit
                }
                return map[key] ?? context.optionalArgument(1) ?? .unit
            case "delete":
                guard let key = MLKey.from(context.argument(0)) else { return .unit }
                return map.removeValue(forKey: key) ?? .unit
            default:
                return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
            }
        case .string(let text):
            switch name {
            case "size", "length": return .int(Int64(text.count))
            case "upcase": return .string(text.uppercased())
            case "downcase": return .string(text.lowercased())
            case "capitalize":
                guard let first = text.first else { return .string(text) }
                return .string(String(first).uppercased() + text.dropFirst().lowercased())
            case "strip": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "chars": return .array(MLArray(text.map { .char($0) }))
            case "to_i":
                guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                    return .int(0)
                }
                return .int(value)
            case "to_f": return .double(Double(text.trimmingCharacters(in: .whitespaces)) ?? 0)
            case "empty?": return .bool(text.isEmpty)
            case "includes?":
                guard let needle = context.argument(0).asString else { return .bool(false) }
                return .bool(needle.isEmpty || text.contains(needle))
            case "starts_with?": return .bool(text.hasPrefix(context.argument(0).asString ?? ""))
            case "ends_with?": return .bool(text.hasSuffix(context.argument(0).asString ?? ""))
            case "each_char":
                let body = try context.requireFunction(0, "each_char")
                for character in text {
                    _ = try interpreter.callFunction(body, arguments: [.char(character)])
                }
                return receiver
            case "gsub":
                return .string(text.replacingOccurrences(
                    of: context.argument(0).asString ?? "",
                    with: context.argument(1).asString ?? ""))
            default:
                return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
            }
        case .int, .double:
            switch name {
            case "times":
                let body = try context.requireFunction(0, "times")
                for index in 0..<Swift.max(0, Int(receiver.asInt ?? 0)) {
                    _ = try interpreter.callFunction(body, arguments: [.int(Int64(index))])
                }
                return receiver
            case "upto":
                let limit = try context.requireInt(0, "upto")
                let body = try context.requireFunction(1, "upto")
                var value = receiver.asInt ?? 0
                while value <= limit {
                    _ = try interpreter.callFunction(body, arguments: [.int(value)])
                    value += 1
                }
                return receiver
            case "downto":
                let limit = try context.requireInt(0, "downto")
                let body = try context.requireFunction(1, "downto")
                var value = receiver.asInt ?? 0
                while value >= limit {
                    _ = try interpreter.callFunction(body, arguments: [.int(value)])
                    value -= 1
                }
                return receiver
            case "to_i": return .int(receiver.asInt ?? Int64(receiver.asDouble ?? 0))
            case "to_f": return .double(receiver.asDouble ?? 0)
            case "even?": return .bool((receiver.asInt ?? 0) % 2 == 0)
            case "odd?": return .bool((receiver.asInt ?? 0) % 2 != 0)
            case "abs":
                if case .int(let number) = receiver.forced {
                    return .int(number < 0 ? -number : number)
                }
                return .double(Swift.abs(receiver.asDouble ?? 0))
            default:
                return try MLStdlib.callMethod(on: receiver, name: name, context: context)
            }
        case .range(let range):
            let array = MLArray(range.elements.map { .int($0) })
            return try method(on: .array(array), name: name, context: context,
                              semantics: semantics)
        default:
            return nil
        }
    }
}
