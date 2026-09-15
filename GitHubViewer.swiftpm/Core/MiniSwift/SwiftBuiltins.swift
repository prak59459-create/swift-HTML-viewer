import Foundation

/// Swift の標準ライブラリのうち、よく使うものを実装する。
enum SwiftBuiltins {
    static let globalFunctions: Set<String> = [
        "print", "abs", "min", "max", "Int", "Double", "String", "Bool", "Character", "Array",
        "sqrt", "pow", "floor", "ceil", "round", "readLine", "zip", "stride", "fatalError", "assert",
        "sin", "cos", "tan", "log", "exp", "repeatElement",
        "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=",
    ]

    static func isGlobalFunction(_ name: String) -> Bool {
        globalFunctions.contains(name)
    }

    // MARK: - グローバル関数

    static func globalFunction(name: String, arguments: [(label: String?, value: SwiftValue)],
                               interpreter: SwiftInterpreter,
                               location: SourceLocation) throws -> SwiftValue? {
        func value(_ index: Int) -> SwiftValue {
            index < arguments.count ? arguments[index].value : .none
        }
        func labeled(_ label: String) -> SwiftValue? {
            arguments.first { $0.label == label }?.value
        }

        switch name {
        case "print":
            let separator = labeled("separator")?.displayText ?? " "
            let terminator = labeled("terminator")?.displayText ?? "\n"
            let items = arguments.filter { $0.label == nil }.map { $0.value.displayText }
            interpreter.write(items.joined(separator: separator) + terminator)
            return SwiftValue.none

        case "abs":
            if case .double(let number) = value(0) { return .double(Swift.abs(number)) }
            return .integer(Swift.abs(value(0).asInt))

        case "min", "max":
            var candidates = arguments.map(\.value)
            if candidates.count == 1, case .array(let values) = candidates[0] { candidates = values }
            guard var best = candidates.first else { return SwiftValue.none }
            for candidate in candidates.dropFirst() {
                let comparison = SwiftOperations.compare(candidate, best)
                if (name == "max" && comparison > 0) || (name == "min" && comparison < 0) { best = candidate }
            }
            return best

        case "Int":
            switch value(0) {
            case .string(let text):
                if let radix = labeled("radix")?.asInt {
                    return Int(text, radix: radix).map { SwiftValue.integer($0) } ?? SwiftValue.none
                }
                return Int(text).map { SwiftValue.integer($0) } ?? SwiftValue.none
            case .double(let number): return .integer(Int(number))
            case .boolean(let flag): return .integer(flag ? 1 : 0)
            case .character(let character): return Int(String(character)).map { SwiftValue.integer($0) } ?? .none
            default: return .integer(value(0).asInt)
            }

        case "Double":
            if case .string(let text) = value(0) {
                return Double(text).map { SwiftValue.double($0) } ?? SwiftValue.none
            }
            return .double(value(0).asDouble)

        case "String":
            if let repeating = labeled("repeating"), let count = labeled("count") {
                return .string(String(repeating: repeating.displayText, count: Swift.max(0, count.asInt)))
            }
            return .string(value(0).displayText)

        case "Bool":
            if case .string(let text) = value(0) { return .boolean(text == "true") }
            return .boolean(value(0).asBool)

        case "Character":
            return .character(value(0).displayText.first ?? " ")

        case "Array":
            if let repeating = labeled("repeating"), let count = labeled("count") {
                return .array(Array(repeating: repeating, count: Swift.max(0, count.asInt)))
            }
            return .array(value(0).asArray)

        case "repeatElement":
            let count = labeled("count")?.asInt ?? 0
            return .array(Array(repeating: value(0), count: Swift.max(0, count)))

        case "sqrt": return .double(Foundation.sqrt(value(0).asDouble))
        case "pow": return .double(Foundation.pow(value(0).asDouble, value(1).asDouble))
        case "floor": return .double(value(0).asDouble.rounded(.down))
        case "ceil": return .double(value(0).asDouble.rounded(.up))
        case "round": return .double(value(0).asDouble.rounded())
        case "sin": return .double(Foundation.sin(value(0).asDouble))
        case "cos": return .double(Foundation.cos(value(0).asDouble))
        case "tan": return .double(Foundation.tan(value(0).asDouble))
        case "log": return .double(Foundation.log(value(0).asDouble))
        case "exp": return .double(Foundation.exp(value(0).asDouble))

        case "readLine":
            return interpreter.readLine()

        case "zip":
            let left = value(0).asArray
            let right = value(1).asArray
            return .array(zip(left, right).map { .tuple([(label: nil, value: $0), (label: nil, value: $1)]) })

        case "stride":
            let from = labeled("from")?.asInt ?? 0
            let by = labeled("by")?.asInt ?? 1
            var result: [SwiftValue] = []
            if let to = labeled("to")?.asInt {
                var current = from
                while by > 0 ? current < to : current > to {
                    result.append(.integer(current))
                    current += by
                }
            } else if let through = labeled("through")?.asInt {
                var current = from
                while by > 0 ? current <= through : current >= through {
                    result.append(.integer(current))
                    current += by
                }
            }
            return .array(result)

        case "+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=":
            return try SwiftOperations.binary(name, value(0), value(1), location)

        case "fatalError":
            throw SwiftRuntimeFailure(message: "fatalError: \(value(0).displayText)", location: location)

        case "assert":
            if !value(0).asBool {
                throw SwiftRuntimeFailure(message: "assert に失敗しました。", location: location)
            }
            return SwiftValue.none

        default:
            return nil
        }
    }

