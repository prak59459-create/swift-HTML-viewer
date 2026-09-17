import Foundation

/// PHP の標準関数のうち、よく使うものを実装する。
enum PHPBuiltins {
    static let names: Set<String> = [
        "strlen", "count", "sizeof", "str_repeat", "str_replace", "substr", "strpos", "strrpos",
        "strtoupper", "strtolower", "ucfirst", "lcfirst", "ucwords", "trim", "ltrim", "rtrim",
        "explode", "implode", "join", "str_split", "str_pad", "strrev", "str_contains",
        "str_starts_with", "str_ends_with", "sprintf", "printf", "number_format", "nl2br",
        "substr_count", "strcmp", "strcasecmp", "wordwrap", "htmlspecialchars",
        "array_push", "array_pop", "array_shift", "array_unshift", "array_keys", "array_values",
        "array_merge", "array_slice", "array_splice", "array_reverse", "array_sum", "array_product",
        "array_map", "array_filter", "array_reduce", "array_search", "in_array", "array_key_exists",
        "array_unique", "array_combine", "array_flip", "array_fill", "array_column", "array_diff",
        "array_intersect", "array_chunk", "range", "compact", "sort", "rsort", "usort", "uasort",
        "uksort", "ksort", "krsort", "asort", "arsort", "shuffle", "array_rand",
        "abs", "max", "min", "floor", "ceil", "round", "sqrt", "pow", "intdiv", "fmod",
        "intval", "floatval", "doubleval", "strval", "boolval", "is_int", "is_integer", "is_float",
        "is_double", "is_string", "is_bool", "is_array", "is_null", "is_numeric", "is_callable",
        "is_object", "gettype", "settype", "json_encode", "var_dump", "print_r", "var_export",
        "rand", "mt_rand", "random_int", "srand", "mt_srand", "pi", "exp", "log", "log10",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "deg2rad", "rad2deg",
        "function_exists", "class_exists", "method_exists", "property_exists", "get_class",
        "call_user_func", "call_user_func_array", "func_get_args", "str_word_count",
        "preg_quote", "ord", "chr", "dechex", "hexdec", "decbin", "bindec", "decoct", "octdec",
        "base_convert", "number_parse", "print", "clone", "exit", "die", "fgets", "readline",
        "trigger_error", "error_log", "usleep", "sleep", "microtime", "time", "uniqid",
        "end", "reset", "current", "key", "array_key_first", "array_key_last", "array_pad",
        "array_fill_keys", "str_word_count", "similar_text", "levenshtein", "soundex",
    ]

