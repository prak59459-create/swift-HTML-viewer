import Foundation

/// Go らしい振る舞い。
final class GoSemantics: MLSemantics {
    override var languageID: String { "go" }
    override var displayName: String { "内蔵 Go 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// struct は値型。
    override var usesValueSemantics: Bool { false }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("bool が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float64"
        case .char: return "rune"
        case .string: return "string"
        case .array: return "slice"
        case .map: return "map"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    /// Go の `fmt.Println` は `%v` 相当。
    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.shortestStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "<nil>"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return MLNumberFormatting.shortestStyle(number)
        case .string(let text): return text
        case .char(let character):
            // Go の rune は整数として表示される。
            return String(character.unicodeScalars.first?.value ?? 0)
        case .array(let array):
            return "[" + array.elements.map { display($0) }.joined(separator: " ") + "]"
        case .map(let map):
            // Go の map はキー順に並べて表示する。
            let sorted = map.pairs.sorted { lhs, rhs in
                (compare(lhs.key.asValue, rhs.key.asValue) ?? 0) < 0
            }
            return "map[" + sorted.map { "\(display($0.key.asValue)):\(display($0.value))" }
                .joined(separator: " ") + "]"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            let items = object.fields.values.map { display($0) }
            return "{" + items.joined(separator: " ") + "}"
        case .tuple(let items):
            return items.map { display($0) }.joined(separator: " ")
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        if typeName.hasPrefix("Array") { return .array(MLArray()) }
        if typeName.hasPrefix("Map") { return .map(MLMap()) }
        switch typeName {
        case "int", "int8", "int16", "int32", "int64",
             "uint", "uint8", "uint16", "uint32", "uint64", "byte", "rune":
            return .int(0)
        case "float32", "float64": return .double(0)
        case "bool": return .bool(false)
        case "string": return .string("")
        default:
            return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        if let typeName, ["float32", "float64"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        if op == "+", case .string = lhs.forced, case .string = rhs.forced {
            return .string((lhs.asString ?? "") + (rhs.asString ?? ""))
        }
        if op == "&^", let left = lhs.asInt, let right = rhs.asInt {
            return .int(left & ~right)
        }
        return nil
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        GoLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        // Go のメソッドは `型名.メソッド名` という関数として登録してある。
        if let object = value.asObject, let klass = object.classDeclaration {
            let qualified = "\(klass.name).\(name)"
            if let box = context.interpreter.globals.lookup(qualified),
               let function = box.value.asFunction {
                return try context.interpreter.callFunction(
                    function, arguments: [value] + arguments, location: context.location)
            }
        }
        return try GoLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}

/// Go の標準ライブラリのうちよく使うもの。
enum GoLibrary {

    static func install(into environment: MLEnvironment, semantics: GoSemantics) {
        environment.define("fmt", .object(makeFmt(semantics: semantics)), isConstant: true)
        environment.define("strings", .object(makeStrings(semantics: semantics)),
                           isConstant: true)
        environment.define("strconv", .object(makeStrconv(semantics: semantics)),
                           isConstant: true)
        environment.define("math", .object(makeMath()), isConstant: true)
        environment.define("sort", .object(makeSort()), isConstant: true)
        environment.define("os", .object(makeOS()), isConstant: true)
        environment.define("errors", .object(makeErrors()), isConstant: true)
        environment.define("time", .object(makeTime()), isConstant: true)
        environment.define("bufio", .object(MLObject(typeName: "bufio")), isConstant: true)

        environment.define("len", .function(.native("len", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
            if let text = value.asString { return .int(Int64(text.utf8.count)) }
            if case .range(let range) = value { return .int(Int64(range.elements.count)) }
            return .int(0)
        }))
        environment.define("cap", .function(.native("cap", 1) { context in
            .int(Int64(context.argument(0).asArray?.count ?? 0))
        }))
        environment.define("append", .function(.native("append", 1...64) { context in
            let base = context.argument(0).asArray?.elements ?? []
            var elements = base
            for argument in context.arguments.dropFirst() { elements.append(argument) }
            return .array(MLArray(elements))
        }))
        environment.define("copy", .function(.native("copy", 2) { context in
            guard let destination = context.argument(0).asArray,
                  let source = context.argument(1).asArray else { return .int(0) }
            let count = Swift.min(destination.count, source.count)
            for index in 0..<count { destination.elements[index] = source.elements[index] }
            return .int(Int64(count))
        }))
        environment.define("delete", .function(.native("delete", 2) { context in
            guard let map = context.argument(0).asMap,
                  let key = MLKey.from(context.argument(1)) else { return .unit }
            _ = map.removeValue(forKey: key)
            return .unit
        }))
        environment.define("make", .function(.native("make", 1...3) { context in
            // `make([]int, 5)` / `make(map[string]int)` は型名を文字列で受け取る。
            let typeName = context.argument(0).asString ?? ""
            if typeName.hasPrefix("Map") { return .map(MLMap()) }
            let count = Int(context.optionalArgument(1)?.asInt ?? 0)
            var element = MLValue.int(0)
            if let inner = typeName.firstIndex(of: "<") {
                let elementType = String(typeName[typeName.index(after: inner)...]
                    .dropLast())
                element = semantics.defaultValue(forTypeName: elementType)
            }
            return .array(MLArray(Array(repeating: element, count: Swift.max(0, count))))
        }))
        environment.define("new", .function(.native("new", 1) { context in
            let typeName = context.argument(0).asString ?? ""
            if let klass = context.interpreter.lookupClass(typeName) {
                return try context.interpreter.instantiate(klass, arguments: [], labels: [],
                                                           location: context.location)
            }
            return semantics.defaultValue(forTypeName: typeName)
        }))
        environment.define("panic", .function(.native("panic", 1) { context in
            throw MLError.runtime("panic: " + semantics.display(context.argument(0)))
        }))
        environment.define("recover", .function(.native("recover", 0...0) { _ in .unit }))
        environment.define("print", .function(.native("print", 0...32) { context in
            context.interpreter.write(context.arguments.map { semantics.display($0) }.joined())
            return .unit
        }))
        environment.define("println", .function(.native("println", 0...32) { context in
            context.interpreter.write(
                context.arguments.map { semantics.display($0) }.joined(separator: " ") + "\n")
            return .unit
        }))
        // `for i, v := range xs` の受け皿。
        environment.define("#enumerate", .function(.native("#enumerate", 1) { context in
            let value = context.argument(0)
            if let map = value.asMap {
                // map の range はキー順にして再現性を保つ。
                let sorted = map.pairs.sorted { lhs, rhs in
                    (semantics.compare(lhs.key.asValue, rhs.key.asValue) ?? 0) < 0
                }
                return .array(MLArray(sorted.map { .tuple([$0.key.asValue, $0.value]) }))
            }
            if let text = value.asString {
                var results: [MLValue] = []
                var offset = 0
                for character in text {
                    results.append(.tuple([.int(Int64(offset)), .char(character)]))
                    offset += String(character).utf8.count
                }
                return .array(MLArray(results))
            }
            if case .int(let count) = value.forced {
                return .array(MLArray((0..<Swift.max(0, Int(count)))
                    .map { .tuple([.int(Int64($0)), .int(Int64($0))]) }))
            }
            let items = try MLOperations.iterate(value, semantics: semantics)
            return .array(MLArray(items.enumerated()
                .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
        }))
        // 型変換関数。
        for name in ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                     "uint32", "uint64", "byte", "rune"] {
            environment.define(name, .function(.native(name, 1) { context in
                let value = context.argument(0)
                if let number = value.asDouble { return .int(Int64(number)) }
                if let text = value.asString, let first = text.first {
                    return .int(Int64(first.unicodeScalars.first?.value ?? 0))
                }
                return .int(0)
            }))
        }
        for name in ["float32", "float64"] {
            environment.define(name, .function(.native(name, 1) { context in
                .double(context.argument(0).asDouble ?? 0)
            }))
        }
        environment.define("string", .function(.native("string", 1) { context in
            let value = context.argument(0)
            if case .int(let number) = value.forced,
               let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                return .string(String(Character(scalar)))
            }
            if let array = value.asArray {
                var text = ""
                for element in array.elements {
                    if let number = element.asInt,
                       let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                        text.append(Character(scalar))
                    }
                }
                return .string(text)
            }
            return .string(semantics.display(value))
        }))
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

    static func makeFmt(semantics: GoSemantics) -> MLObject {
        namespace("fmt", [
            ("Println", function("Println", 0...32) { context in
                context.interpreter.write(
                    context.arguments.map { semantics.display($0) }
                        .joined(separator: " ") + "\n")
                return .unit
            }),
            ("Print", function("Print", 0...32) { context in
                // Go の Print は「両隣が文字列でないときだけ」空白を入れる。
                var text = ""
                for (index, argument) in context.arguments.enumerated() {
                    if index > 0 {
                        let previousIsString = context.arguments[index - 1].asString != nil
                        let currentIsString = argument.asString != nil
                        if !previousIsString && !currentIsString { text += " " }
                    }
                    text += semantics.display(argument)
                }
                context.interpreter.write(text)
                return .unit
            }),
            ("Printf", function("Printf", 1...32) { context in
                let pattern = try context.requireString(0, "fmt.Printf")
                context.interpreter.write(
                    try goFormat(pattern, Array(context.arguments.dropFirst()),
                                 semantics: semantics))
                return .unit
            }),
            ("Sprintf", function("Sprintf", 1...32) { context in
                let pattern = try context.requireString(0, "fmt.Sprintf")
                return .string(try goFormat(pattern, Array(context.arguments.dropFirst()),
                                            semantics: semantics))
            }),
            ("Sprint", function("Sprint", 0...32) { context in
                .string(context.arguments.map { semantics.display($0) }.joined())
            }),
            ("Sprintln", function("Sprintln", 0...32) { context in
                .string(context.arguments.map { semantics.display($0) }
                    .joined(separator: " ") + "\n")
            }),
            ("Errorf", function("Errorf", 1...32) { context in
                let pattern = try context.requireString(0, "fmt.Errorf")
                let object = MLObject(typeName: "error")
                object.fields[.string("message")] =
                    .string(try goFormat(pattern, Array(context.arguments.dropFirst()),
                                         semantics: semantics))
                return .object(object)
            }),
            ("Scan", function("Scan", 0...8) { context in
                var count = 0
                for box in context.boxes {
                    guard let box, let token = nextToken(context.interpreter) else { break }
                    if let number = Int64(token) { box.value = .int(number) }
                    else if let number = Double(token) { box.value = .double(number) }
                    else { box.value = .string(token) }
                    count += 1
                }
                return .int(Int64(count))
            }),
            ("Scanln", function("Scanln", 0...8) { context in
                guard let line = context.interpreter.input.nextLine() else { return .int(0) }
                let tokens = line.split(whereSeparator: { $0.isWhitespace })
                var count = 0
                for (index, box) in context.boxes.enumerated() {
                    guard let box, index < tokens.count else { break }
                    let token = String(tokens[index])
                    if let number = Int64(token) { box.value = .int(number) }
                    else if let number = Double(token) { box.value = .double(number) }
                    else { box.value = .string(token) }
                    count += 1
                }
                return .int(Int64(count))
            })
        ])
    }

    static func nextToken(_ interpreter: MLInterpreter) -> String? {
        var token = ""
        while let character = interpreter.input.nextCharacter() {
            if character.isWhitespace {
                if token.isEmpty { continue }
                break
            }
            token.append(character)
        }
        return token.isEmpty ? nil : token
    }

    /// Go の書式指定。`%v` などは C にないので自前で処理する。
    static func goFormat(_ pattern: String, _ arguments: [MLValue],
                         semantics: GoSemantics) throws -> String {
        var result = ""
        var argumentIndex = 0
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else {
                result.append(characters[index])
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { break }
            if characters[index] == "%" {
                result.append("%")
                index += 1
                continue
            }
            var spec = "%"
            while index < characters.count,
                  "-+ #0123456789.*".contains(characters[index]) {
                spec.append(characters[index])
                index += 1
            }
            guard index < characters.count else { break }
            let conversion = characters[index]
            index += 1
            let value = argumentIndex < arguments.count ? arguments[argumentIndex].forced : .unit
            argumentIndex += 1

            switch conversion {
            case "v":
                result += padded(semantics.display(value), spec: spec)
            case "T":
                result += semantics.typeName(of: value)
            case "d":
                result += try MLStdlib.format(spec + "d", arguments: [value],
                                              semantics: semantics)
            case "s", "q":
                var text = semantics.display(value)
                if conversion == "q" { text = "\"\(text)\"" }
                result += padded(text, spec: spec)
            case "f", "F", "e", "E", "g", "G":
                var effective = spec
                if conversion == "f", !spec.contains(".") { effective += ".6" }
                result += try MLStdlib.format(effective + String(conversion),
                                              arguments: [value], semantics: semantics)
            case "t":
                result += padded(semantics.display(value), spec: spec)
            case "x", "X", "o", "b":
                let radix = conversion == "b" ? 2 : (conversion == "o" ? 8 : 16)
                var text = String(value.asInt ?? 0, radix: radix)
                if conversion == "X" { text = text.uppercased() }
                result += padded(text, spec: spec)
            case "c":
                if let number = value.asInt,
                   let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                    result.append(Character(scalar))
                } else {
                    result += semantics.display(value)
                }
            default:
                result += "%!" + String(conversion) + "(" + semantics.display(value) + ")"
            }
        }
        return result
    }

    /// `%5v` のような幅指定を文字列に適用する。
    static func padded(_ text: String, spec: String) -> String {
        let body = spec.dropFirst()
        let leftAligned = body.contains("-")
        let digits = body.drop(while: { !$0.isNumber })
        let widthText = digits.prefix(while: { $0.isNumber })
        guard let width = Int(widthText), text.count < width else { return text }
        let filler = String(repeating: " ", count: width - text.count)
        return leftAligned ? text + filler : filler + text
    }

    static func makeStrings(semantics: GoSemantics) -> MLObject {
        namespace("strings", [
            ("Split", function("Split", 2) { context in
                let text = try context.requireString(0, "strings.Split")
                let separator = try context.requireString(1, "strings.Split")
                let parts = separator.isEmpty ? text.map { String($0) }
                                              : text.components(separatedBy: separator)
                return .array(MLArray(parts.map { .string($0) }))
            }),
            ("Join", function("Join", 2) { context in
                let array = try context.requireArray(0, "strings.Join")
                let separator = try context.requireString(1, "strings.Join")
                return .string(array.elements.map { semantics.display($0) }
                    .joined(separator: separator))
            }),
            ("Contains", function("Contains", 2) { context in
                let text = try context.requireString(0, "strings.Contains")
                let needle = try context.requireString(1, "strings.Contains")
                return .bool(needle.isEmpty || text.contains(needle))
            }),
            ("HasPrefix", function("HasPrefix", 2) { context in
                .bool(try context.requireString(0, "strings.HasPrefix")
                    .hasPrefix(try context.requireString(1, "strings.HasPrefix")))
            }),
            ("HasSuffix", function("HasSuffix", 2) { context in
                .bool(try context.requireString(0, "strings.HasSuffix")
                    .hasSuffix(try context.requireString(1, "strings.HasSuffix")))
            }),
            ("ToUpper", function("ToUpper", 1) { context in
                .string(try context.requireString(0, "strings.ToUpper").uppercased())
            }),
            ("ToLower", function("ToLower", 1) { context in
                .string(try context.requireString(0, "strings.ToLower").lowercased())
            }),
            ("TrimSpace", function("TrimSpace", 1) { context in
                .string(try context.requireString(0, "strings.TrimSpace")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }),
            ("Trim", function("Trim", 2) { context in
                let text = try context.requireString(0, "strings.Trim")
                let cutset = Set(try context.requireString(1, "strings.Trim"))
                var characters = Array(text)
                while let first = characters.first, cutset.contains(first) {
                    characters.removeFirst()
                }
                while let last = characters.last, cutset.contains(last) {
                    characters.removeLast()
                }
                return .string(String(characters))
            }),
            ("Replace", function("Replace", 3...4) { context in
                let text = try context.requireString(0, "strings.Replace")
                let target = try context.requireString(1, "strings.Replace")
                let replacement = try context.requireString(2, "strings.Replace")
                let count = Int(context.optionalArgument(3)?.asInt ?? -1)
                if count < 0 {
                    return .string(text.replacingOccurrences(of: target, with: replacement))
                }
                var result = text
                for _ in 0..<count {
                    guard let found = result.range(of: target) else { break }
                    result = result.replacingCharacters(in: found, with: replacement)
                }
                return .string(result)
            }),
            ("ReplaceAll", function("ReplaceAll", 3) { context in
                .string(try context.requireString(0, "strings.ReplaceAll")
                    .replacingOccurrences(of: try context.requireString(1, "strings.ReplaceAll"),
                                          with: try context.requireString(2, "strings.ReplaceAll")))
            }),
            ("Index", function("Index", 2) { context in
                let text = Array(try context.requireString(0, "strings.Index"))
                let needle = try context.requireString(1, "strings.Index")
                guard let found = MLStdlib.firstIndex(of: needle, in: text) else {
                    return .int(-1)
                }
                return .int(Int64(found))
            }),
            ("Repeat", function("Repeat", 2) { context in
                let text = try context.requireString(0, "strings.Repeat")
                let count = Int(try context.requireInt(1, "strings.Repeat"))
                return .string(count > 0 ? String(repeating: text, count: count) : "")
            }),
            ("Fields", function("Fields", 1) { context in
                let text = try context.requireString(0, "strings.Fields")
                return .array(MLArray(text.split(whereSeparator: { $0.isWhitespace })
                    .map { .string(String($0)) }))
            }),
            ("TrimPrefix", function("TrimPrefix", 2) { context in
                let text = try context.requireString(0, "strings.TrimPrefix")
                let prefix = try context.requireString(1, "strings.TrimPrefix")
                return .string(text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count))
                                                      : text)
            }),
            ("TrimSuffix", function("TrimSuffix", 2) { context in
                let text = try context.requireString(0, "strings.TrimSuffix")
                let suffix = try context.requireString(1, "strings.TrimSuffix")
                return .string(text.hasSuffix(suffix) ? String(text.dropLast(suffix.count))
                                                      : text)
            }),
            ("Count", function("Count", 2) { context in
                .int(Int64(MLStdlib.countOccurrences(
                    of: try context.requireString(1, "strings.Count"),
                    in: try context.requireString(0, "strings.Count"))))
            }),
            ("Builder", function("Builder", 0...0) { _ in
                let object = MLObject(typeName: "strings.Builder")
                object.fields[.string("value")] = .string("")
                return .object(object)
            })
        ])
    }

    static func makeStrconv(semantics: GoSemantics) -> MLObject {
        namespace("strconv", [
            ("Itoa", function("Itoa", 1) { context in
                .string(String(try context.requireInt(0, "strconv.Itoa")))
            }),
            ("Atoi", function("Atoi", 1) { context in
                let text = try context.requireString(0, "strconv.Atoi")
                guard let value = Int64(text) else {
                    let error = MLObject(typeName: "error")
                    error.fields[.string("message")] =
                        .string("strconv.Atoi: parsing \"\(text)\": invalid syntax")
                    return .tuple([.int(0), .object(error)])
                }
                return .tuple([.int(value), .unit])
            }),
            ("ParseFloat", function("ParseFloat", 1...2) { context in
                let text = try context.requireString(0, "strconv.ParseFloat")
                guard let value = Double(text) else {
                    let error = MLObject(typeName: "error")
                    error.fields[.string("message")] =
                        .string("strconv.ParseFloat: parsing \"\(text)\": invalid syntax")
                    return .tuple([.double(0), .object(error)])
                }
                return .tuple([.double(value), .unit])
            }),
            ("ParseInt", function("ParseInt", 1...3) { context in
                let text = try context.requireString(0, "strconv.ParseInt")
                let radix = Int(context.optionalArgument(1)?.asInt ?? 10)
                guard let value = Int64(text, radix: radix == 0 ? 10 : radix) else {
                    return .tuple([.int(0), .string("invalid syntax")])
                }
                return .tuple([.int(value), .unit])
            }),
            ("FormatFloat", function("FormatFloat", 2...4) { context in
                let value = try context.requireDouble(0, "strconv.FormatFloat")
                let digits = Int(context.optionalArgument(2)?.asInt ?? -1)
                if digits < 0 { return .string(MLNumberFormatting.shortestStyle(value)) }
                return .string(MLNumberFormatting.fixed(value, digits: digits))
            }),
            ("Quote", function("Quote", 1) { context in
                .string("\"" + (try context.requireString(0, "strconv.Quote")) + "\"")
            })
        ])
    }

    static func makeMath() -> MLObject {
        var entries: [(String, MLValue)] = [
            ("Pi", .double(Double.pi)),
            ("E", .double(M_E)),
            ("MaxInt64", .int(Int64.max)),
            ("MinInt64", .int(Int64.min)),
            ("MaxInt", .int(Int64.max)),
            ("MinInt", .int(Int64.min)),
            ("MaxInt32", .int(Int64(Int32.max))),
            ("MinInt32", .int(Int64(Int32.min))),
            ("MaxFloat64", .double(Double.greatestFiniteMagnitude)),
            ("Inf", function("Inf", 0...1) { context in
                .double((context.optionalArgument(0)?.asInt ?? 1) < 0
                        ? -Double.infinity : Double.infinity)
            }),
            ("Pow", function("Pow", 2) { context in
                .double(Foundation.pow(try context.requireDouble(0, "math.Pow"),
                                       try context.requireDouble(1, "math.Pow")))
            }),
            ("Abs", function("Abs", 1) { context in
                .double(Swift.abs(try context.requireDouble(0, "math.Abs")))
            }),
            ("Max", function("Max", 2) { context in
                .double(Swift.max(try context.requireDouble(0, "math.Max"),
                                  try context.requireDouble(1, "math.Max")))
            }),
            ("Min", function("Min", 2) { context in
                .double(Swift.min(try context.requireDouble(0, "math.Min"),
                                  try context.requireDouble(1, "math.Min")))
            }),
            ("Mod", function("Mod", 2) { context in
                .double(try context.requireDouble(0, "math.Mod")
                    .truncatingRemainder(dividingBy: try context.requireDouble(1, "math.Mod")))
            })
        ]
        for (name, implementation) in MLStdlib.mathFunctions {
            let capitalized = name.prefix(1).uppercased() + name.dropFirst()
            entries.append((capitalized, function(capitalized, 1) { context in
                .double(implementation(try context.requireDouble(0, "math." + capitalized)))
            }))
        }
        return namespace("math", entries)
    }

    static func makeSort() -> MLObject {
        namespace("sort", [
            ("Ints", function("Ints", 1) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: nil)
                return .unit
            }),
            ("Strings", function("Strings", 1) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: nil)
                return .unit
            }),
            ("Float64s", function("Float64s", 1) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: nil)
                return .unit
            }),
            ("Slice", function("Slice", 2) { context in
                guard let array = context.argument(0).asArray,
                      let less = context.optionalArgument(1)?.asFunction else { return .unit }
                // Go の `less(i, j)` は添字を受け取るので、値の比較に直す。
                let original = array.elements
                let indices = try MLStdlib.stableSorted(
                    (0..<original.count).map { .int(Int64($0)) },
                    interpreter: context.interpreter,
                    comparator: less)
                array.elements = indices.map { original[Int($0.asInt ?? 0)] }
                return .unit
            })
        ])
    }

    static func makeOS() -> MLObject {
        namespace("os", [
            ("Exit", function("Exit", 1) { context in
                throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
            }),
            ("Args", .array(MLArray([.string("program")]))),
            ("Stdin", .object(MLObject(typeName: "os.File"))),
            ("Stdout", .object(MLObject(typeName: "os.File")))
        ])
    }

    static func makeErrors() -> MLObject {
        namespace("errors", [
            ("New", function("New", 1) { context in
                let object = MLObject(typeName: "error")
                object.fields[.string("message")] = .string(context.argument(0).asString ?? "")
                return .object(object)
            }),
            ("Is", function("Is", 2) { context in
                .bool(context.interpreter.semantics.areEqual(context.argument(0),
                                                             context.argument(1)))
            })
        ])
    }

    static func makeTime() -> MLObject {
        namespace("time", [
            ("Now", function("Now", 0...0) { _ in
                .int(Int64(Date().timeIntervalSince1970))
            }),
            ("Since", function("Since", 1) { _ in .int(0) })
        ])
    }

    // MARK: メソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: GoSemantics) throws -> MLValue? {
        if let object = receiver.asObject, object.typeName == "strings.Builder" {
            let current = object.fields[.string("value")]?.asString ?? ""
            switch name {
            case "WriteString", "WriteRune", "WriteByte":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return .unit
            case "String": return .string(current)
            case "Len": return .int(Int64(current.count))
            case "Reset":
                object.fields[.string("value")] = .string("")
                return .unit
            default: return nil
            }
        }
        if let object = receiver.asObject, object.typeName == "error",
           name == "Error" {
            return object.fields[.string("message")] ?? .string("")
        }
        return try MLStdlib.callMethod(on: receiver, name: name, context: context)
    }
}
