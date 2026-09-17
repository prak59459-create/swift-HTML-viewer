import Foundation

/// sprintf / var_dump / print_r / json_encode の書式。
enum PHPFormatter {
    // MARK: - sprintf

    static func format(_ format: String, _ arguments: [PHPValue]) -> String {
        var output = ""
        let characters = Array(format)
        var index = 0
        var argumentIndex = 0

        while index < characters.count {
            guard characters[index] == "%" else {
                output.append(characters[index])
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { break }
            if characters[index] == "%" {
                output.append("%")
                index += 1
                continue
            }

            // 位置指定 (%1$s)
            var explicitPosition: Int?
            var lookahead = index
            var digits = ""
            while lookahead < characters.count, characters[lookahead].isNumber {
                digits.append(characters[lookahead])
                lookahead += 1
            }
            if lookahead < characters.count, characters[lookahead] == "$", !digits.isEmpty {
                explicitPosition = Int(digits)! - 1
                index = lookahead + 1
            }

            var leftAlign = false
            var padCharacter: Character = " "
            var forceSign = false
            loop: while index < characters.count {
                switch characters[index] {
                case "-": leftAlign = true
                case "+": forceSign = true
                case "0": padCharacter = "0"
                case " ": padCharacter = " "
                case "'":
                    index += 1
                    if index < characters.count { padCharacter = characters[index] }
                default: break loop
                }
                index += 1
            }

            var width = 0
            while index < characters.count, characters[index].isNumber {
                width = width * 10 + Int(String(characters[index]))!
                index += 1
            }

            var precision: Int?
            if index < characters.count, characters[index] == "." {
                index += 1
                var value = 0
                while index < characters.count, characters[index].isNumber {
                    value = value * 10 + Int(String(characters[index]))!
                    index += 1
                }
                precision = value
            }

            guard index < characters.count else { break }
            let conversion = characters[index]
            index += 1

            let position = explicitPosition ?? argumentIndex
            if explicitPosition == nil { argumentIndex += 1 }
            let value = position < arguments.count ? arguments[position] : .null

            var text: String
            switch conversion {
            case "d", "i":
                let number = value.asInt
                text = String(number)
                if forceSign, number >= 0 { text = "+" + text }
            case "u":
                text = String(UInt64(bitPattern: value.asInt))
            case "f", "F":
                text = String(format: "%.\(precision ?? 6)f", value.asDouble)
                if forceSign, value.asDouble >= 0 { text = "+" + text }
            case "e", "E":
                text = String(format: "%.\(precision ?? 6)\(conversion == "e" ? "e" : "E")", value.asDouble)
                // PHP は指数部の桁を詰める (1.0e+1)
                text = text.replacingOccurrences(of: "e+0", with: "e+")
                    .replacingOccurrences(of: "e-0", with: "e-")
                    .replacingOccurrences(of: "E+0", with: "E+")
                    .replacingOccurrences(of: "E-0", with: "E-")
            case "g", "G":
                text = PHPValue.format(value.asDouble)
            case "s":
                text = value.asString
                if let precision { text = String(text.prefix(precision)) }
            case "x": text = String(UInt64(bitPattern: value.asInt), radix: 16)
            case "X": text = String(UInt64(bitPattern: value.asInt), radix: 16).uppercased()
            case "o": text = String(UInt64(bitPattern: value.asInt), radix: 8)
            case "b": text = String(UInt64(bitPattern: value.asInt), radix: 2)
            case "c":
                text = String(Character(UnicodeScalar(UInt8(truncatingIfNeeded: value.asInt))))
            default:
                text = String(conversion)
            }

            if text.count < width {
                let padding = String(repeating: String(padCharacter), count: width - text.count)
                if leftAlign {
                    text += String(repeating: " ", count: width - text.count)
                } else if padCharacter == "0", text.hasPrefix("-") {
                    text = "-" + padding + text.dropFirst()
                } else {
                    text = padding + text
                }
            }
            output += text
        }
        return output
    }

    // MARK: - var_dump

    static func varDump(_ value: PHPValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return pad + "NULL\n"
        case .boolean(let flag):
            return pad + "bool(\(flag ? "true" : "false"))\n"
        case .integer(let number):
            return pad + "int(\(number))\n"
        case .number(let number):
            return pad + "float(\(shortest(number)))\n"
        case .text(let text):
            return pad + "string(\(text.utf8.count)) \"\(text)\"\n"
        case .array(let array):
            var result = pad + "array(\(array.count)) {\n"
            for key in array.keys {
                switch key {
                case .integer(let number): result += pad + "  [\(number)]=>\n"
                case .text(let name): result += pad + "  [\"\(name)\"]=>\n"
                }
                result += varDump(array[key] ?? .null, indent: indent + 2)
            }
            result += pad + "}\n"
            return result
        case .object(let object):
            var result = pad + "object(\(object.className))#1 (\(object.properties.count)) {\n"
            for key in object.properties.keys {
                result += pad + "  [\"\(key.description)\"]=>\n"
                result += varDump(object.properties[key] ?? .null, indent: indent + 2)
            }
            result += pad + "}\n"
            return result
        case .closure:
            return pad + "object(Closure)#1 (0) {\n" + pad + "}\n"
        }
    }

