import Foundation

/// 標準ライブラリとして用意している関数。
public enum Builtin: Int, CaseIterable {
    case printf, puts, putchar, getchar, scanf
    case strlen, strcmp, strncmp, strcpy, strncpy, strcat, strchr
    case memset, memcpy, memmove
    case malloc, calloc, realloc, free
    case abs, labs, atoi, atof, exitProgram
    case rand, srand, time
    case sqrt, pow, fabs, floor, ceil, round, fmod
    case sin, cos, tan, atan, atan2, log, log10, exp
    // 追加分
    case sprintf, snprintf, fprintf, fputs, fputc, fflush
    case strstr, strrchr, strdup, strncat, memcmp, strtol, strtod, atol
    case isalpha, isdigit, isalnum, isspace, isupper, islower, ispunct, toupper, tolower
    case qsort, bsearch, assertFailed

    public var name: String {
        switch self {
        case .printf: return "printf"
        case .puts: return "puts"
        case .putchar: return "putchar"
        case .getchar: return "getchar"
        case .scanf: return "scanf"
        case .strlen: return "strlen"
        case .strcmp: return "strcmp"
        case .strncmp: return "strncmp"
        case .strcpy: return "strcpy"
        case .strncpy: return "strncpy"
        case .strcat: return "strcat"
        case .strchr: return "strchr"
        case .memset: return "memset"
        case .memcpy: return "memcpy"
        case .memmove: return "memmove"
        case .malloc: return "malloc"
        case .calloc: return "calloc"
        case .realloc: return "realloc"
        case .free: return "free"
        case .abs: return "abs"
        case .labs: return "labs"
        case .atoi: return "atoi"
        case .atof: return "atof"
        case .exitProgram: return "exit"
        case .rand: return "rand"
        case .srand: return "srand"
        case .time: return "time"
        case .sqrt: return "sqrt"
        case .pow: return "pow"
        case .fabs: return "fabs"
        case .floor: return "floor"
        case .ceil: return "ceil"
        case .round: return "round"
        case .fmod: return "fmod"
        case .sin: return "sin"
        case .cos: return "cos"
        case .tan: return "tan"
        case .atan: return "atan"
        case .atan2: return "atan2"
        case .log: return "log"
        case .log10: return "log10"
        case .exp: return "exp"
        case .sprintf: return "sprintf"
        case .snprintf: return "snprintf"
        case .fprintf: return "fprintf"
        case .fputs: return "fputs"
        case .fputc: return "fputc"
        case .fflush: return "fflush"
        case .strstr: return "strstr"
        case .strrchr: return "strrchr"
        case .strdup: return "strdup"
        case .strncat: return "strncat"
        case .memcmp: return "memcmp"
        case .strtol: return "strtol"
        case .strtod: return "strtod"
        case .atol: return "atol"
        case .isalpha: return "isalpha"
        case .isdigit: return "isdigit"
        case .isalnum: return "isalnum"
        case .isspace: return "isspace"
        case .isupper: return "isupper"
        case .islower: return "islower"
        case .ispunct: return "ispunct"
        case .toupper: return "toupper"
        case .tolower: return "tolower"
        case .qsort: return "qsort"
        case .bsearch: return "bsearch"
        case .assertFailed: return "__assert_failed"
        }
    }

