import Foundation

/// 二項演算・比較の共通処理。言語ごとの差は `MLSemantics` が先に横取りする。
public enum MLOperations {

    // MARK: 算術

    public static func arithmetic(op: String, lhs rawLHS: MLValue, rhs rawRHS: MLValue,
                                  semantics: MLSemantics) throws -> MLValue {
        let lhs = rawLHS.forced
        let rhs = rawRHS.forced

        // 文字列の連結。
        if op == "+" {
            if case .string(let left) = lhs {
                return .string(left + semantics.stringify(rhs))
            }
            if case .string(let right) = rhs {
                return .string(semantics.stringify(lhs) + right)
            }
            if let left = lhs.asArray, let right = rhs.asArray {
                return .array(MLArray(left.elements + right.elements))
            }
        }

        guard lhs.isNumeric || lhs.asInt != nil, rhs.isNumeric || rhs.asInt != nil else {
            throw MLError.runtime(
                "\(semantics.typeName(of: lhs)) と \(semantics.typeName(of: rhs)) の間で `\(op)` は使えません")
        }

        // どちらかが小数なら小数演算。
        if case .double = lhs {
            return try doubleArithmetic(op: op, lhs.asDouble ?? 0, rhs.asDouble ?? 0, semantics)
        }
        if case .double = rhs {
            return try doubleArithmetic(op: op, lhs.asDouble ?? 0, rhs.asDouble ?? 0, semantics)
        }

        guard let left = lhs.asInt, let right = rhs.asInt else {
            throw MLError.runtime("`\(op)` に数値以外が渡されました")
        }
        return try integerArithmetic(op: op, left, right, semantics)
    }

    static func integerArithmetic(op: String, _ lhs: Int64, _ rhs: Int64,
                                  _ semantics: MLSemantics) throws -> MLValue {
        switch op {
        case "+":
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return try semantics.wrapInteger(value, overflow: overflow)
        case "-":
            let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
            return try semantics.wrapInteger(value, overflow: overflow)
        case "*":
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            return try semantics.wrapInteger(value, overflow: overflow)
        case "/":
            return try semantics.divideIntegers(lhs, rhs)
        case "%":
            return try semantics.moduloIntegers(lhs, rhs)
        case "**", "^^":
            return power(Double(lhs), Double(rhs), preferInteger: rhs >= 0)
        case "&": return .int(lhs & rhs)
        case "|": return .int(lhs | rhs)
        case "^": return .int(lhs ^ rhs)
        case "<<":
            guard rhs >= 0, rhs < 64 else { return .int(0) }
            return .int(lhs << rhs)
        case ">>":
            guard rhs >= 0 else { return .int(0) }
            if rhs >= 64 { return .int(lhs < 0 ? -1 : 0) }
            return .int(lhs >> rhs)
        case ">>>":
            guard rhs >= 0 else { return .int(0) }
            if rhs >= 64 { return .int(0) }
            return .int(Int64(bitPattern: UInt64(bitPattern: lhs) >> UInt64(rhs)))
        default:
            throw MLError.runtime("知らない演算子です: \(op)")
        }
    }

    static func doubleArithmetic(op: String, _ lhs: Double, _ rhs: Double,
                                 _ semantics: MLSemantics) throws -> MLValue {
        switch op {
        case "+": return .double(lhs + rhs)
        case "-": return .double(lhs - rhs)
        case "*": return .double(lhs * rhs)
        case "/": return .double(lhs / rhs)
        case "%": return .double(lhs.truncatingRemainder(dividingBy: rhs))
        case "**", "^^": return .double(pow(lhs, rhs))
        default:
            throw MLError.runtime("小数には `\(op)` は使えません")
        }
    }

    /// 冪乗。整数同士で結果も整数に収まるなら整数で返す。
    public static func power(_ base: Double, _ exponent: Double, preferInteger: Bool) -> MLValue {
        let result = pow(base, exponent)
        if preferInteger, base == base.rounded(), exponent == exponent.rounded(),
           result == result.rounded(), abs(result) < 9.0e18 {
            return .int(Int64(result))
        }
        return .double(result)
    }

    // MARK: 比較

