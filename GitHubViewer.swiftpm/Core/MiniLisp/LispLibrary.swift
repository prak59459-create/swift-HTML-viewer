import Foundation

/// Lisp らしい振る舞い。
final class LispSemantics: MLSemantics {
    override var languageID: String { "lisp" }
    override var displayName: String { "内蔵 Lisp 処理系" }
    override var requiresDefinitionBeforeUse: Bool { false }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    /// 偽は `nil` だけ (0 も "" も真)。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .unit: return false
        case .bool(let flag): return flag
        case .array(let array): return !array.elements.isEmpty
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "NULL"
        case .bool: return "BOOLEAN"
        case .int: return "INTEGER"
        case .double: return "FLOAT"
        case .string: return "STRING"
        case .char: return "CHARACTER"
        case .array: return "CONS"
        case .map: return "HASH-TABLE"
        case .function: return "FUNCTION"
        case .symbol: return "SYMBOL"
        case .object(let object): return object.typeName
        default: return "T"
        }
    }

    /// `princ` / `format ~a` の書き方。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "NIL"
        case .bool(let flag): return flag ? "T" : "NIL"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .symbol(let name): return name.uppercased()
        case .array(let array):
            return "(" + array.elements.map { display($0) }.joined(separator: " ") + ")"
        case .map(let map):
            return "#S(HASH-TABLE " + map.pairs.map { "\(display($0.key.asValue)) \(display($0.value))" }
                .joined(separator: " ") + ")"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// `prin1` / `format ~s` は文字列に引用符を付ける。
    override func inspect(_ value: MLValue) -> String {
        switch value.forced {
        case .string(let text): return "\"\(text)\""
        case .char(let character): return "#\\\(character)"
        case .array(let array):
            return "(" + array.elements.map { inspect($0) }.joined(separator: " ") + ")"
        default: return display(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value)) + ".0"
        }
        return MLNumberFormatting.shortestStyle(value)
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        LispLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }
}

