import Foundation

/// Pascal らしい振る舞い。
final class PascalSemantics: MLSemantics {
    override var languageID: String { "pascal" }
    override var displayName: String { "内蔵 Pascal 処理系" }
    override var usesValueSemantics: Bool { true }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// 添字は宣言しだいだが、文字列は 1 始まり。
    override var indexBase: Int { 0 }
    /// 列挙のケースは型名なしで書ける。
    override var exposesEnumCasesGlobally: Bool { true }
    /// `var P: TPoint;` と書けばレコードの実体ができる。
    override var defaultInitializesDeclaredTypes: Bool { true }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool: return "Boolean"
        case .int: return "Integer"
        case .double: return "Real"
        case .string: return "string"
        case .char: return "Char"
        case .array: return "array"
        case .map: return "map"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    /// Pascal の `WriteLn` は真を `TRUE` と書く。
    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return array.elements.map { display($0) }.joined(separator: " ")
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            return object.typeName
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// 既定の実数表示は指数つき (`1.5000000000000000E+000`)。
    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        var text = String(format: "%.15E", value)
        // `1.500000000000000E+00` の指数部を 3 桁にそろえる。
        if let range = text.range(of: "E") {
            let mantissa = String(text[text.startIndex..<range.lowerBound])
            var exponent = String(text[range.upperBound...])
            let sign = exponent.first == "-" ? "-" : "+"
            exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            while exponent.count < 3 { exponent = "0" + exponent }
            text = mantissa + "E" + sign + exponent
        }
        return (value < 0 ? "" : " ") + text
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        switch typeName {
        case "integer", "longint", "shortint", "byte", "word", "cardinal", "int64",
             "smallint", "qword":
            return .int(0)
        case "real", "double", "single", "extended", "currency": return .double(0)
        case "boolean", "bool": return .bool(false)
        case "string", "ansistring", "shortstring", "widestring": return .string("")
        case "char", "ansichar", "widechar": return .char(" ")
        case "array", "set": return .array(MLArray())
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        switch typeName {
        case "real", "double", "single", "extended":
            if let number = value.asInt { return .double(Double(number)) }
        default:
            break
        }
        return value
    }

    /// Pascal 独自の演算子。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "<>":
            return .bool(!areEqual(lhs, rhs))
        case "=":
            return .bool(areEqual(lhs, rhs))
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
        case "/":
            // `/` は常に実数を返す。
            if let left = lhs.asInt, let right = rhs.asInt {
                guard right != 0 else { throw MLError.runtime("0 では割れません") }
                return .double(Double(left) / Double(right))
            }
            return nil
        case "+":
            // 文字列の連結。
            if case .string(let left) = lhs.forced {
                return .string(left + display(rhs))
            }
            return nil
        default:
            return nil
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        PascalLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        if name == "length", let array = value.asArray { return .int(Int64(array.count)) }
        return nil
    }
}

