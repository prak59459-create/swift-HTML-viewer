import Foundation

/// AST を検査しながらバイトコードに変換する。
///
/// 型検査とコード生成を 1 パスで行う素直な構成。式の生成関数は
/// 「値をスタックに 1 つ積み、その型を返す」という約束で書かれている。
final class MiniCCompiler {
    // 出力
    private var instructions: [Instruction] = []
    private var lineNumbers: [Int] = []
    private var functions: [FunctionInfo] = []
    private var staticData: [UInt8] = Array(repeating: 0, count: 8) // 先頭 8 バイトは NULL 用に予約

    // 記号表
    private struct Symbol {
        var type: CType
        var storage: Storage
    }

    private enum Storage {
        case global(Int)
        case local(Int)
    }

    private struct FunctionSignature {
        var index: Int
        var returnType: CType
        var parameterTypes: [CType]
        var isVariadic: Bool
        var isDefined: Bool
    }

    private let diagnostics: DiagnosticBag
    private let types = TypeContext()
    private var globals: [String: Symbol] = [:]
    private var signatures: [String: FunctionSignature] = [:]
    private var stringLiterals: [String: Int] = [:]

    // 関数ごとの状態
    private var scopes: [[String: Symbol]] = []
    private var frameSize = 0
    private var maximumFrameSize = 0
    private var currentReturnType: CType = .void
    private var currentFunctionName = ""

    private struct JumpContext {
        var breakPatches: [Int] = []
        var continuePatches: [Int] = []
    }
    private var loopContexts: [JumpContext] = []
    /// goto のラベル位置と、まだ飛び先が決まっていない goto。
    private var labelPositions: [String: Int] = [:]
    private var pendingGotos: [(label: String, patchIndex: Int, location: SourceLocation)] = []
    /// switch は break だけを受け持つ。
    private var switchContexts: [JumpContext] = []

    init(diagnostics: DiagnosticBag) {
        self.diagnostics = diagnostics
    }

    // MARK: - 入口

    func compile(unit: TranslationUnit, structs: [StructDefinition], enums: [EnumDefinition]) throws -> MiniCProgram {
        defineStandardNames()
        registerTypes(unit: unit, structs: structs, enums: enums)
        registerFunctionSignatures(unit)
        allocateGlobals(unit)

        for declaration in unit.declarations {
            if case .function(let function) = declaration, function.body != nil {
                emitFunction(function)
            }
        }

        guard let main = signatures["main"], main.isDefined else {
            diagnostics.error("main 関数が見つかりません。", at: SourceLocation(line: 1, column: 1))
            throw CompileFailure(diagnostics: diagnostics.diagnostics, source: diagnostics.source)
        }
        if let failure = diagnostics.failureIfNeeded() { throw failure }

        return MiniCProgram(instructions: instructions,
                            lineNumbers: lineNumbers,
                            functions: functions,
                            entryFunction: main.index,
                            staticImage: staticData)
    }

    /// 標準ヘッダにある名前のうち、コンパイラ側で用意しておくもの。
    private func defineStandardNames() {
        types.defineTypedef("va_list", type: .long)
        types.defineTypedef("size_t", type: .ulong)
        types.defineTypedef("ssize_t", type: .long)
        types.defineTypedef("FILE", type: .void)
        types.defineTypedef("uint8_t", type: .uchar)
        types.defineTypedef("int8_t", type: .char)
        types.defineTypedef("uint32_t", type: .uint)
        types.defineTypedef("int32_t", type: .int)
        types.defineTypedef("uint64_t", type: .ulong)
        types.defineTypedef("int64_t", type: .long)
        types.defineEnumConstant("NULL", value: 0)
        types.defineEnumConstant("EOF", value: -1)
        types.defineEnumConstant("stdout", value: 1)
        types.defineEnumConstant("stderr", value: 2)
        types.defineEnumConstant("stdin", value: 0)
        types.defineEnumConstant("true", value: 1)
        types.defineEnumConstant("false", value: 0)
        types.defineEnumConstant("RAND_MAX", value: 2_147_483_647)
    }

    // MARK: - 型の登録

    private func registerTypes(unit: TranslationUnit, structs: [StructDefinition], enums: [EnumDefinition]) {
        // 1. 名前だけ先に登録して、相互参照 (struct Node { struct Node *next; }) を許す
        for definition in structs {
            types.defineStruct(StructLayout(name: definition.name, members: [], size: 1, alignment: 1,
                                            isUnion: definition.isUnion))
        }
        for definition in enums {
            for constant in definition.constants {
                types.defineEnumConstant(constant.name, value: constant.value)
            }
        }
        for declaration in unit.declarations {
            if case .typedefDefinition(let name, let typeName, _) = declaration {
                types.defineTypedef(name, type: resolveType(typeName))
            }
        }
        // 2. メンバーを解決して配置を決める
        for definition in structs {
            var members: [(name: String, type: CType)] = []
            for member in definition.members {
                let type = resolveType(member.type)
                if case .structure(let name) = type, types.structure(named: name)?.members.isEmpty != false,
                   name != definition.name {
                    diagnostics.error("構造体 \(name) の中身が分からないため、メンバー \(member.name) を置けません。",
                                      at: member.location)
                }
                members.append((name: member.name, type: type))
            }
            types.defineStruct(types.layout(name: definition.name, members: members,
                                            isUnion: definition.isUnion))
        }
        // typedef が構造体を指している場合、サイズが確定した後にもう一度解決する
        for declaration in unit.declarations {
            if case .typedefDefinition(let name, let typeName, _) = declaration {
                types.defineTypedef(name, type: resolveType(typeName))
            }
        }
    }

    private func resolveType(_ typeName: TypeName) -> CType {
        resolve(typeName.type, at: typeName.location)
    }

    private func resolve(_ reference: TypeRef, at location: SourceLocation) -> CType {
        switch reference {
        case .base(let specifier):
            switch specifier {
            case .void: return .void
            case .char: return .char
            case .uchar: return .uchar
            case .int: return .int
            case .uint: return .uint
            case .long: return .long
            case .ulong: return .ulong
            case .double: return .double
            case .structure(let name): return .structure(name)
            case .enumeration: return .int
            case .typedefName(let name):
                if let resolved = types.typedef(named: name) { return resolved }
                diagnostics.error("知らない型名です: \(name)", at: location)
                return .int
            }
        case .pointer(let inner):
            return .pointer(resolve(inner, at: location))
        case .array(let inner, let count):
            return .array(resolve(inner, at: location), count: count ?? 0)
        case .function(let returns, let parameters, let isVariadic):
            return .function(returns: resolve(returns, at: location),
                             parameters: parameters.map { resolve($0.type.type, at: location).decayed },
                             isVariadic: isVariadic)
        }
    }

    // MARK: - 関数シグネチャ