/// Lisp の組み込み関数。
enum LispLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func items(_ value: MLValue) -> [MLValue] {
        if let array = value.asArray { return array.elements }
        if value.isUnit { return [] }
        return [value.forced]
    }

    /// `format` の指示子を組み立てる。
    static func format(_ pattern: String, _ arguments: [MLValue],
                       semantics: LispSemantics) -> String {
        var result = ""
        var index = 0
        var characters = Array(pattern)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            guard character == "~" else {
                result.append(character)
                position += 1
                continue
            }
            position += 1
            guard position < characters.count else { break }
            // 桁数の指定は読み飛ばす。
            var digits = ""
            while position < characters.count,
                  characters[position].isNumber || characters[position] == "," {
                digits.append(characters[position])
                position += 1
            }
            guard position < characters.count else { break }
            let directive = characters[position]
            position += 1
            switch directive {
            case "a", "A":
                if index < arguments.count {
                    result += semantics.display(arguments[index])
                    index += 1
                }
            case "s", "S":
                if index < arguments.count {
                    result += semantics.inspect(arguments[index])
                    index += 1
                }
            case "d", "D":
                if index < arguments.count {
                    result += semantics.display(arguments[index])
                    index += 1
                }
            case "f", "F":
                if index < arguments.count {
                    let number = arguments[index].asDouble
                        ?? Double(arguments[index].asInt ?? 0)
                    let decimals = Int(digits.split(separator: ",").last.map(String.init)
                                        ?? "") ?? 6
                    result += String(format: "%.\(decimals)f", number)
                    index += 1
                }
            case "%", "&":
                result += "\n"
            case "~":
                result += "~"
            case "{":
                // `~{~a ~}` の繰り返し。中身をそのまま各要素に当てる。
                var inner = ""
                var depth = 1
                while position < characters.count {
                    if characters[position] == "~", position + 1 < characters.count {
                        if characters[position + 1] == "{" { depth += 1 }
                        if characters[position + 1] == "}" {
                            depth -= 1
                            if depth == 0 {
                                position += 2
                                break
                            }
                        }
                    }
                    inner.append(characters[position])
                    position += 1
                }
                if index < arguments.count {
                    for element in items(arguments[index]) {
                        result += format(inner, [element], semantics: semantics)
                    }
                    index += 1
                }
            default:
                result.append(directive)
            }
        }
        _ = characters
        characters = []
        return result
    }

    static func install(into environment: MLEnvironment, semantics: LispSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)
        environment.define("nil", .unit)
        environment.define("t", .bool(true))
        environment.define("pi", .double(Double.pi))

        environment.define("format", function("format", 1...64) { context in
            // 最初の引数が `t` なら標準出力、`nil` なら文字列を返す。
            let target = context.argument(0)
            let pattern = context.optionalArgument(1)?.asString ?? ""
            let rest = Array(context.arguments.dropFirst(2))
            let text = format(pattern, rest, semantics: semantics)
            if target.isUnit { return .string(text) }
            context.interpreter.write(text)
            return .unit
        })
        environment.define("princ", function("princ", 1...2) { context in
            context.interpreter.write(semantics.display(context.argument(0)))
            return context.argument(0)
        })
        environment.define("prin1", function("prin1", 1...2) { context in
            context.interpreter.write(semantics.inspect(context.argument(0)))
            return context.argument(0)
        })
        environment.define("print", function("print", 1...2) { context in
            context.interpreter.write("\n" + semantics.inspect(context.argument(0)) + " ")
            return context.argument(0)
        })
        environment.define("terpri", function("terpri", 0...1) { context in
            context.interpreter.write("\n")
            return .unit
        })
        environment.define("write-line", function("write-line", 1...2) { context in
            context.interpreter.write(semantics.display(context.argument(0)) + "\n")
            return context.argument(0)
        })
        environment.define("read-line", function("read-line", 0...3) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })

        // リスト。
        environment.define("car", function("car", 1) { context in
            items(context.argument(0)).first ?? .unit
        })
        environment.define("first", function("first", 1) { context in
            items(context.argument(0)).first ?? .unit
        })
        environment.define("cdr", function("cdr", 1) { context in
            let elements = items(context.argument(0))
            guard elements.count > 1 else { return .unit }
            return .array(MLArray(Array(elements.dropFirst())))
        })
        environment.define("rest", function("rest", 1) { context in
            let elements = items(context.argument(0))
            guard elements.count > 1 else { return .unit }
            return .array(MLArray(Array(elements.dropFirst())))
        })
        environment.define("cons", function("cons", 2) { context in
            var elements = [context.argument(0)]
            elements += items(context.argument(1))
            return .array(MLArray(elements))
        })
        environment.define("list", function("list", 0...256) { context in
            .array(MLArray(context.arguments))
        })
        environment.define("append", function("append", 0...256) { context in
            var elements: [MLValue] = []
            for value in context.arguments { elements += items(value) }
            return .array(MLArray(elements))
        })
        environment.define("length", function("length", 1) { context in
            let value = context.argument(0)
            if let text = value.asString { return .int(Int64(text.count)) }
            return .int(Int64(items(value).count))
        })
        environment.define("nth", function("nth", 2) { context in
            let elements = items(context.argument(1))
            let index = Int(context.argument(0).asInt ?? 0)
            return index >= 0 && index < elements.count ? elements[index] : .unit
        })
        environment.define("elt", function("elt", 2) { context in
            let elements = items(context.argument(0))
            let index = Int(context.argument(1).asInt ?? 0)
            return index >= 0 && index < elements.count ? elements[index] : .unit
        })
        environment.define("last", function("last", 1...2) { context in
            guard let element = items(context.argument(0)).last else { return .unit }
            return .array(MLArray([element]))
        })
        environment.define("reverse", function("reverse", 1) { context in
            if let text = context.argument(0).asString {
                return .string(String(text.reversed()))
            }
            return .array(MLArray(items(context.argument(0)).reversed()))
        })
        environment.define("#push", function("#push", 2) { context in
            guard let array = context.argument(0).asArray else {
                return .array(MLArray([context.argument(1)]))
            }
            array.elements.insert(context.argument(1), at: 0)
            return .array(array)
        })
        environment.define("null", function("null", 1) { context in
            .bool(try !semantics.isTruthy(context.argument(0)))
        })
        environment.define("atom", function("atom", 1) { context in
            .bool(context.argument(0).asArray == nil)
        })
        environment.define("listp", function("listp", 1) { context in
            .bool(context.argument(0).asArray != nil || context.argument(0).isUnit)
        })
        environment.define("numberp", function("numberp", 1) { context in
            .bool(context.argument(0).asInt != nil || context.argument(0).asDouble != nil)
        })
        environment.define("stringp", function("stringp", 1) { context in
            .bool(context.argument(0).asString != nil)
        })
        environment.define("symbolp", function("symbolp", 1) { context in
            if case .symbol = context.argument(0) { return .bool(true) }
            return .bool(false)
        })
        environment.define("eq", function("eq", 2) { context in
            .bool(MLOperations.strictEquals(context.argument(0), context.argument(1),
                                            semantics: semantics))
        })
        environment.define("eql", function("eql", 2) { context in
            .bool(MLOperations.strictEquals(context.argument(0), context.argument(1),
                                            semantics: semantics))
        })
        environment.define("equal", function("equal", 2) { context in
            .bool(semantics.display(context.argument(0))
                    == semantics.display(context.argument(1)))
        })
        environment.define("member", function("member", 2) { context in
            let elements = items(context.argument(1))
            guard let position = elements.firstIndex(where: {
                MLOperations.strictEquals($0, context.argument(0), semantics: semantics)
            }) else { return .unit }
            return .array(MLArray(Array(elements[position...])))
        })

        // 高階関数。
        environment.define("mapcar", function("mapcar", 2...8) { context in
            let body = try context.requireFunction(0, "mapcar")
            let lists = context.arguments.dropFirst().map { items($0) }
            let count = lists.map { $0.count }.min() ?? 0
            var result: [MLValue] = []
            for index in 0..<count {
                result.append(try context.interpreter.callFunction(
                    body, arguments: lists.map { $0[index] }, location: context.location))
            }
            return .array(MLArray(result))
        })
        environment.define("mapc", function("mapc", 2...8) { context in
            let body = try context.requireFunction(0, "mapc")
            for element in items(context.argument(1)) {
                _ = try context.interpreter.callFunction(body, arguments: [element],
                                                         location: context.location)
            }
            return context.argument(1)
        })
        environment.define("remove-if-not", function("remove-if-not", 2) { context in
            try filtered(context, semantics: semantics, keepWhenTrue: true)
        })
        environment.define("remove-if", function("remove-if", 2) { context in
            try filtered(context, semantics: semantics, keepWhenTrue: false)
        })
        environment.define("find-if", function("find-if", 2) { context in
            let body = try context.requireFunction(0, "find-if")
            for element in items(context.argument(1)) {
                let kept = try context.interpreter.callFunction(
                    body, arguments: [element], location: context.location)
                if try semantics.isTruthy(kept) { return element }
            }
            return .unit
        })
        environment.define("reduce", function("reduce", 2...4) { context in
            let body = try context.requireFunction(0, "reduce")
            var elements = items(context.argument(1))
            var accumulator: MLValue
            if let initial = context.argument(labeled: "initial-value") {
                accumulator = initial
            } else if let first = elements.first {
                accumulator = first
                elements = Array(elements.dropFirst())
            } else {
                return .unit
            }
            for element in elements {
                accumulator = try context.interpreter.callFunction(
                    body, arguments: [accumulator, element], location: context.location)
            }
            return accumulator
        })
        environment.define("sort", function("sort", 1...3) { context in
            let elements = items(context.argument(0))
            let comparator = context.optionalArgument(1)?.asFunction
            return .array(MLArray(try MLStdlib.stableSorted(
                elements, interpreter: context.interpreter, comparator: comparator)))
        })
        environment.define("apply", function("apply", 1...8) { context in
            let body = try context.requireFunction(0, "apply")
            var arguments = Array(context.arguments.dropFirst())
            if let last = arguments.last, last.asArray != nil {
                arguments.removeLast()
                arguments += items(last)
            }
            return try context.interpreter.callFunction(body, arguments: arguments,
                                                        location: context.location)
        })
        environment.define("funcall", function("funcall", 1...8) { context in
            let body = try context.requireFunction(0, "funcall")
            return try context.interpreter.callFunction(
                body, arguments: Array(context.arguments.dropFirst()),
                location: context.location)
        })

        // 文字列。
        environment.define("concatenate", function("concatenate", 1...64) { context in
            // 最初の引数は型の指定 ('string など)。
            let rest = context.arguments.dropFirst()
            if rest.contains(where: { $0.asArray != nil }) {
                var elements: [MLValue] = []
                for value in rest { elements += items(value) }
                return .array(MLArray(elements))
            }
            return .string(rest.map { semantics.display($0) }.joined())
        })
        environment.define("string-upcase", function("string-upcase", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("string-downcase", function("string-downcase", 1) { context in
            .string(semantics.display(context.argument(0)).lowercased())
        })
        environment.define("string=", function("string=", 2) { context in
            .bool(semantics.display(context.argument(0))
                    == semantics.display(context.argument(1)))
        })
        environment.define("subseq", function("subseq", 2...3) { context in
            let value = context.argument(0)
            let start = Int(context.argument(1).asInt ?? 0)
            if let text = value.asString {
                let characters = Array(text)
                let end = Int(context.optionalArgument(2)?.asInt ?? Int64(characters.count))
                guard start >= 0, start <= characters.count else { return .string("") }
                return .string(String(characters[start..<Swift.min(characters.count, end)]))
            }
            let elements = items(value)
            let end = Int(context.optionalArgument(2)?.asInt ?? Int64(elements.count))
            guard start >= 0, start <= elements.count else { return .array(MLArray()) }
            return .array(MLArray(Array(elements[start..<Swift.min(elements.count, end)])))
        })

        // ハッシュ表。
        environment.define("make-hash-table", function("make-hash-table", 0...4) { _ in
            .map(MLMap())
        })
        environment.define("gethash", function("gethash", 2...3) { context in
            guard let map = context.argument(1).asMap,
                  let key = MLKey.from(context.argument(0)) else { return .unit }
            return map[key] ?? context.optionalArgument(2) ?? .unit
        })
        environment.define("sethash", function("sethash", 3) { context in
            guard let map = context.argument(1).asMap,
                  let key = MLKey.from(context.argument(0)) else { return .unit }
            map[key] = context.argument(2)
            return context.argument(2)
        })
        environment.define("hash-table-count", function("hash-table-count", 1) { context in
            .int(Int64(context.argument(0).asMap?.count ?? 0))
        })

        // 数。
        environment.define("mod", function("mod", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.runtime("division by zero") }
            let remainder = left % right
            return .int(remainder != 0 && (remainder < 0) != (right < 0)
                            ? remainder + right : remainder)
        })
        environment.define("rem", function("rem", 2) { context in
            let left = context.argument(0).asInt ?? 0
            let right = context.argument(1).asInt ?? 1
            guard right != 0 else { throw MLError.runtime("division by zero") }
            return .int(left % right)
        })
        environment.define("expt", function("expt", 2) { context in
            let base = context.argument(0).asDouble ?? Double(context.argument(0).asInt ?? 0)
            let power = context.argument(1).asDouble ?? Double(context.argument(1).asInt ?? 0)
            let result = Foundation.pow(base, power)
            if context.argument(0).asInt != nil, context.argument(1).asInt != nil,
               result == result.rounded() {
                return .int(Int64(result))
            }
            return .double(result)
        })
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(context.argument(0).asDouble
                                        ?? Double(context.argument(0).asInt ?? 0)))
        })
        environment.define("floor", function("floor", 1...2) { context in
            .int(Int64((context.argument(0).asDouble
                            ?? Double(context.argument(0).asInt ?? 0)).rounded(.down)))
        })
        environment.define("evenp", function("evenp", 1) { context in
            .bool((context.argument(0).asInt ?? 0) % 2 == 0)
        })
        environment.define("oddp", function("oddp", 1) { context in
            .bool((context.argument(0).asInt ?? 0) % 2 != 0)
        })
        environment.define("zerop", function("zerop", 1) { context in
            .bool((context.argument(0).asDouble ?? Double(context.argument(0).asInt ?? 0)) == 0)
        })
        environment.define("1+", function("1+", 1) { context in
            .int((context.argument(0).asInt ?? 0) + 1)
        })
        environment.define("1-", function("1-", 1) { context in
            .int((context.argument(0).asInt ?? 0) - 1)
        })
        // 演算子を値として渡せるようにする (`#'+` など)。
        for op in ["+", "-", "*", "/"] {
            environment.define(op, function(op, 0...64) { context in
                guard var result = context.arguments.first else {
                    return .int(op == "*" ? 1 : 0)
                }
                if context.arguments.count == 1 {
                    if op == "-" {
                        return try MLOperations.arithmetic(op: "-", lhs: .int(0),
                                                           rhs: result, semantics: semantics)
                    }
                    if op == "/" {
                        return try MLOperations.arithmetic(op: "/", lhs: .int(1),
                                                           rhs: result, semantics: semantics)
                    }
                    return result
                }
                for value in context.arguments.dropFirst() {
                    result = try MLOperations.arithmetic(op: op, lhs: result, rhs: value,
                                                         semantics: semantics)
                }
                return result
            })
        }
        for op in ["<", ">", "<=", ">=", "=", "/="] {
            environment.define(op, function(op, 1...64) { context in
                for index in 0..<(context.arguments.count - 1) {
                    let left = context.arguments[index]
                    let right = context.arguments[index + 1]
                    let ordered: Bool
                    if op == "=" || op == "/=" {
                        let same = MLOperations.strictEquals(left, right,
                                                             semantics: semantics)
                        ordered = op == "=" ? same : !same
                    } else {
                        guard let order = semantics.compare(left, right) else {
                            return .bool(false)
                        }
                        switch op {
                        case "<": ordered = order < 0
                        case ">": ordered = order > 0
                        case "<=": ordered = order <= 0
                        default: ordered = order >= 0
                        }
                    }
                    if !ordered { return .bool(false) }
                }
                return .bool(true)
            })
        }
        environment.define("copy-list", function("copy-list", 1) { context in
            .array(MLArray(items(context.argument(0))))
        })
        environment.define("list-length", function("list-length", 1) { context in
            .int(Int64(items(context.argument(0)).count))
        })

        environment.define("error", function("error", 0...64) { context in
            let pattern = context.optionalArgument(0)?.asString ?? "error"
            throw MLError.thrown(.string(format(pattern,
                                                Array(context.arguments.dropFirst()),
                                                semantics: semantics)))
        })
    }

    private static func filtered(_ context: MLCallContext, semantics: LispSemantics,
                                 keepWhenTrue: Bool) throws -> MLValue {
        let body = try context.requireFunction(0, "remove-if")
        var result: [MLValue] = []
        for element in items(context.argument(1)) {
            let kept = try context.interpreter.callFunction(body, arguments: [element],
                                                            location: context.location)
            if try semantics.isTruthy(kept) == keepWhenTrue { result.append(element) }
        }
        return .array(MLArray(result))
    }
}
