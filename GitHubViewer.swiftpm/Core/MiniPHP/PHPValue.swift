import Foundation

/// PHP の配列のキー (整数か文字列)。
public enum PHPKey: Hashable {
    case integer(Int64)
    case text(String)

    var asValue: PHPValue {
        switch self {
        case .integer(let value): return .integer(value)
        case .text(let value): return .text(value)
        }
    }

    var description: String {
        switch self {
        case .integer(let value): return String(value)
        case .text(let value): return value
        }
    }
}

/// 順序を保つ PHP の配列。値型なので、代入するとコピーされる (PHP と同じ)。
public struct PHPArray: Equatable {
    private(set) var order: [PHPKey] = []
    private(set) var storage: [PHPKey: PHPValue] = [:]
    /// 次に `$a[] = x` で使われる整数キー。
    private(set) var nextIndex: Int64 = 0

    public init() {}

    public var count: Int { order.count }
    public var keys: [PHPKey] { order }
    public var values: [PHPValue] { order.compactMap { storage[$0] } }
    public var isEmpty: Bool { order.isEmpty }

    public subscript(key: PHPKey) -> PHPValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { order.append(key) }
                storage[key] = newValue
                if case .integer(let index) = key, index >= nextIndex { nextIndex = index + 1 }
            } else {
                if storage[key] != nil {
                    order.removeAll { $0 == key }
                    storage[key] = nil
                }
            }
        }
    }

    public mutating func append(_ value: PHPValue) {
        self[.integer(nextIndex)] = value
    }

    public mutating func removeValue(forKey key: PHPKey) {
        self[key] = nil
    }

    /// キーはそのままに、値だけ並べ替える (sort 系で使う)。
    public mutating func replaceValues(_ newValues: [PHPValue]) {
        for (index, key) in order.enumerated() where index < newValues.count {
            storage[key] = newValues[index]
        }
    }

    /// キーを捨てて 0 から振り直す (sort / array_values)。
    public mutating func reindex(with newValues: [PHPValue]) {
        order.removeAll()
        storage.removeAll()
        nextIndex = 0
        for value in newValues { append(value) }
    }

    /// キーと値の組をそのまま置き換える (ksort / asort)。
    public mutating func reorder(_ pairs: [(PHPKey, PHPValue)]) {
        order = pairs.map(\.0)
        storage = [:]
        for (key, value) in pairs { storage[key] = value }
    }

    public static func from(_ values: [PHPValue]) -> PHPArray {
        var array = PHPArray()
        for value in values { array.append(value) }
        return array
    }

    public static func from(_ pairs: [(PHPKey, PHPValue)]) -> PHPArray {
        var array = PHPArray()
        for (key, value) in pairs { array[key] = value }
        return array
    }
}

/// クラスのインスタンス。PHP のオブジェクトは参照なので class で表す。
public final class PHPObject: Equatable {
    public let className: String
    public var properties: PHPArray

    public init(className: String, properties: PHPArray = PHPArray()) {
        self.className = className
        self.properties = properties
    }

    public static func == (lhs: PHPObject, rhs: PHPObject) -> Bool { lhs === rhs }
}

/// 無名関数 (クロージャ)。
public final class PHPClosure: Equatable {
    public let declaration: PHPFunctionDeclaration
    /// `use` で取り込んだ変数。
    public let captured: [String: PHPValue]
    /// メソッドとして呼ぶときの `$this`。
    public let boundObject: PHPObject?

    public init(declaration: PHPFunctionDeclaration, captured: [String: PHPValue], boundObject: PHPObject? = nil) {
        self.declaration = declaration
        self.captured = captured
        self.boundObject = boundObject
    }

    public static func == (lhs: PHPClosure, rhs: PHPClosure) -> Bool { lhs === rhs }
}

