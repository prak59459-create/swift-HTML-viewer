import Foundation

/// OCaml らしい振る舞い。
final class OCamlSemantics: MLSemantics {
    override var languageID: String { "ocaml" }
    override var displayName: String { "内蔵 OCaml 処理系" }
    override var requiresDefinitionBeforeUse: Bool { true }
    override var assignmentDefinesNewVariables: Bool { true }
    override var integerDivisionTruncatesTowardZero: Bool { true }
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
        case .unit: return "unit"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "string"
        case .char: return "char"
        case .array: return "list"
        case .tuple: return "tuple"
        case .map: return "record"
        case .function: return "function"
        case .object(let object): return object.typeName
        default: return "value"
        }
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: "; ") + "]"
        case .tuple(let items):
            return "(" + items.map { display($0) }.joined(separator: ", ") + ")"
        case .map(let map):
            return "{" + map.pairs.map { "\($0.key.asValue.asString ?? "") = \(display($0.value))" }
                .joined(separator: "; ") + "}"
        case .object(let object):
            guard let caseName = object.caseName else { return object.typeName }
            if object.payload.isEmpty { return caseName }
            return caseName + " (" + object.payload.map { display($0) }
                .joined(separator: ", ") + ")"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "neg_infinity" : "infinity" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value)) + "."
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    /// OCaml の浮動小数点用の演算子と、文字列・リストの連結。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "+.", "-.", "*.", "/.":
            let left = lhs.asDouble ?? Double(lhs.asInt ?? 0)
            let right = rhs.asDouble ?? Double(rhs.asInt ?? 0)
            switch op {
            case "+.": return .double(left + right)
            case "-.": return .double(left - right)
            case "*.": return .double(left * right)
            default:
                guard right != 0 else { return .double(.infinity) }
                return .double(left / right)
            }
        case "^":
            return .string(display(lhs) + display(rhs))
        case "@":
            var elements = lhs.asArray?.elements ?? [lhs.forced]
            elements += rhs.asArray?.elements ?? [rhs.forced]
            return .array(MLArray(elements))
        case "::":
            var elements = [lhs.forced]
            elements += rhs.asArray?.elements ?? []
            return .array(MLArray(elements))
        case "=":
            return .bool(MLOperations.strictEquals(lhs, rhs, semantics: self))
        case "<>":
            return .bool(!MLOperations.strictEquals(lhs, rhs, semantics: self))
        case "mod":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            guard right != 0 else { throw MLError.thrown(.string("Division_by_zero")) }
            return .int(left % right)
        case "land":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left & right)
        case "lor":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left | right)
        case "lxor":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left ^ right)
        case "lsl":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left << right)
        case "lsr":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left >> right)
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        OCamlLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }
}

/// OCaml の標準ライブラリ (よく使うところ)。
enum OCamlLibrary {

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

    /// `Printf.printf` の書式。
    static func format(_ pattern: String, _ arguments: [MLValue],
                       semantics: OCamlSemantics) -> String {
        var result = ""
        var index = 0
        let characters = Array(pattern)
        var position = 0
        while position < characters.count {
            guard characters[position] == "%" else {
                result.append(characters[position])
                position += 1
                continue
            }
            position += 1
            var flags = ""
            while position < characters.count,
                  "0123456789.-+ ".contains(characters[position]) {
                flags.append(characters[position])
                position += 1
            }
            guard position < characters.count else { break }
            let directive = characters[position]
            position += 1
            func next() -> MLValue? {
                guard index < arguments.count else { return nil }
                defer { index += 1 }
                return arguments[index]
            }
            switch directive {
            case "d", "i", "u":
                if let value = next() {
                    result += pad(String(value.asInt ?? Int64(value.asDouble ?? 0)),
                                  flags: flags)
                }
            case "s":
                if let value = next() { result += pad(semantics.display(value), flags: flags) }
            case "f", "e", "g":
                if let value = next() {
                    let number = value.asDouble ?? Double(value.asInt ?? 0)
                    let decimals = flags.contains(".")
                        ? Int(flags.split(separator: ".").last.map(String.init) ?? "6") ?? 6
                        : 6
                    result += String(format: "%.\(decimals)f", number)
                }
            case "b", "B":
                if let value = next() {
                    result += (try? semantics.isTruthy(value)) == true ? "true" : "false"
                }
            case "c":
                if let value = next() { result += semantics.display(value) }
            case "%":
                result += "%"
            default:
                result.append(directive)
            }
        }
        return result
    }

