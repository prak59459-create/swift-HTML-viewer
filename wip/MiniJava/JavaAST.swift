import Foundation

/// 内蔵 Java インタプリタの式ノード。
public indirect enum JavaExpr {
    case intLiteral(Int32, SourceLocation)
    case longLiteral(Int64, SourceLocation)
    case doubleLiteral(Double, SourceLocation)
    case boolLiteral(Bool, SourceLocation)
    case stringLiteral(String, SourceLocation)
    case charLiteral(Character, SourceLocation)
    case nullLiteral(SourceLocation)
    case identifier(String, SourceLocation)
    case thisExpr(SourceLocation)
    case superExpr(SourceLocation)
    case arrayLiteral([JavaExpr], SourceLocation)
    case newArray(elementType: String, sizeExprs: [JavaExpr], initializer: [JavaExpr]?, SourceLocation)
    case newObject(className: String, args: [JavaExpr], SourceLocation)
    /// レシーバが nil ならローカル関数・静的呼び出し。
    case call(receiver: JavaExpr?, name: String, args: [JavaExpr], SourceLocation)
    case member(JavaExpr, String, SourceLocation)
    case index(JavaExpr, JavaExpr, SourceLocation)
    case unary(String, JavaExpr, prefix: Bool, SourceLocation)
    case binary(String, JavaExpr, JavaExpr, SourceLocation)
    case assign(String, JavaExpr, JavaExpr, SourceLocation)
    case ternary(JavaExpr, JavaExpr, JavaExpr, SourceLocation)
    case cast(String, JavaExpr, SourceLocation)
    case instanceOf(JavaExpr, String, SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .intLiteral(_, let l), .longLiteral(_, let l), .doubleLiteral(_, let l),
             .boolLiteral(_, let l), .stringLiteral(_, let l), .charLiteral(_, let l),
             .nullLiteral(let l), .identifier(_, let l), .thisExpr(let l), .superExpr(let l),
             .arrayLiteral(_, let l), .newArray(_, _, _, let l), .newObject(_, _, let l),
             .call(_, _, _, let l), .member(_, _, let l), .index(_, _, let l),
             .unary(_, _, _, let l), .binary(_, _, _, let l), .assign(_, _, _, let l),
             .ternary(_, _, _, let l), .cast(_, _, let l), .instanceOf(_, _, let l):
            return l
        }
    }
}

public struct JavaSwitchCase {
    public var values: [JavaExpr]  // 空なら default
    public var isDefault: Bool
    public var body: [JavaStmt]
}

/// 内蔵 Java インタプリタの文ノード。
public indirect enum JavaStmt {
    case exprStmt(JavaExpr, SourceLocation)
    case varDecl(typeName: String, declarators: [(name: String, value: JavaExpr?)], SourceLocation)
    case block([JavaStmt], SourceLocation)
    case ifStmt(JavaExpr, [JavaStmt], [JavaStmt]?, SourceLocation)
    case whileStmt(JavaExpr, [JavaStmt], SourceLocation)
    case doWhile([JavaStmt], JavaExpr, SourceLocation)
    case forStmt(initStmts: [JavaStmt], cond: JavaExpr?, update: [JavaStmt], body: [JavaStmt], SourceLocation)
    case forEach(typeName: String, name: String, iterable: JavaExpr, body: [JavaStmt], SourceLocation)
    case returnStmt(JavaExpr?, SourceLocation)
    case breakStmt(SourceLocation)
    case continueStmt(SourceLocation)
    case switchStmt(JavaExpr, [JavaSwitchCase], SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .exprStmt(_, let l), .varDecl(_, _, let l), .block(_, let l), .ifStmt(_, _, _, let l),
             .whileStmt(_, _, let l), .doWhile(_, _, let l), .forStmt(_, _, _, _, let l),
             .forEach(_, _, _, _, let l), .returnStmt(_, let l), .breakStmt(let l),
             .continueStmt(let l), .switchStmt(_, _, let l):
            return l
        }
    }
}

public struct JavaFieldDecl {
    public var name: String
    public var typeName: String
    public var isStatic: Bool
    public var initExpr: JavaExpr?
}

public final class JavaMethodDecl {
    public let name: String
    public let params: [(typeName: String, name: String)]
    public let returnType: String
    public let body: [JavaStmt]
    public let isStatic: Bool
    public let location: SourceLocation

    public init(name: String, params: [(typeName: String, name: String)], returnType: String,
                body: [JavaStmt], isStatic: Bool, location: SourceLocation) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isStatic = isStatic
        self.location = location
    }
}

public final class JavaClassDecl {
    public let name: String
    public let superName: String?
    public var fields: [JavaFieldDecl]
    public var methods: [JavaMethodDecl]
    public var constructors: [JavaMethodDecl]
    public let location: SourceLocation

    public init(name: String, superName: String?, fields: [JavaFieldDecl],
                methods: [JavaMethodDecl], constructors: [JavaMethodDecl], location: SourceLocation) {
        self.name = name
        self.superName = superName
        self.fields = fields
        self.methods = methods
        self.constructors = constructors
        self.location = location
    }
}
