import Foundation

// MARK: - 型の書き方 (構文上の型)

/// `int`, `struct Point`, `Foo` (typedef 名) など、基底の型指定。
public enum TypeSpecifier: Equatable {
    case void
    case char
    case uchar
    case int
    case uint
    case long
    case ulong
    case double
    case structure(String)
    case enumeration(String)
    case typedefName(String)
}

/// 宣言に現れる型の書き方 (`int *a[3]` の `int *` + `[3]` の部分)。
public struct TypeName: Equatable {
    public var specifier: TypeSpecifier
    public var pointerDepth: Int
    /// 配列の要素数 (外側から順)。`nil` は `[]` (サイズ省略)。
    public var arrayCounts: [Int?]
    public var location: SourceLocation

    public init(specifier: TypeSpecifier, pointerDepth: Int = 0,
                arrayCounts: [Int?] = [], location: SourceLocation = .unknown) {
        self.specifier = specifier
        self.pointerDepth = pointerDepth
        self.arrayCounts = arrayCounts
        self.location = location
    }
}

// MARK: - 演算子

public enum UnaryOperator: String, Equatable {
    case plus = "+", minus = "-", logicalNot = "!", bitwiseNot = "~"
    case addressOf = "&", dereference = "*"
    case preIncrement = "++", preDecrement = "--"
}

public enum PostfixOperator: String, Equatable {
    case increment = "++", decrement = "--"
}

public enum BinaryOperator: String, Equatable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    case shiftLeft = "<<", shiftRight = ">>"
    case less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    case equal = "==", notEqual = "!="
    case bitwiseAnd = "&", bitwiseXor = "^", bitwiseOr = "|"
    case logicalAnd = "&&", logicalOr = "||"

    public var isComparison: Bool {
        switch self {
        case .less, .lessEqual, .greater, .greaterEqual, .equal, .notEqual: return true
        default: return false
        }
    }

    public var isBitwise: Bool {
        switch self {
        case .bitwiseAnd, .bitwiseOr, .bitwiseXor, .shiftLeft, .shiftRight, .remainder: return true
        default: return false
        }
    }
}

// MARK: - 式

public indirect enum Expr: Equatable {
    case integerLiteral(Int64, isLong: Bool, SourceLocation)
    case floatingLiteral(Double, SourceLocation)
    case characterLiteral(Int64, SourceLocation)
    case stringLiteral(String, SourceLocation)
    case identifier(String, SourceLocation)
    case unary(UnaryOperator, Expr, SourceLocation)
    case postfix(PostfixOperator, Expr, SourceLocation)
    case binary(BinaryOperator, Expr, Expr, SourceLocation)
    /// `op` が nil なら単純な代入、そうでなければ複合代入 (`+=` など)。
    case assignment(BinaryOperator?, Expr, Expr, SourceLocation)
    case conditional(Expr, Expr, Expr, SourceLocation)
    case call(Expr, [Expr], SourceLocation)
    case subscriptExpr(Expr, Expr, SourceLocation)
    case member(Expr, String, isArrow: Bool, SourceLocation)
    case cast(TypeName, Expr, SourceLocation)
    case sizeofType(TypeName, SourceLocation)
    case sizeofExpr(Expr, SourceLocation)
    case comma(Expr, Expr, SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .integerLiteral(_, _, let location),
             .floatingLiteral(_, let location),
             .characterLiteral(_, let location),
             .stringLiteral(_, let location),
             .identifier(_, let location),
             .unary(_, _, let location),
             .postfix(_, _, let location),
             .binary(_, _, _, let location),
             .assignment(_, _, _, let location),
             .conditional(_, _, _, let location),
             .call(_, _, let location),
             .subscriptExpr(_, _, let location),
             .member(_, _, _, let location),
             .cast(_, _, let location),
             .sizeofType(_, let location),
             .sizeofExpr(_, let location),
             .comma(_, _, let location):
            return location
        }
    }
}

// MARK: - 初期化子

public indirect enum Initializer: Equatable {
    case expression(Expr)
    case list([Initializer], SourceLocation)
}

/// 変数宣言 1 つ分。
public struct VariableDeclaration: Equatable {
    public var name: String
    public var type: TypeName
    public var initializer: Initializer?
    public var isStatic: Bool
    public var location: SourceLocation
}

// MARK: - 文

public indirect enum Stmt: Equatable {
    case expression(Expr?, SourceLocation)
    case declaration([VariableDeclaration], SourceLocation)
    case compound([Stmt], SourceLocation)
    case ifStmt(condition: Expr, then: Stmt, else: Stmt?, SourceLocation)
    case whileStmt(condition: Expr, body: Stmt, SourceLocation)
    case doWhile(body: Stmt, condition: Expr, SourceLocation)
    case forStmt(initializer: Stmt?, condition: Expr?, step: Expr?, body: Stmt, SourceLocation)
    case switchStmt(subject: Expr, cases: [SwitchCase], SourceLocation)
    case breakStmt(SourceLocation)
    case continueStmt(SourceLocation)
    case returnStmt(Expr?, SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .expression(_, let location),
             .declaration(_, let location),
             .compound(_, let location),
             .ifStmt(_, _, _, let location),
             .whileStmt(_, _, let location),
             .doWhile(_, _, let location),
             .forStmt(_, _, _, _, let location),
             .switchStmt(_, _, let location),
             .breakStmt(let location),
             .continueStmt(let location),
             .returnStmt(_, let location):
            return location
        }
    }
}

/// switch の 1 ラベル分。`value` が nil なら default。
public struct SwitchCase: Equatable {
    public var value: Expr?
    public var body: [Stmt]
    public var location: SourceLocation
}

// MARK: - 宣言

public struct FunctionParameter: Equatable {
    public var name: String
    public var type: TypeName
    public var location: SourceLocation
}

public struct FunctionDeclaration: Equatable {
    public var name: String
    public var returnType: TypeName
    public var parameters: [FunctionParameter]
    public var isVariadic: Bool
    /// プロトタイプ宣言なら nil。
    public var body: [Stmt]?
    public var location: SourceLocation
}

public struct StructDefinition: Equatable {
    public var name: String
    public var members: [VariableDeclaration]
    public var location: SourceLocation
}

public struct EnumDefinition: Equatable {
    public var name: String
    public var constants: [(name: String, value: Int64)]
    public var location: SourceLocation

    public static func == (lhs: EnumDefinition, rhs: EnumDefinition) -> Bool {
        lhs.name == rhs.name && lhs.location == rhs.location
            && lhs.constants.map(\.name) == rhs.constants.map(\.name)
            && lhs.constants.map(\.value) == rhs.constants.map(\.value)
    }
}

public enum TopLevelDeclaration: Equatable {
    case function(FunctionDeclaration)
    case globalVariables([VariableDeclaration], SourceLocation)
    case structDefinition(StructDefinition)
    case enumDefinition(EnumDefinition)
    case typedefDefinition(name: String, type: TypeName, SourceLocation)
}

/// 翻訳単位 (ソース 1 本ぶん)。
public struct TranslationUnit: Equatable {
    public var declarations: [TopLevelDeclaration]
}
