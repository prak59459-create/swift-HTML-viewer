import Foundation

/// Erlang らしい振る舞い。
final class ErlangSemantics: MLSemantics {
    override var languageID: String { "erlang" }
    override var displayName: String { "内蔵 Erlang 処理系" }
    override var requiresDefinitionBeforeUse: Bool { false }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// `/` は常に小数。整数の割り算は `div`。
    override var divisionAlwaysProducesDouble: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .symbol(let name): return name == "true"
        case .unit: return false
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .int: return "integer"
        case .double: return "float"
        case .string: return "string"
        case .array: return "list"
        case .tuple: return "tuple"
        case .map: return "map"
        case .symbol, .bool: return "atom"
        case .function: return "fun"
        default: return "term"
        }
    }

    /// `~p` / `io:format` の書き方。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "undefined"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "$\(character)"
        case .symbol(let name): return name
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ",") + "]"
        case .tuple(let items):
            return "{" + items.map { display($0) }.joined(separator: ",") + "}"
        case .map(let map):
            return "#{" + map.pairs.map { "\(display($0.key.asValue)) => \(display($0.value))" }
                .joined(separator: ",") + "}"
        case .function: return "#Fun<>"
        default: return MLDisplay.plain(value, semantics: self)
        }
    }

    /// `~s` は文字列をそのまま出す。
    override func stringify(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return text
        case .symbol(let name): return name
        case .array(let array): return array.elements.map { stringify($0) }.joined()
        default: return display(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value)) + ".0"
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "++":
            var elements = lhs.asArray?.elements ?? []
            if lhs.asArray == nil, let text = lhs.asString {
                if let right = rhs.asString { return .string(text + right) }
                elements = text.map { .char($0) }
            }
            elements += rhs.asArray?.elements ?? [rhs.forced]
            return .array(MLArray(elements))
        case "--":
            var elements = lhs.asArray?.elements ?? [lhs.forced]
            for value in rhs.asArray?.elements ?? [rhs.forced] {
                if let position = elements.firstIndex(where: {
                    MLOperations.strictEquals($0, value, semantics: self)
                }) { elements.remove(at: position) }
            }
            return .array(MLArray(elements))
        case "=:=", "==":
            return .bool(MLOperations.strictEquals(lhs, rhs, semantics: self))
        case "=/=", "/=":
            return .bool(!MLOperations.strictEquals(lhs, rhs, semantics: self))
        case "=<":
            guard let order = compare(lhs, rhs) else { return .bool(false) }
            return .bool(order <= 0)
        case "div":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            guard right != 0 else { throw MLError.thrown(.symbol("badarith")) }
            return .int(left / right)
        case "rem":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            guard right != 0 else { throw MLError.thrown(.symbol("badarith")) }
            return .int(left % right)
        case "band":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left & right)
        case "bor":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left | right)
        case "bxor":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left ^ right)
        case "bsl":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left << right)
        case "bsr":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left >> right)
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        ErlangLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }
}

