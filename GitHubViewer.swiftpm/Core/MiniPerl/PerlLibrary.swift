import Foundation

/// Perl らしい振る舞い。
final class PerlSemantics: MLSemantics {
    override var languageID: String { "perl" }
    override var displayName: String { "内蔵 Perl 処理系" }
    override var requiresDefinitionBeforeUse: Bool { false }
    override var integerDivisionTruncatesTowardZero: Bool { true }
    /// `/` は常に小数を返す (整数に割り切れても 3/2 は 1.5)。
    override var divisionAlwaysProducesDouble: Bool { true }

    /// 0・空文字・"0"・undef・空リストが偽。
    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .unit: return false
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .string(let text): return !text.isEmpty && text != "0"
        case .array(let array): return !array.elements.isEmpty
        case .map(let map): return map.count > 0
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "undef"
        case .array: return "ARRAY"
        case .map: return "HASH"
        case .function: return "CODE"
        case .object(let object): return object.typeName
        default: return "SCALAR"
        }
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return ""
        case .bool(let flag): return flag ? "1" : ""
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array): return array.elements.map { display($0) }.joined()
        case .map(let map):
            return map.pairs.map { display($0.key.asValue) + display($0.value) }.joined()
        default: return MLDisplay.plain(value, semantics: self)
        }
    }

    /// Perl は 15 桁の有効数字で書く (`1/3` は 0.333333333333333)。
    override func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.15g", value)
        if text.contains("e") {
            text = text.replacingOccurrences(of: "e", with: "e")
        }
        return text
    }

    /// 文字列に埋め込むとき、配列は空白で区切る (`"@list"`)。
    override func stringify(_ value: MLValue) -> String {
        if let array = value.forced.asArray {
            return array.elements.map { display($0) }.joined(separator: " ")
        }
        return display(value)
    }

    /// 文字列と数の比較は演算子で決まる。
    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        switch op {
        case ".":
            return .string(display(lhs) + display(rhs))
        case "x":
            let count = Int(numeric(rhs).asInt ?? 0)
            if let array = lhs.asArray {
                var elements: [MLValue] = []
                for _ in 0..<Swift.max(0, count) { elements += array.elements }
                return .array(MLArray(elements))
            }
            return .string(String(repeating: display(lhs), count: Swift.max(0, count)))
        case "eq": return .bool(display(lhs) == display(rhs))
        case "ne": return .bool(display(lhs) != display(rhs))
        case "lt": return .bool(display(lhs) < display(rhs))
        case "gt": return .bool(display(lhs) > display(rhs))
        case "le": return .bool(display(lhs) <= display(rhs))
        case "ge": return .bool(display(lhs) >= display(rhs))
        case "cmp":
            let left = display(lhs), right = display(rhs)
            return .int(left == right ? 0 : (left < right ? -1 : 1))
        case "<=>":
            let left = numericDouble(lhs), right = numericDouble(rhs)
            return .int(left == right ? 0 : (left < right ? -1 : 1))
        case "==", "!=", "<", ">", "<=", ">=":
            // 数として比べる。
            let left = numericDouble(lhs), right = numericDouble(rhs)
            switch op {
            case "==": return .bool(left == right)
            case "!=": return .bool(left != right)
            case "<": return .bool(left < right)
            case ">": return .bool(left > right)
            case "<=": return .bool(left <= right)
            default: return .bool(left >= right)
            }
        case "+", "-", "*", "%", "**":
            // 文字列でも数として計算する。
            return try MLOperations.arithmetic(op: op, lhs: numeric(lhs), rhs: numeric(rhs),
                                               semantics: self)
        case "/":
            let right = numericDouble(rhs)
            guard right != 0 else { throw MLError.runtime("Illegal division by zero") }
            let result = numericDouble(lhs) / right
            if result == result.rounded(), Swift.abs(result) < 1e15 {
                return .int(Int64(result))
            }
            return .double(result)
        default:
            return nil
        }
    }

    /// 文字列を数として読む (Perl は先頭の数字だけ見る)。
    func numeric(_ value: MLValue) -> MLValue {
        switch value.forced {
        case .string(let text):
            var digits = ""
            var sawDot = false
            for character in text.trimmingCharacters(in: .whitespaces) {
                if character.isNumber { digits.append(character) }
                else if character == "." && !sawDot { sawDot = true; digits.append(character) }
                else if (character == "-" || character == "+") && digits.isEmpty {
                    digits.append(character)
                } else { break }
            }
            if sawDot { return .double(Double(digits) ?? 0) }
            return .int(Int64(digits) ?? 0)
        case .array(let array): return .int(Int64(array.elements.count))
        case .unit: return .int(0)
        case .bool(let flag): return .int(flag ? 1 : 0)
        default: return value.forced
        }
    }

    func numericDouble(_ value: MLValue) -> Double {
        let number = numeric(value)
        return number.asDouble ?? Double(number.asInt ?? 0)
    }

    override func installBuiltins(into environment: MLEnvironment,
                                  interpreter: MLInterpreter) {
        PerlLibrary.install(into: environment, semantics: self, interpreter: interpreter)
    }

    /// `scalar(@list)` のように、配列を数の文脈で使ったら要素数。
    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }
}

