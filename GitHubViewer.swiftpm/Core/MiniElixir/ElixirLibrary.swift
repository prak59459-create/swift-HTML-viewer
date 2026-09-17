import Foundation

/// Elixir らしい振る舞い。
final class ElixirSemantics: MLSemantics {
    override var languageID: String { "elixir" }
    override var displayName: String { "内蔵 Elixir 処理系" }
    override var requiresDefinitionBeforeUse: Bool { false }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    override var divisionAlwaysProducesDouble: Bool { true }

    /// 偽は `false` と `nil` だけ。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        case .symbol(let name): return name != "nil" && name != "false"
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "float"
        case .string: return "binary"
        case .array: return "list"
        case .map: return "map"
        case .tuple: return "tuple"
        case .symbol: return "atom"
        case .function: return "function"
        case .object(let object): return object.typeName
        default: return "term"
        }
    }

    /// `IO.puts` が使う書き方。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .symbol(let name): return name
        case .array(let array): return array.elements.map { display($0) }.joined()
        default: return inspect(value)
        }
    }

    /// `IO.inspect` が使う書き方。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "\"\(character)\""
        case .symbol(let name): return ":" + name
        case .array(let array):
            return "[" + array.elements.map { inspect($0) }.joined(separator: ", ") + "]"
        case .tuple(let items):
            return "{" + items.map { inspect($0) }.joined(separator: ", ") + "}"
        case .map(let map):
            let pairs = map.pairs.map { pair -> String in
                if case .symbol(let name) = pair.key.asValue.forced {
                    return "\(name): \(inspect(pair.value))"
                }
                return "\(inspect(pair.key.asValue)) => \(inspect(pair.value))"
            }
            return "%{" + pairs.joined(separator: ", ") + "}"
        case .function: return "#Function<>"
        default: return MLDisplay.plain(value, semantics: self)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value)) + ".0"
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    /// Elixir だけの演算子。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "<>":
            return .string(display(lhs) + display(rhs))
        case "++":
            var elements = lhs.asArray?.elements ?? [lhs.forced]
            elements += rhs.asArray?.elements ?? [rhs.forced]
            return .array(MLArray(elements))
        case "--":
            var elements = lhs.asArray?.elements ?? [lhs.forced]
            for value in rhs.asArray?.elements ?? [rhs.forced] {
                if let position = elements.firstIndex(where: {
                    MLOperations.strictEquals($0, value, semantics: self)
                }) {
                    elements.remove(at: position)
                }
            }
            return .array(MLArray(elements))
        case "in":
            let items = try MLOperations.iterate(rhs, semantics: self)
            return .bool(items.contains {
                MLOperations.strictEquals($0, lhs, semantics: self)
            })
        case "/":
            // `/` は常に小数。整数の割り算は `div`。
            let left = lhs.asDouble ?? Double(lhs.asInt ?? 0)
            let right = rhs.asDouble ?? Double(rhs.asInt ?? 0)
            guard right != 0 else { throw MLError.thrown(.string("ArithmeticError")) }
            return .double(left / right)
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        ElixirLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }

    /// `map.key` はアトムのキーで引く。
    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        guard let map = value.asMap else { return nil }
        return map[.symbol(name)] ?? map[.string(name)]
    }

    /// `map[:key]` / `list[0]`
    override func subscriptValue(of receiver: MLValue, index: MLValue,
                                 interpreter: MLInterpreter) throws -> MLValue? {
        guard let map = receiver.asMap, let key = MLKey.from(index) else { return nil }
        return map[key] ?? .unit
    }
}