    /// 引数の「式」が必要な関数 (sort など、変数を書き換えるもの)。
    static func callSpecial(name: String, arguments: [PHPExpr], interpreter: PHPInterpreter,
                            location: SourceLocation) throws -> PHPValue? {
        switch name {
        case "sort", "rsort", "usort", "uasort", "uksort", "ksort", "krsort", "asort", "arsort", "shuffle":
            guard let first = arguments.first else { return .boolean(false) }
            var array = try interpreter.evaluateExpression(first).asArray
            let callback = arguments.count > 1 ? try interpreter.evaluateExpression(arguments[1]) : PHPValue.null

            switch name {
            case "sort", "rsort":
                var values = array.values
                let descending = name == "rsort"
                try sortValues(&values, interpreter: interpreter, location: location) { left, right in
                    descending ? PHPOperations.compare(right, left) : PHPOperations.compare(left, right)
                }
                array.reindex(with: values)
            case "usort":
                var values = array.values
                try sortValues(&values, interpreter: interpreter, location: location) { left, right in
                    Int(try interpreter.call(value: callback, arguments: [left, right],
                                             location: location).asInt)
                }
                array.reindex(with: values)
            case "uasort":
                var pairs = array.keys.map { ($0, array[$0] ?? .null) }
                try sortPairs(&pairs) { left, right in
                    Int(try interpreter.call(value: callback, arguments: [left.1, right.1],
                                             location: location).asInt)
                }
                array.reorder(pairs)
            case "uksort":
                var pairs = array.keys.map { ($0, array[$0] ?? .null) }
                try sortPairs(&pairs) { left, right in
                    Int(try interpreter.call(value: callback, arguments: [left.0.asValue, right.0.asValue],
                                             location: location).asInt)
                }
                array.reorder(pairs)
            case "ksort", "krsort":
                var pairs = array.keys.map { ($0, array[$0] ?? .null) }
                let descendingKeys = name == "krsort"
                try sortPairs(&pairs) { left, right in
                    descendingKeys ? PHPOperations.compare(right.0.asValue, left.0.asValue)
                        : PHPOperations.compare(left.0.asValue, right.0.asValue)
                }
                array.reorder(pairs)
            case "asort", "arsort":
                var pairs = array.keys.map { ($0, array[$0] ?? .null) }
                let descendingValues = name == "arsort"
                try sortPairs(&pairs) { left, right in
                    descendingValues ? PHPOperations.compare(right.1, left.1)
                        : PHPOperations.compare(left.1, right.1)
                }
                array.reorder(pairs)
            case "shuffle":
                var values = array.values
                for index in stride(from: values.count - 1, to: 0, by: -1) {
                    let target = Int(interpreter.nextRandom(0, Int64(index)))
                    values.swapAt(index, target)
                }
                array.reindex(with: values)
            default:
                break
            }
            try interpreter.assignTo(first, .array(array))
            return .boolean(true)

        case "array_push":
            guard let first = arguments.first else { return .integer(0) }
            var array = try interpreter.evaluateExpression(first).asArray
            for argument in arguments.dropFirst() {
                array.append(try interpreter.evaluateExpression(argument))
            }
            try interpreter.assignTo(first, .array(array))
            return .integer(Int64(array.count))

        case "array_pop":
            guard let first = arguments.first else { return .null }
            var array = try interpreter.evaluateExpression(first).asArray
            guard let lastKey = array.keys.last else { return .null }
            let value = array[lastKey] ?? .null
            array.removeValue(forKey: lastKey)
            try interpreter.assignTo(first, .array(array))
            return value

        case "array_shift":
            guard let first = arguments.first else { return .null }
            let array = try interpreter.evaluateExpression(first).asArray
            guard let firstKey = array.keys.first else { return .null }
            let value = array[firstKey] ?? .null
            var rest = PHPArray()
            for key in array.keys.dropFirst() {
                switch key {
                case .integer: rest.append(array[key] ?? .null)
                case .text: rest[key] = array[key]
                }
            }
            try interpreter.assignTo(first, .array(rest))
            return value

        case "array_unshift":
            guard let first = arguments.first else { return .integer(0) }
            let array = try interpreter.evaluateExpression(first).asArray
            var result = PHPArray()
            for argument in arguments.dropFirst() {
                result.append(try interpreter.evaluateExpression(argument))
            }
            for key in array.keys {
                switch key {
                case .integer: result.append(array[key] ?? .null)
                case .text: result[key] = array[key]
                }
            }
            try interpreter.assignTo(first, .array(result))
            return .integer(Int64(result.count))

        case "settype":
            guard arguments.count >= 2 else { return .boolean(false) }
            let value = try interpreter.evaluateExpression(arguments[0])
            let type = try interpreter.evaluateExpression(arguments[1]).asString
            let converted: PHPValue
            switch type {
            case "int", "integer": converted = .integer(value.asInt)
            case "float", "double": converted = .number(value.asDouble)
            case "string": converted = .text(value.asString)
            case "bool", "boolean": converted = .boolean(value.asBool)
            case "array": converted = .array(value.asArray)
            default: converted = value
            }
            try interpreter.assignTo(arguments[0], converted)
            return .boolean(true)

        default:
            return nil
        }
    }

    private static func sortValues(_ values: inout [PHPValue], interpreter: PHPInterpreter,
                                   location: SourceLocation,
                                   by comparator: (PHPValue, PHPValue) throws -> Int) throws {
        // 例外を投げられる比較でも使えるマージソート
        guard values.count > 1 else { return }
        var buffer = values
        try merge(&values, &buffer, 0, values.count, comparator)
    }

    private static func sortPairs(_ pairs: inout [(PHPKey, PHPValue)],
                                  by comparator: ((PHPKey, PHPValue), (PHPKey, PHPValue)) throws -> Int) throws {
        guard pairs.count > 1 else { return }
        var buffer = pairs
        try merge(&pairs, &buffer, 0, pairs.count, comparator)
    }

