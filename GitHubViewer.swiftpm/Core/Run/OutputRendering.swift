import Foundation

// MARK: - 114. 標準出力と標準エラーの区別

/// 出力がどちら側から来たか。
public enum OutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
    /// コンパイル時のメッセージ。
    case compiler
    /// アプリ自身の案内 (「実行しました」など)。
    case note

    public var displayName: String {
        switch self {
        case .standardOutput: return "標準出力"
        case .standardError: return "標準エラー"
        case .compiler: return "コンパイル"
        case .note: return "案内"
        }
    }
}

// MARK: - 119. ANSI エスケープ

/// ANSI の色。
public enum ANSIColor: Int, Equatable, Sendable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack = 8, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    /// 256 色指定から近い色を選ぶ。
    static func from256(_ value: Int) -> ANSIColor? {
        if value < 16 { return ANSIColor(rawValue: value) }
        return nil
    }
}

/// 文字の見た目。
public struct ANSIStyle: Equatable, Sendable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isInverted: Bool
    public var isDim: Bool

    public init(foreground: ANSIColor? = nil, background: ANSIColor? = nil,
                isBold: Bool = false, isItalic: Bool = false,
                isUnderlined: Bool = false, isInverted: Bool = false,
                isDim: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isInverted = isInverted
        self.isDim = isDim
    }

    public static let plain = ANSIStyle()

    public var isPlain: Bool { self == .plain }
}

/// 同じ見た目が続くひとかたまり。
public struct StyledRun: Equatable, Sendable {
    public var text: String
    public var style: ANSIStyle
    public var stream: OutputStream

    public init(text: String, style: ANSIStyle = .plain,
                stream: OutputStream = .standardOutput) {
        self.text = text
        self.style = style
        self.stream = stream
    }
}

/// ANSI エスケープを読み取って、見た目つきの文字列にする。
public enum ANSIParser {

    /// `\u{1B}[...m` を解釈して、かたまりに分ける。
    public static func parse(_ text: String,
                             stream: OutputStream = .standardOutput) -> [StyledRun] {
        var runs: [StyledRun] = []
        var current = ""
        var style = ANSIStyle()
        var characters = Array(text)
        var index = 0

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(StyledRun(text: current, style: style, stream: stream))
            current = ""
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "\u{1B}", index + 1 < characters.count,
                  characters[index + 1] == "[" else {
                current.append(character)
                index += 1
                continue
            }

            // `ESC [ 数字 ; 数字 … 文字` を読む。
            var cursor = index + 2
            var parameters = ""
            while cursor < characters.count, !characters[cursor].isLetter {
                parameters.append(characters[cursor])
                cursor += 1
            }
            guard cursor < characters.count else {
                // 途中で切れている。そのまま文字として扱う。
                current.append(character)
                index += 1
                continue
            }
            let final = characters[cursor]
            index = cursor + 1

            switch final {
            case "m":
                flush()
                style = apply(parameters, to: style)
            case "K":
                // 行末まで消す。ここでは何もしない。
                break
            case "J":
                // 画面を消す。ためた分を捨てる。
                flush()
                runs.removeAll()
            default:
                // カーソル移動などは読み飛ばす。
                break
            }
        }
        flush()
        return runs
    }

    /// `0;1;31` のような指定を見た目に反映する。
    static func apply(_ parameters: String, to style: ANSIStyle) -> ANSIStyle {
        var updated = style
        let codes = parameters.isEmpty ? [0]
            : parameters.components(separatedBy: ";").map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: updated = ANSIStyle()
            case 1: updated.isBold = true
            case 2: updated.isDim = true
            case 3: updated.isItalic = true
            case 4: updated.isUnderlined = true
            case 7: updated.isInverted = true
            case 21, 22: updated.isBold = false; updated.isDim = false
            case 23: updated.isItalic = false
            case 24: updated.isUnderlined = false
            case 27: updated.isInverted = false
            case 30...37: updated.foreground = ANSIColor(rawValue: code - 30)
            case 39: updated.foreground = nil
            case 40...47: updated.background = ANSIColor(rawValue: code - 40)
            case 49: updated.background = nil
            case 90...97: updated.foreground = ANSIColor(rawValue: code - 90 + 8)
            case 100...107: updated.background = ANSIColor(rawValue: code - 100 + 8)
            case 38, 48:
                // `38;5;n` (256 色) と `38;2;r;g;b` (フルカラー)。
                let isForeground = code == 38
                if index + 1 < codes.count, codes[index + 1] == 5 {
                    if index + 2 < codes.count {
                        let color = ANSIColor.from256(codes[index + 2])
                        if isForeground { updated.foreground = color }
                        else { updated.background = color }
                    }
                    index += 2
                } else if index + 1 < codes.count, codes[index + 1] == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
        return updated
    }

    /// エスケープを取り除いた素の文字列。
    public static func strip(_ text: String) -> String {
        parse(text).map(\.text).joined()
    }

    /// エスケープが入っているか。
    public static func containsEscapes(_ text: String) -> Bool {
        text.contains("\u{1B}[")
    }
}