    private func registerFunctionSignatures(_ unit: TranslationUnit) {
        for declaration in unit.declarations {
            guard case .function(let function) = declaration else { continue }
            let returnType = resolveType(function.returnType)
            let parameterTypes = function.parameters.map { resolveType($0.type).decayed }

            if Builtin.lookup[function.name] != nil {
                diagnostics.warning("\(function.name) は組み込み関数です。ここでの宣言は無視されます。",
                                    at: function.location)
                continue
            }

            if var existing = signatures[function.name] {
                if existing.isDefined, function.body != nil {
                    diagnostics.error("関数 \(function.name) が二重に定義されています。", at: function.location)
                    continue
                }
                if existing.returnType != returnType {
                    diagnostics.error("関数 \(function.name) の戻り値の型が前の宣言と違います。", at: function.location)
                }
                if function.body != nil {
                    existing.isDefined = true
                    existing.parameterTypes = parameterTypes
                    signatures[function.name] = existing
                }
                continue
            }

            let index = functions.count
            functions.append(FunctionInfo(name: function.name, entry: -1, frameSize: 0,
                                          parameters: [], returnsVoid: returnType == .void,
                                          returnsAggregate: returnType.isStructure,
                                          returnSize: types.size(of: returnType),
                                          isVariadic: function.isVariadic))
            signatures[function.name] = FunctionSignature(index: index,
                                                          returnType: returnType,
                                                          parameterTypes: parameterTypes,
                                                          isVariadic: function.isVariadic,
                                                          isDefined: function.body != nil)
        }
    }

    // MARK: - グローバル変数

    private func allocateGlobals(_ unit: TranslationUnit) {
        for declaration in unit.declarations {
            guard case .globalVariables(let variables, _) = declaration else { continue }
            for variable in variables {
                var type = resolveType(variable.type)

                // サイズ省略の配列は初期化子から決める
                if case .array(let element, let count) = type, count == 0 {
                    if case .list(let items, _)? = variable.initializer {
                        type = .array(element, count: items.count)
                    } else if case .expression(.stringLiteral(let text, _))? = variable.initializer {
                        type = .array(element, count: text.utf8.count + 1)
                    }
                }

                let size = types.size(of: type)
                let alignment = types.alignment(of: type)
                let address = TypeContext.align(staticData.count, to: alignment)
                staticData.append(contentsOf: Array(repeating: 0, count: address - staticData.count + size))

                if globals[variable.name] != nil {
                    diagnostics.error("グローバル変数 \(variable.name) が二重に宣言されています。", at: variable.location)
                }
                globals[variable.name] = Symbol(type: type, storage: .global(address))

                if let initializer = variable.initializer {
                    writeStaticInitializer(initializer, type: type, address: address, location: variable.location)
                }
            }
        }
    }

    /// 静的領域に定数の初期値を書き込む。
    private func writeStaticInitializer(_ initializer: Initializer, type: CType,
                                        address: Int, location: SourceLocation) {
        switch initializer {
        case .expression(let expression):
            if case .array(let element, let count) = type {
                if case .stringLiteral(let text, _) = expression, element == .char {
                    var bytes = Array(text.utf8).map { Int64($0) }
                    bytes.append(0)
                    for (offset, byte) in bytes.prefix(count).enumerated() {
                        writeStatic(value: byte, size: 1, at: address + offset)
                    }
                    return
                }
                diagnostics.error("配列の初期化には { } を使ってください。", at: location)
                return
            }
            guard let value = constantValue(expression) else {
                diagnostics.error("グローバル変数の初期値は定数式でなければなりません。", at: expression.location)
                return
            }
            switch value {
            case .integer(let number):
                if type == .double {
                    writeStaticDouble(Double(number), at: address)
                } else {
                    writeStatic(value: number, size: types.size(of: type), at: address)
                }
            case .floating(let number):
                if type == .double {
                    writeStaticDouble(number, at: address)
                } else {
                    writeStatic(value: Int64(number), size: types.size(of: type), at: address)
                }
            case .address(let pointer):
                writeStatic(value: Int64(pointer), size: 8, at: address)
            }

        case .list(let items, let listLocation):
            switch type {
            case .array(let element, let count):
                let elementSize = types.size(of: element)
                if items.count > count {
                    diagnostics.warning("初期化子が配列の要素数より多いです。", at: listLocation)
                }
                for (offset, item) in items.prefix(count).enumerated() {
                    writeStaticInitializer(item, type: element,
                                           address: address + offset * elementSize, location: listLocation)
                }
            case .structure(let name):
                guard let layout = types.structure(named: name) else { return }
                for (offset, item) in items.enumerated() where offset < layout.members.count {
                    let member = layout.members[offset]
                    writeStaticInitializer(item, type: member.type,
                                           address: address + member.offset, location: listLocation)
                }
            default:
                diagnostics.error("この型には { } の初期化子を使えません。", at: listLocation)
            }
        }
    }

    private func writeStatic(value: Int64, size: Int, at address: Int) {
        guard address >= 0, address + size <= staticData.count else { return }
        for offset in 0..<size {
            staticData[address + offset] = UInt8(truncatingIfNeeded: value >> (8 * offset))
        }
    }

    private func writeStaticDouble(_ value: Double, at address: Int) {
        writeStatic(value: Int64(bitPattern: value.bitPattern), size: 8, at: address)
    }

    /// 文字列リテラルを静的領域に置いてアドレスを返す。
    private func internString(_ text: String) -> Int {
        if let existing = stringLiterals[text] { return existing }
        let address = staticData.count
        staticData.append(contentsOf: Array(text.utf8))
        staticData.append(0)
        stringLiterals[text] = address
        return address
    }

    // MARK: - 定数式

    private enum ConstantValue {
        case integer(Int64)
        case floating(Double)
        case address(Int)
    }

    private func constantValue(_ expression: Expr) -> ConstantValue? {
        switch expression {
        case .integerLiteral(let value, _, _):
            return .integer(value)
        case .characterLiteral(let value, _):
            return .integer(value)
        case .floatingLiteral(let value, _):
            return .floating(value)
        case .stringLiteral(let text, _):
            return .address(internString(text))
        case .identifier(let name, _):
            if let value = types.enumConstant(named: name) { return .integer(value) }
            return nil
        case .sizeofType(let typeName, _):
            return .integer(Int64(types.size(of: resolveType(typeName))))
        case .cast(let typeName, let inner, _):
            guard let value = constantValue(inner) else { return nil }
            let target = resolveType(typeName)
            switch (value, target) {
            case (.integer(let number), .double): return .floating(Double(number))
            case (.floating(let number), let type) where type.isInteger: return .integer(Int64(number))
            default: return value
            }
        case .unary(let op, let operand, _):
            guard let value = constantValue(operand) else { return nil }
            switch (op, value) {
            case (.minus, .integer(let number)): return .integer(0 &- number)
            case (.minus, .floating(let number)): return .floating(-number)
            case (.plus, _): return value
            case (.bitwiseNot, .integer(let number)): return .integer(~number)
            case (.logicalNot, .integer(let number)): return .integer(number == 0 ? 1 : 0)
            default: return nil
            }
        case .binary(let op, let lhs, let rhs, _):
            guard let left = constantValue(lhs), let right = constantValue(rhs) else { return nil }
            if case .integer(let a) = left, case .integer(let b) = right {
                switch op {
                case .add: return .integer(a &+ b)
                case .subtract: return .integer(a &- b)
                case .multiply: return .integer(a &* b)
                case .divide: return b == 0 ? nil : .integer(a / b)
                case .remainder: return b == 0 ? nil : .integer(a % b)
                case .shiftLeft: return .integer(a << b)
                case .shiftRight: return .integer(a >> b)
                case .bitwiseAnd: return .integer(a & b)
                case .bitwiseOr: return .integer(a | b)
                case .bitwiseXor: return .integer(a ^ b)
                default: return nil
                }
            }
            let a = doubleValue(left)
            let b = doubleValue(right)
            switch op {
            case .add: return .floating(a + b)
            case .subtract: return .floating(a - b)
            case .multiply: return .floating(a * b)
            case .divide: return b == 0 ? nil : .floating(a / b)
            default: return nil
            }
        default:
            return nil
        }
    }