/// Perl の組み込み関数。
enum PerlLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    /// 正規表現オブジェクト (模様と旗を持つ)。
    static func pattern(_ source: String, _ flags: String) -> MLObject {
        let object = MLObject(typeName: "Regexp")
        object.fields[.string("pattern")] = .string(source)
        object.fields[.string("flags")] = .string(flags)
        return object
    }

    static func regex(from value: MLValue, extraFlags: String = "") throws
        -> NSRegularExpression {
        var source = ""
        var flags = extraFlags
        if let object = value.asObject, object.typeName == "Regexp" {
            source = object.fields[.string("pattern")]?.asString ?? ""
            flags += object.fields[.string("flags")]?.asString ?? ""
        } else {
            source = value.asString ?? ""
        }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        do {
            return try NSRegularExpression(pattern: source, options: options)
        } catch {
            throw MLError.runtime("正規表現が読めません: /\(source)/")
        }
    }

    /// `$1` などの捕捉を大域に置く。
    static func storeCaptures(_ match: NSTextCheckingResult, in text: String,
                              interpreter: MLInterpreter) {
        guard match.numberOfRanges > 1 else { return }
        for group in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: group), in: text) else { continue }
            interpreter.globals.define("$\(group)", .string(String(text[range])))
        }
    }

    static func install(into environment: MLEnvironment, semantics: PerlSemantics,
                        interpreter: MLInterpreter) {
        MLStdlib.installCommon(into: environment, interpreter: interpreter)
        environment.define("$_", .string(""))
        environment.define("$0", .string("script.pl"))

        environment.define("print", function("print", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            context.interpreter.write(text)
            return .int(1)
        })
        environment.define("say", function("say", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            context.interpreter.write(text + "\n")
            return .int(1)
        })
        environment.define("printf", function("printf", 1...64) { context in
            let pattern = try context.requireString(0, "printf")
            let text = try MLStdlib.format(pattern, arguments: Array(context.arguments.dropFirst()),
                                       semantics: semantics)
            context.interpreter.write(text)
            return .int(1)
        })
        environment.define("sprintf", function("sprintf", 1...64) { context in
            let pattern = try context.requireString(0, "sprintf")
            return .string(try MLStdlib.format(pattern, arguments: Array(context.arguments.dropFirst()),
                                           semantics: semantics))
        })
        environment.define("die", function("die", 0...64) { context in
            let text = context.arguments.map { semantics.display($0) }.joined()
            throw MLError.thrown(.string(text.isEmpty ? "Died" : text))
        })
        environment.define("warn", function("warn", 0...64) { _ in .int(1) })

        // 配列。
        environment.define("push", function("push", 1...64) { context in
            guard let array = context.argument(0).asArray else {
                throw MLError.runtime("push: 配列が必要です")
            }
            for value in context.arguments.dropFirst() {
                if let inner = value.asArray, inner !== array {
                    array.elements.append(contentsOf: inner.elements)
                } else {
                    array.elements.append(value)
                }
            }
            return .int(Int64(array.count))
        })
        environment.define("unshift", function("unshift", 1...64) { context in
            guard let array = context.argument(0).asArray else {
                throw MLError.runtime("unshift: 配列が必要です")
            }
            array.elements.insert(contentsOf: context.arguments.dropFirst(), at: 0)
            return .int(Int64(array.count))
        })
        environment.define("pop", function("pop", 0...1) { context in
            guard let array = context.optionalArgument(0)?.asArray,
                  !array.elements.isEmpty else { return .unit }
            return array.elements.removeLast()
        })
        environment.define("shift", function("shift", 0...1) { context in
            guard let array = context.optionalArgument(0)?.asArray,
                  !array.elements.isEmpty else { return .unit }
            return array.elements.removeFirst()
        })
        environment.define("scalar", function("scalar", 1) { context in
            let value = context.argument(0)
            if let array = value.asArray { return .int(Int64(array.count)) }
            if let map = value.asMap { return .int(Int64(map.count)) }
            return value
        })
        environment.define("reverse", function("reverse", 1...64) { context in
            if context.arguments.count == 1, let array = context.argument(0).asArray {
                return .array(MLArray(array.elements.reversed()))
            }
            if context.arguments.count == 1, let text = context.argument(0).asString {
                return .string(String(text.reversed()))
            }
            return .array(MLArray(context.arguments.reversed()))
        })
        environment.define("join", function("join", 1...64) { context in
            let separator = semantics.display(context.argument(0))
            var items: [MLValue] = []
            for value in context.arguments.dropFirst() {
                if let array = value.asArray { items += array.elements }
                else { items.append(value) }
            }
            return .string(items.map { semantics.display($0) }.joined(separator: separator))
        })
        environment.define("split", function("split", 1...3) { context in
            let text = semantics.display(context.argument(1))
            let separator = context.argument(0)
            if let object = separator.asObject, object.typeName == "Regexp" {
                let expression = try regex(from: separator)
                let full = NSRange(text.startIndex..., in: text)
                var parts: [MLValue] = []
                var cursor = text.startIndex
                expression.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                    guard let match, let range = Range(match.range, in: text) else { return }
                    parts.append(.string(String(text[cursor..<range.lowerBound])))
                    cursor = range.upperBound
                }
                parts.append(.string(String(text[cursor...])))
                return .array(MLArray(parts))
            }
            let mark = semantics.display(separator)
            if mark == " " {
                return .array(MLArray(text.split(whereSeparator: { $0.isWhitespace })
                    .map { .string(String($0)) }))
            }
            if mark.isEmpty {
                return .array(MLArray(text.map { .string(String($0)) }))
            }
            return .array(MLArray(text.components(separatedBy: mark).map { .string($0) }))
        })

        // ハッシュ。
        environment.define("keys", function("keys", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.pairs.map { $0.key.asValue }))
        })
        environment.define("values", function("values", 1) { context in
            guard let map = context.argument(0).asMap else { return .array(MLArray()) }
            return .array(MLArray(map.pairs.map { $0.value }))
        })
        environment.define("exists", function("exists", 1) { context in
            .bool(!context.argument(0).isUnit)
        })
        environment.define("defined", function("defined", 0...1) { context in
            .bool(!(context.optionalArgument(0) ?? .unit).isUnit)
        })
        environment.define("delete", function("delete", 1) { context in
            context.argument(0)
        })

        // 文字列。
        environment.define("length", function("length", 1) { context in
            .int(Int64(semantics.display(context.argument(0)).count))
        })
        environment.define("uc", function("uc", 1) { context in
            .string(semantics.display(context.argument(0)).uppercased())
        })
        environment.define("lc", function("lc", 1) { context in
            .string(semantics.display(context.argument(0)).lowercased())
        })
        environment.define("ucfirst", function("ucfirst", 1) { context in
            let text = semantics.display(context.argument(0))
            guard let first = text.first else { return .string(text) }
            return .string(String(first).uppercased() + text.dropFirst())
        })
        environment.define("lcfirst", function("lcfirst", 1) { context in
            let text = semantics.display(context.argument(0))
            guard let first = text.first else { return .string(text) }
            return .string(String(first).lowercased() + text.dropFirst())
        })
        environment.define("substr", function("substr", 2...4) { context in
            let characters = Array(semantics.display(context.argument(0)))
            var start = Int(context.argument(1).asInt ?? 0)
            if start < 0 { start = Swift.max(0, characters.count + start) }
            guard start < characters.count else { return .string("") }
            var count = characters.count - start
            if let requested = context.optionalArgument(2)?.asInt {
                count = requested < 0 ? Swift.max(0, count + Int(requested))
                                      : Int(requested)
            }
            let end = Swift.min(characters.count, start + Swift.max(0, count))
            return .string(String(characters[start..<end]))
        })
        environment.define("index", function("index", 2...3) { context in
            let haystack = semantics.display(context.argument(0))
            let needle = semantics.display(context.argument(1))
            guard let range = haystack.range(of: needle) else { return .int(-1) }
            return .int(Int64(haystack.distance(from: haystack.startIndex,
                                                to: range.lowerBound)))
        })
        environment.define("chomp", function("chomp", 0...1) { context in
            guard let box = context.boxes.first ?? nil else { return .int(0) }
            var text = semantics.display(box.value)
            if text.hasSuffix("\n") { text.removeLast() }
            box.value = .string(text)
            return .int(1)
        })
        environment.define("ord", function("ord", 1) { context in
            let text = semantics.display(context.argument(0))
            return .int(Int64(text.unicodeScalars.first?.value ?? 0))
        })
        environment.define("chr", function("chr", 1) { context in
            let code = UInt32(Swift.max(0, context.argument(0).asInt ?? 0))
            guard let scalar = Unicode.Scalar(code) else { return .string("") }
            return .string(String(Character(scalar)))
        })

        // 並べ替え・写像・選別。
        environment.define("sort", function("sort", 0...64) { context in
            var comparator: MLFunction?
            var items: [MLValue] = []
            for (index, value) in context.arguments.enumerated() {
                if index == 0, let function = value.asFunction {
                    comparator = function
                    continue
                }
                if let array = value.asArray { items += array.elements }
                else { items.append(value) }
            }
            guard let comparator else {
                // 既定は文字列としての並べ替え。
                return .array(MLArray(items.sorted {
                    semantics.display($0) < semantics.display($1)
                }))
            }
            return .array(MLArray(try mergeSort(items, interpreter: context.interpreter,
                                                comparator: comparator,
                                                location: context.location)))
        })
        environment.define("map", function("map", 1...64) { context in
            guard let body = context.argument(0).asFunction else {
                throw MLError.runtime("map: ブロックが必要です")
            }
            var items: [MLValue] = []
            for value in context.arguments.dropFirst() {
                if let array = value.asArray { items += array.elements }
                else { items.append(value) }
            }
            var result: [MLValue] = []
            for item in items {
                context.interpreter.globals.define("$_", item)
                let mapped = try context.interpreter.callFunction(
                    body, arguments: [item], location: context.location)
                if let array = mapped.asArray { result += array.elements }
                else { result.append(mapped) }
            }
            return .array(MLArray(result))
        })
        environment.define("grep", function("grep", 1...64) { context in
            guard let body = context.argument(0).asFunction else {
                throw MLError.runtime("grep: ブロックが必要です")
            }
            var items: [MLValue] = []
            for value in context.arguments.dropFirst() {
                if let array = value.asArray { items += array.elements }
                else { items.append(value) }
            }
            var result: [MLValue] = []
            for item in items {
                context.interpreter.globals.define("$_", item)
                let kept = try context.interpreter.callFunction(
                    body, arguments: [item], location: context.location)
                if try semantics.isTruthy(kept) { result.append(item) }
            }
            return .array(MLArray(result))
        })

        // 並びからハッシュ・配列を作る。
        environment.define("#hashfrom", function("#hashfrom", 1) { context in
            let value = context.argument(0)
            if value.asMap != nil { return value }
            let map = MLMap()
            guard let array = value.asArray else {
                if case .tuple(let pair) = value.forced, pair.count == 2,
                   let key = MLKey.from(pair[0]) {
                    map[key] = pair[1]
                }
                return .map(map)
            }
            var index = 0
            while index < array.elements.count {
                let element = array.elements[index].forced
                if case .tuple(let pair) = element, pair.count == 2,
                   let key = MLKey.from(pair[0]) {
                    map[key] = pair[1]
                    index += 1
                    continue
                }
                guard let key = MLKey.from(element) else { index += 1; continue }
                map[key] = index + 1 < array.elements.count
                    ? array.elements[index + 1] : .unit
                index += 2
            }
            return .map(map)
        })
        environment.define("#listfrom", function("#listfrom", 1) { context in
            let value = context.argument(0)
            if value.asArray != nil { return value }
            if case .tuple(let items) = value.forced { return .array(MLArray(items)) }
            if value.isUnit { return .array(MLArray()) }
            if let map = value.asMap {
                var items: [MLValue] = []
                for pair in map.pairs { items.append(pair.key.asValue); items.append(pair.value) }
                return .array(MLArray(items))
            }
            return .array(MLArray([value]))
        })

        // 正規表現。
        environment.define("#pattern", function("#pattern", 1...2) { context in
            .object(pattern(try context.requireString(0, "正規表現"),
                            context.optionalArgument(1)?.asString ?? ""))
        })
        environment.define("#matches", function("#matches", 2) { context in
            let text = semantics.display(context.argument(0))
            let expression = try regex(from: context.argument(1))
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, options: [], range: range) else {
                return .bool(false)
            }
            storeCaptures(match, in: text, interpreter: context.interpreter)
            return .bool(true)
        })
        environment.define("#substitute", function("#substitute", 3...4) { context in
            let text = semantics.display(context.argument(0))
            let flags = context.optionalArgument(3)?.asString ?? ""
            let expression = try regex(from: .string(try context.requireString(1, "s///")),
                                       extraFlags: flags)
            var template = try context.requireString(2, "s///")
            // Perl の `$1` を NSRegularExpression の `$1` に合わせる。
            template = template.replacingOccurrences(of: "\\", with: "\\\\")
            let range = NSRange(text.startIndex..., in: text)
            if flags.contains("g") {
                return .string(expression.stringByReplacingMatches(
                    in: text, options: [], range: range, withTemplate: template))
            }
            guard let match = expression.firstMatch(in: text, options: [], range: range),
                  let matched = Range(match.range, in: text) else { return .string(text) }
            let replacement = expression.replacementString(for: match, in: text, offset: 0,
                                                           template: template)
            return .string(text.replacingCharacters(in: matched, with: replacement))
        })
        environment.define("#translate", function("#translate", 3...4) { context in
            let text = semantics.display(context.argument(0))
            let from = Array(try context.requireString(1, "tr///"))
            let to = Array(try context.requireString(2, "tr///"))
            var result = ""
            for character in text {
                if let index = from.firstIndex(of: character) {
                    result.append(index < to.count ? to[index] : (to.last ?? character))
                } else {
                    result.append(character)
                }
            }
            return .string(result)
        })

        // 数。
        environment.define("int", function("int", 1) { context in
            .int(Int64(semantics.numericDouble(context.argument(0))))
        })
        environment.define("sqrt", function("sqrt", 1) { context in
            .double(Foundation.sqrt(semantics.numericDouble(context.argument(0))))
        })
        environment.define("wantarray", function("wantarray", 0) { _ in .bool(false) })
        environment.define("ref", function("ref", 1) { context in
            .string(semantics.typeName(of: context.argument(0)))
        })
        environment.define("exit", function("exit", 0...1) { context in
            throw MLError.exit(Int32(context.optionalArgument(0)?.asInt ?? 0))
        })
    }

    /// 比較関数つきの安定な並べ替え (`$a` / `$b` に入れて呼ぶ)。
    static func mergeSort(_ elements: [MLValue], interpreter: MLInterpreter,
                          comparator: MLFunction,
                          location: SourceLocation) throws -> [MLValue] {
        guard elements.count > 1 else { return elements }
        let middle = elements.count / 2
        let left = try mergeSort(Array(elements[..<middle]), interpreter: interpreter,
                                 comparator: comparator, location: location)
        let right = try mergeSort(Array(elements[middle...]), interpreter: interpreter,
                                  comparator: comparator, location: location)
        var result: [MLValue] = []
        var leftIndex = 0, rightIndex = 0
        while leftIndex < left.count && rightIndex < right.count {
            interpreter.globals.define("$a", left[leftIndex])
            interpreter.globals.define("$b", right[rightIndex])
            let order = try interpreter.callFunction(
                comparator, arguments: [left[leftIndex], right[rightIndex]],
                location: location)
            if (order.asInt ?? 0) <= 0 {
                result.append(left[leftIndex])
                leftIndex += 1
            } else {
                result.append(right[rightIndex])
                rightIndex += 1
            }
        }
        result += left[leftIndex...]
        result += right[rightIndex...]
        return result
    }
}
