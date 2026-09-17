import Foundation

/// 各言語のパーサが吐く共通の構文木。
///
/// 言語ごとに書き方は違っても「やっていること」はかなり重なるので、
/// 構文解析だけ言語ごとに書き、評価器は 1 つを共有する。

// MARK: - 式

public indirect enum MLExpr {
    case literal(MLValue, SourceLocation)
    /// 変数・関数などの名前。
    case name(String, SourceLocation)
    /// `self` / `this` / `me`
    case selfRef(SourceLocation)
    /// `super`
    case superRef(SourceLocation)
    /// 配列リテラル。`spreadIndices` に入っている位置は展開する (`[...a, b]`)。
    case listLiteral([MLExpr], spreadIndices: Set<Int>, SourceLocation)
    /// 辞書リテラル。
    case mapLiteral([(key: MLExpr, value: MLExpr)], SourceLocation)
    /// タプル / 位置引数の組。
    case tupleLiteral([MLExpr], SourceLocation)
    /// 文字列補間。`parts` の各要素を文字列化して連結する。
    case interpolation([MLExpr], SourceLocation)
    /// `a.b` / `a?.b` / `a->b`
    case member(MLExpr, String, isOptional: Bool, SourceLocation)
    /// `a[i]` / `a[i:j]` (`upper` があればスライス)
    case subscriptExpr(MLExpr, index: MLExpr, upper: MLExpr?, SourceLocation)
    case call(callee: MLExpr, arguments: [MLArgument], SourceLocation)
    /// `new Foo(...)` のように「必ず生成」と分かる形。
    case construct(typeName: String, arguments: [MLArgument], SourceLocation)
    case unary(op: String, operand: MLExpr, isPostfix: Bool, SourceLocation)
    case binary(op: String, lhs: MLExpr, rhs: MLExpr, SourceLocation)
    /// `a = b` / `a += b`。`op` は `"="` か複合代入の記号。
    case assign(op: String, target: MLExpr, value: MLExpr, SourceLocation)
    case ternary(condition: MLExpr, then: MLExpr, otherwise: MLExpr, SourceLocation)
    case lambda(MLFunctionDecl, SourceLocation)
    case range(lower: MLExpr?, upper: MLExpr?, isClosed: Bool, step: MLExpr?, SourceLocation)
    /// `x as T` / `(T)x`。`isOptional` は `as?`。
    case cast(MLExpr, typeName: String, isOptional: Bool, SourceLocation)
    /// `x is T` / `x instanceof T`
    case typeTest(MLExpr, typeName: String, SourceLocation)
    /// `x!` (強制アンラップ)
    case forceUnwrap(MLExpr, SourceLocation)
    /// `.someCase` のように型が文脈で決まるメンバー。
    case implicitMember(String, SourceLocation)
    /// 内包表記 `[f(x) for x in xs if p(x)]`
    case comprehension(MLComprehension, SourceLocation)
    /// 式としての `match` / `case` / `switch`。
    case match(subject: MLExpr, arms: [MLMatchArm], SourceLocation)
    /// 式としてのブロック (最後の式が値になる)。
    case block([MLStmt], SourceLocation)
    /// 式としての `if`。
    case ifExpr(condition: MLExpr, then: MLExpr, otherwise: MLExpr?, SourceLocation)
    /// 遅延評価したい式 (Haskell の引数など)。
    case lazy(MLExpr, SourceLocation)
    /// 参照を作る (`\@a`, `&x`)。
    case reference(MLExpr, SourceLocation)
    /// 参照をたどる (`$$ref`, `*p`)。
    case dereference(MLExpr, SourceLocation)
    /// 未初期化の既定値 (`var x: Int` のように値を書かない宣言用)。
    case defaultValue(typeName: String?, SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .literal(_, let l), .name(_, let l), .selfRef(let l), .superRef(let l),
             .listLiteral(_, _, let l), .mapLiteral(_, let l), .tupleLiteral(_, let l),
             .interpolation(_, let l), .member(_, _, _, let l), .subscriptExpr(_, _, _, let l),
             .call(_, _, let l), .construct(_, _, let l), .unary(_, _, _, let l),
             .binary(_, _, _, let l), .assign(_, _, _, let l), .ternary(_, _, _, let l),
             .lambda(_, let l), .range(_, _, _, _, let l), .cast(_, _, _, let l),
             .typeTest(_, _, let l), .forceUnwrap(_, let l), .implicitMember(_, let l),
             .comprehension(_, let l), .match(_, _, let l), .block(_, let l),
             .ifExpr(_, _, _, let l), .lazy(_, let l), .reference(_, let l),
             .dereference(_, let l), .defaultValue(_, let l):
            return l
        }
    }
}

