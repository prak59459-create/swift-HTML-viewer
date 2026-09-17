import Foundation

// MARK: - エラーと制御の流れ

public enum MLError: Error {
    /// 実行時エラー。
    case runtime(String)
    /// 実行上限に達した (無限ループなど)。
    case limitExceeded(String)
    /// プログラムが投げた例外。
    case thrown(MLValue)
    /// `exit(n)`
    case exit(Int32)

    public var message: String {
        switch self {
        case .runtime(let text): return text
        case .limitExceeded(let text): return text
        case .thrown(let value): return "捕まえられていない例外: \(MLDisplay.plain(value))"
        case .exit(let code): return "exit(\(code))"
        }
    }
}

/// 評価器の中だけで使う「途中で抜ける」合図。
enum MLControl: Error {
    case breakLoop(label: String?)
    case continueLoop(label: String?)
    case returnValue(MLValue)
    /// C 系 switch の fallthrough。
    case fallThrough
}

// MARK: - 環境 (変数のしまい場所)

/// 変数 1 つぶんの入れ物。参照渡しや上位変数の書き換えのために箱にしてある。
open class MLBox {
    open var value: MLValue
    public let isConstant: Bool
    public let declaredTypeName: String?

    public init(_ value: MLValue, isConstant: Bool = false, declaredTypeName: String? = nil) {
        self.value = value
        self.isConstant = isConstant
        self.declaredTypeName = declaredTypeName
    }
}

public final class MLEnvironment {
    private var storage: [String: MLBox] = [:]
    public let parent: MLEnvironment?
    /// 関数の本体かどうか (ここより外側をたどらない言語の探索に使う)。
    public let isFunctionScope: Bool

    public init(parent: MLEnvironment? = nil, isFunctionScope: Bool = false) {
        self.parent = parent
        self.isFunctionScope = isFunctionScope
    }

    public func lookup(_ name: String) -> MLBox? {
        var scope: MLEnvironment? = self
        while let current = scope {
            if let box = current.storage[name] { return box }
            scope = current.parent
        }
        return nil
    }

    /// 現在のスコープだけを見る。
    public func lookupLocal(_ name: String) -> MLBox? { storage[name] }

    /// 新しい変数をこのスコープに作る。
    @discardableResult
    public func define(_ name: String, _ value: MLValue,
                       isConstant: Bool = false, typeName: String? = nil) -> MLBox {
        let box = MLBox(value, isConstant: isConstant, declaredTypeName: typeName)
        storage[name] = box
        return box
    }

    public func defineBox(_ name: String, _ box: MLBox) {
        storage[name] = box
    }

    public func remove(_ name: String) {
        storage.removeValue(forKey: name)
    }

    /// 既存の変数を書き換える。見つからなければ false。
    public func assign(_ name: String, _ value: MLValue) throws -> Bool {
        guard let box = lookup(name) else { return false }
        if box.isConstant {
            throw MLError.runtime("定数 \(name) には代入できません")
        }
        box.value = value
        return true
    }

    public var localNames: [String] { Array(storage.keys) }

    /// 関数スコープの直近の入れ物 (関数内の静的変数などに使う)。
    public var functionScope: MLEnvironment {
        var scope: MLEnvironment = self
        while !scope.isFunctionScope, let parent = scope.parent { scope = parent }
        return scope
    }
}

// MARK: - 関数の値

public final class MLFunction {
    public enum Body {
        /// 言語で書かれた関数。
        case declared(MLFunctionDecl)
        /// Swift で書いた組み込み関数。
        case native(name: String, arity: ClosedRange<Int>, impl: MLNativeImpl)
    }

    public typealias MLNativeImpl = (MLCallContext) throws -> MLValue

    public let body: Body
    /// 定義されたときの環境 (クロージャ)。
    public let closure: MLEnvironment?
    /// メソッドのときの受け手。
    public var boundSelf: MLValue?
    /// メソッドが定義されているクラス (`super` の解決に使う)。
    public var owner: MLClass?
    /// カリー化で先に受け取った引数。
    public var partialArguments: [MLValue]