    private func doubleValue(_ value: ConstantValue) -> Double {
        switch value {
        case .integer(let number): return Double(number)
        case .floating(let number): return number
        case .address(let number): return Double(number)
        }
    }

    // MARK: - 命令の出力

    @discardableResult
    private func emit(_ instruction: Instruction, at location: SourceLocation) -> Int {
        instructions.append(instruction)
        lineNumbers.append(location.line)
        return instructions.count - 1
    }

    private func patch(_ index: Int, to target: Int) {
        guard index >= 0, index < instructions.count else { return }
        switch instructions[index] {
        case .jump: instructions[index] = .jump(target)
        case .jumpIfZero: instructions[index] = .jumpIfZero(target)
        case .jumpIfNotZero: instructions[index] = .jumpIfNotZero(target)
        default: break
        }
    }

    /// 型を知りたいだけのときに、出力を捨てて式を評価する。
    private func inferType(_ expression: Expr) -> CType {
        let instructionCount = instructions.count
        let lineCount = lineNumbers.count
        diagnostics.beginSuppression()
        let type = emitExpression(expression)
        diagnostics.endSuppression()
        instructions.removeLast(instructions.count - instructionCount)
        lineNumbers.removeLast(lineNumbers.count - lineCount)
        return type
    }

    // MARK: - 関数本体

    private func emitFunction(_ function: FunctionDeclaration) {
        guard let signature = signatures[function.name] else { return }
        let index = signature.index

        scopes = [[:]]
        frameSize = 0
        maximumFrameSize = 0
        currentReturnType = signature.returnType
        currentFunctionName = function.name
        labelPositions.removeAll()
        pendingGotos.removeAll()

        var parameterInfos: [ParameterInfo] = []
        for (position, parameter) in function.parameters.enumerated() {
            let declared = resolveType(parameter.type)
            let type = declared.decayed
            let size = types.size(of: type)
            let offset = allocateLocal(size: size, alignment: types.alignment(of: type))
            scopes[scopes.count - 1][parameter.name] = Symbol(type: type, storage: .local(offset))
            parameterInfos.append(ParameterInfo(offset: offset,
                                                size: size,
                                                isAggregate: type.isStructure,
                                                isDouble: type == .double))
            if parameter.name.isEmpty {
                diagnostics.warning("\(position + 1) 番目の引数に名前がありません。", at: parameter.location)
            }
        }

        let entry = instructions.count
        for statement in function.body ?? [] {
            emitStatement(statement)
        }

        // goto の飛び先を解決する
        for pending in pendingGotos {
            guard let target = labelPositions[pending.label] else {
                diagnostics.error("ラベル \(pending.label) が見つかりません。", at: pending.location)
                continue
            }
            patch(pending.patchIndex, to: target)
        }
        pendingGotos.removeAll()

        // 最後まで来たときの戻り。
        // 本体が return で終わっていて、関数の末尾に飛んでくるジャンプもなければ省く。
        let endsWithReturn = instructions.last == .returnValue || instructions.last == .returnVoid
        let hasJumpToEnd = instructions[entry...].contains { instruction in
            switch instruction {
            case .jump(let target), .jumpIfZero(let target), .jumpIfNotZero(let target):
                return target >= instructions.count
            default:
                return false
            }
        }
        if !endsWithReturn || hasJumpToEnd {
            if currentReturnType == .void {
                emit(.returnVoid, at: function.location)
            } else {
                emit(.pushInt(0), at: function.location)
                emit(.returnValue, at: function.location)
            }
        }

        functions[index] = FunctionInfo(name: function.name,
                                        entry: entry,
                                        frameSize: maximumFrameSize,
                                        parameters: parameterInfos,
                                        returnsVoid: currentReturnType == .void,
                                        returnsAggregate: currentReturnType.isStructure,
                                        returnSize: types.size(of: currentReturnType),
                                        isVariadic: signature.isVariadic)
        scopes = []
    }

    private func allocateLocal(size: Int, alignment: Int) -> Int {
        frameSize = TypeContext.align(frameSize, to: alignment)
        let offset = frameSize
        frameSize += max(size, 1)
        maximumFrameSize = max(maximumFrameSize, frameSize)
        return offset
    }

    private func lookup(_ name: String) -> Symbol? {
        for scope in scopes.reversed() {
            if let symbol = scope[name] { return symbol }
        }
        return globals[name]
    }

    // MARK: - 文

    private func emitStatement(_ statement: Stmt) {
        switch statement {
        case .expression(let expression, let location):
            guard let expression else { return }
            let type = emitExpression(expression)
            if type != .void {
                emit(.pop, at: location)
            }

        case .labeled(let label, let inner, let location):
            if labelPositions[label] != nil {
                diagnostics.error("ラベル \(label) が二重に定義されています。", at: location)
            }
            labelPositions[label] = instructions.count
            emitStatement(inner)

        case .gotoStmt(let label, let location):
            let index = emit(.jump(-1), at: location)
            pendingGotos.append((label: label, patchIndex: index, location: location))

        case .declaration(let variables, _):
            for variable in variables {
                emitLocalDeclaration(variable)
            }

        case .compound(let statements, _):
            let savedFrameSize = frameSize
            scopes.append([:])
            for inner in statements {
                emitStatement(inner)
            }
            scopes.removeLast()
            frameSize = savedFrameSize

        case .ifStmt(let condition, let then, let otherwise, let location):
            emitCondition(condition)
            let toElse = emit(.jumpIfZero(-1), at: location)
            emitStatement(then)
            if let otherwise {
                let toEnd = emit(.jump(-1), at: location)
                patch(toElse, to: instructions.count)
                emitStatement(otherwise)
                patch(toEnd, to: instructions.count)
            } else {
                patch(toElse, to: instructions.count)
            }

        case .whileStmt(let condition, let body, let location):
            let start = instructions.count
            emitCondition(condition)
            let toEnd = emit(.jumpIfZero(-1), at: location)
            loopContexts.append(JumpContext())
            emitStatement(body)
            let context = loopContexts.removeLast()
            emit(.jump(start), at: location)
            let end = instructions.count
            patch(toEnd, to: end)
            for index in context.breakPatches { patch(index, to: end) }
            for index in context.continuePatches { patch(index, to: start) }

        case .doWhile(let body, let condition, let location):
            let start = instructions.count
            loopContexts.append(JumpContext())
            emitStatement(body)
            let context = loopContexts.removeLast()
            let conditionStart = instructions.count
            emitCondition(condition)
            emit(.jumpIfNotZero(start), at: location)
            let end = instructions.count
            for index in context.breakPatches { patch(index, to: end) }
            for index in context.continuePatches { patch(index, to: conditionStart) }

        case .forStmt(let initializer, let condition, let step, let body, let location):
            let savedFrameSize = frameSize
            scopes.append([:])
            if let initializer { emitStatement(initializer) }
            let conditionStart = instructions.count
            var toEnd = -1
            if let condition {
                emitCondition(condition)
                toEnd = emit(.jumpIfZero(-1), at: location)
            }
            loopContexts.append(JumpContext())
            emitStatement(body)
            let context = loopContexts.removeLast()
            let stepStart = instructions.count
            if let step {
                let type = emitExpression(step)
                if type != .void { emit(.pop, at: location) }
            }
            emit(.jump(conditionStart), at: location)
            let end = instructions.count
            if toEnd >= 0 { patch(toEnd, to: end) }
            for index in context.breakPatches { patch(index, to: end) }
            for index in context.continuePatches { patch(index, to: stepStart) }
            scopes.removeLast()
            frameSize = savedFrameSize

        case .switchStmt(let subject, let cases, let location):
            emitSwitch(subject: subject, cases: cases, location: location)

        case .breakStmt(let location):
            let index = emit(.jump(-1), at: location)
            if !switchContexts.isEmpty, switchDepthIsInnermost() {
                switchContexts[switchContexts.count - 1].breakPatches.append(index)
            } else if !loopContexts.isEmpty {
                loopContexts[loopContexts.count - 1].breakPatches.append(index)
            } else {
                diagnostics.error("break はループか switch の中だけで使えます。", at: location)
            }

        case .continueStmt(let location):
            guard !loopContexts.isEmpty else {
                diagnostics.error("continue はループの中だけで使えます。", at: location)
                return
            }
            let index = emit(.jump(-1), at: location)
            loopContexts[loopContexts.count - 1].continuePatches.append(index)

        case .returnStmt(let value, let location):
            if let value {
                if currentReturnType == .void {
                    diagnostics.error("void を返す関数 \(currentFunctionName) で値を返しています。", at: location)
                    let type = emitExpression(value)
                    if type != .void { emit(.pop, at: location) }
                    emit(.returnVoid, at: location)
                    return
                }
                let type = emitExpression(value)
                if currentReturnType.isStructure {
                    if type != currentReturnType {
                        diagnostics.error("return の型が違います "
                                          + "(\(currentReturnType.description) ← \(type.description))。",
                                          at: location)
                    }
                } else {
                    convert(from: type, to: currentReturnType, at: location, context: "return")
                }
                emit(.returnValue, at: location)
            } else {
                if currentReturnType != .void {
                    diagnostics.warning("戻り値が必要な関数 \(currentFunctionName) で値を返していません。", at: location)
                    emit(.pushInt(0), at: location)
                    emit(.returnValue, at: location)
                    return
                }
                emit(.returnVoid, at: location)
            }
        }
    }

