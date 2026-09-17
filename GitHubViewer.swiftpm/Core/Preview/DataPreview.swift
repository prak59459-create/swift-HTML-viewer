import Foundation

// MARK: - 171. CSV / JSON / YAML の表

/// 表としてのプレビュー。
public struct TablePreview: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String]]
    /// 読み取れなかった行の数。
    public var skippedRows: Int

    public init(columns: [String], rows: [[String]], skippedRows: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.skippedRows = skippedRows
    }

    public var isEmpty: Bool { rows.isEmpty && columns.isEmpty }
    public var rowCount: Int { rows.count }
    public var columnCount: Int { columns.count }

    /// 「3 列 × 120 行」。
    public var summary: String {
        "\(columnCount) 列 × \(rowCount) 行"
    }

    /// 列の幅の目安 (いちばん長い中身の文字数)。
    public var columnWidths: [Int] {
        columns.enumerated().map { index, name in
            var width = name.count
            for row in rows where index < row.count {
                width = Swift.max(width, row[index].count)
            }
            return width
        }
    }

    /// 1 行を取り出す (足りない列は空にする)。
    public func row(_ index: Int) -> [String] {
        guard rows.indices.contains(index) else { return [] }
        var values = rows[index]
        while values.count < columns.count { values.append("") }
        return values
    }
}

/// CSV / TSV を読む。
public enum CSVParser {

    /// 区切りを決めて読む。決めなければ 1 行目から推測する。
    public static func parse(_ text: String, separator: Character? = nil,
                             hasHeader: Bool = true,
                             maximumRows: Int = 5000) -> TablePreview {
        guard !text.isEmpty else { return TablePreview(columns: [], rows: []) }
        let mark = separator ?? guessSeparator(text)
        var records = records(in: text, separator: mark, maximumRows: maximumRows + 1)
        guard !records.isEmpty else { return TablePreview(columns: [], rows: []) }

        let columns: [String]
        if hasHeader {
            columns = records.removeFirst()
        } else {
            let width = records.map(\.count).max() ?? 0
            columns = (1...Swift.max(1, width)).map { "列 \($0)" }
        }
        let skipped = Swift.max(0, records.count - maximumRows)
        if skipped > 0 { records.removeLast(skipped) }
        return TablePreview(columns: columns, rows: records, skippedRows: skipped)
    }

    /// 1 行目に多く出てくる記号を区切りとみなす。
    public static func guessSeparator(_ text: String) -> Character {
        let line = text.components(separatedBy: "\n").first ?? ""
        let candidates: [Character] = ["\t", ",", ";", "|"]
        var best: Character = ","
        var bestCount = 0
        for candidate in candidates {
            let count = line.filter { $0 == candidate }.count
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        return best
    }

    /// 引用符の中の区切りと改行を守りながら読む。
    static func records(in text: String, separator: Character,
                        maximumRows: Int) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
            case separator:
                fields.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                fields.append(field)
                field = ""
                if !(fields.count == 1 && fields[0].isEmpty) { rows.append(fields) }
                fields = []
                if rows.count >= maximumRows { return rows }
            default:
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(fields)
        }
        return rows
    }
}

/// JSON を表や木にほどく。
public enum JSONPreview {

