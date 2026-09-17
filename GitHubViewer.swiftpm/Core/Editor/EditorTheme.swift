import Foundation

/// 色 1 つ。SwiftUI に依存しないように 0〜1 の三原色で持つ。
public struct ThemeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` から作る。
    public init(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        let value = UInt32(text, radix: 16) ?? 0
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        alpha = 1
    }

    /// `#RRGGBB` の形。
    public var hexString: String {
        String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

/// エディタの配色。
public struct EditorTheme: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 暗い配色かどうか (画面全体の見た目を合わせるのに使う)。
    public var isDark: Bool
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var currentLine: ThemeColor
    public var selection: ThemeColor
    public var lineNumber: ThemeColor
    public var currentLineNumber: ThemeColor
    public var guideLine: ThemeColor
    /// 種類ごとの色。
    public var colors: [HighlightKind: ThemeColor]

    public init(id: String, name: String, isDark: Bool, background: ThemeColor,
                foreground: ThemeColor, currentLine: ThemeColor, selection: ThemeColor,
                lineNumber: ThemeColor, currentLineNumber: ThemeColor,
                guideLine: ThemeColor, colors: [HighlightKind: ThemeColor]) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.currentLine = currentLine
        self.selection = selection
        self.lineNumber = lineNumber
        self.currentLineNumber = currentLineNumber
        self.guideLine = guideLine
        self.colors = colors
    }

    /// 種類に対応する色 (無ければ本文の色)。
    public func color(for kind: HighlightKind) -> ThemeColor {
        colors[kind] ?? foreground
    }
}

/// 使える配色の一覧。
public enum EditorThemeCatalog {
    public static let all: [EditorTheme] = [
        light, dark, solarizedLight, solarizedDark, midnight, paper, highContrast, ocean
    ]

    public static func theme(id: String) -> EditorTheme? {
        all.first { $0.id == id }
    }

    /// 明るい / 暗いに合わせた既定の配色。
    public static func `default`(isDark: Bool) -> EditorTheme {
        isDark ? dark : light
    }

    // MARK: 明るい配色

    public static let light = EditorTheme(
        id: "light", name: "ライト", isDark: false,
        background: ThemeColor(hex: "#FFFFFF"),
        foreground: ThemeColor(hex: "#1F2328"),
        currentLine: ThemeColor(hex: "#F6F8FA"),
        selection: ThemeColor(hex: "#B6D7FF"),
        lineNumber: ThemeColor(hex: "#B1B7BE"),
        currentLineNumber: ThemeColor(hex: "#57606A"),
        guideLine: ThemeColor(hex: "#EBEEF1"),
        colors: [
            .keyword: ThemeColor(hex: "#CF222E"),
            .type: ThemeColor(hex: "#953800"),
            .function: ThemeColor(hex: "#8250DF"),
            .number: ThemeColor(hex: "#0550AE"),
            .string: ThemeColor(hex: "#0A3069"),
            .character: ThemeColor(hex: "#0A3069"),
            .comment: ThemeColor(hex: "#6E7781"),
            .documentationComment: ThemeColor(hex: "#57794A"),
            .operatorSymbol: ThemeColor(hex: "#CF222E"),
            .punctuation: ThemeColor(hex: "#57606A"),
            .preprocessor: ThemeColor(hex: "#8250DF"),
            .attribute: ThemeColor(hex: "#8250DF"),
            .variable: ThemeColor(hex: "#0550AE"),
            .constant: ThemeColor(hex: "#0550AE"),
            .invalid: ThemeColor(hex: "#D1242F")
        ])

    public static let dark = EditorTheme(
        id: "dark", name: "ダーク", isDark: true,
        background: ThemeColor(hex: "#0D1117"),
        foreground: ThemeColor(hex: "#E6EDF3"),
        currentLine: ThemeColor(hex: "#161B22"),
        selection: ThemeColor(hex: "#264F78"),
        lineNumber: ThemeColor(hex: "#484F58"),
        currentLineNumber: ThemeColor(hex: "#8B949E"),
        guideLine: ThemeColor(hex: "#21262D"),
        colors: [
            .keyword: ThemeColor(hex: "#FF7B72"),
            .type: ThemeColor(hex: "#FFA657"),
            .function: ThemeColor(hex: "#D2A8FF"),
            .number: ThemeColor(hex: "#79C0FF"),
            .string: ThemeColor(hex: "#A5D6FF"),
            .character: ThemeColor(hex: "#A5D6FF"),
            .comment: ThemeColor(hex: "#8B949E"),
            .documentationComment: ThemeColor(hex: "#7EE787"),
            .operatorSymbol: ThemeColor(hex: "#FF7B72"),
            .punctuation: ThemeColor(hex: "#8B949E"),
            .preprocessor: ThemeColor(hex: "#D2A8FF"),
            .attribute: ThemeColor(hex: "#D2A8FF"),
            .variable: ThemeColor(hex: "#79C0FF"),
            .constant: ThemeColor(hex: "#79C0FF"),
            .invalid: ThemeColor(hex: "#FF7B72")
        ])

