import Foundation

/// 小数の書き方は言語ごとにかなり違うので、部品をここに集めておく。
public enum MLNumberFormatting {

    /// Swift の最短表現をほどいて「仮数の桁」と「10 の指数」に分ける。
    ///
    /// 戻り値の `digits` は先頭が 0 でない数字列、`exponent` は
    /// `0.digits × 10^exponent` ではなく `digits[0].digits[1...] × 10^exponent` の指数。
    public static func decompose(_ value: Double) -> (negative: Bool, digits: String, exponent: Int)? {
        guard value.isFinite, value != 0 else { return nil }
        var text = "\(Swift.abs(value))"
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = String(text[..<marker])
        }
        var digits = ""
        var pointPosition = text.count
        for (index, character) in text.enumerated() {
            if character == "." {
                pointPosition = index
                continue
            }
            digits.append(character)
        }
        // 先頭の 0 を落としつつ指数を調整する。
        var leadingZeros = 0
        for character in digits {
            if character == "0" { leadingZeros += 1 } else { break }
        }
        digits.removeFirst(leadingZeros)
        if digits.isEmpty { return nil }
        // 末尾の 0 は表示には不要。
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
        exponent += pointPosition - leadingZeros - 1
        return (value < 0, digits, exponent)
    }

    /// Java / Kotlin / Scala の `Double.toString` に相当する形。
    ///
    /// `1.0E7` 以上か `1.0E-3` 未満なら指数表記、それ以外は小数点表記。
    /// どちらでも小数部は最低 1 桁残る。
    public static func javaStyle(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        guard let parts = decompose(value) else {
            return value.sign == .minus ? "-0.0" : "0.0"
        }
        let sign = parts.negative ? "-" : ""
        let digits = Array(parts.digits)
        let exponent = parts.exponent

        if exponent >= 7 || exponent < -3 {
            var mantissa = String(digits[0])
            mantissa += "."
            mantissa += digits.count > 1 ? String(digits[1...]) : "0"
            return sign + mantissa + "E" + String(exponent)
        }
        if exponent >= 0 {
            var text = ""
            for index in 0...exponent {
                text.append(index < digits.count ? digits[index] : "0")
            }
            text += "."
            if digits.count > exponent + 1 {
                text += String(digits[(exponent + 1)...])
            } else {
                text += "0"
            }
            return sign + text
        }
        var text = "0."
        text += String(repeating: "0", count: -exponent - 1)
        text += String(digits)
        return sign + text
    }

    /// JavaScript / Dart の `toString` のように、整数値なら小数点を付けない形。
    public static func compactStyle(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), Swift.abs(value) < 1e21 {
            return String(Int64(value))
        }
        guard let parts = decompose(value) else { return "0" }
        let sign = parts.negative ? "-" : ""
        let digits = Array(parts.digits)
        let exponent = parts.exponent
        if exponent >= 21 || exponent <= -7 {
            var mantissa = String(digits[0])
            if digits.count > 1 { mantissa += "." + String(digits[1...]) }
            return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + String(Swift.abs(exponent))
        }
        if exponent >= 0 {
            var text = ""
            for index in 0...exponent {
                text.append(index < digits.count ? digits[index] : "0")
            }
            if digits.count > exponent + 1 {
                text += "." + String(digits[(exponent + 1)...])
            }
            return sign + text
        }
        return sign + "0." + String(repeating: "0", count: -exponent - 1) + String(digits)
    }

    /// Go / C の `%v` / `%g` のように、必要な桁だけ出す形。
    public static func shortestStyle(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "+Inf" }
        if value == value.rounded(), Swift.abs(value) < 1e21 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    /// 桁数を指定した固定小数表記 (四捨五入は偶数丸めではなく通常の丸め)。
    public static func fixed(_ value: Double, digits: Int) -> String {
        String(format: "%.\(Swift.max(0, digits))f", value)
    }
}