    /// break が switch とループのどちらに属するかの判定。
    /// switch を開いた時点のループの深さを覚えておき、それ以降にループが増えていなければ switch のもの。
    private var switchLoopDepths: [Int] = []

    private func switchDepthIsInnermost() -> Bool {
        guard let depth = switchLoopDepths.last else { return false }
        return loopContexts.count <= depth
    }

    private func emitSwitch(subject: Expr, cases: [SwitchCase], location: SourceLocation) {
        // 判定に使う値を一時領域へ保存する
        let slot = allocateLocal(size: 8, alignment: 8)
        emit(.pushLocal(slot), at: location)
        let subjectType = emitExpression(subject)
        guard subjectType.isInteger || subjectType.isPointer else {
            diagnostics.error("switch には整数を指定してください。", at: location)
            emit(.storeDrop(size: 8), at: location)
            return
        }
        emit(.storeDrop(size: 8), at: location)

        var caseJumps: [(caseIndex: Int, patch: Int)] = []
        var defaultPatch: Int?

        for (offset, switchCase) in cases.enumerated() {
            guard let value = switchCase.value else { continue }
            guard let constant = constantValue(value), case .integer(let number) = constant else {
                diagnostics.error("case のラベルは定数でなければなりません。", at: switchCase.location)
                continue
            }
            emit(.pushLocal(slot), at: switchCase.location)
            emit(.load(size: 8, signed: true), at: switchCase.location)
            emit(.pushInt(number), at: switchCase.location)
            emit(.compareInt(.equal), at: switchCase.location)
            caseJumps.append((offset, emit(.jumpIfNotZero(-1), at: switchCase.location)))
        }
        if cases.contains(where: { $0.value == nil }) {
            defaultPatch = emit(.jump(-1), at: location)
        }
        let toEnd = emit(.jump(-1), at: location)

        switchContexts.append(JumpContext())
        switchLoopDepths.append(loopContexts.count)

        var caseStarts: [Int: Int] = [:]
        for (offset, switchCase) in cases.enumerated() {
            caseStarts[offset] = instructions.count
            if switchCase.value == nil, let defaultPatch {
                patch(defaultPatch, to: instructions.count)
            }
            let savedFrameSize = frameSize
            scopes.append([:])
            for statement in switchCase.body {
                emitStatement(statement)
            }
            scopes.removeLast()
            frameSize = savedFrameSize
        }

        let end = instructions.count
        patch(toEnd, to: end)
        for (caseIndex, patchIndex) in caseJumps {
            patch(patchIndex, to: caseStarts[caseIndex] ?? end)
        }
        let context = switchContexts.removeLast()
        switchLoopDepths.removeLast()
        for index in context.breakPatches { patch(index, to: end) }
    }

    private func emitLocalDeclaration(_ variable: VariableDeclaration) {
        var type = resolveType(variable.type)

        if case .array(let element, let count) = type, count == 0 {
            if case .list(let items, _)? = variable.initializer {
                type = .array(element, count: items.count)
            } else if case .expression(.stringLiteral(let text, _))? = variable.initializer {
                type = .array(element, count: text.utf8.count + 1)
            }
        }

        if type == .void {
            diagnostics.error("void 型の変数は作れません: \(variable.name)", at: variable.location)
            return
        }
        if case .structure(let name) = type, types.structure(named: name)?.members.isEmpty != false {
            diagnostics.error("中身の分からない構造体です: struct \(name)", at: variable.location)
        }

        if variable.isStatic {
            // 静的領域に置いて、関数を抜けても値が残るようにする
            let size = types.size(of: type)
            let alignment = types.alignment(of: type)
            let address = TypeContext.align(staticData.count, to: alignment)
            staticData.append(contentsOf: Array(repeating: 0, count: address - staticData.count + size))
            if let initializer = variable.initializer {
                writeStaticInitializer(initializer, type: type, address: address, location: variable.location)
            }
            scopes[scopes.count - 1][variable.name] = Symbol(type: type, storage: .global(address))
            return
        }
        let size = types.size(of: type)
        let offset = allocateLocal(size: size, alignment: types.alignment(of: type))
        if scopes[scopes.count - 1][variable.name] != nil {
            diagnostics.error("変数 \(variable.name) が同じブロックで二重に宣言されています。", at: variable.location)
        }
        scopes[scopes.count - 1][variable.name] = Symbol(type: type, storage: .local(offset))

        guard let initializer = variable.initializer else { return }
        emitInitializer(initializer, type: type, base: .pushLocal(offset), offset: 0,
                        location: variable.location)
    }

