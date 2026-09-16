import Foundation

/// 共通の木たどり評価器。
///
/// 26 言語ぶんのフロントエンド (字句解析 + 構文解析) が `MLProgram` を作り、
/// 実行はすべてこのクラスが行う。言語ごとの違いは `MLSemantics` 経由で差し込む。
public final class MLInterpreter {
    public let semantics: MLSemantics
    public let limits: MiniLangLimits
    public let output: MiniLangOutput
    public let input: MiniLangInput
    public let globals: MLEnvironment
    /// 宣言された型 (名前で引く)。
    public private(set) var classes: [String: MLClass] = [:]
    /// 列挙のケース名から所属クラスを引く表 (`.some` のような省略記法用)。
    private var caseOwners: [String: MLClass] = [:]

    private var stepCount = 0
    private var callDepth = 0
    public var exitCode: Int32 = 0
    /// 言語フロントエンドが自由に使える置き場。
    public var userInfo: [String: Any] = [:]

    public init(semantics: MLSemantics, limits: MiniLangLimits = .default, input: String = "") {
        self.semantics = semantics
        self.limits = limits
        self.output = MiniLangOutput(limit: limits.maximumOutputBytes)
        self.input = MiniLangInput(input)
        self.globals = MLEnvironment(isFunctionScope: true)
    }

    // MARK: - 実行の入口

    public func run(_ program: MLProgram) -> MiniLangExecution {
        semantics.installBuiltins(into: globals, interpreter: self)
        do {
            try semantics.prepare(program: program, interpreter: self)
            try hoist(program.statements, in: globals)
            try execute(program.statements, in: globals)
            if let entry = semantics.entryPoint(for: program) {
                try callEntryPoint(name: entry.name, typeName: entry.typeName)
            }
            semantics.finish(interpreter: self)
            return MiniLangExecution(parsed: true, output: output.text, exitCode: exitCode)
        } catch let error as MLError {
            if case .exit(let code) = error {
                semantics.finish(interpreter: self)
                return MiniLangExecution(parsed: true, output: output.text, exitCode: code)
            }
            semantics.finish(interpreter: self)
            return MiniLangExecution(parsed: true, output: output.text,
                                     runtimeError: error.message, exitCode: 1)
        } catch let control as MLControl {
            semantics.finish(interpreter: self)
            if case .returnValue(let value) = control {
                let code = value.asInt.map { Int32(truncatingIfNeeded: $0) } ?? 0
                return MiniLangExecution(parsed: true, output: output.text, exitCode: code)
            }
            return MiniLangExecution(parsed: true, output: output.text,
                                     runtimeError: "ループの外で break / continue が使われました",
                                     exitCode: 1)
        } catch {
            semantics.finish(interpreter: self)
            return MiniLangExecution(parsed: true, output: output.text,
                                     runtimeError: "内部エラー: \(error)", exitCode: 1)
        }
    }

    private func callEntryPoint(name: String, typeName: String?) throws {
        if let typeName, let klass = classes[typeName] {
            if let found = klass.findStaticMethod(name) {
                _ = try invoke(found.decls, receiver: nil, owner: found.owner,
                               arguments: [.array(MLArray())], labels: [nil], boxes: [nil],
                               closure: klass.declarationEnvironment ?? globals,
                               location: found.decls[0].location)
                return
            }
            if let found = klass.findMethod(name) {
                let instance = try instantiate(klass, arguments: [], labels: [],
                                               location: found.decls[0].location)
                _ = try invoke(found.decls, receiver: instance, owner: found.owner,
                               arguments: [.array(MLArray())], labels: [nil], boxes: [nil],
                               closure: klass.declarationEnvironment ?? globals,
                               location: found.decls[0].location)
                return
            }
        }
        // 型を指定されていなければ、全クラスと大域から探す。
        if let box = globals.lookup(name), let function = box.value.asFunction {
            _ = try callFunction(function, arguments: [.array(MLArray())],
                                 location: SourceLocation(line: 0, column: 0))
            return
        }
        for klass in classes.values {
            if let found = klass.findStaticMethod(name) {
                _ = try invoke(found.decls, receiver: nil, owner: found.owner,
                               arguments: [.array(MLArray())], labels: [nil], boxes: [nil],
                               closure: klass.declarationEnvironment ?? globals,
                               location: found.decls[0].location)
                return
            }
        }
        throw MLError.runtime("開始点 \(name) が見つかりません")
    }

    // MARK: - 上限の見張り

    @inline(__always)
    func tick() throws {
        stepCount += 1
        if stepCount > limits.maximumSteps {
            throw MLError.limitExceeded(
                "実行ステップが上限 (\(limits.maximumSteps)) を超えました。無限ループかもしれません。")
        }
    }

    public func write(_ text: String) {
        output.write(text)
    }

    // MARK: - 宣言の先読み

    /// 関数と型の宣言だけ先に登録する (相互再帰や前方参照のため)。
    public func hoist(_ statements: [MLStmt], in environment: MLEnvironment) throws {
        // 型はメソッド解決のため先に器だけ作る。
        var pendingTypes: [(MLTypeDecl, MLClass)] = []
        for statement in statements {
            if case .typeDecl(let decl) = statement {
                let klass = registerClassShell(decl, in: environment)
                pendingTypes.append((decl, klass))
            }
        }
        for (decl, klass) in pendingTypes {
            try fillClass(decl, klass: klass, in: environment)
        }
        for statement in statements {
            if case .funcDecl(let decl) = statement {
                defineFunction(decl, in: environment)
            }
        }
    }

    private func registerClassShell(_ decl: MLTypeDecl, in environment: MLEnvironment) -> MLClass {
        let klass = MLClass(name: decl.name, kind: decl.kind)
        klass.declarationEnvironment = environment
        klass.isAbstract = decl.isAbstract
        classes[decl.name] = klass
        for nested in decl.nestedTypes {
            _ = registerClassShell(nested, in: environment)
        }
        return klass
    }

    private func fillClass(_ decl: MLTypeDecl, klass: MLClass,
                           in environment: MLEnvironment) throws {
        if let superName = decl.superclassName {
            klass.superclass = classes[superName]
        }
        klass.interfaceNames = decl.interfaceNames
        klass.interfaces = decl.interfaceNames.compactMap {
            classes[$0] ?? classes[MLInterpreter.baseTypeName($0)]
        }
        // 親クラスがインタフェースとして宣言されていた場合も取り込む。
        if let superName = decl.superclassName,
           let parent = classes[superName] ?? classes[MLInterpreter.baseTypeName(superName)],
           parent.kind == .interfaceType {
            klass.superclass = nil
            klass.interfaces.append(parent)
            klass.interfaceNames.append(parent.name)
        }
        klass.properties = decl.properties
        klass.primaryParameters = decl.primaryParameters
        klass.bodyStatements = decl.bodyStatements
        klass.initializers = decl.initializers
        for method in decl.methods {
            if method.isStatic {
                klass.staticMethods[method.name, default: []].append(method)
            } else {
                klass.methods[method.name, default: []].append(method)
            }
        }
        for enumCase in decl.cases {
            klass.cases[enumCase.name] = enumCase
            klass.caseOrder.append(enumCase.name)
            if caseOwners[enumCase.name] == nil { caseOwners[enumCase.name] = klass }
        }
        for nested in decl.nestedTypes {
            if let nestedClass = classes[nested.name] {
                try fillClass(nested, klass: nestedClass, in: environment)
            }
        }
        // 型名そのものを値として引けるようにしておく (`Foo.bar` の解決用)。
        environment.define(decl.name, .object(classToken(klass)), isConstant: true)
        try initializeStaticMembers(of: klass, decl: decl, in: environment)
    }

    /// 型を指す値 (静的メンバー参照に使う目印つきオブジェクト)。
    private var classTokens: [ObjectIdentifier: MLObject] = [:]

    public func classToken(_ klass: MLClass) -> MLObject {
        let key = ObjectIdentifier(klass)
        if let existing = classTokens[key] { return existing }
        let token = MLObject(typeName: klass.name, classDeclaration: klass)
        token.caseName = nil
        token.attachment = .symbol("#type")
        classTokens[key] = token
        return token
    }

    public func isClassToken(_ value: MLValue) -> MLClass? {
        guard let object = value.asObject, case .symbol("#type")? = object.attachment,
              let klass = object.classDeclaration else { return nil }
        return klass
    }

    private func initializeStaticMembers(of klass: MLClass, decl: MLTypeDecl,
                                         in environment: MLEnvironment) throws {
        let scope = MLEnvironment(parent: environment)
        scope.define("#class", .object(classToken(klass)), isConstant: true)
        for property in decl.properties where property.isStatic {
            let value: MLValue
            if let expression = property.defaultValue {
                value = try evaluate(expression, in: scope)
            } else {
                value = semantics.defaultValue(forTypeName: property.typeName)
            }
            klass.staticStorage.define(property.name, value,
                                       isConstant: property.isConstant,
                                       typeName: property.typeName)
        }
        // 列挙の単純なケースは定数として引けるようにする。
        for name in klass.caseOrder {
            guard let enumCase = klass.cases[name] else { continue }
            if enumCase.associatedTypes.isEmpty && enumCase.associatedNames.isEmpty {
                let object = MLObject(typeName: klass.name, classDeclaration: klass,
                                      caseName: name)
                if let raw = enumCase.rawValue {
                    object.attachment = try evaluate(raw, in: scope)
                }
                klass.staticStorage.define(name, .object(object), isConstant: true)
            }
        }
    }

    public func defineFunction(_ decl: MLFunctionDecl, in environment: MLEnvironment) {
        // 同名の節が別々の文として来る言語 (Haskell / Erlang) では 1 つにまとめる。
        if let existing = environment.lookupLocal(decl.name),
           let function = existing.value.asFunction,
           case .declared(let previous) = function.body,
           previous !== decl {
            previous.clauses.append(contentsOf: decl.clauses)
            return
        }
        let function = MLFunction(body: .declared(decl), closure: environment)
        environment.define(decl.name, .function(function), isConstant: false)
    }

