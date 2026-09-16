import Foundation

/// C++ らしい振る舞い。
final class CppSemantics: MLSemantics {
    override var languageID: String { "cpp" }
    override var displayName: String { "内蔵 C++ 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// `std::vector` などは値としてコピーされる。
    override var usesValueSemantics: Bool { true }
    override var arraysAreValueTypes: Bool { true }

    /// `std::cout` に溜める行バッファ。
    var pendingOutput = ""

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .unit: return false
        case .string(let text): return !text.isEmpty
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "void"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .char: return "char"
        case .string: return "std::string"
        case .array: return "std::vector"
        case .map: return "std::map"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    /// C++ の `<<` による出力は既定で有効数字 6 桁。
    override func formatDouble(_ value: Double) -> String {
        CppLibrary.streamDouble(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "1" : "0"
        case .int(let number): return String(number)
        case .double(let number): return CppLibrary.streamDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(display($0.key.asValue)): \(display($0.value))" }
                .joined(separator: ", ") + "}"
        case .tuple(let items):
            return "(" + items.map { display($0) }.joined(separator: ", ") + ")"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            return object.typeName
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        let base = MLInterpreter.baseTypeName(typeName)
        if typeName.hasPrefix("Array") || base == "vector" || base == "deque"
            || base == "list" || base == "set" || base == "array" {
            return .array(MLArray())
        }
        if base == "map" || base == "unordered_map" { return .map(MLMap()) }
        switch base {
        case "int", "long", "short", "size_t", "long long", "unsigned", "unsigned int",
             "int64_t", "int32_t", "uint64_t", "uint32_t", "char", "signed", "unsigned long":
            return .int(0)
        case "double", "float", "long double": return .double(0)
        case "bool": return .bool(false)
        case "string", "wstring": return .string("")
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        let base = MLInterpreter.baseTypeName(typeName)
        if ["double", "float", "long double"].contains(base), case .int(let n) = value.forced {
            return .double(Double(n))
        }
        if ["int", "long", "short", "size_t", "long long"].contains(base),
           case .double(let n) = value.forced {
            return .int(Int64(n))
        }
        if base == "bool", case .int(let n) = value.forced { return .bool(n != 0) }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        // `std::cout << x`
        if op == "<<", let stream = lhs.asObject, stream.typeName == "ostream" {
            if let object = rhs.asObject, object.typeName == "manipulator",
               case .symbol(let name)? = object.attachment {
                if name == "endl" {
                    interpreter.write(pendingOutput + "\n")
                    pendingOutput = ""
                }
                return lhs
            }
            pendingOutput += display(rhs)
            return lhs
        }
        if op == ">>", let stream = lhs.asObject, stream.typeName == "istream" {
            return lhs
        }
        if op == "+", case .string(let left) = lhs.forced {
            return .string(left + display(rhs))
        }
        if op == "+", case .string(let right) = rhs.forced {
            return .string(display(lhs) + right)
        }
        if op == "+", case .char(let left) = lhs.forced, case .string(let right) = rhs.forced {
            return .string(String(left) + right)
        }
        // char は整数として計算する。
        if "+-*/%".contains(op), op.count == 1 {
            if case .char(let left) = lhs.forced, rhs.isNumeric {
                let number = Int64(left.unicodeScalars.first?.value ?? 0)
                return try MLOperations.arithmetic(op: op, lhs: .int(number), rhs: rhs,
                                                   semantics: self)
            }
            if case .char(let right) = rhs.forced, lhs.isNumeric {
                let number = Int64(right.unicodeScalars.first?.value ?? 0)
                return try MLOperations.arithmetic(op: op, lhs: lhs, rhs: .int(number),
                                                   semantics: self)
            }
        }
        return nil
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        CppLibrary.install(into: environment, semantics: self)
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try CppLibrary.method(on: value, name: name, context: context, semantics: self)
    }

    override func finish(interpreter: MLInterpreter) {
        // `endl` で流し込まれなかったぶんを出す。
        if !pendingOutput.isEmpty {
            interpreter.write(pendingOutput)
            pendingOutput = ""
        }
    }
}

/// C++ の標準ライブラリ。
enum CppLibrary {

    /// `operator<<` の既定は有効数字 6 桁。
    static func streamDouble(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return "0" }
        let magnitude = Swift.abs(value)
        if magnitude >= 1e-5 && magnitude < 1e6 {
            var text = String(format: "%.6g", value)
            // `%g` は末尾の 0 を落とすので、そのまま使える。
            if text.contains("e") {
                text = text.replacingOccurrences(of: "e+0", with: "e+")
                    .replacingOccurrences(of: "e-0", with: "e-")
            }
            return text
        }
        var text = String(format: "%.6g", value)
        if let marker = text.firstIndex(where: { $0 == "e" }) {
            let mantissa = String(text[..<marker])
            var exponent = String(text[text.index(after: marker)...])
            let sign = exponent.hasPrefix("-") ? "-" : "+"
            exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            while exponent.count < 2 { exponent = "0" + exponent }
            text = mantissa + "e" + sign + exponent
        }
        return text
    }

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

    static func manipulator(_ name: String) -> MLValue {
        let object = MLObject(typeName: "manipulator")
        object.attachment = .symbol(name)
        return .object(object)
    }

    static func install(into environment: MLEnvironment, semantics: CppSemantics) {
        let cout = MLObject(typeName: "ostream")
        let cerr = MLObject(typeName: "ostream")
        let cin = MLObject(typeName: "istream")

        environment.define("cout", .object(cout), isConstant: true)
        environment.define("cerr", .object(cerr), isConstant: true)
        environment.define("cin", .object(cin), isConstant: true)
        environment.define("endl", manipulator("endl"), isConstant: true)

        // `std::` を書いても同じものが引けるようにする。
        var stdEntries: [(String, MLValue)] = [
            ("cout", .object(cout)),
            ("cerr", .object(cerr)),
            ("cin", .object(cin)),
            ("endl", manipulator("endl")),
            ("string", function("string", 0...2) { context in
                if let count = context.optionalArgument(0)?.asInt,
                   let character = context.optionalArgument(1)?.asString?.first {
                    return .string(String(repeating: String(character),
                                          count: Swift.max(0, Int(count))))
                }
                return .string(context.optionalArgument(0).map { semantics.display($0) } ?? "")
            })
        ]

        let helpers: [(String, MLValue)] = [
            ("to_string", function("to_string", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("stoi", function("stoi", 1...2) { context in
                let text = try context.requireString(0, "stoi").trimmingCharacters(in: .whitespaces)
                guard let value = Int64(text) else {
                    throw MLError.runtime("stoi: 数値に変換できません: \(text)")
                }
                return .int(value)
            }),
            ("stol", function("stol", 1...2) { context in
                let text = try context.requireString(0, "stol").trimmingCharacters(in: .whitespaces)
                guard let value = Int64(text) else {
                    throw MLError.runtime("stol: 数値に変換できません: \(text)")
                }
                return .int(value)
            }),
            ("stod", function("stod", 1...2) { context in
                let text = try context.requireString(0, "stod").trimmingCharacters(in: .whitespaces)
                guard let value = Double(text) else {
                    throw MLError.runtime("stod: 数値に変換できません: \(text)")
                }
                return .double(value)
            }),
            ("getline", function("getline", 2...3) { context in
                guard context.boxes.count > 1, let box = context.boxes[1] else { return .unit }
                guard let line = context.interpreter.input.nextLine() else {
                    return .bool(false)
                }
                box.value = .string(line)
                return .bool(true)
            }),
            ("swap", function("swap", 2) { context in
                guard context.boxes.count > 1, let left = context.boxes[0],
                      let right = context.boxes[1] else { return .unit }
                let temporary = left.value
                left.value = right.value
                right.value = temporary
                return .unit
            }),
            ("max", function("max", 1...8) { context in
                try MLStdlib.reduceExtreme(context, keepSmaller: false)
            }),
            ("min", function("min", 1...8) { context in
                try MLStdlib.reduceExtreme(context, keepSmaller: true)
            }),
            ("abs", function("abs", 1) { context in
                switch context.argument(0) {
                case .int(let value): return .int(value < 0 ? -value : value)
                case .double(let value): return .double(Swift.abs(value))
                default: throw MLError.runtime("abs: 数値が必要です")
                }
            }),
            ("sort", function("sort", 1...3) { context in
                try sortRange(context)
            }),
            ("reverse", function("reverse", 1...2) { context in
                context.argument(0).asArray?.elements.reverse()
                return .unit
            }),
            ("accumulate", function("accumulate", 2...4) { context in
                guard let array = context.argument(0).asArray else { return .int(0) }
                var total = context.optionalArgument(2) ?? .int(0)
                // `accumulate(v.begin(), v.end(), 0)` の形は begin/end が配列になる。
                if context.arguments.count == 2 { total = context.argument(1) }
                for element in array.elements {
                    total = try MLOperations.arithmetic(op: "+", lhs: total, rhs: element,
                                                        semantics: semantics)
                }
                return total
            }),
            ("find", function("find", 2...3) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let target = context.arguments.count >= 3 ? context.argument(2)
                                                          : context.argument(1)
                if let index = array.elements.firstIndex(where: {
                    semantics.areEqual($0, target)
                }) {
                    return .int(Int64(index))
                }
                return .int(Int64(array.count))
            }),
            ("count", function("count", 2...3) { context in
                guard let array = context.argument(0).asArray else { return .int(0) }
                let target = context.arguments.count >= 3 ? context.argument(2)
                                                          : context.argument(1)
                return .int(Int64(array.elements.filter { semantics.areEqual($0, target) }.count))
            }),
            ("make_pair", function("make_pair", 2) { context in
                .tuple([context.argument(0), context.argument(1)])
            }),
            ("pair", function("pair", 2) { context in
                .tuple([context.argument(0), context.argument(1)])
            }),
            ("printf", function("printf", 1...32) { context in
                let pattern = try context.requireString(0, "printf")
                semantics.pendingOutput += try MLStdlib.format(
                    pattern, arguments: Array(context.arguments.dropFirst()),
                    semantics: semantics)
                // C の printf は行バッファではないのでそのまま出す。
                context.interpreter.write(semantics.pendingOutput)
                semantics.pendingOutput = ""
                return .unit
            }),
            ("#newArray", function("#newArray", 2) { context in
                let count = Int(try context.requireInt(0, "配列の生成"))
                let element = semantics.defaultValue(
                    forTypeName: context.argument(1).asString ?? "")
                return .array(MLArray(Array(repeating: element, count: Swift.max(0, count))))
            })
        ]
        for (name, value) in helpers {
            environment.define(name, value, isConstant: true)
            stdEntries.append((name, value))
        }

        // コンテナの生成。
        for name in ["vector", "deque", "list", "set", "multiset", "unordered_set",
                     "stack", "queue", "priority_queue", "array"] {
            let maker = function(name, 0...2) { context in
                if let count = context.optionalArgument(0)?.asInt {
                    let fill = context.optionalArgument(1) ?? .int(0)
                    return .array(MLArray(Array(repeating: fill,
                                                count: Swift.max(0, Int(count)))))
                }
                return .array(MLArray())
            }
            environment.define(name, maker, isConstant: true)
            stdEntries.append((name, maker))
        }
        for name in ["map", "unordered_map", "multimap"] {
            let maker = function(name, 0...1) { _ in MLValue.map(MLMap()) }
            environment.define(name, maker, isConstant: true)
            stdEntries.append((name, maker))
        }

        for (name, implementation) in MLStdlib.mathFunctions {
            let value = function(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            }
            environment.define(name, value, isConstant: true)
            stdEntries.append((name, value))
        }
        let powFunction = function("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        }
        environment.define("pow", powFunction, isConstant: true)
        stdEntries.append(("pow", powFunction))

        environment.define("std", .object(namespace("std", stdEntries)), isConstant: true)
        environment.define("INT_MAX", .int(Int64(Int32.max)), isConstant: true)
        environment.define("INT_MIN", .int(Int64(Int32.min)), isConstant: true)
        environment.define("M_PI", .double(Double.pi), isConstant: true)
        environment.define("exit", .function(.native("exit", 0...1) { context in
            throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
        }), isConstant: true)
    }

    /// `sort(v.begin(), v.end())` と `sort(v)` の両方を受け付ける。
    static func sortRange(_ context: MLCallContext) throws -> MLValue {
        guard let array = context.argument(0).asArray else { return .unit }
        var comparator: MLFunction?
        for argument in context.arguments.dropFirst() {
            if let function = argument.asFunction { comparator = function }
        }
        array.elements = try MLStdlib.stableSorted(array.elements,
                                                   interpreter: context.interpreter,
                                                   comparator: comparator)
        return .unit
    }

    // MARK: メソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: CppSemantics) throws -> MLValue? {
        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context, semantics: semantics)
        case .array(let array):
            return try containerMethod(array, name: name, context: context,
                                       semantics: semantics)
        case .map(let map):
            return try mapMethod(map, name: name, context: context, semantics: semantics)
        case .tuple(let items):
            switch name {
            case "first": return items.first ?? .unit
            case "second": return items.count > 1 ? items[1] : .unit
            default: return nil
            }
        default:
            return nil
        }
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: CppSemantics) throws -> MLValue? {
        let characters = Array(text)
        switch name {
        case "size", "length": return .int(Int64(characters.count))
        case "empty": return .bool(text.isEmpty)
        case "at":
            let position = Int(try context.requireInt(0, "at"))
            guard position >= 0, position < characters.count else {
                throw MLError.runtime("std::string::at: 範囲外です")
            }
            return .char(characters[position])
        case "substr":
            let start = Int(try context.requireInt(0, "substr"))
            let count = context.optionalArgument(1)?.asInt.map { Int($0) }
                ?? (characters.count - start)
            let low = Swift.max(0, Swift.min(start, characters.count))
            let high = Swift.max(low, Swift.min(low + count, characters.count))
            return .string(String(characters[low..<high]))
        case "find":
            guard let needle = context.argument(0).asString else {
                return .int(Int64(text.count))
            }
            guard let found = MLStdlib.firstIndex(of: needle, in: characters) else {
                // std::string::npos
                return .int(-1)
            }
            return .int(Int64(found))
        case "push_back":
            if let box = context.boxes.first ?? nil,
               let character = context.argument(0).asString {
                box.value = .string(text + character)
            }
            return .unit
        case "c_str", "data": return .string(text)
        case "begin", "end": return .array(MLArray(characters.map { .char($0) }))
        case "erase", "clear":
            if let box = context.boxes.first ?? nil { box.value = .string("") }
            return .unit
        case "compare":
            return .int(Int64(semantics.compare(.string(text), context.argument(0)) ?? 0))
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    static func containerMethod(_ array: MLArray, name: String, context: MLCallContext,
                                semantics: CppSemantics) throws -> MLValue? {
        switch name {
        case "size", "length": return .int(Int64(array.count))
        case "empty": return .bool(array.elements.isEmpty)
        case "push_back", "push", "insert", "emplace_back", "emplace":
            array.elements.append(context.argument(0))
            return .unit
        case "pop_back":
            _ = array.elements.popLast()
            return .unit
        case "pop", "pop_front":
            if !array.elements.isEmpty { array.elements.removeFirst() }
            return .unit
        case "push_front":
            array.elements.insert(context.argument(0), at: 0)
            return .unit
        case "front", "top": return array.elements.first ?? .unit
        case "back": return array.elements.last ?? .unit
        case "at":
            let position = Int(try context.requireInt(0, "at"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("std::vector::at: 範囲外です")
            }
            return array.elements[position]
        case "clear":
            array.elements.removeAll()
            return .unit
        case "begin", "end", "rbegin", "rend":
            return .array(array)
        case "resize":
            let count = Int(try context.requireInt(0, "resize"))
            let fill = context.optionalArgument(1) ?? .int(0)
            while array.count < count { array.elements.append(fill) }
            while array.count > count { array.elements.removeLast() }
            return .unit
        case "count":
            let target = context.argument(0)
            return .int(Int64(array.elements.filter { semantics.areEqual($0, target) }.count))
        case "erase":
            if let position = context.argument(0).asInt,
               position >= 0, Int(position) < array.count {
                array.elements.remove(at: Int(position))
            }
            return .unit
        default:
            return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: CppSemantics) throws -> MLValue? {
        switch name {
        case "size": return .int(Int64(map.count))
        case "empty": return .bool(map.isEmpty)
        case "insert":
            if case .tuple(let items) = context.argument(0).forced, items.count >= 2,
               let key = MLKey.from(items[0]) {
                map[key] = items[1]
            }
            return .unit
        case "count":
            guard let key = MLKey.from(context.argument(0)) else { return .int(0) }
            return .int(map.contains(key) ? 1 : 0)
        case "find":
            guard let key = MLKey.from(context.argument(0)), map.contains(key) else {
                return .unit
            }
            return .tuple([key.asValue, map[key] ?? .unit])
        case "erase":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            _ = map.removeValue(forKey: key)
            return .unit
        case "clear":
            map.removeAll()
            return .unit
        case "at":
            guard let key = MLKey.from(context.argument(0)), let value = map[key] else {
                throw MLError.runtime("std::map::at: キーがありません")
            }
            return value
        case "begin", "end":
            return .array(MLArray(map.pairs.map { .tuple([$0.key.asValue, $0.value]) }))
        default:
            return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
        }
    }
}
