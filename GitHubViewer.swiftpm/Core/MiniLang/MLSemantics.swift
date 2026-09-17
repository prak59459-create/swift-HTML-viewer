import Foundation

/// 言語ごとの「味付け」。
///
/// 評価器 (`MLInterpreter`) は 1 つを共有し、言語差はここを継承して表現する。
/// 既定の実装は「C 系の素直な言語」を想定している。
open class MLSemantics {
    /// `LanguageCatalog` の言語 ID。
    open var languageID: String { "minilang" }
    open var displayName: String { "内蔵処理系" }

    public init() {}

    // MARK: 値のかたち

    /// 構造体・配列・辞書を代入するときにコピーするか (値型の言語なら true)。
    open var usesValueSemantics: Bool { false }
    /// 配列だけ値型か (Swift / PHP など)。
    open var arraysAreValueTypes: Bool { usesValueSemantics }
    /// 添字の起点 (Julia / R / Lua は 1)。
    open var indexBase: Int { 0 }
    /// `a[-1]` が末尾を指すか。
    open var allowsNegativeIndexing: Bool { false }
    /// `/` が常に小数を返すか (Python3 / Julia / R)。
    open var divisionAlwaysProducesDouble: Bool { false }
    /// 整数割り算を 0 方向に丸めるか (C 系)。false なら負の無限大方向 (Python / Haskell)。
    open var integerDivisionTruncatesTowardZero: Bool { true }
    /// 未初期化の変数を読んだらエラーにするか。
    open var requiresDefinitionBeforeUse: Bool { true }
    /// 関数に足りない引数が来たらカリー化するか。
    open var curriesByDefault: Bool { false }
    /// 添字外アクセスを実行時エラーにするか (false なら nil を返す)。
    open var outOfBoundsIsError: Bool { true }

    // MARK: 真偽値

    /// `if` などで真偽値に変える。
    open func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .unit: return false
        default:
            throw MLError.runtime("条件には真偽値が必要です (\(typeName(of: value)) が渡されました)")
        }
    }

    // MARK: 表示

    /// 型の名前 (エラーメッセージや `typeof` 系で使う)。
    open func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "null"
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

    /// `print` に渡したときの文字列。
    open func display(_ value: MLValue) -> String {
        MLDisplay.plain(value, semantics: self)
    }

    /// デバッグ表示 (文字列に引用符が付くなど)。既定は `display` と同じ。
    open func inspect(_ value: MLValue) -> String {
        display(value)
    }

    /// 小数の既定の書き方。
    open func formatDouble(_ value: Double) -> String {
        MLDisplay.defaultDouble(value)
    }

    /// 文字列補間・文字列連結で値を文字列にするとき。
    open func stringify(_ value: MLValue) -> String {
        display(value)
    }

    // MARK: 演算

    /// 言語独自の二項演算。`nil` を返すと共通処理にまかせる。
    open func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                           interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    /// 言語独自の単項演算。
    open func customUnary(op: String, operand: MLValue,
                          interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    /// 等価判定。既定は型も見る厳密比較。
    open func areEqual(_ lhs: MLValue, _ rhs: MLValue) -> Bool {
        MLOperations.strictEquals(lhs, rhs, semantics: self)
    }

    /// 大小比較。比べられないときは nil。
    open func compare(_ lhs: MLValue, _ rhs: MLValue) -> Int? {
        MLOperations.defaultCompare(lhs, rhs, semantics: self)
    }

    /// 整数同士の割り算。
    open func divideIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        if rhs == 0 { throw MLError.runtime("0 で割ることはできません") }
        if divisionAlwaysProducesDouble { return .double(Double(lhs) / Double(rhs)) }
        if integerDivisionTruncatesTowardZero { return .int(lhs / rhs) }
        return .int(Int64((Double(lhs) / Double(rhs)).rounded(.down)))
    }

    /// 整数の剰余。
    open func moduloIntegers(_ lhs: Int64, _ rhs: Int64) throws -> MLValue {
        if rhs == 0 { throw MLError.runtime("0 で割った余りは求められません") }
        if integerDivisionTruncatesTowardZero { return .int(lhs % rhs) }
        let remainder = lhs % rhs
        return .int(remainder != 0 && (remainder < 0) != (rhs < 0) ? remainder + rhs : remainder)
    }

    /// 整数のあふれ方。既定は 2 の補数で巻き戻す (C 系)。
    open func wrapInteger(_ value: Int64, overflow: Bool) throws -> MLValue {
        .int(value)
    }

    // MARK: メンバー

    /// `obj.method` と書くだけで引数なし呼び出しになる言語 (Ruby / Crystal)。
    open var autoCallsZeroArgumentMembers: Bool { false }

    /// `x.f(y)` を `f(x, y)` と読み替える言語 (Nim / D の UFCS)。
    open var usesUniformFunctionCall: Bool { false }

    /// 引数の型で多重定義を選ぶ言語 (Nim / C++ のオーバーロード)。
    open var selectsOverloadsByParameterType: Bool { false }

    /// 列挙のケースを型名なしでも書ける言語 (Nim / Pascal / C の enum)。
    open var exposesEnumCasesGlobally: Bool { false }

    /// `var P: TPoint;` だけで実体ができる言語 (Pascal のレコードなど)。
    open var defaultInitializesDeclaredTypes: Bool { false }

    /// 実引数が宣言された型に当てはまるか。false を返すとその定義は選ばれない。
    open func value(_ value: MLValue, matchesDeclaredType typeName: String,
                    interpreter: MLInterpreter) -> Bool {
        true
    }

    /// `value.name` の読み出し。`nil` を返すと共通処理にまかせる。
    open func member(of value: MLValue, name: String,
                     interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    /// `value.name(args)` の呼び出し。`nil` を返すと共通処理にまかせる。
    open func callMember(of value: MLValue, name: String, arguments: [MLValue],
                         context: MLCallContext) throws -> MLValue? {
        nil
    }

    /// 型注釈から既定値を作る (`int x;` が 0 になる言語など)。
    open func defaultValue(forTypeName typeName: String?) -> MLValue {
        .unit
    }

    /// 宣言された型にあわせて値を整える (`double x = 1;` を 1.0 にするなど)。
    open func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        value
    }

    // MARK: 組み込み

    /// 大域に組み込み関数・定数を並べる。
    open func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)
    }

    /// プログラムを走らせる前の下ごしらえ (エントリポイントの決定など)。
    open func prepare(program: MLProgram, interpreter: MLInterpreter) throws {}

    /// トップレベルを実行したあとに呼ぶ開始点。
    open func entryPoint(for program: MLProgram) -> (name: String, typeName: String?)? {
        guard let name = program.entryPoint else { return nil }
        return (name, program.entryTypeName)
    }

    /// 実行後の後始末 (バッファの掃き出しなど)。
    open func finish(interpreter: MLInterpreter) {}
}

