import Foundation

/// スタックに積まれる値。
public enum Value: Equatable {
    case integer(Int64)
    case number(Double)

    public var int: Int64 {
        switch self {
        case .integer(let value): return value
        case .number(let value): return value.isFinite ? Int64(value.rounded(.towardZero)) : 0
        }
    }

    public var double: Double {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        }
    }
}

/// 実行時の制限。
public struct MiniCLimits {
    public var heapSize: Int
    public var stackSize: Int
    public var maximumSteps: Int
    public var maximumOutputBytes: Int
    public var maximumCallDepth: Int

    public init(heapSize: Int = 4 << 20,
                stackSize: Int = 1 << 20,
                maximumSteps: Int = 20_000_000,
                maximumOutputBytes: Int = 1 << 20,
                maximumCallDepth: Int = 10_000) {
        self.heapSize = heapSize
        self.stackSize = stackSize
        self.maximumSteps = maximumSteps
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumCallDepth = maximumCallDepth
    }

    public static let `default` = MiniCLimits()
}

/// 実行結果。
public struct MiniCRunResult: Equatable {
    public var output: String
    /// stderr に書かれた内容。
    public var errorOutput: String = ""
    public var exitCode: Int32
    /// 異常終了したときの説明 (正常なら nil)。
    public var runtimeError: String?
    public var executedSteps: Int

    public var succeeded: Bool { runtimeError == nil }
}

/// バイトコードを実行する仮想マシン。
public final class MiniCVM {
    private struct Frame {
        var returnAddress: Int
        var savedFramePointer: Int
        var savedStackPointer: Int
        var functionIndex: Int
        /// `...` で渡された引数。
        var variadicArguments: [Value] = []
        /// 構造体を返す関数のための、呼び出し側が用意した置き場所。
        var aggregateDestination: Int = 0
    }

    /// 関数ポインタの値はこのビットを立てて表す (メモリのアドレスと区別するため)。
    private static let functionTag: Int64 = 0x4000_0000_0000_0000

    private struct RuntimeError: Error {
        var message: String
    }

    private struct ExitSignal: Error {
        var code: Int32
    }

    private let program: MiniCProgram
    private let limits: MiniCLimits

    private var memory: [UInt8]
    private var operandStack: [Value] = []
    private var frames: [Frame] = []
    private var programCounter = 0
    private var framePointer = 0
    private var stackPointer = 0
    private var steps = 0

    private let heapBase: Int
    private let heapEnd: Int
    private let stackBase: Int
    private let stackEnd: Int

    private var output = Data()
    private var errorOutput = Data()
    private var outputOverflowed = false
    private var inputCharacters: [Character]
    private var inputPosition = 0
    private var randomState: UInt64 = 1

    // MARK: - 141 / 142. 中の様子を見せる

    /// いまのスタック・メモリ・呼び出しの様子を取り出す。
    public var snapshot: VMSnapshot {
        let instruction = programCounter < program.instructions.count
            ? MiniCProgram.text(for: program.instructions[programCounter])
            : "(終わり)"
        let line = programCounter < program.lineNumbers.count
            ? program.lineNumbers[programCounter] : 0

        let slots = operandStack.reversed().enumerated().map { depth, value in
            StackSlot(depth: depth,
                      text: {
                          switch value {
                          case .integer(let number): return String(number)
                          case .number(let number): return MLNumberFormatting.shortestStyle(number)
                          }
                      }(),
                      intValue: value.int, doubleValue: value.double)
        }

        var names: [String] = []
        for frame in frames {
            let name = frame.functionIndex < program.functions.count
                ? program.functions[frame.functionIndex].name : "?"
            names.append(name)
        }

        return VMSnapshot(programCounter: programCounter, instruction: instruction,
                          sourceLine: line, stack: slots, callStack: names,
                          regions: memoryRegions, steps: steps)
    }

    /// メモリの区切りと、そこで使っている量。
    public var memoryRegions: [MemoryRegion] {
        [MemoryRegion(kind: .staticData, start: 0, size: heapBase,
                      used: program.staticImage.count),
         MemoryRegion(kind: .heap, start: heapBase, size: heapEnd - heapBase,
                      used: usedHeapBytes),
         // スタックは上から下へ伸びる。
         MemoryRegion(kind: .stack, start: stackBase, size: stackEnd - stackBase,
                      used: Swift.max(0, stackPointer - stackBase))]
    }

    public init(program: MiniCProgram, input: String = "", limits: MiniCLimits = .default) {
        self.program = program
        self.limits = limits
        self.inputCharacters = Array(input)

        let staticSize = TypeContext.align(program.staticImage.count, to: 16)
        heapBase = staticSize
        heapEnd = heapBase + limits.heapSize
        stackBase = heapEnd
        stackEnd = stackBase + limits.stackSize

        memory = Array(repeating: 0, count: stackEnd)
        memory.replaceSubrange(0..<program.staticImage.count, with: program.staticImage)
        stackPointer = stackBase
        initializeHeap()
    }

    // MARK: - 実行

    public func run() -> MiniCRunResult {
        do {
            try callFunction(index: program.entryFunction, argumentCount: 0)
            while !frames.isEmpty {
                try step()
            }
            let exitCode = operandStack.popLast()?.int ?? 0
            return result(exitCode: Int32(truncatingIfNeeded: exitCode), error: nil)
        } catch let signal as ExitSignal {
            return result(exitCode: signal.code, error: nil)
        } catch let error as RuntimeError {
            return result(exitCode: 1, error: describe(error))
        } catch {
            return result(exitCode: 1, error: "実行を中断しました: \(error)")
        }
    }