    /// 引数と戻り値の型 (型検査と引数の変換に使う)。
    public var signature: (parameters: [CType], returnType: CType, isVariadic: Bool) {
        let voidPointer = CType.pointer(.void)
        let charPointer = CType.pointer(.char)
        switch self {
        case .printf: return ([charPointer], .int, true)
        case .puts: return ([charPointer], .int, false)
        case .putchar: return ([.int], .int, false)
        case .getchar: return ([], .int, false)
        case .scanf: return ([charPointer], .int, true)
        case .strlen: return ([charPointer], .long, false)
        case .strcmp: return ([charPointer, charPointer], .int, false)
        case .strncmp: return ([charPointer, charPointer, .long], .int, false)
        case .strcpy: return ([charPointer, charPointer], charPointer, false)
        case .strncpy: return ([charPointer, charPointer, .long], charPointer, false)
        case .strcat: return ([charPointer, charPointer], charPointer, false)
        case .strchr: return ([charPointer, .int], charPointer, false)
        case .memset: return ([voidPointer, .int, .long], voidPointer, false)
        case .memcpy, .memmove: return ([voidPointer, voidPointer, .long], voidPointer, false)
        case .malloc: return ([.long], voidPointer, false)
        case .calloc: return ([.long, .long], voidPointer, false)
        case .realloc: return ([voidPointer, .long], voidPointer, false)
        case .free: return ([voidPointer], .void, false)
        case .abs: return ([.int], .int, false)
        case .labs: return ([.long], .long, false)
        case .atoi: return ([charPointer], .int, false)
        case .atof: return ([charPointer], .double, false)
        case .exitProgram: return ([.int], .void, false)
        case .rand: return ([], .int, false)
        case .srand: return ([.int], .void, false)
        case .time: return ([voidPointer], .long, false)
        case .sqrt, .fabs, .floor, .ceil, .round, .sin, .cos, .tan, .atan, .log, .log10, .exp:
            return ([.double], .double, false)
        case .pow, .fmod, .atan2:
            return ([.double, .double], .double, false)

        case .sprintf: return ([charPointer, charPointer], .int, true)
        case .snprintf: return ([charPointer, .long, charPointer], .int, true)
        case .fprintf: return ([voidPointer, charPointer], .int, true)
        case .fputs: return ([charPointer, voidPointer], .int, false)
        case .fputc: return ([.int, voidPointer], .int, false)
        case .fflush: return ([voidPointer], .int, false)
        case .strstr, .strrchr: return self == .strstr ? ([charPointer, charPointer], charPointer, false)
                                                       : ([charPointer, .int], charPointer, false)
        case .strdup: return ([charPointer], charPointer, false)
        case .strncat: return ([charPointer, charPointer, .long], charPointer, false)
        case .memcmp: return ([voidPointer, voidPointer, .long], .int, false)
        case .strtol: return ([charPointer, .pointer(charPointer), .int], .long, false)
        case .strtod: return ([charPointer, .pointer(charPointer)], .double, false)
        case .atol: return ([charPointer], .long, false)
        case .isalpha, .isdigit, .isalnum, .isspace, .isupper, .islower, .ispunct,
             .toupper, .tolower:
            return ([.int], .int, false)
        case .qsort: return ([voidPointer, .long, .long, voidPointer], .void, false)
        case .bsearch: return ([voidPointer, voidPointer, .long, .long, voidPointer], voidPointer, false)
        case .assertFailed: return ([charPointer, .int], .void, false)
        }
    }

    public static let lookup: [String: Builtin] = {
        var table: [String: Builtin] = [:]
        for builtin in Builtin.allCases { table[builtin.name] = builtin }
        return table
    }()
}

