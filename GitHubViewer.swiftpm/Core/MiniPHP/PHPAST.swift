import Foundation

/// 関数の引数 1 つ。
public struct PHPParameter {
    public var name: String
    public var defaultValue: PHPExpr?
    public var isVariadic: Bool
    public var byReference: Bool
}

/// 関数・メソッド・クロージャの宣言。クロージャから参照するので class。
public final class PHPFunctionDeclaration: Equatable {
    public let name: String
    public let parameters: [PHPParameter]
    public let body: [PHPStmt]
    public let isStatic: Bool
    public let location: SourceLocation

    public init(name: String, parameters: [PHPParameter], body: [PHPStmt],
                isStatic: Bool = false, location: SourceLocation) {
        self.name = name
        self.parameters = parameters
        self.body = body
        self.isStatic = isStatic
        self.location = location
    }

    public static func == (lhs: PHPFunctionDeclaration, rhs: PHPFunctionDeclaration) -> Bool { lhs === rhs }
}

/// クラス宣言。
public final class PHPClassDeclaration: Equatable {
    public let name: String
    public let parentName: String?
    /// プロパティ名と既定値。
    public let properties: [(name: String, defaultValue: PHPExpr?)]
    public let methods: [String: PHPFunctionDeclaration]
    /// クラス定数。
    public let constants: [(name: String, value: PHPExpr)]
    public let location: SourceLocation

    public init(name: String, parentName: String?,
                properties: [(name: String, defaultValue: PHPExpr?)],
                methods: [String: PHPFunctionDeclaration],
                constants: [(name: String, value: PHPExpr)],
                location: SourceLocation) {
        self.name = name
        self.parentName = parentName
        self.properties = properties
        self.methods = methods
        self.constants = constants
        self.location = location
    }

    public static func == (lhs: PHPClassDeclaration, rhs: PHPClassDeclaration) -> Bool { lhs === rhs }
}

public indirect enum PHPExpr {
    case literal(PHPValue, SourceLocation)
    /// `"a $b c"` のような、文字列の中に式が混ざったもの。
    case interpolated([PHPExpr], SourceLocation)
    case variable(String, SourceLocation)
    case arrayLiteral([(key: PHPExpr?, value: PHPExpr)], SourceLocation)
    /// `$a[i]`。index が nil なら `$a[]` (末尾に追加)。
    case index(PHPExpr, PHPExpr?, SourceLocation)
    case property(PHPExpr, String, SourceLocation)
    case methodCall(PHPExpr, String, [PHPExpr], SourceLocation)
    case call(String, [PHPExpr], SourceLocation)
    case callValue(PHPExpr, [PHPExpr], SourceLocation)
    case newObject(String, [PHPExpr], SourceLocation)
    case staticCall(String, String, [PHPExpr], SourceLocation)
    case classConstant(String, String, SourceLocation)
    case unary(String, PHPExpr, SourceLocation)
    case binary(String, PHPExpr, PHPExpr, SourceLocation)
    case assign(String, PHPExpr, PHPExpr, SourceLocation)
    case increment(PHPExpr, isIncrement: Bool, isPrefix: Bool, SourceLocation)
    /// `a ? b : c` (b が nil なら `a ?: c`)
    case ternary(PHPExpr, PHPExpr?, PHPExpr, SourceLocation)
    case closure(PHPFunctionDeclaration, [String], SourceLocation)
    case cast(String, PHPExpr, SourceLocation)
    case constant(String, SourceLocation)
    case issetCheck([PHPExpr], SourceLocation)
    case emptyCheck(PHPExpr, SourceLocation)
    case thisReference(SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .literal(_, let location), .interpolated(_, let location), .variable(_, let location),
             .arrayLiteral(_, let location), .index(_, _, let location), .property(_, _, let location),
             .methodCall(_, _, _, let location), .call(_, _, let location), .callValue(_, _, let location),
             .newObject(_, _, let location), .staticCall(_, _, _, let location),
             .classConstant(_, _, let location), .unary(_, _, let location), .binary(_, _, _, let location),
             .assign(_, _, _, let location), .increment(_, _, _, let location),
             .ternary(_, _, _, let location), .closure(_, _, let location), .cast(_, _, let location),
             .constant(_, let location), .issetCheck(_, let location), .emptyCheck(_, let location),
             .thisReference(let location):
            return location
        }
    }
}

public indirect enum PHPStmt {
    /// `?>` の外にある、そのまま出力される部分。
    case inlineHTML(String, SourceLocation)
    case echo([PHPExpr], SourceLocation)
    case expression(PHPExpr, SourceLocation)
    case ifStmt(branches: [(condition: PHPExpr, body: [PHPStmt])], elseBody: [PHPStmt]?, SourceLocation)
    case whileStmt(PHPExpr, [PHPStmt], SourceLocation)
    case doWhile([PHPStmt], PHPExpr, SourceLocation)
    case forStmt(initial: [PHPExpr], condition: [PHPExpr], step: [PHPExpr], body: [PHPStmt], SourceLocation)
    case foreachStmt(subject: PHPExpr, keyVariable: String?, valueVariable: String,
                     byReference: Bool, body: [PHPStmt], SourceLocation)
    case switchStmt(subject: PHPExpr, cases: [(value: PHPExpr?, body: [PHPStmt])], SourceLocation)
    case breakStmt(Int, SourceLocation)
    case continueStmt(Int, SourceLocation)
    case returnStmt(PHPExpr?, SourceLocation)
    case functionDeclaration(PHPFunctionDeclaration)
    case classDeclaration(PHPClassDeclaration)
    case globalStmt([String], SourceLocation)
    case unsetStmt([PHPExpr], SourceLocation)
    case block([PHPStmt], SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .inlineHTML(_, let location), .echo(_, let location), .expression(_, let location),
             .ifStmt(_, _, let location), .whileStmt(_, _, let location), .doWhile(_, _, let location),
             .forStmt(_, _, _, _, let location), .foreachStmt(_, _, _, _, _, let location),
             .switchStmt(_, _, let location), .breakStmt(_, let location), .continueStmt(_, let location),
             .returnStmt(_, let location), .globalStmt(_, let location), .unsetStmt(_, let location),
             .block(_, let location):
            return location
        case .functionDeclaration(let declaration): return declaration.location
        case .classDeclaration(let declaration): return declaration.location
        }
    }
}