    private func result(exitCode: Int32, error: String?) -> MiniCRunResult {
        var text = String(data: output, encoding: .utf8) ?? String(decoding: output, as: UTF8.self)
        if outputOverflowed {
            text += "\n…出力が上限 (\(limits.maximumOutputBytes) バイト) に達したので打ち切りました。"
        }
        let errorText = String(decoding: errorOutput, as: UTF8.self)
        return MiniCRunResult(output: text, errorOutput: errorText, exitCode: exitCode,
                              runtimeError: error, executedSteps: steps)
    }

    private func describe(_ error: RuntimeError) -> String {
        var text = error.message
        let line = programCounter < program.lineNumbers.count ? program.lineNumbers[programCounter] : 0
        if line > 0 {
            text += " (\(line) 行目"
            if let frame = frames.last, frame.functionIndex < program.functions.count {
                text += ", 関数 \(program.functions[frame.functionIndex].name)"
            }
            text += ")"
        }
        return text
    }

    private func step() throws {
        steps += 1
        if steps > limits.maximumSteps {
            throw RuntimeError(message: "実行が長すぎます (\(limits.maximumSteps) 命令を超えました)。無限ループかもしれません。")
        }
        guard programCounter >= 0, programCounter < program.instructions.count else {
            throw RuntimeError(message: "命令の位置が範囲外です。")
        }
        let instruction = program.instructions[programCounter]
        programCounter += 1
        try execute(instruction)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func execute(_ instruction: Instruction) throws {
        switch instruction {
        case .pushInt(let value):
            operandStack.append(.integer(value))
        case .pushDouble(let value):
            operandStack.append(.number(value))
        case .pushGlobal(let address):
            operandStack.append(.integer(Int64(address)))
        case .pushLocal(let offset):
            operandStack.append(.integer(Int64(framePointer + offset)))

        case .load(let size, let signed):
            let address = try popAddress()
            operandStack.append(.integer(try readInteger(at: address, size: size, signed: signed)))
        case .loadDouble:
            let address = try popAddress()
            operandStack.append(.number(try readDouble(at: address)))

        case .store(let size):
            let value = try pop()
            let address = try popAddress()
            try writeInteger(value.int, at: address, size: size)
            operandStack.append(value)
        case .storeDrop(let size):
            let value = try pop()
            let address = try popAddress()
            try writeInteger(value.int, at: address, size: size)
        case .storeDouble:
            let value = try pop()
            let address = try popAddress()
            try writeDouble(value.double, at: address)
            operandStack.append(value)
        case .storeDoubleDrop:
            let value = try pop()
            let address = try popAddress()
            try writeDouble(value.double, at: address)

        case .memcopy(let size):
            let source = try popAddress()
            let destination = try popAddress()
            try copyMemory(from: source, to: destination, size: size)
            operandStack.append(.integer(Int64(destination)))
        case .memcopyDrop(let size):
            let source = try popAddress()
            let destination = try popAddress()
            try copyMemory(from: source, to: destination, size: size)
        case .fillZero(let size):
            let address = try popAddress()
            try checkAccess(address: address, size: size)
            for offset in 0..<size { memory[address + offset] = 0 }

        case .pop:
            _ = try pop()
        case .dup:
            let value = try pop()
            operandStack.append(value)
            operandStack.append(value)
        case .dupX1:
            let top = try pop()
            let second = try pop()
            operandStack.append(top)
            operandStack.append(second)
            operandStack.append(top)

        case .addInt: try binaryInteger { $0 &+ $1 }
        case .subInt: try binaryInteger { $0 &- $1 }
        case .mulInt: try binaryInteger { $0 &* $1 }
        case .divInt:
            let right = try pop().int
            let left = try pop().int
            guard right != 0 else { throw RuntimeError(message: "0 で割ろうとしました。") }
            guard !(left == Int64.min && right == -1) else {
                throw RuntimeError(message: "整数の割り算があふれました。")
            }
            operandStack.append(.integer(left / right))
        case .remInt:
            let right = try pop().int
            let left = try pop().int
            guard right != 0 else { throw RuntimeError(message: "0 で剰余を求めようとしました。") }
            guard !(left == Int64.min && right == -1) else {
                throw RuntimeError(message: "整数の剰余があふれました。")
            }
            operandStack.append(.integer(left % right))
        case .negInt:
            let value = try pop().int
            operandStack.append(.integer(0 &- value))

        case .divUInt:
            let right = UInt64(bitPattern: try pop().int)
            let left = UInt64(bitPattern: try pop().int)
            guard right != 0 else { throw RuntimeError(message: "0 で割ろうとしました。") }
            operandStack.append(.integer(Int64(bitPattern: left / right)))
        case .remUInt:
            let right = UInt64(bitPattern: try pop().int)
            let left = UInt64(bitPattern: try pop().int)
            guard right != 0 else { throw RuntimeError(message: "0 で剰余を求めようとしました。") }
            operandStack.append(.integer(Int64(bitPattern: left % right)))
        case .shiftRightUnsigned:
            let right = try pop().int
            let left = UInt64(bitPattern: try pop().int)
            operandStack.append(.integer(right >= 64 || right < 0 ? 0 : Int64(bitPattern: left >> UInt64(right))))
        case .compareUInt(let comparison):
            let right = UInt64(bitPattern: try pop().int)
            let left = UInt64(bitPattern: try pop().int)
            operandStack.append(.integer(compare(left, right, comparison) ? 1 : 0))

        case .addDouble: try binaryDouble { $0 + $1 }
        case .subDouble: try binaryDouble { $0 - $1 }
        case .mulDouble: try binaryDouble { $0 * $1 }
        case .divDouble: try binaryDouble { $0 / $1 }
        case .negDouble:
            let value = try pop().double
            operandStack.append(.number(-value))

        case .shiftLeft:
            let right = try pop().int
            let left = try pop().int
            operandStack.append(.integer(right >= 64 || right < 0 ? 0 : left << right))
        case .shiftRight:
            let right = try pop().int
            let left = try pop().int
            operandStack.append(.integer(right >= 64 || right < 0 ? (left < 0 ? -1 : 0) : left >> right))
        case .bitAnd: try binaryInteger { $0 & $1 }
        case .bitOr: try binaryInteger { $0 | $1 }
        case .bitXor: try binaryInteger { $0 ^ $1 }
        case .bitNot:
            let value = try pop().int
            operandStack.append(.integer(~value))

        case .compareInt(let comparison):
            let right = try pop().int
            let left = try pop().int
            operandStack.append(.integer(compare(left, right, comparison) ? 1 : 0))
        case .compareDouble(let comparison):
            let right = try pop().double
            let left = try pop().double
            operandStack.append(.integer(compare(left, right, comparison) ? 1 : 0))
        case .logicalNot:
            let value = try pop()
            operandStack.append(.integer(value.int == 0 ? 1 : 0))

        case .intToDouble:
            let value = try pop().int
            operandStack.append(.number(Double(value)))
        case .unsignedToDouble:
            let value = UInt64(bitPattern: try pop().int)
            operandStack.append(.number(Double(value)))
        case .doubleToInt:
            let value = try pop().double
            guard value.isFinite else { operandStack.append(.integer(0)); break }
            operandStack.append(.integer(Int64(value.rounded(.towardZero))))
        case .truncate(let size, let signed):
            let value = try pop().int
            operandStack.append(.integer(truncate(value, to: size, signed: signed)))

        case .jump(let target):
            programCounter = target
        case .jumpIfZero(let target):
            if try pop().int == 0 { programCounter = target }
        case .jumpIfNotZero(let target):
            if try pop().int != 0 { programCounter = target }

        case .pushFunction(let index):
            operandStack.append(.integer(MiniCVM.functionTag | Int64(index + 1)))

        case .call(let function, let argumentCount):
            try callFunction(index: function, argumentCount: argumentCount)

        case .callIndirect(let argumentCount):
            let callee = try pop()
            try callFunctionValue(callee, argumentCount: argumentCount)

        case .vaArg(let isDouble):
            let address = try popAddress()
            let index = Int(try readInteger(at: address, size: 8))
            guard let frame = frames.last, index >= 0, index < frame.variadicArguments.count else {
                throw RuntimeError(message: "va_arg で引数を取りすぎました。")
            }
            let value = frame.variadicArguments[index]
            try writeInteger(Int64(index + 1), at: address, size: 8)
            operandStack.append(isDouble ? .number(value.double) : .integer(value.int))
        case .callBuiltin(let builtin, let argumentCount):
            guard let builtin = Builtin(rawValue: builtin) else {
                throw RuntimeError(message: "知らない組み込み関数です。")
            }
            try callBuiltin(builtin, argumentCount: argumentCount)

        case .returnValue:
            var value = try pop()
            if let frame = frames.last, frame.functionIndex < program.functions.count,
               program.functions[frame.functionIndex].returnsAggregate {
                let size = program.functions[frame.functionIndex].returnSize
                let destination = frame.aggregateDestination
                if destination != 0 {
                    try copyMemory(from: Int(value.int), to: destination, size: size)
                    value = .integer(Int64(destination))
                }
            }
            try returnFromFunction()
            operandStack.append(value)
        case .returnVoid:
            try returnFromFunction()

        case .halt:
            throw ExitSignal(code: 0)
        }
    }

    // MARK: - スタック操作

    private func pop() throws -> Value {
        guard let value = operandStack.popLast() else {
            throw RuntimeError(message: "内部エラー: 値スタックが空です。")
        }
        return value
    }

    private func popAddress() throws -> Int {
        let value = try pop().int
        guard value != 0 else { throw RuntimeError(message: "NULL ポインタを参照しました。") }
        guard value > 0, value < Int64(memory.count) else {
            throw RuntimeError(message: "不正なアドレスを参照しました (\(value))。")
        }
        return Int(value)
    }

    private func binaryInteger(_ operation: (Int64, Int64) -> Int64) throws {
        let right = try pop().int
        let left = try pop().int
        operandStack.append(.integer(operation(left, right)))
    }

    private func binaryDouble(_ operation: (Double, Double) -> Double) throws {
        let right = try pop().double
        let left = try pop().double
        operandStack.append(.number(operation(left, right)))
    }

    private func compare<T: Comparable>(_ left: T, _ right: T, _ comparison: Comparison) -> Bool {
        switch comparison {
        case .less: return left < right
        case .lessEqual: return left <= right
        case .greater: return left > right
        case .greaterEqual: return left >= right
        case .equal: return left == right
        case .notEqual: return left != right
        }
    }

    private func truncate(_ value: Int64, to size: Int, signed: Bool) -> Int64 {
        switch (size, signed) {
        case (1, true): return Int64(Int8(truncatingIfNeeded: value))
        case (1, false): return Int64(UInt8(truncatingIfNeeded: value))
        case (2, true): return Int64(Int16(truncatingIfNeeded: value))
        case (2, false): return Int64(UInt16(truncatingIfNeeded: value))
        case (4, true): return Int64(Int32(truncatingIfNeeded: value))
        case (4, false): return Int64(UInt32(truncatingIfNeeded: value))
        default: return value
        }
    }

    // MARK: - 呼び出し

    private func callFunction(index: Int, argumentCount: Int) throws {
        guard index >= 0, index < program.functions.count else {
            throw RuntimeError(message: "知らない関数を呼び出しました。")
        }
        let function = program.functions[index]
        guard function.entry >= 0 else {
            throw RuntimeError(message: "関数 \(function.name) は宣言だけで、本体がありません。")
        }
        guard frames.count < limits.maximumCallDepth else {
            throw RuntimeError(message: "関数の呼び出しが深すぎます (\(limits.maximumCallDepth) 段)。"
                               + "再帰が止まらなくなっていませんか。")
        }

        var arguments: [Value] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            arguments.append(try pop())
        }
        arguments.reverse()

        // 構造体を返す関数は、先頭の引数が置き場所のアドレス
        var aggregateDestination = 0
        if function.returnsAggregate, !arguments.isEmpty {
            aggregateDestination = Int(arguments.removeFirst().int)
        }
        var variadicArguments: [Value] = []
        if arguments.count > function.parameters.count {
            variadicArguments = Array(arguments[function.parameters.count...])
            arguments = Array(arguments[..<function.parameters.count])
        }

        let newFramePointer = TypeContext.align(stackPointer, to: 16)
        guard newFramePointer + function.frameSize <= stackEnd else {
            throw RuntimeError(message: "スタックがあふれました。再帰が深すぎるか、ローカル変数が大きすぎます。")
        }

        frames.append(Frame(returnAddress: programCounter,
                            savedFramePointer: framePointer,
                            savedStackPointer: stackPointer,
                            functionIndex: index,
                            variadicArguments: variadicArguments,
                            aggregateDestination: aggregateDestination))
        if function.frameSize > 0 {
            for offset in 0..<function.frameSize {
                memory[newFramePointer + offset] = 0
            }
        }
        framePointer = newFramePointer
        stackPointer = newFramePointer + max(function.frameSize, 0)

        for (position, parameter) in function.parameters.enumerated() where position < arguments.count {
            let target = framePointer + parameter.offset
            let value = arguments[position]
            if parameter.isAggregate {
                let source = Int(value.int)
                try copyMemory(from: source, to: target, size: parameter.size)
            } else if parameter.isDouble {
                try writeDouble(value.double, at: target)
            } else {
                try writeInteger(value.int, at: target, size: parameter.size)
            }
        }

        programCounter = function.entry
    }