/// 呼び出しの引数。ラベル付き・名前付き・可変長展開に対応する。
public struct MLArgument {
    public var label: String?
    public var value: MLExpr
    /// `f(*args)` / `f(...args)` のような展開。
    public var isSpread: Bool

    public init(label: String? = nil, value: MLExpr, isSpread: Bool = false) {
        self.label = label
        self.value = value
        self.isSpread = isSpread
    }
}

/// 内包表記 1 つぶん。
public struct MLComprehension {
    public struct Clause {
        public var pattern: MLPattern
        public var sequence: MLExpr
        public init(pattern: MLPattern, sequence: MLExpr) {
            self.pattern = pattern
            self.sequence = sequence
        }
    }

    public enum Shape {
        case list
        case map
        case set
    }

    public var shape: Shape
    /// 各要素を作る式 (map のときは value 側)。
    public var element: MLExpr
    /// map のときのキー。
    public var keyElement: MLExpr?
    public var clauses: [Clause]
    public var filters: [MLExpr]

    public init(shape: Shape = .list, element: MLExpr, keyElement: MLExpr? = nil,
                clauses: [Clause], filters: [MLExpr]) {
        self.shape = shape
        self.element = element
        self.keyElement = keyElement
        self.clauses = clauses
        self.filters = filters
    }
}

// MARK: - パターン

public indirect enum MLPattern {
    /// `_`
    case wildcard
    /// 名前に束縛する。
    case binding(String)
    /// リテラルとの一致。
    case literal(MLValue)
    /// 式を評価した結果との一致 (定数名など)。
    case expression(MLExpr)
    /// `(a, b)` / `{a, b}`
    case tuple([MLPattern])
    /// `[a, b, ...rest]`。`restIndex` に残り全部を受ける位置。
    case list([MLPattern], restIndex: Int?, restName: String?)
    /// `Some(x)` / `Cons(h, t)` / `:ok` / `Point{x: a}`
    case constructor(name: String, positional: [MLPattern], named: [(String, MLPattern)])
    /// `%{a: x}` のような辞書パターン。
    case map([(key: MLExpr, value: MLPattern)])
    /// `x: Int` / `case let n as Int`
    case typed(MLPattern, typeName: String)
    /// `a | b`
    case or([MLPattern])
    /// `x @ pattern` (全体にも名前を付ける)
    case named(String, MLPattern)
    /// 範囲パターン `1...5`
    case range(lower: MLExpr, upper: MLExpr, isClosed: Bool)
    /// Haskell の `(x:xs)` のような「先頭と残り」。
    case cons(head: MLPattern, tail: MLPattern)

    /// このパターンが束縛する名前を集める。
    public var boundNames: [String] {
        switch self {
        case .wildcard, .literal, .expression, .range: return []
        case .binding(let name): return [name]
        case .tuple(let items): return items.flatMap { $0.boundNames }
        case .list(let items, _, let restName):
            return items.flatMap { $0.boundNames } + (restName.map { [$0] } ?? [])
        case .constructor(_, let positional, let named):
            return positional.flatMap { $0.boundNames } + named.flatMap { $0.1.boundNames }
        case .map(let pairs): return pairs.flatMap { $0.value.boundNames }
        case .typed(let inner, _): return inner.boundNames
        case .or(let options): return options.first?.boundNames ?? []
        case .named(let name, let inner): return [name] + inner.boundNames
        case .cons(let head, let tail): return head.boundNames + tail.boundNames
        }
    }
}

