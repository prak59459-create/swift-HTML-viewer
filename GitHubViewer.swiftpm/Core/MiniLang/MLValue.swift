import Foundation

/// 内蔵処理系が共通で扱う値。
///
/// 26 言語ぶんの処理系を別々の値モデルで書くと維持できないので、
/// 「だいたいどの言語にもある形」をここに集めてある。
/// 言語ごとの差 (整数割り算の丸め、真偽値の判定、print の書式など) は
/// `MLSemantics` 側で吸収する。
public enum MLValue {
    /// void / nil / null / None / Unit / undefined をまとめたもの。
    case unit
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case char(Character)
    case string(String)
    /// 配列・リスト・ベクタ・スライス。参照箱なので別名からの書き換えが見える。
    case array(MLArray)
    /// 辞書・マップ・連想配列。挿入順を保つ。
    case map(MLMap)
    /// タプル (固定長・要素ごとに型が違ってよい)。値として扱う。
    case tuple([MLValue])
    /// クラスのインスタンス・構造体・レコード・代数的データ型の値。
    case object(MLObject)
    case function(MLFunction)
    case range(MLRange)
    /// アトム / シンボル / キーワード (Elixir の `:ok`, Lisp の `'foo` など)。
    case symbol(String)
    /// 遅延評価の未計算値 (Haskell 用)。`force` で潰す。
    case thunk(MLThunk)

    public static func number(_ value: Int) -> MLValue { .int(Int64(value)) }
}

// MARK: - 参照箱

/// 可変な配列の実体。
public final class MLArray {
    public var elements: [MLValue]
    /// 要素の型名 (言語によっては表示に使う)。
    public var elementTypeName: String?

    public init(_ elements: [MLValue] = [], elementTypeName: String? = nil) {
        self.elements = elements
        self.elementTypeName = elementTypeName
    }

    public var count: Int { elements.count }

    public func copy() -> MLArray {
        MLArray(elements.map { $0.deepCopy() }, elementTypeName: elementTypeName)
    }
}

/// 挿入順を保つ辞書。
///
/// PHP の配列や Ruby/Python 的な辞書、JSON など「順番が見える」言語が多いので、
/// 素の Swift Dictionary ではなく順序つきで持つ。
public final class MLMap {
    public private(set) var keys: [MLKey] = []
    private var storage: [MLKey: MLValue] = [:]

    public init() {}