    // MARK: - 型そのものに対する呼び出し

    static func typeMethod(typeName: String, name: String,
                           arguments: [(label: String?, value: SwiftValue)],
                           interpreter: SwiftInterpreter,
                           location: SourceLocation) throws -> SwiftValue? {
        switch (typeName, name) {
        case ("Int", "random"), ("Double", "random"):
            return .integer(0)
        default:
            return nil
        }
    }

    // MARK: - プロパティ

    static func property(_ name: String, of base: SwiftValue, interpreter: SwiftInterpreter,
                         location: SourceLocation) throws -> SwiftValue? {
        switch base {
        case .string(let text):
            switch name {
            case "count": return .integer(text.count)
            case "isEmpty": return .boolean(text.isEmpty)
            case "first": return text.first.map { SwiftValue.character($0) } ?? SwiftValue.none
            case "last": return text.last.map { SwiftValue.character($0) } ?? SwiftValue.none
            case "uppercased": return .string(text.uppercased())
            case "lowercased": return .string(text.lowercased())
            case "reversed": return .string(String(text.reversed()))
            case "description": return .string(text)
            case "utf8", "unicodeScalars": return .array(text.map { .character($0) })
            default: return nil
            }
        case .character(let character):
            switch name {
            case "isLetter": return .boolean(character.isLetter)
            case "isNumber": return .boolean(character.isNumber)
            case "isUppercase": return .boolean(character.isUppercase)
            case "isLowercase": return .boolean(character.isLowercase)
            case "isWhitespace": return .boolean(character.isWhitespace)
            case "isPunctuation": return .boolean(character.isPunctuation)
            case "description": return .string(String(character))
            case "wholeNumberValue":
                return character.wholeNumberValue.map { SwiftValue.integer($0) } ?? SwiftValue.none
            default: return nil
            }
        case .array(let values):
            switch name {
            case "count": return .integer(values.count)
            case "isEmpty": return .boolean(values.isEmpty)
            case "first": return values.first ?? SwiftValue.none
            case "last": return values.last ?? SwiftValue.none
            case "indices": return .array((0..<values.count).map { .integer($0) })
            case "reversed": return .array(values.reversed())
            case "description": return .string(base.displayText)
            default: return nil
            }
        case .dictionary(let pairs):
            switch name {
            case "count": return .integer(pairs.count)
            case "isEmpty": return .boolean(pairs.isEmpty)
            case "keys": return .array(pairs.map(\.key))
            case "values": return .array(pairs.map(\.value))
            default: return nil
            }
        case .integer(let number):
            switch name {
            case "description": return .string(String(number))
            case "magnitude": return .integer(Swift.abs(number))
            case "isMultiple": return nil
            default: return nil
            }
        case .double(let number):
            switch name {
            case "description": return .string(SwiftFormatter.doubleText(number))
            case "magnitude": return .double(Swift.abs(number))
            case "isNaN": return .boolean(number.isNaN)
            case "isFinite": return .boolean(number.isFinite)
            default: return nil
            }
        case .boolean(let flag):
            if name == "description" { return .string(flag ? "true" : "false") }
            return nil
        case .range(let lower, let upper, let isClosed):
            switch name {
            case "count": return .integer(Swift.max(0, isClosed ? upper - lower + 1 : upper - lower))
            case "lowerBound": return .integer(lower)
            case "upperBound": return .integer(upper)
            case "isEmpty": return .boolean(isClosed ? lower > upper : lower >= upper)
            default: return nil
            }
        case .tuple(let items):
            if let position = Int(name), position < items.count { return items[position].value }
            return items.first { $0.label == name }?.value
        case .enumeration(_, _, let rawValue):
            if name == "rawValue" { return rawValue ?? .none }
            return nil
        default:
            return nil
        }
    }