    /// 初期化子を base + offset のアドレスに書き込む。
    private func emitInitializer(_ initializer: Initializer, type: CType,
                                 base: Instruction, offset: Int, location: SourceLocation) {
        switch initializer {
        case .expression(let expression):
            // char 配列 = 文字列リテラル
            if case .array(let element, let count) = type, element == .char,
               case .stringLiteral(let text, let stringLocation) = expression {
                let address = internString(text)
                emitAddress(base: base, offset: offset, at: stringLocation)
                emit(.pushGlobal(address), at: stringLocation)
                emit(.memcopyDrop(size: min(count, text.utf8.count + 1)), at: stringLocation)
                return
            }
            if type.isStructure || type.isArray {
                emitAddress(base: base, offset: offset, at: location)
                let valueType = emitExpression(expression)
                if valueType == type {
                    emit(.memcopyDrop(size: types.size(of: type)), at: location)
                } else {
                    diagnostics.error("この初期化の書き方には対応していません "
                                      + "(\(type.description) ← \(valueType.description))。", at: location)
                    emit(.pop, at: location)
                    emit(.pop, at: location)
                }
                return
            }
            emitAddress(base: base, offset: offset, at: location)
            let valueType = emitExpression(expression)
            convert(from: valueType, to: type, at: location, context: "初期化")
            emitStore(type: type, drop: true, at: location)

        case .list(let items, let listLocation):
            switch type {
            case .array(let element, let count):
                let elementSize = types.size(of: element)
                // 書かれなかった部分は 0 にする
                emitAddress(base: base, offset: offset, at: listLocation)
                emit(.fillZero(size: types.size(of: type)), at: listLocation)
                if items.count > count {
                    diagnostics.warning("初期化子が配列の要素数より多いです。", at: listLocation)
                }
                for (position, item) in items.prefix(count).enumerated() {
                    emitInitializer(item, type: element, base: base,
                                    offset: offset + position * elementSize, location: listLocation)
                }
            case .structure(let name):
                guard let layout = types.structure(named: name) else { return }
                emitAddress(base: base, offset: offset, at: listLocation)
                emit(.fillZero(size: layout.size), at: listLocation)
                if items.count > layout.members.count {
                    diagnostics.warning("初期化子がメンバーの数より多いです。", at: listLocation)
                }
                for (position, item) in items.enumerated() where position < layout.members.count {
                    let member = layout.members[position]
                    emitInitializer(item, type: member.type, base: base,
                                    offset: offset + member.offset, location: listLocation)
                }
            default:
                diagnostics.error("この型には { } の初期化子を使えません。", at: listLocation)
            }
        }
    }

    /// base (グローバル/ローカルのアドレス) に offset を足したアドレスを積む。
    private func emitAddress(base: Instruction, offset: Int, at location: SourceLocation) {
        emit(base, at: location)
        if offset != 0 {
            emit(.pushInt(Int64(offset)), at: location)
            emit(.addInt, at: location)
        }
    }

    // MARK: - 式

    /// 条件として使う値を積む (double は 0 との比較に変換する)。
    private func emitCondition(_ expression: Expr) {
        let type = emitExpression(expression)
        makeTruthValue(type, at: expression.location)
    }

    private func makeTruthValue(_ type: CType, at location: SourceLocation) {
        switch type {
        case .double:
            emit(.pushDouble(0), at: location)
            emit(.compareDouble(.notEqual), at: location)
        case .void:
            diagnostics.error("void は条件に使えません。", at: location)
        default:
            break
        }
    }

    /// 式を評価して値をスタックに積み、その型を返す。
    @discardableResult
    private func emitExpression(_ expression: Expr) -> CType {
        switch expression {
        case .integerLiteral(let value, let isLong, let location):
            emit(.pushInt(value), at: location)
            return isLong ? .long : .int

        case .characterLiteral(let value, let location):
            emit(.pushInt(value), at: location)
            return .int

        case .floatingLiteral(let value, let location):
            emit(.pushDouble(value), at: location)
            return .double

        case .stringLiteral(let text, let location):
            emit(.pushGlobal(internString(text)), at: location)
            return .pointer(.char)

        case .identifier(let name, let location):
            if let value = types.enumConstant(named: name) {
                emit(.pushInt(value), at: location)
                return .int
            }
            if let symbol = lookup(name) {
                emitAddressOf(symbol, at: location)
                if symbol.type.isArray || symbol.type.isStructure {
                    return symbol.type // 配列と構造体はアドレスをそのまま値として扱う
                }
                emitLoad(type: symbol.type, at: location)
                return symbol.type
            }
            // 関数名は関数ポインタとして扱える
            if let signature = signatures[name] {
                emit(.pushFunction(signature.index), at: location)
                return .pointer(.function(returns: signature.returnType,
                                          parameters: signature.parameterTypes,
                                          isVariadic: signature.isVariadic))
            }
            diagnostics.error("知らない名前です: \(name)", at: location)
            emit(.pushInt(0), at: location)
            return .int

        case .unary(let op, let operand, let location):
            return emitUnary(op, operand, location)

        case .postfix(let op, let operand, let location):
            return emitPostfix(op, operand, location)

        case .binary(let op, let lhs, let rhs, let location):
            return emitBinary(op, lhs, rhs, location)

        case .assignment(let op, let target, let value, let location):
            return emitAssignment(op, target, value, location)

        case .conditional(let condition, let then, let otherwise, let location):
            return emitConditional(condition, then, otherwise, location)

        case .call(let callee, let arguments, let location):
            return emitCall(callee, arguments, location)

        case .subscriptExpr, .member:
            let type = emitAddressExpression(expression)
            if type.isArray || type.isStructure { return type }
            emitLoad(type: type, at: expression.location)
            return type

        case .cast(let typeName, let inner, let location):
            let target = resolveType(typeName)
            let sourceType = emitExpression(inner)
            convert(from: sourceType, to: target, at: location, context: "型変換", isExplicit: true)
            return target

        case .sizeofType(let typeName, let location):
            emit(.pushInt(Int64(types.size(of: resolveType(typeName)))), at: location)
            return .long

        case .vaArg(let list, let typeName, let location):
            let type = resolveType(typeName)
            _ = emitAddressExpression(list)
            emit(.vaArg(isDouble: type == .double), at: location)
            if type.isInteger, types.size(of: type) < 8 {
                emit(.truncate(size: types.size(of: type), signed: !type.isUnsigned), at: location)
            }
            return type

        case .sizeofExpr(let inner, let location):
            let type = inferType(inner)
            emit(.pushInt(Int64(types.size(of: type))), at: location)
            return .long

        case .comma(let first, let second, let location):
            let firstType = emitExpression(first)
            if firstType != .void { emit(.pop, at: location) }
            return emitExpression(second)
        }
    }

    private func emitAddressOf(_ symbol: Symbol, at location: SourceLocation) {
        switch symbol.storage {
        case .global(let address):
            emit(.pushGlobal(address), at: location)
        case .local(let offset):
            emit(.pushLocal(offset), at: location)
        }
    }