/// `match` / `switch` の 1 本の腕。
public struct MLMatchArm {
    public var patterns: [MLPattern]
    public var guardCondition: MLExpr?
    public var body: [MLStmt]
    /// C 系の `switch` のように次の腕へ流れるか。
    public var fallsThrough: Bool
    public var isDefault: Bool

    public init(patterns: [MLPattern], guardCondition: MLExpr? = nil, body: [MLStmt],
                fallsThrough: Bool = false, isDefault: Bool = false) {
        self.patterns = patterns
        self.guardCondition = guardCondition
        self.body = body
        self.fallsThrough = fallsThrough
        self.isDefault = isDefault
    }
}

// MARK: - 文

public indirect enum MLStmt {
    case expression(MLExpr, SourceLocation)
    /// 変数宣言。`isConstant` は再代入禁止。
    case varDecl(pattern: MLPattern, typeName: String?, value: MLExpr?,
                 isConstant: Bool, SourceLocation)
    case ifStmt(condition: MLExpr, then: [MLStmt], otherwise: [MLStmt]?, SourceLocation)
    case whileStmt(condition: MLExpr, body: [MLStmt], label: String?, SourceLocation)
    /// `do { } while ()` / `repeat { } until ()`
    case doWhile(body: [MLStmt], condition: MLExpr, isUntil: Bool, label: String?, SourceLocation)
    /// `for (init; cond; step)`
    case forClassic(initializer: [MLStmt], condition: MLExpr?, step: [MLStmt],
                    body: [MLStmt], label: String?, SourceLocation)
    /// `for x in xs`
    case forIn(pattern: MLPattern, sequence: MLExpr, body: [MLStmt],
               whereClause: MLExpr?, label: String?, SourceLocation)
    case matchStmt(subject: MLExpr, arms: [MLMatchArm], label: String?, SourceLocation)
    case breakStmt(label: String?, SourceLocation)
    case continueStmt(label: String?, SourceLocation)
    case returnStmt(MLExpr?, SourceLocation)
    case throwStmt(MLExpr, SourceLocation)
    /// `try { } catch (E e) { } finally { }`
    case tryStmt(body: [MLStmt], catches: [MLCatchClause], finallyBody: [MLStmt]?, SourceLocation)
    case funcDecl(MLFunctionDecl)
    case typeDecl(MLTypeDecl)
    case block([MLStmt], SourceLocation)
    /// `guard cond else { ... }` (条件が偽なら else を実行して抜ける)
    case guardStmt(condition: MLExpr, elseBody: [MLStmt], SourceLocation)
    /// import / package / use など、実行に影響しない宣言。
    case noop(SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .expression(_, let l), .varDecl(_, _, _, _, let l), .ifStmt(_, _, _, let l),
             .whileStmt(_, _, _, let l), .doWhile(_, _, _, _, let l),
             .forClassic(_, _, _, _, _, let l), .forIn(_, _, _, _, _, let l),
             .matchStmt(_, _, _, let l), .breakStmt(_, let l), .continueStmt(_, let l),
             .returnStmt(_, let l), .throwStmt(_, let l), .tryStmt(_, _, _, let l),
             .block(_, let l), .guardStmt(_, _, let l), .noop(let l):
            return l
        case .funcDecl(let decl): return decl.location
        case .typeDecl(let decl): return decl.location
        }
    }
}

public struct MLCatchClause {
    /// 捕まえる型名 (nil ならなんでも)。
    public var typeName: String?
    /// 例外を受ける変数名。
    public var binding: String?
    /// 型名の代わりにパターンで受ける言語 (OCaml など) 用。
    public var pattern: MLPattern?
    public var guardCondition: MLExpr?
    public var body: [MLStmt]

