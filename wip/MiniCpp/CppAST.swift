import Foundation

/// 型注釈。実行時の型チェックはせず、`auto` の解決や既定値づくりに使う程度。
indirect enum CppType: Equatable {
    case int, double, bool_, char_, string, void
    case named(String)
    case vector(CppType)
    case map(CppType, CppType)
    case reference(CppType)
    case auto_
}

struct CppParameter {
    var type: CppType
    var name: String
    var isReference: Bool
    var defaultValue: CppExpr?
}

final class CppFunctionDecl {
    let name: String
    let returnType: CppType
    let parameters: [CppParameter]
    let body: [CppStmt]
    let location: SourceLocation
    init(name: String, returnType: CppType, parameters: [CppParameter], body: [CppStmt], location: SourceLocation) {
        self.name = name
        self.returnType = returnType
        self.parameters = parameters
        self.body = body
        self.location = location
    }
}

struct CppFieldDecl {
    var type: CppType
    var name: String
    var defaultValue: CppExpr?
}

final class CppClassDecl {
    let name: String
    let parentName: String?
    let fields: [CppFieldDecl]
    let methods: [String: CppFunctionDecl]
    /// 複数コンストラクタを引数の個数で区別する (簡易オーバーロード)。
    let constructors: [CppFunctionDecl]
    let location: SourceLocation
    init(name: String, parentName: String?, fields: [CppFieldDecl],
         methods: [String: CppFunctionDecl], constructors: [CppFunctionDecl], location: SourceLocation) {
        self.name = name
        self.parentName = parentName
        self.fields = fields
        self.methods = methods
        self.constructors = constructors
        self.location = location
    }
}

indirect enum CppExpr {
    case intLiteral(Int, SourceLocation)
    case doubleLiteral(Double, SourceLocation)
    case boolLiteral(Bool, SourceLocation)
    case stringLiteral(String, SourceLocation)
    case charLiteral(Character, SourceLocation)
    case identifier(String, SourceLocation)
    case thisExpr(SourceLocation)
    case unary(String, CppExpr, SourceLocation)
    case postfix(String, CppExpr, SourceLocation)
    case binary(String, CppExpr, CppExpr, SourceLocation)
    case logical(String, CppExpr, CppExpr, SourceLocation)
    case assign(String, CppExpr, CppExpr, SourceLocation)
    case ternary(CppExpr, CppExpr, CppExpr, SourceLocation)
    case call(String, [CppExpr], SourceLocation)
    case memberCall(CppExpr, String, [CppExpr], SourceLocation)
    case member(CppExpr, String, SourceLocation)
    case index(CppExpr, CppExpr, SourceLocation)
    case newObject(String, [CppExpr], SourceLocation)
    case initList([CppExpr], SourceLocation)

    var location: SourceLocation {
        switch self {
        case .intLiteral(_, let l), .doubleLiteral(_, let l), .boolLiteral(_, let l),
             .stringLiteral(_, let l), .charLiteral(_, let l), .identifier(_, let l),
             .thisExpr(let l), .unary(_, _, let l), .postfix(_, _, let l),
             .binary(_, _, _, let l), .logical(_, _, _, let l), .assign(_, _, _, let l),
             .ternary(_, _, _, let l), .call(_, _, let l), .memberCall(_, _, _, let l),
             .member(_, _, let l), .index(_, _, let l), .newObject(_, _, let l),
             .initList(_, let l):
            return l
        }
    }
}

indirect enum CppStmt {
    case expression(CppExpr, SourceLocation)
    case varDecl(type: CppType, names: [(String, CppExpr?)], SourceLocation)
    case ifStmt(CppExpr, [CppStmt], [CppStmt]?, SourceLocation)
    case whileStmt(CppExpr, [CppStmt], SourceLocation)
    case doWhile([CppStmt], CppExpr, SourceLocation)
    case forStmt(CppStmt?, CppExpr?, CppExpr?, [CppStmt], SourceLocation)
    /// `for (auto x : container)` / `for (auto& x : container)`
    case forRange(type: CppType, name: String, byReference: Bool, subject: CppExpr, body: [CppStmt], SourceLocation)
    case switchStmt(CppExpr, [(values: [CppExpr]?, body: [CppStmt])], SourceLocation)
    case breakStmt(SourceLocation)
    case continueStmt(SourceLocation)
    case returnStmt(CppExpr?, SourceLocation)
    case block([CppStmt], SourceLocation)
    case functionDecl(CppFunctionDecl)
    case classDecl(CppClassDecl)
}