    /// 左辺値のアドレスを積み、その (配列のままの) 型を返す。
    @discardableResult
    private func emitAddressExpression(_ expression: Expr) -> CType {
        switch expression {
        case .identifier(let name, let location):
            guard let symbol = lookup(name) else {
                diagnostics.error("知らない名前です: \(name)", at: location)
                emit(.pushInt(0), at: location)
                return .int
            }
            emitAddressOf(symbol, at: location)
            return symbol.type

        case .unary(.dereference, let operand, let location):
            let type = emitExpression(operand)
            guard let pointee = type.pointee else {
                diagnostics.error("ポインタではない値に * は使えません (\(type.description))。", at: location)
                return .int
            }
            return pointee

        case .subscriptExpr(let base, let indexExpression, let location):
            let baseType = emitExpression(base)
            guard let element = baseType.pointee else {
                diagnostics.error("配列でもポインタでもない値に [] は使えません (\(baseType.description))。",
                                  at: location)
                return .int
            }
            let indexType = emitExpression(indexExpression)
            guard indexType.isInteger else {
                diagnostics.error("添字には整数を指定してください。", at: location)
                return element
            }
            let size = types.size(of: element)
            if size != 1 {
                emit(.pushInt(Int64(size)), at: location)
                emit(.mulInt, at: location)
            }
            emit(.addInt, at: location)
            return element

        case .member(let base, let name, let isArrow, let location):
            var structureType: CType
            if isArrow {
                let pointerType = emitExpression(base)
                guard let pointee = pointerType.pointee else {
                    diagnostics.error("-> の左側はポインタでなければなりません。", at: location)
                    return .int
                }
                structureType = pointee
            } else {
                switch base {
                case .identifier, .subscriptExpr, .member, .unary(.dereference, _, _):
                    structureType = emitAddressExpression(base)
                default:
                    // 関数の戻り値など、その場限りの構造体。値 (アドレス) をそのまま使う
                    structureType = emitExpression(base)
                }
            }
            guard case .structure(let structureName) = structureType,
                  let layout = types.structure(named: structureName) else {
                diagnostics.error("構造体ではない値のメンバーを参照しています (\(structureType.description))。",
                                  at: location)
                return .int
            }
            guard let member = layout.member(named: name) else {
                diagnostics.error("struct \(structureName) にメンバー \(name) はありません。", at: location)
                return .int
            }
            if member.offset != 0 {
                emit(.pushInt(Int64(member.offset)), at: location)
                emit(.addInt, at: location)
            }
            return member.type

        default:
            diagnostics.error("この式には代入できません。", at: expression.location)
            _ = emitExpression(expression)
            return .int
        }
    }

    private func emitLoad(type: CType, at location: SourceLocation) {
        switch type {
        case .double:
            emit(.loadDouble, at: location)
        case .array, .structure, .function:
            break // アドレスがそのまま値
        default:
            emit(.load(size: types.size(of: type), signed: !type.isUnsigned), at: location)
        }
    }

    private func emitStore(type: CType, drop: Bool, at location: SourceLocation) {
        switch type {
        case .double:
            emit(drop ? .storeDoubleDrop : .storeDouble, at: location)
        case .structure, .array:
            let size = types.size(of: type)
            emit(drop ? .memcopyDrop(size: size) : .memcopy(size: size), at: location)
        default:
            let size = types.size(of: type)
            emit(drop ? .storeDrop(size: size) : .store(size: size), at: location)
        }
    }

    // MARK: - 単項演算

    private func emitUnary(_ op: UnaryOperator, _ operand: Expr, _ location: SourceLocation) -> CType {
        switch op {
        case .plus:
            let type = emitExpression(operand)
            return types.promote(type)

        case .minus:
            let type = emitExpression(operand)
            if type == .double {
                emit(.negDouble, at: location)
                return .double
            }
            guard type.isInteger else {
                diagnostics.error("数値ではない値に - は使えません (\(type.description))。", at: location)
                return type
            }
            emit(.negInt, at: location)
            return types.promote(type)

        case .logicalNot:
            let type = emitExpression(operand)
            makeTruthValue(type, at: location)
            emit(.logicalNot, at: location)
            return .int

        case .bitwiseNot:
            let type = emitExpression(operand)
            guard type.isInteger else {
                diagnostics.error("整数ではない値に ~ は使えません (\(type.description))。", at: location)
                return .int
            }
            emit(.bitNot, at: location)
            return types.promote(type)

        case .addressOf:
            let type = emitAddressExpression(operand)
            return .pointer(type)

        case .dereference:
            let type = emitAddressExpression(.unary(.dereference, operand, location))
            if type.isArray || type.isStructure { return type }
            emitLoad(type: type, at: location)
            return type

        case .preIncrement, .preDecrement:
            let type = emitAddressExpression(operand)
            guard type.isArithmetic || type.isPointer else {
                diagnostics.error("この型には ++ / -- を使えません (\(type.description))。", at: location)
                return type
            }
            emit(.dup, at: location)
            emitLoad(type: type, at: location)
            emitStepValue(type: type, isIncrement: op == .preIncrement, at: location)
            emitStore(type: type, drop: false, at: location)
            return type
        }
    }

    private func emitPostfix(_ op: PostfixOperator, _ operand: Expr, _ location: SourceLocation) -> CType {
        let type = emitAddressExpression(operand)
        guard type.isArithmetic || type.isPointer else {
            diagnostics.error("この型には ++ / -- を使えません (\(type.description))。", at: location)
            return type
        }
        emit(.dup, at: location)                 // [addr, addr]
        emitLoad(type: type, at: location)       // [addr, 値]
        emit(.dupX1, at: location)               // [値, addr, 値]
        emitStepValue(type: type, isIncrement: op == .increment, at: location)
        emitStore(type: type, drop: true, at: location) // [値]
        return type
    }

    /// ++ / -- の加算部分。ポインタなら要素サイズ分動かす。
    private func emitStepValue(type: CType, isIncrement: Bool, at location: SourceLocation) {
        if type == .double {
            emit(.pushDouble(1), at: location)
            emit(isIncrement ? .addDouble : .subDouble, at: location)
            return
        }
        var step = 1
        if case .pointer(let element) = type {
            step = max(1, types.size(of: element))
        }
        emit(.pushInt(Int64(step)), at: location)
        emit(isIncrement ? .addInt : .subInt, at: location)
        if type.isInteger, types.size(of: type) < 8 {
            emit(.truncate(size: types.size(of: type), signed: !type.isUnsigned), at: location)
        }
    }

    // MARK: - 二項演算