    public init(typeName: String? = nil, binding: String? = nil, pattern: MLPattern? = nil,
                guardCondition: MLExpr? = nil, body: [MLStmt]) {
        self.typeName = typeName
        self.binding = binding
        self.pattern = pattern
        self.guardCondition = guardCondition
        self.body = body
    }
}

// MARK: - 宣言

public struct MLParameter {
    /// 呼び出し側のラベル (Swift の `for value: Int` の `for`)。
    public var label: String?
    public var name: String
    public var typeName: String?
    public var defaultValue: MLExpr?
    public var isVariadic: Bool
    /// `inout` / `&$x` / `ref` のように呼び出し元の変数を書き換える。
    public var isByReference: Bool
    /// パターンで受け取る引数 (関数節ごとに違うパターンを持つ言語用)。
    public var pattern: MLPattern?

    public init(label: String? = nil, name: String, typeName: String? = nil,
                defaultValue: MLExpr? = nil, isVariadic: Bool = false,
                isByReference: Bool = false, pattern: MLPattern? = nil) {
        self.label = label
        self.name = name
        self.typeName = typeName
        self.defaultValue = defaultValue
        self.isVariadic = isVariadic
        self.isByReference = isByReference
        self.pattern = pattern
    }
}

/// 関数 1 節ぶん。Haskell / Erlang のように同じ名前で複数の節を書く言語では
/// `MLFunctionDecl.clauses` に複数入る。
public struct MLFunctionClause {
    public var parameters: [MLParameter]
    public var guardCondition: MLExpr?
    public var body: [MLStmt]

    public init(parameters: [MLParameter], guardCondition: MLExpr? = nil, body: [MLStmt]) {
        self.parameters = parameters
        self.guardCondition = guardCondition
        self.body = body
    }
}

public final class MLFunctionDecl {
    public let name: String
    public var clauses: [MLFunctionClause]
    public let returnTypeName: String?
    public let isStatic: Bool
    public let isInitializer: Bool
    /// 構造体の値を書き換えるメソッド (Swift の `mutating`)。
    public let isMutating: Bool
    /// 本体を持たない宣言 (インタフェース・抽象メソッド)。
    public let isAbstract: Bool
    /// `$0` / `it` / `_1` のような暗黙引数を使うクロージャ。
    public let usesImplicitArguments: Bool
    /// 引数が足りないときに部分適用するか (関数型言語のカリー化)。
    public let isCurried: Bool
    public let location: SourceLocation

    public init(name: String, clauses: [MLFunctionClause], returnTypeName: String? = nil,
                isStatic: Bool = false, isInitializer: Bool = false, isMutating: Bool = false,
                isAbstract: Bool = false, usesImplicitArguments: Bool = false,
                isCurried: Bool = false, location: SourceLocation) {
        self.name = name
        self.clauses = clauses
        self.returnTypeName = returnTypeName
        self.isStatic = isStatic
        self.isInitializer = isInitializer
        self.isMutating = isMutating
        self.isAbstract = isAbstract
        self.usesImplicitArguments = usesImplicitArguments
        self.isCurried = isCurried
        self.location = location
    }

    /// 1 節だけの普通の関数を作る近道。
    public convenience init(name: String, parameters: [MLParameter], body: [MLStmt],
                            returnTypeName: String? = nil, isStatic: Bool = false,
                            isInitializer: Bool = false, isMutating: Bool = false,
                            isAbstract: Bool = false,
                            usesImplicitArguments: Bool = false, isCurried: Bool = false,
                            location: SourceLocation) {
        self.init(name: name,
                  clauses: [MLFunctionClause(parameters: parameters, body: body)],
                  returnTypeName: returnTypeName, isStatic: isStatic,
                  isInitializer: isInitializer, isMutating: isMutating,
                  isAbstract: isAbstract,
                  usesImplicitArguments: usesImplicitArguments, isCurried: isCurried,
                  location: location)
    }

    /// 節をまたいだ最大引数個数。
    public var arity: Int { clauses.map { $0.parameters.count }.max() ?? 0 }
}