    /// 配列になっている JSON を表にする。
    public static func table(_ text: String, maximumRows: Int = 5000) -> TablePreview? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed])
        else { return nil }

        if let array = object as? [[String: Any]] {
            var columns: [String] = []
            for item in array {
                for key in item.keys.sorted() where !columns.contains(key) {
                    columns.append(key)
                }
            }
            let kept = array.prefix(maximumRows)
            let rows = kept.map { item in
                columns.map { display(item[$0]) }
            }
            return TablePreview(columns: columns, rows: rows,
                                skippedRows: array.count - kept.count)
        }

        if let array = object as? [Any] {
            let kept = array.prefix(maximumRows)
            return TablePreview(columns: ["値"], rows: kept.map { [display($0)] },
                                skippedRows: array.count - kept.count)
        }

        if let map = object as? [String: Any] {
            let keys = map.keys.sorted()
            return TablePreview(columns: ["キー", "値"],
                                rows: keys.map { [$0, display(map[$0])] })
        }
        return nil
    }

    /// 木としてほどく (152 の値ビューアと同じ形)。
    public static func tree(_ text: String, name: String = "JSON") -> ValueNode? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed])
        else { return nil }
        var counter = 0
        return node(object, label: name, counter: &counter)
    }

    private static func node(_ value: Any, label: String,
                             counter: inout Int) -> ValueNode {
        counter += 1
        let identifier = counter
        if let map = value as? [String: Any] {
            let children = map.keys.sorted().map { key in
                node(map[key] ?? NSNull(), label: key, counter: &counter)
            }
            return ValueNode(id: identifier, label: label,
                             text: "{ \(map.count) 組 }", typeName: "オブジェクト",
                             children: children)
        }
        if let array = value as? [Any] {
            let children = array.enumerated().map { index, item in
                node(item, label: "[\(index)]", counter: &counter)
            }
            return ValueNode(id: identifier, label: label,
                             text: "[ \(array.count) 個 ]", typeName: "配列",
                             children: children)
        }
        return ValueNode(id: identifier, label: label, text: display(value),
                         typeName: typeName(of: value))
    }

    static func display(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let text as String: return text
        case let number as NSNumber:
            // `1` も `Bool` として取り出せてしまうので、先に種類で見分ける。
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            if number.doubleValue == number.doubleValue.rounded(),
               abs(number.doubleValue) < 1e15 {
                return String(number.int64Value)
            }
            return MLNumberFormatting.shortestStyle(number.doubleValue)
        case let array as [Any]: return "[ \(array.count) 個 ]"
        case let map as [String: Any]: return "{ \(map.count) 組 }"
        default: return String(describing: value ?? "")
        }
    }

    static func typeName(of value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case is String: return "文字列"
        case let number as NSNumber: return isBoolean(number) ? "真偽" : "数"
        default: return "値"
        }
    }

    /// JSON の true / false は NSNumber として来る。
    ///
    /// `number is Bool` は整数でも真になってしまうので、
    /// 中の種類 (`c` = 1 バイト) で見分ける。
    static func isBoolean(_ number: NSNumber) -> Bool {
        let name = String(cString: number.objCType)
        return name == "c" || name == "B"
    }

    /// 整える (読みやすく並べ直す)。
    public static func formatted(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
    }

    public static func isValid(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data,
                                                  options: [.fragmentsAllowed])) != nil
    }
}

/// YAML の簡単な読み取り。
///
/// 完全な YAML ではなく、設定ファイルでよく使う「キー: 値」「- 並び」
/// 「字下げによる入れ子」だけを扱う。
public enum YAMLPreview {

    /// キーと値の木にほどく。
    public static func tree(_ text: String, name: String = "YAML") -> ValueNode {
        var counter = 0
        let lines = parseLines(text)
        var index = 0
        let children = parse(lines, from: &index, indent: -1, counter: &counter)
        counter += 1
        return ValueNode(id: counter, label: name, text: "\(children.count) 項目",
                         typeName: "YAML", children: children)
    }

    /// いちばん外側を表にする。
    public static func table(_ text: String) -> TablePreview {
        let root = tree(text)
        return TablePreview(columns: ["キー", "値"],
                            rows: root.children.map {
                                [$0.label, $0.isLeaf ? $0.text : $0.text]
                            })
    }

    struct Line {
        var indent: Int
        var content: String
    }

    static func parseLines(_ text: String) -> [Line] {
        var result: [Line] = []
        for raw in text.components(separatedBy: "\n") {
            // コメントと空行は飛ばす。
            let withoutComment = stripComment(raw)
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "---", trimmed != "..." else { continue }
            let indent = withoutComment.prefix { $0 == " " }.count
            result.append(Line(indent: indent, content: trimmed))
        }
        return result
    }

