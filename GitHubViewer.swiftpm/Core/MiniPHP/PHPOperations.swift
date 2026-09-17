import Foundation

/// PHP の演算子の意味 (型ジャグリングを含む)。
enum PHPOperations {
    static func binary(_ op: String, _ left: PHPValue, _ right: PHPValue,
                       _ location: SourceLocation) throws -> PHPValue {
        switch op {
        case ".":
            return .text(left.asString + right.asString)

        case "+":
            if case .array(let leftArray) = left, case .array(let rightArray) = right {
                var result = leftArray
                for key in rightArray.keys where result[key] == nil {
                    result[key] = rightArray[key]
                }
                return .array(result)
            }
            return arithmetic(left, right) { $0 &+ $1 } double: { $0 + $1 }

        case "-":
            return arithmetic(left, right) { $0 &- $1 } double: { $0 - $1 }

        case "*":
            return arithmetic(left, right) { $0 &* $1 } double: { $0 * $1 }

        case "/":
            let divisor = right.asDouble
            guard divisor != 0 else {
                throw PHPRuntimeFailure(message: "0 で割ろうとしました。", location: location)
            }
            if isInteger(left), isInteger(right) {
                let a = left.asInt
                let b = right.asInt
                if b != 0, a % b == 0 { return .integer(a / b) }
            }
            return .number(left.asDouble / divisor)

        case "%":
            let divisor = right.asInt
            guard divisor != 0 else {
                throw PHPRuntimeFailure(message: "0 で剰余を求めようとしました。", location: location)
            }
            return .integer(left.asInt % divisor)

        case "**":
            if isInteger(left), isInteger(right), right.asInt >= 0 {
                let result = Foundation.pow(left.asDouble, right.asDouble)
                if result.magnitude < 9.2e18 { return .integer(Int64(result)) }
                return .number(result)
            }
            return .number(Foundation.pow(left.asDouble, right.asDouble))

        case "==": return .boolean(try looseEquals(left, right))
        case "!=": return .boolean(!(try looseEquals(left, right)))
        case "===": return .boolean(strictEquals(left, right))
        case "!==": return .boolean(!strictEquals(left, right))
        case "<": return .boolean(compare(left, right) < 0)
        case "<=": return .boolean(compare(left, right) <= 0)
        case ">": return .boolean(compare(left, right) > 0)
        case ">=": return .boolean(compare(left, right) >= 0)
        case "<=>": return .integer(Int64(compare(left, right)))

        case "&": return .integer(left.asInt & right.asInt)
        case "|": return .integer(left.asInt | right.asInt)
        case "^": return .integer(left.asInt ^ right.asInt)
        case "<<": return .integer(left.asInt << right.asInt)
        case ">>": return .integer(left.asInt >> right.asInt)

        default:
            throw PHPRuntimeFailure(message: "知らない演算子です: \(op)", location: location)
        }
    }

    private static func isInteger(_ value: PHPValue) -> Bool {
        switch value {
        case .integer, .boolean, .null: return true
        case .text(let text):
            if case .integer? = PHPValue.parseNumeric(text) { return true }
            return false
        default: return false
        }
    }

    private static func arithmetic(_ left: PHPValue, _ right: PHPValue,
                                   integer: (Int64, Int64) -> Int64,
                                   double: (Double, Double) -> Double) -> PHPValue {
        if isInteger(left), isInteger(right) {
            let a = left.asInt
            let b = right.asInt
            let result = integer(a, b)
            // あふれたら浮動小数点に切り替える (PHP と同じ)
            let exact = double(Double(a), Double(b))
            if Swift.abs(exact) > 9.2e18 { return .number(exact) }
            return .integer(result)
        }
        return .number(double(left.asDouble, right.asDouble))
    }

    /// `==` (PHP 8 の規則)。
    static func looseEquals(_ left: PHPValue, _ right: PHPValue) throws -> Bool {
        switch (left, right) {
        case (.null, .null): return true
        case (.boolean, _), (_, .boolean):
            return left.asBool == right.asBool
        case (.null, _):
            return !right.asBool && !isArray(right) || (isArray(right) && right.asArray.isEmpty)
        case (_, .null):
            return try looseEquals(right, left)
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for key in a.keys {
                guard let other = b[key], let mine = a[key] else { return false }
                if !(try looseEquals(mine, other)) { return false }
            }
            return true
        case (.array, _), (_, .array):
            return false
        case (.object(let a), .object(let b)):
            return a === b || (a.className == b.className && a.properties == b.properties)
        case (.text(let a), .text(let b)):
            if let leftNumber = PHPValue.parseNumeric(a), let rightNumber = PHPValue.parseNumeric(b) {
                return leftNumber.asDouble == rightNumber.asDouble
            }
            return a == b
        case (.text(let text), _):
            // PHP 8: 数値でない文字列とは、数値を文字列にしてから比べる
            if PHPValue.parseNumeric(text) == nil { return text == right.asString }
            return left.asDouble == right.asDouble
        case (_, .text(let text)):
            if PHPValue.parseNumeric(text) == nil { return left.asString == text }
            return left.asDouble == right.asDouble
        default:
            return left.asDouble == right.asDouble
        }
    }

    static func strictEquals(_ left: PHPValue, _ right: PHPValue) -> Bool {
        switch (left, right) {
        case (.null, .null): return true
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count, a.keys == b.keys else { return false }
            for key in a.keys where !strictEquals(a[key] ?? .null, b[key] ?? .null) { return false }
            return true
        case (.object(let a), .object(let b)): return a === b
        case (.closure(let a), .closure(let b)): return a === b
        default: return false
        }
    }

    /// `<`, `>`, `<=>` のための比較。
    static func compare(_ left: PHPValue, _ right: PHPValue) -> Int {
        switch (left, right) {
        case (.array(let a), .array(let b)):
            if a.count != b.count { return a.count < b.count ? -1 : 1 }
            for key in a.keys {
                guard let other = b[key] else { return 1 }
                let result = compare(a[key] ?? .null, other)
                if result != 0 { return result }
            }
            return 0
        case (.text(let a), .text(let b)):
            if let leftNumber = PHPValue.parseNumeric(a), let rightNumber = PHPValue.parseNumeric(b) {
                let x = leftNumber.asDouble
                let y = rightNumber.asDouble
                return x == y ? 0 : (x < y ? -1 : 1)
            }
            return a == b ? 0 : (a < b ? -1 : 1)
        case (.boolean, _), (_, .boolean), (.null, _), (_, .null):
            let x = left.asBool
            let y = right.asBool
            return x == y ? 0 : (!x ? -1 : 1)
        case (.text(let text), _):
            if PHPValue.parseNumeric(text) == nil {
                let other = right.asString
                return text == other ? 0 : (text < other ? -1 : 1)
            }
            let x = left.asDouble
            let y = right.asDouble
            return x == y ? 0 : (x < y ? -1 : 1)
        case (_, .text(let text)):
            if PHPValue.parseNumeric(text) == nil {
                let mine = left.asString
                return mine == text ? 0 : (mine < text ? -1 : 1)
            }
            let x = left.asDouble
            let y = right.asDouble
            return x == y ? 0 : (x < y ? -1 : 1)
        default:
            let x = left.asDouble
            let y = right.asDouble
            return x == y ? 0 : (x < y ? -1 : 1)
        }
    }

    private static func isArray(_ value: PHPValue) -> Bool {
        if case .array = value { return true }
        return false
    }
}
