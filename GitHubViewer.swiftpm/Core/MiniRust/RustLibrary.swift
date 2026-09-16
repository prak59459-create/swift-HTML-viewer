import Foundation

/// Rust らしい振る舞い。
final class RustSemantics: MLSemantics {
    override var languageID: String { "rust" }
    override var displayName: String { "内蔵 Rust 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("bool が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool: return "bool"
        case .int: return "i32"
        case .double: return "f64"
        case .char: return "char"
        case .string: return "String"
        case .array: return "Vec"
        case .map: return "HashMap"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.shortestStyle(value)
    }

    /// `{}` (Display) 用の表示。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.shortestStyle(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        default: return inspect(value)
        }
    }

    /// `{:?}` (Debug) 用の表示。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "()"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            // Rust の Debug は整数値でも `.0` を付ける。
            return number == number.rounded() && Swift.abs(number) < 1e16
                ? String(format: "%.1f", number)
                : MLNumberFormatting.shortestStyle(number)
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "'\(character)'"
        case .array(let array):
            return "[" + array.elements.map { inspect($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(inspect($0.key.asValue)): \(inspect($0.value))" }
                .joined(separator: ", ") + "}"
        case .tuple(let items):
            if items.count == 1 { return "(" + inspect(items[0]) + ",)" }
            return "(" + items.map { inspect($0) }.joined(separator: ", ") + ")"
        case .object(let object):
            if let caseName = object.caseName {
                if object.payload.isEmpty { return caseName }
                return caseName + "(" + object.payload.map { inspect($0) }
                    .joined(separator: ", ") + ")"
            }
            if object.fields.isEmpty { return object.typeName }
            let items = object.fields.pairs.map { pair -> String in
                "\(pair.key.asValue.asString ?? ""): \(inspect(pair.value))"
            }
            return object.typeName + " { " + items.joined(separator: ", ") + " }"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        if typeName.hasPrefix("Vec") || typeName.hasPrefix("Array") { return .array(MLArray()) }
        if typeName.hasPrefix("HashMap") || typeName.hasPrefix("BTreeMap") {
            return .map(MLMap())
        }
        switch typeName {
        case "i8", "i16", "i32", "i64", "i128", "isize",
             "u8", "u16", "u32", "u64", "u128", "usize":
            return .int(0)
        case "f32", "f64": return .double(0)
        case "bool": return .bool(false)
        case "String", "str": return .string("")
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["f32", "f64"].contains(typeName), case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        if op == "+", case .string(let left) = lhs.forced {
            return .string(left + display(rhs))
        }
        if op == "..=" {
            guard let low = lhs.asInt, let high = rhs.asInt else { return nil }
            return .range(MLRange(lower: low, upper: high, isClosed: true))
        }
        if op == "..", lhs.asInt != nil, rhs.asInt != nil {
            return .range(MLRange(lower: lhs.asInt ?? 0, upper: rhs.asInt ?? 0,
                                  isClosed: false))
        }
        return nil
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        RustLibrary.install(into: environment, semantics: self)
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try RustLibrary.method(on: value, name: name, context: context, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        // `String::from` / `Vec::new` などの関連関数。
        if let klass = interpreter.isClassToken(value) {
            _ = klass
            return nil
        }
        return nil
    }
}

/// Rust の標準ライブラリ。
enum RustLibrary {

    static func install(into environment: MLEnvironment, semantics: RustSemantics) {
        // `println!` / `print!` / `format!` などのマクロ。
        environment.define("println!", .function(.native("println!", 0...32) { context in
            context.interpreter.write(try rustFormat(context, semantics: semantics) + "\n")
            return .unit
        }))
        environment.define("print!", .function(.native("print!", 0...32) { context in
            context.interpreter.write(try rustFormat(context, semantics: semantics))
            return .unit
        }))
        environment.define("eprintln!", .function(.native("eprintln!", 0...32) { context in
            context.interpreter.write(try rustFormat(context, semantics: semantics) + "\n")
            return .unit
        }))
        environment.define("format!", .function(.native("format!", 0...32) { context in
            .string(try rustFormat(context, semantics: semantics))
        }))
        environment.define("vec!", .function(.native("vec!", 0...64) { context in
            // `vec![0; 10]` の形は引数 2 つで来る。
            if context.arguments.count == 2, let count = context.arguments[1].asInt,
               context.labels.allSatisfy({ $0 == nil }), count >= 0,
               isRepeatForm(context) {
                return .array(MLArray(Array(repeating: context.argument(0),
                                            count: Int(count))))
            }
            return .array(MLArray(context.arguments))
        }))
        environment.define("panic!", .function(.native("panic!", 0...32) { context in
            throw MLError.runtime("panicked at '" +
                                  (try rustFormat(context, semantics: semantics)) + "'")
        }))
        environment.define("assert!", .function(.native("assert!", 1...32) { context in
            if try !semantics.isTruthy(context.argument(0)) {
                throw MLError.runtime("assertion failed")
            }
            return .unit
        }))
        environment.define("assert_eq!", .function(.native("assert_eq!", 2...32) { context in
            if !semantics.areEqual(context.argument(0), context.argument(1)) {
                throw MLError.runtime("assertion failed: `(left == right)`\n  left: `"
                                      + semantics.inspect(context.argument(0))
                                      + "`,\n right: `"
                                      + semantics.inspect(context.argument(1)) + "`")
            }
            return .unit
        }))
        environment.define("#repeatArray", .function(.native("#repeatArray", 2) { context in
            let count = Int(try context.requireInt(1, "[v; n]"))
            return .array(MLArray(Array(repeating: context.argument(0),
                                        count: Swift.max(0, count))))
        }))

        // Option / Result。
        environment.define("Some", .function(.native("Some", 1) { context in
            let object = MLObject(typeName: "Option", caseName: "Some")
            object.payload = [context.argument(0)]
            return .object(object)
        }), isConstant: true)
        environment.define("None", .object(MLObject(typeName: "Option", caseName: "None")),
                           isConstant: true)
        environment.define("Ok", .function(.native("Ok", 0...1) { context in
            let object = MLObject(typeName: "Result", caseName: "Ok")
            object.payload = context.arguments.isEmpty ? [.unit] : [context.argument(0)]
            return .object(object)
        }), isConstant: true)
        environment.define("Err", .function(.native("Err", 1) { context in
            let object = MLObject(typeName: "Result", caseName: "Err")
            object.payload = [context.argument(0)]
            return .object(object)
        }), isConstant: true)

        environment.define("String", .object(makeStringStatics(semantics: semantics)),
                           isConstant: true)
        environment.define("Vec", .object(makeVecStatics()), isConstant: true)
        environment.define("HashMap", .object(makeMapStatics()), isConstant: true)
        environment.define("BTreeMap", .object(makeMapStatics()), isConstant: true)
        environment.define("HashSet", .object(makeVecStatics()), isConstant: true)
        environment.define("VecDeque", .object(makeVecStatics()), isConstant: true)
        environment.define("std", .object(makeStd()), isConstant: true)
        environment.define("i32", .object(makeIntStatics(bits: 32)), isConstant: true)
        environment.define("i64", .object(makeIntStatics(bits: 64)), isConstant: true)
        environment.define("u32", .object(makeIntStatics(bits: 32)), isConstant: true)
        environment.define("usize", .object(makeIntStatics(bits: 64)), isConstant: true)
        environment.define("f64", .object(makeFloatStatics()), isConstant: true)
    }

    /// `vec![v; n]` の形かどうかを、引数の形から推測する。
    private static func isRepeatForm(_ context: MLCallContext) -> Bool {
        // 構文解析側で `;` を見たときだけ 2 引数にしているので、
        // ここでは 2 つめが非負整数であることだけ確かめる。
        (context.arguments[1].asInt ?? -1) >= 0
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

    /// Rust の `{}` / `{:?}` / `{:.2}` / `{0}` / `{name}` を処理する。
    static func rustFormat(_ context: MLCallContext,
                           semantics: RustSemantics) throws -> String {
        guard let pattern = context.optionalArgument(0)?.asString else { return "" }
        let arguments = Array(context.arguments.dropFirst())
        var result = ""
        var nextIndex = 0
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "{" {
                if index + 1 < characters.count, characters[index + 1] == "{" {
                    result.append("{")
                    index += 2
                    continue
                }
                guard let close = characters[index...].firstIndex(of: "}") else {
                    result.append(character)
                    index += 1
                    continue
                }
                let inside = String(characters[(index + 1)..<close])
                index = close + 1

                let parts = inside.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let selector = String(parts[0])
                let specifier = parts.count > 1 ? String(parts[1]) : ""
                var value = MLValue.unit
                if selector.isEmpty {
                    if nextIndex < arguments.count { value = arguments[nextIndex] }
                    nextIndex += 1
                } else if let position = Int(selector) {
                    if position < arguments.count { value = arguments[position] }
                } else if let box = context.interpreter.globals.lookup(selector) {
                    value = box.value
                }
                result += render(value, specifier: specifier, semantics: semantics)
                continue
            }
            if character == "}" {
                if index + 1 < characters.count, characters[index + 1] == "}" {
                    result.append("}")
                    index += 2
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    static func render(_ value: MLValue, specifier: String,
                       semantics: RustSemantics) -> String {
        var body = specifier
        var isDebug = false
        if body.hasSuffix("?") {
            isDebug = true
            body.removeLast()
            if body.hasSuffix("#") { body.removeLast() }
        }
        var text = isDebug ? semantics.inspect(value) : semantics.display(value)

        // `{:.2}` のような精度。
        if let dot = body.firstIndex(of: ".") {
            let digits = Int(body[body.index(after: dot)...]) ?? 0
            if let number = value.asDouble {
                text = MLNumberFormatting.fixed(number, digits: digits)
            }
            body = String(body[..<dot])
        }
        // 進数指定。
        if body.hasSuffix("b") { text = String(value.asInt ?? 0, radix: 2); body.removeLast() }
        else if body.hasSuffix("x") {
            text = String(value.asInt ?? 0, radix: 16)
            body.removeLast()
        } else if body.hasSuffix("X") {
            text = String(value.asInt ?? 0, radix: 16).uppercased()
            body.removeLast()
        } else if body.hasSuffix("o") {
            text = String(value.asInt ?? 0, radix: 8)
            body.removeLast()
        }
        // 幅と寄せ。
        var fill: Character = " "
        var alignment: Character = value.isNumeric ? ">" : "<"
        var rest = Array(body)
        if rest.count >= 2, "<>^".contains(rest[1]) {
            fill = rest[0]
            alignment = rest[1]
            rest.removeFirst(2)
        } else if let first = rest.first, "<>^".contains(first) {
            alignment = first
            rest.removeFirst()
        }
        if let first = rest.first, first == "0" {
            fill = "0"
            alignment = ">"
            rest.removeFirst()
        }
        let widthText = String(rest.prefix(while: { $0.isNumber }))
        guard let width = Int(widthText), text.count < width else { return text }
        let padding = width - text.count
        switch alignment {
        case "<": return text + String(repeating: fill, count: padding)
        case "^":
            let left = padding / 2
            return String(repeating: fill, count: left) + text
                + String(repeating: fill, count: padding - left)
        default: return String(repeating: fill, count: padding) + text
        }
    }

    static func makeStringStatics(semantics: RustSemantics) -> MLObject {
        namespace("String", [
            ("new", function("new", 0...0) { _ in .string("") }),
            ("from", function("from", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("with_capacity", function("with_capacity", 1) { _ in .string("") })
        ])
    }

    static func makeVecStatics() -> MLObject {
        namespace("Vec", [
            ("new", function("new", 0...0) { _ in .array(MLArray()) }),
            ("with_capacity", function("with_capacity", 1) { _ in .array(MLArray()) }),
            ("from", function("from", 1) { context in
                guard let array = context.argument(0).asArray else { return .array(MLArray()) }
                return .array(MLArray(array.elements))
            })
        ])
    }

    static func makeMapStatics() -> MLObject {
        namespace("HashMap", [
            ("new", function("new", 0...0) { _ in .map(MLMap()) }),
            ("with_capacity", function("with_capacity", 1) { _ in .map(MLMap()) })
        ])
    }

    static func makeIntStatics(bits: Int) -> MLObject {
        let maximum: Int64 = bits == 32 ? Int64(Int32.max) : Int64.max
        let minimum: Int64 = bits == 32 ? Int64(Int32.min) : Int64.min
        return namespace("i\(bits)", [
            ("MAX", .int(maximum)),
            ("MIN", .int(minimum)),
            ("from_str_radix", function("from_str_radix", 2) { context in
                let text = try context.requireString(0, "from_str_radix")
                let radix = Int(try context.requireInt(1, "from_str_radix"))
                let object = MLObject(typeName: "Result")
                if let value = Int64(text, radix: radix) {
                    object.caseName = "Ok"
                    object.payload = [.int(value)]
                } else {
                    object.caseName = "Err"
                    object.payload = [.string("invalid digit")]
                }
                return .object(object)
            })
        ])
    }

    static func makeFloatStatics() -> MLObject {
        namespace("f64", [
            ("MAX", .double(Double.greatestFiniteMagnitude)),
            ("MIN", .double(-Double.greatestFiniteMagnitude)),
            ("INFINITY", .double(Double.infinity)),
            ("NAN", .double(Double.nan)),
            ("EPSILON", .double(Double.ulpOfOne))
        ])
    }

    static func makeStd() -> MLObject {
        var mathEntries: [(String, MLValue)] = [
            ("PI", .double(Double.pi)),
            ("E", .double(M_E))
        ]
        _ = mathEntries
        let consts = namespace("consts", [("PI", .double(Double.pi)), ("E", .double(M_E))])
        let f64Module = namespace("f64", [("consts", .object(consts))])
        let stdMath = namespace("math", [("f64", .object(f64Module))])
        let io = namespace("io", [
            ("stdin", function("stdin", 0...0) { _ in .object(MLObject(typeName: "Stdin")) })
        ])
        let process = namespace("process", [
            ("exit", function("exit", 0...1) { context in
                throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
            })
        ])
        return namespace("std", [
            ("f64", .object(f64Module)),
            ("math", .object(stdMath)),
            ("io", .object(io)),
            ("process", .object(process)),
            ("cmp", .object(namespace("cmp", [
                ("max", function("max", 2) { context in
                    try MLStdlib.reduceExtreme(context, keepSmaller: false)
                }),
                ("min", function("min", 2) { context in
                    try MLStdlib.reduceExtreme(context, keepSmaller: true)
                })
            ])))
        ])
    }

    // MARK: メソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: RustSemantics) throws -> MLValue? {
        let interpreter = context.interpreter

        // `map.entry(k).or_insert(v)` の受け皿。
        if let entry = receiver.asObject, entry.typeName == "Entry",
           case .map(let map)? = entry.attachment,
           let key = entry.fields[.string("#key")].flatMap({ MLKey.from($0) }) {
            switch name {
            case "or_insert":
                if map[key] == nil { map[key] = context.argument(0) }
                // `*map.entry(k).or_insert(0) += 1` と書けるよう、
                // 値ではなく「書き込める場所」を返す。
                return interpreter.makeReference(to: interpreter.box(forKey: key, in: map))
            case "or_insert_with":
                if map[key] == nil {
                    let producer = try context.requireFunction(0, "or_insert_with")
                    map[key] = try interpreter.callFunction(producer, arguments: [])
                }
                return interpreter.makeReference(to: interpreter.box(forKey: key, in: map))
            case "or_default":
                if map[key] == nil { map[key] = .int(0) }
                return interpreter.makeReference(to: interpreter.box(forKey: key, in: map))
            case "and_modify":
                if map[key] != nil {
                    let update = try context.requireFunction(0, "and_modify")
                    map[key] = try interpreter.callFunction(update,
                                                            arguments: [map[key] ?? .unit])
                }
                return receiver
            default:
                break
            }
        }

        // Option / Result のメソッド。
        if let object = receiver.asObject, let caseName = object.caseName,
           object.typeName == "Option" || object.typeName == "Result" {
            let isGood = caseName == "Some" || caseName == "Ok"
            let payload = object.payload.first ?? .unit
            switch name {
            case "unwrap", "expect":
                guard isGood else {
                    let message = context.optionalArgument(0)?.asString
                        ?? "called `\(object.typeName)::unwrap()` on a `\(caseName)` value"
                    throw MLError.runtime(message)
                }
                return payload
            case "unwrap_or":
                return isGood ? payload : context.argument(0)
            case "unwrap_or_else":
                guard !isGood else { return payload }
                let producer = try context.requireFunction(0, "unwrap_or_else")
                return try interpreter.callFunction(producer,
                                                    arguments: isGood ? [] : [payload])
            case "unwrap_or_default":
                return isGood ? payload : .int(0)
            case "is_some", "is_ok": return .bool(isGood)
            case "is_none", "is_err": return .bool(!isGood)
            case "map":
                guard isGood else { return receiver }
                let transform = try context.requireFunction(0, "map")
                let result = MLObject(typeName: object.typeName, caseName: caseName)
                result.payload = [try interpreter.callFunction(transform, arguments: [payload])]
                return .object(result)
            case "and_then":
                guard isGood else { return receiver }
                let transform = try context.requireFunction(0, "and_then")
                return try interpreter.callFunction(transform, arguments: [payload])
            case "ok":
                let result = MLObject(typeName: "Option",
                                      caseName: isGood ? "Some" : "None")
                if isGood { result.payload = [payload] }
                return .object(result)
            default:
                break
            }
        }

        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context, semantics: semantics)
        case .char(let character):
            switch name {
            case "is_alphabetic": return .bool(character.isLetter)
            case "is_numeric", "is_ascii_digit": return .bool(character.isNumber)
            case "is_alphanumeric": return .bool(character.isLetter || character.isNumber)
            case "is_uppercase": return .bool(character.isUppercase)
            case "is_lowercase": return .bool(character.isLowercase)
            case "is_whitespace": return .bool(character.isWhitespace)
            case "to_uppercase", "to_ascii_uppercase":
                return .char(String(character).uppercased().first ?? character)
            case "to_lowercase", "to_ascii_lowercase":
                return .char(String(character).lowercased().first ?? character)
            case "to_digit":
                guard let digit = character.wholeNumberValue else {
                    return .object(MLObject(typeName: "Option", caseName: "None"))
                }
                let object = MLObject(typeName: "Option", caseName: "Some")
                object.payload = [.int(Int64(digit))]
                return .object(object)
            case "to_string": return .string(String(character))
            default:
                return try stringMethod(String(character), name: name, context: context,
                                        semantics: semantics)
            }
        case .array(let array):
            return try vecMethod(array, name: name, context: context, semantics: semantics)
        case .map(let map):
            return try mapMethod(map, name: name, context: context, semantics: semantics)
        case .range(let range):
            let array = MLArray(range.elements.map { .int($0) })
            return try vecMethod(array, name: name, context: context, semantics: semantics)
        case .int, .double:
            switch name {
            case "to_string": return .string(semantics.display(receiver))
            case "abs":
                if case .int(let number) = receiver.forced {
                    return .int(number < 0 ? -number : number)
                }
                return .double(Swift.abs(receiver.asDouble ?? 0))
            case "pow", "powi", "powf":
                let exponent = context.argument(0).asDouble ?? 0
                if case .int(let base) = receiver.forced, name == "pow" {
                    return MLOperations.power(Double(base), exponent, preferInteger: true)
                }
                return .double(Foundation.pow(receiver.asDouble ?? 0, exponent))
            case "sqrt": return .double(Foundation.sqrt(receiver.asDouble ?? 0))
            case "min": return try MLStdlib.reduceExtreme(
                MLCallContext(arguments: [receiver, context.argument(0)],
                              interpreter: interpreter), keepSmaller: true)
            case "max": return try MLStdlib.reduceExtreme(
                MLCallContext(arguments: [receiver, context.argument(0)],
                              interpreter: interpreter), keepSmaller: false)
            case "floor": return .double(Foundation.floor(receiver.asDouble ?? 0))
            case "ceil": return .double(Foundation.ceil(receiver.asDouble ?? 0))
            case "round": return .double((receiver.asDouble ?? 0).rounded())
            case "count_ones":
                return .int(Int64((receiver.asInt ?? 0).nonzeroBitCount))
            case "checked_div":
                let divisor = context.argument(0).asInt ?? 0
                let object = MLObject(typeName: "Option",
                                      caseName: divisor == 0 ? "None" : "Some")
                if divisor != 0 { object.payload = [.int((receiver.asInt ?? 0) / divisor)] }
                return .object(object)
            default:
                return try MLStdlib.callMethod(on: receiver, name: name, context: context)
            }
        case .tuple(let items):
            if name.hasPrefix("_"), let position = Int(name.dropFirst()),
               position < items.count {
                return items[position]
            }
            return nil
        default:
            return nil
        }
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: RustSemantics) throws -> MLValue? {
        switch name {
        case "len": return .int(Int64(text.utf8.count))
        case "is_empty": return .bool(text.isEmpty)
        case "push_str", "push":
            // 受け手の箱に書き戻す。
            let added = semantics.display(context.argument(0))
            if let box = context.boxes.first ?? nil { box.value = .string(text + added) }
            return .unit
        case "to_string", "to_owned", "clone", "as_str", "into": return .string(text)
        case "to_uppercase", "to_ascii_uppercase": return .string(text.uppercased())
        case "to_lowercase", "to_ascii_lowercase": return .string(text.lowercased())
        case "trim": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "trim_start": return .string(String(text.drop(while: { $0.isWhitespace })))
        case "trim_end":
            var result = text
            while let last = result.last, last.isWhitespace { result.removeLast() }
            return .string(result)
        case "chars": return .array(MLArray(text.map { .char($0) }))
        case "bytes", "as_bytes":
            return .array(MLArray(Array(text.utf8).map { .int(Int64($0)) }))
        case "split", "split_whitespace", "split_terminator":
            if name == "split_whitespace" {
                return .array(MLArray(text.split(whereSeparator: { $0.isWhitespace })
                    .map { .string(String($0)) }))
            }
            guard let separator = context.optionalArgument(0)?.asString else {
                return .array(MLArray(text.split(whereSeparator: { $0.isWhitespace })
                    .map { .string(String($0)) }))
            }
            let parts = separator.isEmpty ? text.map { String($0) }
                                          : text.components(separatedBy: separator)
            return .array(MLArray(parts.map { .string($0) }))
        case "lines":
            return .array(MLArray(text.components(separatedBy: "\n").map { .string($0) }))
        case "contains":
            guard let needle = context.argument(0).asString else { return .bool(false) }
            return .bool(needle.isEmpty || text.contains(needle))
        case "starts_with": return .bool(text.hasPrefix(context.argument(0).asString ?? ""))
        case "ends_with": return .bool(text.hasSuffix(context.argument(0).asString ?? ""))
        case "replace":
            return .string(text.replacingOccurrences(of: context.argument(0).asString ?? "",
                                                     with: context.argument(1).asString ?? ""))
        case "repeat":
            let count = Int(try context.requireInt(0, "repeat"))
            return .string(count > 0 ? String(repeating: text, count: count) : "")
        case "parse":
            let object = MLObject(typeName: "Result")
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Int64(trimmed) {
                object.caseName = "Ok"
                object.payload = [.int(value)]
            } else if let value = Double(trimmed) {
                object.caseName = "Ok"
                object.payload = [.double(value)]
            } else {
                object.caseName = "Err"
                object.payload = [.string("invalid digit found in string")]
            }
            return .object(object)
        case "find":
            guard let needle = context.argument(0).asString,
                  let found = MLStdlib.firstIndex(of: needle, in: Array(text)) else {
                return .object(MLObject(typeName: "Option", caseName: "None"))
            }
            let object = MLObject(typeName: "Option", caseName: "Some")
            object.payload = [.int(Int64(found))]
            return .object(object)
        case "rev": return .string(String(text.reversed()))
        case "collect": return .string(text)
        case "iter", "into_iter": return .array(MLArray(text.map { .char($0) }))
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    static func vecMethod(_ array: MLArray, name: String, context: MLCallContext,
                          semantics: RustSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch name {
        case "len": return .int(Int64(array.count))
        case "is_empty": return .bool(array.elements.isEmpty)
        case "push":
            array.elements.append(context.argument(0))
            return .unit
        case "pop":
            let object = MLObject(typeName: "Option")
            if let last = array.elements.popLast() {
                object.caseName = "Some"
                object.payload = [last]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "insert":
            let position = Int(try context.requireInt(0, "insert"))
            let clamped = Swift.max(0, Swift.min(position, array.count))
            array.elements.insert(context.argument(1), at: clamped)
            return .unit
        case "remove":
            let position = Int(try context.requireInt(0, "remove"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("removal index (is \(position)) should be < len (is \(array.count))")
            }
            return array.elements.remove(at: position)
        case "clear":
            array.elements.removeAll()
            return .unit
        case "get":
            let position = Int(try context.requireInt(0, "get"))
            let object = MLObject(typeName: "Option")
            if position >= 0, position < array.count {
                object.caseName = "Some"
                object.payload = [array.elements[position]]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "first", "last":
            let object = MLObject(typeName: "Option")
            let element = name == "first" ? array.elements.first : array.elements.last
            if let element {
                object.caseName = "Some"
                object.payload = [element]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "contains":
            let target = context.argument(0)
            return .bool(array.elements.contains { semantics.areEqual($0, target) })
        case "sort", "sort_unstable":
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: interpreter,
                                                       comparator: nil)
            return .unit
        case "sort_by", "sort_unstable_by":
            let comparator = try context.requireFunction(0, name)
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: interpreter,
                                                       comparator: comparator)
            return .unit
        case "sort_by_key":
            let key = try context.requireFunction(0, "sort_by_key")
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: interpreter,
                                                       comparator: key, byKey: true)
            return .unit
        case "reverse":
            array.elements.reverse()
            return .unit
        case "iter", "into_iter", "iter_mut", "collect", "to_vec", "clone", "cloned",
             "copied", "drain", "as_slice":
            return .array(MLArray(array.elements))
        case "enumerate":
            return .array(MLArray(array.elements.enumerated()
                .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
        case "map", "filter", "sum", "count", "fold", "rev", "take", "skip",
             "flat_map", "zip", "chain":
            return try iteratorMethod(array, name: name, context: context,
                                      semantics: semantics)
        case "max", "min":
            let object = MLObject(typeName: "Option")
            if array.elements.isEmpty {
                object.caseName = "None"
            } else {
                object.caseName = "Some"
                object.payload = [try MLStdlib.extreme(array.elements, semantics: semantics,
                                                        smaller: name == "min")]
            }
            return .object(object)
        case "any", "all":
            return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
        case "find", "position":
            let predicate = try context.requireFunction(0, name)
            for (index, element) in array.elements.enumerated()
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                let object = MLObject(typeName: "Option", caseName: "Some")
                object.payload = [name == "find" ? element : .int(Int64(index))]
                return .object(object)
            }
            return .object(MLObject(typeName: "Option", caseName: "None"))
        case "join":
            let separator = context.optionalArgument(0)?.asString ?? ""
            return .string(array.elements.map { semantics.display($0) }
                .joined(separator: separator))
        case "extend", "extend_from_slice", "append":
            if let other = context.argument(0).asArray {
                array.elements.append(contentsOf: other.elements)
            }
            return .unit
        case "swap":
            let a = Int(try context.requireInt(0, "swap"))
            let b = Int(try context.requireInt(1, "swap"))
            guard a >= 0, a < array.count, b >= 0, b < array.count else {
                throw MLError.runtime("swap: 添字が範囲外です")
            }
            array.elements.swapAt(a, b)
            return .unit
        case "windows", "chunks":
            return try MLStdlib.callMethod(on: .array(array), name: "chunked", context: context)
        case "dedup":
            var results: [MLValue] = []
            for element in array.elements {
                if let last = results.last, semantics.areEqual(last, element) { continue }
                results.append(element)
            }
            array.elements = results
            return .unit
        case "insert_str": return .unit
        default:
            return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
        }
    }

    /// イテレータ風のメソッド。Rust では遅延だが、ここでは即座に配列を作る。
    static func iteratorMethod(_ array: MLArray, name: String, context: MLCallContext,
                               semantics: RustSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch name {
        case "map":
            let transform = try context.requireFunction(0, "map")
            var results: [MLValue] = []
            for element in array.elements {
                results.append(try interpreter.callFunction(transform, arguments: [element]))
            }
            return .array(MLArray(results))
        case "filter":
            let predicate = try context.requireFunction(0, "filter")
            var results: [MLValue] = []
            for element in array.elements
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                results.append(element)
            }
            return .array(MLArray(results))
        case "flat_map":
            let transform = try context.requireFunction(0, "flat_map")
            var results: [MLValue] = []
            for element in array.elements {
                let value = try interpreter.callFunction(transform, arguments: [element])
                if let inner = value.asArray { results.append(contentsOf: inner.elements) }
                else if let text = value.asString { results += text.map { .char($0) } }
                else { results.append(value) }
            }
            return .array(MLArray(results))
        case "sum":
            var total = MLValue.int(0)
            for element in array.elements {
                total = try MLOperations.arithmetic(op: "+", lhs: total, rhs: element,
                                                    semantics: semantics)
            }
            return total
        case "count": return .int(Int64(array.count))
        case "fold":
            var accumulator = context.argument(0)
            let combine = try context.requireFunction(1, "fold")
            for element in array.elements {
                accumulator = try interpreter.callFunction(combine,
                                                           arguments: [accumulator, element])
            }
            return accumulator
        case "rev": return .array(MLArray(array.elements.reversed()))
        case "take":
            let count = Int(try context.requireInt(0, "take"))
            return .array(MLArray(Array(array.elements.prefix(Swift.max(0, count)))))
        case "skip":
            let count = Int(try context.requireInt(0, "skip"))
            return .array(MLArray(Array(array.elements.dropFirst(Swift.max(0, count)))))
        case "zip":
            guard let other = context.argument(0).asArray else { return .array(MLArray()) }
            var results: [MLValue] = []
            for index in 0..<Swift.min(array.count, other.count) {
                results.append(.tuple([array.elements[index], other.elements[index]]))
            }
            return .array(MLArray(results))
        case "chain":
            guard let other = context.argument(0).asArray else { return .array(array) }
            return .array(MLArray(array.elements + other.elements))
        default:
            return nil
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: RustSemantics) throws -> MLValue? {
        switch name {
        case "insert":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            let previous = map[key]
            map[key] = context.argument(1)
            let object = MLObject(typeName: "Option")
            if let previous {
                object.caseName = "Some"
                object.payload = [previous]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "get":
            let object = MLObject(typeName: "Option")
            if let key = MLKey.from(context.argument(0)), let value = map[key] {
                object.caseName = "Some"
                object.payload = [value]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "contains_key":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))
        case "remove":
            let object = MLObject(typeName: "Option")
            if let key = MLKey.from(context.argument(0)),
               let removed = map.removeValue(forKey: key) {
                object.caseName = "Some"
                object.payload = [removed]
            } else {
                object.caseName = "None"
            }
            return .object(object)
        case "entry":
            // `*map.entry(k).or_insert(0) += 1` の形をよく使うので簡単に扱えるようにする。
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            let entry = MLObject(typeName: "Entry")
            entry.fields[.string("#key")] = key.asValue
            entry.attachment = .map(map)
            return .object(entry)
        case "len": return .int(Int64(map.count))
        case "is_empty": return .bool(map.isEmpty)
        case "keys": return .array(MLArray(map.keys.map { $0.asValue }))
        case "values": return .array(MLArray(map.values))
        case "iter", "into_iter":
            return .array(MLArray(map.pairs.map { .tuple([$0.key.asValue, $0.value]) }))
        case "get_or_insert": return .unit
        default:
            return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
        }
    }
}