    public static let solarizedLight = EditorTheme(
        id: "solarized-light", name: "Solarized ライト", isDark: false,
        background: ThemeColor(hex: "#FDF6E3"),
        foreground: ThemeColor(hex: "#657B83"),
        currentLine: ThemeColor(hex: "#EEE8D5"),
        selection: ThemeColor(hex: "#D8D2C0"),
        lineNumber: ThemeColor(hex: "#93A1A1"),
        currentLineNumber: ThemeColor(hex: "#586E75"),
        guideLine: ThemeColor(hex: "#EEE8D5"),
        colors: [
            .keyword: ThemeColor(hex: "#859900"),
            .type: ThemeColor(hex: "#B58900"),
            .function: ThemeColor(hex: "#268BD2"),
            .number: ThemeColor(hex: "#D33682"),
            .string: ThemeColor(hex: "#2AA198"),
            .character: ThemeColor(hex: "#2AA198"),
            .comment: ThemeColor(hex: "#93A1A1"),
            .documentationComment: ThemeColor(hex: "#93A1A1"),
            .operatorSymbol: ThemeColor(hex: "#859900"),
            .punctuation: ThemeColor(hex: "#657B83"),
            .preprocessor: ThemeColor(hex: "#CB4B16"),
            .attribute: ThemeColor(hex: "#CB4B16"),
            .variable: ThemeColor(hex: "#268BD2"),
            .constant: ThemeColor(hex: "#D33682"),
            .invalid: ThemeColor(hex: "#DC322F")
        ])

    public static let solarizedDark = EditorTheme(
        id: "solarized-dark", name: "Solarized ダーク", isDark: true,
        background: ThemeColor(hex: "#002B36"),
        foreground: ThemeColor(hex: "#839496"),
        currentLine: ThemeColor(hex: "#073642"),
        selection: ThemeColor(hex: "#0F4B5B"),
        lineNumber: ThemeColor(hex: "#586E75"),
        currentLineNumber: ThemeColor(hex: "#93A1A1"),
        guideLine: ThemeColor(hex: "#073642"),
        colors: [
            .keyword: ThemeColor(hex: "#859900"),
            .type: ThemeColor(hex: "#B58900"),
            .function: ThemeColor(hex: "#268BD2"),
            .number: ThemeColor(hex: "#D33682"),
            .string: ThemeColor(hex: "#2AA198"),
            .character: ThemeColor(hex: "#2AA198"),
            .comment: ThemeColor(hex: "#586E75"),
            .documentationComment: ThemeColor(hex: "#586E75"),
            .operatorSymbol: ThemeColor(hex: "#859900"),
            .punctuation: ThemeColor(hex: "#839496"),
            .preprocessor: ThemeColor(hex: "#CB4B16"),
            .attribute: ThemeColor(hex: "#CB4B16"),
            .variable: ThemeColor(hex: "#268BD2"),
            .constant: ThemeColor(hex: "#D33682"),
            .invalid: ThemeColor(hex: "#DC322F")
        ])

    public static let midnight = EditorTheme(
        id: "midnight", name: "ミッドナイト", isDark: true,
        background: ThemeColor(hex: "#000000"),
        foreground: ThemeColor(hex: "#DCDCDC"),
        currentLine: ThemeColor(hex: "#101010"),
        selection: ThemeColor(hex: "#264F78"),
        lineNumber: ThemeColor(hex: "#3A3A3A"),
        currentLineNumber: ThemeColor(hex: "#9A9A9A"),
        guideLine: ThemeColor(hex: "#1A1A1A"),
        colors: [
            .keyword: ThemeColor(hex: "#569CD6"),
            .type: ThemeColor(hex: "#4EC9B0"),
            .function: ThemeColor(hex: "#DCDCAA"),
            .number: ThemeColor(hex: "#B5CEA8"),
            .string: ThemeColor(hex: "#CE9178"),
            .character: ThemeColor(hex: "#CE9178"),
            .comment: ThemeColor(hex: "#6A9955"),
            .documentationComment: ThemeColor(hex: "#6A9955"),
            .operatorSymbol: ThemeColor(hex: "#D4D4D4"),
            .punctuation: ThemeColor(hex: "#808080"),
            .preprocessor: ThemeColor(hex: "#C586C0"),
            .attribute: ThemeColor(hex: "#C586C0"),
            .variable: ThemeColor(hex: "#9CDCFE"),
            .constant: ThemeColor(hex: "#4FC1FF"),
            .invalid: ThemeColor(hex: "#F44747")
        ])