    // MARK: - メソッド

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func method(name: String, on base: SwiftValue,
                       arguments: [(label: String?, value: SwiftValue)],
                       interpreter: SwiftInterpreter, location: SourceLocation,
                       mutate: (SwiftValue) throws -> Void) throws -> SwiftValue? {
        func value(_ index: Int) -> SwiftValue {
            index < arguments.count ? arguments[index].value : .none
        }
        func labeled(_ label: String) -> SwiftValue? {
            arguments.first { $0.label == label }?.value
        }
        func callback() -> SwiftValue? {
            arguments.last?.value
        }

        switch base {
        // ---- 文字列 ----
        case .string(let text):
            switch name {
            case "uppercased": return .string(text.uppercased())
            case "lowercased": return .string(text.lowercased())
            case "hasPrefix": return .boolean(text.hasPrefix(value(0).displayText))
            case "hasSuffix": return .boolean(text.hasSuffix(value(0).displayText))
            case "contains": return .boolean(text.contains(value(0).displayText))
            case "count": return .integer(text.count)
            case "isEmpty": return .boolean(text.isEmpty)
            case "split":
                let separator = labeled("separator") ?? value(0)
                let pieces = text.components(separatedBy: separator.displayText)
                let omitEmpty = labeled("omittingEmptySubsequences")?.asBool ?? true
                return .array(pieces.filter { !omitEmpty || !$0.isEmpty }.map { .string($0) })
            case "replacingOccurrences":
                let target = labeled("of")?.displayText ?? value(0).displayText
                let replacement = labeled("with")?.displayText ?? value(1).displayText
                return .string(text.replacingOccurrences(of: target, with: replacement))
            case "trimmingCharacters":
                return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "prefix": return .string(String(text.prefix(value(0).asInt)))
            case "suffix": return .string(String(text.suffix(value(0).asInt)))
            case "dropFirst": return .string(String(text.dropFirst(arguments.isEmpty ? 1 : value(0).asInt)))
            case "dropLast": return .string(String(text.dropLast(arguments.isEmpty ? 1 : value(0).asInt)))
            case "reversed": return .string(String(text.reversed()))
            case "sorted": return .array(text.sorted().map { .character($0) })
            case "firstIndex", "index":
                return SwiftValue.none
            case "append":
                try mutate(.string(text + value(0).displayText))
                return SwiftValue.none
            case "map", "filter", "forEach", "reduce", "compactMap", "enumerated", "joined", "allSatisfy":
                return try method(name: name, on: .array(text.map { .character($0) }), arguments: arguments,
                                  interpreter: interpreter, location: location, mutate: mutate)
            case "starts":
                return .boolean(text.hasPrefix((labeled("with") ?? value(0)).displayText))
            case "components":
                let separator = labeled("separatedBy")?.displayText ?? value(0).displayText
                return .array(text.components(separatedBy: separator).map { .string($0) })
            default: return nil
            }

        // ---- 配列 ----
        case .array(let values):
            switch name {
            case "append":
                try mutate(.array(values + [value(0)]))
                return SwiftValue.none
            case "insert":
                var copy = values
                let position = labeled("at")?.asInt ?? 0
                copy.insert(value(0), at: Swift.max(0, Swift.min(position, copy.count)))
                try mutate(.array(copy))
                return SwiftValue.none
            case "remove":
                var copy = values
                let position = labeled("at")?.asInt ?? value(0).asInt
                guard position >= 0, position < copy.count else {
                    throw SwiftRuntimeFailure(message: "配列の範囲外です。", location: location)
                }
                let removed = copy.remove(at: position)
                try mutate(.array(copy))
                return removed
            case "removeLast":
                var copy = values
                guard !copy.isEmpty else {
                    throw SwiftRuntimeFailure(message: "空の配列から削除しようとしました。", location: location)
                }
                let removed = copy.removeLast()
                try mutate(.array(copy))
                return removed
            case "removeFirst":
                var copy = values
                guard !copy.isEmpty else {
                    throw SwiftRuntimeFailure(message: "空の配列から削除しようとしました。", location: location)
                }
                let removed = copy.removeFirst()
                try mutate(.array(copy))
                return removed
            case "removeAll":
                try mutate(.array([]))
                return SwiftValue.none
            case "contains":
                if let closure = callback(), isCallable(closure), arguments.first?.label == nil,
                   arguments.count == 1, isClosureValue(closure) {
                    for element in values
                    where try interpreter.callClosure(closure, arguments: [element], at: location).asBool {
                        return .boolean(true)
                    }
                    return .boolean(false)
                }
                return .boolean(values.contains { SwiftOperations.equals($0, value(0)) })
            case "firstIndex", "lastIndex":
                let target = labeled("of") ?? value(0)
                let indices = values.indices.filter { SwiftOperations.equals(values[$0], target) }
                let position = name == "firstIndex" ? indices.first : indices.last
                return position.map { SwiftValue.integer($0) } ?? SwiftValue.none
            case "sorted":
                if let closure = callback(), isClosureValue(closure) {
                    var result = values
                    try mergeSort(&result) { left, right in
                        try interpreter.callClosure(closure, arguments: [left, right], at: location).asBool
                    }
                    return .array(result)
                }
                var result = values
                try mergeSort(&result) { left, right in SwiftOperations.compare(left, right) < 0 }
                return .array(result)
            case "reversed":
                return .array(values.reversed())
            case "shuffled":
                return .array(values)
            case "map", "compactMap":
                guard let closure = callback() else { return nil }
                var result: [SwiftValue] = []
                for element in values {
                    let mapped = try interpreter.callClosure(closure, arguments: [element], at: location)
                    if name == "compactMap", mapped.isNil { continue }
                    result.append(mapped)
                }
                return .array(result)
            case "flatMap":
                guard let closure = callback() else { return nil }
                var result: [SwiftValue] = []
                for element in values {
                    result.append(contentsOf: try interpreter.callClosure(closure, arguments: [element],
                                                                          at: location).asArray)
                }
                return .array(result)
            case "filter":
                guard let closure = callback() else { return nil }
                var result: [SwiftValue] = []
                for element in values
                where try interpreter.callClosure(closure, arguments: [element], at: location).asBool {
                    result.append(element)
                }
                return .array(result)
            case "forEach":
                guard let closure = callback() else { return nil }
                for element in values {
                    _ = try interpreter.callClosure(closure, arguments: [element], at: location)
                }
                return SwiftValue.none
            case "reduce":
                guard arguments.count >= 2, let closure = arguments.last?.value else { return nil }
                var accumulator = arguments[0].value
                for element in values {
                    accumulator = try interpreter.callClosure(closure, arguments: [accumulator, element],
                                                              at: location)
                }
                return accumulator
            case "allSatisfy":
                guard let closure = callback() else { return nil }
                for element in values
                where try !interpreter.callClosure(closure, arguments: [element], at: location).asBool {
                    return .boolean(false)
                }
                return .boolean(true)
            case "first":
                if let closure = callback(), isClosureValue(closure) {
                    for element in values
                    where try interpreter.callClosure(closure, arguments: [element], at: location).asBool {
                        return element
                    }
                    return SwiftValue.none
                }
                return values.first ?? SwiftValue.none
            case "last":
                return values.last ?? SwiftValue.none
            case "enumerated":
                return .array(values.enumerated().map { index, element in
                    .tuple([(label: "offset", value: .integer(index)), (label: "element", value: element)])
                })
            case "joined":
                let separator = labeled("separator")?.displayText ?? ""
                return .string(values.map { $0.displayText }.joined(separator: separator))
            case "prefix": return .array(Array(values.prefix(value(0).asInt)))
            case "suffix": return .array(Array(values.suffix(value(0).asInt)))
            case "dropFirst": return .array(Array(values.dropFirst(arguments.isEmpty ? 1 : value(0).asInt)))
            case "dropLast": return .array(Array(values.dropLast(arguments.isEmpty ? 1 : value(0).asInt)))
            case "min", "max":
                guard var best = values.first else { return SwiftValue.none }
                for element in values.dropFirst() {
                    let comparison = SwiftOperations.compare(element, best)
                    if (name == "max" && comparison > 0) || (name == "min" && comparison < 0) { best = element }
                }
                return best
            case "count": return .integer(values.count)
            case "isEmpty": return .boolean(values.isEmpty)
            case "sort":
                var result = values
                if let closure = callback(), isClosureValue(closure) {
                    try mergeSort(&result) { left, right in
                        try interpreter.callClosure(closure, arguments: [left, right], at: location).asBool
                    }
                } else {
                    try mergeSort(&result) { left, right in SwiftOperations.compare(left, right) < 0 }
                }
                try mutate(.array(result))
                return SwiftValue.none
            default: return nil
            }

        // ---- 辞書 ----
        case .dictionary(let pairs):
            switch name {
            case "keys": return .array(pairs.map(\.key))
            case "values": return .array(pairs.map(\.value))
            case "count": return .integer(pairs.count)
            case "isEmpty": return .boolean(pairs.isEmpty)
            case "removeValue":
                var copy = pairs
                let key = labeled("forKey") ?? value(0)
                guard let position = copy.firstIndex(where: { SwiftOperations.equals($0.key, key) }) else {
                    return SwiftValue.none
                }
                let removed = copy.remove(at: position)
                try mutate(.dictionary(copy))
                return removed.value
            case "updateValue":
                var copy = pairs
                let key = labeled("forKey") ?? value(1)
                if let position = copy.firstIndex(where: { SwiftOperations.equals($0.key, key) }) {
                    let old = copy[position].value
                    copy[position].value = value(0)
                    try mutate(.dictionary(copy))
                    return old
                }
                copy.append((key, value(0)))
                try mutate(.dictionary(copy))
                return SwiftValue.none
            case "map", "filter", "sorted", "forEach", "reduce", "compactMap":
                let asTuples = pairs.map { pair in
                    SwiftValue.tuple([(label: "key", value: pair.key), (label: "value", value: pair.value)])
                }
                return try method(name: name, on: .array(asTuples), arguments: arguments,
                                  interpreter: interpreter, location: location, mutate: mutate)
            case "contains":
                return .boolean(pairs.contains { SwiftOperations.equals($0.key, value(0)) })
            default: return nil
            }

        // ---- 範囲 ----
        case .range:
            switch name {
            case "contains":
                if let closure = arguments.last?.value, isClosureValue(closure) {
                    return try method(name: name, on: .array(base.asArray), arguments: arguments,
                                      interpreter: interpreter, location: location, mutate: mutate)
                }
                if case .range(let lower, let upper, let isClosed) = base {
                    let number = value(0).asInt
                    return .boolean(isClosed ? (number >= lower && number <= upper)
                                    : (number >= lower && number < upper))
                }
                return .boolean(false)
            case "map", "filter", "forEach", "reduce", "reversed", "compactMap", "enumerated", "count",
                 "shuffled", "allSatisfy", "sorted", "first", "last", "joined":
                return try method(name: name, on: .array(base.asArray), arguments: arguments,
                                  interpreter: interpreter, location: location, mutate: mutate)
            default: return nil
            }

        // ---- 数値 ----
        case .integer(let number):
            switch name {
            case "description": return .string(String(number))
            case "isMultiple":
                let divisor = (labeled("of") ?? value(0)).asInt
                return .boolean(divisor != 0 && number % divisor == 0)
            case "quotientAndRemainder":
                let divisor = (labeled("dividingBy") ?? value(0)).asInt
                guard divisor != 0 else {
                    throw SwiftRuntimeFailure(message: "0 で割ろうとしました。", location: location)
                }
                return .tuple([(label: "quotient", value: .integer(number / divisor)),
                               (label: "remainder", value: .integer(number % divisor))])
            default: return nil
            }
        case .double(let number):
            switch name {
            case "rounded":
                if let rule = arguments.first?.value, case .enumeration(_, let caseName, _) = rule {
                    switch caseName {
                    case "down": return .double(number.rounded(.down))
                    case "up": return .double(number.rounded(.up))
                    case "towardZero": return .double(number.rounded(.towardZero))
                    default: return .double(number.rounded())
                    }
                }
                return .double(number.rounded())
            case "squareRoot": return .double(number.squareRoot())
            case "description": return .string(SwiftFormatter.doubleText(number))
            default: return nil
            }

        case .character(let character):
            switch name {
            case "uppercased": return .string(character.uppercased())
            case "lowercased": return .string(character.lowercased())
            case "description": return .string(String(character))
            default: return nil
            }

        case .enumeration:
            return nil

        default:
            return nil
        }
    }