    /// 関数ポインタの値から呼び出す。
    private func callFunctionValue(_ callee: Value, argumentCount: Int) throws {
        let raw = callee.int
        guard raw & MiniCVM.functionTag != 0 else {
            throw RuntimeError(message: raw == 0 ? "NULL の関数ポインタを呼び出しました。"
                               : "関数ポインタではない値を呼び出しました。")
        }
        let index = Int(raw & ~MiniCVM.functionTag) - 1
        try callFunction(index: index, argumentCount: argumentCount)
    }

    /// 組み込み関数の中から、C の関数を呼び出して結果を受け取る (qsort の比較関数など)。
    private func invoke(_ callee: Value, _ arguments: [Value]) throws -> Value {
        let depth = frames.count
        for argument in arguments {
            operandStack.append(argument)
        }
        try callFunctionValue(callee, argumentCount: arguments.count)
        while frames.count > depth {
            try step()
        }
        return operandStack.popLast() ?? .integer(0)
    }

    private func returnFromFunction() throws {
        guard let frame = frames.popLast() else {
            throw RuntimeError(message: "内部エラー: 戻る先がありません。")
        }
        programCounter = frame.returnAddress
        framePointer = frame.savedFramePointer
        stackPointer = frame.savedStackPointer
    }

    // MARK: - メモリ