    public func registerClass(_ klass: MLClass) {
        classes[klass.name] = klass
        globals.define(klass.name, .object(classToken(klass)), isConstant: true)
    }

    public func lookupClass(_ name: String) -> MLClass? {
        classes[name] ?? classes[MLInterpreter.baseTypeName(name)]
    }

    /// `java.util.List<String>` → `List` のように、素の型名だけ取り出す。
    public static func baseTypeName(_ typeName: String) -> String {
        var text = typeName
        if let marker = text.firstIndex(of: "<") { text = String(text[..<marker]) }
        if let marker = text.lastIndex(of: ".") {
            text = String(text[text.index(after: marker)...])
        }
        return text
    }

    public func lookupCaseOwner(_ caseName: String) -> MLClass? { caseOwners[caseName] }

    // MARK: - 文の実行

    public func execute(_ statements: [MLStmt], in environment: MLEnvironment) throws {
        for statement in statements {
            try execute(statement, in: environment)
        }
    }

    /// ブロックを実行して「最後の式の値」を返す (式としてのブロック用)。
    public func executeForValue(_ statements: [MLStmt],
                                in environment: MLEnvironment) throws -> MLValue {
        var last = MLValue.unit
        for (index, statement) in statements.enumerated() {
            if index == statements.count - 1, case .expression(let expression, _) = statement {
                last = try evaluate(expression, in: environment)
            } else {
                try execute(statement, in: environment)
                last = .unit
            }
        }
        return last
    }

    public func execute(_ statement: MLStmt, in environment: MLEnvironment) throws {
        try tick()
        switch statement {
        case .noop:
            return

        case .expression(let expression, _):
            _ = try evaluate(expression, in: environment)

        case .varDecl(let pattern, let typeName, let valueExpr, let isConstant, _):
            var value: MLValue
            if let valueExpr {
                value = try evaluate(valueExpr, in: environment)
                value = semantics.coerce(value, toTypeName: typeName)
                if semantics.usesValueSemantics { value = copyForBinding(value) }
            } else {
                value = semantics.defaultValue(forTypeName: typeName)
            }
            try bind(pattern, to: value, in: environment,
                     isConstant: isConstant, typeName: typeName)

        case .ifStmt(let condition, let then, let otherwise, _):
            if try semantics.isTruthy(evaluate(condition, in: environment)) {
                try execute(then, in: MLEnvironment(parent: environment))
            } else if let otherwise {
                try execute(otherwise, in: MLEnvironment(parent: environment))
            }

        case .guardStmt(let condition, let elseBody, _):
            if try !semantics.isTruthy(evaluate(condition, in: environment)) {
                try execute(elseBody, in: MLEnvironment(parent: environment))
                // else 節が抜けなかった場合は素通りさせる。
            }

        case .whileStmt(let condition, let body, let label, _):
            while try semantics.isTruthy(evaluate(condition, in: environment)) {
                try tick()
                do {
                    try execute(body, in: MLEnvironment(parent: environment))
                } catch let control as MLControl {
                    if try handleLoopControl(control, label: label) { return }
                }
            }

        case .doWhile(let body, let condition, let isUntil, let label, _):
            repeat {
                try tick()
                do {
                    try execute(body, in: MLEnvironment(parent: environment))
                } catch let control as MLControl {
                    if try handleLoopControl(control, label: label) { return }
                }
                let flag = try semantics.isTruthy(evaluate(condition, in: environment))
                if isUntil ? flag : !flag { break }
            } while true

        case .forClassic(let initializer, let condition, let step, let body, let label, _):
            let loopScope = MLEnvironment(parent: environment)
            try execute(initializer, in: loopScope)
            while true {
                try tick()
                if let condition,
                   try !semantics.isTruthy(evaluate(condition, in: loopScope)) { break }
                do {
                    try execute(body, in: MLEnvironment(parent: loopScope))
                } catch let control as MLControl {
                    if try handleLoopControl(control, label: label) { return }
                }
                try execute(step, in: loopScope)
            }

        case .forIn(let pattern, let sequenceExpr, let body, let whereClause, let label, _):
            let sequence = try evaluate(sequenceExpr, in: environment)
            for element in try MLOperations.iterate(sequence, semantics: semantics) {
                try tick()
                let scope = MLEnvironment(parent: environment)
                guard try match(pattern, value: element, into: scope) else { continue }
                if let whereClause,
                   try !semantics.isTruthy(evaluate(whereClause, in: scope)) { continue }
                do {
                    try execute(body, in: scope)
                } catch let control as MLControl {
                    if try handleLoopControl(control, label: label) { return }
                }
            }

        case .matchStmt(let subject, let arms, let label, let location):
            _ = try evaluateMatch(subject: subject, arms: arms, in: environment,
                                  label: label, location: location, asStatement: true)

        case .breakStmt(let label, _):
            throw MLControl.breakLoop(label: label)

        case .continueStmt(let label, _):
            throw MLControl.continueLoop(label: label)

        case .returnStmt(let expression, _):
            let value = try expression.map { try evaluate($0, in: environment) } ?? .unit
            throw MLControl.returnValue(value)

        case .throwStmt(let expression, _):
            throw MLError.thrown(try evaluate(expression, in: environment))

        case .tryStmt(let body, let catches, let finallyBody, _):
            try executeTry(body: body, catches: catches, finallyBody: finallyBody,
                           in: environment)

        case .funcDecl(let decl):
            if environment.lookupLocal(decl.name) == nil {
                defineFunction(decl, in: environment)
            } else if case .declared(let existing)? = environment.lookupLocal(decl.name)?
                        .value.asFunction?.body, existing === decl {
                // hoist で登録済み。
            } else {
                defineFunction(decl, in: environment)
            }

        case .typeDecl(let decl):
            if classes[decl.name] == nil || classes[decl.name]?.methods.isEmpty == true {
                let klass = registerClassShell(decl, in: environment)
                try fillClass(decl, klass: klass, in: environment)
            }

        case .block(let statements, _):
            try execute(statements, in: MLEnvironment(parent: environment))
        }
    }

    /// break / continue を受け止める。true を返したらループを抜ける。
    private func handleLoopControl(_ control: MLControl, label: String?) throws -> Bool {
        switch control {
        case .breakLoop(let target):
            if target == nil || target == label { return true }
            throw control
        case .continueLoop(let target):
            if target == nil || target == label { return false }
            throw control
        default:
            throw control
        }
    }

    private func executeTry(body: [MLStmt], catches: [MLCatchClause],
                            finallyBody: [MLStmt]?, in environment: MLEnvironment) throws {
        var pending: Error?
        do {
            try execute(body, in: MLEnvironment(parent: environment))
        } catch let error as MLError {
            if case .exit = error { pending = error }
            else if case .limitExceeded = error { pending = error }
            else {
                let thrown = thrownValue(from: error)
                var handled = false
                for clause in catches {
                    let scope = MLEnvironment(parent: environment)
                    if let pattern = clause.pattern {
                        guard try match(pattern, value: thrown, into: scope) else { continue }
                    } else if let typeName = clause.typeName, !matchesType(thrown, typeName) {
                        continue
                    }
                    if let binding = clause.binding { scope.define(binding, thrown) }
                    if let guardCondition = clause.guardCondition,
                       try !semantics.isTruthy(evaluate(guardCondition, in: scope)) { continue }
                    do {
                        try execute(clause.body, in: scope)
                    } catch {
                        pending = error
                    }
                    handled = true
                    break
                }
                if !handled { pending = error }
            }
        } catch {
            pending = error
        }
        if let finallyBody {
            try execute(finallyBody, in: MLEnvironment(parent: environment))
        }
        if let pending { throw pending }
    }

    /// 例外の中身を値として取り出す。
    public func thrownValue(from error: MLError) -> MLValue {
        if case .thrown(let value) = error { return value }
        let object = MLObject(typeName: "Error")
        object.fields[.string("message")] = .string(error.message)
        return .object(object)
    }

    /// 値が型名に当てはまるか。
    public func matchesType(_ value: MLValue, _ typeName: String) -> Bool {
        let name = typeName
        if name == "Any" || name == "Object" || name == "object" || name == "_" { return true }
        if let object = value.asObject {
            if object.typeName == name { return true }
            if let klass = object.classDeclaration, klass.conforms(to: name) { return true }
            if object.caseName == name { return true }
            // 組み込みの例外型など、継承関係を名前の並びで持っているもの。
            if let ancestors = object.fields[.string("#types")]?.asArray,
               ancestors.elements.contains(where: { $0.asString == name }) {
                return true
            }
        }
        switch value.forced {
        case .int:
            return ["Int", "int", "Integer", "Int64", "Int32", "Long", "long", "Num", "Number",
                    "Numeric", "isize", "i32", "i64", "u32", "u64", "usize", "short", "byte"]
                .contains(name)
        case .double:
            return ["Double", "double", "Float", "float", "Float64", "Real", "Num", "Number",
                    "f32", "f64", "Numeric"].contains(name)
        case .bool:
            return ["Bool", "bool", "Boolean", "boolean"].contains(name)
        case .string:
            return ["String", "string", "str", "Str", "CharSequence", "Text"].contains(name)
        case .char:
            return ["Char", "char", "Character", "rune"].contains(name)
        case .array:
            return name.hasPrefix("Array") || name.hasPrefix("List") || name.hasPrefix("Vec")
                || name.hasPrefix("Seq") || name.hasSuffix("[]") || name == "list"
        case .map:
            return name.hasPrefix("Map") || name.hasPrefix("Dict") || name.hasPrefix("HashMap")
                || name == "dict" || name.hasPrefix("Hash")
        case .function:
            return name.hasPrefix("Func") || name.hasPrefix("fn") || name.contains("->")
        case .unit:
            return ["Void", "void", "Unit", "None", "nil", "null", "Nothing"].contains(name)
        default:
            return false
        }
    }

    // MARK: - 束縛