/// Pascal の標準手続き。
enum PascalLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func install(into environment: MLEnvironment, semantics: PascalSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)

        environment.define("write", function("write", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            context.interpreter.write(text)
            return .unit
        })
        environment.define("writeln", function("writeln", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            context.interpreter.write(text + "\n")
            return .unit
        })
        environment.define("readln", function("readln", 0...4) { context in
            let line = context.interpreter.input.nextLine() ?? ""
            // `ReadLn(X)` は読んだ値を変数に入れる。
            for box in context.boxes.compactMap({ $0 }) {
                switch box.value.forced {
                case .int: box.value = .int(Int64(line.trimmingCharacters(
                    in: .whitespaces)) ?? 0)
                case .double: box.value = .double(Double(line.trimmingCharacters(
                    in: .whitespaces)) ?? 0)
                default: box.value = .string(line)
                }
            }
            return .string(line)
        })
        environment.define("read", function("read", 0...4) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        })

        // 桁指定つきの表示 (`Write(X:8:2)`)。
        environment.define("#format", function("#format", 3) { context in
            let value = context.argument(0)
            let width = Int(context.argument(1).asInt ?? 0)
            let decimals = Int(context.argument(2).asInt ?? -1)
            var text: String
            if decimals >= 0, let number = value.asDouble {
                text = String(format: "%.\(decimals)f", number)
            } else {
                text = semantics.display(value)
            }
            while text.count < width { text = " " + text }
            return .string(text)
        })

        environment.define("length", function("length", 1) { context in
            let value = context.argument(0)
            if let text = value.asString { return .int(Int64(text.count)) }
            if let array = value.asArray { return .int(Int64(array.count)) }
            return .int(0)
        })
        environment.define("setlength", function("setlength", 2) { context in
            guard let array = context.argument(0).asArray,
                  let count = context.argument(1).asInt else { return .unit }
            let target = Int(max(0, count))
            if array.elements.count > target {
                array.elements.removeLast(array.elements.count - target)
            } else {
                array.elements.append(contentsOf:
                    Array(repeating: .int(0), count: target - array.elements.count))
            }
            return .unit
        })
        environment.define("copy", function("copy", 2...3) { context in
            let text = try context.requireString(0, "Copy")
            let characters = Array(text)
            let start = Int(try context.requireInt(1, "Copy")) - 1
            let count = Int(context.optionalArgument(2)?.asInt ?? Int64(characters.count))
            guard start >= 0, start < characters.count else { return .string("") }
            let end = min(characters.count, start + max(0, count))
            return .string(String(characters[start..<end]))
        })
        environment.define("pos", function("pos", 2) { context in
            let needle = try context.requireString(0, "Pos")
            let haystack = try context.requireString(1, "Pos")
            guard let range = haystack.range(of: needle) else { return .int(0) }
            return .int(Int64(haystack.distance(from: haystack.startIndex,
                                                to: range.lowerBound) + 1))
        })
        environment.define("upcase", function("upcase", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("uppercase", function("uppercase", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("lowercase", function("lowercase", 1) { context in
            .string(semantics.display(context.argument(0)).lowercased())
        })
        environment.define("trim", function("trim", 1) { context in
            .string(try context.requireString(0, "Trim")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        })
        environment.define("inttostr", function("inttostr", 1) { context in
            .string(semantics.display(context.argument(0)))
        })
        environment.define("strtoint", function("strtoint", 1) { context in
            let text = try context.requireString(0, "StrToInt")
                .trimmingCharacters(in: .whitespaces)
            guard let number = Int64(text) else {
                throw MLError.thrown(.object(exception("EConvertError",
                                                       "\"\(text)\" is not a valid integer")))
            }
            return .int(number)
        })
        environment.define("floattostr", function("floattostr", 1) { context in
            .string(MLNumberFormatting.shortestStyle(context.argument(0).asDouble ?? 0))
        })
        environment.define("chr", function("chr", 1) { context in
            let code = UInt32(max(0, try context.requireInt(0, "Chr")))
            guard let scalar = Unicode.Scalar(code) else { return .char(" ") }
            return .char(Character(scalar))
        })
        environment.define("ord", function("ord", 1) { context in
            switch context.argument(0) {
            case .char(let character):
                return .int(Int64(character.unicodeScalars.first?.value ?? 0))
            case .int(let number): return .int(number)
            case .bool(let flag): return .int(flag ? 1 : 0)
            case .object(let object):
                if let attachment = object.attachment, let number = attachment.asInt {
                    return .int(number)
                }
                let order = object.classDeclaration?.caseOrder ?? []
                return .int(Int64(order.firstIndex(of: object.caseName ?? "") ?? 0))
            default: return .int(0)
            }
        })
        environment.define("inc", function("inc", 1...2) { context in
            guard let box = context.boxes.first ?? nil else { return .unit }
            let step = context.optionalArgument(1)?.asInt ?? 1
            box.value = .int((box.value.asInt ?? 0) + step)
            return .unit
        })
        environment.define("dec", function("dec", 1...2) { context in
            guard let box = context.boxes.first ?? nil else { return .unit }
            let step = context.optionalArgument(1)?.asInt ?? 1
            box.value = .int((box.value.asInt ?? 0) - step)
            return .unit
        })
        environment.define("sqr", function("sqr", 1) { context in
            if let number = context.argument(0).asInt { return .int(number * number) }
            let number = try context.requireDouble(0, "Sqr")
            return .double(number * number)
        })
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(try context.requireDouble(0, "Sqrt")))
        })
        environment.define("trunc", function("trunc", 1) { context in
            .int(Int64(try context.requireDouble(0, "Trunc")))
        })
        environment.define("round", function("round", 1) { context in
            .int(Int64(try context.requireDouble(0, "Round").rounded()))
        })
        environment.define("odd", function("odd", 1) { context in
            .bool((try context.requireInt(0, "Odd")) % 2 != 0)
        })
        environment.define("halt", function("halt", 0...1) { context in
            throw MLError.exit(Int32(context.optionalArgument(0)?.asInt ?? 0))
        })
        environment.define("exception", .string("Exception"))
        for name in ["Exception", "EConvertError", "EDivByZero", "ERangeError"] {
            environment.define(name.lowercased(), .string(name))
        }
    }

    static func exception(_ typeName: String, _ message: String) -> MLObject {
        let object = MLObject(typeName: typeName)
        object.fields[.string("message")] = .string(message)
        object.fields[.string("msg")] = .string(message)
        return object
    }
}
