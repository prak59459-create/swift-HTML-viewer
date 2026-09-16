import Foundation

// MARK: - 型注釈 (最低限。実行時は動的型なので主に make/var の初期値決定に使う)

public indirect enum GoTypeRef: Equatable {
    case named(String)              // int, float64, string, bool, byte, rune, error, ユーザ定義
    case slice(GoTypeRef)           // []T
    case array(Int, GoTypeRef)      // [N]T
    case map(GoTypeRef, GoTypeRef)  // map[K]V
    case pointer(GoTypeRef)         // *T
    case unknown
}

// MARK: - 式

public indirect enum GoExpr {
    case intLiteral(Int)
    case doubleLiteral(Double)
    case stringLiteral(String)
    case boolLiteral(Bool)
    case nilLiteral
    case identifier(String, SourceLocation)
    case unary(String, GoExpr, SourceLocation)
    case binary(String, GoExpr, GoExpr, SourceLocation)
    case call(GoExpr, [GoExpr], SourceLocation)
    case index(GoExpr, GoExpr, SourceLocation)
    case sliceExpr(GoExpr, GoExpr?, GoExpr?, SourceLocation)
    case selector(GoExpr, String, SourceLocation)
    case compositeLiteral(GoTypeRef, [(String?, GoExpr)], SourceLocation)
    case sliceLiteral(GoTypeRef, [GoExpr], SourceLocation)
    case mapLiteral(GoTypeRef, GoTypeRef, [(GoExpr, GoExpr)], SourceLocation)
    case functionLiteral(GoFunctionSignature, [GoStmt], SourceLocation)
    case addressOf(GoExpr, SourceLocation)
    case deref(GoExpr, SourceLocation)
    case typeConversion(GoTypeRef, GoExpr, SourceLocation)
}

// MARK: - 文

public struct GoParam: Equatable {
    public var name: String
    public var type: GoTypeRef
}

public struct GoFunctionSignature {
    public var params: [GoParam]
    public var results: [GoParam] // 名前付き戻り値。名前なしは name == ""
}

public indirect enum GoStmt {
    case exprStmt(GoExpr)
    case varDecl(names: [String], type: GoTypeRef, values: [GoExpr], location: SourceLocation)
    case constDecl(names: [String], type: GoTypeRef, values: [GoExpr], location: SourceLocation)
    case shortVarDecl(names: [String], values: [GoExpr], location: SourceLocation)
    case assign(op: String, targets: [GoExpr], values: [GoExpr], location: SourceLocation)
    case incDec(target: GoExpr, op: String, location: SourceLocation)
    case block([GoStmt])
    case ifStmt(initStmt: GoStmt?, cond: GoExpr, then: [GoStmt], elseStmt: GoStmt?)
    case forClassic(initStmt: GoStmt?, cond: GoExpr?, post: GoStmt?, body: [GoStmt])
    case forRange(keyName: String?, valueName: String?, declares: Bool, collection: GoExpr, body: [GoStmt])
    case forInfinite(body: [GoStmt])
    case switchStmt(initStmt: GoStmt?, tag: GoExpr?, cases: [(values: [GoExpr], body: [GoStmt])], defaultBody: [GoStmt]?)
    case funcDecl(GoFunctionDecl)
    case returnStmt([GoExpr], SourceLocation)
    case breakStmt
    case continueStmt
    case typeDecl(name: String, underlying: GoTypeRef, isStruct: Bool, fields: [GoParam])
    case structDecl(name: String, fields: [GoParam])
    case empty
}

public final class GoFunctionDecl {
    public var name: String
    public var receiver: GoParam?
    public var signature: GoFunctionSignature
    public var body: [GoStmt]

    public init(name: String, receiver: GoParam?, signature: GoFunctionSignature, body: [GoStmt]) {
        self.name = name
        self.receiver = receiver
        self.signature = signature
        self.body = body
    }
}