public struct MLPropertyDecl {
    public var name: String
    public var typeName: String?
    public var defaultValue: MLExpr?
    public var isConstant: Bool
    public var isStatic: Bool
    /// 計算プロパティの取得処理。
    public var getter: [MLStmt]?
    /// 計算プロパティの設定処理 (受け取る名前は `setterParameter`)。
    public var setter: [MLStmt]?
    public var setterParameter: String?

    public init(name: String, typeName: String? = nil, defaultValue: MLExpr? = nil,
                isConstant: Bool = false, isStatic: Bool = false,
                getter: [MLStmt]? = nil, setter: [MLStmt]? = nil,
                setterParameter: String? = nil) {
        self.name = name
        self.typeName = typeName
        self.defaultValue = defaultValue
        self.isConstant = isConstant
        self.isStatic = isStatic
        self.getter = getter
        self.setter = setter
        self.setterParameter = setterParameter
    }
}

/// 列挙 / 代数的データ型の 1 つのケース。
public struct MLCaseDecl {
    public var name: String
    /// 位置引数の型名 (`Some(Int)`)。
    public var associatedTypes: [String]
    /// 名前つきフィールド (`Point { x: Int }`)。
    public var associatedNames: [String]
    /// `case A = 1` のような生の値。
    public var rawValue: MLExpr?

    public init(name: String, associatedTypes: [String] = [], associatedNames: [String] = [],
                rawValue: MLExpr? = nil) {
        self.name = name
        self.associatedTypes = associatedTypes
        self.associatedNames = associatedNames
        self.rawValue = rawValue
    }
}

public final class MLTypeDecl {
    public enum Kind {
        /// 参照型 (class / object)
        case classType
        /// 値型 (struct / record)
        case structType
        /// 列挙・代数的データ型
        case enumType
        /// インタフェース / trait / protocol
        case interfaceType
        /// モジュール / 名前空間 (Elixir の defmodule など)
        case moduleType
    }

    public let kind: Kind
    public let name: String
    /// 親クラス。
    public let superclassName: String?
    /// 実装しているインタフェース。
    public let interfaceNames: [String]
    public let properties: [MLPropertyDecl]
    public let methods: [MLFunctionDecl]
    public let initializers: [MLFunctionDecl]
    public let cases: [MLCaseDecl]
    /// 入れ子の型。
    public let nestedTypes: [MLTypeDecl]
    /// クラス本体に直接書かれた初期化処理 (Scala/Kotlin の本体式など)。
    public let bodyStatements: [MLStmt]
    /// 主コンストラクタの引数 (Kotlin / Scala)。
    public let primaryParameters: [MLParameter]
    public let isAbstract: Bool
    public let location: SourceLocation

    public init(kind: Kind, name: String, superclassName: String? = nil,
                interfaceNames: [String] = [], properties: [MLPropertyDecl] = [],
                methods: [MLFunctionDecl] = [], initializers: [MLFunctionDecl] = [],
                cases: [MLCaseDecl] = [], nestedTypes: [MLTypeDecl] = [],
                bodyStatements: [MLStmt] = [], primaryParameters: [MLParameter] = [],
                isAbstract: Bool = false, location: SourceLocation) {
        self.kind = kind
        self.name = name
        self.superclassName = superclassName
        self.interfaceNames = interfaceNames
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.cases = cases
        self.nestedTypes = nestedTypes
        self.bodyStatements = bodyStatements
        self.primaryParameters = primaryParameters
        self.isAbstract = isAbstract
        self.location = location
    }
}

/// 解析結果のプログラム全体。
public struct MLProgram {
    public var statements: [MLStmt]
    /// `main` に相当する開始点の名前 (無ければトップレベルを順に実行)。
    public var entryPoint: String?
    /// 開始点が属する型名 (Java の `Main` クラスなど)。
    public var entryTypeName: String?

    public init(statements: [MLStmt], entryPoint: String? = nil, entryTypeName: String? = nil) {
        self.statements = statements
        self.entryPoint = entryPoint
        self.entryTypeName = entryTypeName
    }
}
