import Foundation

// MARK: - 21. 等幅フォント

/// エディタで選べるフォント。
public struct EditorFont: Identifiable, Equatable, Codable, Sendable {
    /// 画面に出す名前。
    public var displayName: String
    /// 実際のフォント名。nil ならその環境の標準の等幅フォント。
    public var fontName: String?
    /// 読みやすさのための覚え書き。
    public var note: String

    public var id: String { fontName ?? "system" }

    public init(displayName: String, fontName: String?, note: String = "") {
        self.displayName = displayName
        self.fontName = fontName
        self.note = note
    }
}

/// 選べるフォントの一覧。
public enum EditorFontCatalog {
    /// iPadOS に入っている等幅フォントを中心に選ぶ。
    public static let all: [EditorFont] = [
        EditorFont(displayName: "システム標準", fontName: nil,
                   note: "その環境の等幅フォント。"),
        EditorFont(displayName: "SF Mono", fontName: "SFMono-Regular",
                   note: "Apple の等幅フォント。読みやすく、記号がはっきりしている。"),
        EditorFont(displayName: "Menlo", fontName: "Menlo",
                   note: "落ち着いた見た目。行の高さが低め。"),
        EditorFont(displayName: "Courier New", fontName: "Courier New",
                   note: "昔ながらのタイプライター風。"),
        EditorFont(displayName: "Andale Mono", fontName: "AndaleMono",
                   note: "字幅が広めで、小さくしても読みやすい。"),
        EditorFont(displayName: "Hiragino Sans", fontName: "HiraginoSans-W3",
                   note: "日本語が多いときに。等幅ではない。")
    ]

    public static let `default` = all[0]

    public static func font(id: String) -> EditorFont? {
        all.first { $0.id == id }
    }
}

// MARK: - 20. 文字の大きさ

/// 文字の大きさ。ピンチで変えるときの上下限をここで決める。
public struct FontSize: Equatable, Codable, Sendable {
    public var points: Double
    public static let minimum: Double = 8
    public static let maximum: Double = 40
    public static let `default` = FontSize(points: 14)

    public init(points: Double) {
        self.points = Swift.min(FontSize.maximum,
                                Swift.max(FontSize.minimum, points))
    }

    /// ピンチの倍率をかける。
    public func scaled(by factor: Double) -> FontSize {
        FontSize(points: points * factor)
    }

    /// 1 段階ずつ変える。
    public func stepped(by amount: Double) -> FontSize {
        FontSize(points: points + amount)
    }

    public var isSmallest: Bool { points <= FontSize.minimum }
    public var isLargest: Bool { points >= FontSize.maximum }

    /// 行の高さの目安。
    public var lineHeight: Double { points * 1.35 }
}

// MARK: - エディタの設定

/// エディタの見た目と動きの設定。
public struct EditorSettings: Equatable, Codable, Sendable {
    /// 17. 折り返し。
    public var wrapMode: LineWrapMode
    /// 折り返す桁数 (`wrapMode` が `.fixedColumns` のとき)。
    public var wrapColumns: Int
    public var fontID: String
    public var fontSize: FontSize
    /// 157. 見た目のテーマ。
    public var themeID: String
    /// 156. ダークモードの手動切り替え。
    public var appearance: AppearanceMode
    public var showsLineNumbers: Bool
    public var showsInvisibles: Bool
    public var highlightsCurrentLine: Bool
    public var showsMinimap: Bool
    /// 180. 桁のガイド線。0 なら出さない。
    public var rulerColumn: Int
    public var indent: IndentStyle
    /// 5. 括弧や引用符の自動補完。
    public var completesBrackets: Bool
    /// 103. 自動実行の方針。
    public var autoRun: AutoRunPolicy
    /// 23. 自動保存。
    public var autoSaves: Bool

