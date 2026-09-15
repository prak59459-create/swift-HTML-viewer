import Foundation

public struct SwiftParameter {
    public var label: String?
    public var name: String
    public var typeName: String?
    public var defaultValue: SwiftExpr?
    public var isVariadic: Bool
    public var isInout: Bool
}

public final class SwiftFunctionDeclaration {
    public let name: String
    public let parameters: [SwiftParameter]
    public let returnTypeName: String?
    public let body: [SwiftStmt]
    public let isMutating: Bool
    public let isStatic: Bool
    public let isInitializer: Bool
    /// クロージャで `$0` を使う形かどうか。
    public let usesShorthandArguments: Bool
    public let location: SourceLocation

    public init(name: String, parameters: [SwiftParameter], returnTypeName: String?, body: [SwiftStmt],
                isMutating: Bool = false, isStatic: Bool = false, isInitializer: Bool = false,
                usesShorthandArguments: Bool = false, location: SourceLocation) {
        self.name = name
        self.parameters = parameters
        self.returnTypeName = returnTypeName
        self.body = body
        self.isMutating = isMutating
        self.isStatic = isStatic
        self.isInitializer = isInitializer
        self.usesShorthandArguments = usesShorthandArguments
        self.location = location
    }
}

public struct SwiftPropertyDeclaration {
    public var name: String
    public var typeName: String?
    public var defaultValue: SwiftExpr?
    public var isConstant: Bool
    public var isStatic: Bool
    /// 計算プロパティの本体 (get だけ)。
    public var getter: [SwiftStmt]?
}

public final class SwiftTypeDeclaration {
    public enum Kind {
        case structure
        case classType
        case enumeration
    }

    public let kind: Kind
    public let name: String
    public let parentName: String?
    public let properties: [SwiftPropertyDeclaration]
    public let methods: [SwiftFunctionDeclaration]
    public let initializers: [SwiftFunctionDeclaration]
    public let enumCases: [(name: String, rawValue: SwiftExpr?)]
    public let location: SourceLocation

    public init(kind: Kind, name: String, parentName: String?,
                properties: [SwiftPropertyDeclaration], methods: [SwiftFunctionDeclaration],
                initializers: [SwiftFunctionDeclaration],
                enumCases: [(name: String, rawValue: SwiftExpr?)], location: SourceLocation) {
        self.kind = kind
        self.name = name
        self.parentName = parentName
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.enumCases = enumCases
        self.location = location
    }
}

public indirect enum SwiftExpr {
    case literal(SwiftValue, SourceLocation)
    /// `"a \(b)"` の各部分。
    case interpolation([SwiftExpr], SourceLocation)
    case identifier(String, SourceLocation)
    case selfExpression(SourceLocation)
    case arrayLiteral([SwiftExpr], SourceLocation)
    case dictionaryLiteral([(key: SwiftExpr, value: SwiftExpr)], SourceLocation)
    case tupleLiteral([(label: String?, value: SwiftExpr)], SourceLocation)
    case member(SwiftExpr, String, isOptional: Bool, SourceLocation)
    case index(SwiftExpr, SwiftExpr, SourceLocation)
    case call(SwiftExpr, [(label: String?, value: SwiftExpr)], SourceLocation)
    case unary(String, SwiftExpr, SourceLocation)
    case binary(String, SwiftExpr, SwiftExpr, SourceLocation)
    case assign(String, SwiftExpr, SwiftExpr, SourceLocation)
    case ternary(SwiftExpr, SwiftExpr, SwiftExpr, SourceLocation)
    case closure(SwiftFunctionDeclaration, SourceLocation)
    case forceUnwrap(SwiftExpr, SourceLocation)
    case rangeExpression(SwiftExpr, SwiftExpr, isClosed: Bool, SourceLocation)
    case typeCast(SwiftExpr, typeName: String, isOptional: Bool, SourceLocation)
    case typeCheck(SwiftExpr, typeName: String, SourceLocation)
    /// `.caseName` (型が推論される列挙のメンバー)
    case implicitMember(String, SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .literal(_, let location), .interpolation(_, let location), .identifier(_, let location),
             .selfExpression(let location), .arrayLiteral(_, let location),
             .dictionaryLiteral(_, let location), .tupleLiteral(_, let location),
             .member(_, _, _, let location), .index(_, _, let location), .call(_, _, let location),
             .unary(_, _, let location), .binary(_, _, _, let location), .assign(_, _, _, let location),
             .ternary(_, _, _, let location), .closure(_, let location), .forceUnwrap(_, let location),
             .rangeExpression(_, _, _, let location), .typeCast(_, _, _, let location),
             .typeCheck(_, _, let location), .implicitMember(_, let location):
            return location
        }
    }
}

public enum SwiftCondition {
    case expression(SwiftExpr)
    /// `if let x = expr` / `guard let x = expr`
    case optionalBinding(name: String, value: SwiftExpr, isConstant: Bool)
}

public indirect enum SwiftPattern {
    case expression(SwiftExpr)
    case binding(String)
    case wildcard
    /// `.caseName` または `.caseName(let x)`
    case enumCase(String, binding: String?)
}

public struct SwiftSwitchCase {
    public var patterns: [SwiftPattern]
    public var whereClause: SwiftExpr?
    public var body: [SwiftStmt]
    public var isDefault: Bool
}

public indirect enum SwiftStmt {
    case expression(SwiftExpr, SourceLocation)
    case variableDeclaration(name: String, typeName: String?, value: SwiftExpr?,
                             isConstant: Bool, SourceLocation)
    case ifStmt(conditions: [SwiftCondition], body: [SwiftStmt], elseBody: [SwiftStmt]?, SourceLocation)
    case guardStmt(conditions: [SwiftCondition], elseBody: [SwiftStmt], SourceLocation)
    case whileStmt(SwiftExpr, [SwiftStmt], SourceLocation)
    /// `while let x = ...` (条件に束縛を含む)
    case whileLet(conditions: [SwiftCondition], body: [SwiftStmt], SourceLocation)
    case repeatWhile([SwiftStmt], SwiftExpr, SourceLocation)
    case forIn(variable: String, sequence: SwiftExpr, whereClause: SwiftExpr?,
               body: [SwiftStmt], SourceLocation)
    case switchStmt(subject: SwiftExpr, cases: [SwiftSwitchCase], SourceLocation)
    case breakStmt(SourceLocation)
    case continueStmt(SourceLocation)
    case returnStmt(SwiftExpr?, SourceLocation)
    case functionDeclaration(SwiftFunctionDeclaration)
    case typeDeclaration(SwiftTypeDeclaration)
    case block([SwiftStmt], SourceLocation)

    public var location: SourceLocation {
        switch self {
        case .expression(_, let location), .variableDeclaration(_, _, _, _, let location),
             .ifStmt(_, _, _, let location), .guardStmt(_, _, let location),
             .whileStmt(_, _, let location), .whileLet(_, _, let location),
             .repeatWhile(_, _, let location),
             .forIn(_, _, _, _, let location), .switchStmt(_, _, let location),
             .breakStmt(let location), .continueStmt(let location), .returnStmt(_, let location),
             .block(_, let location):
            return location
        case .functionDeclaration(let declaration): return declaration.location
        case .typeDeclaration(let declaration): return declaration.location
        }
    }
}
