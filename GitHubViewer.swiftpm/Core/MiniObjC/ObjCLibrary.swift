import Foundation

/// Objective-C らしい振る舞い。
final class ObjCSemantics: MLSemantics {
    override var languageID: String { "objectivec" }
    override var displayName: String { "内蔵 Objective-C 処理系" }
    override var integerDivisionTruncatesTowardZero: Bool { true }

    override func isTruthy(_ value: MLValue) throws -> Bool {
        switch value.forced {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .double(let number): return number != 0
        case .unit: return false
        default: return true
        }
    }

    override func typeName(of value: MLValue) -> String {
        switch value.forced {
        case .unit: return "nil"
        case .bool: return "BOOL"
        case .int: return "NSInteger"
        case .double: return "double"
        case .string, .char: return "NSString"
        case .array: return "NSArray"
        case .map: return "NSDictionary"
        case .object(let object): return object.typeName
        default: return MLDisplay.plain(value)
        }
    }

    override func formatDouble(_ value: Double) -> String {
        // `%f` 相当の既定表示。
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return String(format: "%g", value)
    }

    override func display(_ value: MLValue) -> String {
        switch value.forced {
        case .unit: return "(null)"
        case .bool(let flag): return flag ? "1" : "0"
        case .int(let number): return String(number)
        case .double(let number): return formatDouble(number)
        case .string(let text): return text
        case .char(let character): return String(character)
        case .array(let array):
            // NSArray の description は 1 要素ずつ字下げして書く。
            if array.elements.isEmpty { return "(\n)" }
            let items = array.elements.map { "    " + display($0) }
            return "(\n" + items.joined(separator: ",\n") + "\n)"
        case .map(let map):
            if map.isEmpty { return "{\n}" }
            let items = map.pairs.map { "    \(display($0.key.asValue)) = \(display($0.value));" }
            return "{\n" + items.joined(separator: "\n") + "\n}"
        case .object(let object):
            if let interpreter = toStringInterpreter,
               object.classDeclaration?.findMethod("description") != nil,
               let result = try? interpreter.callMethod(on: value, name: "description",
                                                        arguments: [], location: .unknown),
               let text = result.asString {
                return text
            }
            return "<\(object.typeName): 0x"
                + String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xffffffff,
                         radix: 16) + ">"
        default:
            return MLDisplay.plain(value, semantics: self)
        }
    }

    private var toStringInterpreter: MLInterpreter?

    override func stringify(_ value: MLValue) -> String { display(value) }

    override func defaultValue(forTypeName typeName: String?) -> MLValue {
        guard let typeName else { return .unit }
        let base = MLInterpreter.baseTypeName(typeName)
        if typeName.hasPrefix("Array") { return .array(MLArray()) }
        switch base {
        case "int", "long", "short", "NSInteger", "NSUInteger", "char", "unsigned",
             "size_t":
            return .int(0)
        case "double", "float", "CGFloat": return .double(0)
        case "BOOL": return .bool(false)
        default: return .unit
        }
    }

    override func coerce(_ value: MLValue, toTypeName typeName: String?) -> MLValue {
        guard let typeName else { return value }
        if ["double", "float", "CGFloat"].contains(typeName),
           case .int(let number) = value.forced {
            return .double(Double(number))
        }
        return value
    }

    override func customBinary(op: String, lhs: MLValue, rhs: MLValue,
                               interpreter: MLInterpreter) throws -> MLValue? {
        toStringInterpreter = interpreter
        if op == "+", case .string(let left) = lhs.forced {
            return .string(left + display(rhs))
        }
        if "+-*/%".contains(op), op.count == 1 {
            if case .char(let left) = lhs.forced, rhs.isNumeric {
                let number = Int64(left.unicodeScalars.first?.value ?? 0)
                return try MLOperations.arithmetic(op: op, lhs: .int(number), rhs: rhs,
                                                   semantics: self)
            }
        }
        return nil
    }

    override func installBuiltins(into environment: MLEnvironment, interpreter: MLInterpreter) {
        toStringInterpreter = interpreter
        ObjCLibrary.install(into: environment, semantics: self)
    }

    override func member(of value: MLValue, name: String,
                         interpreter: MLInterpreter) throws -> MLValue? {
        nil
    }

    override func callMember(of value: MLValue, name: String, arguments: [MLValue],
                             context: MLCallContext) throws -> MLValue? {
        try ObjCLibrary.message(to: value, selector: name, context: context,
                                semantics: self)
    }
}