    /// 値型の言語で変数に入れるときのコピー。
    public func copyForBinding(_ value: MLValue) -> MLValue {
        switch value {
        case .array where semantics.arraysAreValueTypes: return value.deepCopy()
        case .map where semantics.arraysAreValueTypes: return value.deepCopy()
        case .object(let object):
            guard let klass = object.classDeclaration else { return value }
            return klass.kind == .structType ? value.deepCopy() : value
        default: return value
        }
    }

    public func bind(_ pattern: MLPattern, to value: MLValue, in environment: MLEnvironment,
                     isConstant: Bool = false, typeName: String? = nil) throws {
        switch pattern {
        case .binding(let name):
            environment.define(name, value, isConstant: isConstant, typeName: typeName)
        case .wildcard:
            return
        default:
            guard try match(pattern, value: value, into: environment) else {
                throw MLError.runtime("パターンに当てはまりませんでした")
            }
        }
    }

    // MARK: - パターン照合

    /// 当てはまれば `environment` に名前を足して true。
    public func match(_ pattern: MLPattern, value rawValue: MLValue,
                      into environment: MLEnvironment) throws -> Bool {
        try tick()
        let value = rawValue.forced
        switch pattern {
        case .wildcard:
            return true

        case .binding(let name):
            environment.define(name, value)
            return true

        case .named(let name, let inner):
            guard try match(inner, value: value, into: environment) else { return false }
            environment.define(name, value)
            return true

        case .literal(let expected):
            return semantics.areEqual(expected, value)

        case .expression(let expression):
            let expected = try evaluate(expression, in: environment)
            // 定数名として書かれた列挙ケースも拾う。
            return semantics.areEqual(expected, value)

        case .typed(let inner, let typeName):
            guard matchesType(value, typeName) else { return false }
            return try match(inner, value: value, into: environment)

        case .or(let options):
            for option in options where try match(option, value: value, into: environment) {
                return true
            }
            return false

        case .range(let lowerExpr, let upperExpr, let isClosed):
            let lower = try evaluate(lowerExpr, in: environment)
            let upper = try evaluate(upperExpr, in: environment)
            guard let low = semantics.compare(lower, value), low <= 0,
                  let high = semantics.compare(value, upper) else { return false }
            return isClosed ? high <= 0 : high < 0

        case .tuple(let items):
            let elements: [MLValue]
            if case .tuple(let values) = value { elements = values }
            else if let array = value.asArray { elements = array.elements }
            else if let object = value.asObject, object.caseName != nil { elements = object.payload }
            else { return false }
            guard elements.count == items.count else { return false }
            for (index, item) in items.enumerated() {
                guard try match(item, value: elements[index], into: environment) else { return false }
            }
            return true

        case .list(let items, let restIndex, let restName):
            guard let elements = listElements(of: value) else { return false }
            if let restIndex {
                guard elements.count >= items.count else { return false }
                let tailCount = items.count - restIndex
                for index in 0..<restIndex {
                    guard try match(items[index], value: elements[index],
                                    into: environment) else { return false }
                }
                let restCount = elements.count - items.count
                if let restName {
                    let rest = Array(elements[restIndex..<(restIndex + restCount)])
                    environment.define(restName, .array(MLArray(rest)))
                }
                for offset in 0..<tailCount {
                    let patternIndex = restIndex + offset
                    let valueIndex = restIndex + restCount + offset
                    guard try match(items[patternIndex], value: elements[valueIndex],
                                    into: environment) else { return false }
                }
                return true
            }
            guard elements.count == items.count else { return false }
            for (index, item) in items.enumerated() {
                guard try match(item, value: elements[index],
                                into: environment) else { return false }
            }
            return true

        case .cons(let headPattern, let tailPattern):
            guard let elements = listElements(of: value), let first = elements.first else {
                return false
            }
            guard try match(headPattern, value: first, into: environment) else { return false }
            let tail = MLValue.array(MLArray(Array(elements.dropFirst())))
            return try match(tailPattern, value: tail, into: environment)

        case .map(let pairs):
            guard let map = value.asMap else { return false }
            for pair in pairs {
                let keyValue = try evaluate(pair.key, in: environment)
                guard let key = MLKey.from(keyValue), let found = map[key] else { return false }
                guard try match(pair.value, value: found, into: environment) else { return false }
            }
            return true

        case .constructor(let name, let positional, let named):
            // 代数的データ型 / 列挙のケース。
            if let object = value.asObject {
                if let caseName = object.caseName {
                    guard caseName == name || object.typeName == name else { return false }
                } else {
                    guard object.typeName == name
                            || object.classDeclaration?.conforms(to: name) == true else {
                        return false
                    }
                }
                if !positional.isEmpty {
                    let payload = object.payload.isEmpty
                        ? object.fields.values : object.payload
                    guard payload.count >= positional.count else { return false }
                    for (index, item) in positional.enumerated() {
                        guard try match(item, value: payload[index],
                                        into: environment) else { return false }
                    }
                }
                for (fieldName, fieldPattern) in named {
                    guard let found = object.fields[.string(fieldName)] else { return false }
                    guard try match(fieldPattern, value: found,
                                    into: environment) else { return false }
                }
                return true
            }
            // アトム (`:ok`) との照合。
            if case .symbol(let symbolName) = value {
                return symbolName == name && positional.isEmpty && named.isEmpty
            }
            // タプルの先頭がタグになっている形 (`{:ok, value}`)。
            if case .tuple(let items) = value, let first = items.first,
               case .symbol(let tag) = first.forced, tag == name {
                let rest = Array(items.dropFirst())
                guard rest.count == positional.count else { return false }
                for (index, item) in positional.enumerated() {
                    guard try match(item, value: rest[index],
                                    into: environment) else { return false }
                }
                return true
            }
            return false
        }
    }

    private func listElements(of value: MLValue) -> [MLValue]? {
        switch value.forced {
        case .array(let array): return array.elements
        case .tuple(let items): return items
        case .string(let text): return text.map { MLValue.char($0) }
        case .range(let range): return range.elements.map { MLValue.int($0) }
        default: return nil
        }
    }

    // MARK: - 式の評価

    public func evaluate(_ expression: MLExpr, in environment: MLEnvironment) throws -> MLValue {
        try tick()
        switch expression {
        case .literal(let value, _):
            return value

        case .name(let name, let location):
            return try lookupName(name, in: environment, location: location)

        case .selfRef(let location):
            guard let box = environment.lookup("self") ?? environment.lookup("this") else {
                throw MLError.runtime("\(location) self を使える場所ではありません")
            }
            return box.value

        case .superRef(let location):
            guard let box = environment.lookup("self") ?? environment.lookup("this") else {
                throw MLError.runtime("\(location) super を使える場所ではありません")
            }
            return box.value

        case .defaultValue(let typeName, _):
            return semantics.defaultValue(forTypeName: typeName)

        case .listLiteral(let items, let spreadIndices, _):
            var elements: [MLValue] = []
            for (index, item) in items.enumerated() {
                let value = try evaluate(item, in: environment)
                if spreadIndices.contains(index) {
                    elements.append(contentsOf: try MLOperations.iterate(value, semantics: semantics))
                } else {
                    elements.append(value)
                }
            }
            return .array(MLArray(elements))

        case .mapLiteral(let pairs, let location):
            let map = MLMap()
            for pair in pairs {
                let keyValue = try evaluate(pair.key, in: environment)
                guard let key = MLKey.from(keyValue) else {
                    throw MLError.runtime("\(location) \(semantics.typeName(of: keyValue)) は辞書のキーにできません")
                }
                map[key] = try evaluate(pair.value, in: environment)
            }
            return .map(map)

        case .tupleLiteral(let items, _):
            if items.count == 1 { return try evaluate(items[0], in: environment) }
            return .tuple(try items.map { try evaluate($0, in: environment) })

        case .interpolation(let parts, _):
            var text = ""
            for part in parts {
                let value = try evaluate(part, in: environment)
                text += semantics.stringify(value)
            }
            return .string(text)

        case .member(let target, let name, let isOptional, let location):
            let receiver = try evaluate(target, in: environment)
            if isOptional, receiver.isUnit { return .unit }
            return try member(of: receiver, name: name, location: location)

        case .subscriptExpr(let target, let indexExpr, let upperExpr, let location):
            let receiver = try evaluate(target, in: environment)
            let index = try evaluate(indexExpr, in: environment)
            if let upperExpr {
                let upper = try evaluate(upperExpr, in: environment)
                return try slice(receiver, from: index, to: upper, location: location)
            }
            return try subscriptValue(receiver, index: index, location: location)

        case .call(let callee, let arguments, let location):
            return try evaluateCall(callee: callee, arguments: arguments,
                                    in: environment, location: location)

        case .construct(let typeName, let arguments, let location):
            let resolved = try resolveArguments(arguments, in: environment)
            // ジェネリクスや修飾は落として素の名前で探す。
            let baseName = MLInterpreter.baseTypeName(typeName)
            if let klass = classes[typeName] ?? classes[baseName] {
                return try instantiate(klass, arguments: resolved.values,
                                       labels: resolved.labels, location: location)
            }
            // 組み込みの型は生成関数として登録してある。
            if let box = environment.lookup(baseName) {
                if let klass = isClassToken(box.value) {
                    return try instantiate(klass, arguments: resolved.values,
                                           labels: resolved.labels, location: location)
                }
                if let function = box.value.asFunction {
                    return try callFunction(function, arguments: resolved.values,
                                            labels: resolved.labels, location: location)
                }
            }
            throw MLError.runtime("\(location) 型 \(typeName) が見つかりません")

        case .unary(let op, let operand, let isPostfix, let location):
            return try evaluateUnary(op: op, operand: operand, isPostfix: isPostfix,
                                     in: environment, location: location)

        case .binary(let op, let lhs, let rhs, let location):
            return try evaluateBinary(op: op, lhs: lhs, rhs: rhs,
                                      in: environment, location: location)

        case .assign(let op, let target, let valueExpr, let location):
            return try evaluateAssign(op: op, target: target, valueExpr: valueExpr,
                                      in: environment, location: location)

        case .ternary(let condition, let then, let otherwise, _):
            return try semantics.isTruthy(evaluate(condition, in: environment))
                ? evaluate(then, in: environment)
                : evaluate(otherwise, in: environment)

        case .ifExpr(let condition, let then, let otherwise, _):
            if try semantics.isTruthy(evaluate(condition, in: environment)) {
                return try evaluate(then, in: environment)
            }
            if let otherwise { return try evaluate(otherwise, in: environment) }
            return .unit

        case .lambda(let decl, _):
            let scope = MLEnvironment(parent: environment)
            let function = MLFunction(body: .declared(decl), closure: scope)
            if !decl.name.isEmpty {
                scope.define(decl.name, .function(function))
            }
            if let selfBox = environment.lookup("self") ?? environment.lookup("this") {
                function.boundSelf = selfBox.value
            }
            return .function(function)

        case .range(let lowerExpr, let upperExpr, let isClosed, let stepExpr, let location):
            let lower = try lowerExpr.map { try evaluate($0, in: environment) } ?? .int(0)
            let upper = try upperExpr.map { try evaluate($0, in: environment) } ?? .int(0)
            let step = try stepExpr.map { try evaluate($0, in: environment) } ?? .int(1)
            guard let low = lower.asInt, let high = upper.asInt, let stride = step.asInt else {
                throw MLError.runtime("\(location) 範囲には整数が必要です")
            }
            return .range(MLRange(lower: low, upper: high, isClosed: isClosed, step: stride))

        case .cast(let valueExpr, let typeName, let isOptional, let location):
            let value = try evaluate(valueExpr, in: environment)
            return try cast(value, to: typeName, isOptional: isOptional, location: location)

        case .typeTest(let valueExpr, let typeName, _):
            return .bool(matchesType(try evaluate(valueExpr, in: environment), typeName))

        case .forceUnwrap(let valueExpr, let location):
            let value = try evaluate(valueExpr, in: environment)
            if value.isUnit {
                throw MLError.runtime("\(location) 値が無いものを強制的に取り出そうとしました")
            }
            return value

        case .implicitMember(let name, let location):
            return try resolveImplicitMember(name, in: environment, location: location)

        case .comprehension(let comprehension, _):
            return try evaluateComprehension(comprehension, in: environment)

        case .match(let subject, let arms, let location):
            return try evaluateMatch(subject: subject, arms: arms, in: environment,
                                     label: nil, location: location, asStatement: false)

        case .block(let statements, _):
            let scope = MLEnvironment(parent: environment)
            try hoist(statements, in: scope)
            return try executeForValue(statements, in: scope)

        case .lazy(let inner, _):
            return .thunk(MLThunk { [weak self] in
                guard let self else { return .unit }
                return try self.evaluate(inner, in: environment)
            })

        case .reference(let inner, let location):
            if let box = try resolveBox(inner, in: environment) {
                let object = MLObject(typeName: "#ref")
                object.attachment = .unit
                object.payload = [box.value]
                referenceBoxes[ObjectIdentifier(object)] = box
                return .object(object)
            }
            throw MLError.runtime("\(location) 参照を作れません")

        case .dereference(let inner, let location):
            let value = try evaluate(inner, in: environment)
            if let object = value.asObject, object.typeName == "#ref",
               let box = referenceBoxes[ObjectIdentifier(object)] {
                return box.value
            }
            if value.asArray != nil || value.asMap != nil || value.asObject != nil {
                return value
            }
            throw MLError.runtime("\(location) 参照ではない値をたどろうとしました")
        }
    }

