import Foundation

/// C# の標準ライブラリのうちよく使うもの。
enum CSharpLibrary {

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    static func namespace(_ typeName: String, _ entries: [(String, MLValue)]) -> MLObject {
        let object = MLObject(typeName: typeName)
        for (name, value) in entries { object.fields[.string(name)] = value }
        return object
    }

    static func install(into environment: MLEnvironment, semantics: CSharpSemantics) {
        environment.define("Console", .object(makeConsole(semantics: semantics)),
                           isConstant: true)
        environment.define("Math", .object(makeMath()), isConstant: true)
        environment.define("Convert", .object(makeConvert(semantics: semantics)),
                           isConstant: true)
        environment.define("int", .object(makeIntStatics()), isConstant: true)
        environment.define("Int32", .object(makeIntStatics()), isConstant: true)
        environment.define("Int64", .object(makeIntStatics()), isConstant: true)
        environment.define("long", .object(makeIntStatics()), isConstant: true)
        environment.define("double", .object(makeDoubleStatics()), isConstant: true)
        environment.define("Double", .object(makeDoubleStatics()), isConstant: true)
        environment.define("bool", .object(makeBoolStatics()), isConstant: true)
        environment.define("string", .object(makeStringStatics(semantics: semantics)),
                           isConstant: true)
        environment.define("String", .object(makeStringStatics(semantics: semantics)),
                           isConstant: true)
        environment.define("Array", .object(makeArrayStatics()), isConstant: true)
        environment.define("Enumerable", .object(makeEnumerable()), isConstant: true)
        environment.define("char", .object(makeCharStatics()), isConstant: true)
        environment.define("Char", .object(makeCharStatics()), isConstant: true)

        for name in ["List", "LinkedList", "Queue", "Stack", "HashSet", "SortedSet",
                     "IList", "ICollection", "IEnumerable"] {
            environment.define(name, .function(.native(name, 0...2) { context in
                if let source = context.optionalArgument(0)?.asArray {
                    return .array(MLArray(source.elements))
                }
                return .array(MLArray())
            }), isConstant: true)
        }
        for name in ["Dictionary", "SortedDictionary", "IDictionary"] {
            environment.define(name, .function(.native(name, 0...2) { context in
                if let source = context.optionalArgument(0)?.asMap { return .map(source.copy()) }
                return .map(MLMap())
            }), isConstant: true)
        }
        environment.define("StringBuilder", .function(.native("StringBuilder", 0...1) { context in
            let object = MLObject(typeName: "StringBuilder")
            object.fields[.string("value")] = .string(context.optionalArgument(0)?.asString ?? "")
            return .object(object)
        }), isConstant: true)

        environment.define("#newArray", .function(.native("#newArray", 2) { context in
            let count = Int(try context.requireInt(0, "new"))
            let element = semantics.defaultValue(forTypeName: context.argument(1).asString ?? "")
            return .array(MLArray(Array(repeating: element, count: Swift.max(0, count))))
        }), isConstant: true)

        for name in exceptionAncestors.keys {
            environment.define(name, .function(.native(name, 0...2) { context in
                .object(exception(name, context.optionalArgument(0)?.asString ?? ""))
            }), isConstant: true)
        }
    }

    /// C# の例外の継承関係 (`catch (Exception e)` で拾えるようにするため)。
    static let exceptionAncestors: [String: [String]] = [
        "Exception": ["Exception"],
        "SystemException": ["SystemException", "Exception"],
        "ArgumentException": ["ArgumentException", "SystemException", "Exception"],
        "ArgumentNullException": ["ArgumentNullException", "ArgumentException",
                                  "SystemException", "Exception"],
        "ArgumentOutOfRangeException": ["ArgumentOutOfRangeException", "ArgumentException",
                                        "SystemException", "Exception"],
        "InvalidOperationException": ["InvalidOperationException", "SystemException",
                                      "Exception"],
        "ArithmeticException": ["ArithmeticException", "SystemException", "Exception"],
        "DivideByZeroException": ["DivideByZeroException", "ArithmeticException",
                                  "SystemException", "Exception"],
        "OverflowException": ["OverflowException", "ArithmeticException",
                              "SystemException", "Exception"],
        "NullReferenceException": ["NullReferenceException", "SystemException", "Exception"],
        "IndexOutOfRangeException": ["IndexOutOfRangeException", "SystemException",
                                     "Exception"],
        "FormatException": ["FormatException", "SystemException", "Exception"],
        "NotSupportedException": ["NotSupportedException", "SystemException", "Exception"],
        "NotImplementedException": ["NotImplementedException", "SystemException", "Exception"],
        "KeyNotFoundException": ["KeyNotFoundException", "SystemException", "Exception"]
    ]