/// Foundation のよく使うクラスを Swift で用意する。
enum ObjCLibrary {

    static func install(into environment: MLEnvironment, semantics: ObjCSemantics) {
        environment.define("NSLog", .function(.native("NSLog", 1...16) { context in
            let pattern = try context.requireString(0, "NSLog")
            let text = try MLStdlib.format(pattern,
                                           arguments: Array(context.arguments.dropFirst()),
                                           semantics: semantics)
            context.interpreter.write(text + "\n")
            return .unit
        }), isConstant: true)
        environment.define("printf", .function(.native("printf", 1...16) { context in
            let pattern = try context.requireString(0, "printf")
            context.interpreter.write(try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics))
            return .unit
        }), isConstant: true)
        environment.define("puts", .function(.native("puts", 1) { context in
            context.interpreter.write(semantics.display(context.argument(0)) + "\n")
            return .unit
        }), isConstant: true)
        environment.define("#newArray", .function(.native("#newArray", 2) { context in
            let count = Int(try context.requireInt(0, "配列の生成"))
            let element = semantics.defaultValue(forTypeName: context.argument(1).asString ?? "")
            return .array(MLArray(Array(repeating: element, count: Swift.max(0, count))))
        }), isConstant: true)

        // クラスは「メッセージを受け取る目印」として置いておく。
        for name in ["NSObject", "NSString", "NSMutableString", "NSArray",
                     "NSMutableArray", "NSDictionary", "NSMutableDictionary",
                     "NSNumber", "NSSet", "NSMutableSet", "NSException"] {
            let token = MLObject(typeName: name)
            token.attachment = .symbol("#objcClass")
            environment.define(name, .object(token), isConstant: true)
        }

