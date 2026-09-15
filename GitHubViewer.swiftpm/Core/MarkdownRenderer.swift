import Foundation

/// 外部ライブラリを使わない、小さな Markdown → HTML 変換器。
///
/// 見出し / 箇条書き / 番号付きリスト / 引用 / コードブロック / 表 / 水平線と、
/// インライン記法 (強調・コード・リンク・画像・打ち消し) に対応する。
public enum MarkdownRenderer {
    public static func render(_ markdown: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var listStack: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + inline(paragraph.joined(separator: "\n")) + "</p>\n"
            paragraph.removeAll()
        }

        func closeLists(downTo depth: Int = 0) {
            while listStack.count > depth {
                html += "</\(listStack.removeLast())>\n"
            }
        }

        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // コードブロック ``` / ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                closeLists()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    if current.hasPrefix(fence) { break }
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                let classAttribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                html += "<pre><code\(classAttribute)>" + escape(body.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            // 空行
            if trimmed.isEmpty {
                flushParagraph()
                closeLists()
                index += 1
                continue
            }

            // 水平線
            if isThematicBreak(trimmed) {
                flushParagraph()
                closeLists()
                html += "<hr>\n"
                index += 1
                continue
            }

            // 見出し (# 〜 ######)
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                closeLists()
                html += "<h\(heading.level)>" + inline(heading.text) + "</h\(heading.level)>\n"
                index += 1
                continue
            }

            // 表 (| a | b | の次の行が |---|---|)
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                closeLists()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                html += "<table>\n<thead><tr>"
                html += header.map { "<th>" + inline($0) + "</th>" }.joined()
                html += "</tr></thead>\n<tbody>\n"
                for row in rows {
                    html += "<tr>" + row.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>\n"
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeLists()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                html += "<blockquote>\n" + render(quoted.joined(separator: "\n")) + "</blockquote>\n"
                continue
            }

            // リスト
            if let item = parseListItem(line) {
                flushParagraph()
                let depth = item.indent / 2 + 1
                if listStack.count > depth { closeLists(downTo: depth) }
                if listStack.count < depth {
                    while listStack.count < depth {
                        html += "<\(item.tag)>\n"
                        listStack.append(item.tag)
                    }
                } else if let current = listStack.last, current != item.tag {
                    html += "</\(listStack.removeLast())>\n<\(item.tag)>\n"
                    listStack.append(item.tag)
                }
                html += "<li>" + inline(item.text) + "</li>\n"
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        closeLists()
        return html
    }

    // MARK: - ブロック要素の判定

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func parseListItem(_ line: String) -> (tag: String, indent: Int, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += (first == "\t") ? 4 : 1
            rest = rest.dropFirst()
        }
        if let marker = rest.first, marker == "-" || marker == "*" || marker == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            var text = after.trimmingCharacters(in: .whitespaces)
            // タスクリスト
            if text.hasPrefix("[ ] ") {
                text = "<input type=\"checkbox\" disabled> " + String(text.dropFirst(4))
            } else if text.lowercased().hasPrefix("[x] ") {
                text = "<input type=\"checkbox\" checked disabled> " + String(text.dropFirst(4))
            }
            return ("ul", indent, text)
        }
        // 1. 2. のような番号付き
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, dot == "." || dot == ")" {
                let text = after.dropFirst().trimmingCharacters(in: .whitespaces)
                return ("ol", indent, text)
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|"), line.contains("-") else { return false }
        let allowed = Set("|-: ")
        return line.allSatisfy { allowed.contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var text = line
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - インライン要素

    /// タスクリストで差し込んだ `<input>` を壊さないよう、既に HTML の部分は退避してから変換する。
    public static func inline(_ text: String) -> String {
        var preserved: [String] = []
        var source = text
        source = replace(source, pattern: "<input[^>]*>") { match in
            preserved.append(match[0])
            return placeholder("HTML", preserved.count - 1)
        }

        var result = escape(source)

        var codes: [String] = []
        result = replace(result, pattern: "`([^`]+)`") { match in
            codes.append(match[1])
            return placeholder("CODE", codes.count - 1)
        }

        result = replace(result, pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)") { match in
            "<img alt=\"\(match[1])\" src=\"\(match[2])\">"
        }
        result = replace(result, pattern: "\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)") { match in
            "<a href=\"\(match[2])\">\(match[1])</a>"
        }
        result = replace(result, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0[1])</strong>" }
        result = replace(result, pattern: "__([^_]+)__") { "<strong>\($0[1])</strong>" }
        result = replace(result, pattern: "(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])") { "<em>\($0[1])</em>" }
        result = replace(result, pattern: "~~([^~]+)~~") { "<del>\($0[1])</del>" }

        for (index, code) in codes.enumerated() {
            result = result.replacingOccurrences(of: placeholder("CODE", index), with: "<code>\(code)</code>")
        }
        for (index, html) in preserved.enumerated() {
            result = result.replacingOccurrences(of: placeholder("HTML", index), with: html)
        }
        return result.replacingOccurrences(of: "\n", with: "<br>\n")
    }

    private static func placeholder(_ kind: String, _ index: Int) -> String {
        "\u{E000}\(kind)\(index)\u{E001}"
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ text: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            var groups: [String] = []
            for group in 0..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append("")
                }
            }
            guard let full = Range(match.range, in: result) else { continue }
            result.replaceSubrange(full, with: transform(groups))
        }
        return result
    }
}