    private static func isClosureValue(_ value: SwiftValue) -> Bool {
        if case .closure = value { return true }
        if case .metatype = value { return true }
        if case .tuple(let items) = value, items.first?.label == "method" { return true }
        return false
    }

    private static func isCallable(_ value: SwiftValue) -> Bool { isClosureValue(value) }

    /// 例外を投げる比較でも使える安定なマージソート。
    private static func mergeSort(_ values: inout [SwiftValue],
                                  by isBefore: (SwiftValue, SwiftValue) throws -> Bool) rethrows {
        guard values.count > 1 else { return }
        var buffer = values
        try sort(&values, &buffer, 0, values.count, isBefore)
    }

    private static func sort(_ values: inout [SwiftValue], _ buffer: inout [SwiftValue],
                             _ start: Int, _ end: Int,
                             _ isBefore: (SwiftValue, SwiftValue) throws -> Bool) rethrows {
        guard end - start > 1 else { return }
        let middle = (start + end) / 2
        try sort(&values, &buffer, start, middle, isBefore)
        try sort(&values, &buffer, middle, end, isBefore)
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
            } else if try isBefore(values[right], values[left]) {
                buffer[index] = values[right]
                right += 1
            } else {
                buffer[index] = values[left]
                left += 1
            }
            index += 1
        }
        for position in start..<end { values[position] = buffer[position] }
    }
}
