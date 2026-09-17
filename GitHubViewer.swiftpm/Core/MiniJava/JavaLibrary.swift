import Foundation

/// Java の標準ライブラリのうち、よく使うものを Swift で用意する。
enum JavaLibrary {

    static func install(into environment: MLEnvironment, interpreter: MLInterpreter,
                        semantics: JavaSemantics) {
        environment.define("System", .object(makeSystem(interpreter: interpreter,
                                                        semantics: semantics)),
                           isConstant: true)
        environment.define("Math", .object(makeMath()), isConstant: true)
        environment.define("Integer", .object(makeInteger(semantics: semantics)),
                           isConstant: true)
        environment.define("Long", .object(makeInteger(semantics: semantics)), isConstant: true)
        environment.define("Double", .object(makeDouble(semantics: semantics)), isConstant: true)
        environment.define("Boolean", .object(makeBoolean()), isConstant: true)
        environment.define("Character", .object(makeCharacter()), isConstant: true)
        environment.define("String", .object(makeStringStatics(semantics: semantics)),
                           isConstant: true)
        environment.define("Arrays", .object(makeArrays(interpreter: interpreter,
                                                        semantics: semantics)),
                           isConstant: true)
        environment.define("Collections", .object(makeCollections(interpreter: interpreter)),
                           isConstant: true)
        environment.define("Objects", .object(makeObjects(semantics: semantics)),
                           isConstant: true)

        // コレクションの生成。
        for name in ["ArrayList", "LinkedList", "Stack", "ArrayDeque", "Vector",
                     "PriorityQueue", "List", "HashSet", "LinkedHashSet", "TreeSet", "Set"] {
            environment.define(name, .function(.native(name, 0...2) { context in
                if let source = context.optionalArgument(0)?.asArray {
                    return .array(MLArray(source.elements))
                }
                return .array(MLArray())
            }), isConstant: true)
        }
        for name in ["HashMap", "LinkedHashMap", "TreeMap", "Map", "Hashtable"] {
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
        environment.define("StringBuffer", .function(.native("StringBuffer", 0...1) { context in
            let object = MLObject(typeName: "StringBuilder")
            object.fields[.string("value")] = .string(context.optionalArgument(0)?.asString ?? "")
            return .object(object)
        }), isConstant: true)
        environment.define("Scanner", .function(.native("Scanner", 0...1) { _ in
            .object(MLObject(typeName: "Scanner"))
        }), isConstant: true)

        // `new int[10]` の受け皿。
        environment.define("#newArray", .function(.native("#newArray", 2) { context in
            let count = Int(try context.requireInt(0, "new"))
            let typeName = context.argument(1).asString ?? ""
            let element = semantics.defaultValue(forTypeName: typeName)
            return .array(MLArray(Array(repeating: element, count: Swift.max(0, count))))
        }), isConstant: true)

        // 例外クラス。
        for name in ["Exception", "RuntimeException", "IllegalArgumentException",
                     "IllegalStateException", "ArithmeticException", "NullPointerException",
                     "IndexOutOfBoundsException", "ArrayIndexOutOfBoundsException",
                     "NumberFormatException", "UnsupportedOperationException", "Error",
                     "Throwable", "IOException"] {
            environment.define(name, .function(.native(name, 0...2) { context in
                .object(exception(name, context.optionalArgument(0)?.asString ?? ""))
            }), isConstant: true)
        }
    }

    // MARK: 名前空間を持つ小さなオブジェクト

    /// フィールドに組み込み関数を並べただけの入れ物を作る。
    static func namespace(_ typeName: String,
                          _ entries: [(String, MLValue)]) -> MLObject {
        let object = MLObject(typeName: typeName)
        for (name, value) in entries { object.fields[.string(name)] = value }
        return object
    }

    static func function(_ name: String, _ arity: ClosedRange<Int>,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity, impl))
    }

    static func function(_ name: String, _ arity: Int,
                         _ impl: @escaping MLFunction.MLNativeImpl) -> MLValue {
        .function(.native(name, arity...arity, impl))
    }

    // MARK: System

    static func makeSystem(interpreter: MLInterpreter, semantics: JavaSemantics) -> MLObject {
        let out = namespace("PrintStream", [
            ("println", function("println", 0...1) { context in
                let text = context.optionalArgument(0).map { semantics.display($0) } ?? ""
                context.interpreter.write(text + "\n")
                return .unit
            }),
            ("print", function("print", 0...1) { context in
                let text = context.optionalArgument(0).map { semantics.display($0) } ?? ""
                context.interpreter.write(text)
                return .unit
            }),
            ("printf", function("printf", 1...32) { context in
                let pattern = try context.requireString(0, "printf")
                var rest = Array(context.arguments.dropFirst())
                // `printf(fmt, args)` で配列 1 つを渡す書き方にも対応する。
                if rest.count == 1, let array = rest[0].asArray { rest = array.elements }
                context.interpreter.write(try MLStdlib.format(pattern, arguments: rest,
                                                              semantics: semantics))
                return .unit
            }),
            ("flush", function("flush", 0...0) { _ in .unit })
        ])
        let err = namespace("PrintStream", [
            ("println", function("println", 0...1) { context in
                let text = context.optionalArgument(0).map { semantics.display($0) } ?? ""
                context.interpreter.write(text + "\n")
                return .unit
            }),
            ("print", function("print", 0...1) { context in
                context.interpreter.write(context.optionalArgument(0)
                    .map { semantics.display($0) } ?? "")
                return .unit
            })
        ])
        return namespace("System", [
            ("out", .object(out)),
            ("err", .object(err)),
            ("in", .object(namespace("InputStream", []))),
            ("exit", function("exit", 0...1) { context in
                throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
            }),
            ("currentTimeMillis", function("currentTimeMillis", 0...0) { _ in
                .int(Int64(Date().timeIntervalSince1970 * 1000))
            }),
            ("nanoTime", function("nanoTime", 0...0) { _ in
                .int(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
            }),
            ("lineSeparator", function("lineSeparator", 0...0) { _ in .string("\n") }),
            ("arraycopy", function("arraycopy", 5) { context in
                guard let source = context.argument(0).asArray,
                      let destination = context.argument(2).asArray else { return .unit }
                let from = Int(context.argument(1).asInt ?? 0)
                let to = Int(context.argument(3).asInt ?? 0)
                let count = Int(context.argument(4).asInt ?? 0)
                for offset in 0..<count {
                    let sourceIndex = from + offset
                    let destinationIndex = to + offset
                    guard sourceIndex < source.count else { break }
                    while destination.count <= destinationIndex {
                        destination.elements.append(.unit)
                    }
                    destination.elements[destinationIndex] = source.elements[sourceIndex]
                }
                return .unit
            })
        ])
    }

    // MARK: Math

    static func makeMath() -> MLObject {
        var entries: [(String, MLValue)] = [
            ("PI", .double(Double.pi)),
            ("E", .double(M_E)),
            ("abs", function("abs", 1) { context in
                switch context.argument(0) {
                case .int(let value): return .int(value < 0 ? -value : value)
                case .double(let value): return .double(Swift.abs(value))
                default: throw MLError.runtime("Math.abs: 数値が必要です")
                }
            }),
            ("max", function("max", 2) { context in
                try extreme(context, keepLarger: true)
            }),
            ("min", function("min", 2) { context in
                try extreme(context, keepLarger: false)
            }),
            ("pow", function("pow", 2) { context in
                .double(Foundation.pow(try context.requireDouble(0, "Math.pow"),
                                       try context.requireDouble(1, "Math.pow")))
            }),
            ("random", function("random", 0...0) { _ in .double(Double.random(in: 0..<1)) }),
            ("round", function("round", 1) { context in
                let value = try context.requireDouble(0, "Math.round")
                return .int(Int64((value).rounded(.toNearestOrAwayFromZero)))
            }),
            ("floor", function("floor", 1) { context in
                .double(Foundation.floor(try context.requireDouble(0, "Math.floor")))
            }),
            ("ceil", function("ceil", 1) { context in
                .double(Foundation.ceil(try context.requireDouble(0, "Math.ceil")))
            }),
            ("signum", function("signum", 1) { context in
                let value = try context.requireDouble(0, "Math.signum")
                return .double(value > 0 ? 1 : (value < 0 ? -1 : 0))
            }),
            ("hypot", function("hypot", 2) { context in
                .double(Foundation.hypot(try context.requireDouble(0, "Math.hypot"),
                                         try context.requireDouble(1, "Math.hypot")))
            }),
            ("atan2", function("atan2", 2) { context in
                .double(Foundation.atan2(try context.requireDouble(0, "Math.atan2"),
                                         try context.requireDouble(1, "Math.atan2")))
            }),
            ("toRadians", function("toRadians", 1) { context in
                .double(try context.requireDouble(0, "Math.toRadians") * Double.pi / 180)
            }),
            ("toDegrees", function("toDegrees", 1) { context in
                .double(try context.requireDouble(0, "Math.toDegrees") * 180 / Double.pi)
            })
        ]
        for (name, implementation) in MLStdlib.mathFunctions {
            entries.append((name, function(name, 1) { context in
                .double(implementation(try context.requireDouble(0, "Math." + name)))
            }))
        }
        return namespace("Math", entries)
    }

    static func extreme(_ context: MLCallContext, keepLarger: Bool) throws -> MLValue {
        let lhs = context.argument(0)
        let rhs = context.argument(1)
        if case .int(let left) = lhs, case .int(let right) = rhs {
            return .int(keepLarger ? Swift.max(left, right) : Swift.min(left, right))
        }
        let left = lhs.asDouble ?? 0
        let right = rhs.asDouble ?? 0
        return .double(keepLarger ? Swift.max(left, right) : Swift.min(left, right))
    }

    // MARK: ラッパー型

    static func makeInteger(semantics: JavaSemantics) -> MLObject {
        namespace("Integer", [
            ("MAX_VALUE", .int(Int64(Int32.max))),
            ("MIN_VALUE", .int(Int64(Int32.min))),
            ("parseInt", function("parseInt", 1...2) { context in
                let text = try context.requireString(0, "Integer.parseInt")
                    .trimmingCharacters(in: .whitespaces)
                let radix = Int(context.optionalArgument(1)?.asInt ?? 10)
                guard let value = Int64(text, radix: radix) else {
                    throw MLError.thrown(.object(exception("NumberFormatException",
                                                           "For input string: \"\(text)\"")))
                }
                return .int(value)
            }),
            ("valueOf", function("valueOf", 1...2) { context in
                if let text = context.argument(0).asString,
                   case .string = context.argument(0).forced {
                    guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                        throw MLError.thrown(.object(exception("NumberFormatException",
                                                               "For input string: \"\(text)\"")))
                    }
                    return .int(value)
                }
                return .int(context.argument(0).asInt ?? 0)
            }),
            ("toString", function("toString", 1...2) { context in
                let value = context.argument(0).asInt ?? 0
                if let radix = context.optionalArgument(1)?.asInt {
                    return .string(String(value, radix: Int(radix)))
                }
                return .string(String(value))
            }),
            ("toBinaryString", function("toBinaryString", 1) { context in
                .string(String(context.argument(0).asInt ?? 0, radix: 2))
            }),
            ("toHexString", function("toHexString", 1) { context in
                .string(String(context.argument(0).asInt ?? 0, radix: 16))
            }),
            ("compare", function("compare", 2) { context in
                let left = context.argument(0).asInt ?? 0
                let right = context.argument(1).asInt ?? 0
                return .int(left == right ? 0 : (left < right ? -1 : 1))
            }),
            ("max", function("max", 2) { context in try extreme(context, keepLarger: true) }),
            ("min", function("min", 2) { context in try extreme(context, keepLarger: false) })
        ])
    }

    static func makeDouble(semantics: JavaSemantics) -> MLObject {
        namespace("Double", [
            ("MAX_VALUE", .double(Double.greatestFiniteMagnitude)),
            ("MIN_VALUE", .double(Double.leastNonzeroMagnitude)),
            ("parseDouble", function("parseDouble", 1) { context in
                let text = try context.requireString(0, "Double.parseDouble")
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Double(text) else {
                    throw MLError.thrown(.object(exception("NumberFormatException",
                                                           "For input string: \"\(text)\"")))
                }
                return .double(value)
            }),
            ("valueOf", function("valueOf", 1) { context in
                .double(context.argument(0).asDouble ?? 0)
            }),
            ("toString", function("toString", 1) { context in
                .string(MLNumberFormatting.javaStyle(context.argument(0).asDouble ?? 0))
            }),
            ("compare", function("compare", 2) { context in
                let left = context.argument(0).asDouble ?? 0
                let right = context.argument(1).asDouble ?? 0
                return .int(left == right ? 0 : (left < right ? -1 : 1))
            })
        ])
    }

    static func makeBoolean() -> MLObject {
        namespace("Boolean", [
            ("TRUE", .bool(true)),
            ("FALSE", .bool(false)),
            ("parseBoolean", function("parseBoolean", 1) { context in
                .bool((context.argument(0).asString ?? "").lowercased() == "true")
            }),
            ("valueOf", function("valueOf", 1) { context in
                if let text = context.argument(0).asString {
                    return .bool(text.lowercased() == "true")
                }
                return context.argument(0)
            }),
            ("toString", function("toString", 1) { context in
                if case .bool(let flag) = context.argument(0) {
                    return .string(flag ? "true" : "false")
                }
                return .string("false")
            })
        ])
    }

    static func makeCharacter() -> MLObject {
        func characterTest(_ name: String,
                           _ test: @escaping (Character) -> Bool) -> (String, MLValue) {
            (name, function(name, 1) { context in
                guard let text = context.argument(0).asString, let character = text.first else {
                    return .bool(false)
                }
                return .bool(test(character))
            })
        }
        return namespace("Character", [
            characterTest("isDigit") { $0.isNumber },
            characterTest("isLetter") { $0.isLetter },
            characterTest("isLetterOrDigit") { $0.isLetter || $0.isNumber },
            characterTest("isUpperCase") { $0.isUppercase },
            characterTest("isLowerCase") { $0.isLowercase },
            characterTest("isWhitespace") { $0.isWhitespace },
            characterTest("isAlphabetic") { $0.isLetter },
            ("toUpperCase", function("toUpperCase", 1) { context in
                guard let text = context.argument(0).asString,
                      let character = text.uppercased().first else { return context.argument(0) }
                return .char(character)
            }),
            ("toLowerCase", function("toLowerCase", 1) { context in
                guard let text = context.argument(0).asString,
                      let character = text.lowercased().first else { return context.argument(0) }
                return .char(character)
            }),
            ("getNumericValue", function("getNumericValue", 1) { context in
                guard let text = context.argument(0).asString, let character = text.first,
                      let digit = character.wholeNumberValue else { return .int(-1) }
                return .int(Int64(digit))
            }),
            ("toString", function("toString", 1) { context in
                .string(context.argument(0).asString ?? "")
            })
        ])
    }

    static func makeStringStatics(semantics: JavaSemantics) -> MLObject {
        namespace("String", [
            ("valueOf", function("valueOf", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("join", function("join", 1...32) { context in
                let separator = try context.requireString(0, "String.join")
                var items = Array(context.arguments.dropFirst())
                if items.count == 1, let array = items[0].asArray { items = array.elements }
                return .string(items.map { semantics.display($0) }.joined(separator: separator))
            }),
            ("format", function("format", 1...32) { context in
                let pattern = try context.requireString(0, "String.format")
                var rest = Array(context.arguments.dropFirst())
                if rest.count == 1, let array = rest[0].asArray { rest = array.elements }
                return .string(try MLStdlib.format(pattern, arguments: rest,
                                                   semantics: semantics))
            })
        ])
    }

    static func makeArrays(interpreter: MLInterpreter, semantics: JavaSemantics) -> MLObject {
        namespace("Arrays", [
            ("toString", function("toString", 1) { context in
                guard let array = context.argument(0).asArray else { return .string("null") }
                return .string("[" + array.elements.map { semantics.display($0) }
                    .joined(separator: ", ") + "]")
            }),
            ("deepToString", function("deepToString", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("sort", function("sort", 1...2) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let comparator = context.optionalArgument(1)?.asFunction
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: comparator)
                return .unit
            }),
            ("asList", function("asList", 0...64) { context in
                if context.arguments.count == 1, let array = context.argument(0).asArray {
                    return .array(MLArray(array.elements))
                }
                return .array(MLArray(context.arguments))
            }),
            ("fill", function("fill", 2) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let value = context.argument(1)
                for index in 0..<array.count { array.elements[index] = value }
                return .unit
            }),
            ("copyOf", function("copyOf", 2) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let count = Int(try context.requireInt(1, "Arrays.copyOf"))
                var elements = Array(array.elements.prefix(count))
                while elements.count < count { elements.append(.int(0)) }
                return .array(MLArray(elements))
            }),
            ("copyOfRange", function("copyOfRange", 3) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let from = Int(try context.requireInt(1, "Arrays.copyOfRange"))
                let to = Int(try context.requireInt(2, "Arrays.copyOfRange"))
                let low = Swift.max(0, Swift.min(from, array.count))
                let high = Swift.max(low, Swift.min(to, array.count))
                return .array(MLArray(Array(array.elements[low..<high])))
            }),
            ("equals", function("equals", 2) { context in
                .bool(semantics.areEqual(context.argument(0), context.argument(1)))
            }),
            ("stream", function("stream", 1) { context in context.argument(0) })
        ])
    }

    static func makeCollections(interpreter: MLInterpreter) -> MLObject {
        namespace("Collections", [
            ("sort", function("sort", 1...2) { context in
                guard let array = context.argument(0).asArray else { return .unit }
                let comparator = context.optionalArgument(1)?.asFunction
                array.elements = try MLStdlib.stableSorted(array.elements,
                                                           interpreter: context.interpreter,
                                                           comparator: comparator)
                return .unit
            }),
            ("reverse", function("reverse", 1) { context in
                context.argument(0).asArray?.elements.reverse()
                return .unit
            }),
            ("shuffle", function("shuffle", 1...2) { context in
                context.argument(0).asArray?.elements.shuffle()
                return .unit
            }),
            ("max", function("max", 1) { context in
                try MLStdlib.extreme(context.argument(0).asArray?.elements ?? [],
                                     semantics: context.interpreter.semantics, smaller: false)
            }),
            ("min", function("min", 1) { context in
                try MLStdlib.extreme(context.argument(0).asArray?.elements ?? [],
                                     semantics: context.interpreter.semantics, smaller: true)
            }),
            ("emptyList", function("emptyList", 0...0) { _ in .array(MLArray()) }),
            ("unmodifiableList", function("unmodifiableList", 1) { context in
                context.argument(0)
            })
        ])
    }

    static func makeObjects(semantics: JavaSemantics) -> MLObject {
        namespace("Objects", [
            ("equals", function("equals", 2) { context in
                .bool(semantics.areEqual(context.argument(0), context.argument(1)))
            }),
            ("toString", function("toString", 1) { context in
                .string(semantics.display(context.argument(0)))
            }),
            ("isNull", function("isNull", 1) { context in .bool(context.argument(0).isUnit) }),
            ("nonNull", function("nonNull", 1) { context in .bool(!context.argument(0).isUnit) }),
            ("hash", function("hash", 0...32) { context in
                var value: Int64 = 17
                for argument in context.arguments {
                    value = value &* 31 &+ Int64(semantics.display(argument).hashValue &
                                                 0x7fffffff)
                }
                return .int(value)
            })
        ])
    }

    /// Java の例外の継承関係 (`catch (Exception e)` で拾えるようにするため)。
    static let exceptionAncestors: [String: [String]] = [
        "Throwable": ["Throwable"],
        "Error": ["Error", "Throwable"],
        "Exception": ["Exception", "Throwable"],
        "IOException": ["IOException", "Exception", "Throwable"],
        "RuntimeException": ["RuntimeException", "Exception", "Throwable"],
        "IllegalArgumentException": ["IllegalArgumentException", "RuntimeException",
                                     "Exception", "Throwable"],
        "NumberFormatException": ["NumberFormatException", "IllegalArgumentException",
                                  "RuntimeException", "Exception", "Throwable"],
        "IllegalStateException": ["IllegalStateException", "RuntimeException",
                                  "Exception", "Throwable"],
        "ArithmeticException": ["ArithmeticException", "RuntimeException",
                                "Exception", "Throwable"],
        "NullPointerException": ["NullPointerException", "RuntimeException",
                                 "Exception", "Throwable"],
        "IndexOutOfBoundsException": ["IndexOutOfBoundsException", "RuntimeException",
                                      "Exception", "Throwable"],
        "ArrayIndexOutOfBoundsException": ["ArrayIndexOutOfBoundsException",
                                           "IndexOutOfBoundsException", "RuntimeException",
                                           "Exception", "Throwable"],
        "StringIndexOutOfBoundsException": ["StringIndexOutOfBoundsException",
                                            "IndexOutOfBoundsException", "RuntimeException",
                                            "Exception", "Throwable"],
        "UnsupportedOperationException": ["UnsupportedOperationException",
                                         "RuntimeException", "Exception", "Throwable"],
        "NoSuchElementException": ["NoSuchElementException", "RuntimeException",
                                   "Exception", "Throwable"],
        "EmptyStackException": ["EmptyStackException", "RuntimeException",
                                "Exception", "Throwable"]
    ]

    static func exception(_ typeName: String, _ message: String) -> MLObject {
        let object = MLObject(typeName: typeName)
        object.fields[.string("message")] = .string(message)
        let ancestors = exceptionAncestors[typeName] ?? [typeName, "Exception", "Throwable"]
        object.fields[.string("#types")] = .array(MLArray(ancestors.map { .string($0) }))
        return object
    }

    // MARK: インスタンスメソッド

    /// Java らしい名前のメソッドを追加で用意する。
    static func method(on receiver: MLValue, name: String, context: MLCallContext,
                       semantics: JavaSemantics) throws -> MLValue? {
        // StringBuilder
        if let object = receiver.asObject, object.typeName == "StringBuilder" {
            let current = object.fields[.string("value")]?.asString ?? ""
            switch name {
            case "append":
                object.fields[.string("value")] =
                    .string(current + semantics.display(context.argument(0)))
                return receiver
            case "insert":
                let position = Int(try context.requireInt(0, "insert"))
                var characters = Array(current)
                let inserted = Array(semantics.display(context.argument(1)))
                let clamped = Swift.max(0, Swift.min(position, characters.count))
                characters.insert(contentsOf: inserted, at: clamped)
                object.fields[.string("value")] = .string(String(characters))
                return receiver
            case "toString": return .string(current)
            case "length": return .int(Int64(current.count))
            case "reverse":
                object.fields[.string("value")] = .string(String(current.reversed()))
                return receiver
            case "charAt":
                let position = Int(try context.requireInt(0, "charAt"))
                let characters = Array(current)
                guard position >= 0, position < characters.count else {
                    throw MLError.thrown(.object(exception("IndexOutOfBoundsException",
                                                           "index \(position)")))
                }
                return .char(characters[position])
            case "setLength":
                let count = Int(try context.requireInt(0, "setLength"))
                object.fields[.string("value")] = .string(String(current.prefix(count)))
                return .unit
            case "deleteCharAt":
                var characters = Array(current)
                let position = Int(try context.requireInt(0, "deleteCharAt"))
                guard position >= 0, position < characters.count else {
                    throw MLError.thrown(.object(exception("IndexOutOfBoundsException",
                                                           "index \(position)")))
                }
                characters.remove(at: position)
                object.fields[.string("value")] = .string(String(characters))
                return receiver
            case "isEmpty": return .bool(current.isEmpty)
            default:
                // 残りは文字列のメソッドとして解釈する。
                return try MLStdlib.callMethod(on: .string(current), name: name,
                                               context: context)
            }
        }

        // Scanner (標準入力)
        if let object = receiver.asObject, object.typeName == "Scanner" {
            switch name {
            case "nextLine": return .string(context.interpreter.input.nextLine() ?? "")
            case "nextInt":
                guard let token = nextToken(context.interpreter), let value = Int64(token) else {
                    throw MLError.thrown(.object(exception("NoSuchElementException", "")))
                }
                return .int(value)
            case "nextDouble":
                guard let token = nextToken(context.interpreter), let value = Double(token) else {
                    throw MLError.thrown(.object(exception("NoSuchElementException", "")))
                }
                return .double(value)
            case "next":
                guard let token = nextToken(context.interpreter) else {
                    throw MLError.thrown(.object(exception("NoSuchElementException", "")))
                }
                return .string(token)
            case "hasNextLine", "hasNext":
                return .bool(!context.interpreter.input.remainingText.isEmpty)
            case "close": return .unit
            default: return nil
            }
        }

        // 例外オブジェクト。
        if let object = receiver.asObject, object.fields.contains(.string("message")),
           object.classDeclaration == nil {
            switch name {
            case "getMessage", "getLocalizedMessage":
                return object.fields[.string("message")] ?? .unit
            case "toString":
                let message = object.fields[.string("message")]?.asString ?? ""
                return .string(message.isEmpty ? object.typeName
                                               : "\(object.typeName): \(message)")
            default: break
            }
        }

        switch receiver.forced {
        case .string(let text):
            return try stringMethod(text, name: name, context: context, semantics: semantics)
        case .char(let character):
            switch name {
            case "charValue": return receiver
            case "equals":
                return .bool(semantics.areEqual(receiver, context.argument(0)))
            case "compareTo":
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
            case "equals": return .bool(semantics.areEqual(receiver, context.argument(0)))
            case "compareTo":
                return .int(Int64(semantics.compare(receiver, context.argument(0)) ?? 0))
            case "intValue": return .int(receiver.asInt ?? 0)
            case "doubleValue": return .double(receiver.asDouble ?? 0)
            case "toString": return .string(semantics.display(receiver))
            case "hashCode": return .int(receiver.asInt ?? 0)
            default: return nil
            }
        default:
            return nil
        }
    }

    static func nextToken(_ interpreter: MLInterpreter) -> String? {
        var token = ""
        while let character = interpreter.input.nextCharacter() {
            if character.isWhitespace {
                if token.isEmpty { continue }
                break
            }
            token.append(character)
        }
        return token.isEmpty ? nil : token
    }

    static func stringMethod(_ text: String, name: String, context: MLCallContext,
                             semantics: JavaSemantics) throws -> MLValue? {
        let characters = Array(text)
        switch name {
        case "charAt":
            let position = Int(try context.requireInt(0, "charAt"))
            guard position >= 0, position < characters.count else {
                throw MLError.thrown(.object(
                    exception("StringIndexOutOfBoundsException",
                              "index \(position), length \(characters.count)")))
            }
            return .char(characters[position])
        case "substring":
            let from = Int(try context.requireInt(0, "substring"))
            let to = context.optionalArgument(1).flatMap { $0.asInt }
                .map { Int($0) } ?? characters.count
            guard from >= 0, to <= characters.count, from <= to else {
                throw MLError.thrown(.object(
                    exception("StringIndexOutOfBoundsException", "begin \(from), end \(to)")))
            }
            return .string(String(characters[from..<to]))
        case "equals":
            return .bool(context.argument(0).asString == text)
        case "compareTo":
            guard let other = context.argument(0).asString else { return .int(0) }
            return .int(Int64(compareJavaStrings(text, other)))
        case "isBlank":
            return .bool(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case "matches":
            // 単純な部分一致に落とす (正規表現の完全実装はしていない)。
            guard let pattern = context.argument(0).asString else { return .bool(false) }
            return .bool(text == pattern)
        case "toString", "intern": return .string(text)
        case "hashCode":
            var hash: Int32 = 0
            for scalar in text.unicodeScalars {
                hash = hash &* 31 &+ Int32(truncatingIfNeeded: Int(scalar.value))
            }
            return .int(Int64(hash))
        case "concat":
            return .string(text + (context.argument(0).asString ?? ""))
        case "split":
            guard let separator = context.argument(0).asString else {
                return .array(MLArray([.string(text)]))
            }
            var parts = separator.isEmpty ? characters.map { String($0) }
                                          : text.components(separatedBy: separator)
            // Java は末尾の空文字列を落とす。
            while parts.count > 1, parts.last == "" { parts.removeLast() }
            return .array(MLArray(parts.map { .string($0) }))
        case "chars":
            return .array(MLArray(text.unicodeScalars.map { .int(Int64($0.value)) }))
        case "strip": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "format":
            let pattern = text
            return .string(try MLStdlib.format(pattern, arguments: context.arguments,
                                               semantics: semantics))
        default:
            return try MLStdlib.callMethod(on: .string(text), name: name, context: context)
        }
    }

    /// Java の `String.compareTo` は UTF-16 単位の差を返す。
    static func compareJavaStrings(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for index in 0..<Swift.min(left.count, right.count) where left[index] != right[index] {
            return Int(left[index]) - Int(right[index])
        }
        return left.count - right.count
    }

    static func listMethod(_ array: MLArray, name: String, context: MLCallContext,
                           semantics: JavaSemantics) throws -> MLValue? {
        switch name {
        case "get":
            let position = Int(try context.requireInt(0, "get"))
            guard position >= 0, position < array.count else {
                throw MLError.thrown(.object(
                    exception("IndexOutOfBoundsException",
                              "Index \(position) out of bounds for length \(array.count)")))
            }
            return array.elements[position]
        case "set":
            let position = Int(try context.requireInt(0, "set"))
            guard position >= 0, position < array.count else {
                throw MLError.thrown(.object(
                    exception("IndexOutOfBoundsException",
                              "Index \(position) out of bounds for length \(array.count)")))
            }
            let previous = array.elements[position]
            array.elements[position] = context.argument(1)
            return previous
        case "add":
            if context.arguments.count == 2, let position = context.argument(0).asInt {
                let clamped = Swift.max(0, Swift.min(Int(position), array.count))
                array.elements.insert(context.argument(1), at: clamped)
                return .unit
            }
            array.elements.append(context.argument(0))
            return .bool(true)
        case "addAll":
            guard let other = context.argument(0).asArray else { return .bool(false) }
            array.elements.append(contentsOf: other.elements)
            return .bool(true)
        case "remove":
            if case .int(let position) = context.argument(0) {
                guard position >= 0, Int(position) < array.count else {
                    throw MLError.thrown(.object(
                        exception("IndexOutOfBoundsException", "Index \(position)")))
                }
                return array.elements.remove(at: Int(position))
            }
            let target = context.argument(0)
            if let found = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                array.elements.remove(at: found)
                return .bool(true)
            }
            return .bool(false)
        case "size": return .int(Int64(array.count))
        case "toString":
            return .string("[" + array.elements.map { semantics.display($0) }
                .joined(separator: ", ") + "]")
        case "equals":
            return .bool(semantics.areEqual(.array(array), context.argument(0)))
        case "stream", "parallelStream", "collect", "boxed": return .array(array)
        case "push":
            array.elements.append(context.argument(0))
            return context.argument(0)
        case "pop":
            guard let last = array.elements.popLast() else {
                throw MLError.thrown(.object(exception("EmptyStackException", "")))
            }
            return last
        case "peek": return array.elements.last ?? .unit
        case "poll", "removeFirst":
            guard !array.elements.isEmpty else { return .unit }
            return array.elements.removeFirst()
        case "offer", "addLast":
            array.elements.append(context.argument(0))
            return .bool(true)
        case "sort":
            let comparator = context.optionalArgument(0)?.asFunction
            array.elements = try MLStdlib.stableSorted(array.elements,
                                                       interpreter: context.interpreter,
                                                       comparator: comparator)
            return .unit
        default:
            return nil
        }
    }

    static func mapMethod(_ map: MLMap, name: String, context: MLCallContext,
                          semantics: JavaSemantics) throws -> MLValue? {
        switch name {
        case "put":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            let previous = map[key]
            map[key] = context.argument(1)
            return previous ?? .unit
        case "get":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            return map[key] ?? .unit
        case "size": return .int(Int64(map.count))
        case "toString":
            return .string("{" + map.pairs.map {
                "\(semantics.display($0.key.asValue))=\(semantics.display($0.value))"
            }.joined(separator: ", ") + "}")
        case "putIfAbsent":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            if let existing = map[key] { return existing }
            map[key] = context.argument(1)
            return .unit
        case "computeIfAbsent":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            if let existing = map[key] { return existing }
            let producer = try context.requireFunction(1, "computeIfAbsent")
            let value = try context.interpreter.callFunction(producer,
                                                             arguments: [context.argument(0)])
            map[key] = value
            return value
        case "merge":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            let value = context.argument(1)
            if let existing = map[key] {
                let combine = try context.requireFunction(2, "merge")
                let merged = try context.interpreter.callFunction(combine,
                                                                  arguments: [existing, value])
                map[key] = merged
                return merged
            }
            map[key] = value
            return value
        case "keySet": return .array(MLArray(map.keys.map { $0.asValue }))
        case "entrySet":
            return .array(MLArray(map.pairs.map { pair in
                let entry = MLObject(typeName: "MapEntry")
                entry.fields[.string("key")] = pair.key.asValue
                entry.fields[.string("value")] = pair.value
                return .object(entry)
            }))
        default:
            return nil
        }
    }
}
