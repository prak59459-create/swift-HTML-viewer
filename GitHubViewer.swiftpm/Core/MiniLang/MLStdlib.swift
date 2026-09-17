import Foundation

/// どの言語からも使い回せる組み込みの実装置き場。
///
/// 「名前」は言語ごとに違う (`length` / `len` / `count` / `size`) ので、
/// ここでは処理だけを用意し、名前付けは各言語の `MLSemantics` が行う。
public enum MLStdlib {

    // MARK: - 共通の大域関数

    /// どの言語でもだいたい要る最低限を入れる。
    public static func installCommon(into environment: MLEnvironment,
                                     interpreter: MLInterpreter) {
        let semantics = interpreter.semantics

        environment.define("print", .function(.native("print", 0...64) { context in
            let text = context.arguments.map { semantics.stringify($0) }.joined(separator: " ")
            context.interpreter.write(text)
            return .unit
        }))

        environment.define("println", .function(.native("println", 0...64) { context in
            let text = context.arguments.map { semantics.stringify($0) }.joined(separator: " ")
            context.interpreter.write(text + "\n")
            return .unit
        }))

        environment.define("abs", .function(.native("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            case .double(let value): return .double(Swift.abs(value))
            default: throw MLError.runtime("abs: 数値が必要です")
            }
        }))

        environment.define("min", .function(.native("min", 1...64) { context in
            try reduceExtreme(context, keepSmaller: true)
        }))
        environment.define("max", .function(.native("max", 1...64) { context in
            try reduceExtreme(context, keepSmaller: false)
        }))

        for (name, function) in mathFunctions {
            environment.define(name, .function(.native(name, 1) { context in
                .double(function(try context.requireDouble(0, name)))
            }))
        }