/// Elixir の標準ライブラリ (よく使うところ)。
enum ElixirLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func namespace(_ typeName: String, _ entries: [(String, MLValue)]) -> MLValue {
        let object = MLObject(typeName: typeName)
        for (name, value) in entries { object.fields[.string(name)] = value }
        return .object(object)
    }

    static func items(_ value: MLValue) -> [MLValue] {
        if let array = value.asArray { return array.elements }
        if let map = value.asMap {
            return map.pairs.map { .tuple([$0.key.asValue, $0.value]) }
        }
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

    static func install(into environment: MLEnvironment, semantics: ElixirSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)

        environment.define("IO", namespace("IO", [
            ("puts", function("puts", 1) { context in
                context.interpreter.write(semantics.display(context.argument(0)) + "\n")
                return .symbol("ok")
            }),
            ("write", function("write", 1) { context in
                context.interpreter.write(semantics.display(context.argument(0)))
                return .symbol("ok")
            }),
            ("inspect", function("inspect", 1...2) { context in
                context.interpreter.write(semantics.inspect(context.argument(0)) + "\n")
                return context.argument(0)
            }),
            ("gets", function("gets", 0...1) { context in
                .string((context.interpreter.input.nextLine() ?? "") + "\n")
            })
        ]))

        environment.define("Enum", namespace("Enum", [
            ("map", function("map", 2) { context in
                let body = try context.requireFunction(1, "Enum.map")
                var result: [MLValue] = []
                for element in items(context.argument(0)) {
                    result.append(try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location))
                }
                return .array(MLArray(result))
            }),
            ("filter", function("filter", 2) { context in
                let body = try context.requireFunction(1, "Enum.filter")
                var result: [MLValue] = []
                for element in items(context.argument(0)) {
                    let kept = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try semantics.isTruthy(kept) { result.append(element) }
                }
                return .array(MLArray(result))
            }),
            ("reject", function("reject", 2) { context in
                let body = try context.requireFunction(1, "Enum.reject")
                var result: [MLValue] = []
                for element in items(context.argument(0)) {
                    let kept = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try !semantics.isTruthy(kept) { result.append(element) }
                }
                return .array(MLArray(result))
            }),
            ("reduce", function("reduce", 2...3) { context in
                let elements = items(context.argument(0))
                if context.arguments.count == 2 {
                    let body = try context.requireFunction(1, "Enum.reduce")
                    guard var accumulator = elements.first else { return .unit }
                    for element in elements.dropFirst() {
                        accumulator = try context.interpreter.callFunction(
                            body, arguments: [element, accumulator],
                            location: context.location)
                    }
                    return accumulator
                }
                let body = try context.requireFunction(2, "Enum.reduce")
                var accumulator = context.argument(1)
                for element in elements {
                    accumulator = try context.interpreter.callFunction(
                        body, arguments: [element, accumulator], location: context.location)
                }
                return accumulator
            }),
            ("sum", function("sum", 1) { context in
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
            }),
            ("count", function("count", 1) { context in
                .int(Int64(items(context.argument(0)).count))
            }),
            ("sort", function("sort", 1...2) { context in
                .array(MLArray(try MLStdlib.stableSorted(
                    items(context.argument(0)), interpreter: context.interpreter,
                    comparator: context.optionalArgument(1)?.asFunction)))
            }),
            ("reverse", function("reverse", 1) { context in
                .array(MLArray(items(context.argument(0)).reversed()))
            }),
            ("join", function("join", 1...2) { context in
                let separator = context.optionalArgument(1)?.asString ?? ""
                return .string(items(context.argument(0))
                    .map { semantics.display($0) }.joined(separator: separator))
            }),
            ("at", function("at", 2...3) { context in
                let elements = items(context.argument(0))
                let index = Int(context.argument(1).asInt ?? 0)
                guard index >= 0, index < elements.count else {
                    return context.optionalArgument(2) ?? .unit
                }
                return elements[index]
            }),
            ("member?", function("member?", 2) { context in
                .bool(items(context.argument(0)).contains {
                    MLOperations.strictEquals($0, context.argument(1), semantics: semantics)
                })
            }),
            ("with_index", function("with_index", 1) { context in
                .array(MLArray(items(context.argument(0)).enumerated()
                    .map { .tuple([$0.element, .int(Int64($0.offset))]) }))
            }),
            ("each", function("each", 2) { context in
                let body = try context.requireFunction(1, "Enum.each")
                for element in items(context.argument(0)) {
                    _ = try context.interpreter.callFunction(body, arguments: [element],
                                                             location: context.location)
                }
                return .symbol("ok")
            }),
            ("max", function("max", 1) { context in
                try extreme(items(context.argument(0)), keepLarger: true,
                            semantics: semantics)
            }),
            ("min", function("min", 1) { context in
                try extreme(items(context.argument(0)), keepLarger: false,
                            semantics: semantics)
            }),
            ("take", function("take", 2) { context in
                let count = Int(context.argument(1).asInt ?? 0)
                return .array(MLArray(Array(items(context.argument(0)).prefix(count))))
            }),
            ("uniq", function("uniq", 1) { context in
                var result: [MLValue] = []
                for element in items(context.argument(0)) {
                    if !result.contains(where: {
                        MLOperations.strictEquals($0, element, semantics: semantics)
                    }) { result.append(element) }
                }
                return .array(MLArray(result))
            })
        ]))

        environment.define("String", namespace("String", [
            ("upcase", function("upcase", 1) { context in
                .string(semantics.display(context.argument(0)).uppercased())
            }),
            ("downcase", function("downcase", 1) { context in
                .string(semantics.display(context.argument(0)).lowercased())
            }),
            ("length", function("length", 1) { context in
                .int(Int64(semantics.display(context.argument(0)).count))
            }),
            ("split", function("split", 1...2) { context in
                let text = semantics.display(context.argument(0))
                let separator = context.optionalArgument(1)
                    .map { semantics.display($0) } ?? " "
                return .array(MLArray(text.components(separatedBy: separator)
                    .map { .string($0) }))
            }),
            ("trim", function("trim", 1) { context in
                .string(semantics.display(context.argument(0))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }),
            ("reverse", function("reverse", 1) { context in
                .string(String(semantics.display(context.argument(0)).reversed()))
            }),
            ("contains?", function("contains?", 2) { context in
                .bool(semantics.display(context.argument(0))
                    .contains(semantics.display(context.argument(1))))
            }),
            ("to_integer", function("to_integer", 1) { context in
                .int(Int64(semantics.display(context.argument(0))) ?? 0)
            }),
            ("duplicate", function("duplicate", 2) { context in
                .string(String(repeating: semantics.display(context.argument(0)),
                               count: Int(max(0, context.argument(1).asInt ?? 0))))
            })
        ]))

        environment.define("Map", namespace("Map", [
            ("get", function("get", 2...3) { context in
                guard let map = context.argument(0).asMap,
                      let key = MLKey.from(context.argument(1)) else {
                    return context.optionalArgument(2) ?? .unit
                }
                return map[key] ?? context.optionalArgument(2) ?? .unit
            }),
            ("put", function("put", 3) { context in
                let map = MLMap()
                if let original = context.argument(0).asMap {
                    for pair in original.pairs { map[pair.key] = pair.value }
                }
                if let key = MLKey.from(context.argument(1)) {
                    map[key] = context.argument(2)
                }
                return .map(map)
            }),
            ("keys", function("keys", 1) { context in
                .array(MLArray(context.argument(0).asMap?.pairs.map { $0.key.asValue } ?? []))
            }),
            ("values", function("values", 1) { context in
                .array(MLArray(context.argument(0).asMap?.pairs.map { $0.value } ?? []))
            }),
            ("has_key?", function("has_key?", 2) { context in
                guard let map = context.argument(0).asMap,
                      let key = MLKey.from(context.argument(1)) else { return .bool(false) }
                return .bool(map[key] != nil)
            })
        ]))

        environment.define("Integer", namespace("Integer", [
            ("to_string", function("to_string", 1...2) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("parse", function("parse", 1) { context in
                let text = semantics.display(context.argument(0))
                guard let number = Int64(text) else { return .symbol("error") }
                return .tuple([.int(number), .string("")])
            })
        ]))

        environment.define("Kernel", namespace("Kernel", []))

        // よく使う関数はそのまま置く。
        environment.define("div", function("div", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.thrown(.string("ArithmeticError")) }
            return .int(left / right)
        })
        environment.define("rem", function("rem", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.thrown(.string("ArithmeticError")) }
            return .int(left % right)
        })
        environment.define("length", function("length", 1) { context in
            .int(Int64(items(context.argument(0)).count))
        })
        environment.define("hd", function("hd", 1) { context in
            items(context.argument(0)).first ?? .unit
        })
        environment.define("tl", function("tl", 1) { context in
            .array(MLArray(Array(items(context.argument(0)).dropFirst())))
        })
        environment.define("elem", function("elem", 2) { context in
            guard case .tuple(let elements) = context.argument(0).forced else { return .unit }
            let index = Int(context.argument(1).asInt ?? 0)
            return index >= 0 && index < elements.count ? elements[index] : .unit
        })
        environment.define("is_atom", function("is_atom", 1) { context in
            if case .symbol = context.argument(0) { return .bool(true) }
            return .bool(false)
        })
        environment.define("is_list", function("is_list", 1) { context in
            .bool(context.argument(0).asArray != nil)
        })
        environment.define("is_integer", function("is_integer", 1) { context in
            .bool(context.argument(0).asInt != nil)
        })
        environment.define("is_binary", function("is_binary", 1) { context in
            .bool(context.argument(0).asString != nil)
        })
        environment.define("to_string", function("to_string", 1) { context in
            .string(semantics.display(context.argument(0)))
        })
        environment.define("inspect", function("inspect", 1...2) { context in
            .string(semantics.inspect(context.argument(0)))
        })
        environment.define("abs", function("abs", 1) { context in
            if let number = context.argument(0).asInt { return .int(Swift.abs(number)) }
            return .double(Swift.abs(context.argument(0).asDouble ?? 0))
        })
        environment.define("raise", function("raise", 1...2) { context in
            throw MLError.thrown(.string(semantics.display(context.argument(0))))
        })
    }

    private static func extreme(_ elements: [MLValue], keepLarger: Bool,
                                semantics: ElixirSemantics) throws -> MLValue {
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
