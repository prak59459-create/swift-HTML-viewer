import Foundation

// MARK: - 140. 逆アセンブルの拡大

/// 逆アセンブルの 1 行。画面で並べたり、ソース行と結びつけたりする。
public struct DisassemblyLine: Identifiable, Equatable, Sendable {
    public var address: Int
    /// もとのソースの行番号 (分からなければ 0)。
    public var sourceLine: Int
    /// 命令の名前 (`push.i` など)。
    public var mnemonic: String
    /// 引数の部分。
    public var operands: String
    /// ここが関数の入口なら、その名前。
    public var functionName: String?
    /// 飛び先 (分岐命令のとき)。
    public var jumpTarget: Int?

    public var id: Int { address }

    public init(address: Int, sourceLine: Int, mnemonic: String, operands: String,
                functionName: String? = nil, jumpTarget: Int? = nil) {
        self.address = address
        self.sourceLine = sourceLine
        self.mnemonic = mnemonic
        self.operands = operands
        self.functionName = functionName
        self.jumpTarget = jumpTarget
    }

    /// 「 12 | 4 | push.i 3」。
    public var text: String {
        let position = String(format: "%5d", address)
        let line = sourceLine > 0 ? String(format: "%4d", sourceLine) : "   -"
        let body = operands.isEmpty ? mnemonic : "\(mnemonic) \(operands)"
        return "\(position) |\(line)| \(body)"
    }
}

/// バイトコードを画面に出しやすい形にほどく。
public enum Disassembly {

    /// 命令の一覧を行に直す。
    public static func lines(of program: MiniCProgram) -> [DisassemblyLine] {
        var entryPoints: [Int: String] = [:]
        for function in program.functions { entryPoints[function.entry] = function.name }

        return program.instructions.enumerated().map { address, instruction in
            let text = MiniCProgram.text(for: instruction)
            let parts = text.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            let mnemonic = parts.first.map(String.init) ?? text
            let operands = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let line = address < program.lineNumbers.count
                ? program.lineNumbers[address] : 0
            return DisassemblyLine(address: address, sourceLine: line,
                                   mnemonic: mnemonic, operands: operands,
                                   functionName: entryPoints[address],
                                   jumpTarget: target(of: instruction))
        }
    }

    /// 分岐命令の飛び先。
    static func target(of instruction: Instruction) -> Int? {
        switch instruction {
        case .jump(let address), .jumpIfZero(let address), .jumpIfNotZero(let address):
            return address
        default:
            return nil
        }
    }

    /// ソースの行 → その行から生まれた命令の番地。
    public static func addressesBySourceLine(of program: MiniCProgram) -> [Int: [Int]] {
        var table: [Int: [Int]] = [:]
        for (address, line) in program.lineNumbers.enumerated() where line > 0 {
            table[line, default: []].append(address)
        }
        return table
    }

    /// 関数ごとに区切った一覧。
    public static func byFunction(_ program: MiniCProgram)
        -> [(name: String, lines: [DisassemblyLine])] {
        let all = lines(of: program)
        let sorted = program.functions.sorted { $0.entry < $1.entry }
        var result: [(String, [DisassemblyLine])] = []
        for (index, function) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].entry : all.count
            guard function.entry < end else { continue }
            result.append((function.name, Array(all[function.entry..<end])))
        }
        return result
    }

    /// 命令の種類ごとの個数 (どんな処理が多いかを見る)。
    public static func histogram(of program: MiniCProgram) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for instruction in program.instructions {
            let text = MiniCProgram.text(for: instruction)
            let mnemonic = text.split(separator: " ").first.map(String.init) ?? text
            counts[mnemonic, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { ($0.key, $0.value) }
    }
}

// MARK: - 141. スタックの可視化

/// VM のスタックに積まれている 1 つ。
public struct StackSlot: Identifiable, Equatable, Sendable {
    /// 上から数えた位置 (0 がいちばん上)。
    public var depth: Int
    public var text: String
    /// 整数として見た値。
    public var intValue: Int64
    public var doubleValue: Double

    public var id: Int { depth }

    public init(depth: Int, text: String, intValue: Int64, doubleValue: Double) {
        self.depth = depth
        self.text = text
        self.intValue = intValue
        self.doubleValue = doubleValue
    }
}

// MARK: - 142. メモリマップ

/// メモリの区切り 1 つ。
public struct MemoryRegion: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// グローバル変数と文字列。
        case staticData
        /// malloc で取る場所。
        case heap
        /// 関数の呼び出しで使う場所。
        case stack

        public var displayName: String {
            switch self {
            case .staticData: return "静的領域"
            case .heap: return "ヒープ"
            case .stack: return "スタック"
            }
        }
    }

    public var kind: Kind
    /// 始まりの番地。
    public var start: Int
    /// 大きさ (バイト)。
    public var size: Int
    /// 使っている量 (バイト)。
    public var used: Int

    public var id: String { "\(kind.rawValue)-\(start)" }

    public init(kind: Kind, start: Int, size: Int, used: Int) {
        self.kind = kind
        self.start = start
        self.size = size
        self.used = used
    }

    public var end: Int { start + size }

    /// 使っている割合 (0〜1)。
    public var fraction: Double {
        guard size > 0 else { return 0 }
        return Swift.min(1, Double(used) / Double(size))
    }

    public var description: String {
        "\(kind.displayName): \(OfflineCache.sizeText(used)) / \(OfflineCache.sizeText(size))"
    }
}

/// VM のある瞬間の様子。
public struct VMSnapshot: Equatable, Sendable {
    /// いま実行しようとしている命令の番地。
    public var programCounter: Int
    /// その命令の文字列。
    public var instruction: String
    /// もとのソースの行。
    public var sourceLine: Int
    /// 積まれている値 (上から順)。
    public var stack: [StackSlot]
    /// 呼び出しの積み重ね (外側から内側)。
    public var callStack: [String]
    public var regions: [MemoryRegion]
    public var steps: Int

    public init(programCounter: Int, instruction: String, sourceLine: Int,
                stack: [StackSlot] = [], callStack: [String] = [],
                regions: [MemoryRegion] = [], steps: Int = 0) {
        self.programCounter = programCounter
        self.instruction = instruction
        self.sourceLine = sourceLine
        self.stack = stack
        self.callStack = callStack
        self.regions = regions
        self.steps = steps
    }

    /// 使っているメモリの合計。
    public var usedBytes: Int { regions.reduce(0) { $0 + $1.used } }
}