    private static func merge<T>(_ values: inout [T], _ buffer: inout [T], _ start: Int, _ end: Int,
                                 _ comparator: (T, T) throws -> Int) rethrows {
        guard end - start > 1 else { return }
        let middle = (start + end) / 2
        try merge(&values, &buffer, start, middle, comparator)
        try merge(&values, &buffer, middle, end, comparator)
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
            } else if try comparator(values[right], values[left]) < 0 {
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

    // MARK: - ふつうの関数

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func call(name: String, arguments: [PHPValue], interpreter: PHPInterpreter,
                     location: SourceLocation) throws -> PHPValue? {
        func argument(_ index: Int) -> PHPValue {
            index < arguments.count ? arguments[index] : .null
        }
        func text(_ index: Int) -> String { argument(index).asString }
        func number(_ index: Int) -> Double { argument(index).asDouble }
        func integer(_ index: Int) -> Int64 { argument(index).asInt }
        func array(_ index: Int) -> PHPArray { argument(index).asArray }

        switch name {
        // ---- 文字列 ----
        case "strlen": return .integer(Int64(text(0).utf8.count))
        case "str_repeat": return .text(String(repeating: text(0), count: max(0, Int(integer(1)))))
        case "strtoupper": return .text(text(0).uppercased())
        case "strtolower": return .text(text(0).lowercased())
        case "ucfirst": return .text(text(0).isEmpty ? "" : text(0).prefix(1).uppercased() + text(0).dropFirst())
        case "lcfirst": return .text(text(0).isEmpty ? "" : text(0).prefix(1).lowercased() + text(0).dropFirst())
        case "ucwords":
            let parts = text(0).components(separatedBy: " ")
            return .text(parts.map { $0.isEmpty ? $0 : $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " "))
        case "trim", "ltrim", "rtrim":
            let characters = arguments.count > 1 ? CharacterSet(charactersIn: text(1))
                : CharacterSet(charactersIn: " \t\n\r\0\u{0B}")
            var value = Substring(text(0))
            if name != "rtrim" {
                while let first = value.first, first.unicodeScalars.allSatisfy({ characters.contains($0) }) {
                    value = value.dropFirst()
                }
            }
            if name != "ltrim" {
                while let last = value.last, last.unicodeScalars.allSatisfy({ characters.contains($0) }) {
                    value = value.dropLast()
                }
            }
            return .text(String(value))
        case "strrev": return .text(String(text(0).reversed()))
        case "str_contains": return .boolean(text(1).isEmpty || text(0).contains(text(1)))
        case "str_starts_with": return .boolean(text(0).hasPrefix(text(1)))
        case "str_ends_with": return .boolean(text(0).hasSuffix(text(1)))
        case "substr":
            let characters = Array(text(0))
            var start = Int(integer(1))
            if start < 0 { start = max(0, characters.count + start) }
            if start >= characters.count { return .text("") }
            var length = characters.count - start
            if arguments.count > 2, case .null = argument(2) {} else if arguments.count > 2 {
                let requested = Int(integer(2))
                length = requested < 0 ? max(0, characters.count - start + requested) : requested
            }
            let end = min(characters.count, start + max(0, length))
            return .text(String(characters[start..<end]))
        case "strpos", "strrpos":
            let haystack = Array(text(0))
            let needle = Array(text(1))
            guard !needle.isEmpty, haystack.count >= needle.count else { return .boolean(false) }
            let positions = 0...(haystack.count - needle.count)
            let matches = positions.filter { Array(haystack[$0..<($0 + needle.count)]) == needle }
            guard let position = (name == "strpos" ? matches.first : matches.last) else {
                return .boolean(false)
            }
            return .integer(Int64(position))
        case "substr_count":
            let haystack = Array(text(0))
            let needle = Array(text(1))
            guard !needle.isEmpty, haystack.count >= needle.count else { return .integer(0) }
            var count = 0
            var index = 0
            while index + needle.count <= haystack.count {
                if Array(haystack[index..<(index + needle.count)]) == needle {
                    count += 1
                    index += needle.count
                } else {
                    index += 1
                }
            }
            return .integer(Int64(count))
        case "str_replace":
            let subject = text(2)
            var result = subject
            let searches = argumentAsList(argument(0))
            let replacements = argumentAsList(argument(1))
            for (index, search) in searches.enumerated() {
                let replacement = replacements.count == 1 ? replacements[0]
                    : (index < replacements.count ? replacements[index] : "")
                if !search.isEmpty {
                    result = result.replacingOccurrences(of: search, with: replacement)
                }
            }
            return .text(result)
        case "str_pad":
            let value = text(0)
            let length = Int(integer(1))
            let padding = arguments.count > 2 ? text(2) : " "
            let type = arguments.count > 3 ? Int(integer(3)) : 1 // STR_PAD_RIGHT
            guard length > value.count, !padding.isEmpty else { return .text(value) }
            let missing = length - value.count
            func make(_ count: Int) -> String {
                String(String(repeating: padding, count: count / padding.count + 1).prefix(count))
            }
            switch type {
            case 0: return .text(make(missing) + value)
            case 2:
                let left = missing / 2
                return .text(make(left) + value + make(missing - left))
            default: return .text(value + make(missing))
            }
        case "str_split":
            let size = arguments.count > 1 ? max(1, Int(integer(1))) : 1
            var pieces: [PHPValue] = []
            var current = ""
            for character in text(0) {
                current.append(character)
                if current.count == size {
                    pieces.append(.text(current))
                    current = ""
                }
            }
            if !current.isEmpty { pieces.append(.text(current)) }
            return .array(PHPArray.from(pieces))
        case "explode":
            let separator = text(0)
            guard !separator.isEmpty else { return .boolean(false) }
            var pieces = text(1).components(separatedBy: separator)
            if arguments.count > 2 {
                let limit = Int(integer(2))
                if limit > 0, pieces.count > limit {
                    let head = pieces.prefix(limit - 1)
                    let tail = pieces.dropFirst(limit - 1).joined(separator: separator)
                    pieces = Array(head) + [tail]
                } else if limit < 0 {
                    pieces = Array(pieces.dropLast(-limit))
                }
            }
            return .array(PHPArray.from(pieces.map { PHPValue.text($0) }))
        case "implode", "join":
            // implode(glue, array) と implode(array) の両方
            if case .array(let list) = argument(0) {
                return .text(list.values.map(\.asString).joined())
            }
            return .text(array(1).values.map(\.asString).joined(separator: text(0)))
        case "nl2br":
            return .text(text(0).replacingOccurrences(of: "\n", with: "<br />\n"))
        case "htmlspecialchars":
            var value = text(0)
            value = value.replacingOccurrences(of: "&", with: "&amp;")
            value = value.replacingOccurrences(of: "<", with: "&lt;")
            value = value.replacingOccurrences(of: ">", with: "&gt;")
            value = value.replacingOccurrences(of: "\"", with: "&quot;")
            value = value.replacingOccurrences(of: "'", with: "&#039;")
            return .text(value)
        case "strcmp", "strcasecmp":
            let left = name == "strcmp" ? text(0) : text(0).lowercased()
            let right = name == "strcmp" ? text(1) : text(1).lowercased()
            return .integer(left == right ? 0 : (left < right ? -1 : 1))
        case "str_word_count":
            let words = text(0).split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            return .integer(Int64(words.count))
        case "wordwrap":
            let width = arguments.count > 1 ? Int(integer(1)) : 75
            let breakText = arguments.count > 2 ? text(2) : "\n"
            var lines: [String] = []
            var current = ""
            for word in text(0).components(separatedBy: " ") {
                if current.isEmpty {
                    current = word
                } else if current.count + 1 + word.count <= width {
                    current += " " + word
                } else {
                    lines.append(current)
                    current = word
                }
            }
            if !current.isEmpty { lines.append(current) }
            return .text(lines.joined(separator: breakText))
        case "sprintf", "printf":
            let formatted = PHPFormatter.format(text(0), Array(arguments.dropFirst()))
            if name == "printf" {
                interpreter.write(formatted)
                return .integer(Int64(formatted.utf8.count))
            }
            return .text(formatted)
        case "number_format":
            let value = number(0)
            let decimals = arguments.count > 1 ? Int(integer(1)) : 0
            let decimalPoint = arguments.count > 2 ? text(2) : "."
            let separator = arguments.count > 3 ? text(3) : ","
            let rounded = String(format: "%.\(decimals)f", value)
            let parts = rounded.components(separatedBy: ".")
            var digits = parts[0]
            var sign = ""
            if digits.hasPrefix("-") {
                sign = "-"
                digits.removeFirst()
            }
            var grouped: [String] = []
            while digits.count > 3 {
                grouped.insert(String(digits.suffix(3)), at: 0)
                digits = String(digits.dropLast(3))
            }
            grouped.insert(digits, at: 0)
            var result = sign + grouped.joined(separator: separator)
            if parts.count > 1, decimals > 0 { result += decimalPoint + parts[1] }
            return .text(result)
        case "ord":
            return .integer(Int64(text(0).utf8.first ?? 0))
        case "chr":
            return .text(String(Character(UnicodeScalar(UInt8(truncatingIfNeeded: integer(0))))))
        case "dechex": return .text(String(UInt64(bitPattern: integer(0)), radix: 16))
        case "hexdec": return .integer(Int64(text(0), radix: 16) ?? 0)
        case "decbin": return .text(String(UInt64(bitPattern: integer(0)), radix: 2))
        case "bindec": return .integer(Int64(text(0), radix: 2) ?? 0)
        case "decoct": return .text(String(UInt64(bitPattern: integer(0)), radix: 8))
        case "octdec": return .integer(Int64(text(0), radix: 8) ?? 0)
        case "base_convert":
            let value = Int64(text(0), radix: Int(integer(1))) ?? 0
            return .text(String(value, radix: Int(integer(2))))
        case "preg_quote":
            var result = ""
            let special = Set(".\\+*?[^]$(){}=!<>|:-#/")
            for character in text(0) {
                if special.contains(character) { result.append("\\") }
                result.append(character)
            }
            return .text(result)

        // ---- 配列 ----
        case "count", "sizeof": return .integer(Int64(array(0).count))
        case "array_keys": return .array(PHPArray.from(array(0).keys.map { $0.asValue }))
        case "array_values": return .array(PHPArray.from(array(0).values))
        case "array_merge":
            var result = PHPArray()
            for value in arguments {
                let source = value.asArray
                for key in source.keys {
                    switch key {
                    case .integer: result.append(source[key] ?? .null)
                    case .text: result[key] = source[key]
                    }
                }
            }
            return .array(result)
        case "array_slice":
            let source = array(0)
            var offset = Int(integer(1))
            let values = source.keys.map { ($0, source[$0] ?? .null) }
            if offset < 0 { offset = max(0, values.count + offset) }
            var length = values.count - offset
            if arguments.count > 2, !(argument(2) == .null) {
                let requested = Int(integer(2))
                length = requested < 0 ? max(0, values.count - offset + requested) : requested
            }
            let preserveKeys = arguments.count > 3 && argument(3).asBool
            guard offset < values.count else { return .array(PHPArray()) }
            let slice = values[offset..<min(values.count, offset + max(0, length))]
            var result = PHPArray()
            for (key, value) in slice {
                if preserveKeys {
                    result[key] = value
                } else if case .text = key {
                    result[key] = value
                } else {
                    result.append(value)
                }
            }
            return .array(result)
        case "array_reverse":
            let source = array(0)
            let preserveKeys = arguments.count > 1 && argument(1).asBool
            var result = PHPArray()
            for key in source.keys.reversed() {
                if preserveKeys {
                    result[key] = source[key]
                } else if case .text = key {
                    result[key] = source[key]
                } else {
                    result.append(source[key] ?? .null)
                }
            }
            return .array(result)
        case "array_sum":
            var isDouble = false
            var sum = 0.0
            for value in array(0).values {
                if case .number = value { isDouble = true }
                if case .text(let text) = value, case .number? = PHPValue.parseNumeric(text) { isDouble = true }
                sum += value.asDouble
            }
            return isDouble ? .number(sum) : .integer(Int64(sum))
        case "array_product":
            var isDouble = false
            var product = 1.0
            for value in array(0).values {
                if case .number = value { isDouble = true }
                product *= value.asDouble
            }
            return isDouble ? .number(product) : .integer(Int64(product))
        case "in_array":
            let needle = argument(0)
            let strict = arguments.count > 2 && argument(2).asBool
            for value in array(1).values {
                if strict ? PHPOperations.strictEquals(needle, value)
                    : (try PHPOperations.looseEquals(needle, value)) {
                    return .boolean(true)
                }
            }
            return .boolean(false)
        case "array_search":
            let needle = argument(0)
            let source = array(1)
            let strict = arguments.count > 2 && argument(2).asBool
            for key in source.keys {
                let value = source[key] ?? .null
                if strict ? PHPOperations.strictEquals(needle, value)
                    : (try PHPOperations.looseEquals(needle, value)) {
                    return key.asValue
                }
            }
            return .boolean(false)
        case "array_key_exists":
            return .boolean(array(1)[argument(0).asKey] != nil)
        case "array_unique":
            let source = array(0)
            var result = PHPArray()
            var seen: [String] = []
            for key in source.keys {
                let value = source[key] ?? .null
                let text = value.asString
                if !seen.contains(text) {
                    seen.append(text)
                    result[key] = value
                }
            }
            return .array(result)
        case "array_flip":
            let source = array(0)
            var result = PHPArray()
            for key in source.keys {
                result[(source[key] ?? .null).asKey] = key.asValue
            }
            return .array(result)
        case "array_combine":
            let keys = array(0).values
            let values = array(1).values
            var result = PHPArray()
            for (key, value) in zip(keys, values) { result[key.asKey] = value }
            return .array(result)
        case "array_fill":
            var result = PHPArray()
            let start = integer(0)
            for offset in 0..<max(0, Int(integer(1))) {
                result[.integer(start + Int64(offset))] = argument(2)
            }
            return .array(result)
        case "array_column":
            let source = array(0)
            var result = PHPArray()
            for row in source.values {
                let rowArray = row.asArray
                guard let value = rowArray[argument(1).asKey] else { continue }
                if arguments.count > 2, let indexValue = rowArray[argument(2).asKey] {
                    result[indexValue.asKey] = value
                } else {
                    result.append(value)
                }
            }
            return .array(result)
        case "array_diff", "array_intersect":
            let source = array(0)
            var others: [String] = []
            for value in arguments.dropFirst() {
                others.append(contentsOf: value.asArray.values.map(\.asString))
            }
            var result = PHPArray()
            for key in source.keys {
                let value = source[key] ?? .null
                let contains = others.contains(value.asString)
                if (name == "array_diff" && !contains) || (name == "array_intersect" && contains) {
                    result[key] = value
                }
            }
            return .array(result)
        case "array_chunk":
            let source = array(0).values
            let size = max(1, Int(integer(1)))
            var result = PHPArray()
            var chunk: [PHPValue] = []
            for value in source {
                chunk.append(value)
                if chunk.count == size {
                    result.append(.array(PHPArray.from(chunk)))
                    chunk = []
                }
            }
            if !chunk.isEmpty { result.append(.array(PHPArray.from(chunk))) }
            return .array(result)
        case "array_map":
            let callback = argument(0)
            let source = array(1)
            var result = PHPArray()
            if case .null = callback {
                return .array(source)
            }
            if arguments.count > 2 {
                let second = array(2)
                let firstValues = source.values
                let secondValues = second.values
                for index in 0..<max(firstValues.count, secondValues.count) {
                    let left = index < firstValues.count ? firstValues[index] : .null
                    let right = index < secondValues.count ? secondValues[index] : .null
                    result.append(try interpreter.call(value: callback, arguments: [left, right],
                                                       location: location))
                }
                return .array(result)
            }
            var allIntegerKeys = true
            for key in source.keys { if case .text = key { allIntegerKeys = false } }
            for key in source.keys {
                let mapped = try interpreter.call(value: callback, arguments: [source[key] ?? .null],
                                                  location: location)
                if allIntegerKeys {
                    result.append(mapped)
                } else {
                    result[key] = mapped
                }
            }
            return .array(result)
        case "array_filter":
            let source = array(0)
            let callback = arguments.count > 1 ? argument(1) : PHPValue.null
            var result = PHPArray()
            for key in source.keys {
                let value = source[key] ?? .null
                let keep: Bool
                if case .null = callback {
                    keep = value.asBool
                } else {
                    keep = try interpreter.call(value: callback, arguments: [value], location: location).asBool
                }
                if keep { result[key] = value }
            }
            return .array(result)
        case "array_reduce":
            let source = array(0)
            let callback = argument(1)
            var accumulator = arguments.count > 2 ? argument(2) : PHPValue.null
            for value in source.values {
                accumulator = try interpreter.call(value: callback, arguments: [accumulator, value],
                                                   location: location)
            }
            return accumulator
        case "range":
            var result = PHPArray()
            let start = argument(0)
            let end = argument(1)
            if case .text(let startText) = start, case .text(let endText) = end,
               startText.count == 1, endText.count == 1,
               let first = startText.unicodeScalars.first?.value,
               let last = endText.unicodeScalars.first?.value,
               PHPValue.parseNumeric(startText) == nil {
                let values = first <= last ? Array(first...last) : Array((last...first).reversed())
                for scalar in values {
                    result.append(.text(String(Character(UnicodeScalar(scalar) ?? " "))))
                }
                return .array(result)
            }
            let step = arguments.count > 2 ? Swift.abs(number(2)) : 1
            let isDouble = !isIntegerValue(start) || !isIntegerValue(end)
                || (arguments.count > 2 && !isIntegerValue(argument(2)))
            if isDouble {
                var value = start.asDouble
                let target = end.asDouble
                let increasing = target >= value
                while increasing ? value <= target + 1e-9 : value >= target - 1e-9 {
                    result.append(.number(value))
                    value += increasing ? step : -step
                }
            } else {
                var value = start.asInt
                let target = end.asInt
                let increment = Int64(max(1, Int(step)))
                if target >= value {
                    while value <= target {
                        result.append(.integer(value))
                        value += increment
                    }
                } else {
                    while value >= target {
                        result.append(.integer(value))
                        value -= increment
                    }
                }
            }
            return .array(result)

        // ---- 数値 ----
        case "abs":
            if case .integer(let value) = argument(0) { return .integer(Swift.abs(value)) }
            return .number(Swift.abs(number(0)))
        case "max", "min":
            var candidates = arguments
            if arguments.count == 1, case .array(let list) = argument(0) { candidates = list.values }
            guard var best = candidates.first else { return .boolean(false) }
            for value in candidates.dropFirst() {
                let comparison = PHPOperations.compare(value, best)
                if (name == "max" && comparison > 0) || (name == "min" && comparison < 0) { best = value }
            }
            return best
        case "floor": return .number(number(0).rounded(.down))
        case "ceil": return .number(number(0).rounded(.up))
        case "round":
            let precision = arguments.count > 1 ? Int(integer(1)) : 0
            let factor = Foundation.pow(10.0, Double(precision))
            let value = (number(0) * factor).rounded() / factor
            return .number(value)
        case "sqrt": return .number(Foundation.sqrt(number(0)))
        case "pow":
            return try PHPOperations.binary("**", argument(0), argument(1), location)
        case "intdiv":
            guard integer(1) != 0 else {
                throw interpreter.throwFailure("0 で割ろうとしました。", at: location)
            }
            return .integer(integer(0) / integer(1))
        case "fmod": return .number(Foundation.fmod(number(0), number(1)))
        case "pi": return .number(Double.pi)
        case "exp": return .number(Foundation.exp(number(0)))
        case "log":
            if arguments.count > 1 { return .number(Foundation.log(number(0)) / Foundation.log(number(1))) }
            return .number(Foundation.log(number(0)))
        case "log10": return .number(Foundation.log10(number(0)))
        case "sin": return .number(Foundation.sin(number(0)))
        case "cos": return .number(Foundation.cos(number(0)))
        case "tan": return .number(Foundation.tan(number(0)))
        case "asin": return .number(Foundation.asin(number(0)))
        case "acos": return .number(Foundation.acos(number(0)))
        case "atan": return .number(Foundation.atan(number(0)))
        case "atan2": return .number(Foundation.atan2(number(0), number(1)))
        case "deg2rad": return .number(number(0) * Double.pi / 180)
        case "rad2deg": return .number(number(0) * 180 / Double.pi)
        case "rand", "mt_rand", "random_int":
            if arguments.count >= 2 {
                return .integer(interpreter.nextRandom(integer(0), integer(1)))
            }
            return .integer(interpreter.nextRandom(0, 2_147_483_647))
        case "srand", "mt_srand":
            return .null
        case "time": return .integer(1_700_000_000)
        case "microtime": return .number(1_700_000_000.0)
        case "uniqid": return .text("id0000000000000")
        case "usleep", "sleep": return .integer(0)

        // ---- 型 ----
        case "intval":
            if arguments.count > 1, case .text(let value) = argument(0) {
                return .integer(Int64(value.trimmingCharacters(in: .whitespaces), radix: Int(integer(1))) ?? 0)
            }
            return .integer(integer(0))
        case "floatval", "doubleval": return .number(number(0))
        case "strval": return .text(text(0))
        case "boolval": return .boolean(argument(0).asBool)
        case "is_int", "is_integer":
            if case .integer = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_float", "is_double":
            if case .number = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_string":
            if case .text = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_bool":
            if case .boolean = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_array":
            if case .array = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_object":
            if case .object = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_null":
            if case .null = argument(0) { return .boolean(true) }
            return .boolean(false)
        case "is_numeric": return .boolean(argument(0).isNumericValue)
        case "is_callable":
            switch argument(0) {
            case .closure: return .boolean(true)
            case .text(let name): return .boolean(interpreter.hasFunction(name))
            default: return .boolean(false)
            }
        case "gettype": return .text(argument(0).typeName)
        case "get_class":
            if case .object(let object) = argument(0) { return .text(object.className) }
            return .boolean(false)
        case "function_exists": return .boolean(interpreter.hasFunction(text(0)))
        case "class_exists": return .boolean(interpreter.hasClass(text(0)))
        case "method_exists":
            if case .object(let object) = argument(0) {
                return .boolean(interpreter.hasMethod(object, text(1)))
            }
            return .boolean(false)
        case "property_exists":
            if case .object(let object) = argument(0) {
                return .boolean(object.properties[.text(text(1))] != nil)
            }
            return .boolean(false)

        // ---- 出力 ----
        case "print":
            interpreter.write(text(0))
            return .integer(1)
        case "var_dump":
            for value in arguments {
                interpreter.write(PHPFormatter.varDump(value, indent: 0))
            }
            return .null
        case "print_r":
            let rendered = PHPFormatter.printR(argument(0), indent: 0)
            if arguments.count > 1, argument(1).asBool { return .text(rendered) }
            interpreter.write(rendered)
            return .boolean(true)
        case "var_export":
            let rendered = PHPFormatter.varExport(argument(0), indent: 0)
            if arguments.count > 1, argument(1).asBool { return .text(rendered) }
            interpreter.write(rendered)
            return .null
        case "json_encode":
            return .text(PHPFormatter.json(argument(0), pretty: arguments.count > 1 && (integer(1) & 128) != 0))
        case "trigger_error", "error_log":
            interpreter.write(text(0) + "\n")
            return .boolean(true)

        // ---- 配列の先頭・末尾 ----
        case "end", "array_key_last":
            let source = array(0)
            guard let lastKey = source.keys.last else { return .boolean(false) }
            return name == "end" ? (source[lastKey] ?? .null) : lastKey.asValue
        case "reset", "current", "array_key_first":
            let source = array(0)
            guard let firstKey = source.keys.first else { return .boolean(false) }
            return name == "array_key_first" ? firstKey.asValue : (source[firstKey] ?? .null)
        case "key":
            let source = array(0)
            guard let firstKey = source.keys.first else { return .null }
            return firstKey.asValue
        case "array_pad":
            var source = array(0)
            let size = Int(integer(1))
            if source.count >= Swift.abs(size) { return .array(source) }
            var values = source.values
            let padding = Array(repeating: argument(2), count: Swift.abs(size) - values.count)
            values = size < 0 ? padding + values : values + padding
            source.reindex(with: values)
            return .array(source)
        case "array_fill_keys":
            var result = PHPArray()
            for key in array(0).values { result[key.asKey] = argument(1) }
            return .array(result)
        case "levenshtein":
            let left = Array(text(0))
            let right = Array(text(1))
            var previous = Array(0...right.count)
            var current = [Int](repeating: 0, count: right.count + 1)
            for i in 1...Swift.max(1, left.count) where !left.isEmpty {
                current[0] = i
                for j in 1...Swift.max(1, right.count) where !right.isEmpty {
                    let cost = left[i - 1] == right[j - 1] ? 0 : 1
                    current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
                previous = current
            }
            if left.isEmpty { return .integer(Int64(right.count)) }
            if right.isEmpty { return .integer(Int64(left.count)) }
            return .integer(Int64(previous[right.count]))

        // ---- その他 ----
        case "call_user_func":
            return try interpreter.call(value: argument(0), arguments: Array(arguments.dropFirst()),
                                        location: location)
        case "call_user_func_array":
            return try interpreter.call(value: argument(0), arguments: array(1).values, location: location)
        case "clone":
            if case .object(let object) = argument(0) {
                return .object(PHPObject(className: object.className, properties: object.properties))
            }
            return argument(0)
        case "fgets", "readline":
            let line = interpreter.readLine()
            if name == "readline", case .text(let value) = line {
                return .text(value.hasSuffix("\n") ? String(value.dropLast()) : value)
            }
            return line
        case "exit", "die":
            interpreter.write(argument(0).typeName == "string" ? text(0) : "")
            throw PHPExitSignal(code: Int32(truncatingIfNeeded: integer(0)))

        default:
            return nil
        }
    }

    private static func isIntegerValue(_ value: PHPValue) -> Bool {
        if case .integer = value { return true }
        if case .text(let text) = value, case .integer? = PHPValue.parseNumeric(text) { return true }
        return false
    }

    private static func argumentAsList(_ value: PHPValue) -> [String] {
        if case .array(let array) = value { return array.values.map(\.asString) }
        return [value.asString]
    }
}

/// exit / die のためのシグナル。
struct PHPExitSignal: Error {
    var code: Int32
}