/// Erlang の標準モジュール (よく使うところ)。
enum ErlangLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func module(_ name: String, _ entries: [(String, MLValue)]) -> MLValue {
        let object = MLObject(typeName: name)
        for (key, value) in entries { object.fields[.string(key)] = value }
        return .object(object)
    }

    static func items(_ value: MLValue) -> [MLValue] {
        if let array = value.asArray { return array.elements }
        if value.isUnit { return [] }
        return [value.forced]
    }

    /// `io:format` の書式。
    static func format(_ pattern: String, _ arguments: [MLValue],
                       semantics: ErlangSemantics) -> String {
        var result = ""
        var index = 0
        let characters = Array(pattern)
        var position = 0
        while position < characters.count {
            guard characters[position] == "~" else {
                result.append(characters[position])
                position += 1
                continue
            }
            position += 1
            // 幅の指定は読み飛ばす。
            while position < characters.count,
                  characters[position].isNumber || characters[position] == "." {
                position += 1
            }
            guard position < characters.count else { break }
            let directive = characters[position]
            position += 1
            switch directive {
            case "p", "w", "P", "W":
                if index < arguments.count {
                    result += semantics.display(arguments[index])
                    index += 1
                }
            case "s":
                if index < arguments.count {
                    result += semantics.stringify(arguments[index])
                    index += 1
                }
            case "b", "d", "B":
                if index < arguments.count {
                    result += String(arguments[index].asInt
                                        ?? Int64(arguments[index].asDouble ?? 0))
                    index += 1
                }
            case "f", "e", "g":
                if index < arguments.count {
                    let number = arguments[index].asDouble
                        ?? Double(arguments[index].asInt ?? 0)
                    result += String(format: "%f", number)
                    index += 1
                }
            case "n":
                result += "\n"
            case "~":
                result += "~"
            default:
                result.append(directive)
            }
        }
        return result
    }

    static func install(into environment: MLEnvironment, semantics: ErlangSemantics,
                        interpreter: MLInterpreter) {
        environment.define("io", module("io", [
            ("format", function("format", 1...2) { context in
                let pattern = context.argument(0).asString ?? ""
                let arguments = context.optionalArgument(1).map { items($0) } ?? []
                context.interpreter.write(format(pattern, arguments, semantics: semantics))
                return .symbol("ok")
            }),
            ("fwrite", function("fwrite", 1...2) { context in
                let pattern = context.argument(0).asString ?? ""
                let arguments = context.optionalArgument(1).map { items($0) } ?? []
                context.interpreter.write(format(pattern, arguments, semantics: semantics))
                return .symbol("ok")
            }),
            ("put_chars", function("put_chars", 1) { context in
                context.interpreter.write(semantics.stringify(context.argument(0)))
                return .symbol("ok")
            }),
            ("get_line", function("get_line", 0...1) { context in
                .string((context.interpreter.input.nextLine() ?? "") + "\n")
            })
        ]))

        environment.define("lists", module("lists", [
            ("map", function("map", 2) { context in
                let body = try context.requireFunction(0, "lists:map")
                var result: [MLValue] = []
                for element in items(context.argument(1)) {
                    result.append(try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location))
                }
                return .array(MLArray(result))
            }),
            ("filter", function("filter", 2) { context in
                let body = try context.requireFunction(0, "lists:filter")
                var result: [MLValue] = []
                for element in items(context.argument(1)) {
                    let kept = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try semantics.isTruthy(kept) { result.append(element) }
                }
                return .array(MLArray(result))
            }),
            ("foldl", function("foldl", 3) { context in
                let body = try context.requireFunction(0, "lists:foldl")
                var accumulator = context.argument(1)
                for element in items(context.argument(2)) {
                    accumulator = try context.interpreter.callFunction(
                        body, arguments: [element, accumulator], location: context.location)
                }
                return accumulator
            }),
            ("foldr", function("foldr", 3) { context in
                let body = try context.requireFunction(0, "lists:foldr")
                var accumulator = context.argument(1)
                for element in items(context.argument(2)).reversed() {
                    accumulator = try context.interpreter.callFunction(
                        body, arguments: [element, accumulator], location: context.location)
                }
                return accumulator
            }),
            ("sum", function("sum", 1) { context in
                var total: Int64 = 0
                var double = 0.0
                var isInteger = true
                for element in items(context.argument(0)) {
                    if let number = element.asInt { total += number }
                    else if let number = element.asDouble {
                        double += number
                        isInteger = false
                    }
                }
                return isInteger ? .int(total) : .double(double + Double(total))
            }),
            ("reverse", function("reverse", 1) { context in
                .array(MLArray(items(context.argument(0)).reversed()))
            }),
            ("sort", function("sort", 1...2) { context in
                if context.arguments.count == 2 {
                    return .array(MLArray(try MLStdlib.stableSorted(
                        items(context.argument(1)), interpreter: context.interpreter,
                        comparator: context.argument(0).asFunction)))
                }
                return .array(MLArray(try MLStdlib.stableSorted(
                    items(context.argument(0)), interpreter: context.interpreter,
                    comparator: nil)))
            }),
            ("length", function("length", 1) { context in
                .int(Int64(items(context.argument(0)).count))
            }),
            ("nth", function("nth", 2) { context in
                let elements = items(context.argument(1))
                let index = Int(context.argument(0).asInt ?? 1) - 1
                return index >= 0 && index < elements.count ? elements[index] : .unit
            }),
            ("seq", function("seq", 2...3) { context in
                let from = context.argument(0).asInt ?? 0
                let to = context.argument(1).asInt ?? 0
                let step = context.optionalArgument(2)?.asInt ?? 1
                var elements: [MLValue] = []
                var current = from
                while step > 0 ? current <= to : current >= to {
                    elements.append(.int(current))
                    current += step == 0 ? 1 : step
                }
                return .array(MLArray(elements))
            }),
            ("member", function("member", 2) { context in
                .bool(items(context.argument(1)).contains {
                    MLOperations.strictEquals($0, context.argument(0), semantics: semantics)
                })
            }),
            ("max", function("max", 1) { context in
                try extreme(items(context.argument(0)), keepLarger: true,
                            semantics: semantics)
            }),
            ("min", function("min", 1) { context in
                try extreme(items(context.argument(0)), keepLarger: false,
                            semantics: semantics)
            }),
            ("concat", function("concat", 1) { context in
                .string(items(context.argument(0)).map { semantics.stringify($0) }.joined())
            })
        ]))

        environment.define("string", module("string", [
            ("to_upper", function("to_upper", 1) { context in
                .string(semantics.stringify(context.argument(0)).uppercased())
            }),
            ("to_lower", function("to_lower", 1) { context in
                .string(semantics.stringify(context.argument(0)).lowercased())
            }),
            ("len", function("len", 1) { context in
                .int(Int64(semantics.stringify(context.argument(0)).count))
            }),
            ("join", function("join", 2) { context in
                let separator = semantics.stringify(context.argument(1))
                return .string(items(context.argument(0))
                    .map { semantics.stringify($0) }.joined(separator: separator))
            }),
            ("tokens", function("tokens", 2) { context in
                let text = semantics.stringify(context.argument(0))
                let separators = Set(semantics.stringify(context.argument(1)))
                return .array(MLArray(text.split(whereSeparator: { separators.contains($0) })
                    .map { .string(String($0)) }))
            }),
            ("concat", function("concat", 2) { context in
                .string(semantics.stringify(context.argument(0))
                            + semantics.stringify(context.argument(1)))
            })
        ]))

        environment.define("maps", module("maps", [
            ("get", function("get", 2...3) { context in
                guard let map = context.argument(1).asMap,
                      let key = MLKey.from(context.argument(0)) else {
                    return context.optionalArgument(2) ?? .unit
                }
                return map[key] ?? context.optionalArgument(2) ?? .unit
            }),
            ("put", function("put", 3) { context in
                let map = MLMap()
                if let original = context.argument(2).asMap {
                    for pair in original.pairs { map[pair.key] = pair.value }
                }
                if let key = MLKey.from(context.argument(0)) {
                    map[key] = context.argument(1)
                }
                return .map(map)
            }),
            ("keys", function("keys", 1) { context in
                .array(MLArray(context.argument(0).asMap?.pairs.map { $0.key.asValue } ?? []))
            }),
            ("values", function("values", 1) { context in
                .array(MLArray(context.argument(0).asMap?.pairs.map { $0.value } ?? []))
            }),
            ("size", function("size", 1) { context in
                .int(Int64(context.argument(0).asMap?.count ?? 0))
            })
        ]))

        // 組み込み関数 (BIF)。
        environment.define("length", function("length", 1) { context in
            .int(Int64(items(context.argument(0)).count))
        })
        environment.define("hd", function("hd", 1) { context in
            items(context.argument(0)).first ?? .unit
        })
        environment.define("tl", function("tl", 1) { context in
            .array(MLArray(Array(items(context.argument(0)).dropFirst())))
        })
        environment.define("element", function("element", 2) { context in
            guard case .tuple(let elements) = context.argument(1).forced else { return .unit }
            let index = Int(context.argument(0).asInt ?? 1) - 1
            return index >= 0 && index < elements.count ? elements[index] : .unit
        })
        environment.define("tuple_size", function("tuple_size", 1) { context in
            guard case .tuple(let elements) = context.argument(0).forced else { return .int(0) }
            return .int(Int64(elements.count))
        })
        environment.define("#cons", function("#cons", 2) { context in
            var elements = items(context.argument(0))
            elements += items(context.argument(1))
            return .array(MLArray(elements))
        })
        environment.define("abs", function("abs", 1) { context in
            if let number = context.argument(0).asInt { return .int(Swift.abs(number)) }
            return .double(Swift.abs(context.argument(0).asDouble ?? 0))
        })
        environment.define("integer_to_list", function("integer_to_list", 1) { context in
            .string(String(context.argument(0).asInt ?? 0))
        })
        environment.define("list_to_integer", function("list_to_integer", 1) { context in
            .int(Int64(semantics.stringify(context.argument(0))) ?? 0)
        })
        environment.define("atom_to_list", function("atom_to_list", 1) { context in
            .string(semantics.stringify(context.argument(0)))
        })
        environment.define("is_atom", function("is_atom", 1) { context in
            if case .symbol = context.argument(0) { return .bool(true) }
            if case .bool = context.argument(0) { return .bool(true) }
            return .bool(false)
        })
        environment.define("is_list", function("is_list", 1) { context in
            .bool(context.argument(0).asArray != nil)
        })
        environment.define("is_integer", function("is_integer", 1) { context in
            .bool(context.argument(0).asInt != nil)
        })
        environment.define("is_tuple", function("is_tuple", 1) { context in
            if case .tuple = context.argument(0).forced { return .bool(true) }
            return .bool(false)
        })
        environment.define("throw", function("throw", 1) { context in
            throw MLError.thrown(context.argument(0))
        })
        environment.define("error", function("error", 1) { context in
            throw MLError.thrown(context.argument(0))
        })
        environment.define("trunc", function("trunc", 1) { context in
            .int(Int64(context.argument(0).asDouble ?? Double(context.argument(0).asInt ?? 0)))
        })
        environment.define("round", function("round", 1) { context in
            .int(Int64((context.argument(0).asDouble
                            ?? Double(context.argument(0).asInt ?? 0)).rounded()))
        })
        environment.define("math", module("math", [
            ("sqrt", function("sqrt", 1) { context in
                .double(Foundation.sqrt(context.argument(0).asDouble
                                            ?? Double(context.argument(0).asInt ?? 0)))
            }),
            ("pow", function("pow", 2) { context in
                .double(Foundation.pow(context.argument(0).asDouble
                                            ?? Double(context.argument(0).asInt ?? 0),
                                       context.argument(1).asDouble
                                            ?? Double(context.argument(1).asInt ?? 0)))
            }),
            ("pi", .double(Double.pi))
        ]))
    }

    private static func extreme(_ elements: [MLValue], keepLarger: Bool,
                                semantics: ErlangSemantics) throws -> MLValue {
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