    public init(wrapMode: LineWrapMode = .word, wrapColumns: Int = 80,
                fontID: String = EditorFontCatalog.default.id,
                fontSize: FontSize = .default,
                themeID: String = "light",
                appearance: AppearanceMode = .system,
                showsLineNumbers: Bool = true, showsInvisibles: Bool = false,
                highlightsCurrentLine: Bool = true, showsMinimap: Bool = false,
                rulerColumn: Int = 0,
                indent: IndentStyle = IndentStyle(usesSpaces: true, width: 4),
                completesBrackets: Bool = true,
                autoRun: AutoRunPolicy = .never,
                autoSaves: Bool = true) {
        self.wrapMode = wrapMode
        self.wrapColumns = wrapColumns
        self.fontID = fontID
        self.fontSize = fontSize
        self.themeID = themeID
        self.appearance = appearance
        self.showsLineNumbers = showsLineNumbers
        self.showsInvisibles = showsInvisibles
        self.highlightsCurrentLine = highlightsCurrentLine
        self.showsMinimap = showsMinimap
        self.rulerColumn = rulerColumn
        self.indent = indent
        self.completesBrackets = completesBrackets
        self.autoRun = autoRun
        self.autoSaves = autoSaves
    }

    public static let `default` = EditorSettings()

    public var font: EditorFont {
        EditorFontCatalog.font(id: fontID) ?? EditorFontCatalog.default
    }

    public var theme: EditorTheme {
        EditorThemeCatalog.theme(id: themeID) ?? EditorThemeCatalog.light
    }

    /// 保存用の JSON。
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// 保存しておいた JSON から戻す。
    public static func decoded(_ data: Data?) -> EditorSettings {
        guard let data,
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: data)
        else { return .default }
        return settings
    }
}

// MARK: - 156. 見た目の切り替え

/// 明るい / 暗いの選び方。
public enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Equatable,
                            Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "端末に合わせる"
        case .light: return "明るい"
        case .dark: return "暗い"
        }
    }

    /// 端末の設定が暗いときに、暗い見た目にするか。
    public func prefersDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    /// この見た目に合うテーマ。
    public func theme(systemIsDark: Bool, lightID: String = "light",
                      darkID: String = "dark") -> EditorTheme {
        let id = prefersDark(systemIsDark: systemIsDark) ? darkID : lightID
        return EditorThemeCatalog.theme(id: id) ?? EditorThemeCatalog.light
    }
}

// MARK: - 32. エラー・警告のインライン表示

/// 行に付ける印。
public struct InlineDiagnostic: Identifiable, Equatable, Sendable {
    public enum Severity: String, Equatable, Comparable, Sendable {
        case error
        case warning
        case hint

        public var displayName: String {
            switch self {
            case .error: return "エラー"
            case .warning: return "警告"
            case .hint: return "ヒント"
            }
        }

        public var symbol: String {
            switch self {
            case .error: return "✗"
            case .warning: return "⚠"
            case .hint: return "•"
            }
        }

        var order: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .hint: return 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.order < rhs.order
        }
    }

    public var id: UUID
    public var line: Int
    public var column: Int
    public var severity: Severity
    public var message: String
    /// 直し方 (あれば)。
    public var suggestion: String?

    public init(id: UUID = UUID(), line: Int, column: Int = 0,
                severity: Severity, message: String, suggestion: String? = nil) {
        self.id = id
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
    }
}

/// いろいろな検査の結果を、行ごとの印にまとめる。
public struct DiagnosticSet: Equatable, Sendable {
    public var items: [InlineDiagnostic]

    public init(items: [InlineDiagnostic] = []) {
        self.items = items.sorted { ($0.line, $0.severity.order) < ($1.line, $1.severity.order) }
    }

    /// 行ごとに引く。
    public func diagnostics(atLine line: Int) -> [InlineDiagnostic] {
        items.filter { $0.line == line }
    }

    /// その行のいちばん重い印。
    public func severity(atLine line: Int) -> InlineDiagnostic.Severity? {
        diagnostics(atLine: line).map(\.severity).min()
    }

    public var errorCount: Int { items.filter { $0.severity == .error }.count }
    public var warningCount: Int { items.filter { $0.severity == .warning }.count }
    public var hasErrors: Bool { errorCount > 0 }

    public var isEmpty: Bool { items.isEmpty }