    public init(body: Body, closure: MLEnvironment?, boundSelf: MLValue? = nil,
                owner: MLClass? = nil, partialArguments: [MLValue] = []) {
        self.body = body
        self.closure = closure
        self.boundSelf = boundSelf
        self.owner = owner
        self.partialArguments = partialArguments
    }

    public static func native(_ name: String, _ arity: ClosedRange<Int>,
                              _ impl: @escaping MLNativeImpl) -> MLFunction {
        MLFunction(body: .native(name: name, arity: arity, impl: impl), closure: nil)
    }

    public static func native(_ name: String, _ arity: Int,
                              _ impl: @escaping MLNativeImpl) -> MLFunction {
        .native(name, arity...arity, impl)
    }

    public var name: String {
        switch body {
        case .declared(let decl): return decl.name
        case .native(let name, _, _): return name
        }
    }

    public var declaredArity: Int {
        switch body {
        case .declared(let decl): return decl.arity
        case .native(_, let arity, _): return arity.lowerBound
        }
    }

    /// Swift で書いた組み込み関数か。
    public var isNative: Bool {
        if case .native = body { return true }
        return false
    }

    /// `self` を束ねた複製を返す。
    public func bound(to receiver: MLValue, owner: MLClass?) -> MLFunction {
        MLFunction(body: body, closure: closure, boundSelf: receiver,
                   owner: owner ?? self.owner, partialArguments: partialArguments)
    }

    public func applying(_ arguments: [MLValue]) -> MLFunction {
        MLFunction(body: body, closure: closure, boundSelf: boundSelf, owner: owner,
                   partialArguments: partialArguments + arguments)
    }
}

/// 組み込み関数に渡す情報。
public struct MLCallContext {
    public var arguments: [MLValue]
    /// ラベル付き引数 (`f(to: 3)`)。
    public var labels: [String?]
    /// 参照渡しのための箱 (取れなかった引数は nil)。
    public var boxes: [MLBox?]
    public var receiver: MLValue?
    public unowned var interpreter: MLInterpreter
    public var location: SourceLocation

    public init(arguments: [MLValue], labels: [String?] = [], boxes: [MLBox?] = [],
                receiver: MLValue? = nil, interpreter: MLInterpreter,
                location: SourceLocation = SourceLocation(line: 0, column: 0)) {
        self.arguments = arguments
        self.labels = labels.isEmpty ? Array(repeating: nil, count: arguments.count) : labels
        self.boxes = boxes.isEmpty ? Array(repeating: nil, count: arguments.count) : boxes
        self.receiver = receiver
        self.interpreter = interpreter
        self.location = location
    }

    public func argument(_ index: Int) -> MLValue {
        index < arguments.count ? arguments[index].forced : .unit
    }

    public func optionalArgument(_ index: Int) -> MLValue? {
        index < arguments.count ? arguments[index].forced : nil
    }

    /// ラベル名で引数を探す。
    public func argument(labeled label: String) -> MLValue? {
        for (index, name) in labels.enumerated() where name == label {
            return index < arguments.count ? arguments[index].forced : nil
        }
        return nil
    }

    public func requireString(_ index: Int, _ function: String) throws -> String {
        guard let text = argument(index).asString else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は文字列である必要があります")
        }
        return text
    }

    public func requireInt(_ index: Int, _ function: String) throws -> Int64 {
        guard let value = argument(index).asInt else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は整数である必要があります")
        }
        return value
    }

    public func requireDouble(_ index: Int, _ function: String) throws -> Double {
        guard let value = argument(index).asDouble else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は数値である必要があります")
        }
        return value
    }

    public func requireArray(_ index: Int, _ function: String) throws -> MLArray {
        guard let value = argument(index).asArray else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は配列である必要があります")
        }
        return value
    }

    public func requireMap(_ index: Int, _ function: String) throws -> MLMap {
        guard let value = argument(index).asMap else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は辞書である必要があります")
        }
        return value
    }

    public func requireFunction(_ index: Int, _ function: String) throws -> MLFunction {
        guard let value = argument(index).asFunction else {
            throw MLError.runtime("\(function): \(index + 1) 番目の引数は関数である必要があります")
        }
        return value
    }

    /// 組み込みから言語側の関数を呼ぶ。
    public func call(_ function: MLValue, _ arguments: [MLValue]) throws -> MLValue {
        try interpreter.callValue(function, arguments: arguments, location: location)
    }
}