// MARK: - 出力のまとめ

/// 画面に出す 1 行。
public struct OutputLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var runs: [StyledRun]
    public var stream: OutputStream

    public init(id: Int, runs: [StyledRun], stream: OutputStream) {
        self.id = id
        self.runs = runs
        self.stream = stream
    }

    /// 見た目を落とした文字列。
    public var text: String { runs.map(\.text).joined() }

    public var isEmpty: Bool { text.isEmpty }
}

/// 実行の出力をひとまとめにして、画面に出せる形にする。
public struct OutputDocument: Equatable, Sendable {
    public var lines: [OutputLine]

    public init(lines: [OutputLine] = []) {
        self.lines = lines
    }

    /// 標準出力と標準エラーを合わせて組み立てる。
    public static func make(standardOutput: String = "", standardError: String = "",
                            compilerOutput: String = "",
                            note: String = "") -> OutputDocument {
        var lines: [OutputLine] = []
        var counter = 0

        func append(_ text: String, stream: OutputStream) {
            guard !text.isEmpty else { return }
            var parts = text.components(separatedBy: "\n")
            if parts.count > 1, parts.last == "" { parts.removeLast() }
            for part in parts {
                lines.append(OutputLine(id: counter, runs: ANSIParser.parse(part,
                                                                            stream: stream),
                                        stream: stream))
                counter += 1
            }
        }

        append(compilerOutput, stream: .compiler)
        append(standardOutput, stream: .standardOutput)
        append(standardError, stream: .standardError)
        append(note, stream: .note)
        return OutputDocument(lines: lines)
    }

    /// 実行結果から組み立てる。
    public static func make(_ result: RunResult) -> OutputDocument {
        make(standardOutput: result.output,
             standardError: result.failureText ?? "",
             note: result.statusLine)
    }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var lineCount: Int { lines.count }

    /// ある種類だけを残す。
    public func filtered(to streams: Set<OutputStream>) -> OutputDocument {
        OutputDocument(lines: lines.filter { streams.contains($0.stream) })
    }

    // MARK: - 115. 出力の検索

    /// 一致する行と、その行の中での位置。
    public func search(_ query: String,
                       options: SearchOptions = SearchOptions()) -> [OutputMatch] {
        guard !query.isEmpty else { return [] }
        var found: [OutputMatch] = []
        for line in lines {
            for match in TextSearch.matches(of: query, in: line.text, options: options) {
                found.append(OutputMatch(lineID: line.id, location: match.location,
                                         length: match.length, text: line.text))
            }
        }
        return found
    }

    // MARK: - 118. 長い出力の折りたたみ

    /// 長すぎる出力をたたんで、前後だけを見せる。
    public func folded(head: Int = 200, tail: Int = 100) -> FoldedOutput {
        guard lines.count > head + tail + 1 else {
            return FoldedOutput(head: lines, hiddenCount: 0, tail: [])
        }
        return FoldedOutput(head: Array(lines.prefix(head)),
                            hiddenCount: lines.count - head - tail,
                            tail: Array(lines.suffix(tail)))
    }
}

/// 出力の中で見つかった場所。
public struct OutputMatch: Equatable, Sendable {
    public var lineID: Int
    /// 行の中での位置 (UTF-16)。
    public var location: Int
    public var length: Int
    public var text: String

    public init(lineID: Int, location: Int, length: Int, text: String) {
        self.lineID = lineID
        self.location = location
        self.length = length
        self.text = text
    }
}

/// たたんだ出力。
public struct FoldedOutput: Equatable, Sendable {
    public var head: [OutputLine]
    public var hiddenCount: Int
    public var tail: [OutputLine]

