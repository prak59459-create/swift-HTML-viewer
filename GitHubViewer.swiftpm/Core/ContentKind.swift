import Foundation

/// 取得したファイルを「何として表示するか」の分類。
public enum ContentKind: Equatable {
    /// ブラウザでそのまま実行できるもの (html / svg)。
    case web
    /// Markdown。HTML に変換してから表示する。
    case markdown
    /// 画像。
    case image
    /// テキスト。`language` はシンタックス表示用のヒント。
    case code(language: String)
    /// テキストとして読めないデータ。
    case binary

    public var isTextual: Bool {
        switch self {
        case .web, .markdown, .code:
            return true
        case .image, .binary:
            return false
        }
    }
}

public enum ContentClassifier {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "ico", "webp", "heic",
    ]

    private static let languages: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "tsx", "jsx": "jsx", "json": "json",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php",
        "sh": "bash", "bash": "bash", "zsh": "bash", "yml": "yaml", "yaml": "yaml",
        "toml": "toml", "ini": "ini", "sql": "sql", "css": "css", "scss": "scss",
        "xml": "xml", "plist": "xml", "txt": "text", "csv": "text", "tsv": "text",
        "lock": "text", "gradle": "groovy", "dart": "dart", "lua": "lua",
    ]

    /// 拡張子と中身から表示方法を推測する。
    public static func classify(fileName: String, data: Data) -> ContentKind {
        let ext = (fileName as NSString).pathExtension.lowercased()

        if imageExtensions.contains(ext) { return .image }
        if ext == "svg" { return .web }
        if ext == "html" || ext == "htm" || ext == "xhtml" { return .web }
        if ext == "md" || ext == "markdown" || ext == "mdown" { return .markdown }

        guard isProbablyText(data) else { return .binary }

        if let language = languages[ext] { return .code(language: language) }
        if ext.isEmpty || fileName.hasPrefix(".") { return .code(language: "text") }
        return .code(language: ext)
    }

    /// NUL バイトの有無と UTF-8 として読めるかでテキストかどうかを判定する。
    public static func isProbablyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let head = data.prefix(4096)
        if head.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// テキストとして読み出す (UTF-8 でなければ Latin-1 にフォールバック)。
    public static func text(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1)
    }
}