    /// `&x` で作った参照の実体。
    private var referenceBoxes: [ObjectIdentifier: MLBox] = [:]

    public func referencedBox(_ value: MLValue) -> MLBox? {
        guard let object = value.asObject, object.typeName == "#ref" else { return nil }
        return referenceBoxes[ObjectIdentifier(object)]
    }

    // MARK: 名前の解決

    public func lookupName(_ name: String, in environment: MLEnvironment,
                           location: SourceLocation) throws -> MLValue {
        if let box = environment.lookup(name) { return box.value }
        // メソッドの中なら self のフィールド・メソッドも探す。
        if let selfBox = environment.lookup("self") ?? environment.lookup("this"),
           let object = selfBox.value.asObject {
            if let field = object.fields[.string(name)] { return field }
            if let klass = object.classDeclaration {
                if let found = klass.findMethod(name) {
                    return .function(MLFunction(body: .declared(found.decls[0]),
                                                closure: klass.declarationEnvironment ?? globals,
                                                boundSelf: selfBox.value, owner: found.owner))
                }
                if let box = klass.findStaticBox(name) { return box.value }
                if let found = klass.findStaticMethod(name) {
                    return .function(MLFunction(body: .declared(found.decls[0]),
                                                closure: klass.declarationEnvironment ?? globals,
                                                owner: found.owner))
                }
            }
        }
        // 静的メソッドの中なら自分のクラスの静的メンバー。
        if let classBox = environment.lookup("#class"), let klass = isClassToken(classBox.value) {
            if let box = klass.findStaticBox(name) { return box.value }
            if let found = klass.findStaticMethod(name) {
                return .function(MLFunction(body: .declared(found.decls[0]),
                                            closure: klass.declarationEnvironment ?? globals,
                                            owner: found.owner))
            }
        }
        if let klass = classes[name] { return .object(classToken(klass)) }
        if !semantics.requiresDefinitionBeforeUse { return .unit }
        throw MLError.runtime("\(location) \(name) が見つかりません")
    }

    private func resolveImplicitMember(_ name: String, in environment: MLEnvironment,
                                       location: SourceLocation) throws -> MLValue {
        if let klass = caseOwners[name] {
            if let box = klass.staticStorage.lookupLocal(name) { return box.value }
            if let enumCase = klass.cases[name] {
                if enumCase.associatedTypes.isEmpty && enumCase.associatedNames.isEmpty {
                    return .object(MLObject(typeName: klass.name, classDeclaration: klass,
                                            caseName: name))
                }
                // 引数つきのケースはコンストラクタ関数として返す。
                return .function(caseConstructor(klass: klass, enumCase: enumCase))
            }
        }
        if let box = environment.lookup(name) { return box.value }
        // 型が分からない `.foo` は単なるシンボルとして扱う。
        return .symbol(name)
    }

    public func caseConstructor(klass: MLClass, enumCase: MLCaseDecl) -> MLFunction {
        let count = max(enumCase.associatedTypes.count, enumCase.associatedNames.count)
        return MLFunction.native(enumCase.name, 0...max(count, 1)) { context in
            let object = MLObject(typeName: klass.name, classDeclaration: klass,
                                  caseName: enumCase.name)
            object.payload = context.arguments
            for (index, fieldName) in enumCase.associatedNames.enumerated()
            where index < context.arguments.count {
                object.fields[.string(fieldName)] = context.arguments[index]
            }
            return .object(object)
        }
    }

    // MARK: 単項・二項

    private func evaluateUnary(op: String, operand: MLExpr, isPostfix: Bool,
                               in environment: MLEnvironment,
                               location: SourceLocation) throws -> MLValue {
        if op == "++" || op == "--" {
            guard let box = try resolveBox(operand, in: environment) else {
                throw MLError.runtime("\(location) \(op) は変数にしか使えません")
            }
            let old = box.value
            let delta: MLValue = .int(op == "++" ? 1 : -1)
            let updated = try MLOperations.arithmetic(op: "+", lhs: old, rhs: delta,
                                                      semantics: semantics)
            box.value = updated
            return isPostfix ? old : updated
        }

        // `&&` 同様に短絡する単項は無いので先に評価してよい。
        let value = try evaluate(operand, in: environment)
        if let custom = try semantics.customUnary(op: op, operand: value, interpreter: self) {
            return custom
        }
        switch op {
        case "-":
            switch value.forced {
            case .int(let number):
                let (result, overflow) = Int64(0).subtractingReportingOverflow(number)
                return try semantics.wrapInteger(result, overflow: overflow)
            case .double(let number): return .double(-number)
            default:
                throw MLError.runtime("\(location) \(semantics.typeName(of: value)) に単項 `-` は使えません")
            }
        case "+":
            return value
        case "!", "not":
            return .bool(try !semantics.isTruthy(value))
        case "~":
            guard let number = value.asInt else {
                throw MLError.runtime("\(location) `~` には整数が必要です")
            }
            return .int(~number)
        default:
            throw MLError.runtime("\(location) 知らない単項演算子です: \(op)")
        }
    }

    private func evaluateBinary(op: String, lhs lhsExpr: MLExpr, rhs rhsExpr: MLExpr,
                                in environment: MLEnvironment,
                                location: SourceLocation) throws -> MLValue {
        // 短絡する演算子。
        switch op {
        case "&&", "and", "&&&":
            let lhs = try evaluate(lhsExpr, in: environment)
            if try !semantics.isTruthy(lhs) { return shortCircuitResult(lhs, isAnd: true) }
            return try evaluate(rhsExpr, in: environment)
        case "||", "or":
            let lhs = try evaluate(lhsExpr, in: environment)
            if try semantics.isTruthy(lhs) { return shortCircuitResult(lhs, isAnd: false) }
            return try evaluate(rhsExpr, in: environment)
        case "??":
            let lhs = try evaluate(lhsExpr, in: environment)
            return lhs.isUnit ? try evaluate(rhsExpr, in: environment) : lhs
        default:
            break
        }

        let lhs = try evaluate(lhsExpr, in: environment)
        let rhs = try evaluate(rhsExpr, in: environment)
        return try applyBinary(op: op, lhs: lhs, rhs: rhs, location: location)
    }

    /// `&&` / `||` が真偽値ではなく被演算子そのものを返す言語のための出口。
    private func shortCircuitResult(_ value: MLValue, isAnd: Bool) -> MLValue {
        if semanticsReturnsOperandsFromLogicalOperators { return value }
        return .bool(!isAnd)
    }

    /// 論理演算子が被演算子を返すか (JavaScript / Lua / Perl など)。
    public var semanticsReturnsOperandsFromLogicalOperators = false