/// printf 系の書式を処理する。
enum FormatPrinter {
    /// - Parameters:
    ///   - format: 書式文字列
    ///   - arguments: 可変長引数
    ///   - readString: アドレスから C 文字列を読む関数
    static func render(format: String, arguments: [Value], readString: (Int64) -> String) -> String {
        var output = ""
        var argumentIndex = 0
        let characters = Array(format)
        var index = 0

        func nextArgument() -> Value? {
            guard argumentIndex < arguments.count else { return nil }
            defer { argumentIndex += 1 }
            return arguments[argumentIndex]
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                output.append(character)
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

            // フラグ
            var leftAlign = false
            var zeroPad = false
            var forceSign = false
            var spaceSign = false
            var alternate = false
            loop: while index < characters.count {
                switch characters[index] {
                case "-": leftAlign = true
                case "0": zeroPad = true
                case "+": forceSign = true
                case " ": spaceSign = true
                case "#": alternate = true
                default: break loop
                }
                index += 1
            }

            // 幅
            var width = 0
            if index < characters.count, characters[index] == "*" {
                width = Int(nextArgument()?.int ?? 0)
                if width < 0 { leftAlign = true; width = -width }
                index += 1
            } else {
                while index < characters.count, characters[index].isNumber {
                    width = width * 10 + Int(String(characters[index]))!
                    index += 1
                }
            }

            // 精度
            var precision: Int?
            if index < characters.count, characters[index] == "." {
                index += 1
                var value = 0
                if index < characters.count, characters[index] == "*" {
                    value = Int(nextArgument()?.int ?? 0)
                    index += 1
                } else {
                    while index < characters.count, characters[index].isNumber {
                        value = value * 10 + Int(String(characters[index]))!
                        index += 1
                    }
                }
                precision = max(0, value)
            }

            // 長さ修飾子 (%d と %u の幅を決める)
            var isWide = false
            var isShort = false
            while index < characters.count, "hlLzjt".contains(characters[index]) {
                if characters[index] == "l" || characters[index] == "L" || characters[index] == "z"
                    || characters[index] == "j" || characters[index] == "t" {
                    isWide = true
                }
                if characters[index] == "h" { isShort = true }
                index += 1
            }
            guard index < characters.count else { break }

            let conversion = characters[index]
            index += 1

            var text: String
            switch conversion {
            case "d", "i":
                var value = nextArgument()?.int ?? 0
                if !isWide { value = Int64(Int32(truncatingIfNeeded: value)) }
                if isShort { value = Int64(Int16(truncatingIfNeeded: value)) }
                text = String(value.magnitude)
                if let precision, text.count < precision {
                    text = String(repeating: "0", count: precision - text.count) + text
                }
                if value < 0 {
                    text = "-" + text
                } else if forceSign {
                    text = "+" + text
                } else if spaceSign {
                    text = " " + text
                }
            case "u":
                let raw = nextArgument()?.int ?? 0
                text = String(isWide ? UInt64(bitPattern: raw) : UInt64(UInt32(truncatingIfNeeded: raw)))
            case "x", "X":
                let value = nextArgument()?.int ?? 0
                let unsigned = isWide ? UInt64(bitPattern: value) : UInt64(UInt32(truncatingIfNeeded: value))
                text = String(unsigned, radix: 16)
                if conversion == "X" { text = text.uppercased() }
                if let precision, text.count < precision {
                    text = String(repeating: "0", count: precision - text.count) + text
                }
                if alternate, value != 0 { text = (conversion == "X" ? "0X" : "0x") + text }
            case "o":
                let value = nextArgument()?.int ?? 0
                let unsigned = isWide ? UInt64(bitPattern: value) : UInt64(UInt32(truncatingIfNeeded: value))
                text = String(unsigned, radix: 8)
                if alternate { text = "0" + text }
            case "c":
                let value = nextArgument()?.int ?? 0
                let scalar = UnicodeScalar(UInt8(truncatingIfNeeded: value))
                text = String(Character(scalar))
            case "s":
                let value = nextArgument()?.int ?? 0
                text = value == 0 ? "(null)" : readString(value)
                if let precision, text.count > precision {
                    text = String(text.prefix(precision))
                }
            case "f", "F":
                let value = nextArgument()?.double ?? 0
                text = formatFixed(value, precision: precision ?? 6, forceSign: forceSign, spaceSign: spaceSign)
            case "e", "E":
                let value = nextArgument()?.double ?? 0
                text = String(format: "%.\(precision ?? 6)\(conversion == "e" ? "e" : "E")", value)
                if value >= 0, forceSign { text = "+" + text }
            case "g", "G":
                let value = nextArgument()?.double ?? 0
                text = String(format: "%.\(precision ?? 6)\(conversion == "g" ? "g" : "G")", value)
                if value >= 0, forceSign { text = "+" + text }
            case "p":
                let value = nextArgument()?.int ?? 0
                text = "0x" + String(UInt64(bitPattern: value), radix: 16)
            default:
                text = "%" + String(conversion)
            }

            if text.count < width {
                let padding = width - text.count
                if leftAlign {
                    text += String(repeating: " ", count: padding)
                } else if zeroPad, "dieEfgGxXou".contains(conversion) {
                    // 符号の後ろに 0 を詰める
                    if let first = text.first, first == "-" || first == "+" {
                        text = String(first) + String(repeating: "0", count: padding) + text.dropFirst()
                    } else {
                        text = String(repeating: "0", count: padding) + text
                    }
                } else {
                    text = String(repeating: " ", count: padding) + text
                }
            }
            output += text
        }
        return output
    }

