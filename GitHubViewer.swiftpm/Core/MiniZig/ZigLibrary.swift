import Foundation

/// Zig らしい振る舞い。
final class ZigSemantics: MLSemantics {
    override var languageID: String { "zig" }
    override var displayName: String { "内蔵 Zig 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            // Zig は「あるかないか」も条件に書けるので、null 以外は真とする。
            return !value.isUnit
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "bool"
        case .int: return "i64"
        case .double: return "f64"
        case .string, .char: return "[]const u8"
        case .array: return "[]T"
        case .map: return "HashMap"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.shortestStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.shortestStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "{ " + array.elements.map { display($0) }.joined(separator: ", ") + " }"
        case .map(let map):
            return "{ " + map.pairs.map { ".\(display($0.key.asValue)) = \(display($0.value))" }
                .joined(separator: ", ") + " }"
        case .object(let object):
            if let caseName = object.caseName { return "." + caseName }
            let items = object.fields.pairs.map { pair -> String in
                ".\(pair.key.asValue.asString ?? "") = \(display(pair.value))"
            }
            return object.typeName + "{ " + items.joined(separator: ", ") + " }"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        if typeName.hasPrefix("Array") || typeName.hasPrefix("[]") { return .array(MLArray()) }
        switch typeName {
        case "i8", "i16", "i32", "i64", "isize", "u8", "u16", "u32", "u64", "usize",
             "comptime_int":
            return .int(0)
        case "f16", "f32", "f64": return .double(0)
        case "bool": return .bool(false)
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["f16", "f32", "f64"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "++":
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
            return .string(display(lhs) + display(rhs))
        case "**":
            guard let count = rhs.asInt, count >= 0 else { return nil }
            if let left = lhs.asArray {
                var elements: [MLValue] = []
                for _ in 0..<count { elements += left.elements }
                return .array(MLArray(elements))
            }
            if case .string(let text) = lhs.forced {
                return .string(String(repeating: text, count: Int(count)))
            }
            return nil
        case "and": return .bool(try isTruthy(lhs) && isTruthy(rhs))
        case "or": return .bool(try isTruthy(lhs) || isTruthy(rhs))
        default: return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        ZigLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        if name == "len" {
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.utf8.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        }
        if name == "items", let array = value.asArray { return .array(array) }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try ZigLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

/// Zig の標準ライブラリのうち、`std.debug.print` などよく使うもの。
enum ZigLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func namespace(_ typeName: String, _ entries: [(String, MLValue)]) -> MLObject {
        let object = MLObject(typeName: typeName)
        for (name, value) in entries { object.fields[.string(name)] = value }
        return object
    }

    static func install(into environment: MLEnvironment, semantics: ZigSemantics) {
        let debug = namespace("std.debug", [
            ("print", function("print", 1...2) { context in
                let pattern = try context.requireString(0, "std.debug.print")
                let arguments = context.optionalArgument(1)?.asArray?.elements
                    ?? (context.optionalArgument(1).map { [$0] } ?? [])
                context.interpreter.write(try zigFormat(pattern, arguments,
                                                        semantics: semantics))
                return .unit
            }),
            ("assert", function("assert", 1) { context in
                if try !semantics.isTruthy(context.argument(0)) {
                    throw MLError.runtime("assert: 条件が成り立ちません")
                }
                return .unit
            })
        ])

        let writer = namespace("Writer", [
            ("print", function("print", 1...2) { context in
                let pattern = try context.requireString(0, "print")
                let arguments = context.optionalArgument(1)?.asArray?.elements
                    ?? (context.optionalArgument(1).map { [$0] } ?? [])
                context.interpreter.write(try zigFormat(pattern, arguments,
                                                        semantics: semantics))
                return .unit
            }),
            ("writeAll", function("writeAll", 1) { context in
                context.interpreter.write(semantics.display(context.argument(0)))
                return .unit
            })
        ])

        let stdout = namespace("File", [
            ("writer", function("writer", 0...0) { _ in .object(writer) }),
            ("print", function("print", 1...2) { context in
                let pattern = try context.requireString(0, "print")
                let arguments = context.optionalArgument(1)?.asArray?.elements ?? []
                context.interpreter.write(try zigFormat(pattern, arguments,
                                                        semantics: semantics))
                return .unit
            })
        ])

        let io = namespace("std.io", [
            ("getStdOut", function("getStdOut", 0...0) { _ in .object(stdout) }),
            ("getStdErr", function("getStdErr", 0...0) { _ in .object(stdout) })
        ])

        let math = namespace("std.math", [
            ("pi", .double(Double.pi)),
            ("e", .double(M_E)),
            ("maxInt", function("maxInt", 1) { _ in .int(Int64.max) }),
            ("minInt", function("minInt", 1) { _ in .int(Int64.min) }),
            ("max", function("max", 2) { context in
                try MLStdlib.reduceExtreme(context, keepSmaller: false)
            }),
            ("min", function("min", 2) { context in
                try MLStdlib.reduceExtreme(context, keepSmaller: true)
            }),
            ("absCast", function("absCast", 1) { context in
                .int(Swift.abs(context.argument(0).asInt ?? 0))
            }),
            ("pow", function("pow", 2...3) { context in
                let base = context.arguments.count >= 3 ? context.argument(1)
                                                        : context.argument(0)
                let exponent = context.arguments.count >= 3 ? context.argument(2)
                                                            : context.argument(1)
                return MLOperations.power(base.asDouble ?? 0, exponent.asDouble ?? 0,
                                          preferInteger: base.asInt != nil)
            }),
            ("sqrt", function("sqrt", 1) { context in
                .double(Foundation.sqrt(try context.requireDouble(0, "sqrt")))
            })
        ])

        let sortModule = namespace("std.sort", [
            ("sort", function("sort", 1...4) { context in
                // `std.sort.sort(T, slice, ctx, lessThan)` / `std.sort.sort(slice)`
                var array: MLArray?
                var comparator: MLFunction?
                for argument in context.arguments {
                    if let candidate = argument.asArray, array == nil { array = candidate }
                    if let candidate = argument.asFunction { comparator = candidate }
                }
                guard let array else { return .unit }
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: comparator)
                return .unit
            })
        ])

        let mem = namespace("std.mem", [
            ("eql", function("eql", 2...3) { context in
                let left = context.arguments.count >= 3 ? context.argument(1)
                                                        : context.argument(0)
                let right = context.arguments.count >= 3 ? context.argument(2)
                                                         : context.argument(1)
                return .bool(semantics.areEqual(left, right))
            }),
            ("indexOf", function("indexOf", 2...3) { context in
                let haystack = context.arguments.count >= 3 ? context.argument(1)
                                                            : context.argument(0)
                let needle = context.arguments.count >= 3 ? context.argument(2)
                                                          : context.argument(1)
                guard let text = haystack.asString, let target = needle.asString,
                      let found = MLStdlib.firstIndex(of: target, in: Array(text)) else {
                    return .unit
                }
                return .int(Int64(found))
            })
        ])

        let std = namespace("std", [
            ("debug", .object(debug)),
            ("io", .object(io)),
            ("math", .object(math)),
            ("sort", .object(sortModule)),
            ("mem", .object(mem)),
            ("ArrayList", function("ArrayList", 0...1) { _ in .array(MLArray()) })
        ])
        environment.define("std", .object(std), isConstant: true)

        environment.define("@import", .function(.native("@import", 1) { context in
            // `@import("std")` は用意済みの名前空間を返す。
            if context.argument(0).asString == "std" { return .object(std) }
            return .object(MLObject(typeName: "module"))
        }), isConstant: true)
        environment.define("@intCast", .function(.native("@intCast", 1...2) { context in
            .int(context.arguments.last?.asInt
                 ?? Int64(context.arguments.last?.asDouble ?? 0))
        }), isConstant: true)
        environment.define("@floatFromInt", .function(.native("@floatFromInt", 1...2) { context in
            .double(context.arguments.last?.asDouble ?? 0)
        }), isConstant: true)
        environment.define("@intFromFloat", .function(.native("@intFromFloat", 1...2) { context in
            .int(Int64(context.arguments.last?.asDouble ?? 0))
        }), isConstant: true)
        environment.define("@as", .function(.native("@as", 2) { context in
            context.argument(1)
        }), isConstant: true)
        environment.define("#enumerate", .function(.native("#enumerate", 1) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            return .array(MLArray(items.enumerated()
                .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
        }), isConstant: true)
    }

    /// Zig の `{}` `{d}` `{s}` `{any}` などの書式。
    static func zigFormat(_ pattern: String, _ arguments: [MLValue],
                          semantics: ZigSemantics) throws -> String {
        var result = ""
        var index = 0
        let characters = Array(pattern)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character == "{" {
                if position + 1 < characters.count, characters[position + 1] == "{" {
                    result.append("{")
                    position += 2
                    continue
                }
                guard let close = characters[position...].firstIndex(of: "}") else {
                    result.append(character)
                    position += 1
                    continue
                }
                let specifier = String(characters[(position + 1)..<close])
                position = close + 1
                let value = index < arguments.count ? arguments[index] : .unit
                index += 1
                result += render(value, specifier: specifier, semantics: semantics)
                continue
            }
            if character == "}", position + 1 < characters.count,
               characters[position + 1] == "}" {
                result.append("}")
                position += 2
                continue
            }
            result.append(character)
            position += 1
        }
        return result
    }

    static func render(_ value: MLValue, specifier: String,
                       semantics: ZigSemantics) -> String {
        var body = specifier
        var width: Int?
        var fill: Character = " "
        if let colon = body.firstIndex(of: ":") {
            let padding = String(body[body.index(after: colon)...])
            body = String(body[..<colon])
            var rest = Array(padding)
            if rest.count >= 2, rest[1] == ">" || rest[1] == "<" {
                fill = rest[0]
                rest.removeFirst(2)
            } else if let first = rest.first, first == ">" || first == "<" {
                rest.removeFirst()
            }
            width = Int(String(rest.prefix(while: { $0.isNumber })))
        }
        var text: String
        switch body {
        case "d": text = String(value.asInt ?? Int64(value.asDouble ?? 0))
        case "s": text = semantics.display(value)
        case "c":
            if let number = value.asInt,
               let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                text = String(Character(scalar))
            } else {
                text = semantics.display(value)
            }
        case "x": text = String(value.asInt ?? 0, radix: 16)
        case "X": text = String(value.asInt ?? 0, radix: 16).uppercased()
        case "b": text = String(value.asInt ?? 0, radix: 2)
        case "any", "": text = semantics.display(value)
        default:
            if body.hasPrefix("d:") || body.hasPrefix("."), body.contains(".") {
                let digits = Int(body.split(separator: ".").last ?? "2") ?? 2
                text = MLNumberFormatting.fixed(value.asDouble ?? 0, digits: digits)
            } else {
                text = semantics.display(value)
            }
        }
        if let width, text.count < width {
            text = String(repeating: fill, count: width - text.count) + text
        }
        return text
    }

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: ZigSemantics) throws -> MLValue? {
        switch receiver.forced {
        case .array(let array):
            switch name {
            case "append":
                array.elements.append(context.arguments.last ?? .unit)
                return .unit
            case "pop": return array.elements.popLast() ?? .unit
            case "len", "count": return .int(Int64(array.count))
            case "items", "toOwnedSlice": return .array(array)
            case "deinit", "clearAndFree":
                array.elements.removeAll()
                return .unit
            default:
                return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
            }
        case .string(let text):
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        default:
            return try MLStdlib.callMethod(on: receiver, name: name, context: context)
        }
    }
}