    public func applyBinary(op: String, lhs: MLValue, rhs: MLValue,
                            location: SourceLocation) throws -> MLValue {
        if let custom = try semantics.customBinary(op: op, lhs: lhs, rhs: rhs, interpreter: self) {
            return custom
        }
        switch op {
        case "==", "eq", "===":
            return .bool(semantics.areEqual(lhs, rhs))
        case "!=", "ne", "<>", "!==", "/=":
            return .bool(!semantics.areEqual(lhs, rhs))
        case "<", ">", "<=", ">=":
            guard let order = semantics.compare(lhs, rhs) else {
                throw MLError.runtime(
                    "\(location) \(semantics.typeName(of: lhs)) と \(semantics.typeName(of: rhs)) は比べられません")
            }
            switch op {
            case "<": return .bool(order < 0)
            case ">": return .bool(order > 0)
            case "<=": return .bool(order <= 0)
            default: return .bool(order >= 0)
            }
        case "<=>":
            guard let order = semantics.compare(lhs, rhs) else { return .unit }
            return .int(Int64(order))
        default:
            return try MLOperations.arithmetic(op: op, lhs: lhs, rhs: rhs, semantics: semantics)
        }
    }

    // MARK: 代入

    private func evaluateAssign(op: String, target: MLExpr, valueExpr: MLExpr,
                                in environment: MLEnvironment,
                                location: SourceLocation) throws -> MLValue {
        var value = try evaluate(valueExpr, in: environment)
        if op != "=" {
            let current = try evaluate(target, in: environment)
            let binaryOp = String(op.dropLast())
            if binaryOp == "??" {
                value = current.isUnit ? value : current
            } else {
                value = try applyBinary(op: binaryOp, lhs: current, rhs: value, location: location)
            }
        }
        if semantics.usesValueSemantics { value = copyForBinding(value) }
        try assign(to: target, value: value, in: environment, location: location)
        return value
    }

    public func assign(to target: MLExpr, value: MLValue, in environment: MLEnvironment,
                       location: SourceLocation) throws {
        switch target {
        case .name(let name, _):
            if let box = environment.lookup(name) {
                if box.isConstant {
                    throw MLError.runtime("\(location) 定数 \(name) には代入できません")
                }
                box.value = semantics.coerce(value, toTypeName: box.declaredTypeName)
                return
            }
            // self のフィールドへの暗黙代入。
            if let selfBox = environment.lookup("self") ?? environment.lookup("this"),
               let object = selfBox.value.asObject,
               object.fields.contains(.string(name)) {
                object.fields[.string(name)] = value
                return
            }
            if let classBox = environment.lookup("#class"), let klass = isClassToken(classBox.value),
               let box = klass.findStaticBox(name) {
                box.value = value
                return
            }
            if semantics.requiresDefinitionBeforeUse {
                throw MLError.runtime("\(location) \(name) が見つかりません")
            }
            environment.functionScope.define(name, value)

        case .member(let receiverExpr, let name, _, _):
            let receiver = try evaluate(receiverExpr, in: environment)
            try setMember(of: receiver, name: name, value: value, location: location)

        case .subscriptExpr(let receiverExpr, let indexExpr, _, _):
            let receiver = try evaluate(receiverExpr, in: environment)
            let index = try evaluate(indexExpr, in: environment)
            try setSubscript(of: receiver, index: index, value: value,
                             location: location, in: environment, receiverExpr: receiverExpr)

        case .tupleLiteral(let items, _), .listLiteral(let items, _, _):
            // 多重代入 `(a, b) = (1, 2)`
            let values = try MLOperations.iterate(value, semantics: semantics)
            for (index, item) in items.enumerated() where index < values.count {
                try assign(to: item, value: values[index], in: environment, location: location)
            }

        case .dereference(let inner, _):
            let reference = try evaluate(inner, in: environment)
            if let box = referencedBox(reference) {
                box.value = value
                return
            }
            throw MLError.runtime("\(location) 参照ではない値に代入しようとしました")

        case .forceUnwrap(let inner, _):
            try assign(to: inner, value: value, in: environment, location: location)

        default:
            throw MLError.runtime("\(location) ここには代入できません")
        }
    }

    /// 代入先の箱 (参照渡し・インクリメント用)。
    public func resolveBox(_ expression: MLExpr,
                           in environment: MLEnvironment) throws -> MLBox? {
        switch expression {
        case .name(let name, _):
            if let box = environment.lookup(name) { return box }
            if let selfBox = environment.lookup("self") ?? environment.lookup("this"),
               let object = selfBox.value.asObject, object.fields.contains(.string(name)) {
                return MLFieldBox(object: object, key: .string(name))
            }
            if let classBox = environment.lookup("#class"),
               let klass = isClassToken(classBox.value) {
                return klass.findStaticBox(name)
            }
            if !semantics.requiresDefinitionBeforeUse {
                return environment.functionScope.define(name, .unit)
            }
            return nil
        case .member(let receiverExpr, let name, _, _):
            let receiver = try evaluate(receiverExpr, in: environment)
            if let object = receiver.asObject {
                if object.fields.contains(.string(name)) {
                    return MLFieldBox(object: object, key: .string(name))
                }
                if let klass = isClassToken(receiver), let box = klass.findStaticBox(name) {
                    return box
                }
                object.fields[.string(name)] = .unit
                return MLFieldBox(object: object, key: .string(name))
            }
            if let map = receiver.asMap {
                return MLMapBox(map: map, key: .string(name))
            }
            return nil
        case .subscriptExpr(let receiverExpr, let indexExpr, _, _):
            let receiver = try evaluate(receiverExpr, in: environment)
            let index = try evaluate(indexExpr, in: environment)
            if let array = receiver.asArray, let raw = index.asInt,
               let position = MLOperations.normalizeIndex(raw, count: array.count,
                                                          semantics: semantics) {
                return MLElementBox(array: array, index: position)
            }
            if let map = receiver.asMap, let key = MLKey.from(index) {
                if map[key] == nil { map[key] = .unit }
                return MLMapBox(map: map, key: key)
            }
            return nil
        case .dereference(let inner, _):
            let reference = try evaluate(inner, in: environment)
            return referencedBox(reference)
        default:
            return nil
        }
    }

    // MARK: メンバー