        environment.define("pow", .function(.native("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        }))

        environment.define("exit", .function(.native("exit", 0...1) { context in
            throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
        }))
    }

    static let mathFunctions: [(String, (Double) -> Double)] = [
        ("sqrt", sqrt), ("sin", sin), ("cos", cos), ("tan", tan),
        ("asin", asin), ("acos", acos), ("atan", atan),
        ("exp", exp), ("log", Foundation.log), ("log2", Foundation.log2),
        ("log10", Foundation.log10), ("floor", floor), ("ceil", ceil),
        ("round", { $0.rounded() }), ("trunc", trunc),
        ("sinh", sinh), ("cosh", cosh), ("tanh", tanh), ("cbrt", cbrt)
    ]

    static func reduceExtreme(_ context: MLCallContext, keepSmaller: Bool) throws -> MLValue {
        let semantics = context.interpreter.semantics
        var items = context.arguments
        // 引数が 1 つで配列なら、その中身を比べる。
        if items.count == 1, let array = items[0].asArray { items = array.elements }
        guard var best = items.first else {
            throw MLError.runtime("min / max には少なくとも 1 つ値が必要です")
        }
        for item in items.dropFirst() {
            guard let order = semantics.compare(item, best) else {
                throw MLError.runtime("min / max: 比べられない値が混ざっています")
            }
            if keepSmaller ? order < 0 : order > 0 { best = item }
        }
        return best
    }

    // MARK: - 組み込み型のプロパティ

    /// `value.name` (呼び出しではない読み出し)。扱えなければ nil。
    public static func member(of receiver: MLValue, name: String,
                              interpreter: MLInterpreter) throws -> MLValue? {
        switch receiver.forced {
        case .string(let text):
            switch name {
            case "length", "count", "size", "len": return .int(Int64(text.count))
            case "isEmpty": return .bool(text.isEmpty)
            case "chars", "characters": return .array(MLArray(text.map { .char($0) }))
            default: return nil
            }
        case .array(let array):
            switch name {
            case "length", "count", "size", "len": return .int(Int64(array.count))
            case "isEmpty": return .bool(array.elements.isEmpty)
            case "first", "head": return array.elements.first ?? .unit
            case "last": return array.elements.last ?? .unit
            case "indices":
                return .range(MLRange(lower: Int64(interpreter.semantics.indexBase),
                                      upper: Int64(array.count + interpreter.semantics.indexBase),
                                      isClosed: false))
            default: return nil
            }
        case .map(let map):
            switch name {
            case "length", "count", "size", "len": return .int(Int64(map.count))
            case "isEmpty": return .bool(map.isEmpty)
            case "keys": return .array(MLArray(map.keys.map { $0.asValue }))
            case "values": return .array(MLArray(map.values))
            default: return nil
            }
        case .range(let range):
            switch name {
            case "length", "count", "size", "len": return .int(Int64(range.elements.count))
            case "lowerBound", "start", "first": return .int(range.lower)
            case "upperBound", "stop", "last":
                return .int(range.isClosed ? range.upper : range.upper - 1)
            default: return nil
            }
        case .tuple(let items):
            if name.hasPrefix("_"), let index = Int(name.dropFirst()),
               index >= 1, index <= items.count {
                return items[index - 1]
            }
            switch name {
            case "length", "count", "size": return .int(Int64(items.count))
            case "first": return items.first ?? .unit
            case "last": return items.last ?? .unit
            default: return nil
            }
        case .int(let value):
            switch name {
            case "isEven": return .bool(value % 2 == 0)
            case "isOdd": return .bool(value % 2 != 0)
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - 組み込み型のメソッド

    /// `value.name(args)`。扱えなければ nil を返して呼び出し側にまかせる。
    public static func callMethod(on receiver: MLValue, name: String,
                                  context: MLCallContext) throws -> MLValue? {
        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context)
        case .char(let character):
            return try stringMethod(String(character), name: name, context: context)
        case .array(let array):
            return try arrayMethod(array, name: name, context: context)
        case .map(let map):
            return try mapMethod(map, name: name, context: context)
        case .range(let range):
            let array = MLArray(range.elements.map { .int($0) })
            return try arrayMethod(array, name: name, context: context)
        case .int, .double:
            return try numberMethod(receiver.forced, name: name, context: context)
        default:
            return nil
        }
    }

    // MARK: 文字列

    static func stringMethod(_ text: String, name: String,
                             context: MLCallContext) throws -> MLValue? {
        let semantics = context.interpreter.semantics
        let characters = Array(text)

        switch name {
        case "length", "count", "size", "len":
            if let needle = context.optionalArgument(0)?.asString {
                return .int(Int64(countOccurrences(of: needle, in: text)))
            }
            return .int(Int64(characters.count))

        case "isEmpty": return .bool(text.isEmpty)
        case "isNotEmpty", "isNonEmpty": return .bool(!text.isEmpty)

        case "toUpperCase", "toUpper", "upper", "uppercase", "uppercased", "upcase", "toUpperCased":
            return .string(text.uppercased())
        case "toLowerCase", "toLower", "lower", "lowercase", "lowercased", "downcase":
            return .string(text.lowercased())

        case "trim", "strip", "trimmed", "trimmingWhitespace":
            return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "trimStart", "lstrip", "trimLeft", "stripLeading":
            return .string(String(text.drop(while: { $0.isWhitespace })))
        case "trimEnd", "rstrip", "trimRight", "stripTrailing":
            var result = text
            while let last = result.last, last.isWhitespace { result.removeLast() }
            return .string(result)

        case "contains", "includes", "has":
            guard let needle = context.argument(0).asString else { return .bool(false) }
            return .bool(needle.isEmpty || text.contains(needle))

        case "startsWith", "hasPrefix", "startswith":
            guard let prefix = context.argument(0).asString else { return .bool(false) }
            return .bool(text.hasPrefix(prefix))
        case "endsWith", "hasSuffix", "endswith":
            guard let suffix = context.argument(0).asString else { return .bool(false) }
            return .bool(text.hasSuffix(suffix))

        case "indexOf", "index", "find":
            guard let needle = context.argument(0).asString else { return .int(-1) }
            guard let position = firstIndex(of: needle, in: characters) else { return .int(-1) }
            return .int(Int64(position + semantics.indexBase))
        case "lastIndexOf", "rfind":
            guard let needle = context.argument(0).asString else { return .int(-1) }
            guard let position = lastIndex(of: needle, in: characters) else { return .int(-1) }
            return .int(Int64(position + semantics.indexBase))

        case "charAt":
            let raw = try context.requireInt(0, name)
            guard let position = MLOperations.normalizeIndex(raw, count: characters.count,
                                                             semantics: semantics) else {
                throw MLError.runtime("charAt: 添字 \(raw) は範囲外です")
            }
            return .char(characters[position])

        case "substring", "substr", "slice":
            let start = Int(context.argument(0).asInt ?? 0) - semantics.indexBase
            var end = characters.count
            if let second = context.optionalArgument(1)?.asInt {
                // substr は「長さ」、substring / slice は「終端」。
                end = name == "substr" ? start + Int(second) : Int(second) - semantics.indexBase
            }
            let low = Swift.max(0, Swift.min(start, characters.count))
            let high = Swift.max(low, Swift.min(end, characters.count))
            return .string(String(characters[low..<high]))

        case "split":
            guard let separator = context.optionalArgument(0)?.asString else {
                return .array(MLArray(characters.map { .string(String($0)) }))
            }
            let parts = separator.isEmpty
                ? characters.map { String($0) }
                : text.components(separatedBy: separator)
            return .array(MLArray(parts.map { .string($0) }))

        case "replace", "replacingOccurrences", "replaceAll", "gsub":
            guard let target = context.argument(0).asString,
                  let replacement = context.argument(1).asString else { return .string(text) }
            return .string(text.replacingOccurrences(of: target, with: replacement))
        case "replaceFirst", "sub":
            guard let target = context.argument(0).asString,
                  let replacement = context.argument(1).asString,
                  let found = text.range(of: target) else { return .string(text) }
            return .string(text.replacingCharacters(in: found, with: replacement))

        case "repeat", "times":
            let count = Int(try context.requireInt(0, name))
            return .string(count > 0 ? String(repeating: text, count: count) : "")

        case "reverse", "reversed":
            return .string(String(characters.reversed()))

        case "toInt", "toInteger", "parseInt", "toI":
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let value = Int64(trimmed) else { return .unit }
            return .int(value)
        case "toDouble", "toFloat", "parseDouble", "toF":
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return .unit }
            return .double(value)
        case "toString", "toStr", "str": return .string(text)

        case "padStart", "padLeft":
            let width = Int(try context.requireInt(0, name))
            let padding = context.optionalArgument(1)?.asString ?? " "
            return .string(pad(text, to: width, with: padding, left: true))
        case "padEnd", "padRight":
            let width = Int(try context.requireInt(0, name))
            let padding = context.optionalArgument(1)?.asString ?? " "
            return .string(pad(text, to: width, with: padding, left: false))

        case "lines": return .array(MLArray(text.components(separatedBy: "\n").map { .string($0) }))
        case "words":
            let parts = text.split(whereSeparator: { $0.isWhitespace })
            return .array(MLArray(parts.map { .string(String($0)) }))

        case "join":
            guard let array = context.argument(0).asArray else { return .string(text) }
            return .string(array.elements.map { semantics.stringify($0) }.joined(separator: text))

        case "compareTo":
            guard let other = context.argument(0).asString else { return .int(0) }
            return .int(Int64(semantics.compare(.string(text), .string(other)) ?? 0))

        case "equalsIgnoreCase":
            guard let other = context.argument(0).asString else { return .bool(false) }
            return .bool(text.lowercased() == other.lowercased())

        case "chars", "characters", "toCharArray":
            return .array(MLArray(characters.map { .char($0) }))
        case "bytes", "getBytes":
            return .array(MLArray(Array(text.utf8).map { .int(Int64($0)) }))

        case "capitalize", "capitalized", "ucfirst":
            guard let first = characters.first else { return .string(text) }
            return .string(String(first).uppercased() + String(characters.dropFirst()))

        default:
            return nil
        }
    }

    static func countOccurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    static func firstIndex(of needle: String, in characters: [Character]) -> Int? {
        let target = Array(needle)
        if target.isEmpty { return 0 }
        guard characters.count >= target.count else { return nil }
        for start in 0...(characters.count - target.count)
        where Array(characters[start..<(start + target.count)]) == target {
            return start
        }
        return nil
    }

    static func lastIndex(of needle: String, in characters: [Character]) -> Int? {
        let target = Array(needle)
        if target.isEmpty { return characters.count }
        guard characters.count >= target.count else { return nil }
        for start in stride(from: characters.count - target.count, through: 0, by: -1)
        where Array(characters[start..<(start + target.count)]) == target {
            return start
        }
        return nil
    }

    static func pad(_ text: String, to width: Int, with padding: String, left: Bool) -> String {
        guard text.count < width, !padding.isEmpty else { return text }
        var filler = ""
        while filler.count < width - text.count { filler += padding }
        filler = String(filler.prefix(width - text.count))
        return left ? filler + text : text + filler
    }

    // MARK: 配列

    static func arrayMethod(_ array: MLArray, name: String,
                            context: MLCallContext) throws -> MLValue? {
        let interpreter = context.interpreter
        let semantics = interpreter.semantics

        switch name {
        case "length", "count", "size", "len":
            if let predicate = context.optionalArgument(0)?.asFunction {
                var total = 0
                for element in array.elements
                where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element])) {
                    total += 1
                }
                return .int(Int64(total))
            }
            if let needle = context.optionalArgument(0) {
                return .int(Int64(array.elements.filter { semantics.areEqual($0, needle) }.count))
            }
            return .int(Int64(array.count))

        case "isEmpty": return .bool(array.elements.isEmpty)
        case "isNotEmpty", "isNonEmpty": return .bool(!array.elements.isEmpty)

        case "push", "append", "add", "addLast", "pushBack", "push_back":
            for value in context.arguments { array.elements.append(value) }
            return .int(Int64(array.count))
        case "pop", "popLast", "removeLast", "pop_back":
            guard let last = array.elements.popLast() else { return .unit }
            return last
        case "shift", "removeFirst", "popFirst":
            guard !array.elements.isEmpty else { return .unit }
            return array.elements.removeFirst()
        case "unshift", "prepend", "addFirst", "pushFront", "push_front":
            array.elements.insert(contentsOf: context.arguments, at: 0)
            return .int(Int64(array.count))

        case "insert":
            let raw = try context.requireInt(0, name)
            let position = Swift.max(0, Swift.min(Int(raw) - semantics.indexBase, array.count))
            array.elements.insert(context.argument(1), at: position)
            return .unit

        case "removeAt", "remove_at", "delete", "removeIndex":
            let raw = try context.requireInt(0, name)
            guard let position = MLOperations.normalizeIndex(raw, count: array.count,
                                                             semantics: semantics) else {
                throw MLError.runtime("\(name): 添字 \(raw) は範囲外です")
            }
            return array.elements.remove(at: position)

        case "remove", "removeValue", "removeObject":
            let target = context.argument(0)
            if let index = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                return array.elements.remove(at: index)
            }
            return .unit

