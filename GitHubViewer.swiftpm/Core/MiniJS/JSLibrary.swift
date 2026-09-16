import Foundation

/// JavaScript らしい振る舞い。
final class JSSemantics: MLSemantics {
    override var languageID: String { "javascript" }
    override var displayName: String { "内蔵 JavaScript 処理系" }

    /// JavaScript の `null` は `undefined` と別物なので、専用の値で表す。
    static let nullValue = MLValue.symbol("#null")

    static func isNull(_ value: MLValue) -> Bool {
        if case .symbol("#null") = value.forced { return true }
        return false
    }

    /// `/` は常に小数 (JavaScript の数値は 1 種類しかない)。
    override var divisionAlwaysProducesDouble: Bool { false }
    override var outOfBoundsIsError: Bool { false }
    override var requiresDefinitionBeforeUse: Bool { true }
    override var allowsNegativeIndexing: Bool { false }

    /// 何が「真」か。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        if JSSemantics.isNull(value) { return false }
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        case .int(let number): return number != 0
        case .double(let number): return number != 0 && !number.isNaN
        case .string(let text): return !text.isEmpty
        case .char(let character): return character != "\0"
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        if JSSemantics.isNull(value) { return "object" }
        switch value.forced {
        case .unit: return "undefined"
        case .bool: return "boolean"
        case .int, .double: return "number"
        case .string, .char: return "string"
        case .function: return "function"
        default: return "object"
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.compactStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        if JSSemantics.isNull(value) { return "null" }
        switch value.forced {
        case .unit: return "undefined"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.compactStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            // `console.log` は配列を `[ 1, 2, 3 ]` の形で出す。
            if array.elements.isEmpty { return "[]" }
            return "[ " + array.elements.map { inspect($0) }.joined(separator: ", ") + " ]"
        case .map(let map):
            if map.isEmpty { return "{}" }
            let items = map.pairs.map { pair -> String in
                let key = pair.key.asValue.asString ?? display(pair.key.asValue)
                return "\(quotedKey(key)): \(inspect(pair.value))"
            }
            return "{ " + items.joined(separator: ", ") + " }"
        case .tuple(let items):
            return "[ " + items.map { inspect($0) }.joined(separator: ", ") + " ]"
        case .function(let function):
            return function.name.isEmpty ? "[Function (anonymous)]"
                                         : "[Function: \(function.name)]"
        case .object(let object):
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("toString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "toString",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            let items = object.fields.pairs.map { pair -> String in
                let key = pair.key.asValue.asString ?? ""
                return "\(quotedKey(key)): \(inspect(pair.value))"
            }
            let prefix = object.classDeclaration == nil ? "" : object.typeName + " "
            if items.isEmpty { return prefix + "{}" }
            return prefix + "{ " + items.joined(separator: ", ") + " }"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// `console.log` が入れ子の中で使う形 (文字列に引用符が付く)。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "'\(text)'"
        case .char(let character): return "'\(character)'"
        default: return display(value)
        }
    }

    /// 識別子として使えるキーは引用符なしで出す。
    private func quotedKey(_ key: String) -> String {
        guard let first = key.first, MLLexerBase.isIdentifierStart(first),
              key.allSatisfy({ MLLexerBase.isIdentifierPart($0) }) else {
            return "'\(key)'"
        }
        return key
    }