    public func member(of receiver: MLValue, name: String,
                       location: SourceLocation) throws -> MLValue {
        if let custom = try semantics.member(of: receiver, name: name, interpreter: self) {
            return custom
        }
        // 型そのものへのアクセス (静的メンバー / 列挙ケース)。
        if let klass = isClassToken(receiver) {
            if let box = klass.findStaticBox(name) { return box.value }
            if let found = klass.findStaticMethod(name) {
                return .function(MLFunction(body: .declared(found.decls[0]),
                                            closure: klass.declarationEnvironment ?? globals,
                                            owner: found.owner))
            }
            if let enumCase = klass.cases[name] {
                if enumCase.associatedTypes.isEmpty && enumCase.associatedNames.isEmpty {
                    return .object(MLObject(typeName: klass.name, classDeclaration: klass,
                                            caseName: name))
                }
                return .function(caseConstructor(klass: klass, enumCase: enumCase))
            }
            if let found = klass.findMethod(name) {
                return .function(MLFunction(body: .declared(found.decls[0]),
                                            closure: klass.declarationEnvironment ?? globals,
                                            owner: found.owner))
            }
            throw MLError.runtime("\(location) \(klass.name) に \(name) はありません")
        }

        if let object = receiver.asObject {
            if let value = object.fields[.string(name)] { return value }
            if let klass = object.classDeclaration {
                // 計算プロパティ。
                if let (property, owner) = klass.findProperty(name), let getter = property.getter {
                    let scope = MLEnvironment(parent: owner.declarationEnvironment ?? globals,
                                              isFunctionScope: true)
                    scope.define("self", receiver)
                    scope.define("this", receiver)
                    scope.define("#class", .object(classToken(owner)))
                    do {
                        try execute(getter, in: scope)
                    } catch let control as MLControl {
                        if case .returnValue(let value) = control { return value }
                        throw control
                    }
                    return .unit
                }
                if let found = klass.findMethod(name) {
                    return .function(MLFunction(body: .declared(found.decls[0]),
                                                closure: klass.declarationEnvironment ?? globals,
                                                boundSelf: receiver, owner: found.owner))
                }
                if let box = klass.findStaticBox(name) { return box.value }
                if let found = klass.findStaticMethod(name) {
                    return .function(MLFunction(body: .declared(found.decls[0]),
                                                closure: klass.declarationEnvironment ?? globals,
                                                owner: found.owner))
                }
            }
            // 代数的データ型の位置引数に名前でアクセスする言語向け。
            if let index = Int(name.dropFirst()), name.hasPrefix("_"),
               index >= 1, index <= object.payload.count {
                return object.payload[index - 1]
            }
            if object.caseName != nil, name == "name" {
                return .string(object.caseName ?? "")
            }
            throw MLError.runtime("\(location) \(object.typeName) に \(name) はありません")
        }

        if let map = receiver.asMap, let value = map[.string(name)] { return value }

        // 組み込み型のプロパティ (length など) は共通ライブラリに任せる。
        if let value = try MLStdlib.member(of: receiver, name: name, interpreter: self) {
            return value
        }
        throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)) に \(name) はありません")
    }

    public func setMember(of receiver: MLValue, name: String, value: MLValue,
                          location: SourceLocation) throws {
        if let klass = isClassToken(receiver) {
            if let box = klass.findStaticBox(name) {
                box.value = value
                return
            }
            klass.staticStorage.define(name, value)
            return
        }
        if let object = receiver.asObject {
            if let klass = object.classDeclaration,
               let (property, owner) = klass.findProperty(name),
               let setter = property.setter {
                let scope = MLEnvironment(parent: owner.declarationEnvironment ?? globals,
                                          isFunctionScope: true)
                scope.define("self", receiver)
                scope.define("this", receiver)
                scope.define("#class", .object(classToken(owner)))
                scope.define(property.setterParameter ?? "newValue", value)
                do {
                    try execute(setter, in: scope)
                } catch let control as MLControl {
                    if case .returnValue = control { return }
                    throw control
                }
                return
            }
            object.fields[.string(name)] = value
            return
        }
        if let map = receiver.asMap {
            map[.string(name)] = value
            return
        }
        throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)).\(name) には代入できません")
    }

    // MARK: 添字

    public func subscriptValue(_ receiver: MLValue, index: MLValue,
                               location: SourceLocation) throws -> MLValue {
        switch receiver.forced {
        case .array(let array):
            guard let raw = index.asInt else {
                throw MLError.runtime("\(location) 配列の添字には整数が必要です")
            }
            guard let position = MLOperations.normalizeIndex(raw, count: array.count,
                                                             semantics: semantics) else {
                if semantics.outOfBoundsIsError {
                    throw MLError.runtime("\(location) 添字 \(raw) は範囲外です (要素数 \(array.count))")
                }
                return .unit
            }
            return array.elements[position]

        case .map(let map):
            guard let key = MLKey.from(index) else {
                throw MLError.runtime("\(location) 辞書のキーにできない値です")
            }
            if let value = map[key] { return value }
            if semantics.outOfBoundsIsError {
                throw MLError.runtime("\(location) キー \(semantics.display(index)) はありません")
            }
            return .unit

        case .string(let text):
            guard let raw = index.asInt else {
                throw MLError.runtime("\(location) 文字列の添字には整数が必要です")
            }
            let characters = Array(text)
            guard let position = MLOperations.normalizeIndex(raw, count: characters.count,
                                                             semantics: semantics) else {
                if semantics.outOfBoundsIsError {
                    throw MLError.runtime("\(location) 添字 \(raw) は範囲外です (長さ \(characters.count))")
                }
                return .unit
            }
            return .char(characters[position])

        case .tuple(let items):
            guard let raw = index.asInt,
                  let position = MLOperations.normalizeIndex(raw, count: items.count,
                                                             semantics: semantics) else {
                throw MLError.runtime("\(location) タプルの添字が範囲外です")
            }
            return items[position]

        case .object(let object):
            if let value = MLKey.from(index).flatMap({ object.fields[$0] }) { return value }
            if let raw = index.asInt, raw >= 0, Int(raw) < object.payload.count {
                return object.payload[Int(raw)]
            }
            throw MLError.runtime("\(location) \(object.typeName) は添字で引けません")

        case .range(let range):
            let elements = range.elements
            guard let raw = index.asInt,
                  let position = MLOperations.normalizeIndex(raw, count: elements.count,
                                                             semantics: semantics) else {
                throw MLError.runtime("\(location) 範囲の添字が範囲外です")
            }
            return .int(elements[position])

        default:
            throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)) は添字で引けません")
        }
    }

    public func setSubscript(of receiver: MLValue, index: MLValue, value: MLValue,
                             location: SourceLocation, in environment: MLEnvironment,
                             receiverExpr: MLExpr) throws {
        switch receiver.forced {
        case .array(let array):
            guard let raw = index.asInt else {
                throw MLError.runtime("\(location) 配列の添字には整数が必要です")
            }
            var position = Int(raw) - semantics.indexBase
            if position < 0, semantics.allowsNegativeIndexing { position += array.count }
            if position >= 0, position < array.count {
                array.elements[position] = value
                return
            }
            // 末尾への追加を許す言語 (PHP / JavaScript など) 向け。
            if position >= array.count, !semantics.outOfBoundsIsError {
                while array.count < position { array.elements.append(.unit) }
                array.elements.append(value)
                return
            }
            throw MLError.runtime("\(location) 添字 \(raw) は範囲外です (要素数 \(array.count))")

        case .map(let map):
            guard let key = MLKey.from(index) else {
                throw MLError.runtime("\(location) 辞書のキーにできない値です")
            }
            map[key] = value

        case .string(let text):
            guard let raw = index.asInt,
                  let position = MLOperations.normalizeIndex(raw, count: text.count,
                                                             semantics: semantics),
                  let replacement = value.asString?.first else {
                throw MLError.runtime("\(location) 文字列の書き換えに失敗しました")
            }
            var characters = Array(text)
            characters[position] = replacement
            try assign(to: receiverExpr, value: .string(String(characters)),
                       in: environment, location: location)

        case .object(let object):
            guard let key = MLKey.from(index) else {
                throw MLError.runtime("\(location) 添字にできない値です")
            }
            object.fields[key] = value

        default:
            throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)) には添字代入できません")
        }
    }

    public func slice(_ receiver: MLValue, from lower: MLValue, to upper: MLValue,
                      location: SourceLocation) throws -> MLValue {
        let low = Int(lower.asInt ?? 0) - semantics.indexBase
        switch receiver.forced {
        case .array(let array):
            let high = Int(upper.asInt ?? Int64(array.count + semantics.indexBase))
                - semantics.indexBase
            let start = max(0, min(low, array.count))
            let end = max(start, min(high, array.count))
            return .array(MLArray(Array(array.elements[start..<end])))
        case .string(let text):
            let characters = Array(text)
            let high = Int(upper.asInt ?? Int64(characters.count + semantics.indexBase))
                - semantics.indexBase
            let start = max(0, min(low, characters.count))
            let end = max(start, min(high, characters.count))
            return .string(String(characters[start..<end]))
        default:
            throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)) は切り出せません")
        }
    }

    // MARK: 型変換

    public func cast(_ value: MLValue, to typeName: String, isOptional: Bool,
                     location: SourceLocation) throws -> MLValue {
        if matchesType(value, typeName) { return value }
        switch typeName {
        case "Int", "int", "Integer", "Int64", "Int32", "Long", "long", "i32", "i64":
            if let number = value.asDouble { return .int(Int64(number)) }
            if let text = value.asString, let number = Int64(text.trimmingCharacters(in: .whitespaces)) {
                return .int(number)
            }
        case "Double", "double", "Float", "float", "f64", "f32", "Float64":
            if let number = value.asDouble { return .double(number) }
            if let text = value.asString, let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                return .double(number)
            }
        case "String", "string", "str":
            return .string(semantics.stringify(value))
        case "Bool", "bool", "Boolean", "boolean":
            return .bool((try? semantics.isTruthy(value)) ?? false)
        case "Char", "char", "Character":
            if let text = value.asString, let first = text.first { return .char(first) }
            if let number = value.asInt, let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                return .char(Character(scalar))
            }
        default:
            break
        }
        if isOptional { return .unit }
        throw MLError.runtime("\(location) \(semantics.typeName(of: value)) を \(typeName) には変換できません")
    }

    // MARK: 内包表記

    private func evaluateComprehension(_ comprehension: MLComprehension,
                                       in environment: MLEnvironment) throws -> MLValue {
        var results: [MLValue] = []
        let map = MLMap()

        func walk(_ index: Int, _ scope: MLEnvironment) throws {
            try tick()
            if index == comprehension.clauses.count {
                for filter in comprehension.filters
                where try !semantics.isTruthy(evaluate(filter, in: scope)) { return }
                let value = try evaluate(comprehension.element, in: scope)
                if comprehension.shape == .map, let keyExpr = comprehension.keyElement {
                    let keyValue = try evaluate(keyExpr, in: scope)
                    guard let key = MLKey.from(keyValue) else {
                        throw MLError.runtime("辞書のキーにできない値です")
                    }
                    map[key] = value
                } else {
                    results.append(value)
                }
                return
            }
            let clause = comprehension.clauses[index]
            let sequence = try evaluate(clause.sequence, in: scope)
            for element in try MLOperations.iterate(sequence, semantics: semantics) {
                let inner = MLEnvironment(parent: scope)
                guard try match(clause.pattern, value: element, into: inner) else { continue }
                try walk(index + 1, inner)
            }
        }

        try walk(0, MLEnvironment(parent: environment))
        if comprehension.shape == .map { return .map(map) }
        if comprehension.shape == .set {
            var seen: [MLValue] = []
            for value in results where !seen.contains(where: { semantics.areEqual($0, value) }) {
                seen.append(value)
            }
            return .array(MLArray(seen))
        }
        return .array(MLArray(results))
    }

    // MARK: match / switch

    @discardableResult
    func evaluateMatch(subject subjectExpr: MLExpr, arms: [MLMatchArm],
                       in environment: MLEnvironment, label: String?,
                       location: SourceLocation, asStatement: Bool) throws -> MLValue {
        let subject = try evaluate(subjectExpr, in: environment)
        var index = 0
        while index < arms.count {
            let arm = arms[index]
            let scope = MLEnvironment(parent: environment)
            var matched = arm.isDefault && arm.patterns.isEmpty
            if !matched {
                for pattern in arm.patterns
                where try match(pattern, value: subject, into: scope) {
                    matched = true
                    break
                }
                if arm.isDefault { matched = true }
            }
            if matched, let guardCondition = arm.guardCondition {
                matched = try semantics.isTruthy(evaluate(guardCondition, in: scope))
            }
            guard matched else {
                index += 1
                continue
            }
            do {
                if asStatement {
                    try execute(arm.body, in: scope)
                    // C 系 switch の落ち込み。
                    var current = index
                    while arms[current].fallsThrough, current + 1 < arms.count {
                        current += 1
                        try execute(arms[current].body, in: MLEnvironment(parent: environment))
                    }
                    return .unit
                }
                return try executeForValue(arm.body, in: scope)
            } catch let control as MLControl {
                if case .breakLoop(let target) = control, target == nil || target == label {
                    return .unit
                }
                if case .fallThrough = control, index + 1 < arms.count {
                    index += 1
                    try execute(arms[index].body, in: MLEnvironment(parent: environment))
                    return .unit
                }
                throw control
            }
        }
        if asStatement { return .unit }
        throw MLError.runtime("\(location) どの場合にも当てはまりませんでした")
    }

    // MARK: - 呼び出し

    private func evaluateCall(callee: MLExpr, arguments: [MLArgument],
                              in environment: MLEnvironment,
                              location: SourceLocation) throws -> MLValue {
        // `obj.method(...)` はメソッド呼び出しとして扱う。
        if case .member(let receiverExpr, let name, let isOptional, _) = callee {
            let receiver = try evaluate(receiverExpr, in: environment)
            if isOptional, receiver.isUnit { return .unit }
            let resolved = try resolveArguments(arguments, in: environment,
                                                boxesFor: arguments.map { $0.value },
                                                environment: environment)
            return try callMethod(on: receiver, name: name, arguments: resolved.values,
                                  labels: resolved.labels, boxes: resolved.boxes,
                                  location: location)
        }
        // `super.method(...)`
        if case .superRef = callee {
            return try callSuperInitializer(arguments: arguments, in: environment,
                                            location: location)
        }
        // 型名を関数のように呼んだらインスタンス化。
        if case .name(let name, _) = callee, environment.lookup(name) == nil,
           let klass = classes[name] {
            let resolved = try resolveArguments(arguments, in: environment)
            return try instantiate(klass, arguments: resolved.values,
                                   labels: resolved.labels, location: location)
        }

        let calleeValue = try evaluate(callee, in: environment)
        if let klass = isClassToken(calleeValue) {
            let resolved = try resolveArguments(arguments, in: environment)
            return try instantiate(klass, arguments: resolved.values,
                                   labels: resolved.labels, location: location)
        }
        let resolved = try resolveArguments(arguments, in: environment,
                                            boxesFor: arguments.map { $0.value },
                                            environment: environment)
        guard let function = calleeValue.asFunction else {
            throw MLError.runtime("\(location) \(semantics.typeName(of: calleeValue)) は呼び出せません")
        }
        return try callFunction(function, arguments: resolved.values, labels: resolved.labels,
                                boxes: resolved.boxes, location: location)
    }

    struct ResolvedArguments {
        var values: [MLValue]
        var labels: [String?]
        var boxes: [MLBox?]
    }

    func resolveArguments(_ arguments: [MLArgument], in environment: MLEnvironment,
                          boxesFor expressions: [MLExpr]? = nil,
                          environment boxEnvironment: MLEnvironment? = nil) throws -> ResolvedArguments {
        var values: [MLValue] = []
        var labels: [String?] = []
        var boxes: [MLBox?] = []
        for (index, argument) in arguments.enumerated() {
            let value = try evaluate(argument.value, in: environment)
            if argument.isSpread {
                for item in try MLOperations.iterate(value, semantics: semantics) {
                    values.append(item)
                    labels.append(nil)
                    boxes.append(nil)
                }
                continue
            }
            values.append(value)
            labels.append(argument.label)
            if let expressions, index < expressions.count, let boxEnvironment {
                boxes.append(try? resolveBox(expressions[index], in: boxEnvironment))
            } else {
                boxes.append(nil)
            }
        }
        return ResolvedArguments(values: values, labels: labels, boxes: boxes)
    }

    /// 値として持っている関数を呼ぶ (組み込みから使う入口)。
    public func callValue(_ callee: MLValue, arguments: [MLValue],
                          location: SourceLocation) throws -> MLValue {
        if let klass = isClassToken(callee) {
            return try instantiate(klass, arguments: arguments,
                                   labels: Array(repeating: nil, count: arguments.count),
                                   location: location)
        }
        guard let function = callee.asFunction else {
            throw MLError.runtime("\(location) \(semantics.typeName(of: callee)) は呼び出せません")
        }
        return try callFunction(function, arguments: arguments, location: location)
    }

    public func callFunction(_ function: MLFunction, arguments rawArguments: [MLValue],
                             labels rawLabels: [String?] = [],
                             boxes rawBoxes: [MLBox?] = [],
                             location: SourceLocation = SourceLocation(line: 0, column: 0))
        throws -> MLValue {
        let arguments = function.partialArguments + rawArguments
        var labels = rawLabels
        if labels.count < arguments.count {
            labels = Array(repeating: nil, count: arguments.count - labels.count) + labels
        }
        var boxes = rawBoxes
        if boxes.count < arguments.count {
            boxes = Array(repeating: nil, count: arguments.count - boxes.count) + boxes
        }

        switch function.body {
        case .native(let name, let arity, let impl):
            guard arguments.count >= arity.lowerBound else {
                if semantics.curriesByDefault {
                    return .function(function.applying(rawArguments))
                }
                throw MLError.runtime(
                    "\(location) \(name) には引数が \(arity.lowerBound) 個必要です (\(arguments.count) 個渡されました)")
            }
            let context = MLCallContext(arguments: arguments, labels: labels, boxes: boxes,
                                        receiver: function.boundSelf, interpreter: self,
                                        location: location)
            return try impl(context)

        case .declared(let decl):
            return try invoke([decl], receiver: function.boundSelf, owner: function.owner,
                              arguments: arguments, labels: labels, boxes: boxes,
                              closure: function.closure ?? globals, location: location,
                              partialSource: function)
        }
    }

    /// 宣言された関数を呼ぶ。節が複数あるときは当てはまるものを選ぶ。
    func invoke(_ declarations: [MLFunctionDecl], receiver: MLValue?, owner: MLClass?,
                arguments: [MLValue], labels: [String?], boxes: [MLBox?],
                closure: MLEnvironment, location: SourceLocation,
                partialSource: MLFunction? = nil) throws -> MLValue {
        callDepth += 1
        defer { callDepth -= 1 }
        if callDepth > limits.maximumCallDepth {
            throw MLError.limitExceeded(
                "関数呼び出しが深くなりすぎました (上限 \(limits.maximumCallDepth))。再帰が終わらないのかもしれません。")
        }

        // 引数の個数で多重定義を選ぶ。
        let candidates = declarations.count == 1 ? declarations
            : declarations.filter { decl in
                decl.clauses.contains { clause in
                    fits(arguments.count, clause.parameters)
                }
            }
        let pool = candidates.isEmpty ? declarations : candidates

        for decl in pool {
            for clause in decl.clauses {
                // カリー化: 引数が足りなければ部分適用した関数を返す。
                if arguments.count < requiredCount(clause.parameters) {
                    if decl.isCurried || semantics.curriesByDefault {
                        // 部分適用した関数を返す (カリー化)。
                        return .function(MLFunction(body: .declared(decl), closure: closure,
                                                    boundSelf: receiver, owner: owner,
                                                    partialArguments: arguments))
                    }
                    continue
                }
                let scope = MLEnvironment(parent: closure, isFunctionScope: true)
                if let receiver {
                    scope.define("self", receiver)
                    scope.define("this", receiver)
                }
                if let owner {
                    scope.define("#class", .object(classToken(owner)))
                    if let superclass = owner.superclass {
                        scope.define("#super", .object(classToken(superclass)))
                    }
                }
                guard try bindParameters(clause.parameters, arguments: arguments,
                                         labels: labels, boxes: boxes, into: scope,
                                         usesImplicitArguments: decl.usesImplicitArguments) else {
                    continue
                }
                if let guardCondition = clause.guardCondition,
                   try !semantics.isTruthy(evaluate(guardCondition, in: scope)) {
                    continue
                }
                do {
                    try hoist(clause.body, in: scope)
                    let last = try executeForValue(clause.body, in: scope)
                    // 関数型言語では最後の式が戻り値。
                    if let receiver, decl.isMutating, case .object(let object) = receiver.forced,
                       object.classDeclaration?.kind == .structType {
                        // mutating は self を直接書き換えているのでそのままでよい。
                    }
                    if decl.isInitializer, let receiver { return receiver }
                    return last
                } catch let control as MLControl {
                    if case .returnValue(let value) = control {
                        if decl.isInitializer, let receiver { return receiver }
                        return value
                    }
                    throw control
                }
            }
        }
        let name = declarations.first?.name ?? "関数"
        throw MLError.runtime("\(location) \(name) に当てはまる定義がありません (引数 \(arguments.count) 個)")
    }

    private func requiredCount(_ parameters: [MLParameter]) -> Int {
        parameters.filter { $0.defaultValue == nil && !$0.isVariadic }.count
    }

    private func fits(_ count: Int, _ parameters: [MLParameter]) -> Bool {
        if parameters.contains(where: { $0.isVariadic }) {
            return count >= requiredCount(parameters)
        }
        return count >= requiredCount(parameters) && count <= parameters.count
    }

    private func bindParameters(_ parameters: [MLParameter], arguments: [MLValue],
                                labels: [String?], boxes: [MLBox?],
                                into scope: MLEnvironment,
                                usesImplicitArguments: Bool) throws -> Bool {
        if usesImplicitArguments && parameters.isEmpty {
            // `$0` / `it` / `_` を使うクロージャ。
            for (index, value) in arguments.enumerated() {
                scope.define("$\(index)", value)
                scope.define("_\(index + 1)", value)
            }
            if let first = arguments.first {
                scope.define("it", first)
                scope.define("_", first)
            }
            scope.define("#args", .array(MLArray(arguments)))
            return true
        }

        // ラベル付き引数を先に振り分ける。
        var positional: [MLValue] = []
        var positionalBoxes: [MLBox?] = []
        var named: [String: MLValue] = [:]
        for (index, value) in arguments.enumerated() {
            let label = index < labels.count ? labels[index] : nil
            if let label, parameters.contains(where: { ($0.label ?? $0.name) == label }) {
                named[label] = value
            } else {
                positional.append(value)
                positionalBoxes.append(index < boxes.count ? boxes[index] : nil)
            }
        }

        var cursor = 0
        for parameter in parameters {
            if parameter.isVariadic {
                let rest = Array(positional[min(cursor, positional.count)...])
                scope.define(parameter.name, .array(MLArray(rest)))
                cursor = positional.count
                continue
            }
            var value: MLValue?
            if let named = named[parameter.label ?? parameter.name] {
                value = named
            } else if cursor < positional.count {
                value = positional[cursor]
                if parameter.isByReference, let box = positionalBoxes[cursor] {
                    scope.defineBox(parameter.name, box)
                    cursor += 1
                    continue
                }
                cursor += 1
            } else if let defaultValue = parameter.defaultValue {
                value = try evaluate(defaultValue, in: scope)
            } else if let typeName = parameter.typeName {
                value = semantics.defaultValue(forTypeName: typeName)
                if value!.isUnit { return false }
            } else {
                return false
            }
            guard var bound = value else { return false }
            bound = semantics.coerce(bound, toTypeName: parameter.typeName)
            if semantics.usesValueSemantics, !parameter.isByReference {
                bound = copyForBinding(bound)
            }
            if let pattern = parameter.pattern {
                let probe = MLEnvironment(parent: scope)
                guard try match(pattern, value: bound, into: probe) else { return false }
                for name in pattern.boundNames {
                    if let box = probe.lookupLocal(name) { scope.defineBox(name, box) }
                }
                if !parameter.name.isEmpty, parameter.name != "_" {
                    scope.define(parameter.name, bound)
                }
            } else {
                scope.define(parameter.name, bound, typeName: parameter.typeName)
            }
        }
        // 余った実引数は可変長引数として拾えるようにしておく。
        if cursor < positional.count {
            scope.define("#rest", .array(MLArray(Array(positional[cursor...]))))
        }
        scope.define("#args", .array(MLArray(arguments)))
        return true
    }

    // MARK: メソッド呼び出し

    public func callMethod(on receiver: MLValue, name: String, arguments: [MLValue],
                           labels: [String?] = [], boxes: [MLBox?] = [],
                           location: SourceLocation) throws -> MLValue {
        let context = MLCallContext(arguments: arguments, labels: labels, boxes: boxes,
                                    receiver: receiver, interpreter: self, location: location)
        if let custom = try semantics.callMember(of: receiver, name: name,
                                                 arguments: arguments, context: context) {
            return custom
        }

        if let klass = isClassToken(receiver) {
            if let found = klass.findStaticMethod(name) {
                return try invoke(found.decls, receiver: nil, owner: found.owner,
                                  arguments: arguments, labels: labels, boxes: boxes,
                                  closure: klass.declarationEnvironment ?? globals,
                                  location: location)
            }
            if let box = klass.findStaticBox(name), let function = box.value.asFunction {
                return try callFunction(function, arguments: arguments, labels: labels,
                                        boxes: boxes, location: location)
            }
            if let enumCase = klass.cases[name] {
                return try callFunction(caseConstructor(klass: klass, enumCase: enumCase),
                                        arguments: arguments, location: location)
            }
            if let found = klass.findMethod(name) {
                // 静的呼び出しとして許す言語もある。
                return try invoke(found.decls, receiver: nil, owner: found.owner,
                                  arguments: arguments, labels: labels, boxes: boxes,
                                  closure: klass.declarationEnvironment ?? globals,
                                  location: location)
            }
        }

        if let object = receiver.asObject, let klass = object.classDeclaration {
            if let found = klass.findMethod(name) {
                return try invoke(found.decls, receiver: receiver, owner: found.owner,
                                  arguments: arguments, labels: labels, boxes: boxes,
                                  closure: klass.declarationEnvironment ?? globals,
                                  location: location)
            }
            if let found = klass.findStaticMethod(name) {
                return try invoke(found.decls, receiver: nil, owner: found.owner,
                                  arguments: arguments, labels: labels, boxes: boxes,
                                  closure: klass.declarationEnvironment ?? globals,
                                  location: location)
            }
        }
        // フィールドに入っている関数。
        if let object = receiver.asObject, let stored = object.fields[.string(name)],
           let function = stored.asFunction {
            return try callFunction(function, arguments: arguments, labels: labels,
                                    boxes: boxes, location: location)
        }
        if let map = receiver.asMap, let stored = map[.string(name)],
           let function = stored.asFunction {
            return try callFunction(function, arguments: arguments, labels: labels,
                                    boxes: boxes, location: location)
        }
        // 組み込み型のメソッド。
        if let value = try MLStdlib.callMethod(on: receiver, name: name, context: context) {
            return value
        }
        // 最後にプロパティとして取り出して呼んでみる。
        if let stored = try? member(of: receiver, name: name, location: location),
           let function = stored.asFunction {
            return try callFunction(function, arguments: arguments, labels: labels,
                                    boxes: boxes, location: location)
        }
        throw MLError.runtime("\(location) \(semantics.typeName(of: receiver)) に \(name) というメソッドはありません")
    }

    private func callSuperInitializer(arguments: [MLArgument], in environment: MLEnvironment,
                                      location: SourceLocation) throws -> MLValue {
        guard let selfBox = environment.lookup("self"),
              let superBox = environment.lookup("#super"),
              let superclass = isClassToken(superBox.value) else {
            throw MLError.runtime("\(location) super の呼び出し先が分かりません")
        }
        let resolved = try resolveArguments(arguments, in: environment)
        try runInitializer(of: superclass, on: selfBox.value, arguments: resolved.values,
                           labels: resolved.labels, location: location)
        return selfBox.value
    }

    // MARK: インスタンス生成

    public func instantiate(_ klass: MLClass, arguments: [MLValue], labels: [String?],
                            location: SourceLocation) throws -> MLValue {
        if klass.isAbstract {
            throw MLError.runtime("\(location) 抽象型 \(klass.name) はそのまま作れません")
        }
        let object = MLObject(typeName: klass.name, classDeclaration: klass)
        try initializeFields(of: klass, on: object)
        let value = MLValue.object(object)
        try runInitializer(of: klass, on: value, arguments: arguments, labels: labels,
                           location: location)
        return value
    }

    /// 祖先から順に既定値を入れる。
    private func initializeFields(of klass: MLClass, on object: MLObject) throws {
        for ancestor in klass.lineage.reversed() {
            let scope = MLEnvironment(parent: ancestor.declarationEnvironment ?? globals)
            scope.define("self", .object(object))
            scope.define("this", .object(object))
            for property in ancestor.properties where !property.isStatic {
                if property.getter != nil { continue }
                let value: MLValue
                if let expression = property.defaultValue {
                    value = try evaluate(expression, in: scope)
                } else {
                    value = semantics.defaultValue(forTypeName: property.typeName)
                }
                object.fields[.string(property.name)] = value
            }
        }
    }

    private func runInitializer(of klass: MLClass, on receiver: MLValue,
                                arguments: [MLValue], labels: [String?],
                                location: SourceLocation) throws {
        // 主コンストラクタ引数 (Kotlin / Scala 形式)。
        if !klass.primaryParameters.isEmpty || klass.initializers.isEmpty {
            if !klass.primaryParameters.isEmpty {
                let object = receiver.asObject
                for (index, parameter) in klass.primaryParameters.enumerated() {
                    var value: MLValue = .unit
                    if let named = labels.firstIndex(where: { $0 == (parameter.label ?? parameter.name) }),
                       named < arguments.count {
                        value = arguments[named]
                    } else if index < arguments.count {
                        value = arguments[index]
                    } else if let defaultValue = parameter.defaultValue {
                        value = try evaluate(defaultValue,
                                             in: klass.declarationEnvironment ?? globals)
                    } else {
                        value = semantics.defaultValue(forTypeName: parameter.typeName)
                    }
                    object?.fields[.string(parameter.name)] = value
                }
            }
        }

        // クラス本体の初期化文。
        if !klass.bodyStatements.isEmpty {
            let scope = MLEnvironment(parent: klass.declarationEnvironment ?? globals,
                                      isFunctionScope: true)
            scope.define("self", receiver)
            scope.define("this", receiver)
            scope.define("#class", .object(classToken(klass)))
            if let superclass = klass.superclass {
                scope.define("#super", .object(classToken(superclass)))
            }
            if let object = receiver.asObject {
                for (key, value) in object.fields.pairs {
                    if case .string(let name) = key { scope.define(name, value) }
                }
            }
            try execute(klass.bodyStatements, in: scope)
            // 本体で定義された名前をフィールドとして取り込む。
            if let object = receiver.asObject {
                for name in scope.localNames where !name.hasPrefix("#") && name != "self"
                    && name != "this" {
                    if let box = scope.lookupLocal(name) {
                        object.fields[.string(name)] = box.value
                    }
                }
            }
        }

        guard !klass.initializers.isEmpty else {
            // コンストラクタが無ければ引数をフィールド順に入れる (構造体の既定生成)。
            if klass.primaryParameters.isEmpty, let object = receiver.asObject,
               !arguments.isEmpty {
                let names = klass.lineage.reversed()
                    .flatMap { $0.properties.filter { !$0.isStatic && $0.getter == nil } }
                    .map { $0.name }
                for (index, value) in arguments.enumerated() {
                    if let label = index < labels.count ? labels[index] : nil,
                       names.contains(label) {
                        object.fields[.string(label)] = value
                    } else if index < names.count {
                        object.fields[.string(names[index])] = value
                    }
                }
            }
            return
        }
        _ = try invoke(klass.initializers, receiver: receiver, owner: klass,
                       arguments: arguments, labels: labels,
                       boxes: Array(repeating: nil, count: arguments.count),
                       closure: klass.declarationEnvironment ?? globals, location: location)
    }
}

// MARK: - 箱のいろいろ

/// オブジェクトのフィールドを指す箱。
final class MLFieldBox: MLBox {
    private let object: MLObject
    private let key: MLKey

    init(object: MLObject, key: MLKey) {
        self.object = object
        self.key = key
        super.init(object.fields[key] ?? .unit)
    }

    override var value: MLValue {
        get { object.fields[key] ?? .unit }
        set { object.fields[key] = newValue }
    }
}

/// 辞書の 1 要素を指す箱。
final class MLMapBox: MLBox {
    private let map: MLMap
    private let key: MLKey

    init(map: MLMap, key: MLKey) {
        self.map = map
        self.key = key
        super.init(map[key] ?? .unit)
    }

    override var value: MLValue {
        get { map[key] ?? .unit }
        set { map[key] = newValue }
    }
}

/// 配列の 1 要素を指す箱。
final class MLElementBox: MLBox {
    private let array: MLArray
    private let index: Int

    init(array: MLArray, index: Int) {
        self.array = array
        self.index = index
        super.init(index < array.count ? array.elements[index] : .unit)
    }

    override var value: MLValue {
        get { index < array.count ? array.elements[index] : .unit }
        set { if index < array.count { array.elements[index] = newValue } }
    }
}