    /// 引用符の外の `#` から後ろを落とす。
    static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                result.append(character)
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                result.append(character)
                continue
            }
            if character == "#" {
                // 行頭か、前が空白のときだけコメント。
                if result.isEmpty || result.last == " " { break }
            }
            result.append(character)
        }
        return result
    }

    static func parse(_ lines: [Line], from index: inout Int, indent: Int,
                      counter: inout Int) -> [ValueNode] {
        var result: [ValueNode] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent > indent else { break }

            counter += 1
            let identifier = counter

            if line.content.hasPrefix("- ") || line.content == "-" {
                let body = String(line.content.dropFirst(line.content == "-" ? 1 : 2))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                let children = parse(lines, from: &index, indent: line.indent,
                                     counter: &counter)
                result.append(ValueNode(id: identifier, label: "[\(result.count)]",
                                        text: body.isEmpty ? "\(children.count) 項目"
                                                           : unquote(body),
                                        typeName: children.isEmpty ? "値" : "並び",
                                        children: children))
                continue
            }

            if let separator = line.content.firstIndex(of: ":") {
                let key = String(line.content[line.content.startIndex..<separator])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(line.content[line.content.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                let children = parse(lines, from: &index, indent: line.indent,
                                     counter: &counter)
                result.append(ValueNode(id: identifier, label: unquote(key),
                                        text: value.isEmpty
                                            ? "\(children.count) 項目" : unquote(value),
                                        typeName: children.isEmpty ? "値" : "まとまり",
                                        children: children))
                continue
            }

            index += 1
            result.append(ValueNode(id: identifier, label: "",
                                    text: unquote(line.content), typeName: "値"))
        }
        return result
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

// MARK: - 177. バイナリの 16 進ダンプ

/// 16 進ダンプの 1 行。
public struct HexDumpLine: Identifiable, Equatable, Sendable {
    public var offset: Int
    /// 16 進の部分。
    public var hex: String
    /// 文字として読める部分。
    public var ascii: String

    public var id: Int { offset }

    public init(offset: Int, hex: String, ascii: String) {
        self.offset = offset
        self.hex = hex
        self.ascii = ascii
    }

    /// 「00000010  48 65 6c 6c ...  |Hello|」。
    public var text: String {
        String(format: "%08X  %@  |%@|", offset, hex, ascii)
    }
}

/// バイナリを 16 進で見せる。
public enum HexDump {

    public static func lines(of data: Data, bytesPerLine: Int = 16,
                            maximumLines: Int = 4096) -> [HexDumpLine] {
        var result: [HexDumpLine] = []
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count, result.count < maximumLines {
            let end = Swift.min(offset + bytesPerLine, bytes.count)
            let slice = bytes[offset..<end]
            var hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            // 最後の行が短くても、桁がそろうように埋める。
            let missing = bytesPerLine - slice.count
            if missing > 0 { hex += String(repeating: "   ", count: missing) }
            let ascii = String(slice.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            })
            result.append(HexDumpLine(offset: offset, hex: hex, ascii: ascii))
            offset = end
        }
        return result
    }

    public static func text(of data: Data, bytesPerLine: Int = 16,
                           maximumLines: Int = 4096) -> String {
        lines(of: data, bytesPerLine: bytesPerLine, maximumLines: maximumLines)
            .map(\.text).joined(separator: "\n")
    }

    /// 先頭の数バイトから、どんなファイルかを当てる。
    public static func fileTypeGuess(_ data: Data) -> String? {
        let signatures: [(bytes: [UInt8], name: String)] = [
            ([0x89, 0x50, 0x4E, 0x47], "PNG 画像"),
            ([0xFF, 0xD8, 0xFF], "JPEG 画像"),
            ([0x47, 0x49, 0x46, 0x38], "GIF 画像"),
            ([0x25, 0x50, 0x44, 0x46], "PDF"),
            ([0x50, 0x4B, 0x03, 0x04], "ZIP (docx / jar など)"),
            ([0x1F, 0x8B], "gzip"),
            ([0x7F, 0x45, 0x4C, 0x46], "ELF 実行ファイル"),
            ([0x53, 0x51, 0x4C, 0x69], "SQLite データベース"),
            ([0x00, 0x00, 0x00, 0x18], "MP4 動画"),
            ([0x49, 0x44, 0x33], "MP3 音声"),
            ([0x52, 0x49, 0x46, 0x46], "RIFF (WAV / AVI)"),
            ([0x77, 0x4F, 0x46, 0x46], "WOFF フォント"),
            ([0x77, 0x4F, 0x46, 0x32], "WOFF2 フォント"),
            ([0x00, 0x01, 0x00, 0x00], "TrueType フォント")
        ]
        let bytes = [UInt8](data.prefix(16))
        for signature in signatures where bytes.count >= signature.bytes.count {
            if Array(bytes.prefix(signature.bytes.count)) == signature.bytes {
                return signature.name
            }
        }
        return nil
    }
}
