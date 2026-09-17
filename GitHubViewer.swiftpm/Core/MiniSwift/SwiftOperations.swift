import Foundation

/// Swift の演算子の意味。
enum SwiftOperations {
    static func binary(_ op: String, _ left: SwiftValue, _ right: SwiftValue,
                       _ location: SourceLocation) throws -> SwiftValue {
        switch op {
        case "+":
            if case .string(let a) = left {
                return .string(a + right.displayText)
            }
            if case .array(let a) = left, case .array(let b) = right {
                return .array(a + b)
            }
            return try arithmetic(left, right, location) { $0 + $1 } double: { $0 + $1 }
        case "-":
            return try arithmetic(left, right, location) { $0 - $1 } double: { $0 - $1 }
        case "*":
            return try arithmetic(left, right, location) { $0 * $1 } double: { $0 * $1 }
        case "/":
            if isDouble(left) || isDouble(right) {
                return .double(left.asDouble / right.asDouble)
            }
            guard right.asInt != 0 else {
                throw SwiftRuntimeFailure(message: "0 で割ろうとしました。", location: location)
            }
            return .integer(left.asInt / right.asInt)
        case "%":
            guard right.asInt != 0 else {
                throw SwiftRuntimeFailure(message: "0 で剰余を求めようとしました。", location: location)
            }
            if isDouble(left) || isDouble(right) {
                return .double(left.asDouble.truncatingRemainder(dividingBy: right.asDouble))
            }
            return .integer(left.asInt % right.asInt)
        case "==": return .boolean(equals(left, right))
        case "!=": return .boolean(!equals(left, right))
        case "<": return .boolean(compare(left, right) < 0)
        case "<=": return .boolean(compare(left, right) <= 0)
        case ">": return .boolean(compare(left, right) > 0)
        case ">=": return .boolean(compare(left, right) >= 0)
        default:
            throw SwiftRuntimeFailure(message: "知らない演算子です: \(op)", location: location)
        }
    }

    private static func isDouble(_ value: SwiftValue) -> Bool {
        if case .double = value { return true }
        return false
    }

    private static func arithmetic(_ left: SwiftValue, _ right: SwiftValue, _ location: SourceLocation,
                                   integer: (Int, Int) -> Int,
                                   double: (Double, Double) -> Double) throws -> SwiftValue {
        if isDouble(left) || isDouble(right) {
            return .double(double(left.asDouble, right.asDouble))
        }
        let a = left.asInt
        let b = right.asInt
        let result = double(Double(a), Double(b))
        guard Swift.abs(result) <= 9.2e18 else {
            throw SwiftRuntimeFailure(message: "整数の計算があふれました。", location: location)
        }
        return .integer(integer(a, b))
    }

    static func equals(_ left: SwiftValue, _ right: SwiftValue) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case (.none, _), (_, .none): return false
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.integer(let a), .double(let b)): return Double(a) == b
        case (.double(let a), .integer(let b)): return a == Double(b)
        case (.string(let a), .string(let b)): return a == b
        case (.character(let a), .character(let b)): return a == b
        case (.string(let a), .character(let b)): return a == String(b)
        case (.character(let a), .string(let b)): return String(a) == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { equals($0, $1) }
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            for pair in a {
                guard let other = b.first(where: { equals($0.key, pair.key) }) else { return false }
                if !equals(other.value, pair.value) { return false }
            }
            return true
        case (.tuple(let a), .tuple(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { equals($0.value, $1.value) }
        case (.enumeration(let typeA, let caseA, _), .enumeration(let typeB, let caseB, _)):
            return typeA == typeB && caseA == caseB
        case (.structure(let nameA, let propertiesA), .structure(let nameB, let propertiesB)):
            guard nameA == nameB, propertiesA.names == propertiesB.names else { return false }
            return propertiesA.names.allSatisfy {
                equals(propertiesA[$0] ?? .none, propertiesB[$0] ?? .none)
            }
        case (.object(let a), .object(let b)): return a === b
        case (.range(let lowerA, let upperA, let closedA), .range(let lowerB, let upperB, let closedB)):
            return lowerA == lowerB && upperA == upperB && closedA == closedB
        default: return false
        }
    }

    static func compare(_ left: SwiftValue, _ right: SwiftValue) -> Int {
        switch (left, right) {
        case (.string(let a), .string(let b)):
            return a == b ? 0 : (a < b ? -1 : 1)
        case (.character(let a), .character(let b)):
            return a == b ? 0 : (a < b ? -1 : 1)
        case (.array(let a), .array(let b)):
            for (x, y) in zip(a, b) {
                let result = compare(x, y)
                if result != 0 { return result }
            }
            return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
        default:
            let a = left.asDouble
            let b = right.asDouble
            return a == b ? 0 : (a < b ? -1 : 1)
        }
    }
}