        case "clear", "removeAll", "empty":
            array.elements.removeAll()
            return .unit

        case "first", "head":
            return array.elements.first ?? .unit
        case "last":
            return array.elements.last ?? .unit
        case "tail", "rest", "drop_first":
            return .array(MLArray(Array(array.elements.dropFirst())))

        case "contains", "includes", "has", "member":
            let target = context.argument(0)
            if let predicate = target.asFunction {
                for element in array.elements
                where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element])) {
                    return .bool(true)
                }
                return .bool(false)
            }
            return .bool(array.elements.contains { semantics.areEqual($0, target) })

        case "indexOf", "index", "find_index":
            let target = context.argument(0)
            if let index = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                return .int(Int64(index + semantics.indexBase))
            }
            return .int(-1)

        case "map", "collect":
            let transform = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for element in array.elements {
                results.append(try interpreter.callFunction(transform, arguments: [element]))
            }
            return .array(MLArray(results))

        case "mapIndexed", "mapWithIndex", "enumerated_map":
            let transform = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for (index, element) in array.elements.enumerated() {
                results.append(try interpreter.callFunction(
                    transform, arguments: [.int(Int64(index + semantics.indexBase)), element]))
            }
            return .array(MLArray(results))

        case "filter", "select", "findAll", "where":
            let predicate = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for element in array.elements
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                results.append(element)
            }
            return .array(MLArray(results))

        case "reject", "filterNot":
            let predicate = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for element in array.elements
            where try !semantics.isTruthy(interpreter.callFunction(predicate,
                                                                   arguments: [element])) {
                results.append(element)
            }
            return .array(MLArray(results))

        case "reduce", "fold", "foldLeft", "inject":
            let (initial, combine) = try reduceArguments(context, name: name)
            var accumulator = initial ?? array.elements.first ?? .unit
            let rest = initial == nil ? Array(array.elements.dropFirst()) : array.elements
            for element in rest {
                accumulator = try interpreter.callFunction(combine,
                                                           arguments: [accumulator, element])
            }
            return accumulator

        case "reduceRight", "foldRight":
            let (initial, combine) = try reduceArguments(context, name: name)
            var accumulator = initial ?? array.elements.last ?? .unit
            let rest = initial == nil ? Array(array.elements.dropLast()) : array.elements
            for element in rest.reversed() {
                accumulator = try interpreter.callFunction(combine,
                                                           arguments: [element, accumulator])
            }
            return accumulator

        case "forEach", "each", "foreach":
            let body = try context.requireFunction(0, name)
            for element in array.elements {
                _ = try interpreter.callFunction(body, arguments: [element])
            }
            return .unit

        case "find", "first_where", "detect":
            let predicate = try context.requireFunction(0, name)
            for element in array.elements
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                return element
            }
            return .unit

        case "any", "some", "exists":
            let predicate = try context.requireFunction(0, name)
            for element in array.elements
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                return .bool(true)
            }
            return .bool(false)

        case "all", "every", "forall":
            let predicate = try context.requireFunction(0, name)
            for element in array.elements
            where try !semantics.isTruthy(interpreter.callFunction(predicate,
                                                                   arguments: [element])) {
                return .bool(false)
            }
            return .bool(true)

        case "sort", "sorted", "sortBy", "sortWith", "sort_by":
            let comparator = context.optionalArgument(0)?.asFunction
            let sorted = try stableSorted(array.elements, interpreter: interpreter,
                                          comparator: comparator, byKey: name.contains("By"))
            if name == "sort" || name == "sort_by" {
                array.elements = sorted
                return .array(array)
            }
            return .array(MLArray(sorted))

        case "reverse", "reversed":
            if name == "reverse" {
                array.elements.reverse()
                return .array(array)
            }
            return .array(MLArray(array.elements.reversed()))

        case "join", "joined", "mkString":
            let separator = context.optionalArgument(0)?.asString ?? ""
            return .string(array.elements.map { semantics.stringify($0) }
                .joined(separator: separator))

        case "sum":
            var total = MLValue.int(0)
            for element in array.elements {
                total = try MLOperations.arithmetic(op: "+", lhs: total, rhs: element,
                                                    semantics: semantics)
            }
            return total

        case "product":
            var total = MLValue.int(1)
            for element in array.elements {
                total = try MLOperations.arithmetic(op: "*", lhs: total, rhs: element,
                                                    semantics: semantics)
            }
            return total

        case "min", "minimum", "minOrNull":
            return try extreme(array.elements, semantics: semantics, smaller: true)
        case "max", "maximum", "maxOrNull":
            return try extreme(array.elements, semantics: semantics, smaller: false)

        case "slice", "subarray", "sublist", "subList":
            let start = Int(context.argument(0).asInt ?? 0) - semantics.indexBase
            let end = context.optionalArgument(1)?.asInt
                .map { Int($0) - semantics.indexBase } ?? array.count
            let low = Swift.max(0, Swift.min(start, array.count))
            let high = Swift.max(low, Swift.min(end, array.count))
            return .array(MLArray(Array(array.elements[low..<high])))

        case "take", "limit":
            let count = Int(try context.requireInt(0, name))
            return .array(MLArray(Array(array.elements.prefix(Swift.max(0, count)))))
        case "drop", "skip":
            let count = Int(try context.requireInt(0, name))
            return .array(MLArray(Array(array.elements.dropFirst(Swift.max(0, count)))))
        case "takeWhile":
            let predicate = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for element in array.elements {
                guard try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element]))
                else { break }
                results.append(element)
            }
            return .array(MLArray(results))
        case "dropWhile":
            let predicate = try context.requireFunction(0, name)
            var index = 0
            while index < array.count,
                  try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [array.elements[index]])) {
                index += 1
            }
            return .array(MLArray(Array(array.elements[index...])))

        case "flatten":
            var results: [MLValue] = []
            for element in array.elements {
                if let inner = element.asArray { results.append(contentsOf: inner.elements) }
                else { results.append(element) }
            }
            return .array(MLArray(results))

        case "flatMap":
            let transform = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for element in array.elements {
                let value = try interpreter.callFunction(transform, arguments: [element])
                if let inner = value.asArray { results.append(contentsOf: inner.elements) }
                else { results.append(value) }
            }
            return .array(MLArray(results))

        case "distinct", "unique", "uniq", "toSet":
            var results: [MLValue] = []
            for element in array.elements
            where !results.contains(where: { semantics.areEqual($0, element) }) {
                results.append(element)
            }
            return .array(MLArray(results))

        case "zip":
            guard let other = context.argument(0).asArray else { return .array(MLArray()) }
            var results: [MLValue] = []
            for index in 0..<Swift.min(array.count, other.count) {
                results.append(.tuple([array.elements[index], other.elements[index]]))
            }
            return .array(MLArray(results))

        case "concat", "plus", "appendAll":
            var results = array.elements
            for argument in context.arguments {
                if let other = argument.asArray { results.append(contentsOf: other.elements) }
                else { results.append(argument) }
            }
            return .array(MLArray(results))

        case "copy", "clone", "toList", "toArray", "toMutableList":
            return .array(MLArray(array.elements))

        case "fill":
            let value = context.argument(0)
            for index in 0..<array.count { array.elements[index] = value }
            return .array(array)

        case "groupBy":
            let keySelector = try context.requireFunction(0, name)
            let map = MLMap()
            for element in array.elements {
                let keyValue = try interpreter.callFunction(keySelector, arguments: [element])
                guard let key = MLKey.from(keyValue) else {
                    throw MLError.runtime("groupBy: キーにできない値です")
                }
                if let existing = map[key]?.asArray {
                    existing.elements.append(element)
                } else {
                    map[key] = .array(MLArray([element]))
                }
            }
            return .map(map)

        case "chunked", "chunks":
            let size = Swift.max(1, Int(try context.requireInt(0, name)))
            var results: [MLValue] = []
            var index = 0
            while index < array.count {
                let end = Swift.min(index + size, array.count)
                results.append(.array(MLArray(Array(array.elements[index..<end]))))
                index = end
            }
            return .array(MLArray(results))

        default:
            return nil
        }
    }

    static func reduceArguments(_ context: MLCallContext,
                                name: String) throws -> (MLValue?, MLFunction) {
        if context.arguments.count >= 2 {
            if let combine = context.argument(1).asFunction {
                return (context.argument(0), combine)
            }
            if let combine = context.argument(0).asFunction {
                return (context.argument(1), combine)
            }
        }
        guard let combine = context.argument(0).asFunction else {
            throw MLError.runtime("\(name): 畳み込みの関数が必要です")
        }
        return (nil, combine)
    }

    static func extreme(_ elements: [MLValue], semantics: MLSemantics,
                        smaller: Bool) throws -> MLValue {
        guard var best = elements.first else { return .unit }
        for element in elements.dropFirst() {
            guard let order = semantics.compare(element, best) else {
                throw MLError.runtime("比べられない値が混ざっています")
            }
            if smaller ? order < 0 : order > 0 { best = element }
        }
        return best
    }

    /// 安定な併合ソート。比較関数は「真なら前」か「負/0/正」のどちらでもよい。
    public static func stableSorted(_ elements: [MLValue], interpreter: MLInterpreter,
                                    comparator: MLFunction?,
                                    byKey: Bool = false) throws -> [MLValue] {
        let semantics = interpreter.semantics

        func precedes(_ lhs: MLValue, _ rhs: MLValue) throws -> Bool {
            guard let comparator else {
                guard let order = semantics.compare(lhs, rhs) else {
                    throw MLError.runtime("並べ替え: 比べられない値が混ざっています")
                }
                return order < 0
            }
            if byKey {
                let left = try interpreter.callFunction(comparator, arguments: [lhs])
                let right = try interpreter.callFunction(comparator, arguments: [rhs])
                guard let order = semantics.compare(left, right) else {
                    throw MLError.runtime("並べ替え: 比べられないキーです")
                }
                return order < 0
            }
            let result = try interpreter.callFunction(comparator, arguments: [lhs, rhs])
            if case .bool(let flag) = result.forced { return flag }
            if let order = result.asInt { return order < 0 }
            if let order = result.asDouble { return order < 0 }
            throw MLError.runtime("並べ替え: 比較関数は真偽値か数値を返す必要があります")
        }

        // 併合ソート (安定)。
        func merge(_ left: [MLValue], _ right: [MLValue]) throws -> [MLValue] {
            var result: [MLValue] = []
            result.reserveCapacity(left.count + right.count)
            var leftIndex = 0
            var rightIndex = 0
            while leftIndex < left.count && rightIndex < right.count {
                try interpreter.tick()
                if try precedes(right[rightIndex], left[leftIndex]) {
                    result.append(right[rightIndex])
                    rightIndex += 1
                } else {
                    result.append(left[leftIndex])
                    leftIndex += 1
                }
            }
            result.append(contentsOf: left[leftIndex...])
            result.append(contentsOf: right[rightIndex...])
            return result
        }

        func sort(_ items: [MLValue]) throws -> [MLValue] {
            guard items.count > 1 else { return items }
            let middle = items.count / 2
            let left = try sort(Array(items[..<middle]))
            let right = try sort(Array(items[middle...]))
            return try merge(left, right)
        }

        return try sort(elements)
    }

    // MARK: 辞書

    static func mapMethod(_ map: MLMap, name: String,
                          context: MLCallContext) throws -> MLValue? {
        let interpreter = context.interpreter
        let semantics = interpreter.semantics

        switch name {
        case "length", "count", "size", "len": return .int(Int64(map.count))
        case "isEmpty": return .bool(map.isEmpty)
        case "isNotEmpty": return .bool(!map.isEmpty)
        case "keys", "keySet": return .array(MLArray(map.keys.map { $0.asValue }))
        case "values": return .array(MLArray(map.values))
        case "entries", "pairs", "items", "entrySet", "toList":
            return .array(MLArray(map.pairs.map { .tuple([$0.key.asValue, $0.value]) }))

        case "get", "getOrNull":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            if let value = map[key] { return value }
            return context.optionalArgument(1) ?? .unit

        case "getOrDefault", "fetch":
            guard let key = MLKey.from(context.argument(0)) else {
                return context.optionalArgument(1) ?? .unit
            }
            return map[key] ?? context.optionalArgument(1) ?? .unit

        case "set", "put", "store":
            guard let key = MLKey.from(context.argument(0)) else {
                throw MLError.runtime("\(name): キーにできない値です")
            }
            let previous = map[key]
            map[key] = context.argument(1)
            return previous ?? .unit

        case "containsKey", "hasKey", "has", "contains", "includes", "member", "key?":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))

        case "containsValue", "hasValue":
            let target = context.argument(0)
            return .bool(map.values.contains { semantics.areEqual($0, target) })

        case "remove", "delete", "erase":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            return map.removeValue(forKey: key) ?? .unit

        case "clear", "removeAll":
            map.removeAll()
            return .unit

        case "forEach", "each":
            let body = try context.requireFunction(0, name)
            for (key, value) in map.pairs {
                _ = try interpreter.callFunction(body, arguments: [key.asValue, value])
            }
            return .unit

        case "map":
            let transform = try context.requireFunction(0, name)
            var results: [MLValue] = []
            for (key, value) in map.pairs {
                results.append(try interpreter.callFunction(transform,
                                                            arguments: [key.asValue, value]))
            }
            return .array(MLArray(results))

        case "filter":
            let predicate = try context.requireFunction(0, name)
            let result = MLMap()
            for (key, value) in map.pairs
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [key.asValue, value])) {
                result[key] = value
            }
            return .map(result)

        case "merge", "putAll", "update":
            guard let other = context.argument(0).asMap else { return .map(map) }
            for (key, value) in other.pairs { map[key] = value }
            return .map(map)

        case "copy", "clone", "toMap":
            return .map(map.copy())

        default:
            return nil
        }
    }

    // MARK: 数値

    static func numberMethod(_ value: MLValue, name: String,
                             context: MLCallContext) throws -> MLValue? {
        let semantics = context.interpreter.semantics
        switch name {
        case "toString", "toStr", "str", "to_s":
            if let radix = context.optionalArgument(0)?.asInt, let number = value.asInt {
                return .string(String(number, radix: Int(radix)))
            }
            return .string(semantics.stringify(value))
        case "toInt", "toInteger", "intValue", "to_i", "truncate":
            guard let number = value.asDouble else { return .unit }
            return .int(Int64(number))
        case "toDouble", "toFloat", "doubleValue", "to_f":
            guard let number = value.asDouble else { return .unit }
            return .double(number)
        case "toChar":
            guard let number = value.asInt,
                  let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) else {
                return .unit
            }
            return .char(Character(scalar))
        case "abs":
            switch value {
            case .int(let number): return .int(number < 0 ? -number : number)
            case .double(let number): return .double(Swift.abs(number))
            default: return .unit
            }
        case "round":
            guard let number = value.asDouble else { return value }
            if let digits = context.optionalArgument(0)?.asInt, digits > 0 {
                let factor = Foundation.pow(10.0, Double(digits))
                return .double((number * factor).rounded() / factor)
            }
            if case .int = value { return value }
            return .int(Int64(number.rounded()))
        case "floor":
            guard let number = value.asDouble else { return value }
            if case .int = value { return value }
            return .int(Int64(number.rounded(.down)))
        case "ceil":
            guard let number = value.asDouble else { return value }
            if case .int = value { return value }
            return .int(Int64(number.rounded(.up)))
        case "isEven": return .bool((value.asInt ?? 0) % 2 == 0)
        case "isOdd": return .bool((value.asInt ?? 0) % 2 != 0)
        case "times":
            // `3.times { ... }`
            guard let count = value.asInt, let body = context.optionalArgument(0)?.asFunction else {
                return .unit
            }
            for index in 0..<Swift.max(0, Int(count)) {
                _ = try context.interpreter.callFunction(body, arguments: [.int(Int64(index))])
            }
            return .unit
        default:
            return nil
        }
    }

    // MARK: - 書式つき出力

    /// C の `printf` 風の書式化。多くの言語が似た記法を持つので共通化しておく。
    public static func format(_ pattern: String, arguments: [MLValue],
                              semantics: MLSemantics) throws -> String {
        var result = ""
        var argumentIndex = 0
        let characters = Array(pattern)
        var index = 0

        func nextArgument() -> MLValue {
            guard argumentIndex < arguments.count else { return .unit }
            defer { argumentIndex += 1 }
            return arguments[argumentIndex].forced
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { result.append("%"); break }
            if characters[index] == "%" {
                result.append("%")
                index += 1
                continue
            }
            // フラグ
            var flags = ""
            while index < characters.count, "-+ #0".contains(characters[index]) {
                flags.append(characters[index])
                index += 1
            }
            // 幅
            var width = ""
            if index < characters.count, characters[index] == "*" {
                width = String(nextArgument().asInt ?? 0)
                index += 1
            } else {
                while index < characters.count, characters[index].isNumber {
                    width.append(characters[index])
                    index += 1
                }
            }
            // 精度
            var precision: String?
            if index < characters.count, characters[index] == "." {
                index += 1
                var digits = ""
                if index < characters.count, characters[index] == "*" {
                    digits = String(nextArgument().asInt ?? 0)
                    index += 1
                } else {
                    while index < characters.count, characters[index].isNumber {
                        digits.append(characters[index])
                        index += 1
                    }
                }
                precision = digits.isEmpty ? "0" : digits
            }
            // 長さ修飾子は読み飛ばす。
            while index < characters.count, "hlLqjzt".contains(characters[index]) {
                index += 1
            }
            guard index < characters.count else { break }
            let conversion = characters[index]
            index += 1

            var spec = "%" + flags + width
            if let precision { spec += "." + precision }

            switch conversion {
            case "d", "i":
                let value = nextArgument()
                let number = value.asInt ?? Int64(value.asDouble ?? 0)
                result += String(format: spec + "lld", number)
            case "u":
                let number = nextArgument().asInt ?? 0
                result += String(format: spec + "llu", UInt64(bitPattern: number))
            case "x", "X", "o":
                let number = nextArgument().asInt ?? 0
                result += String(format: spec + "ll" + String(conversion), number)
            case "f", "F", "e", "E", "g", "G":
                let number = nextArgument().asDouble ?? 0
                result += String(format: spec + String(conversion), number)
            case "s", "@", "v":
                // `%@` は Objective-C の「オブジェクトを表示する」指定。
                var text = semantics.stringify(nextArgument())
                if let precision, let limit = Int(precision) { text = String(text.prefix(limit)) }
                if let columns = Int(width), text.count < columns {
                    let filler = String(repeating: " ", count: columns - text.count)
                    text = flags.contains("-") ? text + filler : filler + text
                }
                result += text
            case "c":
                let value = nextArgument()
                if let text = value.asString, let first = text.first {
                    result.append(first)
                } else if let number = value.asInt,
                          let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) {
                    result.append(Character(scalar))
                }
            case "b":
                let number = nextArgument().asInt ?? 0
                result += String(number, radix: 2)
            case "n":
                result += "\n"
            default:
                result.append("%")
                result.append(conversion)
            }
        }
        return result
    }
}