/// 既定の値表示。
public enum MLDisplay {
    public static func plain(_ value: MLValue, semantics: MLSemantics? = nil) -> String {
        switch value.forced {
        case .unit: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            return semantics?.formatDouble(number) ?? defaultDouble(number)
        case .char(let character): return String(character)
        case .string(let text): return text
        case .array(let array):
            let items = array.elements.map { quoted($0, semantics: semantics) }
            return "[" + items.joined(separator: ", ") + "]"
        case .map(let map):
            let items = map.pairs.map { pair in
                let key = quoted(pair.key.asValue, semantics: semantics)
                return "\(key): \(quoted(pair.value, semantics: semantics))"
            }
            return "{" + items.joined(separator: ", ") + "}"
        case .tuple(let items):
            return "(" + items.map { quoted($0, semantics: semantics) }.joined(separator: ", ") + ")"
        case .object(let object):
            if let caseName = object.caseName {
                if object.payload.isEmpty { return caseName }
                let items = object.payload.map { quoted($0, semantics: semantics) }
                return caseName + "(" + items.joined(separator: ", ") + ")"
            }
            if object.fields.isEmpty { return object.typeName + "()" }
            let items = object.fields.pairs.map { pair in
                let key = pair.key.asValue.asString ?? plain(pair.key.asValue, semantics: semantics)
                return "\(key): \(quoted(pair.value, semantics: semantics))"
            }
            return object.typeName + "(" + items.joined(separator: ", ") + ")"
        case .function(let function): return "<function \(function.name)>"
        case .range(let range):
            return "\(range.lower)\(range.isClosed ? "..." : "..<")\(range.upper)"
        case .symbol(let name): return name
        case .thunk: return "<未評価>"
        }
    }

    /// 入れ子の中で文字列を引用符つきにする。
    static func quoted(_ value: MLValue, semantics: MLSemantics?) -> String {
        if case .string(let text) = value.forced { return "\"\(text)\"" }
        if case .char(let character) = value.forced { return "'\(character)'" }
        return plain(value, semantics: semantics)
    }

    /// 小数の既定表示。整数値でも `.0` を残す (多くの言語がそうする)。
    public static func defaultDouble(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == value.rounded(), abs(value) < 1e16 {
            return String(format: "%.1f", value)
        }
        var text = "\(value)"
        // Swift の既定表示は `1e-05` のような形になることがあるので整える。
        if text.contains("e") {
            text = text.replacingOccurrences(of: "e+0", with: "e+")
                       .replacingOccurrences(of: "e-0", with: "e-")
        }
        return text
    }

    /// 小数を「整数なら整数のように」書く言語 (JavaScript など) 向け。
    public static func compactDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e21 {
            return String(Int64(value))
        }
        return "\(value)"
    }
}