/// PHP の値。
public indirect enum PHPValue: Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case text(String)
    case array(PHPArray)
    case object(PHPObject)
    case closure(PHPClosure)

    // MARK: - 型の名前

    public var typeName: String {
        switch self {
        case .null: return "NULL"
        case .boolean: return "boolean"
        case .integer: return "integer"
        case .number: return "double"
        case .text: return "string"
        case .array: return "array"
        case .object: return "object"
        case .closure: return "object"
        }
    }

    // MARK: - 変換 (PHP の型ジャグリング)

    public var asBool: Bool {
        switch self {
        case .null: return false
        case .boolean(let value): return value
        case .integer(let value): return value != 0
        case .number(let value): return value != 0
        case .text(let value): return !(value.isEmpty || value == "0")
        case .array(let value): return !value.isEmpty
        case .object, .closure: return true
        }
    }

    public var asInt: Int64 {
        switch self {
        case .null: return 0
        case .boolean(let value): return value ? 1 : 0
        case .integer(let value): return value
        case .number(let value):
            guard value.isFinite else { return 0 }
            return Int64(value.rounded(.towardZero))
        case .text(let value): return PHPValue.numericPrefix(value).asInt
        case .array(let value): return value.isEmpty ? 0 : 1
        case .object, .closure: return 1
        }
    }

    public var asDouble: Double {
        switch self {
        case .null: return 0
        case .boolean(let value): return value ? 1 : 0
        case .integer(let value): return Double(value)
        case .number(let value): return value
        case .text(let value): return PHPValue.numericPrefix(value).asDouble
        case .array(let value): return value.isEmpty ? 0 : 1
        case .object, .closure: return 1
        }
    }

    public var asString: String {
        switch self {
        case .null: return ""
        case .boolean(let value): return value ? "1" : ""
        case .integer(let value): return String(value)
        case .number(let value): return PHPValue.format(value)
        case .text(let value): return value
        case .array: return "Array"
        case .object(let object): return "Object(\(object.className))"
        case .closure: return "Closure"
        }
    }

    public var asArray: PHPArray {
        switch self {
        case .array(let value): return value
        case .null: return PHPArray()
        case .object(let object): return object.properties
        default: return PHPArray.from([self])
        }
    }

    public var asKey: PHPKey {
        switch self {
        case .integer(let value): return .integer(value)
        case .boolean(let value): return .integer(value ? 1 : 0)
        case .number(let value): return .integer(Int64(value))
        case .null: return .text("")
        case .text(let value):
            // "10" のような整数そのものの文字列は整数キーになる
            if let number = Int64(value), String(number) == value { return .integer(number) }
            return .text(value)
        default: return .text(asString)
        }
    }

    /// 数値として扱えるか (PHP の is_numeric 相当)。
    public var isNumericValue: Bool {
        switch self {
        case .integer, .number: return true
        case .text(let value): return PHPValue.parseNumeric(value) != nil
        default: return false
        }
    }

    /// 数値文字列を数値にする。数値でなければ 0。
    static func numericPrefix(_ text: String) -> PHPValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = parseNumeric(trimmed) { return value }
        // 先頭の数値部分だけを取る ("42abc" → 42)
        var digits = ""
        var seenDot = false
        var seenExponent = false
        for (index, character) in trimmed.enumerated() {
            if character == "-" || character == "+" {
                if index == 0 || digits.last == "e" || digits.last == "E" {
                    digits.append(character)
                    continue
                }
                break
            }
            if character.isNumber {
                digits.append(character)
            } else if character == ".", !seenDot, !seenExponent {
                seenDot = true
                digits.append(character)
            } else if character == "e" || character == "E", !seenExponent, !digits.isEmpty {
                seenExponent = true
                digits.append(character)
            } else {
                break
            }
        }
        if digits.isEmpty { return .integer(0) }
        if seenDot || seenExponent { return .number(Double(digits) ?? 0) }
        return .integer(Int64(digits) ?? 0)
    }

    /// 全体が数値ならその値を返す。
    static func parseNumeric(_ text: String) -> PHPValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Int64(trimmed) { return .integer(value) }
        if let value = Double(trimmed), trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "xX")) == nil {
            return .number(value)
        }
        return nil
    }

    /// PHP の echo と同じ小数の書き方 (precision=14)。
    public static func format(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }

        var text = String(format: "%.14G", value)
        if text.contains("E") {
            // 1E+20 → 1.0E+20
            let parts = text.components(separatedBy: "E")
            var mantissa = parts[0]
            if !mantissa.contains(".") { mantissa += ".0" }
            text = mantissa + "E" + parts[1]
        } else if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