    public init(head: [OutputLine], hiddenCount: Int, tail: [OutputLine]) {
        self.head = head
        self.hiddenCount = hiddenCount
        self.tail = tail
    }

    public var isFolded: Bool { hiddenCount > 0 }

    public var noticeText: String {
        isFolded ? "… \(RunFormatting.number(hiddenCount)) 行を省略しました …" : ""
    }
}

// MARK: - 117. 折り返し

/// 長い行をどう見せるか。
public enum LineWrapMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// 折り返さず横に伸ばす。
    case none
    /// 画面幅で折り返す。
    case word
    /// 決めた桁数で折り返す。
    case fixedColumns

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "折り返さない"
        case .word: return "画面幅で折り返す"
        case .fixedColumns: return "桁数で折り返す"
        }
    }
}

/// 折り返しの計算。
public enum LineWrapping {
    /// 決めた桁数で折り返す。単語の途中で切らないようにする。
    public static func wrap(_ text: String, columns: Int) -> [String] {
        guard columns > 0 else { return [text] }
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            result += wrapOne(line, columns: columns)
        }
        return result
    }

    private static func wrapOne(_ line: String, columns: Int) -> [String] {
        guard line.count > columns else { return [line] }
        var result: [String] = []
        var current = ""
        var pendingWord = ""

        func flushLine() {
            result.append(current)
            current = ""
        }

        for character in line {
            if character == " " {
                if current.count + pendingWord.count + 1 > columns, !current.isEmpty {
                    flushLine()
                }
                current += pendingWord + " "
                pendingWord = ""
                continue
            }
            pendingWord.append(character)
            // 1 単語が長すぎるときは途中で切る。
            if pendingWord.count >= columns {
                if !current.isEmpty { flushLine() }
                result.append(pendingWord)
                pendingWord = ""
            }
        }
        if current.count + pendingWord.count > columns, !current.isEmpty { flushLine() }
        current += pendingWord
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [""] : result
    }
}

// MARK: - 116 / 124 / 125. コピーと共有

/// 実行結果を人に見せる形にまとめる。
public enum RunSharing {

    /// 出力だけを Markdown のコード塊にする。
    public static func outputMarkdown(_ result: RunResult) -> String {
        let text = ANSIParser.strip(result.output)
        return "```\n\(text.isEmpty ? "(出力なし)" : text)\n```"
    }

    /// コードと出力を並べた Markdown。
    public static func markdown(source: String, result: RunResult,
                                languageID: String? = nil, input: String = "",
                                includeStatus: Bool = true) -> String {
        var parts: [String] = []
        parts.append("```\(languageID ?? result.languageID)\n\(source)\n```")
        if !input.isEmpty {
            parts.append("入力:\n\n```\n\(input)\n```")
        }
        parts.append("出力:\n\n" + outputMarkdown(result))
        if let failure = result.failureText, !failure.isEmpty {
            parts.append("エラー:\n\n```\n\(failure)\n```")
        }
        if includeStatus {
            parts.append("`\(result.engineName)` — \(result.statusLine)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 貼り付け用のプレーンテキスト。
    public static func plainText(source: String, result: RunResult,
                                 input: String = "") -> String {
        var parts = ["--- コード ---", source]
        if !input.isEmpty { parts += ["--- 入力 ---", input] }
        parts += ["--- 出力 ---", ANSIParser.strip(result.output)]
        if let failure = result.failureText, !failure.isEmpty {
            parts += ["--- エラー ---", failure]
        }
        parts += ["--- 実行 ---", "\(result.engineName) / \(result.statusLine)"]
        return parts.joined(separator: "\n")
    }

    /// 複数言語で動かした結果を表にする。
    public static func comparisonTable(_ results: [RunResult]) -> String {
        guard !results.isEmpty else { return "" }
        var rows = ["| 言語 | 出力 | 時間 | ステップ | 終了コード |",
                    "| --- | --- | --- | --- | --- |"]
        for result in results {
            let output = ANSIParser.strip(result.output)
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
                .replacingOccurrences(of: "|", with: "\\|")
            rows.append("| \(result.languageID) | \(output.isEmpty ? "(なし)" : output) "
                + "| \(RunFormatting.duration(result.duration)) "
                + "| \(RunFormatting.number(result.steps)) | \(result.exitCode) |")
        }
        return rows.joined(separator: "\n")
    }
}
