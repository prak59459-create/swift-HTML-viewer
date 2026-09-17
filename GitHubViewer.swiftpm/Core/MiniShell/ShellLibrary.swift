import Foundation

/// シェルらしい振る舞い。
final class ShellSemantics: MLSemantics {
    override var languageID: String { "shell" }
    override var displayName: String { "内蔵シェル処理系" }
    override var requiresDefinitionBeforeUse: Bool { false }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    /// 条件は「終了状態が 0 なら成功」。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .int(let status): return status == 0
        case .bool(let flag): return flag
        case .unit: return false
        case .string(let text): return !text.isEmpty
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .array: return "array"
        case .int: return "integer"
        default: return "string"
        }
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "1" : "0"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            return array.elements.map { display($0) }.joined(separator: " ")
        default: return MLDisplay.plain(value, semantics: self)
        }
    }

    override func stringify(_ value: MLValue) -> String { display(value) }

    /// 文字列も数として計算できるようにする。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case "+", "-", "*", "/", "%":
            guard lhs.asString != nil || rhs.asString != nil else { return nil }
            return try MLOperations.arithmetic(op: op, lhs: .int(number(lhs)),
                                               rhs: .int(number(rhs)), semantics: self)
        case "==", "!=", "<", ">", "<=", ">=":
            guard lhs.asString != nil, rhs.asString != nil else { return nil }
            let left = display(lhs), right = display(rhs)
            switch op {
            case "==": return .bool(left == right)
            case "!=": return .bool(left != right)
            case "<": return .bool(left < right)
            case ">": return .bool(left > right)
            case "<=": return .bool(left <= right)
            default: return .bool(left >= right)
            }
        default:
            return nil
        }
    }

    /// 文字列を数として読む。
    func number(_ value: MLValue) -> Int64 {
        switch value.forced {
        case .int(let number): return number
        case .double(let number): return Int64(number)
        case .bool(let flag): return flag ? 1 : 0
        case .string(let text): return Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        ShellLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }
}

