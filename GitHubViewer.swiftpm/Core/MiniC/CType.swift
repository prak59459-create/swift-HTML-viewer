import Foundation

/// MiniC が扱う型。
public indirect enum CType: Equatable {
    case void
    case char           // 1 バイト符号付き
    case uchar          // 1 バイト符号なし
    case int            // 4 バイト符号付き
    case uint           // 4 バイト符号なし
    case long           // 8 バイト符号付き
    case ulong          // 8 バイト符号なし
    case double         // 8 バイト浮動小数点
    case pointer(CType)
    case array(CType, count: Int)
    case structure(String)
    case function(returns: CType, parameters: [CType], isVariadic: Bool)

    public var isArithmetic: Bool {
        switch self {
        case .char, .uchar, .int, .uint, .long, .ulong, .double: return true
        default: return false
        }
    }

    public var isInteger: Bool {
        switch self {
        case .char, .uchar, .int, .uint, .long, .ulong: return true
        default: return false
        }
    }

    /// 符号なし整数かどうか。
    public var isUnsigned: Bool {
        switch self {
        case .uchar, .uint, .ulong: return true
        default: return false
        }
    }

    /// 整数の変換順位 (大きいほど広い)。
    public var integerRank: Int {
        switch self {
        case .char, .uchar: return 1
        case .int, .uint: return 2
        case .long, .ulong: return 3
        default: return 0
        }
    }

    public var isFloating: Bool { self == .double }

    public var isPointer: Bool {
        if case .pointer = self { return true }
        return false
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var isStructure: Bool {
        if case .structure = self { return true }
        return false
    }

    /// スカラー (条件式や算術に使える) かどうか。配列とポインタはアドレスとして扱える。
    public var isScalar: Bool {
        isArithmetic || isPointer || isArray
    }

    /// 配列はポインタに読み替える (C の配列→ポインタ変換)。
    public var decayed: CType {
        if case .array(let element, _) = self { return .pointer(element) }
        return self
    }

    public var pointee: CType? {
        switch self {
        case .pointer(let element): return element
        case .array(let element, _): return element
        default: return nil
        }
    }

    /// エラーメッセージ用の表記。
    public var description: String {
        switch self {
        case .void: return "void"
        case .char: return "char"
        case .uchar: return "unsigned char"
        case .int: return "int"
        case .uint: return "unsigned int"
        case .long: return "long"
        case .ulong: return "unsigned long"
        case .double: return "double"
        case .pointer(let element): return "\(element.description) *"
        case .array(let element, let count): return "\(element.description)[\(count)]"
        case .structure(let name): return "struct \(name)"
        case .function(let returns, let parameters, let isVariadic):
            let list = parameters.map(\.description) + (isVariadic ? ["..."] : [])
            return "\(returns.description)(\(list.joined(separator: ", ")))"
        }
    }
}

/// 構造体のメンバー。
public struct StructMember: Equatable {
    public var name: String
    public var type: CType
    public var offset: Int
}

/// 構造体の定義。
public struct StructLayout: Equatable {
    public var name: String
    public var members: [StructMember]
    public var size: Int
    public var alignment: Int

    public func member(named name: String) -> StructMember? {
        members.first { $0.name == name }
    }
}

/// 型のサイズ計算と構造体テーブル。
final class TypeContext {
    private(set) var structures: [String: StructLayout] = [:]
    private(set) var typedefs: [String: CType] = [:]
    private(set) var enumConstants: [String: Int64] = [:]

    func defineStruct(_ layout: StructLayout) {
        structures[layout.name] = layout
    }

    func structure(named name: String) -> StructLayout? {
        structures[name]
    }

    func defineTypedef(_ name: String, type: CType) {
        typedefs[name] = type
    }

    func typedef(named name: String) -> CType? {
        typedefs[name]
    }

    func defineEnumConstant(_ name: String, value: Int64) {
        enumConstants[name] = value
    }

    func enumConstant(named name: String) -> Int64? {
        enumConstants[name]
    }

    /// バイト数。
    func size(of type: CType) -> Int {
        switch type {
        case .void: return 1
        case .char, .uchar: return 1
        case .int, .uint: return 4
        case .long, .ulong, .double, .pointer, .function: return 8
        case .array(let element, let count): return size(of: element) * max(0, count)
        case .structure(let name): return structures[name]?.size ?? 0
        }
    }

    /// 境界。
    func alignment(of type: CType) -> Int {
        switch type {
        case .void, .char, .uchar: return 1
        case .int, .uint: return 4
        case .long, .ulong, .double, .pointer, .function: return 8
        case .array(let element, _): return alignment(of: element)
        case .structure(let name): return structures[name]?.alignment ?? 1
        }
    }

    /// 構造体のメンバー配置を計算する。
    func layout(name: String, members: [(name: String, type: CType)]) -> StructLayout {
        var offset = 0
        var maximumAlignment = 1
        var laidOut: [StructMember] = []
        for member in members {
            let memberAlignment = alignment(of: member.type)
            maximumAlignment = max(maximumAlignment, memberAlignment)
            offset = TypeContext.align(offset, to: memberAlignment)
            laidOut.append(StructMember(name: member.name, type: member.type, offset: offset))
            offset += size(of: member.type)
        }
        let total = TypeContext.align(offset, to: maximumAlignment)
        return StructLayout(name: name, members: laidOut, size: max(total, 1), alignment: maximumAlignment)
    }

    static func align(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    /// 算術演算での型の格上げ (C の「通常の算術変換」)。
    func usualArithmeticConversion(_ lhs: CType, _ rhs: CType) -> CType {
        if lhs == .double || rhs == .double { return .double }
        if lhs == .ulong || rhs == .ulong { return .ulong }
        if lhs == .long || rhs == .long { return .long }
        if lhs == .uint || rhs == .uint { return .uint }
        return .int
    }

    /// 整数格上げ (char / unsigned char → int)。
    func promote(_ type: CType) -> CType {
        switch type {
        case .char, .uchar: return .int
        default: return type
        }
    }
}