    static func exception(_ typeName: String, _ message: String) -> MLObject {
        let object = MLObject(typeName: typeName)
        object.fields[.string("Message")] = .string(message)
        let ancestors = exceptionAncestors[typeName] ?? [typeName, "Exception"]
        object.fields[.string("#types")] = .array(MLArray(ancestors.map { .string($0) }))
        return object
    }

    static func makeConsole(semantics: CSharpSemantics) -> MLObject {
        namespace("Console", [
            ("WriteLine", function("WriteLine", 0...32) { context in
                context.interpreter.write(try formatted(context, semantics: semantics) + "\n")
                return .unit
            }),
            ("Write", function("Write", 0...32) { context in
                context.interpreter.write(try formatted(context, semantics: semantics))
                return .unit
            }),
            ("ReadLine", function("ReadLine", 0...0) { context in
                guard let line = context.interpreter.input.nextLine() else { return .unit }
                return .string(line)
            })
        ])
    }

    /// `Console.WriteLine("{0} と {1}", a, b)` の書式にも対応する。
    static func formatted(_ context: MLCallContext,
                          semantics: CSharpSemantics) throws -> String {
        guard let first = context.optionalArgument(0) else { return "" }
        guard context.arguments.count > 1, let pattern = first.asString,
              pattern.contains("{") else {
            return semantics.display(first)
        }
        let rest = Array(context.arguments.dropFirst())
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "{", let close = pattern[index...].firstIndex(of: "}") {
                let inside = String(pattern[pattern.index(after: index)..<close])
                // `{0:F2}` のような書式指定も簡単に扱う。
                let parts = inside.split(separator: ":", maxSplits: 1)
                if let position = Int(parts[0]), position < rest.count {
                    if parts.count == 2 {
                        result += applyFormat(rest[position], String(parts[1]),
                                              semantics: semantics)
                    } else {
                        result += semantics.display(rest[position])
                    }
                    index = pattern.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = pattern.index(after: index)
        }
        return result
    }

    static func applyFormat(_ value: MLValue, _ specifier: String,
                            semantics: CSharpSemantics) -> String {
        guard let kind = specifier.first else { return semantics.display(value) }
        let digits = Int(specifier.dropFirst()) ?? 2
        switch kind {
        case "F", "f": return MLNumberFormatting.fixed(value.asDouble ?? 0, digits: digits)
        case "D", "d": return String(format: "%0\(digits)lld", value.asInt ?? 0)
        case "X": return String(value.asInt ?? 0, radix: 16).uppercased()
        case "x": return String(value.asInt ?? 0, radix: 16)
        case "P", "p":
            return MLNumberFormatting.fixed((value.asDouble ?? 0) * 100, digits: digits) + "%"
        default: return semantics.display(value)
        }
    }

    static func makeMath() -> MLObject {
        var entries: [(String, MLValue)] = [
            ("PI", .double(Double.pi)),
            ("E", .double(M_E)),
            ("Abs", function("Abs", 1) { context in
                switch context.argument(0) {
                case .int(let value): return .int(value < 0 ? -value : value)
                case .double(let value): return .double(Swift.abs(value))
                default: throw MLError.runtime("Math.Abs: 数値が必要です")
                }
            }),
            ("Max", function("Max", 2) { context in
                if case .int(let left) = context.argument(0),
                   case .int(let right) = context.argument(1) {
                    return .int(Swift.max(left, right))
                }
                return .double(Swift.max(context.argument(0).asDouble ?? 0,
                                         context.argument(1).asDouble ?? 0))
            }),
            ("Min", function("Min", 2) { context in
                if case .int(let left) = context.argument(0),
                   case .int(let right) = context.argument(1) {
                    return .int(Swift.min(left, right))
                }
                return .double(Swift.min(context.argument(0).asDouble ?? 0,
                                         context.argument(1).asDouble ?? 0))
            }),
            ("Pow", function("Pow", 2) { context in
                .double(Foundation.pow(try context.requireDouble(0, "Math.Pow"),
                                       try context.requireDouble(1, "Math.Pow")))
            }),
            ("Sqrt", function("Sqrt", 1) { context in
                .double(Foundation.sqrt(try context.requireDouble(0, "Math.Sqrt")))
            }),
            ("Round", function("Round", 1...2) { context in
                let value = try context.requireDouble(0, "Math.Round")
                if let digits = context.optionalArgument(1)?.asInt {
                    let factor = Foundation.pow(10.0, Double(digits))
                    return .double((value * factor).rounded() / factor)
                }
                return .double(value.rounded(.toNearestOrEven))
            }),
            ("Floor", function("Floor", 1) { context in
                .double(Foundation.floor(try context.requireDouble(0, "Math.Floor")))
            }),
            ("Ceiling", function("Ceiling", 1) { context in
                .double(Foundation.ceil(try context.requireDouble(0, "Math.Ceiling")))
            }),
            ("Sign", function("Sign", 1) { context in
                let value = try context.requireDouble(0, "Math.Sign")
                return .int(value > 0 ? 1 : (value < 0 ? -1 : 0))
            })
        ]
        for (name, implementation) in MLStdlib.mathFunctions {
            let capitalized = name.prefix(1).uppercased() + name.dropFirst()
            entries.append((capitalized, function(capitalized, 1) { context in
                .double(implementation(try context.requireDouble(0, "Math." + capitalized)))
            }))
        }
        return namespace("Math", entries)
    }

    static func makeConvert(semantics: CSharpSemantics) -> MLObject {
        namespace("Convert", [
            ("ToInt32", function("ToInt32", 1) { context in
                if let text = context.argument(0).asString,
                   case .string = context.argument(0).forced {
                    guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                        throw MLError.runtime("Convert.ToInt32: 数値に変換できません")
                    }
                    return .int(value)
                }
                return .int(Int64(context.argument(0).asDouble ?? 0))
            }),
            ("ToDouble", function("ToDouble", 1) { context in
                if let text = context.argument(0).asString,
                   case .string = context.argument(0).forced {
                    guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                        throw MLError.runtime("Convert.ToDouble: 数値に変換できません")
                    }
                    return .double(value)
                }
                return .double(context.argument(0).asDouble ?? 0)
            }),
            ("ToString", function("ToString", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("ToBoolean", function("ToBoolean", 1) { context in
                if let text = context.argument(0).asString {
                    return .bool(text.lowercased() == "true")
                }
                return .bool((context.argument(0).asInt ?? 0) != 0)
            })
        ])
    }

    static func makeIntStatics() -> MLObject {
        namespace("int", [
            ("MaxValue", .int(Int64(Int32.max))),
            ("MinValue", .int(Int64(Int32.min))),
            ("Parse", function("Parse", 1) { context in
                let text = try context.requireString(0, "int.Parse")
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Int64(text) else {
                    throw MLError.runtime("int.Parse: 数値に変換できません: \(text)")
                }
                return .int(value)
            }),
            ("TryParse", function("TryParse", 2) { context in
                let text = context.argument(0).asString ?? ""
                let value = Int64(text.trimmingCharacters(in: .whitespaces))
                if context.boxes.count > 1, let box = context.boxes[1] {
                    box.value = .int(value ?? 0)
                }
                return .bool(value != nil)
            })
        ])
    }

    static func makeDoubleStatics() -> MLObject {
        namespace("double", [
            ("MaxValue", .double(Double.greatestFiniteMagnitude)),
            ("MinValue", .double(-Double.greatestFiniteMagnitude)),
            ("Parse", function("Parse", 1) { context in
                let text = try context.requireString(0, "double.Parse")
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Double(text) else {
                    throw MLError.runtime("double.Parse: 数値に変換できません: \(text)")
                }
                return .double(value)
            })
        ])
    }

    static func makeBoolStatics() -> MLObject {
        namespace("bool", [
            ("Parse", function("Parse", 1) { context in
                .bool((context.argument(0).asString ?? "").lowercased() == "true")
            })
        ])
    }

    static func makeCharStatics() -> MLObject {
        func test(_ name: String, _ check: @escaping (Character) -> Bool) -> (String, MLValue) {
            (name, function(name, 1) { context in
                guard let character = context.argument(0).asString?.first else {
                    return .bool(false)
                }
                return .bool(check(character))
            })
        }
        return namespace("char", [
            test("IsDigit") { $0.isNumber },
            test("IsLetter") { $0.isLetter },
            test("IsLetterOrDigit") { $0.isLetter || $0.isNumber },
            test("IsUpper") { $0.isUppercase },
            test("IsLower") { $0.isLowercase },
            test("IsWhiteSpace") { $0.isWhitespace },
            ("ToUpper", function("ToUpper", 1) { context in
                guard let character = context.argument(0).asString?.uppercased().first else {
                    return context.argument(0)
                }
                return .char(character)
            }),
            ("ToLower", function("ToLower", 1) { context in
                guard let character = context.argument(0).asString?.lowercased().first else {
                    return context.argument(0)
                }
                return .char(character)
            })
        ])
    }

    static func makeStringStatics(semantics: CSharpSemantics) -> MLObject {
        namespace("string", [
            ("Empty", .string("")),
            ("Join", function("Join", 1...32) { context in
                let separator = semantics.display(context.argument(0))
                var items = Array(context.arguments.dropFirst())
                if items.count == 1, let array = items[0].asArray { items = array.elements }
                return .string(items.map { semantics.display($0) }.joined(separator: separator))
            }),
            ("Format", function("Format", 1...32) { context in
                .string(try formatted(context, semantics: semantics))
            }),
            ("IsNullOrEmpty", function("IsNullOrEmpty", 1) { context in
                .bool(context.argument(0).isUnit || (context.argument(0).asString ?? "").isEmpty)
            }),
            ("IsNullOrWhiteSpace", function("IsNullOrWhiteSpace", 1) { context in
                let text = context.argument(0).asString ?? ""
                return .bool(context.argument(0).isUnit
                             || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }),
            ("Concat", function("Concat", 0...32) { context in
                .string(context.arguments.map { semantics.display($0) }.joined())
            })
        ])
    }

    static func makeArrayStatics() -> MLObject {
        namespace("Array", [
            ("Sort", function("Sort", 1...2) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                array.elements = try MLStdlib.stableSorted(
                    array.elements, interpreter: context.interpreter,
                    comparator: context.optionalArgument(1)?.asFunction)
                return .unit
            }),
            ("Reverse", function("Reverse", 1) { context in
                context.argument(0).asArray?.elements.reverse()
                return .unit
            }),
            ("IndexOf", function("IndexOf", 2) { context in
                guard let array = context.argument(0).asArray else { return .int(-1) }
                let target = context.argument(1)
                let semantics = context.interpreter.semantics
                if let found = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                    return .int(Int64(found))
                }
                return .int(-1)
            })
        ])
    }