/// シェルの組み込みコマンド。
enum ShellLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    /// 単語を並べる (配列は要素ごとにばらす)。
    static func words(_ values: [MLValue], semantics: ShellSemantics) -> [String] {
        var result: [String] = []
        for value in values {
            if let array = value.asArray {
                result += array.elements.map { semantics.display($0) }
                continue
            }
            result.append(semantics.display(value))
        }
        return result
    }

    static func install(into environment: MLEnvironment, semantics: ShellSemantics,
                        interpreter: MLInterpreter) {
        environment.define("?", .int(0))
        environment.define("#argv", .array(MLArray()))
        environment.define("IFS", .string(" "))
        environment.define("HOME", .string("/root"))
        environment.define("PWD", .string("/"))

        /// コマンドを 1 つ走らせる。
        environment.define("#run", function("#run", 1...256) { context in
            let parts = words(context.arguments, semantics: semantics)
            guard let name = parts.first else { return .int(0) }
            let arguments = Array(parts.dropFirst())
            let status = try run(name: name, arguments: arguments, context: context,
                                 semantics: semantics)
            context.interpreter.globals.define("?", .int(Int64(status)))
            return .int(Int64(status))
        })

        environment.define("#words", function("#words", 0...256) { context in
            var elements: [MLValue] = []
            for value in context.arguments {
                if let array = value.asArray {
                    elements += array.elements
                    continue
                }
                // 単語は空白で分ける。
                let text = semantics.display(value)
                if text.contains(" ") || text.contains("\n") {
                    elements += text.split(whereSeparator: { $0.isWhitespace })
                        .map { .string(String($0)) }
                } else if !text.isEmpty {
                    elements.append(.string(text))
                }
            }
            return .array(MLArray(elements))
        })

        environment.define("#andThen", function("#andThen", 2) { context in
            guard try semantics.isTruthy(context.argument(0)) else { return context.argument(0) }
            let body = try context.requireFunction(1, "&&")
            return try context.interpreter.callFunction(body, arguments: [],
                                                        location: context.location)
        })
        environment.define("#orElse", function("#orElse", 2) { context in
            guard try !semantics.isTruthy(context.argument(0)) else {
                return context.argument(0)
            }
            let body = try context.requireFunction(1, "||")
            return try context.interpreter.callFunction(body, arguments: [],
                                                        location: context.location)
        })
        environment.define("#not", function("#not", 1) { context in
            .int(try semantics.isTruthy(context.argument(0)) ? 1 : 0)
        })
        environment.define("#status", function("#status", 1) { context in
            .int(try semantics.isTruthy(context.argument(0)) ? 0 : 1)
        })
        environment.define("#truthy", function("#truthy", 1) { context in
            .bool(semantics.number(context.argument(0)) != 0)
        })
        environment.define("#length", function("#length", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count)) }
            return .int(Int64(semantics.display(value).count))
        })
        environment.define("#default", function("#default", 2) { context in
            let value = context.argument(0)
            if value.isUnit || semantics.display(value).isEmpty {
                return context.argument(1)
            }
            return value
        })
        environment.define("#trimPrefix", function("#trimPrefix", 2) { context in
            let text = semantics.display(context.argument(0))
            let prefix = semantics.display(context.argument(1))
                .replacingOccurrences(of: "*", with: "")
            guard text.hasPrefix(prefix) else { return .string(text) }
            return .string(String(text.dropFirst(prefix.count)))
        })
        environment.define("#argc", function("#argc", 0) { context in
            .int(Int64(context.interpreter.globals.lookup("#argv")?
                .value.asArray?.count ?? 0))
        })
        environment.define("#arg", function("#arg", 1) { context in
            let index = Int(context.argument(0).asInt ?? 0) - 1
            guard index >= 0,
                  let array = context.interpreter.globals.lookup("#argv")?.value.asArray,
                  index < array.count else { return .string("") }
            return array.elements[index]
        })

        // コマンド置換。
        environment.define("#capture", function("#capture", 1) { context in
            let body = try context.requireFunction(0, "コマンド置換")
            var thrown: Error?
            let text = context.interpreter.capturingOutput {
                do {
                    _ = try context.interpreter.callFunction(body, arguments: [],
                                                             location: context.location)
                } catch { thrown = error }
            }
            if let thrown { throw thrown }
            // 末尾の改行は落とす。
            var trimmed = text
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            return .string(trimmed)
        })

        // パイプ。左の出力を右の標準入力にする。
        environment.define("#pipeline", function("#pipeline", 1...32) { context in
            var carried = ""
            var status: MLValue = .int(0)
            for (index, value) in context.arguments.enumerated() {
                guard let stage = value.asFunction else { continue }
                let isLast = index == context.arguments.count - 1
                context.interpreter.globals.define("#stdin", .string(carried))
                if isLast {
                    status = try context.interpreter.callFunction(
                        stage, arguments: [], location: context.location)
                } else {
                    var thrown: Error?
                    carried = context.interpreter.capturingOutput {
                        do {
                            status = try context.interpreter.callFunction(
                                stage, arguments: [], location: context.location)
                        } catch { thrown = error }
                    }
                    if let thrown { throw thrown }
                }
            }
            context.interpreter.globals.define("#stdin", .string(""))
            return status
        })

        // `test` / `[ ... ]`
        environment.define("#test", function("#test", 0...64) { context in
            .int(Int64(try test(words(context.arguments, semantics: semantics)) ? 0 : 1))
        })
    }

    /// 1 つのコマンドを実行する。戻り値は終了状態。
    static func run(name: String, arguments: [String], context: MLCallContext,
                    semantics: ShellSemantics) throws -> Int {
        let interpreter = context.interpreter

        // 利用者が定義した関数。
        if let box = interpreter.globals.lookup(name), let function = box.value.asFunction {
            let previous = interpreter.globals.lookup("#argv")?.value
            interpreter.globals.define("#argv",
                                       .array(MLArray(arguments.map { .string($0) })))
            defer { interpreter.globals.define("#argv", previous ?? .array(MLArray())) }
            let result = try interpreter.callFunction(function,
                                                      arguments: arguments.map { .string($0) },
                                                      location: context.location)
            return Int(result.asInt ?? 0)
        }

        switch name {
        case "echo":
            var items = arguments
            var newline = true
            if items.first == "-n" {
                newline = false
                items.removeFirst()
            }
            if items.first == "-e" { items.removeFirst() }
            interpreter.write(items.joined(separator: " ") + (newline ? "\n" : ""))
            return 0
        case "printf":
            guard let pattern = arguments.first else { return 0 }
            // 数に見える引数は数として渡す (`%d` のため)。
            let rest = arguments.dropFirst().map { text -> MLValue in
                if let number = Int64(text) { return .int(number) }
                if let number = Double(text) { return .double(number) }
                return .string(text)
            }
            interpreter.write(try MLStdlib.format(unescaped(pattern),
                                                  arguments: Array(rest),
                                                  semantics: semantics))
            return 0
        case "true", ":":
            return 0
        case "false":
            return 1
        case "test", "[":
            var items = arguments
            if items.last == "]" { items.removeLast() }
            return try test(items) ? 0 : 1
        case "read":
            let line = interpreter.input.nextLine()
            guard let line else { return 1 }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (index, variable) in arguments.enumerated() where !variable.hasPrefix("-") {
                if index == arguments.count - 1 {
                    interpreter.globals.define(
                        variable, .string(parts.dropFirst(index).joined(separator: " ")))
                } else {
                    interpreter.globals.define(variable,
                                               .string(index < parts.count ? parts[index] : ""))
                }
            }
            return 0
        case "exit":
            throw MLError.exit(Int32(arguments.first.flatMap { Int32($0) } ?? 0))
        case "seq":
            let numbers = arguments.compactMap { Int($0) }
            let from = numbers.count > 1 ? numbers[0] : 1
            let to = numbers.last ?? 0
            let step = numbers.count > 2 ? numbers[1] : 1
            var current = from
            var lines: [String] = []
            while step > 0 ? current <= to : current >= to {
                lines.append(String(current))
                current += step == 0 ? 1 : step
            }
            interpreter.write(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            return 0
        case "cat":
            interpreter.write(standardInput(interpreter))
            return 0
        case "wc":
            let text = standardInput(interpreter)
            if arguments.contains("-l") {
                let count = text.isEmpty ? 0 : text.split(separator: "\n",
                                                          omittingEmptySubsequences: false)
                    .filter { !$0.isEmpty }.count
                interpreter.write("\(count)\n")
                return 0
            }
            if arguments.contains("-w") {
                interpreter.write("\(text.split(whereSeparator: { $0.isWhitespace }).count)\n")
                return 0
            }
            interpreter.write("\(text.count)\n")
            return 0
        case "head", "tail":
            let text = standardInput(interpreter)
            var count = 10
            if let flag = arguments.firstIndex(of: "-n"), flag + 1 < arguments.count {
                count = Int(arguments[flag + 1]) ?? 10
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.isEmpty }
            let picked = name == "head" ? Array(lines.prefix(count))
                                        : Array(lines.suffix(count))
            interpreter.write(picked.joined(separator: "\n") + (picked.isEmpty ? "" : "\n"))
            return 0
        case "sort":
            let text = standardInput(interpreter)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.isEmpty }
            if arguments.contains("-n") {
                lines.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
            } else {
                lines.sort()
            }
            if arguments.contains("-r") { lines.reverse() }
            interpreter.write(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            return 0
        case "uniq":
            let text = standardInput(interpreter)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.isEmpty }
            var result: [String] = []
            for line in lines where result.last != line { result.append(line) }
            interpreter.write(result.joined(separator: "\n") + (result.isEmpty ? "" : "\n"))
            return 0
        case "grep":
            let text = standardInput(interpreter)
            guard let pattern = arguments.first(where: { !$0.hasPrefix("-") }) else {
                return 1
            }
            let inverted = arguments.contains("-v")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).filter { !$0.isEmpty }
            let picked = lines.filter { $0.contains(pattern) != inverted }
            interpreter.write(picked.joined(separator: "\n") + (picked.isEmpty ? "" : "\n"))
            return picked.isEmpty ? 1 : 0
        case "tr":
            let text = standardInput(interpreter)
            guard arguments.count >= 2 else { return 1 }
            let from = expandedSet(arguments[0]), to = expandedSet(arguments[1])
            var result = ""
            for character in text {
                if let index = from.firstIndex(of: character) {
                    result.append(index < to.count ? to[index] : (to.last ?? character))
                } else {
                    result.append(character)
                }
            }
            interpreter.write(result)
            return 0
        case "expr":
            let joined = arguments.joined(separator: " ")
            let lexer = ShellArithmeticLexer(source: joined,
                                             diagnostics: DiagnosticBag(source: joined))
            let parser = ShellArithmeticParser(tokens: lexer.tokenize(),
                                               diagnostics: DiagnosticBag(source: joined))
            guard let expression = try? parser.parseExpression() else { return 1 }
            let value = try interpreter.evaluate(expression, in: interpreter.globals)
            interpreter.write(semantics.display(value) + "\n")
            return 0
        case "let":
            for argument in arguments {
                let lexer = ShellArithmeticLexer(source: argument,
                                                 diagnostics: DiagnosticBag(source: argument))
                let parser = ShellArithmeticParser(
                    tokens: lexer.tokenize(), diagnostics: DiagnosticBag(source: argument))
                guard let expression = try? parser.parseExpression() else { continue }
                _ = try interpreter.evaluate(expression, in: interpreter.globals)
            }
            return 0
        case "unset":
            for argument in arguments { interpreter.globals.define(argument, .unit) }
            return 0
        case "shift":
            guard let array = interpreter.globals.lookup("#argv")?.value.asArray,
                  !array.elements.isEmpty else { return 1 }
            array.elements.removeFirst()
            return 0
        case "source", ".", "export", "set", "shopt", "trap", "umask", "cd", "sleep",
             "local", "declare", "readonly":
            return 0
        case "basename":
            guard let path = arguments.first else { return 1 }
            interpreter.write((path as NSString).lastPathComponent + "\n")
            return 0
        case "dirname":
            guard let path = arguments.first else { return 1 }
            interpreter.write((path as NSString).deletingLastPathComponent + "\n")
            return 0
        case "date":
            interpreter.write("(date)\n")
            return 0
        default:
            throw MLError.runtime("\(name): command not found")
        }
    }

    /// パイプで渡ってきた入力。
    private static func standardInput(_ interpreter: MLInterpreter) -> String {
        if let box = interpreter.globals.lookup("#stdin"), let text = box.value.asString,
           !text.isEmpty {
            return text
        }
        var lines: [String] = []
        while let line = interpreter.input.nextLine() { lines.append(line) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// `tr` の引数を文字の並びにする (`a-z` の範囲と `\n` の書き方に対応)。
    static func expandedSet(_ text: String) -> [Character] {
        let characters = Array(unescaped(text))
        var result: [Character] = []
        var index = 0
        while index < characters.count {
            if index + 2 < characters.count, characters[index + 1] == "-",
               let lower = characters[index].unicodeScalars.first?.value,
               let upper = characters[index + 2].unicodeScalars.first?.value,
               lower <= upper {
                for code in lower...upper {
                    if let scalar = Unicode.Scalar(code) { result.append(Character(scalar)) }
                }
                index += 3
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    /// `printf` の `\n` などを本当の文字にする。
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                switch characters[index + 1] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default:
                    result.append(characters[index])
                    result.append(characters[index + 1])
                }
                index += 2
                continue
            }
            result.append(characters[index])
            index += 1
        }
        characters = []
        return result
    }

    /// `test` の判定。
    static func test(_ arguments: [String]) throws -> Bool {
        var items = arguments
        if items.first == "!" {
            items.removeFirst()
            return !(try test(items))
        }
        switch items.count {
        case 0:
            return false
        case 1:
            return !items[0].isEmpty
        case 2:
            switch items[0] {
            case "-z": return items[1].isEmpty
            case "-n": return !items[1].isEmpty
            case "-e", "-f", "-d": return false
            default: return !items[1].isEmpty
            }
        default:
            let left = items[0], op = items[1], right = items[2]
            switch op {
            case "=", "==": return left == right
            case "!=": return left != right
            case "<": return left < right
            case ">": return left > right
            case "-eq": return (Int(left) ?? 0) == (Int(right) ?? 0)
            case "-ne": return (Int(left) ?? 0) != (Int(right) ?? 0)
            case "-lt": return (Int(left) ?? 0) < (Int(right) ?? 0)
            case "-le": return (Int(left) ?? 0) <= (Int(right) ?? 0)
            case "-gt": return (Int(left) ?? 0) > (Int(right) ?? 0)
            case "-ge": return (Int(left) ?? 0) >= (Int(right) ?? 0)
            case "-a": return try test([left]) && test(Array(items.dropFirst(2)))
            case "-o": return try test([left]) || test(Array(items.dropFirst(2)))
            default: return !left.isEmpty
            }
        }
    }
}
