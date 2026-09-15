import Foundation

/// 比較の種類。
public enum Comparison: String, Equatable {
    case less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">=", equal = "==", notEqual = "!="
}

/// スタックマシンの命令。
public enum Instruction: Equatable {
    case pushInt(Int64)
    case pushDouble(Double)
    /// 静的領域の絶対アドレスを積む。
    case pushGlobal(Int)
    /// フレーム先頭からの相対アドレスを積む。
    case pushLocal(Int)

    /// [addr] → [値] (size バイト読む。signed なら符号拡張、そうでなければ 0 拡張)
    case load(size: Int, signed: Bool)
    /// [addr] → [値] (double)
    case loadDouble
    /// [addr, 値] → [値]
    case store(size: Int)
    case storeDouble
    /// [addr, 値] → []
    case storeDrop(size: Int)
    case storeDoubleDrop
    /// [dst, src] → [dst] (size バイトコピー)
    case memcopy(size: Int)
    /// [dst, src] → []
    case memcopyDrop(size: Int)
    /// [addr] → [] (size バイトを 0 で埋める)
    case fillZero(size: Int)

    case pop
    case dup
    /// 先頭の値のコピーを 2 番目の下に差し込む ([a, b] → [b, a, b])
    case dupX1

    case addInt, subInt, mulInt, divInt, remInt, negInt
    /// 符号なしの除算・剰余・右シフト・比較
    case divUInt, remUInt, shiftRightUnsigned
    case compareUInt(Comparison)
    case addDouble, subDouble, mulDouble, divDouble, negDouble
    case shiftLeft, shiftRight, bitAnd, bitOr, bitXor, bitNot
    case compareInt(Comparison)
    case compareDouble(Comparison)
    case logicalNot

    case intToDouble
    /// 符号なし整数 → double
    case unsignedToDouble
    case doubleToInt
    /// size バイトに切り詰める (signed なら符号拡張、そうでなければ 0 拡張)。
    case truncate(size: Int, signed: Bool)

    case jump(Int)
    case jumpIfZero(Int)
    case jumpIfNotZero(Int)

    case call(function: Int, argumentCount: Int)
    case callBuiltin(builtin: Int, argumentCount: Int)
    case returnValue
    case returnVoid
    case halt
}

/// 関数の引数 1 つ分の受け取り方。
public struct ParameterInfo: Equatable {
    public var offset: Int
    public var size: Int
    /// 構造体などアドレス渡しでコピーするもの。
    public var isAggregate: Bool
    public var isDouble: Bool
}

/// 関数 1 つ分の情報。
public struct FunctionInfo: Equatable {
    public var name: String
    public var entry: Int
    public var frameSize: Int
    public var parameters: [ParameterInfo]
    public var returnsVoid: Bool
}

/// コンパイル結果。
public struct MiniCProgram: Equatable {
    public var instructions: [Instruction]
    /// 命令ごとの行番号 (実行時エラーの表示に使う)。
    public var lineNumbers: [Int]
    public var functions: [FunctionInfo]
    /// main の関数番号。
    public var entryFunction: Int
    /// 静的領域 (グローバル変数と文字列リテラル) の初期イメージ。
    public var staticImage: [UInt8]

    public var staticSize: Int { staticImage.count }

    /// 逆アセンブル結果。
    public var disassembly: String {
        var entryPoints: [Int: String] = [:]
        for function in functions {
            entryPoints[function.entry] = function.name
        }
        var lines: [String] = []
        lines.append("; 静的領域: \(staticImage.count) バイト / 関数: \(functions.count) 個 / 命令: \(instructions.count) 個")
        for (address, instruction) in instructions.enumerated() {
            if let name = entryPoints[address] {
                let info = functions.first { $0.entry == address }
                lines.append("")
                lines.append("\(name):  ; フレーム \(info?.frameSize ?? 0) バイト, 引数 \(info?.parameters.count ?? 0) 個")
            }
            let line = address < lineNumbers.count ? lineNumbers[address] : 0
            let position = String(format: "%5d", address)
            let sourceLine = line > 0 ? String(format: "%4d", line) : "   -"
            lines.append("\(position) |\(sourceLine)| \(MiniCProgram.text(for: instruction))")
        }
        return lines.joined(separator: "\n")
    }

    static func text(for instruction: Instruction) -> String {
        switch instruction {
        case .pushInt(let value): return "push.i    \(value)"
        case .pushDouble(let value): return "push.d    \(value)"
        case .pushGlobal(let address): return "global    @\(address)"
        case .pushLocal(let offset): return "local     fp+\(offset)"
        case .load(let size, let signed): return "load.\(size)\(signed ? "" : "u")"
        case .loadDouble: return "load.d"
        case .store(let size): return "store.\(size)"
        case .storeDouble: return "store.d"
        case .storeDrop(let size): return "store.\(size)!"
        case .storeDoubleDrop: return "store.d!"
        case .memcopy(let size): return "memcpy    \(size)"
        case .memcopyDrop(let size): return "memcpy!   \(size)"
        case .fillZero(let size): return "bzero     \(size)"
        case .pop: return "pop"
        case .dup: return "dup"
        case .dupX1: return "dup_x1"
        case .addInt: return "add.i"
        case .subInt: return "sub.i"
        case .mulInt: return "mul.i"
        case .divInt: return "div.i"
        case .remInt: return "rem.i"
        case .negInt: return "neg.i"
        case .divUInt: return "div.u"
        case .remUInt: return "rem.u"
        case .shiftRightUnsigned: return "shr.u"
        case .compareUInt(let comparison): return "cmp.u     \(comparison.rawValue)"
        case .addDouble: return "add.d"
        case .subDouble: return "sub.d"
        case .mulDouble: return "mul.d"
        case .divDouble: return "div.d"
        case .negDouble: return "neg.d"
        case .shiftLeft: return "shl"
        case .shiftRight: return "shr"
        case .bitAnd: return "and"
        case .bitOr: return "or"
        case .bitXor: return "xor"
        case .bitNot: return "not"
        case .compareInt(let comparison): return "cmp.i     \(comparison.rawValue)"
        case .compareDouble(let comparison): return "cmp.d     \(comparison.rawValue)"
        case .logicalNot: return "lnot"
        case .intToDouble: return "i2d"
        case .unsignedToDouble: return "u2d"
        case .doubleToInt: return "d2i"
        case .truncate(let size, let signed): return "trunc.\(size)\(signed ? "" : "u")"
        case .jump(let target): return "jmp       \(target)"
        case .jumpIfZero(let target): return "jz        \(target)"
        case .jumpIfNotZero(let target): return "jnz       \(target)"
        case .call(let function, let count): return "call      #\(function), \(count) 引数"
        case .callBuiltin(let builtin, let count):
            let name = Builtin(rawValue: builtin)?.name ?? "?"
            return "callext   \(name), \(count) 引数"
        case .returnValue: return "ret"
        case .returnVoid: return "ret.v"
        case .halt: return "halt"
        }
    }
}