    /// PHP の var_dump / json_encode は、往復できる最短の表記で小数を書く。
    static func shortest(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        if value == value.rounded(), Swift.abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = "\(value)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        if text.contains("e") {
            // 1e-05 → 1.0E-5
            let parts = text.components(separatedBy: "e")
            var mantissa = parts[0]
            if !mantissa.contains(".") { mantissa += ".0" }
            var exponent = parts[1]
            let negative = exponent.hasPrefix("-")
            exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            while exponent.count > 1, exponent.hasPrefix("0") { exponent.removeFirst() }
            text = mantissa + "E" + (negative ? "-" : "+") + exponent
        }
        return text
    }

    // MARK: - print_r

    static func printR(_ value: PHPValue, indent: Int) -> String {
        switch value {
        case .array(let array):
            let pad = String(repeating: " ", count: indent)
            var result = "Array\n" + pad + "(\n"
            for key in array.keys {
                let child = array[key] ?? .null
                result += pad + "    [\(key.description)] => " + printR(child, indent: indent + 8)
                result += "\n"
            }
            result += pad + ")\n"
            return result
        case .object(let object):
            let pad = String(repeating: " ", count: indent)
            var result = "\(object.className) Object\n" + pad + "(\n"
            for key in object.properties.keys {
                let child = object.properties[key] ?? .null
                result += pad + "    [\(key.description)] => " + printR(child, indent: indent + 8)
                result += "\n"
            }
            result += pad + ")\n"
            return result
        default:
            return value.asString
        }
    }

    // MARK: - var_export

    static func varExport(_ value: PHPValue, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null: return "NULL"
        case .boolean(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .number(let number):
            let text = shortest(number)
            return text.contains(".") || text.contains("E") ? text : text + ".0"
        case .text(let text): return "'" + text.replacingOccurrences(of: "'", with: "\\'") + "'"
        case .array(let array):
            var result = "array (\n"
            for key in array.keys {
                let keyText: String
                switch key {
                case .integer(let number): keyText = String(number)
                case .text(let name): keyText = "'\(name)'"
                }
                result += pad + "  " + keyText + " => "
                let child = array[key] ?? .null
                if case .array = child {
                    result += "\n" + pad + "  " + varExport(child, indent: indent + 2)
                } else {
                    result += varExport(child, indent: indent + 2)
                }
                result += ",\n"
            }
            result += pad + ")"
            return result
        case .object(let object):
            return "\\\(object.className)::__set_state(array(\n" + pad + "))"
        case .closure:
            return "\\Closure::__set_state(array(\n" + pad + "))"
        }
    }

    // MARK: - json_encode

    static func json(_ value: PHPValue, pretty: Bool, indent: Int = 0) -> String {
        let pad = pretty ? String(repeating: "    ", count: indent + 1) : ""
        let closingPad = pretty ? String(repeating: "    ", count: indent) : ""
        let newline = pretty ? "\n" : ""
        let separator = pretty ? ": " : ":"

        switch value {
        case .null: return "null"
        case .boolean(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .number(let number):
            let text = shortest(number)
            return text.contains(".") || text.contains("E") ? text : text + ".0"
        case .text(let text): return jsonString(text)
        case .array(let array):
            // キーが 0..n-1 の整数なら JSON 配列、そうでなければオブジェクト
            var isList = true
            for (position, key) in array.keys.enumerated() {
                if case .integer(let number) = key, number == Int64(position) { continue }
                isList = false
                break
            }
            if isList {
                if array.isEmpty { return "[]" }
                let items = array.values.map { pad + json($0, pretty: pretty, indent: indent + 1) }
                return "[" + newline + items.joined(separator: "," + newline) + newline + closingPad + "]"
            }
            if array.isEmpty { return "{}" }
            let items = array.keys.map { key in
                pad + jsonString(key.description) + separator
                    + json(array[key] ?? .null, pretty: pretty, indent: indent + 1)
            }
            return "{" + newline + items.joined(separator: "," + newline) + newline + closingPad + "}"
        case .object(let object):
            return json(.array(object.properties), pretty: pretty, indent: indent)
        case .closure:
            return "{}"
        }
    }

    private static func jsonString(_ text: String) -> String {
        var result = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "/": result += "\\/"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else if character.value > 127 {
                    // PHP の既定は \uXXXX に変換する
                    if character.value > 0xFFFF {
                        let value = character.value - 0x10000
                        let high = 0xD800 + (value >> 10)
                        let low = 0xDC00 + (value & 0x3FF)
                        result += String(format: "\\u%04x\\u%04x", high, low)
                    } else {
                        result += String(format: "\\u%04x", character.value)
                    }
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }
}