    private static func pad(_ text: String, flags: String) -> String {
        guard let width = Int(flags.trimmingCharacters(in: CharacterSet(charactersIn: "-."))),
              width > text.count else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return flags.hasPrefix("-") ? text + padding : padding + text
    }

    static func install(into environment: MLEnvironment, semantics: OCamlSemantics,
                        interpreter: MLInterpreter) {
        environment.define("print_endline", function("print_endline", 1) { context in
            context.interpreter.write(semantics.display(context.argument(0)) + "\n")
            return .unit
        })
        environment.define("print_string", function("print_string", 1) { context in
            context.interpreter.write(semantics.display(context.argument(0)))
            return .unit
        })
        environment.define("print_int", function("print_int", 1) { context in
            context.interpreter.write(String(context.argument(0).asInt ?? 0))
            return .unit
        })
        environment.define("print_newline", function("print_newline", 0...1) { context in
            context.interpreter.write("\n")
            return .unit
        })
        environment.define("read_line", function("read_line", 0...1) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })
        environment.define("string_of_int", function("string_of_int", 1) { context in
            .string(String(context.argument(0).asInt ?? 0))
        })
        environment.define("int_of_string", function("int_of_string", 1) { context in
            .int(Int64(semantics.display(context.argument(0))) ?? 0)
        })
        environment.define("string_of_float", function("string_of_float", 1) { context in
            .string(semantics.formatDouble(context.argument(0).asDouble ?? 0))
        })
        environment.define("float_of_int", function("float_of_int", 1) { context in
            .double(Double(context.argument(0).asInt ?? 0))
        })
        environment.define("int_of_float", function("int_of_float", 1) { context in
            .int(Int64(context.argument(0).asDouble ?? 0))
        })
        environment.define("abs", function("abs", 1) { context in
            .int(Swift.abs(context.argument(0).asInt ?? 0))
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
        environment.define("compare", function("compare", 2) { context in
            .int(Int64(semantics.compare(context.argument(0), context.argument(1)) ?? 0))
        })
        environment.define("succ", function("succ", 1) { context in
            .int((context.argument(0).asInt ?? 0) + 1)
        })
        environment.define("pred", function("pred", 1) { context in
            .int((context.argument(0).asInt ?? 0) - 1)
        })
        environment.define("failwith", function("failwith", 1) { context in
            throw MLError.thrown(.string(semantics.display(context.argument(0))))
        })
        environment.define("raise", function("raise", 1) { context in
            throw MLError.thrown(context.argument(0))
        })
        environment.define("ignore", function("ignore", 1) { _ in .unit })

        environment.define("Printf", module("Printf", [
            ("printf", function("printf", 1...32) { context in
                let pattern = context.argument(0).asString ?? ""
                context.interpreter.write(format(pattern,
                                                 Array(context.arguments.dropFirst()),
                                                 semantics: semantics))
                return .unit
            }),
            ("sprintf", function("sprintf", 1...32) { context in
                let pattern = context.argument(0).asString ?? ""
                return .string(format(pattern, Array(context.arguments.dropFirst()),
                                      semantics: semantics))
            })
        ]))

        environment.define("List", module("List", [
            ("map", function("map", 2) { context in
                let body = try context.requireFunction(0, "List.map")
                var result: [MLValue] = []
                for element in items(context.argument(1)) {
                    result.append(try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location))
                }
                return .array(MLArray(result))
            }),
            ("filter", function("filter", 2) { context in
                let body = try context.requireFunction(0, "List.filter")
                var result: [MLValue] = []
                for element in items(context.argument(1)) {
                    let kept = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try semantics.isTruthy(kept) { result.append(element) }
                }
                return .array(MLArray(result))
            }),
            ("fold_left", function("fold_left", 3) { context in
                let body = try context.requireFunction(0, "List.fold_left")
                var accumulator = context.argument(1)
                for element in items(context.argument(2)) {
                    accumulator = try context.interpreter.callFunction(
                        body, arguments: [accumulator, element], location: context.location)
                }
                return accumulator
            }),
            ("fold_right", function("fold_right", 3) { context in
                let body = try context.requireFunction(0, "List.fold_right")
                var accumulator = context.argument(2)
                for element in items(context.argument(1)).reversed() {
                    accumulator = try context.interpreter.callFunction(
                        body, arguments: [element, accumulator], location: context.location)
                }
                return accumulator
            }),
            ("iter", function("iter", 2) { context in
                let body = try context.requireFunction(0, "List.iter")
                for element in items(context.argument(1)) {
                    _ = try context.interpreter.callFunction(body, arguments: [element],
                                                             location: context.location)
                }
                return .unit
            }),
            ("length", function("length", 1) { context in
                .int(Int64(items(context.argument(0)).count))
            }),
            ("rev", function("rev", 1) { context in
                .array(MLArray(items(context.argument(0)).reversed()))
            }),
            ("hd", function("hd", 1) { context in
                items(context.argument(0)).first ?? .unit
            }),
            ("tl", function("tl", 1) { context in
                .array(MLArray(Array(items(context.argument(0)).dropFirst())))
            }),
            ("nth", function("nth", 2) { context in
                let elements = items(context.argument(0))
                let index = Int(context.argument(1).asInt ?? 0)
                return index >= 0 && index < elements.count ? elements[index] : .unit
            }),
            ("sort", function("sort", 2) { context in
                .array(MLArray(try MLStdlib.stableSorted(
                    items(context.argument(1)), interpreter: context.interpreter,
                    comparator: context.argument(0).asFunction)))
            }),
            ("mem", function("mem", 2) { context in
                .bool(items(context.argument(1)).contains {
                    MLOperations.strictEquals($0, context.argument(0), semantics: semantics)
                })
            }),
            ("append", function("append", 2) { context in
                .array(MLArray(items(context.argument(0)) + items(context.argument(1))))
            }),
            ("init", function("init", 2) { context in
                let count = Int(context.argument(0).asInt ?? 0)
                let body = try context.requireFunction(1, "List.init")
                var result: [MLValue] = []
                for index in 0..<Swift.max(0, count) {
                    result.append(try context.interpreter.callFunction(
                        body, arguments: [.int(Int64(index))], location: context.location))
                }
                return .array(MLArray(result))
            }),
            ("exists", function("exists", 2) { context in
                let body = try context.requireFunction(0, "List.exists")
                for element in items(context.argument(1)) {
                    let found = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try semantics.isTruthy(found) { return .bool(true) }
                }
                return .bool(false)
            }),
            ("for_all", function("for_all", 2) { context in
                let body = try context.requireFunction(0, "List.for_all")
                for element in items(context.argument(1)) {
                    let found = try context.interpreter.callFunction(
                        body, arguments: [element], location: context.location)
                    if try !semantics.isTruthy(found) { return .bool(false) }
                }
                return .bool(true)
            })
        ]))

        environment.define("String", module("String", [
            ("length", function("length", 1) { context in
                .int(Int64(semantics.display(context.argument(0)).count))
            }),
            ("uppercase_ascii", function("uppercase_ascii", 1) { context in
                .string(semantics.display(context.argument(0)).uppercased())
            }),
            ("lowercase_ascii", function("lowercase_ascii", 1) { context in
                .string(semantics.display(context.argument(0)).lowercased())
            }),
            ("concat", function("concat", 2) { context in
                let separator = semantics.display(context.argument(0))
                return .string(items(context.argument(1))
                    .map { semantics.display($0) }.joined(separator: separator))
            }),
            ("sub", function("sub", 3) { context in
                let characters = Array(semantics.display(context.argument(0)))
                let start = Int(context.argument(1).asInt ?? 0)
                let count = Int(context.argument(2).asInt ?? 0)
                guard start >= 0, start <= characters.count else { return .string("") }
                let end = Swift.min(characters.count, start + Swift.max(0, count))
                return .string(String(characters[start..<end]))
            }),
            ("split_on_char", function("split_on_char", 2) { context in
                let separator = semantics.display(context.argument(0))
                let text = semantics.display(context.argument(1))
                return .array(MLArray(text.components(separatedBy: separator)
                    .map { .string($0) }))
            }),
            ("trim", function("trim", 1) { context in
                .string(semantics.display(context.argument(0))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }),
            ("contains", function("contains", 2) { context in
                .bool(semantics.display(context.argument(0))
                    .contains(semantics.display(context.argument(1))))
            })
        ]))

        environment.define("Array", module("Array", [
            ("length", function("length", 1) { context in
                .int(Int64(items(context.argument(0)).count))
            }),
            ("of_list", function("of_list", 1) { context in
                .array(MLArray(items(context.argument(0))))
            }),
            ("to_list", function("to_list", 1) { context in
                .array(MLArray(items(context.argument(0))))
            })
        ]))
    }
}