    /// 「エラー 2 / 警告 1」。
    public var summary: String {
        guard !isEmpty else { return "問題は見つかりませんでした" }
        var parts: [String] = []
        if errorCount > 0 { parts.append("エラー \(errorCount)") }
        if warningCount > 0 { parts.append("警告 \(warningCount)") }
        let hints = items.count - errorCount - warningCount
        if hints > 0 { parts.append("ヒント \(hints)") }
        return parts.joined(separator: " / ")
    }

    // MARK: - 31. 直前のエラー箇所へジャンプ

    /// いまの行より後ろで、いちばん近い印。無ければ先頭に戻る。
    public func next(after line: Int) -> InlineDiagnostic? {
        items.first { $0.line > line } ?? items.first
    }

    /// いまの行より前で、いちばん近い印。無ければ末尾に戻る。
    public func previous(before line: Int) -> InlineDiagnostic? {
        items.last { $0.line < line } ?? items.last
    }

    /// いちばん最初のエラー。
    public var firstError: InlineDiagnostic? {
        items.first { $0.severity == .error }
    }

    // MARK: - 組み立て

    /// 構文チェック・Lint・よくある間違いをまとめる。
    public static func collect(source: String, languageID: String?,
                               includesLint: Bool = true,
                               includesHints: Bool = true,
                               lintOptions: LintOptions = .default) -> DiagnosticSet {
        var items: [InlineDiagnostic] = []

        if let languageID, RunSession.hasEngine(for: languageID),
           let check = try? RunSession.checkSyntax(languageID: languageID,
                                                   source: source), !check.isValid {
            items += parse(check.diagnosticsText)
        }

        if includesLint {
            for finding in Lint.check(source, languageID: languageID,
                                      options: lintOptions) {
                items.append(InlineDiagnostic(
                    line: finding.line, column: finding.column,
                    severity: finding.level == .mistake ? .warning : .hint,
                    message: finding.message))
            }
        }

        if includesHints {
            for hint in CommonMistakes.hints(in: source, languageID: languageID) {
                items.append(InlineDiagnostic(
                    line: hint.line,
                    severity: hint.level == .mistake ? .warning : .hint,
                    message: hint.message, suggestion: hint.suggestion))
            }
        }

        return DiagnosticSet(items: items)
    }

    /// 実行結果のエラーを印にする。
    public static func fromRun(_ result: RunResult) -> DiagnosticSet {
        var items: [InlineDiagnostic] = []
        if !result.execution.parsed {
            items += parse(result.execution.diagnosticsText)
        } else if let error = result.execution.runtimeError {
            let line = result.execution.errorStack?.line ?? lineNumber(in: error) ?? 0
            items.append(InlineDiagnostic(
                line: line, severity: .error, message: error,
                suggestion: ErrorHelp.explanation(for: error)?.remedy))
        }
        for warning in result.execution.warnings {
            items.append(InlineDiagnostic(line: warning.line, severity: .warning,
                                          message: warning.message))
        }
        return DiagnosticSet(items: items)
    }

    /// 「3:12 なんとか」の形の並びを読み取る。
    static func parse(_ text: String) -> [InlineDiagnostic] {
        var items: [InlineDiagnostic] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: " ")
            guard let head = parts.first else { continue }
            let numbers = head.components(separatedBy: ":")
            guard numbers.count >= 2, let lineNumber = Int(numbers[0]),
                  let column = Int(numbers[1]) else {
                // 位置が分からないものも残す。
                items.append(InlineDiagnostic(line: 0, severity: .error, message: line))
                continue
            }
            let message = parts.dropFirst().joined(separator: " ")
            items.append(InlineDiagnostic(line: lineNumber, column: column,
                                          severity: .error,
                                          message: message.isEmpty ? line : message))
        }
        return items
    }

    /// メッセージから「12 行目」を拾う。
    static func lineNumber(in message: String) -> Int? {
        if let range = message.range(of: #"([0-9]+) 行目"#,
                                     options: .regularExpression) {
            let text = message[range].components(separatedBy: " ").first ?? ""
            return Int(text)
        }
        if let range = message.range(of: #"^\s*([0-9]+):"#,
                                     options: .regularExpression) {
            return Int(message[range].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: ""))
        }
        return nil
    }
}