    /// 型まで見る厳密な等価。
    public static func strictEquals(_ rawLHS: MLValue, _ rawRHS: MLValue,
                                    semantics: MLSemantics) -> Bool {
        let lhs = rawLHS.forced
        let rhs = rawRHS.forced
        switch (lhs, rhs) {
        case (.unit, .unit): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)): return Double(a) == b
        case (.double(let a), .int(let b)): return a == Double(b)
        case (.char(let a), .char(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.char(let a), .string(let b)): return String(a) == b
        case (.string(let a), .char(let b)): return a == String(b)
        case (.symbol(let a), .symbol(let b)): return a == b
        case (.array(let a), .array(let b)):
            if a === b { return true }
            guard a.count == b.count else { return false }
            for index in 0..<a.count
            where !strictEquals(a.elements[index], b.elements[index], semantics: semantics) {
                return false
            }
            return true
        case (.tuple(let a), .tuple(let b)):
            guard a.count == b.count else { return false }
            for index in 0..<a.count
            where !strictEquals(a[index], b[index], semantics: semantics) { return false }
            return true
        case (.map(let a), .map(let b)):
            if a === b { return true }
            guard a.count == b.count else { return false }
            for (key, value) in a.pairs {
                guard let other = b[key],
                      strictEquals(value, other, semantics: semantics) else { return false }
            }
            return true
        case (.object(let a), .object(let b)):
            if a === b { return true }
            guard a.typeName == b.typeName, a.caseName == b.caseName,
                  a.payload.count == b.payload.count else { return false }
            for index in 0..<a.payload.count
            where !strictEquals(a.payload[index], b.payload[index], semantics: semantics) {
                return false
            }
            guard a.fields.count == b.fields.count else { return false }
            for (key, value) in a.fields.pairs {
                guard let other = b.fields[key],
                      strictEquals(value, other, semantics: semantics) else { return false }
            }
            return true
        case (.function(let a), .function(let b)): return a === b
        case (.range(let a), .range(let b)):
            return a.lower == b.lower && a.upper == b.upper && a.isClosed == b.isClosed
        default: return false
        }
    }

    /// 既定の大小比較。比べられないときは nil。
    public static func defaultCompare(_ rawLHS: MLValue, _ rawRHS: MLValue,
                                      semantics: MLSemantics) -> Int? {
        let lhs = rawLHS.forced
        let rhs = rawRHS.forced
        if let left = lhs.asString, let right = rhs.asString,
           !lhs.isNumeric, !rhs.isNumeric {
            if left == right { return 0 }
            // Unicode スカラ順 (多くの言語のバイト比較に近い)。
            return Array(left.unicodeScalars).lexicographicallyPrecedes(
                Array(right.unicodeScalars), by: { $0.value < $1.value }) ? -1 : 1
        }
        if case .int(let left) = lhs, case .int(let right) = rhs {
            return left == right ? 0 : (left < right ? -1 : 1)
        }
        if let left = lhs.asDouble, let right = rhs.asDouble {
            if left == right { return 0 }
            return left < right ? -1 : 1
        }
        if case .bool(let left) = lhs, case .bool(let right) = rhs {
            return left == right ? 0 : (right ? -1 : 1)
        }
        // 配列・タプルは辞書順。
        let leftItems = sequenceItems(lhs)
        let rightItems = sequenceItems(rhs)
        if let leftItems, let rightItems {
            for index in 0..<min(leftItems.count, rightItems.count) {
                guard let order = defaultCompare(leftItems[index], rightItems[index],
                                                 semantics: semantics) else { return nil }
                if order != 0 { return order }
            }
            if leftItems.count == rightItems.count { return 0 }
            return leftItems.count < rightItems.count ? -1 : 1
        }
        return nil
    }

    static func sequenceItems(_ value: MLValue) -> [MLValue]? {
        switch value.forced {
        case .array(let array): return array.elements
        case .tuple(let items): return items
        default: return nil
        }
    }

    // MARK: 繰り返せる値

    /// `for x in ...` で回せる形にほどく。
    public static func iterate(_ value: MLValue, semantics: MLSemantics) throws -> [MLValue] {
        switch value.forced {
        case .array(let array): return array.elements
        case .tuple(let items): return items
        case .range(let range): return range.elements.map { MLValue.int($0) }
        case .string(let text): return text.map { MLValue.char($0) }
        case .map(let map):
            return map.pairs.map { MLValue.tuple([$0.key.asValue, $0.value]) }
        case .object(let object):
            // 単方向リストのような代数的データ型もほどけるようにしておく。
            if object.caseName != nil { return object.payload }
            return object.fields.values
        case .unit: return []
        default:
            throw MLError.runtime("\(semantics.typeName(of: value)) は繰り返せません")
        }
    }

    // MARK: 添字

    /// 添字を Swift の 0 起点に直す。範囲外なら nil。
    public static func normalizeIndex(_ index: Int64, count: Int,
                                      semantics: MLSemantics) -> Int? {
        var position = Int(index) - semantics.indexBase
        if position < 0, semantics.allowsNegativeIndexing { position += count }
        guard position >= 0, position < count else { return nil }
        return position
    }
}
