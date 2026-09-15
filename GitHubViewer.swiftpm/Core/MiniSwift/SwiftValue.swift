import Foundation

/// 構造体・クラスのインスタンスが持つ、順序つきのプロパティ。
public struct SwiftProperties {
    private(set) var order: [String] = []
    private(set) var storage: [String: SwiftValue] = [:]

    public init() {}

    public subscript(name: String) -> SwiftValue? {
        get { storage[name] }
        set {
            if let newValue {
                if storage[name] == nil { order.append(name) }
                storage[name] = newValue
            } else {
                order.removeAll { $0 == name }
                storage[name] = nil
            }
        }
    }

    public var names: [String] { order }
}

/// クラスのインスタンス (参照型)。
public final class SwiftObject {
    public let typeName: String
    public var properties: SwiftProperties

    public init(typeName: String, properties: SwiftProperties) {
        self.typeName = typeName
        self.properties = properties
    }
}

/// クロージャ (関数も同じ形で持つ)。
public final class SwiftClosure {
    public let declaration: SwiftFunctionDeclaration
    public let captured: [String: SwiftValue]
    public let boundSelf: SwiftValue?
    /// 定義されたときのスコープ (Swift と同じく参照で捕まえる)。
    let environment: SwiftEnvironment?

    init(declaration: SwiftFunctionDeclaration, captured: [String: SwiftValue],
         boundSelf: SwiftValue? = nil, environment: SwiftEnvironment? = nil) {
        self.declaration = declaration
        self.captured = captured
        self.boundSelf = boundSelf
        self.environment = environment
    }
}

/// MiniSwift が扱う値。
public indirect enum SwiftValue {
    case none                       // nil
    case boolean(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case character(Character)
    case array([SwiftValue])
    /// キーの順序を保つ辞書 (Swift の辞書は順不同だが、表示を安定させるため順序を覚えておく)。
    case dictionary([(key: SwiftValue, value: SwiftValue)])
    case tuple([(label: String?, value: SwiftValue)])
    case range(lower: Int, upper: Int, isClosed: Bool)
    /// 構造体 (値型なのでコピーされる)
    case structure(typeName: String, properties: SwiftProperties)
    /// 列挙型の値 (raw 値つき)
    case enumeration(typeName: String, caseName: String, rawValue: SwiftValue?)
    case object(SwiftObject)
    case closure(SwiftClosure)
    /// 型そのもの (Int.self のような使い方や、メソッド解決のために使う)
    case metatype(String)

    public var isNil: Bool {
        if case .none = self { return true }
        return false
    }

    public var typeName: String {
        switch self {
        case .none: return "Optional"
        case .boolean: return "Bool"
        case .integer: return "Int"
        case .double: return "Double"
        case .string: return "String"
        case .character: return "Character"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        case .tuple: return "Tuple"
        case .range: return "Range"
        case .structure(let name, _): return name
        case .enumeration(let name, _, _): return name
        case .object(let object): return object.typeName
        case .closure: return "Function"
        case .metatype(let name): return name
        }
    }

    public var asBool: Bool {
        switch self {
        case .boolean(let value): return value
        case .integer(let value): return value != 0
        case .none: return false
        default: return true
        }
    }

    public var asInt: Int {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int(value)
        case .boolean(let value): return value ? 1 : 0
        case .string(let value): return Int(value) ?? 0
        default: return 0
        }
    }

    public var asDouble: Double {
        switch self {
        case .integer(let value): return Double(value)
        case .double(let value): return value
        case .boolean(let value): return value ? 1 : 0
        case .string(let value): return Double(value) ?? 0
        default: return 0
        }
    }

    public var asArray: [SwiftValue] {
        switch self {
        case .array(let values): return values
        case .range(let lower, let upper, let isClosed):
            guard lower <= upper else { return [] }
            return (isClosed ? Array(lower...upper) : Array(lower..<upper)).map { .integer($0) }
        case .string(let text): return text.map { .character($0) }
        case .dictionary(let pairs): return pairs.map { .tuple([(label: "key", value: $0.key),
                                                                (label: "value", value: $0.value)]) }
        default: return []
        }
    }

    /// `print` や文字列補間での表示。
    public var displayText: String {
        SwiftFormatter.describe(self, topLevel: true)
    }
}

/// Swift の標準的な表示のしかたを再現する。
public enum SwiftFormatter {
    public static func describe(_ value: SwiftValue, topLevel: Bool) -> String {
        switch value {
        case .none:
            return "nil"
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .integer(let number):
            return String(number)
        case .double(let number):
            return doubleText(number)
        case .string(let text):
            return topLevel ? text : "\"\(text)\""
        case .character(let character):
            return topLevel ? String(character) : "\"\(character)\""
        case .array(let values):
            return "[" + values.map { describe($0, topLevel: false) }.joined(separator: ", ") + "]"
        case .dictionary(let pairs):
            if pairs.isEmpty { return "[:]" }
            return "[" + pairs.map { "\(describe($0.key, topLevel: false)): \(describe($0.value, topLevel: false))" }
                .joined(separator: ", ") + "]"
        case .tuple(let items):
            return "(" + items.map { item in
                if let label = item.label { return "\(label): \(describe(item.value, topLevel: false))" }
                return describe(item.value, topLevel: false)
            }.joined(separator: ", ") + ")"
        case .range(let lower, let upper, let isClosed):
            return "\(lower)\(isClosed ? "..." : "..<")\(upper)"
        case .structure(let name, let properties):
            let fields = properties.names.map { "\($0): \(describe(properties[$0] ?? .none, topLevel: false))" }
            return "\(name)(\(fields.joined(separator: ", ")))"
        case .enumeration(_, let caseName, _):
            return caseName
        case .object(let object):
            return object.typeName
        case .closure:
            return "(Function)"
        case .metatype(let name):
            return name
        }
    }

    /// Swift の Double の表示 (1.0 は "1.0"、0.1+0.2 は "0.30000000000000004")。
    public static func doubleText(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        var text = "\(value)"
        if text.contains("e") {
            // 1e+20 → 1e+20 (Swift の表記に合わせる)
            text = text.replacingOccurrences(of: "e+", with: "e+")
        }
        return text
    }
}
