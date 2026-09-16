import Foundation

/// Java らしい振る舞い。
final class JavaSemantics: MLSemantics {
    override var languageID: String { "java" }
    override var displayName: String { "内蔵 Java 処理系" }

    /// 配列・オブジェクトは参照。
    override var usesValueSemantics: Bool { false }
    override var outOfBoundsIsError: Bool { true }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        guard case .bool(let flag) = value.forced else {
            throw MLError.runtime("boolean が必要です (\(typeName(of: value)) が渡されました)")
        }
        return flag
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool: return "boolean"
        case .int: return "int"
        case .double: return "double"
        case .char: return "char"
        case .string: return "String"
        case .array: return "array"
        case .map: return "Map"
        case .tuple: return "Object[]"
        case .object(let object): return object.typeName
        case .function: return "lambda"
        case .range: return "Range"
        case .symbol: return "Symbol"
        case .thunk: return "Object"
        }
    }

    override func formatDouble(_ value: Double) -> String {
        MLNumberFormatting.javaStyle(value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
        case .double(let number): return MLNumberFormatting.javaStyle(number)
        case .char(let character): return String(character)
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .array(let array):
            // Java の配列は `toString` すると `[I@1b6d` になるが、
            // 実用上は中身が見えたほうが役に立つので `Arrays.toString` と同じ形にする。
            return "[" + array.elements.map { display($0) }.joined(separator: ", ") + "]"
        case .map(let map):
            return "{" + map.pairs.map { "\(display($0.key.asValue))=\(display($0.value))" }
                .joined(separator: ", ") + "}"
        case .object(let object):
            if let caseName = object.caseName { return caseName }
            if object.typeName == "StringBuilder" {
                return object.fields[.string("value")]?.asString ?? ""
            }
            if let klass = object.classDeclaration, klass.findMethod("toString") != nil {
                return javaToString(value) ?? object.typeName
            }
            return object.typeName + "@" + String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xfffffff, radix: 16)
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    /// 利用者が定義した `toString()` を呼ぶ。
    private var toStringInterpreter: MLInterpreter?

    private func javaToString(_ value: MLValue) -> String? {
        guard let interpreter = toStringInterpreter else { return nil }
        guard let result = try? interpreter.callMethod(on: value, name: "toString",
                                                       arguments: [],
                                                       location: SourceLocation.unknown) else {
            return nil
        }
        return result.asString
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        switch typeName {
        case "int", "long", "short", "byte": return .int(0)
        case "double", "float": return .double(0)
        case "boolean": return .bool(false)
        case "char": return .char("\0")
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        switch typeName {
        case "double", "float", "Double", "Float":
            if let number = value.asDouble, case .int = value.forced { return .double(number) }
        case "int", "long", "short", "byte":
            if case .char(let character) = value.forced {
                return .int(Int64(character.unicodeScalars.first?.value ?? 0))
            }
        default:
            break
        }
        return value
    }

    /// `+` で片方が文字列なら連結、`char` 同士は整数。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        if op == "+" {
            if case .string = lhs.forced { return .string(display(lhs) + display(rhs)) }
            if case .string = rhs.forced { return .string(display(lhs) + display(rhs)) }
        }
        // char は数値として計算する。
        if case .char(let left) = lhs.forced, rhs.isNumeric || rhs.asInt != nil,
           "+-*/%".contains(op), op.count == 1 {
            let leftValue = Int64(left.unicodeScalars.first?.value ?? 0)
            return try MLOperations.arithmetic(op: op, lhs: .int(leftValue), rhs: rhs,
                                               semantics: self)
        }
        if case .char(let right) = rhs.forced, lhs.isNumeric, "+-*/%".contains(op),
           op.count == 1 {
            let rightValue = Int64(right.unicodeScalars.first?.value ?? 0)
            return try MLOperations.arithmetic(op: op, lhs: lhs, rhs: .int(rightValue),
                                               semantics: self)
        }
        return nil
    }

    override func areEqual(_ lhs: MLValue, _ rhs: MLValue) -> Bool {
        // Java の `==` は参照比較だが、文字列リテラルの比較でつまずくのは
        // 学習の役に立たないので、値としての比較にしている。
        MLOperations.strictEquals(lhs, rhs, semantics: self)
    }

    /// Java の 0 除算は捕まえられる例外。
    override func divideIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        guard rhs != 0 else {
            throw MLError.thrown(.object(JavaLibrary.exception("ArithmeticException",
                                                               "/ by zero")))
        }
        return .int(lhs / rhs)
    }

    override func moduloIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        guard rhs != 0 else {
            throw MLError.thrown(.object(JavaLibrary.exception("ArithmeticException",
                                                               "/ by zero")))
        }
        return .int(lhs % rhs)
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        JavaLibrary.install(into: environment, interpreter: interpreter, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        // `array.length`
        if name == "length", let array = value.asArray { return .int(Int64(array.count)) }
        return nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try JavaLibrary.method(on: value, name: name, context: context, semantics: self)
    }
}