    private func emitBinary(_ op: BinaryOperator, _ lhs: Expr, _ rhs: Expr,
                            _ location: SourceLocation) -> CType {
        if op == .logicalAnd || op == .logicalOr {
            return emitLogical(op, lhs, rhs, location)
        }

        let leftType = emitExpression(lhs).decayed

        // ポインタ演算
        if leftType.isPointer, op == .add || op == .subtract {
            let rightType = emitExpression(rhs).decayed
            if rightType.isPointer {
                guard op == .subtract else {
                    diagnostics.error("ポインタ同士を足すことはできません。", at: location)
                    return leftType
                }
                emit(.subInt, at: location)
                let size = max(1, types.size(of: leftType.pointee ?? .char))
                if size != 1 {
                    emit(.pushInt(Int64(size)), at: location)
                    emit(.divInt, at: location)
                }
                return .long
            }
            guard rightType.isInteger else {
                diagnostics.error("ポインタに足せるのは整数だけです。", at: location)
                return leftType
            }
            let size = max(1, types.size(of: leftType.pointee ?? .char))
            if size != 1 {
                emit(.pushInt(Int64(size)), at: location)
                emit(.mulInt, at: location)
            }
            emit(op == .add ? .addInt : .subInt, at: location)
            return leftType
        }

        // 整数 + ポインタ
        if leftType.isInteger, op == .add {
            let rightType = inferType(rhs).decayed
            if rightType.isPointer {
                let size = max(1, types.size(of: rightType.pointee ?? .char))
                if size != 1 {
                    emit(.pushInt(Int64(size)), at: location)
                    emit(.mulInt, at: location)
                }
                _ = emitExpression(rhs)
                emit(.addInt, at: location)
                return rightType
            }
        }

        let rightType = emitExpression(rhs).decayed

        // ポインタ同士の比較
        if leftType.isPointer || rightType.isPointer {
            guard op.isComparison else {
                diagnostics.error("ポインタにこの演算子は使えません: \(op.rawValue)", at: location)
                return .int
            }
            emit(.compareInt(comparison(for: op)), at: location)
            return .int
        }

        guard leftType.isArithmetic, rightType.isArithmetic else {
            diagnostics.error("この型には \(op.rawValue) を使えません "
                              + "(\(leftType.description) と \(rightType.description))。", at: location)
            return .int
        }

        var resultType = types.usualArithmeticConversion(types.promote(leftType), types.promote(rightType))
        if op.isBitwise, resultType == .double {
            diagnostics.error("浮動小数点数には \(op.rawValue) を使えません。", at: location)
            resultType = .long
        }

        // 左辺を先に積んでいるので、必要なら右辺だけ変換してから左辺を合わせる
        if resultType == .double {
            if rightType != .double {
                emit(.intToDouble, at: location)
            }
            if leftType != .double {
                // 左辺は下にあるので、入れ替えてから変換する
                emit(.dupX1, at: location)  // [右, 左, 右]
                emit(.pop, at: location)    // [右, 左]
                emit(.intToDouble, at: location)
                emit(.dupX1, at: location)  // [左, 右, 左]
                emit(.pop, at: location)    // [左, 右]
            }
        }

        if op.isComparison {
            if resultType == .double {
                emit(.compareDouble(comparison(for: op)), at: location)
            } else if resultType.isUnsigned {
                emit(.compareUInt(comparison(for: op)), at: location)
            } else {
                emit(.compareInt(comparison(for: op)), at: location)
            }
            return .int
        }

        emitArithmetic(op, resultType: resultType, at: location)

        if resultType.isInteger, types.size(of: resultType) < 8 {
            emit(.truncate(size: types.size(of: resultType), signed: !resultType.isUnsigned), at: location)
        }
        return resultType
    }

    /// 加減乗除などの本体を、型に合わせた命令で出す。
    private func emitArithmetic(_ op: BinaryOperator, resultType: CType, at location: SourceLocation) {
        let isDouble = resultType == .double
        let isUnsigned = resultType.isUnsigned
        switch op {
        case .add: emit(isDouble ? .addDouble : .addInt, at: location)
        case .subtract: emit(isDouble ? .subDouble : .subInt, at: location)
        case .multiply: emit(isDouble ? .mulDouble : .mulInt, at: location)
        case .divide: emit(isDouble ? .divDouble : (isUnsigned ? .divUInt : .divInt), at: location)
        case .remainder: emit(isUnsigned ? .remUInt : .remInt, at: location)
        case .shiftLeft: emit(.shiftLeft, at: location)
        case .shiftRight: emit(isUnsigned ? .shiftRightUnsigned : .shiftRight, at: location)
        case .bitwiseAnd: emit(.bitAnd, at: location)
        case .bitwiseOr: emit(.bitOr, at: location)
        case .bitwiseXor: emit(.bitXor, at: location)
        default:
            diagnostics.error("この演算子には対応していません: \(op.rawValue)", at: location)
        }
    }

    private func comparison(for op: BinaryOperator) -> Comparison {
        switch op {
        case .less: return .less
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .greaterEqual: return .greaterEqual
        case .equal: return .equal
        default: return .notEqual
        }
    }

    private func emitLogical(_ op: BinaryOperator, _ lhs: Expr, _ rhs: Expr,
                             _ location: SourceLocation) -> CType {
        emitCondition(lhs)
        let shortCircuit = emit(op == .logicalAnd ? .jumpIfZero(-1) : .jumpIfNotZero(-1), at: location)
        emitCondition(rhs)
        emit(.pushInt(0), at: location)
        emit(.compareInt(.notEqual), at: location)
        let toEnd = emit(.jump(-1), at: location)
        patch(shortCircuit, to: instructions.count)
        emit(.pushInt(op == .logicalAnd ? 0 : 1), at: location)
        patch(toEnd, to: instructions.count)
        return .int
    }

    // MARK: - 代入

    private func emitAssignment(_ op: BinaryOperator?, _ target: Expr, _ value: Expr,
                                _ location: SourceLocation) -> CType {
        let targetType = emitAddressExpression(target)

        // 構造体の代入はまるごとコピー
        if targetType.isStructure {
            guard op == nil else {
                diagnostics.error("構造体には \(op?.rawValue ?? "") を使えません。", at: location)
                return targetType
            }
            let valueType = emitExpression(value)
            guard valueType == targetType else {
                diagnostics.error("違う型の構造体は代入できません "
                                  + "(\(targetType.description) ← \(valueType.description))。", at: location)
                return targetType
            }
            emit(.memcopy(size: types.size(of: targetType)), at: location)
            return targetType
        }

        if targetType.isArray {
            diagnostics.error("配列そのものには代入できません。", at: location)
            return targetType
        }

        guard let op else {
            let valueType = emitExpression(value)
            convert(from: valueType, to: targetType, at: location, context: "代入")
            emitStore(type: targetType, drop: false, at: location)
            return targetType
        }

        // 複合代入: addr を複製して読み込み、演算してから書き戻す
        emit(.dup, at: location)
        emitLoad(type: targetType, at: location)

        // ポインタ += 整数
        if targetType.isPointer {
            guard op == .add || op == .subtract else {
                diagnostics.error("ポインタには \(op.rawValue)= を使えません。", at: location)
                return targetType
            }
            let valueType = emitExpression(value)
            guard valueType.isInteger else {
                diagnostics.error("ポインタに足せるのは整数だけです。", at: location)
                return targetType
            }
            let size = max(1, types.size(of: targetType.pointee ?? .char))
            if size != 1 {
                emit(.pushInt(Int64(size)), at: location)
                emit(.mulInt, at: location)
            }
            emit(op == .add ? .addInt : .subInt, at: location)
            emitStore(type: targetType, drop: false, at: location)
            return targetType
        }

        let valueType = emitExpression(value).decayed
        let operationType = types.usualArithmeticConversion(types.promote(targetType), types.promote(valueType))

        if operationType == .double {
            if valueType != .double { emit(.intToDouble, at: location) }
            if targetType != .double {
                emit(.dupX1, at: location)
                emit(.pop, at: location)
                emit(.intToDouble, at: location)
                emit(.dupX1, at: location)
                emit(.pop, at: location)
            }
        } else if valueType == .double {
            emit(.doubleToInt, at: location)
        }

        emitArithmetic(op, resultType: operationType, at: location)

        convert(from: operationType, to: targetType, at: location, context: "代入")
        emitStore(type: targetType, drop: false, at: location)
        return targetType
    }

    private func emitConditional(_ condition: Expr, _ then: Expr, _ otherwise: Expr,
                                 _ location: SourceLocation) -> CType {
        let thenType = inferType(then).decayed
        let otherwiseType = inferType(otherwise).decayed
        var resultType = thenType
        if thenType.isArithmetic, otherwiseType.isArithmetic {
            resultType = types.usualArithmeticConversion(types.promote(thenType), types.promote(otherwiseType))
        } else if thenType == .void || otherwiseType == .void {
            resultType = .void
        }

        emitCondition(condition)
        let toOtherwise = emit(.jumpIfZero(-1), at: location)
        let actualThen = emitExpression(then)
        if resultType != .void {
            convert(from: actualThen, to: resultType, at: location, context: "三項演算子")
        }
        let toEnd = emit(.jump(-1), at: location)
        patch(toOtherwise, to: instructions.count)
        let actualOtherwise = emitExpression(otherwise)
        if resultType != .void {
            convert(from: actualOtherwise, to: resultType, at: location, context: "三項演算子")
        }
        patch(toEnd, to: instructions.count)
        return resultType
    }

