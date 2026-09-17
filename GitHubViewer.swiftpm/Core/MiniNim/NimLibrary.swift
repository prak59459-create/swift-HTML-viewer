import Foundation

/// Nim らしい振る舞い。
final class NimSemantics: MLSemantics {
    override var languageID: String { "nim" }
    override var displayName: String { "内蔵 Nim 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// `x.len` や `xs.add(1)` を `len(x)` / `add(xs, 1)` として解く。
    override var usesUniformFunctionCall: Bool { true }
    /// 同じ名前の手続きを引数の型で選び分ける。
    override var selectsOverloadsByParameterType: Bool { true }
    /// `Green` のように型名を書かずに列挙のケースを使える。
    override var exposesEnumCasesGlobally: Bool { true }

    /// 実引数が宣言の型に当てはまるか。知らない型名なら通す。
    override func value(_ value: MLValue, matchesDeclaredType typeName: String,
                        interpreter: MLInterpreter) -> Bool {
        switch typeName {
        case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
             "uint32", "uint64", "byte", "Natural", "Positive":
            return value.asInt != nil && !isDouble(value)
        case "float", "float32", "float64":
            return isDouble(value) || value.asInt != nil
        case "string":
            if case .string = value.forced { return true }
            return false
        case "char":
            if case .char = value.forced { return true }
            return false
        case "bool":
            if case .bool = value.forced { return true }
            return false
        case "seq", "array", "openArray", "varargs":
            return value.asArray != nil
        case "Table", "OrderedTable", "CountTable":
            return value.asMap != nil
        case "auto", "typed", "untyped", "any", "T":
            return true
        default:
            // 利用者が宣言した型は、継承をたどって確かめる。
            guard let klass = interpreter.lookupClass(typeName) else { return true }
            guard let object = value.asObject else { return false }
            var current = object.classDeclaration
            while let candidate = current {
                if candidate.name == klass.name { return true }
                current = candidate.superclass
            }
            return false
        }
    }

    private func isDouble(_ value: MLValue) -> Bool {
        if case .double = value.forced { return true }
        return false
    }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else { return !value.isUnit }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "string"
        case .char: return "char"
        case .array: return "seq"
        case .map: return "Table"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == value.rounded(), Swift.abs(value) < 1e16 {
            return String(format: "%.1f", value)
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    /// `echo` や `$` が使う表示。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "@[" + array.elements.map { inspect($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(inspect($0.key.asValue)): \(inspect($0.value))" }
                .joined(separator: ", ") + "}"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            let items = object.fields.pairs.map { pair -> String in
                "\(pair.key.asValue.asString ?? ""): \(inspect(pair.value))"
            }
            return "(" + items.joined(separator: ", ") + ")"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// 入れ子のときは文字列を引用符で囲む。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "'\(character)'"
        default: return display(value)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        switch typeName {
        case "int", "int8", "int16", "int32", "int64",
             "uint", "uint8", "uint16", "uint32", "uint64", "byte", "Natural", "Positive":
            return .int(0)
        case "float", "float32", "float64": return .double(0)
        case "bool": return .bool(false)
        case "string": return .string("")
        case "char": return .char(" ")
        case "seq", "array", "openArray": return .array(MLArray())
        case "Table", "OrderedTable", "CountTable": return .map(MLMap())
        case "HashSet", "set": return .array(MLArray())
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        if typeName == "float" || typeName == "float64" || typeName == "float32",
           let number = value.asInt {
            return .double(Double(number))
        }
        return value
    }

    /// Nim だけの二項演算子。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "&":
            return .string(stringify(lhs) + stringify(rhs))
        case "div":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            guard right != 0 else { throw MLError.runtime("0 では割れません") }
            return .int(left / right)
        case "mod":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            guard right != 0 else { throw MLError.runtime("0 では割れません") }
            return .int(left % right)
        case "xor":
            if let left = lhs.asInt, let right = rhs.asInt { return .int(left ^ right) }
            return .bool(try isTruthy(lhs) != isTruthy(rhs))
        case "shl":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left << right)
        case "shr":
            guard let left = lhs.asInt, let right = rhs.asInt else { return nil }
            return .int(left >> right)
        case "notin":
            let items = try MLOperations.iterate(rhs, semantics: self)
            let found = items.contains { MLOperations.strictEquals($0, lhs, semantics: self) }
            return .bool(!found)
        case "isnot":
            return .bool(typeName(of: lhs) != (rhs.asString ?? ""))
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        NimLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        switch name {
        case "len":
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
        case "high":
            if let array = value.asArray { return .int(Int64(array.count - 1)) }
            if let text = value.asString { return .int(Int64(text.count - 1)) }
        case "low":
            if value.asArray != nil || value.asString != nil { return .int(0) }
        default:
            break
        }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try NimLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

/// Nim の標準ライブラリのうち、よく使うものを用意する。
enum NimLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func install(into environment: MLEnvironment, semantics: NimSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)
        environment.define("echo", function("echo", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            context.interpreter.write(text + "\n")
            return .unit
        })
        environment.define("write", function("write", 1...64) { context in
            let text = context.arguments.dropFirst()
                .map { semantics.display($0) }.joined()
            context.interpreter.write(text)
            return .unit
        })
        environment.define("stdout", .object(MLObject(typeName: "File")))
        environment.define("$", function("$", 1) { context in
            .string(semantics.display(context.argument(0)))
        })
        environment.define("repr", function("repr", 1) { context in
            .string(semantics.inspect(context.argument(0)))
        })

        // 長さ・追加といった、UFCS でよく使う手続き。
        environment.define("len", function("len", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let text = value.asString { return .int(Int64(text.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
            return .int(0)
        })
        environment.define("add", function("add", 2...64) { context in
            guard let array = context.argument(0).asArray else {
                if let text = context.argument(0).asString, let box = context.boxes.first ?? nil {
                    box.value = .string(text + semantics.display(context.argument(1)))
                    return .unit
                }
                throw MLError.runtime("add: seq が必要です")
            }
            for value in context.arguments.dropFirst() { array.elements.append(value) }
            return .unit
        })
        environment.define("insert", function("insert", 2...3) { context in
            guard let array = context.argument(0).asArray else {
                throw MLError.runtime("insert: seq が必要です")
            }
            let index = Int(context.optionalArgument(2)?.asInt ?? 0)
            array.elements.insert(context.argument(1),
                                  at: Swift.max(0, Swift.min(index, array.count)))
            return .unit
        })
        environment.define("delete", function("delete", 2) { context in
            guard let array = context.argument(0).asArray,
                  let index = context.argument(1).asInt else {
                throw MLError.runtime("delete: seq と位置が必要です")
            }
            guard index >= 0, Int(index) < array.count else { return .unit }
            array.elements.remove(at: Int(index))
            return .unit
        })
        environment.define("newSeq", function("newSeq", 0...2) { context in
            let count = Int(context.optionalArgument(0)?.asInt ?? 0)
            return .array(MLArray(Array(repeating: .int(0), count: Swift.max(0, count))))
        })
        environment.define("newSeqOfCap", function("newSeqOfCap", 0...1) { _ in
            .array(MLArray())
        })
        environment.define("high", function("high", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count - 1)) }
            if let text = value.asString { return .int(Int64(text.count - 1)) }
            return .int(0)
        })
        environment.define("low", function("low", 1) { _ in .int(0) })
        environment.define("contains", function("contains", 2) { context in
            let items = try MLOperations.iterate(context.argument(0), semantics: semantics)
            let needle = context.argument(1)
            return .bool(items.contains {
                MLOperations.strictEquals($0, needle, semantics: semantics)
            })
        })

        // 文字列。
        environment.define("parseInt", function("parseInt", 1) { context in
            let text = try context.requireString(0, "parseInt")
                .trimmingCharacters(in: .whitespaces)
            guard let number = Int64(text) else {
                throw MLError.thrown(.object(exception("ValueError",
                                                       "invalid integer: " + text)))
            }
            return .int(number)
        })
        environment.define("parseFloat", function("parseFloat", 1) { context in
            let text = try context.requireString(0, "parseFloat")
            guard let number = Double(text) else {
                throw MLError.thrown(.object(exception("ValueError",
                                                       "invalid float: " + text)))
            }
            return .double(number)
        })
        environment.define("intToStr", function("intToStr", 1) { context in
            .string(String(try context.requireInt(0, "intToStr")))
        })
        environment.define("toUpperAscii", function("toUpperAscii", 1) { context in
            .string(try context.requireString(0, "toUpperAscii").uppercased())
        })
        environment.define("toLowerAscii", function("toLowerAscii", 1) { context in
            .string(try context.requireString(0, "toLowerAscii").lowercased())
        })
        environment.define("strip", function("strip", 1) { context in
            .string(try context.requireString(0, "strip")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        })
        environment.define("split", function("split", 1...2) { context in
            let text = try context.requireString(0, "split")
            let separator = context.optionalArgument(1).flatMap { $0.asString } ?? " "
            let parts = separator.isEmpty
                ? text.map { String($0) }
                : text.components(separatedBy: separator)
            return .array(MLArray(parts.map { .string($0) }))
        })
        environment.define("join", function("join", 1...2) { context in
            let array = try context.requireArray(0, "join")
            let separator = context.optionalArgument(1).flatMap { $0.asString } ?? ""
            return .string(array.elements.map { semantics.display($0) }
                .joined(separator: separator))
        })
        environment.define("startsWith", function("startsWith", 2) { context in
            .bool(try context.requireString(0, "startsWith")
                .hasPrefix(context.requireString(1, "startsWith")))
        })
        environment.define("endsWith", function("endsWith", 2) { context in
            .bool(try context.requireString(0, "endsWith")
                .hasSuffix(context.requireString(1, "endsWith")))
        })
        environment.define("repeat", function("repeat", 2) { context in
            let count = Int(try context.requireInt(1, "repeat"))
            if let text = context.argument(0).asString {
                return .string(String(repeating: text, count: Swift.max(0, count)))
            }
            let array = try context.requireArray(0, "repeat")
            var elements: [MLValue] = []
            for _ in 0..<Swift.max(0, count) { elements += array.elements }
            return .array(MLArray(elements))
        })

        // 表。
        environment.define("initTable", function("initTable", 0...1) { _ in .map(MLMap()) })
        environment.define("initOrderedTable", function("initOrderedTable", 0...1) { _ in
            .map(MLMap())
        })
        environment.define("toTable", function("toTable", 1) { context in
            let array = try context.requireArray(0, "toTable")
            let map = MLMap()
            for element in array.elements {
                guard case .tuple(let pair) = element.forced, pair.count == 2,
                      let key = MLKey.from(pair[0]) else { continue }
                map[key] = pair[1]
            }
            return .map(map)
        })
        environment.define("hasKey", function("hasKey", 2) { context in
            guard let map = context.argument(0).asMap, let key = MLKey.from(context.argument(1)) else {
                return .bool(false)
            }
            return .bool(map[key] != nil)
        })
        environment.define("keys", function("keys", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.pairs.map { $0.key.asValue }))
        })
        environment.define("values", function("values", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.pairs.map { $0.value }))
        })
        environment.define("pairs", function("pairs", 1) { context in
            let value = context.argument(0)
            if let map = value.asMap {
                return .array(MLArray(map.pairs.map { .tuple([$0.key.asValue, $0.value]) }))
            }
            if let array = value.asArray {
                return .array(MLArray(array.elements.enumerated()
                    .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
            }
            return .array(MLArray())
        })
        environment.define("items", function("items", 1) { context in
            context.argument(0)
        })

        // 例外。
        environment.define("newException", function("newException", 1...2) { context in
            let name = context.argument(0).asString
                ?? context.argument(0).asObject?.typeName ?? "Exception"
            let message = context.optionalArgument(1).flatMap { $0.asString } ?? ""
            return .object(exception(name, message))
        })
        for name in ["Exception", "ValueError", "IndexDefect", "KeyError", "IOError",
                     "OSError", "DivByZeroDefect", "CatchableError"] {
            environment.define(name, .string(name))
        }

        // 数学。
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(try context.requireDouble(0, "sqrt")))
        })
        environment.define("pow", function("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        })
        environment.define("floor", function("floor", 1) { context in
            .double(try context.requireDouble(0, "floor").rounded(.down))
        })
        environment.define("ceil", function("ceil", 1) { context in
            .double(try context.requireDouble(0, "ceil").rounded(.up))
        })
        environment.define("round", function("round", 1) { context in
            .double(try context.requireDouble(0, "round").rounded())
        })
        environment.define("toFloat", function("toFloat", 1) { context in
            .double(try context.requireDouble(0, "toFloat"))
        })
        environment.define("toInt", function("toInt", 1) { context in
            .int(Int64(try context.requireDouble(0, "toInt").rounded()))
        })
        environment.define("readLine", function("readLine", 0...1) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })
        environment.define("stdin", .object(MLObject(typeName: "File")))
        _ = interpreter
    }

    /// 例外オブジェクトを作る。
    static func exception(_ typeName: String, _ message: String) -> MLObject {
        let object = MLObject(typeName: typeName)
        object.fields[.string("msg")] = .string(message)
        object.fields[.string("name")] = .string(typeName)
        return object
    }

    /// UFCS で書かれることの多いメソッド。
    static func method(on value: MLValue, name: String, context: MLCallContext,
                       semantics: NimSemantics) throws -> MLValue? {
        switch name {
        case "add":
            guard let array = value.asArray else { return nil }
            for argument in context.arguments { array.elements.append(argument) }
            return .unit
        case "sort":
            guard let array = value.asArray else { return nil }
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: context.interpreter,
                                                       comparator: nil)
            return .unit
        case "sorted":
            guard let array = value.asArray else { return nil }
            return .array(MLArray(try MLStdlib.stableSorted(
                array.elements, interpreter: context.interpreter, comparator: nil)))
        case "reversed":
            guard let array = value.asArray else { return nil }
            return .array(MLArray(array.elements.reversed()))
        default:
            return nil
        }
    }
}