    /// 文字列化 (`"" + x` や テンプレートリテラル)。
    override func stringify(_ value: MLValue) -> String {
        if JSSemantics.isNull(value) { return "null" }
        switch value.forced {
        case .unit: return "undefined"
        case .array(let array):
            // JavaScript の配列は `join(",")` で文字列になる。
            return array.elements.map { $0.isUnit ? "" : stringify($0) }.joined(separator: ",")
        case .map: return "[object Object]"
        case .object(let object):
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("toString") != nil,
               let result = try? interpreter.callMethod(on: value, name: "toString",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            return "[object Object]"
        default: return display(value)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    /// `/` は割り切れなければ小数になる。
    override func divideIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        if rhs == 0 {
            if lhs == 0 { return .double(Double.nan) }
            return .double(lhs > 0 ? Double.infinity : -Double.infinity)
        }
        if lhs % rhs == 0 { return .int(lhs / rhs) }
        return .double(Double(lhs) / Double(rhs))
    }

    override func moduloIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        if rhs == 0 { return .double(Double.nan) }
        return .int(lhs % rhs)
    }

    /// `==` はゆるい比較、`===` は厳密比較。
    override func areEqual(_ lhs: MLValue, _ rhs: MLValue) -> Bool {
        looseEquals(lhs, rhs)
    }

    func looseEquals(_ rawLHS: MLValue, _ rawRHS: MLValue) -> Bool {
        let lhs = rawLHS.forced
        let rhs = rawRHS.forced
        // `null == undefined` は真、それ以外との比較は偽。
        let leftIsNullish = JSSemantics.isNull(lhs) || lhs.isUnit
        let rightIsNullish = JSSemantics.isNull(rhs) || rhs.isUnit
        if leftIsNullish || rightIsNullish { return leftIsNullish && rightIsNullish }
        // 数値と文字列は数値として比べる。
        if lhs.isNumeric, case .string(let text) = rhs {
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            return (lhs.asDouble ?? 0) == number
        }
        if rhs.isNumeric, case .string(let text) = lhs {
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            return number == (rhs.asDouble ?? 0)
        }
        if case .bool(let flag) = lhs, !rhs.isUnit {
            return looseEquals(.int(flag ? 1 : 0), rhs)
        }
        if case .bool(let flag) = rhs, !lhs.isUnit {
            return looseEquals(lhs, .int(flag ? 1 : 0))
        }
        return MLOperations.strictEquals(lhs, rhs, semantics: self)
    }

    override func compare(_ lhs: MLValue, _ rhs: MLValue) -> Int? {
        // 片方が数値なら数値として比べる。
        if lhs.isNumeric, case .string(let text) = rhs.forced,
           let number = Double(text) {
            let left = lhs.asDouble ?? 0
            return left == number ? 0 : (left < number ? -1 : 1)
        }
        if rhs.isNumeric, case .string(let text) = lhs.forced,
           let number = Double(text) {
            let right = rhs.asDouble ?? 0
            return number == right ? 0 : (number < right ? -1 : 1)
        }
        return MLOperations.defaultCompare(lhs, rhs, semantics: self)
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        switch op {
        case "===":
            return .bool(MLOperations.strictEquals(lhs, rhs, semantics: self)
                         && sameKind(lhs, rhs))
        case "!==":
            return .bool(!(MLOperations.strictEquals(lhs, rhs, semantics: self)
                           && sameKind(lhs, rhs)))
        case "+":
            // 片方が文字列なら連結、そうでなければ数値の足し算。
            if case .string = lhs.forced { return .string(stringify(lhs) + stringify(rhs)) }
            if case .string = rhs.forced { return .string(stringify(lhs) + stringify(rhs)) }
            if lhs.asArray != nil || rhs.asArray != nil || lhs.asMap != nil
                || rhs.asMap != nil {
                return .string(stringify(lhs) + stringify(rhs))
            }
            return nil
        case "in":
            if let map = rhs.asMap, let key = MLKey.from(lhs) {
                return .bool(map.contains(key))
            }
            if let object = rhs.asObject, let key = MLKey.from(lhs) {
                return .bool(object.fields.contains(key))
            }
            if let array = rhs.asArray, let index = lhs.asInt {
                return .bool(index >= 0 && Int(index) < array.count)
            }
            return .bool(false)
        case "instanceof":
            guard let object = lhs.asObject else { return .bool(false) }
            if let klass = interpreter.isClassToken(rhs) {
                return .bool(object.classDeclaration?.conforms(to: klass.name) ?? false)
            }
            return .bool(false)
        default:
            return nil
        }
    }

    private func sameKind(_ lhs: MLValue, _ rhs: MLValue) -> Bool {
        typeName(of: lhs) == typeName(of: rhs)
    }

    override func defaultValue(forTypeName typeName: String?) -> MLValue { .unit }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        JSLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "length":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let function = value.asFunction { return .int(Int64(function.declaredArity)) }
        case "size":
            if let map = value.asMap { return .int(Int64(map.count)) }
        default:
            break
        }
        // 無いプロパティは undefined (JavaScript はエラーにしない)。
        if let map = value.asMap { return map[.string(name)] ?? .unit }
        if let object = value.asObject, object.classDeclaration == nil {
            return object.fields[.string(name)] ?? .unit
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try JSLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

/// JavaScript の標準ライブラリ。
enum JSLibrary {

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

    static func install(into environment: MLEnvironment, semantics: JSSemantics) {
        environment.define("console", .object(makeConsole(semantics: semantics)),
                           isConstant: true)
        environment.define("Math", .object(makeMath()), isConstant: true)
        environment.define("JSON", .object(makeJSON(semantics: semantics)), isConstant: true)
        environment.define("Object", .object(makeObject(semantics: semantics)),
                           isConstant: true)
        environment.define("Array", .object(makeArrayStatics()), isConstant: true)
        environment.define("Number", .object(makeNumber(semantics: semantics)),
                           isConstant: true)
        environment.define("String", .object(makeStringStatics(semantics: semantics)),
                           isConstant: true)
        environment.define("Boolean", .function(.native("Boolean", 0...1) { context in
            .bool(try semantics.isTruthy(context.argument(0)))
        }), isConstant: true)

        // `String(x)` / `Number(x)` / `Array(n)` は「呼び出せる名前空間」。
        if let string = environment.lookup("String")?.value.asObject {
            string.fields[.string("#call")] = function("String", 0...1) { context in
                .string(context.arguments.isEmpty ? ""
                        : semantics.stringify(context.argument(0)))
            }
        }
        if let number = environment.lookup("Number")?.value.asObject {
            number.fields[.string("#call")] = function("Number", 0...1) { context in
                guard let first = context.optionalArgument(0) else { return .int(0) }
                if first.isNumeric { return first }
                if case .bool(let flag) = first { return .int(flag ? 1 : 0) }
                if first.isUnit { return .double(Double.nan) }
                guard let text = first.asString else { return .double(Double.nan) }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return .int(0) }
                if let integer = Int64(trimmed) { return .int(integer) }
                guard let value = Double(trimmed) else { return .double(Double.nan) }
                return .double(value)
            }
        }
        if let array = environment.lookup("Array")?.value.asObject {
            array.fields[.string("#call")] = function("Array", 0...32) { context in
                if context.arguments.count == 1, let count = context.argument(0).asInt {
                    return .array(MLArray(Array(repeating: .unit,
                                                count: Swift.max(0, Int(count)))))
                }
                return .array(MLArray(context.arguments))
            }
        }
        if let object = environment.lookup("Object")?.value.asObject {
            object.fields[.string("#call")] = function("Object", 0...1) { context in
                context.optionalArgument(0) ?? .map(MLMap())
            }
        }

        environment.define("NaN", .double(Double.nan), isConstant: true)
        environment.define("Infinity", .double(Double.infinity), isConstant: true)
        environment.define("undefined", .unit, isConstant: true)

        environment.define("parseInt", .function(.native("parseInt", 1...2) { context in
            let text = semantics.stringify(context.argument(0))
                .trimmingCharacters(in: .whitespaces)
            let radix = Int(context.optionalArgument(1)?.asInt ?? 10)
            var digits = ""
            var index = text.startIndex
            if index < text.endIndex, text[index] == "-" || text[index] == "+" {
                digits.append(text[index])
                index = text.index(after: index)
            }
            while index < text.endIndex,
                  Int(String(text[index]), radix: radix == 0 ? 10 : radix) != nil {
                digits.append(text[index])
                index = text.index(after: index)
            }
            guard let value = Int64(digits, radix: radix == 0 ? 10 : radix) else {
                return .double(Double.nan)
            }
            return .int(value)
        }), isConstant: true)

        environment.define("parseFloat", .function(.native("parseFloat", 1) { context in
            let text = semantics.stringify(context.argument(0))
                .trimmingCharacters(in: .whitespaces)
            var digits = ""
            for character in text {
                if character.isNumber || character == "." || character == "-"
                    || character == "+" || character == "e" || character == "E" {
                    digits.append(character)
                } else {
                    break
                }
            }
            guard let value = Double(digits) else { return .double(Double.nan) }
            return .double(value)
        }), isConstant: true)

        environment.define("isNaN", .function(.native("isNaN", 1) { context in
            guard let number = context.argument(0).asDouble else { return .bool(true) }
            return .bool(number.isNaN)
        }), isConstant: true)
        environment.define("isFinite", .function(.native("isFinite", 1) { context in
            guard let number = context.argument(0).asDouble else { return .bool(false) }
            return .bool(number.isFinite)
        }), isConstant: true)

        environment.define("#typeof", .function(.native("#typeof", 1) { context in
            .string(semantics.typeName(of: context.argument(0)))
        }), isConstant: true)
        environment.define("#delete", .function(.native("#delete", 2) { context in
            if let map = context.argument(0).asMap, let key = MLKey.from(context.argument(1)) {
                _ = map.removeValue(forKey: key)
            }
            if let object = context.argument(0).asObject,
               let key = MLKey.from(context.argument(1)) {
                object.fields[key] = nil
            }
            return .bool(true)
        }), isConstant: true)

        environment.define("Map", .function(.native("Map", 0...1) { context in
            let map = MLMap()
            if let source = context.optionalArgument(0)?.asArray {
                for entry in source.elements {
                    guard case .tuple(let pair) = entry.forced, pair.count >= 2,
                          let key = MLKey.from(pair[0]) else {
                        if let inner = entry.asArray, inner.count >= 2,
                           let key = MLKey.from(inner.elements[0]) {
                            map[key] = inner.elements[1]
                        }
                        continue
                    }
                    map[key] = pair[1]
                }
            }
            return .map(map)
        }), isConstant: true)
        environment.define("Set", .function(.native("Set", 0...1) { context in
            var unique: [MLValue] = []
            if let source = context.optionalArgument(0)?.asArray {
                for value in source.elements
                where !unique.contains(where: {
                    MLOperations.strictEquals($0, value, semantics: semantics)
                }) {
                    unique.append(value)
                }
            }
            return .array(MLArray(unique))
        }), isConstant: true)
        environment.define("Promise", .object(namespace("Promise", [
            ("resolve", function("resolve", 0...1) { context in context.argument(0) }),
            ("all", function("all", 1) { context in context.argument(0) })
        ])), isConstant: true)
        environment.define("Date", .function(.native("Date", 0...7) { _ in
            let object = MLObject(typeName: "Date")
            object.fields[.string("#time")] = .double(Date().timeIntervalSince1970 * 1000)
            return .object(object)
        }), isConstant: true)

        for name in exceptionAncestors.keys {
            environment.define(name, .function(.native(name, 0...2) { context in
                .object(exception(name, semantics.stringify(context.argument(0))))
            }), isConstant: true)
        }
    }

    static let exceptionAncestors: [String: [String]] = [
        "Error": ["Error"],
        "TypeError": ["TypeError", "Error"],
        "RangeError": ["RangeError", "Error"],
        "SyntaxError": ["SyntaxError", "Error"],
        "ReferenceError": ["ReferenceError", "Error"],
        "EvalError": ["EvalError", "Error"]
    ]

    static func exception(_ typeName: String, _ message: String) -> MLObject {
        let object = MLObject(typeName: typeName)
        object.fields[.string("name")] = .string(typeName)
        object.fields[.string("message")] = .string(message)
        object.fields[.string("#types")] =
            .array(MLArray((exceptionAncestors[typeName] ?? [typeName, "Error"])
                .map { .string($0) }))
        return object
    }

    static func makeConsole(semantics: JSSemantics) -> MLObject {
        func writer(_ name: String, newline: Bool = true) -> (String, MLValue) {
            (name, function(name, 0...32) { context in
                let text = context.arguments.map { semantics.display($0) }
                    .joined(separator: " ")
                context.interpreter.write(text + (newline ? "\n" : ""))
                return .unit
            })
        }
        return namespace("console", [
            writer("log"), writer("info"), writer("warn"), writer("error"),
            writer("debug"), writer("trace"),
            ("table", function("table", 0...2) { context in
                context.interpreter.write(semantics.display(context.argument(0)) + "\n")
                return .unit
            })
        ])
    }

    static func makeMath() -> MLObject {
        var entries: [(String, MLValue)] = [
            ("PI", .double(Double.pi)),
            ("E", .double(M_E)),
            ("LN2", .double(M_LN2)),
            ("LN10", .double(M_LN10)),
            ("SQRT2", .double(2.0.squareRoot())),
            ("abs", function("abs", 1) { context in
                switch context.argument(0) {
                case .int(let value): return .int(value < 0 ? -value : value)
                default: return .double(Swift.abs(context.argument(0).asDouble ?? Double.nan))
                }
            }),
            ("max", function("max", 0...32) { context in
                guard !context.arguments.isEmpty else { return .double(-Double.infinity) }
                return try MLStdlib.reduceExtreme(context, keepSmaller: false)
            }),
            ("min", function("min", 0...32) { context in
                guard !context.arguments.isEmpty else { return .double(Double.infinity) }
                return try MLStdlib.reduceExtreme(context, keepSmaller: true)
            }),
            ("pow", function("pow", 2) { context in
                .double(Foundation.pow(try context.requireDouble(0, "Math.pow"),
                                       try context.requireDouble(1, "Math.pow")))
            }),
            ("random", function("random", 0...0) { _ in .double(Double.random(in: 0..<1)) }),
            ("floor", function("floor", 1) { context in
                .int(Int64(Foundation.floor(try context.requireDouble(0, "Math.floor"))))
            }),
            ("ceil", function("ceil", 1) { context in
                .int(Int64(Foundation.ceil(try context.requireDouble(0, "Math.ceil"))))
            }),
            ("round", function("round", 1) { context in
                let value = try context.requireDouble(0, "Math.round")
                // JavaScript の round は「.5 は大きい方へ」。
                return .int(Int64(Foundation.floor(value + 0.5)))
            }),
            ("trunc", function("trunc", 1) { context in
                .int(Int64(try context.requireDouble(0, "Math.trunc")))
            }),
            ("sign", function("sign", 1) { context in
                let value = try context.requireDouble(0, "Math.sign")
                return .int(value > 0 ? 1 : (value < 0 ? -1 : 0))
            }),
            ("hypot", function("hypot", 0...8) { context in
                var total = 0.0
                for argument in context.arguments { total += Foundation.pow(argument.asDouble ?? 0, 2) }
                return .double(Foundation.sqrt(total))
            })
        ]
        for (name, implementation) in MLStdlib.mathFunctions
        where !["floor", "ceil", "round", "trunc"].contains(name) {
            entries.append((name, function(name, 1) { context in
                .double(implementation(try context.requireDouble(0, "Math." + name)))
            }))
        }
        return namespace("Math", entries)
    }

    static func makeJSON(semantics: JSSemantics) -> MLObject {
        namespace("JSON", [
            ("stringify", function("stringify", 1...3) { context in
                let indent = context.optionalArgument(2)?.asInt.map { Int($0) } ?? 0
                return .string(encode(context.argument(0), indent: indent, level: 0,
                                      semantics: semantics))
            }),
            ("parse", function("parse", 1) { context in
                let text = try context.requireString(0, "JSON.parse")
                var scanner = JSONScanner(text: Array(text))
                guard let value = scanner.parseValue() else {
                    throw MLError.thrown(.object(exception("SyntaxError",
                                                           "Unexpected token in JSON")))
                }
                return value
            })
        ])
    }

    /// JSON へ書き出す。
    static func encode(_ value: MLValue, indent: Int, level: Int,
                       semantics: JSSemantics) -> String {
        let pad = indent > 0 ? String(repeating: " ", count: indent * (level + 1)) : ""
        let closePad = indent > 0 ? String(repeating: " ", count: indent * level) : ""
        let newline = indent > 0 ? "\n" : ""
        let separator = indent > 0 ? ": " : ":"

        switch value.forced {
        case .unit, .symbol: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            return number.isFinite ? MLNumberFormatting.compactStyle(number) : "null"
        case .string, .char:
            return escape(semantics.stringify(value))
        case .array(let array):
            if array.elements.isEmpty { return "[]" }
            let items = array.elements.map {
                pad + encode($0, indent: indent, level: level + 1, semantics: semantics)
            }
            return "[" + newline + items.joined(separator: "," + newline) + newline
                + closePad + "]"
        case .map(let map):
            if map.isEmpty { return "{}" }
            let items = map.pairs.map { pair -> String in
                let key = escape(pair.key.asValue.asString
                                 ?? semantics.stringify(pair.key.asValue))
                return pad + key + separator
                    + encode(pair.value, indent: indent, level: level + 1, semantics: semantics)
            }
            return "{" + newline + items.joined(separator: "," + newline) + newline
                + closePad + "}"
        case .object(let object):
            if object.fields.isEmpty { return "{}" }
            let items = object.fields.pairs.map { pair -> String in
                let key = escape(pair.key.asValue.asString ?? "")
                return pad + key + separator
                    + encode(pair.value, indent: indent, level: level + 1, semantics: semantics)
            }
            return "{" + newline + items.joined(separator: "," + newline) + newline
                + closePad + "}"
        case .function: return "null"
        default: return escape(semantics.stringify(value))
        }
    }

    static func escape(_ text: String) -> String {
        var result = "\""
        for character in text {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    /// JSON を読み込む小さな解析器。
    struct JSONScanner {
        let text: [Character]
        var index = 0

        init(text: [Character]) { self.text = text }

        mutating func skipSpace() {
            while index < text.count, text[index].isWhitespace { index += 1 }
        }

        mutating func parseValue() -> MLValue? {
            skipSpace()
            guard index < text.count else { return nil }
            switch text[index] {
            case "{":
                index += 1
                let map = MLMap()
                skipSpace()
                if index < text.count, text[index] == "}" {
                    index += 1
                    return .map(map)
                }
                while index < text.count {
                    skipSpace()
                    guard let keyValue = parseValue(), let key = MLKey.from(keyValue) else {
                        return nil
                    }
                    skipSpace()
                    guard index < text.count, text[index] == ":" else { return nil }
                    index += 1
                    guard let value = parseValue() else { return nil }
                    map[key] = value
                    skipSpace()
                    if index < text.count, text[index] == "," {
                        index += 1
                        continue
                    }
                    break
                }
                skipSpace()
                guard index < text.count, text[index] == "}" else { return nil }
                index += 1
                return .map(map)
            case "[":
                index += 1
                var items: [MLValue] = []
                skipSpace()
                if index < text.count, text[index] == "]" {
                    index += 1
                    return .array(MLArray(items))
                }
                while index < text.count {
                    guard let value = parseValue() else { return nil }
                    items.append(value)
                    skipSpace()
                    if index < text.count, text[index] == "," {
                        index += 1
                        continue
                    }
                    break
                }
                skipSpace()
                guard index < text.count, text[index] == "]" else { return nil }
                index += 1
                return .array(MLArray(items))
            case "\"":
                index += 1
                var result = ""
                while index < text.count, text[index] != "\"" {
                    if text[index] == "\\", index + 1 < text.count {
                        index += 1
                        switch text[index] {
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        case "r": result.append("\r")
                        case "u":
                            let start = index + 1
                            let end = Swift.min(start + 4, text.count)
                            if let code = UInt32(String(text[start..<end]), radix: 16),
                               let scalar = Unicode.Scalar(code) {
                                result.append(Character(scalar))
                            }
                            index = end - 1
                        default: result.append(text[index])
                        }
                    } else {
                        result.append(text[index])
                    }
                    index += 1
                }
                guard index < text.count else { return nil }
                index += 1
                return .string(result)
            default:
                if text[index] == "t", index + 4 <= text.count {
                    index += 4
                    return .bool(true)
                }
                if text[index] == "f", index + 5 <= text.count {
                    index += 5
                    return .bool(false)
                }
                if text[index] == "n", index + 4 <= text.count {
                    index += 4
                    return JSSemantics.nullValue
                }
                var digits = ""
                while index < text.count,
                      text[index].isNumber || "+-.eE".contains(text[index]) {
                    digits.append(text[index])
                    index += 1
                }
                if digits.isEmpty { return nil }
                if let value = Int64(digits) { return .int(value) }
                guard let value = Double(digits) else { return nil }
                return .double(value)
            }
        }
    }

    static func makeObject(semantics: JSSemantics) -> MLObject {
        namespace("Object", [
            ("keys", function("keys", 1) { context in
                if let map = context.argument(0).asMap {
                    return .array(MLArray(map.keys.map { $0.asValue }))
                }
                if let object = context.argument(0).asObject {
                    return .array(MLArray(object.fields.keys.map { $0.asValue }))
                }
                if let array = context.argument(0).asArray {
                    return .array(MLArray((0..<array.count).map { .string(String($0)) }))
                }
                return .array(MLArray())
            }),
            ("values", function("values", 1) { context in
                if let map = context.argument(0).asMap { return .array(MLArray(map.values)) }
                if let object = context.argument(0).asObject {
                    return .array(MLArray(object.fields.values))
                }
                if let array = context.argument(0).asArray { return .array(MLArray(array.elements)) }
                return .array(MLArray())
            }),
            ("entries", function("entries", 1) { context in
                if let map = context.argument(0).asMap {
                    return .array(MLArray(map.pairs.map {
                        .array(MLArray([$0.key.asValue, $0.value]))
                    }))
                }
                if let object = context.argument(0).asObject {
                    return .array(MLArray(object.fields.pairs.map {
                        .array(MLArray([$0.key.asValue, $0.value]))
                    }))
                }
                return .array(MLArray())
            }),
            ("assign", function("assign", 1...8) { context in
                guard let target = context.argument(0).asMap else { return context.argument(0) }
                for argument in context.arguments.dropFirst() {
                    if let source = argument.asMap {
                        for (key, value) in source.pairs { target[key] = value }
                    }
                }
                return .map(target)
            }),
            ("freeze", function("freeze", 1) { context in context.argument(0) }),
            ("fromEntries", function("fromEntries", 1) { context in
                let map = MLMap()
                guard let entries = context.argument(0).asArray else { return .map(map) }
                for entry in entries.elements {
                    if let pair = entry.asArray, pair.count >= 2,
                       let key = MLKey.from(pair.elements[0]) {
                        map[key] = pair.elements[1]
                    }
                }
                return .map(map)
            })
        ])
    }

    static func makeArrayStatics() -> MLObject {
        namespace("Array", [
            ("isArray", function("isArray", 1) { context in
                .bool(context.argument(0).asArray != nil)
            }),
            ("from", function("from", 1...2) { context in
                let source = context.argument(0)
                var items: [MLValue]
                if let array = source.asArray { items = array.elements }
                else if let text = source.asString { items = text.map { .char($0) } }
                else if let map = source.asMap {
                    items = map.pairs.map { .array(MLArray([$0.key.asValue, $0.value])) }
                } else { items = [] }
                if let transform = context.optionalArgument(1)?.asFunction {
                    var results: [MLValue] = []
                    for (index, item) in items.enumerated() {
                        results.append(try context.interpreter.callFunction(
                            transform, arguments: [item, .int(Int64(index))]))
                    }
                    items = results
                }
                return .array(MLArray(items))
            }),
            ("of", function("of", 0...32) { context in .array(MLArray(context.arguments)) })
        ])
    }

    static func makeNumber(semantics: JSSemantics) -> MLObject {
        namespace("Number", [
            ("MAX_SAFE_INTEGER", .int(9007199254740991)),
            ("MIN_SAFE_INTEGER", .int(-9007199254740991)),
            ("MAX_VALUE", .double(Double.greatestFiniteMagnitude)),
            ("EPSILON", .double(Double.ulpOfOne)),
            ("POSITIVE_INFINITY", .double(Double.infinity)),
            ("NEGATIVE_INFINITY", .double(-Double.infinity)),
            ("NaN", .double(Double.nan)),
            ("isInteger", function("isInteger", 1) { context in
                if case .int = context.argument(0) { return .bool(true) }
                guard let number = context.argument(0).asDouble else { return .bool(false) }
                return .bool(number == number.rounded() && number.isFinite)
            }),
            ("isNaN", function("isNaN", 1) { context in
                guard let number = context.argument(0).asDouble else { return .bool(false) }
                return .bool(number.isNaN)
            }),
            ("isFinite", function("isFinite", 1) { context in
                guard let number = context.argument(0).asDouble else { return .bool(false) }
                return .bool(number.isFinite)
            }),
            ("parseFloat", function("parseFloat", 1) { context in
                guard let number = Double(semantics.stringify(context.argument(0))) else {
                    return .double(Double.nan)
                }
                return .double(number)
            })
        ])
    }

    static func makeStringStatics(semantics: JSSemantics) -> MLObject {
        namespace("String", [
            ("fromCharCode", function("fromCharCode", 0...32) { context in
                var text = ""
                for argument in context.arguments {
                    if let code = argument.asInt,
                       let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: code)) {
                        text.append(Character(scalar))
                    }
                }
                return .string(text)
            })
        ])
    }

    // MARK: メソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: JSSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context, semantics: semantics)
        case .char(let character):
            return try stringMethod(String(character), name: name, context: context,
                                    semantics: semantics)
        case .array(let array):
            return try arrayMethod(array, name: name, context: context, semantics: semantics)
        case .map(let map):
            return try mapMethod(map, name: name, context: context, semantics: semantics)
        case .int, .double:
            switch name {
            case "toString":
                if let radix = context.optionalArgument(0)?.asInt, let number = receiver.asInt {
                    return .string(String(number, radix: Int(radix)))
                }
                return .string(semantics.display(receiver))
            case "toFixed":
                let digits = Int(context.optionalArgument(0)?.asInt ?? 0)
                return .string(MLNumberFormatting.fixed(receiver.asDouble ?? 0, digits: digits))
            case "toPrecision":
                let digits = Int(context.optionalArgument(0)?.asInt ?? 6)
                return .string(String(format: "%.\(digits)g", receiver.asDouble ?? 0))
            case "valueOf": return receiver
            default: return nil
            }
        case .object(let object):
            if object.classDeclaration == nil, object.fields.contains(.string("message")) {
                if name == "toString" {
                    let type = object.fields[.string("name")]?.asString ?? object.typeName
                    let message = object.fields[.string("message")]?.asString ?? ""
                    return .string(message.isEmpty ? type : "\(type): \(message)")
                }
            }
            if let stored = object.fields[.string(name)], let function = stored.asFunction {
                return try interpreter.callFunction(function, arguments: context.arguments,
                                                    location: context.location)
            }
            return nil
        case .function(let function):
            switch name {
            case "call":
                let rest = Array(context.arguments.dropFirst())
                return try interpreter.callFunction(function, arguments: rest,
                                                    location: context.location)
            case "apply":
                let rest = context.optionalArgument(1)?.asArray?.elements ?? []
                return try interpreter.callFunction(function, arguments: rest,
                                                    location: context.location)
            case "bind":
                return .function(function.applying(Array(context.arguments.dropFirst())))
            case "toString": return .string("function \(function.name)() { }")
            default: return nil
            }
        default:
            return nil
        }
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: JSSemantics) throws -> MLValue? {
        let characters = Array(text)
        switch name {
        case "charAt":
            let position = Int(context.optionalArgument(0)?.asInt ?? 0)
            guard position >= 0, position < characters.count else { return .string("") }
            return .string(String(characters[position]))
        case "charCodeAt", "codePointAt":
            let position = Int(context.optionalArgument(0)?.asInt ?? 0)
            guard position >= 0, position < characters.count else { return .double(Double.nan) }
            return .int(Int64(characters[position].unicodeScalars.first?.value ?? 0))
        case "at":
            var position = Int(context.optionalArgument(0)?.asInt ?? 0)
            if position < 0 { position += characters.count }
            guard position >= 0, position < characters.count else { return .unit }
            return .string(String(characters[position]))
        case "slice":
            var start = Int(context.optionalArgument(0)?.asInt ?? 0)
            var end = Int(context.optionalArgument(1)?.asInt ?? Int64(characters.count))
            if start < 0 { start += characters.count }
            if end < 0 { end += characters.count }
            let low = Swift.max(0, Swift.min(start, characters.count))
            let high = Swift.max(low, Swift.min(end, characters.count))
            return .string(String(characters[low..<high]))
        case "substring":
            var start = Int(context.optionalArgument(0)?.asInt ?? 0)
            var end = Int(context.optionalArgument(1)?.asInt ?? Int64(characters.count))
            start = Swift.max(0, Swift.min(start, characters.count))
            end = Swift.max(0, Swift.min(end, characters.count))
            if start > end { Swift.swap(&start, &end) }
            return .string(String(characters[start..<end]))
        case "split":
            guard let separator = context.optionalArgument(0)?.asString else {
                return .array(MLArray([.string(text)]))
            }
            let parts = separator.isEmpty ? characters.map { String($0) }
                                          : text.components(separatedBy: separator)
            return .array(MLArray(parts.map { .string($0) }))
        case "replace":
            guard let target = context.argument(0).asString else { return .string(text) }
            if let replacement = context.argument(1).asString {
                guard let found = text.range(of: target) else { return .string(text) }
                return .string(text.replacingCharacters(in: found, with: replacement))
            }
            return .string(text)
        case "replaceAll":
            guard let target = context.argument(0).asString,
                  let replacement = context.argument(1).asString else { return .string(text) }
            return .string(text.replacingOccurrences(of: target, with: replacement))
        case "toUpperCase": return .string(text.uppercased())
        case "toLowerCase": return .string(text.lowercased())
        case "trim": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "trimStart": return .string(String(text.drop(while: { $0.isWhitespace })))
        case "trimEnd":
            var result = text
            while let last = result.last, last.isWhitespace { result.removeLast() }
            return .string(result)
        case "includes":
            guard let needle = context.argument(0).asString else { return .bool(false) }
            return .bool(needle.isEmpty || text.contains(needle))
        case "indexOf":
            guard let needle = context.argument(0).asString,
                  let found = MLStdlib.firstIndex(of: needle, in: characters) else {
                return .int(-1)
            }
            return .int(Int64(found))
        case "lastIndexOf":
            guard let needle = context.argument(0).asString,
                  let found = MLStdlib.lastIndex(of: needle, in: characters) else {
                return .int(-1)
            }
            return .int(Int64(found))
        case "startsWith": return .bool(text.hasPrefix(context.argument(0).asString ?? ""))
        case "endsWith": return .bool(text.hasSuffix(context.argument(0).asString ?? ""))
        case "repeat":
            let count = Int(try context.requireInt(0, "repeat"))
            return .string(count > 0 ? String(repeating: text, count: count) : "")
        case "padStart", "padEnd":
            let width = Int(context.optionalArgument(0)?.asInt ?? 0)
            let padding = context.optionalArgument(1)?.asString ?? " "
            return .string(MLStdlib.pad(text, to: width, with: padding,
                                        left: name == "padStart"))
        case "concat":
            return .string(text + context.arguments.map { semantics.stringify($0) }.joined())
        case "toString", "valueOf", "normalize", "trimRight" : return .string(text)
        case "localeCompare":
            return .int(Int64(semantics.compare(.string(text), context.argument(0)) ?? 0))
        case "match", "matchAll", "search": return .unit
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    static func arrayMethod(_ array: MLArray, name: String, context: MLCallContext,
                            semantics: JSSemantics) throws -> MLValue? {
        let interpreter = context.interpreter

        /// JavaScript のコールバックは (値, 添字, 配列) を受け取る。
        func callback(_ function: MLFunction, _ element: MLValue,
                      _ index: Int) throws -> MLValue {
            try interpreter.callFunction(function,
                                         arguments: [element, .int(Int64(index)),
                                                     .array(array)])
        }

        switch name {
        case "push":
            for value in context.arguments { array.elements.append(value) }
            return .int(Int64(array.count))
        case "pop":
            return array.elements.popLast() ?? .unit
        case "shift":
            return array.elements.isEmpty ? .unit : array.elements.removeFirst()
        case "unshift":
            array.elements.insert(contentsOf: context.arguments, at: 0)
            return .int(Int64(array.count))
        case "map":
            let transform = try context.requireFunction(0, "map")
            var results: [MLValue] = []
            for (index, element) in array.elements.enumerated() {
                results.append(try callback(transform, element, index))
            }
            return .array(MLArray(results))
        case "filter":
            let predicate = try context.requireFunction(0, "filter")
            var results: [MLValue] = []
            for (index, element) in array.elements.enumerated()
            where try semantics.isTruthy(callback(predicate, element, index)) {
                results.append(element)
            }
            return .array(MLArray(results))
        case "forEach":
            let body = try context.requireFunction(0, "forEach")
            for (index, element) in array.elements.enumerated() {
                _ = try callback(body, element, index)
            }
            return .unit
        case "reduce", "reduceRight":
            let combine = try context.requireFunction(0, name)
            var items = array.elements.enumerated().map { ($0.offset, $0.element) }
            if name == "reduceRight" { items.reverse() }
            var accumulator: MLValue
            var start = 0
            if let initial = context.optionalArgument(1) {
                accumulator = initial
            } else {
                guard !items.isEmpty else {
                    throw MLError.thrown(.object(exception(
                        "TypeError", "Reduce of empty array with no initial value")))
                }
                accumulator = items[0].1
                start = 1
            }
            for position in start..<items.count {
                accumulator = try interpreter.callFunction(
                    combine, arguments: [accumulator, items[position].1,
                                         .int(Int64(items[position].0)), .array(array)])
            }
            return accumulator
        case "find", "findIndex", "findLast", "findLastIndex":
            let predicate = try context.requireFunction(0, name)
            let indices = name.contains("Last") ? Array((0..<array.count).reversed())
                                                : Array(0..<array.count)
            for index in indices
            where try semantics.isTruthy(callback(predicate, array.elements[index], index)) {
                return name.contains("Index") ? .int(Int64(index)) : array.elements[index]
            }
            return name.contains("Index") ? .int(-1) : .unit
        case "some":
            let predicate = try context.requireFunction(0, "some")
            for (index, element) in array.elements.enumerated()
            where try semantics.isTruthy(callback(predicate, element, index)) {
                return .bool(true)
            }
            return .bool(false)
        case "every":
            let predicate = try context.requireFunction(0, "every")
            for (index, element) in array.elements.enumerated()
            where try !semantics.isTruthy(callback(predicate, element, index)) {
                return .bool(false)
            }
            return .bool(true)
        case "includes":
            let target = context.argument(0)
            return .bool(array.elements.contains {
                MLOperations.strictEquals($0, target, semantics: semantics)
            })
        case "indexOf", "lastIndexOf":
            let target = context.argument(0)
            let indices = name == "indexOf" ? Array(0..<array.count)
                                            : Array((0..<array.count).reversed())
            for index in indices
            where MLOperations.strictEquals(array.elements[index], target,
                                            semantics: semantics) {
                return .int(Int64(index))
            }
            return .int(-1)
        case "join":
            let separator = context.optionalArgument(0)?.asString ?? ","
            return .string(array.elements
                .map { $0.isUnit ? "" : semantics.stringify($0) }
                .joined(separator: separator))
        case "slice":
            var start = Int(context.optionalArgument(0)?.asInt ?? 0)
            var end = Int(context.optionalArgument(1)?.asInt ?? Int64(array.count))
            if start < 0 { start += array.count }
            if end < 0 { end += array.count }
            let low = Swift.max(0, Swift.min(start, array.count))
            let high = Swift.max(low, Swift.min(end, array.count))
            return .array(MLArray(Array(array.elements[low..<high])))
        case "splice":
            var start = Int(context.optionalArgument(0)?.asInt ?? 0)
            if start < 0 { start += array.count }
            start = Swift.max(0, Swift.min(start, array.count))
            let count = Swift.min(Int(context.optionalArgument(1)?.asInt
                                      ?? Int64(array.count - start)),
                                  array.count - start)
            let removed = Array(array.elements[start..<(start + Swift.max(0, count))])
            array.elements.removeSubrange(start..<(start + Swift.max(0, count)))
            let inserted = Array(context.arguments.dropFirst(2))
            array.elements.insert(contentsOf: inserted, at: start)
            return .array(MLArray(removed))
        case "concat":
            var results = array.elements
            for argument in context.arguments {
                if let other = argument.asArray { results += other.elements }
                else { results.append(argument) }
            }
            return .array(MLArray(results))
        case "sort":
            let comparator = context.optionalArgument(0)?.asFunction
            if comparator == nil {
                // 既定では文字列として比べる。
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: interpreter,
                    comparator: .native("#stringCompare", 2...2) { inner in
                        let left = semantics.stringify(inner.argument(0))
                        let right = semantics.stringify(inner.argument(1))
                        return .int(left == right ? 0 : (left < right ? -1 : 1))
                    })
            } else {
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: interpreter,
                                                           comparator: comparator)
            }
            return .array(array)
        case "reverse":
            array.elements.reverse()
            return .array(array)
        case "flat":
            var results: [MLValue] = []
            for element in array.elements {
                if let inner = element.asArray { results += inner.elements }
                else { results.append(element) }
            }
            return .array(MLArray(results))
        case "flatMap":
            let transform = try context.requireFunction(0, "flatMap")
            var results: [MLValue] = []
            for (index, element) in array.elements.enumerated() {
                let value = try callback(transform, element, index)
                if let inner = value.asArray { results += inner.elements }
                else { results.append(value) }
            }
            return .array(MLArray(results))
        case "fill":
            let value = context.argument(0)
            for index in 0..<array.count { array.elements[index] = value }
            return .array(array)
        case "keys":
            return .array(MLArray((0..<array.count).map { .int(Int64($0)) }))
        case "values":
            return .array(MLArray(array.elements))
        case "entries":
            return .array(MLArray(array.elements.enumerated()
                .map { .array(MLArray([.int(Int64($0.offset)), $0.element])) }))
        case "at":
            var position = Int(context.optionalArgument(0)?.asInt ?? 0)
            if position < 0 { position += array.count }
            guard position >= 0, position < array.count else { return .unit }
            return array.elements[position]
        case "toString":
            return .string(array.elements.map { $0.isUnit ? "" : semantics.stringify($0) }
                .joined(separator: ","))
        default:
            return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: JSSemantics) throws -> MLValue? {
        switch name {
        case "get":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            return map[key] ?? .unit
        case "set":
            guard let key = MLKey.from(context.argument(0)) else { return .map(map) }
            map[key] = context.argument(1)
            return .map(map)
        case "has":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))
        case "delete":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.removeValue(forKey: key) != nil)
        case "clear":
            map.removeAll()
            return .unit
        case "forEach":
            let body = try context.requireFunction(0, "forEach")
            for (key, value) in map.pairs {
                _ = try context.interpreter.callFunction(body,
                                                         arguments: [value, key.asValue,
                                                                     .map(map)])
            }
            return .unit
        case "keys": return .array(MLArray(map.keys.map { $0.asValue }))
        case "values": return .array(MLArray(map.values))
        case "entries":
            return .array(MLArray(map.pairs.map { .array(MLArray([$0.key.asValue, $0.value])) }))
        case "hasOwnProperty":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))
        case "toString": return .string("[object Object]")
        default:
            // オブジェクトのフィールドに入っている関数を呼ぶ。
            if let stored = map[.string(name)], let function = stored.asFunction {
                return try context.interpreter.callFunction(function,
                                                            arguments: context.arguments,
                                                            location: context.location)
            }
            return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
        }
    }
}