    static func makeEnumerable() -> MLObject {
        namespace("Enumerable", [
            ("Range", function("Range", 2) { context in
                let start = try context.requireInt(0, "Enumerable.Range")
                let count = try context.requireInt(1, "Enumerable.Range")
                return .array(MLArray((0..<Swift.max(0, Int(count)))
                    .map { .int(start + Int64($0)) }))
            }),
            ("Repeat", function("Repeat", 2) { context in
                let value = context.argument(0)
                let count = Int(try context.requireInt(1, "Enumerable.Repeat"))
                return .array(MLArray(Array(repeating: value, count: Swift.max(0, count))))
            }),
            ("Empty", function("Empty", 0...1) { _ in .array(MLArray()) })
        ])
    }

    // MARK: インスタンスメソッド

    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: CSharpSemantics) throws -> MLValue? {
        if let object = receiver.asObject, object.typeName == "StringBuilder" {
            let current = object.fields[.string("value")]?.asString ?? ""
            switch name {
            case "Append":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return receiver
            case "AppendLine":
                let added = context.optionalArgument(0).map { semantics.display($0) } ?? ""
                object.fields[.string("value")] = .string(current + added + "\n")
                return receiver
            case "ToString": return .string(current)
            case "Clear":
                object.fields[.string("value")] = .string("")
                return receiver
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
            case "ToString": return .string(String(character))
            case "CompareTo":
                return .int(Int64(semantics.compare(receiver, context.argument(0)) ?? 0))
            default:
                return try stringMethod(String(character), name: name, context: context,
                                        semantics: semantics)
            }
        case .array(let array):
            return try listMethod(array, name: name, context: context, semantics: semantics)
        case .map(let map):
            return try mapMethod(map, name: name, context: context, semantics: semantics)
        case .int, .double, .bool:
            switch name {
            case "ToString":
                if let specifier = context.optionalArgument(0)?.asString {
                    return .string(applyFormat(receiver, specifier, semantics: semantics))
                }
                return .string(semantics.display(receiver))
            case "CompareTo":
                return .int(Int64(semantics.compare(receiver, context.argument(0)) ?? 0))
            case "Equals": return .bool(semantics.areEqual(receiver, context.argument(0)))
            default: return nil
            }
        default:
            if let object = receiver.asObject, object.fields.contains(.string("Message")),
               object.classDeclaration == nil {
                if name == "ToString" {
                    let message = object.fields[.string("Message")]?.asString ?? ""
                    return .string(message.isEmpty ? object.typeName
                                                   : "\(object.typeName): \(message)")
                }
            }
            return nil
        }
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: CSharpSemantics) throws -> MLValue? {
        let characters = Array(text)
        switch name {
        case "ToUpper": return .string(text.uppercased())
        case "ToLower": return .string(text.lowercased())
        case "Trim": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "TrimStart": return .string(String(text.drop(while: { $0.isWhitespace })))
        case "TrimEnd":
            var result = text
            while let last = result.last, last.isWhitespace { result.removeLast() }
            return .string(result)
        case "Contains":
            guard let needle = context.argument(0).asString else { return .bool(false) }
            return .bool(needle.isEmpty || text.contains(needle))
        case "StartsWith":
            return .bool(text.hasPrefix(context.argument(0).asString ?? ""))
        case "EndsWith":
            return .bool(text.hasSuffix(context.argument(0).asString ?? ""))
        case "IndexOf":
            guard let needle = context.argument(0).asString,
                  let found = MLStdlib.firstIndex(of: needle, in: characters) else {
                return .int(-1)
            }
            return .int(Int64(found))
        case "LastIndexOf":
            guard let needle = context.argument(0).asString,
                  let found = MLStdlib.lastIndex(of: needle, in: characters) else {
                return .int(-1)
            }
            return .int(Int64(found))
        case "Substring":
            let start = Int(try context.requireInt(0, "Substring"))
            let length = context.optionalArgument(1)?.asInt.map { Int($0) }
                ?? (characters.count - start)
            guard start >= 0, start <= characters.count, length >= 0,
                  start + length <= characters.count else {
                throw MLError.runtime("Substring: 範囲が不正です")
            }
            return .string(String(characters[start..<(start + length)]))
        case "Replace":
            return .string(text.replacingOccurrences(of: context.argument(0).asString ?? "",
                                                     with: context.argument(1).asString ?? ""))
        case "Split":
            var separators: [String] = []
            for argument in context.arguments {
                if let array = argument.asArray {
                    separators += array.elements.compactMap { $0.asString }
                } else if let text = argument.asString {
                    separators.append(text)
                }
            }
            if separators.isEmpty { separators = [" "] }
            var parts = [text]
            for separator in separators where !separator.isEmpty {
                parts = parts.flatMap { $0.components(separatedBy: separator) }
            }
            return .array(MLArray(parts.map { .string($0) }))
        case "ToCharArray": return .array(MLArray(characters.map { .char($0) }))
        case "ToString": return .string(text)
        case "Equals": return .bool(context.argument(0).asString == text)
        case "CompareTo":
            return .int(Int64(semantics.compare(.string(text), context.argument(0)) ?? 0))
        case "PadLeft":
            let width = Int(try context.requireInt(0, "PadLeft"))
            let padding = context.optionalArgument(1)?.asString ?? " "
            return .string(MLStdlib.pad(text, to: width, with: padding, left: true))
        case "PadRight":
            let width = Int(try context.requireInt(0, "PadRight"))
            let padding = context.optionalArgument(1)?.asString ?? " "
            return .string(MLStdlib.pad(text, to: width, with: padding, left: false))
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    static func listMethod(_ array: MLArray, name: String, context: MLCallContext,
                           semantics: CSharpSemantics) throws -> MLValue? {
        let interpreter = context.interpreter
        switch name {
        case "Add":
            array.elements.append(context.argument(0))
            return .unit
        case "AddRange":
            if let other = context.argument(0).asArray {
                array.elements.append(contentsOf: other.elements)
            }
            return .unit
        case "Insert":
            let position = Int(try context.requireInt(0, "Insert"))
            let clamped = Swift.max(0, Swift.min(position, array.count))
            array.elements.insert(context.argument(1), at: clamped)
            return .unit
        case "Remove":
            let target = context.argument(0)
            if let found = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                array.elements.remove(at: found)
                return .bool(true)
            }
            return .bool(false)
        case "RemoveAt":
            let position = Int(try context.requireInt(0, "RemoveAt"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("RemoveAt: 範囲外です")
            }
            array.elements.remove(at: position)
            return .unit
        case "Clear":
            array.elements.removeAll()
            return .unit
        case "Contains":
            let target = context.argument(0)
            return .bool(array.elements.contains { semantics.areEqual($0, target) })
        case "IndexOf":
            let target = context.argument(0)
            if let found = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                return .int(Int64(found))
            }
            return .int(-1)
        case "Sort":
            array.elements = try MLStdlib.stableSorted(
                array.elements, interpreter: interpreter,
                comparator: context.optionalArgument(0)?.asFunction)
            return .unit
        case "Reverse":
            array.elements.reverse()
            return .unit
        case "ToArray", "ToList": return .array(MLArray(array.elements))
        case "Count":
            if let predicate = context.optionalArgument(0)?.asFunction {
                var total = 0
                for element in array.elements
                where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element])) {
                    total += 1
                }
                return .int(Int64(total))
            }
            return .int(Int64(array.count))
        // LINQ 風のメソッド。
        case "Select":
            return try MLStdlib.callMethod(on: .array(array), name: "map", context: context)
        case "Where":
            return try MLStdlib.callMethod(on: .array(array), name: "filter", context: context)
        case "Sum":
            return try MLStdlib.callMethod(on: .array(array), name: "sum", context: context)
        case "Max":
            return try MLStdlib.callMethod(on: .array(array), name: "max", context: context)
        case "Min":
            return try MLStdlib.callMethod(on: .array(array), name: "min", context: context)
        case "Average":
            guard !array.elements.isEmpty else { return .double(0) }
            var total = 0.0
            for element in array.elements { total += element.asDouble ?? 0 }
            return .double(total / Double(array.count))
        case "First", "FirstOrDefault":
            if let predicate = context.optionalArgument(0)?.asFunction {
                for element in array.elements
                where try semantics.isTruthy(interpreter.callFunction(predicate,
                                                                      arguments: [element])) {
                    return element
                }
                return .unit
            }
            return array.elements.first ?? .unit
        case "Last", "LastOrDefault": return array.elements.last ?? .unit
        case "Any":
            return try MLStdlib.callMethod(on: .array(array), name: "any", context: context)
                ?? .bool(!array.elements.isEmpty)
        case "All":
            return try MLStdlib.callMethod(on: .array(array), name: "all", context: context)
        case "OrderBy":
            let key = try context.requireFunction(0, "OrderBy")
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: key, byKey: true)))
        case "OrderByDescending":
            let key = try context.requireFunction(0, "OrderByDescending")
            return .array(MLArray(try MLStdlib.stableSorted(array.elements,
                                                            interpreter: interpreter,
                                                            comparator: key,
                                                            byKey: true).reversed()))
        case "Take":
            return try MLStdlib.callMethod(on: .array(array), name: "take", context: context)
        case "Skip":
            return try MLStdlib.callMethod(on: .array(array), name: "drop", context: context)
        case "Distinct":
            return try MLStdlib.callMethod(on: .array(array), name: "distinct", context: context)
        case "ForEach":
            return try MLStdlib.callMethod(on: .array(array), name: "forEach", context: context)
        case "ToString":
            return .string("[" + array.elements.map { semantics.display($0) }
                .joined(separator: ", ") + "]")
        case "Push":
            array.elements.append(context.argument(0))
            return .unit
        case "Pop":
            guard let last = array.elements.popLast() else {
                throw MLError.runtime("Pop: 空です")
            }
            return last
        case "Peek": return array.elements.last ?? .unit
        case "Enqueue":
            array.elements.append(context.argument(0))
            return .unit
        case "Dequeue":
            guard !array.elements.isEmpty else { throw MLError.runtime("Dequeue: 空です") }
            return array.elements.removeFirst()
        default:
            return nil
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: CSharpSemantics) throws -> MLValue? {
        switch name {
        case "Add":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            map[key] = context.argument(1)
            return .unit
        case "ContainsKey":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.contains(key))
        case "ContainsValue":
            let target = context.argument(0)
            return .bool(map.values.contains { semantics.areEqual($0, target) })
        case "Remove":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            return .bool(map.removeValue(forKey: key) != nil)
        case "TryGetValue":
            guard let key = MLKey.from(context.argument(0)) else { return .bool(false) }
            if let value = map[key] {
                if context.boxes.count > 1, let box = context.boxes[1] { box.value = value }
                return .bool(true)
            }
            return .bool(false)
        case "Clear":
            map.removeAll()
            return .unit
        default:
            return nil
        }
    }
}