    // MARK: - 関数呼び出し

    private func emitCall(_ callee: Expr, _ arguments: [Expr], _ location: SourceLocation) -> CType {
        if case .identifier(let name, _) = callee {
            // va_start / va_end はその場で処理する
            if name == "va_start" {
                if let first = arguments.first {
                    _ = emitAddressExpression(first)
                    emit(.pushInt(0), at: location)
                    emit(.storeDrop(size: 8), at: location)
                } else {
                    diagnostics.error("va_start には引数が必要です。", at: location)
                }
                return .void
            }
            if name == "va_end" {
                return .void
            }
            if let builtin = Builtin.lookup[name], lookup(name) == nil {
                return emitBuiltinCall(builtin, arguments, location)
            }
            if lookup(name) == nil, let signature = signatures[name] {
                return emitDirectCall(name: name, signature: signature, arguments: arguments, location: location)
            }
        }

        // 関数ポインタ経由の呼び出し
        let calleeType = inferType(callee).decayed
        guard case .pointer(let pointee) = calleeType,
              case .function(let returns, let parameterTypes, let isVariadic) = pointee else {
            if case .identifier(let name, _) = callee {
                diagnostics.error("知らない関数です: \(name)", at: location)
            } else {
                diagnostics.error("関数ではないものを呼び出しています (\(calleeType.description))。", at: location)
            }
            for argument in arguments {
                let type = emitExpression(argument)
                if type != .void { emit(.pop, at: location) }
            }
            emit(.pushInt(0), at: location)
            return .int
        }

        if arguments.count != parameterTypes.count, !isVariadic {
            diagnostics.error("この関数ポインタの引数は \(parameterTypes.count) 個ですが "
                              + "\(arguments.count) 個渡されています。", at: location)
        }
        var hiddenCount = 0
        var temporary = -1
        if returns.isStructure {
            temporary = allocateLocal(size: types.size(of: returns), alignment: types.alignment(of: returns))
            emit(.pushLocal(temporary), at: location)
            hiddenCount = 1
        }
        for (position, argument) in arguments.enumerated() {
            let actual = emitExpression(argument)
            if position < parameterTypes.count {
                let expected = parameterTypes[position]
                if !expected.isStructure {
                    convert(from: actual, to: expected, at: location, context: "引数")
                }
            } else if actual == .char || actual == .uchar {
                emit(.truncate(size: 4, signed: actual == .char), at: location)
            }
        }
        _ = emitExpression(callee)
        emit(.callIndirect(argumentCount: arguments.count + hiddenCount), at: location)
        return returns
    }

    /// 名前の分かっている関数の呼び出し。
    private func emitDirectCall(name: String, signature: FunctionSignature,
                                arguments: [Expr], location: SourceLocation) -> CType {
        if arguments.count != signature.parameterTypes.count, !signature.isVariadic {
            diagnostics.error("\(name) の引数は \(signature.parameterTypes.count) 個ですが "
                              + "\(arguments.count) 個渡されています。", at: location)
        }

        // 構造体を返す関数は、置き場所のアドレスを最初に渡す
        var hiddenCount = 0
        if signature.returnType.isStructure {
            let size = types.size(of: signature.returnType)
            let temporary = allocateLocal(size: size, alignment: types.alignment(of: signature.returnType))
            emit(.pushLocal(temporary), at: location)
            hiddenCount = 1
        }

        for (position, argument) in arguments.enumerated() {
            let expected = position < signature.parameterTypes.count ? signature.parameterTypes[position] : nil
            let actual = emitExpression(argument)
            if let expected {
                if expected.isStructure {
                    if actual != expected {
                        diagnostics.error("\(name) の \(position + 1) 番目の引数の型が違います "
                                          + "(\(expected.description) ← \(actual.description))。", at: location)
                    }
                } else {
                    convert(from: actual, to: expected, at: location, context: "\(name) の引数")
                }
            } else if actual == .char || actual == .uchar {
                emit(.truncate(size: 4, signed: actual == .char), at: location)
            }
        }

        emit(.call(function: signature.index, argumentCount: arguments.count + hiddenCount), at: location)
        return signature.returnType
    }

    private func emitBuiltinCall(_ builtin: Builtin, _ arguments: [Expr],
                                 _ location: SourceLocation) -> CType {
        let signature = builtin.signature
        if arguments.count < signature.parameters.count
            || (!signature.isVariadic && arguments.count != signature.parameters.count) {
            diagnostics.error("\(builtin.name) の引数の数が合いません "
                              + "(\(signature.parameters.count) 個必要、\(arguments.count) 個渡されています)。",
                              at: location)
        }

        for (position, argument) in arguments.enumerated() {
            let actual = emitExpression(argument).decayed
            if position < signature.parameters.count {
                let expected = signature.parameters[position]
                if expected == .double, actual.isInteger {
                    emit(.intToDouble, at: location)
                } else if expected.isInteger, actual == .double {
                    emit(.doubleToInt, at: location)
                }
            } else if actual == .char || actual == .uchar {
                // 可変長引数の既定の格上げ
                emit(.truncate(size: 4, signed: actual == .char), at: location)
            }
        }

        emit(.callBuiltin(builtin: builtin.rawValue, argumentCount: arguments.count), at: location)
        return signature.returnType
    }

    // MARK: - 型変換

    private func convert(from source: CType, to target: CType, at location: SourceLocation,
                         context: String, isExplicit: Bool = false) {
        let from = source.decayed
        let to = target.decayed
        if from == to { return }

        if to == .void { return }

        if from == .double, to.isInteger {
            emit(.doubleToInt, at: location)
            if types.size(of: to) < 8 {
                emit(.truncate(size: types.size(of: to), signed: !to.isUnsigned), at: location)
            }
            return
        }
        if from.isInteger, to == .double {
            emit(from == .ulong ? .unsignedToDouble : .intToDouble, at: location)
            return
        }
        if from.isInteger, to.isInteger {
            if types.size(of: to) < 8 {
                emit(.truncate(size: types.size(of: to), signed: !to.isUnsigned), at: location)
            } else if to.isUnsigned != from.isUnsigned, types.size(of: from) < 8 {
                emit(.truncate(size: types.size(of: from), signed: !to.isUnsigned), at: location)
            }
            return
        }
        if from.isPointer, to.isPointer { return }
        if from.isPointer, to.isInteger {
            if !isExplicit {
                diagnostics.warning("\(context): ポインタを整数に変換しています。", at: location)
            }
            return
        }
        if from.isInteger, to.isPointer {
            if !isExplicit {
                diagnostics.warning("\(context): 整数をポインタに変換しています。", at: location)
            }
            return
        }
        if from == .double, to.isPointer {
            diagnostics.error("\(context): 小数をポインタには変換できません。", at: location)
            return
        }

        diagnostics.error("\(context): 型が合いません (\(to.description) ← \(from.description))。", at: location)
    }
}