    public init(_ pairs: [(MLKey, MLValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: MLKey) -> MLValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage[key] != nil {
                storage[key] = nil
                if let index = keys.firstIndex(of: key) { keys.remove(at: index) }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [MLValue] { keys.map { storage[$0] ?? .unit } }
    public var pairs: [(key: MLKey, value: MLValue)] { keys.map { ($0, storage[$0] ?? .unit) } }

    public func contains(_ key: MLKey) -> Bool { storage[key] != nil }

    public func removeValue(forKey key: MLKey) -> MLValue? {
        guard let existing = storage[key] else { return nil }
        self[key] = nil
        return existing
    }

    public func removeAll() {
        keys.removeAll()
        storage.removeAll()
    }

    /// 並べ替えなど、キーの順番だけを差し替えたいとき。
    public func reorder(_ newKeys: [MLKey]) {
        precondition(newKeys.count == keys.count)
        keys = newKeys
    }

    public func copy() -> MLMap {
        let result = MLMap()
        for (key, value) in pairs { result[key] = value.deepCopy() }
        return result
    }
}

/// 辞書のキーになれる値。
public enum MLKey: Hashable {
    case int(Int64)
    case string(String)
    case bool(Bool)
    case double(Double)
    case symbol(String)
    case tuple([MLKey])

    public var asValue: MLValue {
        switch self {
        case .int(let value): return .int(value)
        case .string(let value): return .string(value)
        case .bool(let value): return .bool(value)
        case .double(let value): return .double(value)
        case .symbol(let value): return .symbol(value)
        case .tuple(let items): return .tuple(items.map { $0.asValue })
        }
    }

    /// 辞書キーとして使える値なら鍵に変換する。
    public static func from(_ value: MLValue) -> MLKey? {
        switch value.forced {
        case .int(let v): return .int(v)
        case .string(let v): return .string(v)
        case .char(let v): return .string(String(v))
        case .bool(let v): return .bool(v)
        case .double(let v):
            // 1.0 のような整数値は整数キーと同一視する (多くの言語がそう振る舞う)。
            if v == v.rounded(), abs(v) < 9.2e18 { return .int(Int64(v)) }
            return .double(v)
        case .symbol(let v): return .symbol(v)
        case .tuple(let items):
            var keys: [MLKey] = []
            for item in items {
                guard let key = MLKey.from(item) else { return nil }
                keys.append(key)
            }
            return .tuple(keys)
        default: return nil
        }
    }
}

/// クラスのインスタンス / 構造体 / レコード / 代数的データ型の値。
///
/// 「名前つきのフィールドを持つ入れ物」と「タグつきの組」を 1 つの型でまかなう。
public final class MLObject {
    /// 型名 (`Point`, `Person` など)。
    public var typeName: String
    /// 定義への参照 (メソッド解決に使う)。
    public weak var classDeclaration: MLClass?
    /// 名前つきフィールド。
    public var fields: MLMap
    /// 代数的データ型のときのコンストラクタ名 (`Some`, `Cons`, `:ok` など)。
    public var caseName: String?
    /// 代数的データ型の位置引数。
    public var payload: [MLValue]
    /// 言語側が自由に使える付随データ (例外オブジェクトの元の値など)。
    public var attachment: MLValue?

    public init(typeName: String, classDeclaration: MLClass? = nil,
                fields: MLMap = MLMap(), caseName: String? = nil, payload: [MLValue] = []) {
        self.typeName = typeName
        self.classDeclaration = classDeclaration
        self.fields = fields
        self.caseName = caseName
        self.payload = payload
    }

    public func copy() -> MLObject {
        let result = MLObject(typeName: typeName, classDeclaration: classDeclaration,
                              fields: fields.copy(), caseName: caseName,
                              payload: payload.map { $0.deepCopy() })
        result.attachment = attachment
        return result
    }
}

public struct MLRange {
    public var lower: Int64
    public var upper: Int64
    /// 上端を含むか (`1...5` と `1..<5` の違い)。
    public var isClosed: Bool
    public var step: Int64

    public init(lower: Int64, upper: Int64, isClosed: Bool, step: Int64 = 1) {
        self.lower = lower
        self.upper = upper
        self.isClosed = isClosed
        self.step = step == 0 ? 1 : step
    }

    public var elements: [Int64] {
        var result: [Int64] = []
        if step > 0 {
            var current = lower
            while isClosed ? current <= upper : current < upper {
                result.append(current)
                let (next, overflow) = current.addingReportingOverflow(step)
                if overflow { break }
                current = next
            }
        } else {
            var current = lower
            while isClosed ? current >= upper : current > upper {
                result.append(current)
                let (next, overflow) = current.addingReportingOverflow(step)
                if overflow { break }
                current = next
            }
        }
        return result
    }
}

/// 未計算の値 (遅延評価)。一度計算したら結果を覚える。
public final class MLThunk {
    private var compute: (() throws -> MLValue)?
    private var cached: MLValue?
    /// 評価中に自分を再び踏んだら循環定義。
    private var isEvaluating = false

    public init(_ compute: @escaping () throws -> MLValue) {
        self.compute = compute
    }

    public init(value: MLValue) {
        self.cached = value
    }

    public func force() throws -> MLValue {
        if let cached { return cached }
        if isEvaluating {
            throw MLError.runtime("値の定義が自分自身を参照していて、計算が終わりません (循環参照)")
        }
        guard let compute else { return .unit }
        isEvaluating = true
        defer { isEvaluating = false }
        var result = try compute()
        // サンクの入れ子はここで潰しておく。
        while case .thunk(let inner) = result { result = try inner.force() }
        cached = result
        self.compute = nil
        return result
    }

    /// すでに計算済みかどうか (表示のときに無理に評価しないため)。
    public var isForced: Bool { cached != nil }
    public var cachedValue: MLValue? { cached }
}

// MARK: - 便利な問い合わせ

public extension MLValue {
    /// サンクだったら潰した値。潰せない場合はそのまま返す。
    var forced: MLValue {
        if case .thunk(let thunk) = self {
            if let cached = thunk.cachedValue { return cached }
            return (try? thunk.force()) ?? .unit
        }
        return self
    }

    /// サンクを潰す (失敗したら投げる)。
    func force() throws -> MLValue {
        if case .thunk(let thunk) = self { return try thunk.force() }
        return self
    }

    var isUnit: Bool { if case .unit = forced { return true }; return false }

    var asArray: MLArray? { if case .array(let value) = forced { return value }; return nil }
    var asMap: MLMap? { if case .map(let value) = forced { return value }; return nil }
    var asObject: MLObject? { if case .object(let value) = forced { return value }; return nil }
    var asFunction: MLFunction? { if case .function(let value) = forced { return value }; return nil }

    var asString: String? {
        switch forced {
        case .string(let value): return value
        case .char(let value): return String(value)
        default: return nil
        }
    }

    var asInt: Int64? {
        switch forced {
        case .int(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .char(let value): return Int64(value.unicodeScalars.first?.value ?? 0)
        default: return nil
        }
    }

    var asDouble: Double? {
        switch forced {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var isNumeric: Bool {
        switch forced {
        case .int, .double: return true
        default: return false
        }
    }

    /// 値型の言語で代入するときに使う深いコピー。
    func deepCopy() -> MLValue {
        switch self {
        case .array(let value): return .array(value.copy())
        case .map(let value): return .map(value.copy())
        case .tuple(let items): return .tuple(items.map { $0.deepCopy() })
        case .object(let value): return .object(value.copy())
        default: return self
        }
    }

    /// 型を表す短い名前 (エラーメッセージ用。言語ごとの正式名は `MLSemantics` が出す)。
    var kindName: String {
        switch forced {
        case .unit: return "nil"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .char: return "char"
        case .string: return "string"
        case .array: return "array"
        case .map: return "map"
        case .tuple: return "tuple"
        case .object(let object): return object.typeName
        case .function: return "function"
        case .range: return "range"
        case .symbol: return "symbol"
        case .thunk: return "thunk"
        }
    }
}