        for (name, implementation) in MLStdlib.mathFunctions {
            environment.define(name, .function(.native(name, 1) { context in
                .double(implementation(try context.requireDouble(0, name)))
            }), isConstant: true)
        }
        environment.define("pow", .function(.native("pow", 2) { context in
            .double(Foundation.pow(try context.requireDouble(0, "pow"),
                                   try context.requireDouble(1, "pow")))
        }), isConstant: true)
        environment.define("abs", .function(.native("abs", 1) { context in
            switch context.argument(0) {
            case .int(let value): return .int(value < 0 ? -value : value)
            default: return .double(Swift.abs(context.argument(0).asDouble ?? 0))
            }
        }), isConstant: true)
        environment.define("exit", .function(.native("exit", 0...1) { context in
            throw MLError.exit(Int32(truncatingIfNeeded: context.argument(0).asInt ?? 0))
        }), isConstant: true)
    }

    /// 組み込みクラスへのメッセージかどうか。
    static func builtinClassName(_ value: MLValue) -> String? {
        guard let object = value.asObject, case .symbol("#objcClass")? = object.attachment
        else { return nil }
        return object.typeName
    }

    /// メッセージ送信の本体。
    static func message(to receiver: MLValue, selector: String, context: MLCallContext,
                        semantics: ObjCSemantics) throws -> MLValue? {
        let interpreter = context.interpreter

        // クラスメッセージ (`[NSString stringWithFormat:...]` など)。
        if let className = builtinClassName(receiver) {
            return try classMessage(className, selector: selector, context: context,
                                    semantics: semantics)
        }

        // `alloc` / `init` / `new` / `retain` などの決まり文句。
        switch selector {
        case "alloc", "new", "retain", "autorelease", "copy", "mutableCopy", "self":
            if selector == "copy" || selector == "mutableCopy" {
                return receiver.deepCopy()
            }
            if let klass = interpreter.isClassToken(receiver) {
                return try interpreter.instantiate(klass, arguments: [], labels: [],
                                                   location: context.location)
            }
            return receiver
        case "release": return .unit
        case "description":
            return .string(semantics.display(receiver))
        case "isEqual:", "isEqualToString:", "isEqualToNumber:":
            return .bool(semantics.areEqual(receiver, context.argument(0)))
        case "class": return .string(semantics.typeName(of: receiver))
        case "hash": return .int(Int64(semantics.display(receiver).hashValue & 0x7fffffff))
        default:
            break
        }

        switch receiver.forced {
        case .string(let text):
            return try stringMessage(text, selector: selector, context: context,
                                     semantics: semantics)
        case .array(let array):
            return try arrayMessage(array, selector: selector, context: context,
                                    semantics: semantics)
        case .map(let map):
            return try dictionaryMessage(map, selector: selector, context: context,
                                         semantics: semantics)
        case .int, .double, .bool:
            switch selector {
            case "intValue", "integerValue", "longValue":
                return .int(receiver.asInt ?? Int64(receiver.asDouble ?? 0))
            case "doubleValue", "floatValue": return .double(receiver.asDouble ?? 0)
            case "boolValue": return .bool(try semantics.isTruthy(receiver))
            case "stringValue": return .string(semantics.display(receiver))
            case "compare:":
                return .int(Int64(semantics.compare(receiver, context.argument(0)) ?? 0))
            default: return nil
            }
        default:
            return nil
        }
    }

    static func classMessage(_ className: String, selector: String,
                             context: MLCallContext,
                             semantics: ObjCSemantics) throws -> MLValue? {
        switch className {
        case "NSString", "NSMutableString":
            switch selector {
            case "alloc", "new", "string": return .string("")
            case "stringWithFormat:":
                let pattern = try context.requireString(0, "stringWithFormat:")
                return .string(try MLStdlib.format(
                    pattern, arguments: Array(context.arguments.dropFirst()),
                    semantics: semantics))
            case "stringWithString:", "stringWithUTF8String:":
                return .string(semantics.display(context.argument(0)))
            default: return nil
            }
        case "NSArray", "NSMutableArray":
            switch selector {
            case "alloc", "new", "array": return .array(MLArray())
            case "arrayWithObjects:", "arrayWithArray:":
                if context.arguments.count == 1, let array = context.argument(0).asArray {
                    return .array(MLArray(array.elements))
                }
                // 末尾の nil は番兵なので落とす。
                let items = context.arguments.filter { !$0.isUnit }
                return .array(MLArray(items))
            case "arrayWithObject:":
                return .array(MLArray([context.argument(0)]))
            case "arrayWithCapacity:": return .array(MLArray())
            default: return nil
            }
        case "NSDictionary", "NSMutableDictionary":
            switch selector {
            case "alloc", "new", "dictionary", "dictionaryWithCapacity:":
                return .map(MLMap())
            case "dictionaryWithObjectsAndKeys:":
                let map = MLMap()
                var index = 0
                while index + 1 < context.arguments.count {
                    let value = context.arguments[index]
                    if value.isUnit { break }
                    if let key = MLKey.from(context.arguments[index + 1]) {
                        map[key] = value
                    }
                    index += 2
                }
                return .map(map)
            default: return nil
            }
        case "NSNumber":
            switch selector {
            case "numberWithInt:", "numberWithInteger:", "numberWithLong:":
                return .int(context.argument(0).asInt ?? 0)
            case "numberWithDouble:", "numberWithFloat:":
                return .double(context.argument(0).asDouble ?? 0)
            case "numberWithBool:": return context.argument(0)
            default: return nil
            }
        case "NSException":
            switch selector {
            case "exceptionWithName:reason:userInfo:", "raise:format:":
                let object = MLObject(typeName: "NSException")
                object.fields[.string("name")] = context.argument(0)
                object.fields[.string("reason")] = context.optionalArgument(1) ?? .string("")
                object.fields[.string("#types")] =
                    .array(MLArray([.string("NSException"), .string("NSObject")]))
                return .object(object)
            default: return nil
            }
        case "NSObject":
            if selector == "alloc" || selector == "new" {
                return .object(MLObject(typeName: "NSObject"))
            }
            return nil
        default:
            return nil
        }
    }

    static func stringMessage(_ text: String, selector: String, context: MLCallContext,
                              semantics: ObjCSemantics) throws -> MLValue? {
        let characters = Array(text)
        switch selector {
        case "length": return .int(Int64(characters.count))
        case "uppercaseString": return .string(text.uppercased())
        case "lowercaseString": return .string(text.lowercased())
        case "capitalizedString":
            return .string(text.split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " "))
        case "stringByAppendingString:":
            return .string(text + semantics.display(context.argument(0)))
        case "stringByAppendingFormat:":
            let pattern = try context.requireString(0, "stringByAppendingFormat:")
            return .string(text + (try MLStdlib.format(
                pattern, arguments: Array(context.arguments.dropFirst()),
                semantics: semantics)))
        case "substringFromIndex:":
            let start = Int(try context.requireInt(0, "substringFromIndex:"))
            guard start >= 0, start <= characters.count else {
                throw MLError.runtime("substringFromIndex: 範囲外です")
            }
            return .string(String(characters[start...]))
        case "substringToIndex:":
            let end = Int(try context.requireInt(0, "substringToIndex:"))
            guard end >= 0, end <= characters.count else {
                throw MLError.runtime("substringToIndex: 範囲外です")
            }
            return .string(String(characters[..<end]))
        case "characterAtIndex:":
            let position = Int(try context.requireInt(0, "characterAtIndex:"))
            guard position >= 0, position < characters.count else {
                throw MLError.runtime("characterAtIndex: 範囲外です")
            }
            return .int(Int64(characters[position].unicodeScalars.first?.value ?? 0))
        case "componentsSeparatedByString:":
            let separator = try context.requireString(0, "componentsSeparatedByString:")
            let parts = separator.isEmpty ? characters.map { String($0) }
                                          : text.components(separatedBy: separator)
            return .array(MLArray(parts.map { .string($0) }))
        case "stringByReplacingOccurrencesOfString:withString:":
            return .string(text.replacingOccurrences(
                of: context.argument(0).asString ?? "",
                with: context.argument(1).asString ?? ""))
        case "hasPrefix:": return .bool(text.hasPrefix(context.argument(0).asString ?? ""))
        case "hasSuffix:": return .bool(text.hasSuffix(context.argument(0).asString ?? ""))
        case "containsString:":
            guard let needle = context.argument(0).asString else { return .bool(false) }
            return .bool(needle.isEmpty || text.contains(needle))
        case "intValue", "integerValue":
            return .int(Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0)
        case "doubleValue", "floatValue":
            return .double(Double(text.trimmingCharacters(in: .whitespaces)) ?? 0)
        case "UTF8String", "description": return .string(text)
        case "compare:":
            return .int(Int64(semantics.compare(.string(text), context.argument(0)) ?? 0))
        case "stringByTrimmingCharactersInSet:":
            return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            // セレクタの `:` を落として共通ライブラリに回す。
            return try MLStdlib.callMethod(on: .string(text),
                                           name: selector.replacingOccurrences(of: ":",
                                                                               with: ""),
                                           context: context)
        }
    }

    static func arrayMessage(_ array: MLArray, selector: String, context: MLCallContext,
                             semantics: ObjCSemantics) throws -> MLValue? {
        switch selector {
        case "count": return .int(Int64(array.count))
        case "objectAtIndex:":
            let position = Int(try context.requireInt(0, "objectAtIndex:"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("objectAtIndex: 範囲外です (要素数 \(array.count))")
            }
            return array.elements[position]
        case "firstObject": return array.elements.first ?? .unit
        case "lastObject": return array.elements.last ?? .unit
        case "addObject:":
            array.elements.append(context.argument(0))
            return .unit
        case "addObjectsFromArray:":
            if let other = context.argument(0).asArray {
                array.elements.append(contentsOf: other.elements)
            }
            return .unit
        case "insertObject:atIndex:":
            let position = Int(try context.requireInt(1, "insertObject:atIndex:"))
            let clamped = Swift.max(0, Swift.min(position, array.count))
            array.elements.insert(context.argument(0), at: clamped)
            return .unit
        case "removeObjectAtIndex:":
            let position = Int(try context.requireInt(0, "removeObjectAtIndex:"))
            guard position >= 0, position < array.count else {
                throw MLError.runtime("removeObjectAtIndex: 範囲外です")
            }
            array.elements.remove(at: position)
            return .unit
        case "removeLastObject":
            _ = array.elements.popLast()
            return .unit
        case "removeAllObjects":
            array.elements.removeAll()
            return .unit
        case "containsObject:":
            let target = context.argument(0)
            return .bool(array.elements.contains { semantics.areEqual($0, target) })
        case "indexOfObject:":
            let target = context.argument(0)
            if let found = array.elements.firstIndex(where: { semantics.areEqual($0, target) }) {
                return .int(Int64(found))
            }
            return .int(Int64(Int32.max))   // NSNotFound の代わり
        case "componentsJoinedByString:":
            let separator = try context.requireString(0, "componentsJoinedByString:")
            return .string(array.elements.map { semantics.display($0) }
                .joined(separator: separator))
        case "sortedArrayUsingSelector:", "sortedArrayUsingComparator:":
            let sorted = try MLStdlib.stableSorted(
                array.elements, interpreter: context.interpreter,
                comparator: context.optionalArgument(0)?.asFunction)
            return .array(MLArray(sorted))
        case "sortUsingComparator:", "sortUsingSelector:":
            array.elements = try MLStdlib.stableSorted(
                array.elements, interpreter: context.interpreter,
                comparator: context.optionalArgument(0)?.asFunction)
            return .unit
        case "reverseObjectEnumerator":
            return .array(MLArray(array.elements.reversed()))
        case "description":
            return .string(semantics.display(.array(array)))
        default:
            return try MLStdlib.callMethod(on: .array(array),
                                           name: selector.replacingOccurrences(of: ":",
                                                                               with: ""),
                                           context: context)
        }
    }

    static func dictionaryMessage(_ map: MLMap, selector: String, context: MLCallContext,
                                  semantics: ObjCSemantics) throws -> MLValue? {
        switch selector {
        case "count": return .int(Int64(map.count))
        case "objectForKey:", "valueForKey:":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            return map[key] ?? .unit
        case "setObject:forKey:":
            guard let key = MLKey.from(context.argument(1)) else { return .unit }
            map[key] = context.argument(0)
            return .unit
        case "setValue:forKey:":
            guard let key = MLKey.from(context.argument(1)) else { return .unit }
            map[key] = context.argument(0)
            return .unit
        case "removeObjectForKey:":
            guard let key = MLKey.from(context.argument(0)) else { return .unit }
            _ = map.removeValue(forKey: key)
            return .unit
        case "allKeys": return .array(MLArray(map.keys.map { $0.asValue }))
        case "allValues": return .array(MLArray(map.values))
        case "description": return .string(semantics.display(.map(map)))
        default:
            return try MLStdlib.callMethod(on: .map(map),
                                           name: selector.replacingOccurrences(of: ":",
                                                                               with: ""),
                                           context: context)
        }
    }
}