    public static let paper = EditorTheme(
        id: "paper", name: "紙", isDark: false,
        background: ThemeColor(hex: "#FAF9F5"),
        foreground: ThemeColor(hex: "#2E2B26"),
        currentLine: ThemeColor(hex: "#F1EFE7"),
        selection: ThemeColor(hex: "#D9D2BE"),
        lineNumber: ThemeColor(hex: "#BFB9A8"),
        currentLineNumber: ThemeColor(hex: "#6B6455"),
        guideLine: ThemeColor(hex: "#EDEAE0"),
        colors: [
            .keyword: ThemeColor(hex: "#8B3A2F"),
            .type: ThemeColor(hex: "#7A5B28"),
            .function: ThemeColor(hex: "#3F5C8A"),
            .number: ThemeColor(hex: "#6B4E9B"),
            .string: ThemeColor(hex: "#3F6B4A"),
            .character: ThemeColor(hex: "#3F6B4A"),
            .comment: ThemeColor(hex: "#9A927F"),
            .documentationComment: ThemeColor(hex: "#7E8A6B"),
            .operatorSymbol: ThemeColor(hex: "#8B3A2F"),
            .punctuation: ThemeColor(hex: "#6B6455"),
            .preprocessor: ThemeColor(hex: "#6B4E9B"),
            .attribute: ThemeColor(hex: "#6B4E9B"),
            .variable: ThemeColor(hex: "#3F5C8A"),
            .constant: ThemeColor(hex: "#6B4E9B"),
            .invalid: ThemeColor(hex: "#B03A2E")
        ])

    public static let highContrast = EditorTheme(
        id: "high-contrast", name: "ハイコントラスト", isDark: true,
        background: ThemeColor(hex: "#000000"),
        foreground: ThemeColor(hex: "#FFFFFF"),
        currentLine: ThemeColor(hex: "#1A1A1A"),
        selection: ThemeColor(hex: "#0060C0"),
        lineNumber: ThemeColor(hex: "#808080"),
        currentLineNumber: ThemeColor(hex: "#FFFFFF"),
        guideLine: ThemeColor(hex: "#333333"),
        colors: [
            .keyword: ThemeColor(hex: "#5FD7FF"),
            .type: ThemeColor(hex: "#5FFF87"),
            .function: ThemeColor(hex: "#FFFF5F"),
            .number: ThemeColor(hex: "#FF87FF"),
            .string: ThemeColor(hex: "#FFAF5F"),
            .character: ThemeColor(hex: "#FFAF5F"),
            .comment: ThemeColor(hex: "#A8A8A8"),
            .documentationComment: ThemeColor(hex: "#A8FFA8"),
            .operatorSymbol: ThemeColor(hex: "#FFFFFF"),
            .punctuation: ThemeColor(hex: "#D0D0D0"),
            .preprocessor: ThemeColor(hex: "#FF5FFF"),
            .attribute: ThemeColor(hex: "#FF5FFF"),
            .variable: ThemeColor(hex: "#5FD7FF"),
            .constant: ThemeColor(hex: "#FF87FF"),
            .invalid: ThemeColor(hex: "#FF5F5F")
        ])

    public static let ocean = EditorTheme(
        id: "ocean", name: "オーシャン", isDark: true,
        background: ThemeColor(hex: "#0F1C2E"),
        foreground: ThemeColor(hex: "#C7D5E0"),
        currentLine: ThemeColor(hex: "#16273D"),
        selection: ThemeColor(hex: "#2A4A6E"),
        lineNumber: ThemeColor(hex: "#41576F"),
        currentLineNumber: ThemeColor(hex: "#90A9C0"),
        guideLine: ThemeColor(hex: "#1B2E47"),
        colors: [
            .keyword: ThemeColor(hex: "#6FB3D2"),
            .type: ThemeColor(hex: "#F2C38F"),
            .function: ThemeColor(hex: "#A1D569"),
            .number: ThemeColor(hex: "#DB9C5E"),
            .string: ThemeColor(hex: "#99C794"),
            .character: ThemeColor(hex: "#99C794"),
            .comment: ThemeColor(hex: "#65737E"),
            .documentationComment: ThemeColor(hex: "#7C9E8A"),
            .operatorSymbol: ThemeColor(hex: "#C594C5"),
            .punctuation: ThemeColor(hex: "#8FA1B3"),
            .preprocessor: ThemeColor(hex: "#C594C5"),
            .attribute: ThemeColor(hex: "#C594C5"),
            .variable: ThemeColor(hex: "#6FB3D2"),
            .constant: ThemeColor(hex: "#DB9C5E"),
            .invalid: ThemeColor(hex: "#EC5F67")
        ])
}