// MARK: - クラス

public final class MLClass {
    public let name: String
    public let kind: MLTypeDecl.Kind
    public var superclass: MLClass?
    public var interfaceNames: [String] = []
    /// 解決済みのインタフェース (既定実装のメソッドを引き継ぐ)。
    public var interfaces: [MLClass] = []
    /// インスタンスメソッド (名前 → 関数)。同名多重定義は配列で持つ。
    public var methods: [String: [MLFunctionDecl]] = [:]
    public var staticMethods: [String: [MLFunctionDecl]] = [:]
    public var initializers: [MLFunctionDecl] = []
    public var properties: [MLPropertyDecl] = []
    public var staticStorage = MLEnvironment()
    /// 列挙のケース定義。
    public var cases: [String: MLCaseDecl] = [:]
    public var caseOrder: [String] = []
    /// 主コンストラクタ引数。
    public var primaryParameters: [MLParameter] = []
    public var bodyStatements: [MLStmt] = []
    /// 定義時の環境。
    public var declarationEnvironment: MLEnvironment?
    public var isAbstract: Bool = false
    /// Swift で書いた組み込みクラス (例外型など) の目印。
    public var isBuiltin: Bool = false

    public init(name: String, kind: MLTypeDecl.Kind) {
        self.name = name
        self.kind = kind
    }

    /// 自分と祖先からメソッドを探す。見つからなければインタフェースの既定実装も見る。
    public func findMethod(_ name: String) -> (decls: [MLFunctionDecl], owner: MLClass)? {
        var current: MLClass? = self
        while let klass = current {
            if let decls = klass.methods[name], !decls.isEmpty, !decls[0].isAbstract {
                return (decls, klass)
            }
            current = klass.superclass
        }
        // インタフェースの既定実装 (Java の default メソッドなど)。
        var visited = Set<ObjectIdentifier>()
        func search(_ klass: MLClass) -> (decls: [MLFunctionDecl], owner: MLClass)? {
            guard visited.insert(ObjectIdentifier(klass)).inserted else { return nil }
            for interface in klass.interfaces {
                if let decls = interface.methods[name], !decls.isEmpty, !decls[0].isAbstract {
                    return (decls, interface)
                }
                if let found = search(interface) { return found }
            }
            if let superclass = klass.superclass { return search(superclass) }
            return nil
        }
        if let found = search(self) { return found }
        // 抽象宣言しか無い場合はそれを返す (エラーメッセージのため)。
        current = self
        while let klass = current {
            if let decls = klass.methods[name], !decls.isEmpty { return (decls, klass) }
            current = klass.superclass
        }
        return nil
    }

    public func findStaticMethod(_ name: String) -> (decls: [MLFunctionDecl], owner: MLClass)? {
        var current: MLClass? = self
        while let klass = current {
            if let decls = klass.staticMethods[name], !decls.isEmpty { return (decls, klass) }
            current = klass.superclass
        }
        return nil
    }

    public func findProperty(_ name: String) -> (MLPropertyDecl, MLClass)? {
        var current: MLClass? = self
        while let klass = current {
            if let property = klass.properties.first(where: { $0.name == name }) {
                return (property, klass)
            }
            current = klass.superclass
        }
        return nil
    }

    public func findStaticBox(_ name: String) -> MLBox? {
        var current: MLClass? = self
        while let klass = current {
            if let box = klass.staticStorage.lookupLocal(name) { return box }
            current = klass.superclass
        }
        return nil
    }

    /// 自分または祖先・インタフェースが `name` かどうか。
    public func conforms(to name: String) -> Bool {
        var current: MLClass? = self
        while let klass = current {
            if klass.name == name { return true }
            if klass.interfaceNames.contains(name) { return true }
            for interface in klass.interfaces where interface.conforms(to: name) {
                return true
            }
            current = klass.superclass
        }
        return false
    }

    /// 継承順に並べた祖先 (自分を含む)。
    public var lineage: [MLClass] {
        var result: [MLClass] = []
        var current: MLClass? = self
        while let klass = current {
            result.append(klass)
            current = klass.superclass
        }
        return result
    }
}