    private func checkAccess(address: Int, size: Int) throws {
        guard address >= 8 else {
            throw RuntimeError(message: address == 0 ? "NULL ポインタを参照しました。"
                               : "不正なアドレスを参照しました (\(address))。")
        }
        guard address + size <= memory.count else {
            throw RuntimeError(message: "メモリの範囲外に触れました (アドレス \(address))。")
        }
    }

    private func readInteger(at address: Int, size: Int, signed: Bool = true) throws -> Int64 {
        try checkAccess(address: address, size: size)
        var value: UInt64 = 0
        for offset in 0..<size {
            value |= UInt64(memory[address + offset]) << (8 * offset)
        }
        guard signed else { return Int64(bitPattern: value & mask(for: size)) }
        switch size {
        case 1: return Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: value)))
        case 2: return Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
        case 4: return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        default: return Int64(bitPattern: value)
        }
    }

    private func mask(for size: Int) -> UInt64 {
        size >= 8 ? UInt64.max : (UInt64(1) << (8 * UInt64(size))) - 1
    }

    private func writeInteger(_ value: Int64, at address: Int, size: Int) throws {
        try checkAccess(address: address, size: size)
        for offset in 0..<size {
            memory[address + offset] = UInt8(truncatingIfNeeded: value >> (8 * offset))
        }
    }

    private func readDouble(at address: Int) throws -> Double {
        Double(bitPattern: UInt64(bitPattern: try readInteger(at: address, size: 8)))
    }

    private func writeDouble(_ value: Double, at address: Int) throws {
        try writeInteger(Int64(bitPattern: value.bitPattern), at: address, size: 8)
    }

    private func copyMemory(from source: Int, to destination: Int, size: Int) throws {
        guard size > 0 else { return }
        try checkAccess(address: source, size: size)
        try checkAccess(address: destination, size: size)
        if source == destination { return }
        if source < destination, source + size > destination {
            for offset in stride(from: size - 1, through: 0, by: -1) {
                memory[destination + offset] = memory[source + offset]
            }
        } else {
            for offset in 0..<size {
                memory[destination + offset] = memory[source + offset]
            }
        }
    }

    private func readCString(at address: Int64) -> String {
        guard address > 0, address < Int64(memory.count) else { return "" }
        var bytes: [UInt8] = []
        var position = Int(address)
        while position < memory.count, memory[position] != 0, bytes.count < 1 << 20 {
            bytes.append(memory[position])
            position += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeCString(_ text: String, at address: Int) throws {
        let bytes = Array(text.utf8)
        try checkAccess(address: address, size: bytes.count + 1)
        for (offset, byte) in bytes.enumerated() {
            memory[address + offset] = byte
        }
        memory[address + bytes.count] = 0
    }

    // MARK: - ヒープ (malloc / free)

    /// ブロックの先頭 16 バイトがヘッダ (8 バイト: 全体のサイズ, 8 バイト: 使用中フラグ)。
    private static let headerSize = 16

    /// いま確保されている (空きでない) ブロックの合計。
    var usedHeapBytes: Int {
        var total = 0
        var address = heapBase
        while address + MiniCVM.headerSize <= heapEnd {
            let size = blockSize(at: address)
            if size <= 0 { break }
            if !blockIsFree(at: address) { total += size }
            address += size
        }
        return total
    }

    private func initializeHeap() {
        let size = heapEnd - heapBase
        guard size > MiniCVM.headerSize else { return }
        writeHeader(at: heapBase, size: size, isFree: true)
    }

    private func writeHeader(at address: Int, size: Int, isFree: Bool) {
        guard address >= 0, address + MiniCVM.headerSize <= memory.count else { return }
        for offset in 0..<8 {
            memory[address + offset] = UInt8(truncatingIfNeeded: size >> (8 * offset))
        }
        memory[address + 8] = isFree ? 1 : 0
        for offset in 9..<16 { memory[address + offset] = 0 }
    }

    private func blockSize(at address: Int) -> Int {
        var value = 0
        for offset in 0..<8 {
            value |= Int(memory[address + offset]) << (8 * offset)
        }
        return value
    }

    private func blockIsFree(at address: Int) -> Bool {
        memory[address + 8] == 1
    }

    private func allocate(_ requested: Int) -> Int {
        let needed = TypeContext.align(max(requested, 1), to: 16) + MiniCVM.headerSize
        var address = heapBase
        while address + MiniCVM.headerSize <= heapEnd {
            let size = blockSize(at: address)
            if size <= 0 { return 0 }
            if blockIsFree(at: address) {
                coalesce(at: address)
                let merged = blockSize(at: address)
                if merged >= needed {
                    if merged - needed > MiniCVM.headerSize + 16 {
                        writeHeader(at: address, size: needed, isFree: false)
                        writeHeader(at: address + needed, size: merged - needed, isFree: true)
                    } else {
                        writeHeader(at: address, size: merged, isFree: false)
                    }
                    let payload = address + MiniCVM.headerSize
                    for offset in 0..<(blockSize(at: address) - MiniCVM.headerSize) {
                        memory[payload + offset] = 0
                    }
                    return payload
                }
            }
            address += size
        }
        return 0
    }

    /// 隣り合う空きブロックをつなげる。
    private func coalesce(at address: Int) {
        var size = blockSize(at: address)
        var next = address + size
        while next + MiniCVM.headerSize <= heapEnd, blockIsFree(at: next) {
            let nextSize = blockSize(at: next)
            if nextSize <= 0 { break }
            size += nextSize
            next += nextSize
        }
        writeHeader(at: address, size: size, isFree: true)
    }

    private func deallocate(_ payload: Int) throws {
        guard payload != 0 else { return }
        let address = payload - MiniCVM.headerSize
        guard address >= heapBase, address + MiniCVM.headerSize <= heapEnd else {
            throw RuntimeError(message: "free に渡されたポインタが不正です。")
        }
        guard !blockIsFree(at: address) else {
            throw RuntimeError(message: "同じ領域を 2 回 free しました。")
        }
        writeHeader(at: address, size: blockSize(at: address), isFree: true)
        coalesce(at: address)
    }

    // MARK: - 組み込み関数

    private func write(_ text: String, toError: Bool = false) {
        guard !outputOverflowed else { return }
        let bytes = Data(text.utf8)
        if toError {
            if errorOutput.count + bytes.count <= limits.maximumOutputBytes {
                errorOutput.append(bytes)
            }
            return
        }
        if output.count + bytes.count > limits.maximumOutputBytes {
            let remaining = max(0, limits.maximumOutputBytes - output.count)
            output.append(bytes.prefix(remaining))
            outputOverflowed = true
            return
        }
        output.append(bytes)
    }

    private func callBuiltin(_ builtin: Builtin, argumentCount: Int) throws {
        var arguments: [Value] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            arguments.append(try pop())
        }
        arguments.reverse()

        func integer(_ position: Int) -> Int64 {
            position < arguments.count ? arguments[position].int : 0
        }
        func number(_ position: Int) -> Double {
            position < arguments.count ? arguments[position].double : 0
        }
        func push(_ value: Int64) {
            operandStack.append(.integer(value))
        }
        func pushNumber(_ value: Double) {
            operandStack.append(.number(value))
        }

        switch builtin {
        case .printf:
            let format = readCString(at: integer(0))
            let text = FormatPrinter.render(format: format,
                                            arguments: Array(arguments.dropFirst()),
                                            readString: { [weak self] address in
                                                self?.readCString(at: address) ?? ""
                                            })
            write(text)
            push(Int64(text.utf8.count))

        case .puts:
            let text = readCString(at: integer(0))
            write(text + "\n")
            push(Int64(text.utf8.count + 1))

        case .putchar:
            let value = integer(0)
            write(String(Character(UnicodeScalar(UInt8(truncatingIfNeeded: value)))))
            push(value)

        case .getchar:
            if inputPosition < inputCharacters.count {
                let character = inputCharacters[inputPosition]
                inputPosition += 1
                push(Int64(character.unicodeScalars.first?.value ?? 0))
            } else {
                push(-1)
            }

        case .scanf:
            let format = readCString(at: integer(0))
            let addresses = arguments.dropFirst().map(\.int)
            let scan = FormatPrinter.scan(format: format, input: inputCharacters,
                                          start: inputPosition, addresses: Array(addresses))
            inputPosition = scan.consumed
            for assignment in scan.assignments {
                let address = Int(assignment.address)
                switch assignment.value {
                case .integer(let value):
                    try writeInteger(value, at: address, size: 4)
                case .number(let value):
                    try writeDouble(value, at: address)
                case .text(let value):
                    try writeCString(value, at: address)
                }
            }
            push(Int64(scan.count))

        case .strlen:
            push(Int64(readCString(at: integer(0)).utf8.count))

        case .strcmp, .strncmp:
            let left = Array(readCString(at: integer(0)).utf8)
            let right = Array(readCString(at: integer(1)).utf8)
            let limit = builtin == .strncmp ? Int(integer(2)) : max(left.count, right.count) + 1
            var result: Int64 = 0
            for position in 0..<limit {
                let a = position < left.count ? Int64(left[position]) : 0
                let b = position < right.count ? Int64(right[position]) : 0
                if a != b {
                    result = a < b ? -1 : 1
                    break
                }
                if a == 0 { break }
            }
            push(result)

        case .strcpy, .strncpy:
            let destination = Int(integer(0))
            var text = readCString(at: integer(1))
            if builtin == .strncpy {
                let limit = Int(integer(2))
                text = String(text.prefix(limit))
            }
            try writeCString(text, at: destination)
            push(Int64(destination))

        case .strcat:
            let destination = Int(integer(0))
            let existing = readCString(at: integer(0))
            let addition = readCString(at: integer(1))
            try writeCString(existing + addition, at: destination)
            push(Int64(destination))

        case .strchr:
            let base = integer(0)
            let text = Array(readCString(at: base).utf8)
            let target = UInt8(truncatingIfNeeded: integer(1))
            if let position = text.firstIndex(of: target) {
                push(base + Int64(position))
            } else if target == 0 {
                push(base + Int64(text.count))
            } else {
                push(0)
            }

        case .memset:
            let address = Int(integer(0))
            let byte = UInt8(truncatingIfNeeded: integer(1))
            let size = Int(integer(2))
            try checkAccess(address: address, size: size)
            for offset in 0..<size { memory[address + offset] = byte }
            push(Int64(address))

        case .memcpy, .memmove:
            let destination = Int(integer(0))
            let source = Int(integer(1))
            try copyMemory(from: source, to: destination, size: Int(integer(2)))
            push(Int64(destination))

        case .malloc:
            let size = Int(integer(0))
            guard size >= 0 else { throw RuntimeError(message: "malloc に負のサイズが渡されました。") }
            push(Int64(allocate(size)))

        case .calloc:
            let count = Int(integer(0))
            let size = Int(integer(1))
            push(Int64(allocate(max(0, count * size))))

        case .realloc:
            let pointer = Int(integer(0))
            let size = Int(integer(1))
            let newPointer = allocate(size)
            if pointer != 0, newPointer != 0 {
                let oldSize = blockSize(at: pointer - MiniCVM.headerSize) - MiniCVM.headerSize
                try copyMemory(from: pointer, to: newPointer, size: min(oldSize, size))
                try deallocate(pointer)
            }
            push(Int64(newPointer))

        case .free:
            try deallocate(Int(integer(0)))

        case .abs, .labs:
            let value = integer(0)
            push(value < 0 ? -value : value)

        case .atoi:
            let text = readCString(at: integer(0)).trimmingCharacters(in: .whitespaces)
            var digits = ""
            for character in text {
                if character == "-" || character == "+", digits.isEmpty {
                    digits.append(character)
                } else if character.isNumber {
                    digits.append(character)
                } else {
                    break
                }
            }
            push(Int64(digits) ?? 0)

        case .atof:
            let text = readCString(at: integer(0)).trimmingCharacters(in: .whitespaces)
            pushNumber(Double(text) ?? 0)

        case .exitProgram:
            throw ExitSignal(code: Int32(truncatingIfNeeded: integer(0)))

        case .rand:
            // 決まった順番の疑似乱数 (線形合同法)
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            push(Int64((randomState >> 33) & 0x7FFF_FFFF))

        case .srand:
            randomState = UInt64(bitPattern: integer(0))

        case .time:
            push(1_700_000_000)

        case .sqrt: pushNumber(Foundation.sqrt(number(0)))
        case .pow: pushNumber(Foundation.pow(number(0), number(1)))
        case .fabs: pushNumber(Swift.abs(number(0)))
        case .floor: pushNumber(number(0).rounded(.down))
        case .ceil: pushNumber(number(0).rounded(.up))
        case .round: pushNumber(number(0).rounded())
        case .fmod: pushNumber(Foundation.fmod(number(0), number(1)))
        case .sin: pushNumber(Foundation.sin(number(0)))
        case .cos: pushNumber(Foundation.cos(number(0)))
        case .tan: pushNumber(Foundation.tan(number(0)))
        case .atan: pushNumber(Foundation.atan(number(0)))
        case .atan2: pushNumber(Foundation.atan2(number(0), number(1)))
        case .log: pushNumber(Foundation.log(number(0)))
        case .log10: pushNumber(Foundation.log10(number(0)))
        case .exp: pushNumber(Foundation.exp(number(0)))

        // ---- 文字列に書き出す printf ----
        case .sprintf, .snprintf:
            let destination = Int(integer(0))
            let formatIndex = builtin == .sprintf ? 1 : 2
            let limit = builtin == .snprintf ? Int(integer(1)) : Int.max
            let format = readCString(at: integer(formatIndex))
            var text = FormatPrinter.render(format: format,
                                            arguments: Array(arguments.dropFirst(formatIndex + 1)),
                                            readString: { [weak self] address in
                                                self?.readCString(at: address) ?? ""
                                            })
            let produced = text.utf8.count
            if builtin == .snprintf, limit > 0, produced > limit - 1 {
                text = String(decoding: Array(text.utf8).prefix(limit - 1), as: UTF8.self)
            }
            try writeCString(text, at: destination)
            push(Int64(produced))

        // ---- ファイル (stdout / stderr) ----
        case .fprintf:
            let stream = integer(0)
            let format = readCString(at: integer(1))
            let text = FormatPrinter.render(format: format,
                                            arguments: Array(arguments.dropFirst(2)),
                                            readString: { [weak self] address in
                                                self?.readCString(at: address) ?? ""
                                            })
            write(text, toError: stream == 2)
            push(Int64(text.utf8.count))

        case .fputs:
            let text = readCString(at: integer(0))
            write(text, toError: integer(1) == 2)
            push(Int64(text.utf8.count))

        case .fputc:
            let value = integer(0)
            write(String(Character(UnicodeScalar(UInt8(truncatingIfNeeded: value)))), toError: integer(1) == 2)
            push(value)

        case .fflush:
            push(0)

        // ---- 文字列 ----
        case .strstr:
            let haystackAddress = integer(0)
            let haystack = Array(readCString(at: haystackAddress).utf8)
            let needle = Array(readCString(at: integer(1)).utf8)
            if needle.isEmpty {
                push(haystackAddress)
            } else if haystack.count >= needle.count {
                var found: Int64 = 0
                for start in 0...(haystack.count - needle.count)
                where Array(haystack[start..<(start + needle.count)]) == needle {
                    found = haystackAddress + Int64(start)
                    break
                }
                push(found)
            } else {
                push(0)
            }

        case .strrchr:
            let base = integer(0)
            let text = Array(readCString(at: base).utf8)
            let target = UInt8(truncatingIfNeeded: integer(1))
            if let position = text.lastIndex(of: target) {
                push(base + Int64(position))
            } else if target == 0 {
                push(base + Int64(text.count))
            } else {
                push(0)
            }

        case .strdup:
            let text = readCString(at: integer(0))
            let bytes = Array(text.utf8)
            let pointer = allocate(bytes.count + 1)
            if pointer != 0 { try writeCString(text, at: pointer) }
            push(Int64(pointer))

        case .strncat:
            let destination = Int(integer(0))
            let existing = readCString(at: integer(0))
            let addition = String(readCString(at: integer(1)).prefix(Int(integer(2))))
            try writeCString(existing + addition, at: destination)
            push(Int64(destination))

        case .memcmp:
            let left = Int(integer(0))
            let right = Int(integer(1))
            let size = Int(integer(2))
            try checkAccess(address: left, size: size)
            try checkAccess(address: right, size: size)
            var result: Int64 = 0
            for offset in 0..<size where memory[left + offset] != memory[right + offset] {
                result = memory[left + offset] < memory[right + offset] ? -1 : 1
                break
            }
            push(result)

        case .strtol:
            let base = integer(0)
            let text = Array(readCString(at: base))
            var position = 0
            while position < text.count, text[position].isWhitespace { position += 1 }
            var sign: Int64 = 1
            if position < text.count, text[position] == "-" || text[position] == "+" {
                if text[position] == "-" { sign = -1 }
                position += 1
            }
            var radix = Int(integer(2))
            if radix == 0 {
                if position + 1 < text.count, text[position] == "0",
                   text[position + 1] == "x" || text[position + 1] == "X" {
                    radix = 16
                    position += 2
                } else if position < text.count, text[position] == "0" {
                    radix = 8
                } else {
                    radix = 10
                }
            } else if radix == 16, position + 1 < text.count, text[position] == "0",
                      text[position + 1] == "x" || text[position + 1] == "X" {
                position += 2
            }
            var value: Int64 = 0
            var consumedDigits = 0
            while position < text.count,
                  let digit = text[position].hexDigitValue, digit < radix {
                value = value &* Int64(radix) &+ Int64(digit)
                position += 1
                consumedDigits += 1
            }
            if consumedDigits == 0 { position = 0 }
            if integer(1) != 0 {
                try writeInteger(base + Int64(position), at: Int(integer(1)), size: 8)
            }
            push(sign * value)

        case .strtod:
            let base = integer(0)
            let text = Array(readCString(at: base))
            var position = 0
            while position < text.count, text[position].isWhitespace { position += 1 }
            let start = position
            if position < text.count, text[position] == "-" || text[position] == "+" { position += 1 }
            while position < text.count, text[position].isNumber { position += 1 }
            if position < text.count, text[position] == "." {
                position += 1
                while position < text.count, text[position].isNumber { position += 1 }
            }
            if position < text.count, text[position] == "e" || text[position] == "E" {
                var lookahead = position + 1
                if lookahead < text.count, text[lookahead] == "-" || text[lookahead] == "+" { lookahead += 1 }
                if lookahead < text.count, text[lookahead].isNumber {
                    position = lookahead
                    while position < text.count, text[position].isNumber { position += 1 }
                }
            }
            let numberText = String(text[start..<position])
            let parsed = Double(numberText) ?? 0
            if integer(1) != 0 {
                try writeInteger(base + Int64(parsed == 0 && numberText.isEmpty ? 0 : position),
                                 at: Int(integer(1)), size: 8)
            }
            pushNumber(parsed)

        case .atol:
            let text = readCString(at: integer(0)).trimmingCharacters(in: .whitespaces)
            var digits = ""
            for character in text {
                if character == "-" || character == "+", digits.isEmpty {
                    digits.append(character)
                } else if character.isNumber {
                    digits.append(character)
                } else {
                    break
                }
            }
            push(Int64(digits) ?? 0)

        // ---- 文字の種類 ----
        case .isalpha, .isdigit, .isalnum, .isspace, .isupper, .islower, .ispunct:
            let value = integer(0)
            guard value >= 0, value < 128, let scalar = UnicodeScalar(UInt32(value)) else {
                push(0)
                break
            }
            let character = Character(scalar)
            let result: Bool
            switch builtin {
            case .isalpha: result = character.isLetter
            case .isdigit: result = character.isNumber
            case .isalnum: result = character.isLetter || character.isNumber
            case .isspace: result = character.isWhitespace
            case .isupper: result = character.isUppercase
            case .islower: result = character.isLowercase
            default: result = character.isPunctuation || character.isSymbol
            }
            push(result ? 1 : 0)

        case .toupper, .tolower:
            let value = integer(0)
            guard value >= 0, value < 128, let scalar = UnicodeScalar(UInt32(value)) else {
                push(value)
                break
            }
            let character = Character(scalar)
            let converted = builtin == .toupper ? character.uppercased() : character.lowercased()
            push(Int64(converted.unicodeScalars.first?.value ?? UInt32(value)))

        // ---- 並べ替えと二分探索 (比較関数を呼び戻す) ----
        case .qsort:
            let base = Int(integer(0))
            let count = Int(integer(1))
            let size = Int(integer(2))
            let comparator = arguments.count > 3 ? arguments[3] : .integer(0)
            guard count > 0, size > 0 else { break }
            try checkAccess(address: base, size: count * size)
            var elements: [[UInt8]] = (0..<count).map { index in
                Array(memory[(base + index * size)..<(base + (index + 1) * size)])
            }
            // 比較関数を呼ぶために、一時領域に 2 要素を置いて渡す
            let scratch = allocate(size * 2)
            guard scratch != 0 else { throw RuntimeError(message: "qsort の作業領域を確保できませんでした。") }
            try elements.sortWithComparator { left, right in
                for offset in 0..<size {
                    memory[scratch + offset] = left[offset]
                    memory[scratch + size + offset] = right[offset]
                }
                let result = try invoke(comparator, [.integer(Int64(scratch)), .integer(Int64(scratch + size))])
                return result.int
            }
            try deallocate(scratch)
            for (index, element) in elements.enumerated() {
                for offset in 0..<size {
                    memory[base + index * size + offset] = element[offset]
                }
            }

        case .bsearch:
            let key = Int64(integer(0))
            let base = Int(integer(1))
            let count = Int(integer(2))
            let size = Int(integer(3))
            let comparator = arguments.count > 4 ? arguments[4] : .integer(0)
            var low = 0
            var high = count - 1
            var found: Int64 = 0
            while low <= high {
                let middle = (low + high) / 2
                let element = Int64(base + middle * size)
                let result = try invoke(comparator, [.integer(key), .integer(element)]).int
                if result == 0 {
                    found = element
                    break
                }
                if result < 0 { high = middle - 1 } else { low = middle + 1 }
            }
            push(found)

        case .assertFailed:
            let message = readCString(at: integer(0))
            write("assertion failed: \(message) (\(integer(1)) 行目)\n", toError: true)
            throw ExitSignal(code: 134)
        }
    }
}


extension Array {
    /// 例外を投げる比較関数でも使える単純なマージソート (安定)。
    mutating func sortWithComparator(_ compare: (Element, Element) throws -> Int64) rethrows {
        guard count > 1 else { return }
        var buffer = self
        try mergeSort(&self, &buffer, 0, count, compare)
    }

    private func mergeSort(_ values: inout [Element], _ buffer: inout [Element],
                           _ start: Int, _ end: Int,
                           _ compare: (Element, Element) throws -> Int64) rethrows {
        guard end - start > 1 else { return }
        let middle = (start + end) / 2
        try mergeSort(&values, &buffer, start, middle, compare)
        try mergeSort(&values, &buffer, middle, end, compare)
        var left = start
        var right = middle
        var index = start
        while left < middle || right < end {
            if left >= middle {
                buffer[index] = values[right]
                right += 1
            } else if right >= end {
                buffer[index] = values[left]
                left += 1
            } else if try compare(values[right], values[left]) < 0 {
                buffer[index] = values[right]
                right += 1
            } else {
                buffer[index] = values[left]
                left += 1
            }
            index += 1
        }
        for position in start..<end {
            values[position] = buffer[position]
        }
    }
}