    /// `%f` 用の固定小数点表記 (四捨五入は C と同じく偶数丸めではなく通常の丸め)。
    private static func formatFixed(_ value: Double, precision: Int,
                                    forceSign: Bool, spaceSign: Bool) -> String {
        var text: String
        if value.isNaN {
            text = "nan"
        } else if value.isInfinite {
            text = value < 0 ? "-inf" : "inf"
        } else {
            text = String(format: "%.\(precision)f", value)
        }
        if !text.hasPrefix("-") {
            if forceSign {
                text = "+" + text
            } else if spaceSign {
                text = " " + text
            }
        }
        return text
    }

    /// scanf が読み取った 1 つ分の値。
    enum ScanValue {
        case integer(Int64)
        case number(Double)
        case text(String)
    }

    /// scanf の簡易実装。入力から値を読み取り、書き込むアドレスと値の組を返す。
    struct ScanResult {
        var assignments: [(address: Int64, value: ScanValue)]
        var consumed: Int
        var count: Int
    }

    static func scan(format: String, input: [Character], start: Int, addresses: [Int64]) -> ScanResult {
        var result = ScanResult(assignments: [], consumed: start, count: 0)
        var position = start
        var addressIndex = 0
        let characters = Array(format)
        var index = 0

        func skipSpaces() {
            while position < input.count, input[position].isWhitespace { position += 1 }
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                skipSpaces()
                index += 1
                continue
            }
            guard character == "%" else {
                skipSpaces()
                if position < input.count, input[position] == character {
                    position += 1
                    index += 1
                    continue
                }
                break
            }

            index += 1
            while index < characters.count, "hlLzj".contains(characters[index]) { index += 1 }
            guard index < characters.count, addressIndex < addresses.count else { break }
            let conversion = characters[index]
            index += 1
            let address = addresses[addressIndex]

            switch conversion {
            case "d", "i", "u":
                skipSpaces()
                var text = ""
                if position < input.count, input[position] == "-" || input[position] == "+" {
                    text.append(input[position])
                    position += 1
                }
                while position < input.count, input[position].isNumber {
                    text.append(input[position])
                    position += 1
                }
                guard let value = Int64(text) else { return result }
                result.assignments.append((address, .integer(value)))
            case "f", "g", "e":
                skipSpaces()
                var text = ""
                if position < input.count, input[position] == "-" || input[position] == "+" {
                    text.append(input[position])
                    position += 1
                }
                while position < input.count, input[position].isNumber || input[position] == "." {
                    text.append(input[position])
                    position += 1
                }
                guard let value = Double(text) else { return result }
                result.assignments.append((address, .number(value)))
            case "c":
                guard position < input.count else { return result }
                let character = input[position]
                position += 1
                result.assignments.append((address, .text(String(character))))
            case "s":
                skipSpaces()
                var text = ""
                while position < input.count, !input[position].isWhitespace {
                    text.append(input[position])
                    position += 1
                }
                guard !text.isEmpty else { return result }
                result.assignments.append((address, .text(text)))
            default:
                return result
            }
            addressIndex += 1
            result.count += 1
            result.consumed = position
        }
        result.consumed = position
        return result
    }
}
