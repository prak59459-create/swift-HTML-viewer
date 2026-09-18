import Foundation

/// Kotlin の標準ライブラリ。
enum KotlinLibrary {

    static func install(into environment: MLEnvironment, semantics: KotlinSemantics) {
        environment.define("println", .function(.native("println", 0...1) { context in
            let text = context.optionalArgument(0).map { semantics.display($0) } ?? ""
            context.interpreter.write(text + "\n")
            return .unit
        }))
        environment.define("print", .function(.native("print", 0...1) { context in
            context.interpreter.write(context.optionalArgument(0)
                .map { semantics.display($0) } ?? "")
            return .unit
        }))
        environment.define("readLine", .function(.native("readLine", 0...0) { context in
            guard let line = context.interpreter.input.nextLine() else { return .unit }
            return .string(line)
        }))
        environment.define("readln", .function(.native("readln", 0...0) { context in
            .string(context.interpreter.input.nextLine() ?? "")
        }))

        environment.define("listOf", .function(.native("listOf", 0...64) { context in
            .array(MLArray(context.arguments))
        }))
        environment.define("mutableListOf", .function(.native("mutableListOf", 0...64) { context in
            .array(MLArray(context.arguments))
        }))
        environment.define("arrayListOf", .function(.native("arrayListOf", 0...64) { context in
            .array(MLArray(context.arguments))
        }))
        environment.define("arrayOf", .function(.native("arrayOf", 0...64) { context in
            .array(MLArray(context.arguments))
        }))
        environment.define("setOf", .function(.native("setOf", 0...64) { context in
            var unique: [MLValue] = []
            for value in context.arguments
            where !unique.contains(where: { semantics.areEqual($0, value) }) {
                unique.append(value)
            }
            return .array(MLArray(unique))
        }))
        environment.define("emptyList", .function(.native("emptyList", 0...0) { _ in
            .array(MLArray())
        }))
        environment.define("mapOf", .function(.native("mapOf", 0...64) { context in
            .map(pairsToMap(context.arguments))
        }))
        environment.define("mutableMapOf", .function(.native("mutableMapOf", 0...64) { context in
            .map(pairsToMap(context.arguments))
        }))
        environment.define("hashMapOf", .function(.native("hashMapOf", 0...64) { context in
            .map(pairsToMap(context.arguments))
        }))
        // `HashMap<String, Int>()` のように、型の名前で作る書き方。
        for name in ["HashMap", "LinkedHashMap", "MutableMap", "Map"] {
            environment.define(name, .function(.native(name, 0...64) { context in
                .map(pairsToMap(context.arguments))
            }))
        }
        for name in ["ArrayList", "MutableList", "List"] {
            environment.define(name, .function(.native(name, 0...64) { context in
                // 引数があれば、それを並びの中身にする。
                if context.arguments.count == 1,
                   case .array(let array) = context.argument(0) {
                    return .array(MLArray(array.elements))
                }
                return .array(MLArray(context.arguments))
            }))
        }
        for name in ["HashSet", "MutableSet", "LinkedHashSet"] {
            environment.define(name, .function(.native(name, 0...64) { context in
                var seen: [MLValue] = []
                let source: [MLValue]
                if context.arguments.count == 1,
                   case .array(let array) = context.argument(0) {
                    source = array.elements
                } else {
                    source = context.arguments
                }
                for value in source
                where !seen.contains(where: {
                    context.interpreter.semantics.areEqual($0, value)
                }) {
                    seen.append(value)
                }
                return .array(MLArray(seen))
            }))
        }
        environment.define("Pair", .function(.native("Pair", 2) { context in
            .tuple([context.argument(0), context.argument(1)])
        }))
        environment.define("Triple", .function(.native("Triple", 3) { context in
            .tuple([context.argument(0), context.argument(1), context.argument(2)])
        }))
        environment.define("to", .function(.native("to", 2) { context in
            .tuple([context.argument(0), context.argument(1)])
        }))

        environment.define("IntArray", .function(.native("IntArray", 1...2) { context in
            let count = Int(try context.requireInt(0, "IntArray"))
            if let initializer = context.optionalArgument(1)?.asFunction {
                var elements: [MLValue] = []
                for index in 0..<Swift.max(0, count) {
                    elements.append(try context.interpreter.callFunction(
                        initializer, arguments: [.int(Int64(index))]))
                }
                return .array(MLArray(elements))
            }
            return .array(MLArray(Array(repeating: .int(0), count: Swift.max(0, count))))
        }))
        environment.define("Array", .function(.native("Array", 1...2) { context in
            let count = Int(try context.requireInt(0, "Array"))
            if let initializer = context.optionalArgument(1)?.asFunction {
                var elements: [MLValue] = []
                for index in 0..<Swift.max(0, count) {
                    elements.append(try context.interpreter.callFunction(
                        initializer, arguments: [.int(Int64(index))]))
                }
                return .array(MLArray(elements))
            }
            return .array(MLArray(Array(repeating: .unit, count: Swift.max(0, count))))
        }))
        environment.define("StringBuilder", .function(.native("StringBuilder", 0...1) { context in
            let object = MLObject(typeName: "StringBuilder")
            object.fields[.string("value")] = .string(context.optionalArgument(0)?.asString ?? "")
            return .object(object)
        }))

        environment.define("Math", .object(mathNamespace()), isConstant: true)
        environment.define("kotlin", .object(kotlinNamespace()), isConstant: true)
        for (name, implementation) in MLStdlib.mathFunctions {
            environment.define(name, .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            }))
        }
        environment.define("maxOf", .function(.native("maxOf", 2...8) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: false)
        }))
        environment.define("minOf", .function(.native("minOf", 2...8) { context in
            try MLStdlib.reduceExtreme(context, keepSmaller: true)
        }))
        environment.define("abs", .function(.native("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            case .double(let value): return .double(Swift.abs(value))
            default: throw MLError.runtime("abs: 数値が必要です")
            }
        }))
        environment.define("require", .function(.native("require", 1...2) { context in
            if try !semantics.isTruthy(context.argument(0)) {
                throw MLError.runtime("要求を満たしていません (require)")
            }
            return .unit
        }))
        environment.define("error", .function(.native("error", 1) { context in
            throw MLError.runtime(semantics.display(context.argument(0)))
        }))
        environment.define("TODO", .function(.native("TODO", 0...1) { _ in
            throw MLError.runtime("まだ実装されていません (TODO)")
        }))

        for name in ["Exception", "RuntimeException", "IllegalArgumentException",
                     "IllegalStateException", "ArithmeticException",
                     "IndexOutOfBoundsException", "NumberFormatException"] {
            environment.define(name, .function(.native(name, 0...1) { context in
                let object = MLObject(typeName: name)
                object.fields[.string("message")] =
                    .string(context.optionalArgument(0)?.asString ?? "")
                return .object(object)
            }), isConstant: true)
        }
    }

    static func pairsToMap(_ arguments: [MLValue]) -> MLMap {
        let map = MLMap()
        for argument in arguments {
            guard case .tuple(let items) = argument.forced, items.count >= 2,
                  let key = MLKey.from(items[0]) else { continue }
            map[key] = items[1]
        }
        return map
    }

    static func mathNamespace() -> MLObject {
        let object = MLObject(typeName: "Math")
        object.fields[.string("PI")] = .double(Double.pi)
        object.fields[.string("E")] = .double(M_E)
        for (name, implementation) in MLStdlib.mathFunctions {
            object.fields[.string(name)] = .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            })
        }
        object.fields[.string("pow")] = .function(.native("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        })
        return object
    }

    static func kotlinNamespace() -> MLObject {
        let math = MLObject(typeName: "kotlin.math")
        math.fields[.string("PI")] = .double(Double.pi)
        math.fields[.string("E")] = .double(M_E)
        for (name, implementation) in MLStdlib.mathFunctions {
            math.fields[.string(name)] = .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            })
        }
        let root = MLObject(typeName: "kotlin")
        root.fields[.string("math")] = .object(math)
        return root
    }

    // MARK: メソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: KotlinSemantics) throws -> MLValue? {
        let interpreter = context.interpreter

        // スコープ関数 (`let` / `also` / `apply` / `run` / `takeIf`)。
        switch name {
        case "let", "run":
            guard let body = context.optionalArgument(0)?.asFunction else { return nil }
            return try interpreter.callFunction(body, arguments: [receiver])
        case "also", "apply":
            guard let body = context.optionalArgument(0)?.asFunction else { return nil }
            _ = try interpreter.callFunction(body, arguments: [receiver])
            return receiver
        case "takeIf":
            guard let predicate = context.optionalArgument(0)?.asFunction else { return nil }
            let keep = try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                       arguments: [receiver]))
            return keep ? receiver : .unit
        case "takeUnless":
            guard let predicate = context.optionalArgument(0)?.asFunction else { return nil }
            let drop = try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                       arguments: [receiver]))
            return drop ? .unit : receiver
        case "toString":
            if context.arguments.isEmpty, receiver.asObject?.classDeclaration == nil {
                return .string(semantics.display(receiver))
            }
        default:
            break
        }

        if let object = receiver.asObject, object.typeName == "StringBuilder" {
            let current = object.fields[.string("value")]?.asString ?? ""
            switch name {
            case "append":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return receiver
            case "appendLine":
                let added = context.optionalArgument(0).map { semantics.display($0) } ?? ""
                object.fields[.string("value")] = .string(current + added + "\n")
                return receiver
            case "toString": return .string(current)
            default:
                return try MLStdlib.callMethod(on: .string(current), name: name,
                                               context: context)
            }
        }

        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context, semantics: semantics)
        case .char(let character):
            switch name {
            case "isDigit": return .bool(character.isNumber)
            case "isLetter": return .bool(character.isLetter)
            case "isLetterOrDigit": return .bool(character.isLetter || character.isNumber)
            case "isUpperCase": return .bool(character.isUppercase)
            case "isLowerCase": return .bool(character.isLowercase)
            case "isWhitespace": return .bool(character.isWhitespace)
            case "uppercaseChar":
                return .char(String(character).uppercased().first ?? character)
            case "lowercaseChar":
                return .char(String(character).lowercased().first ?? character)
            case "digitToInt": return .int(Int64(character.wholeNumberValue ?? 0))
            case "code": return .int(Int64(character.unicodeScalars.first?.value ?? 0))
            default:
                return try stringMethod(String(character), name: name, context: context,
                                        semantics: semantics)
            }
        case .array(let array):
            return try listMethod(array, name: name, context: context, semantics: semantics)
        case .map(let map):
            return try mapMethod(map, name: name, context: context, semantics: semantics)
        case .range(let range):
            let array = MLArray(range.elements.map { .int($0) })
            return try listMethod(array, name: name, context: context, semantics: semantics)
        case .int, .double:
            switch name {
            case "toInt", "toLong": return .int(receiver.asInt ?? Int64(receiver.asDouble ?? 0))
            case "toDouble", "toFloat": return .double(receiver.asDouble ?? 0)
            case "toChar":
                guard let number = receiver.asInt,
                      let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: number)) else {
                    return .unit
                }
                return .char(Character(scalar))
            case "coerceIn":
                let low = context.argument(0)
                let high = context.argument(1)
                if semantics.compare(receiver, low) ?? 0 < 0 { return low }
                if semantics.compare(receiver, high) ?? 0 > 0 { return high }
                return receiver
            case "coerceAtLeast":
                return semantics.compare(receiver, context.argument(0)) ?? 0 < 0
                    ? context.argument(0) : receiver
            case "coerceAtMost":
                return semantics.compare(receiver, context.argument(0)) ?? 0 > 0
                    ? context.argument(0) : receiver
            case "rangeTo":
                guard let low = receiver.asInt, let high = context.argument(0).asInt else {
                    return .unit
                }
                return .range(MLRange(lower: low, upper: high, isClosed: true))
            case "until":
                guard let low = receiver.asInt, let high = context.argument(0).asInt else {
                    return .unit
                }
                return .range(MLRange(lower: low, upper: high, isClosed: false))
            case "downTo":
                guard let low = receiver.asInt, let high = context.argument(0).asInt else {
                    return .unit
                }
                return .range(MLRange(lower: low, upper: high, isClosed: true, step: -1))
            case "to": return .tuple([receiver, context.argument(0)])
            default:
                return try MLStdlib.callMethod(on: receiver, name: name, context: context)
            }
        case .tuple(let items):
            switch name {
            case "toList": return .array(MLArray(items))
            case "component1": return items.first ?? .unit
            case "component2": return items.count > 1 ? items[1] : .unit
            default: return nil
            }
        default:
            return nil
        }
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: KotlinSemantics) throws -> MLValue? {
        switch name {
        case "uppercase", "toUpperCase": return .string(text.uppercased())
        case "lowercase", "toLowerCase": return .string(text.lowercased())
        case "toInt", "toIntOrNull":
            guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                if name == "toIntOrNull" { return .unit }
                throw MLError.runtime("toInt: 数値に変換できません: \(text)")
            }
            return .int(value)
        case "toDouble", "toDoubleOrNull":
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                if name == "toDoubleOrNull" { return .unit }
                throw MLError.runtime("toDouble: 数値に変換できません: \(text)")
            }
            return .double(value)
        case "toCharArray", "toList": return .array(MLArray(text.map { .char($0) }))
        case "split":
            var separators: [String] = []
            for argument in context.arguments {
                if let array = argument.asArray {
                    separators += array.elements.compactMap { $0.asString }
                } else if let value = argument.asString {
                    separators.append(value)
                }
            }
            if separators.isEmpty { return .array(MLArray([.string(text)])) }
            var parts = [text]
            for separator in separators where !separator.isEmpty {
                parts = parts.flatMap { $0.components(separatedBy: separator) }
            }
            return .array(MLArray(parts.map { .string($0) }))
        case "substring":
            let characters = Array(text)
            let start = Int(try context.requireInt(0, "substring"))
            let end = context.optionalArgument(1)?.asInt.map { Int($0) } ?? characters.count
            guard start >= 0, end <= characters.count, start <= end else {
                throw MLError.runtime("substring: 範囲が不正です")
            }
            return .string(String(characters[start..<end]))
        case "get":
            let characters = Array(text)
            let position = Int(try context.requireInt(0, "get"))
            guard position >= 0, position < characters.count else {
                throw MLError.runtime("get: 範囲外です")
            }
            return .char(characters[position])
        case "forEach":
            let body = try context.requireFunction(0, "forEach")
            for character in text {
                _ = try context.interpreter.callFunction(body, arguments: [.char(character)])
            }
            return .unit
        case "isBlank":
            return .bool(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case "isNotBlank":
            return .bool(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case "repeat":
            let count = Int(try context.requireInt(0, "repeat"))
            return .string(count > 0 ? String(repeating: text, count: count) : "")
        case "format":
            return .string(try MLStdlib.format(text, arguments: context.arguments,
                                               semantics: semantics))
        case "removePrefix":
            let prefix = context.argument(0).asString ?? ""
            return .string(text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text)
        case "removeSuffix":
            let suffix = context.argument(0).asString ?? ""
            return .string(text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text)
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    static func listMethod(_ array: MLArray, name: String, context: MLCallContext,
                           semantics: KotlinSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch name {
        case "add", "plusAssign":
            array.elements.append(context.argument(0))
            return .bool(true)
        case "get":
            let position = Int(try context.requireInt(0, "get"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("get: 添字 \(position) は範囲外です")
            }
            return array.elements[position]
        case "getOrNull":
            let position = Int(try context.requireInt(0, "getOrNull"))
            guard position >= 0, position < array.count else { return .unit }
            return array.elements[position]
        case "set":
            let position = Int(try context.requireInt(0, "set"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("set: 添字 \(position) は範囲外です")
            }
            let previous = array.elements[position]
            array.elements[position] = context.argument(1)
            return previous
        case "removeAt":
            let position = Int(try context.requireInt(0, "removeAt"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("removeAt: 添字 \(position) は範囲外です")
            }
            return array.elements.remove(at: position)
        case "sortedBy":
            let key = try context.requireFunction(0, "sortedBy")
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: key, byKey: true)))
        case "sortedByDescending":
            let key = try context.requireFunction(0, "sortedByDescending")
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: key,
                                                            byKey: true).reversed()))
        case "sorted":
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: nil)))
        case "sortedDescending":
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: nil).reversed()))
        case "forEachIndexed":
            let body = try context.requireFunction(0, "forEachIndexed")
            for (index, element) in array.elements.enumerated() {
                _ = try interpreter.callFunction(body, arguments: [.int(Int64(index)), element])
            }
            return .unit
        case "withIndex", "mapIndexed" where context.arguments.isEmpty:
            return .array(MLArray(array.elements.enumerated()
                .map { .tuple([.int(Int64($0.offset)), $0.element]) }))
        case "associateWith":
            let transform = try context.requireFunction(0, "associateWith")
            let map = MLMap()
            for element in array.elements {
                guard let key = MLKey.from(element) else { continue }
                map[key] = try interpreter.callFunction(transform, arguments: [element])
            }
            return .map(map)
        case "associateBy":
            let transform = try context.requireFunction(0, "associateBy")
            let map = MLMap()
            for element in array.elements {
                let keyValue = try interpreter.callFunction(transform, arguments: [element])
                guard let key = MLKey.from(keyValue) else { continue }
                map[key] = element
            }
            return .map(map)
        case "groupBy":
            return try MLStdlib.callMethod(on: .array(array), name: "groupBy", context: context)
        case "joinToString":
            var separator = ", "
            if let first = context.optionalArgument(0)?.asString { separator = first }
            if let labeled = context.argument(labeled: "separator")?.asString {
                separator = labeled
            }
            return .string(array.elements.map { semantics.display($0) }
                .joined(separator: separator))
        case "sum", "sumOf":
            if let selector = context.optionalArgument(0)?.asFunction {
                var total = MLValue.int(0)
                for element in array.elements {
                    let value = try interpreter.callFunction(selector, arguments: [element])
                    total = try MLOperations.arithmetic(op: "+", lhs: total, rhs: value,
                                                        semantics: semantics)
                }
                return total
            }
            return try MLStdlib.callMethod(on: .array(array), name: "sum", context: context)
        case "average":
            guard !array.elements.isEmpty else { return .double(Double.nan) }
            var total = 0.0
            for element in array.elements { total += element.asDouble ?? 0 }
            return .double(total / Double(array.count))
        case "maxOrNull", "minOrNull", "max", "min":
            guard !array.elements.isEmpty else { return .unit }
            return try MLStdlib.extreme(array.elements, semantics: semantics,
                                        smaller: name.hasPrefix("min"))
        case "maxByOrNull", "minByOrNull":
            let key = try context.requireFunction(0, name)
            guard var best = array.elements.first else { return .unit }
            var bestKey = try interpreter.callFunction(key, arguments: [best])
            for element in array.elements.dropFirst() {
                let candidate = try interpreter.callFunction(key, arguments: [element])
                let order = semantics.compare(candidate, bestKey) ?? 0
                if name.hasPrefix("max") ? order > 0 : order < 0 {
                    best = element
                    bestKey = candidate
                }
            }
            return best
        case "count":
            return try MLStdlib.callMethod(on: .array(array), name: "length", context: context)
        case "firstOrNull":
            if let predicate = context.optionalArgument(0)?.asFunction {
                for element in array.elements
                where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element])) {
                    return element
                }
                return .unit
            }
            return array.elements.first ?? .unit
        case "lastOrNull": return array.elements.last ?? .unit
        case "toMutableList", "toList", "toTypedArray", "toIntArray":
            return .array(MLArray(array.elements))
        case "toSet", "distinct":
            return try MLStdlib.callMethod(on: .array(array), name: "distinct", context: context)
        case "none":
            guard let predicate = context.optionalArgument(0)?.asFunction else {
                return .bool(array.elements.isEmpty)
            }
            for element in array.elements
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                return .bool(false)
            }
            return .bool(true)
        case "reversed":
            return .array(MLArray(array.elements.reversed()))
        case "shuffled":
            return .array(MLArray(array.elements.shuffled()))
        case "indexOfFirst":
            let predicate = try context.requireFunction(0, "indexOfFirst")
            for (index, element) in array.elements.enumerated()
            where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                  arguments: [element])) {
                return .int(Int64(index))
            }
            return .int(-1)
        case "chunked", "windowed":
            return try MLStdlib.callMethod(on: .array(array), name: "chunked", context: context)
        default:
            return try MLStdlib.callMethod(on: .array(array), name: name, context: context)
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: KotlinSemantics) throws -> MLValue? {
        switch name {
        case "put", "set":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            let previous = map[key]
            map[key] = context.argument(1)
            return previous ?? .unit
        case "get", "getOrNull":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            return map[key] ?? .unit
        case "getOrDefault", "getOrElse":
            guard let key = MLKey.from(context.argument(0)) else {
                return context.optionalArgument(1) ?? .unit
            }
            if let value = map[key] { return value }
            if let fallback = context.optionalArgument(1)?.asFunction {
                return try context.interpreter.callFunction(fallback, arguments: [])
            }
            return context.optionalArgument(1) ?? .unit
        case "getOrPut":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            if let value = map[key] { return value }
            let producer = try context.requireFunction(1, "getOrPut")
            let value = try context.interpreter.callFunction(producer, arguments: [])
            map[key] = value
            return value
        case "containsKey":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))
        case "forEach":
            let body = try context.requireFunction(0, "forEach")
            for (key, value) in map.pairs {
                _ = try context.interpreter.callFunction(
                    body, arguments: [.tuple([key.asValue, value])])
            }
            return .unit
        case "toList", "entries":
            return .array(MLArray(map.pairs.map { .tuple([$0.key.asValue, $0.value]) }))
        default:
            return try MLStdlib.callMethod(on: .map(map), name: name, context: context)
        }
    }
}
