import Foundation

// MARK: - 173. 画像のメタ情報

/// 画像から読み取れたこと。
public struct ImageInfo: Equatable, Sendable {
    public var format: String
    public var width: Int
    public var height: Int
    public var byteCount: Int
    /// 色の深さ (分かれば)。
    public var bitDepth: Int?
    /// アニメーションするか。
    public var isAnimated: Bool

    public init(format: String, width: Int, height: Int, byteCount: Int,
                bitDepth: Int? = nil, isAnimated: Bool = false) {
        self.format = format
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.bitDepth = bitDepth
        self.isAnimated = isAnimated
    }

    /// 「1024 × 768」。
    public var sizeText: String { "\(width) × \(height)" }

    /// 縦横の比。
    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 0
    }

    /// 画素の数。
    public var pixelCount: Int { width * height }

    /// 「PNG · 1024 × 768 · 240 KB」。
    public var summary: String {
        var parts = [format, sizeText, OfflineCache.sizeText(byteCount)]
        if isAnimated { parts.append("アニメーション") }
        return parts.joined(separator: " · ")
    }
}

/// 画像のヘッダだけを読んで、大きさなどを調べる。
///
/// 画像を展開しないので軽く、Linux でも同じように動く。
public enum ImageInspector {

    public static func info(from data: Data) -> ImageInfo? {
        let bytes = [UInt8](data.prefix(1024))
        guard bytes.count >= 8 else { return nil }

        if let info = png(bytes, byteCount: data.count) { return info }
        if let info = gif(bytes, byteCount: data.count) { return info }
        if let info = jpeg([UInt8](data), byteCount: data.count) { return info }
        if let info = bmp(bytes, byteCount: data.count) { return info }
        if let info = webp(bytes, byteCount: data.count) { return info }
        if let info = svg(data) { return info }
        return nil
    }

    static func png(_ bytes: [UInt8], byteCount: Int) -> ImageInfo? {
        guard bytes.count >= 26,
              Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        else { return nil }
        // IHDR は 16 バイト目から幅・高さ (ビッグエンディアン)。
        let width = int32(bytes, at: 16)
        let height = int32(bytes, at: 20)
        return ImageInfo(format: "PNG", width: width, height: height,
                         byteCount: byteCount, bitDepth: Int(bytes[24]),
                         isAnimated: containsChunk(bytes, name: "acTL"))
    }

    static func gif(_ bytes: [UInt8], byteCount: Int) -> ImageInfo? {
        guard bytes.count >= 10, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46
        else { return nil }
        // 幅と高さはリトルエンディアンの 2 バイト。
        let width = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let height = Int(bytes[8]) | (Int(bytes[9]) << 8)
        return ImageInfo(format: "GIF", width: width, height: height,
                         byteCount: byteCount, isAnimated: true)
    }

    static func jpeg(_ bytes: [UInt8], byteCount: Int) -> ImageInfo? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 9 < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            // SOF0〜SOF15 (ただし 0xC4/0xC8/0xCC は別のもの)。
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8,
               marker != 0xCC {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return ImageInfo(format: "JPEG", width: width, height: height,
                                 byteCount: byteCount, bitDepth: Int(bytes[index + 4]))
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length > 0 else { break }
            index += 2 + length
        }
        return nil
    }

    static func bmp(_ bytes: [UInt8], byteCount: Int) -> ImageInfo? {
        guard bytes.count >= 26, bytes[0] == 0x42, bytes[1] == 0x4D else { return nil }
        let width = littleInt32(bytes, at: 18)
        let height = abs(littleInt32(bytes, at: 22))
        return ImageInfo(format: "BMP", width: width, height: height,
                         byteCount: byteCount)
    }

    static func webp(_ bytes: [UInt8], byteCount: Int) -> ImageInfo? {
        guard bytes.count >= 30,
              Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
              Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] else { return nil }
        // VP8X なら 24 バイト目から 3 バイトずつ (1 を足した値)。
        if Array(bytes[12..<16]) == [0x56, 0x50, 0x38, 0x58] {
            let width = 1 + (Int(bytes[24]) | Int(bytes[25]) << 8 | Int(bytes[26]) << 16)
            let height = 1 + (Int(bytes[27]) | Int(bytes[28]) << 8 | Int(bytes[29]) << 16)
            return ImageInfo(format: "WebP", width: width, height: height,
                             byteCount: byteCount,
                             isAnimated: bytes[20] & 0x02 != 0)
        }
        // VP8 (可逆でない) は 26 バイト目から。
        if Array(bytes[12..<16]) == [0x56, 0x50, 0x38, 0x20] {
            let width = (Int(bytes[26]) | Int(bytes[27]) << 8) & 0x3FFF
            let height = (Int(bytes[28]) | Int(bytes[29]) << 8) & 0x3FFF
            return ImageInfo(format: "WebP", width: width, height: height,
                             byteCount: byteCount)
        }
        return ImageInfo(format: "WebP", width: 0, height: 0, byteCount: byteCount)
    }

    static func svg(_ data: Data) -> ImageInfo? {
        guard let text = String(data: data.prefix(4096), encoding: .utf8),
              text.contains("<svg") else { return nil }
        func attribute(_ name: String) -> Int? {
            guard let range = text.range(of: "\(name)=\"[0-9.]+\"",
                                         options: .regularExpression) else { return nil }
            let piece = text[range].components(separatedBy: "\"")
            return piece.count > 1 ? Int(Double(piece[1]) ?? 0) : nil
        }
        return ImageInfo(format: "SVG", width: attribute("width") ?? 0,
                         height: attribute("height") ?? 0, byteCount: data.count)
    }

    static func containsChunk(_ bytes: [UInt8], name: String) -> Bool {
        let target = Array(name.utf8)
        guard bytes.count > target.count else { return false }
        for index in 0...(bytes.count - target.count)
        where Array(bytes[index..<(index + target.count)]) == target {
            return true
        }
        return false
    }

    static func int32(_ bytes: [UInt8], at index: Int) -> Int {
        guard index + 3 < bytes.count else { return 0 }
        return Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
            | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
    }

    static func littleInt32(_ bytes: [UInt8], at index: Int) -> Int {
        guard index + 3 < bytes.count else { return 0 }
        let value = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
        // 上位ビットが立っていれば負の数。
        return value > Int(Int32.max) ? value - (1 << 32) : value
    }
}

// MARK: - 174 / 175. PDF と動画・音声

/// 見せ方の決め方。
public enum MediaKind: String, Equatable, Sendable {
    case image
    case pdf
    case video
    case audio
    case font
    case archive
    case other

    public var displayName: String {
        switch self {
        case .image: return "画像"
        case .pdf: return "PDF"
        case .video: return "動画"
        case .audio: return "音声"
        case .font: return "フォント"
        case .archive: return "書庫"
        case .other: return "その他"
        }
    }

    /// アプリの中で開けるか。
    public var isViewable: Bool {
        self == .image || self == .pdf || self == .video || self == .audio
            || self == .font
    }
}

/// ファイル名と中身から、どう見せるかを決める。
public enum MediaClassifier {

    public static func kind(fileName: String, data: Data? = nil) -> MediaKind {
        let suffix = (fileName.split(separator: ".").last.map(String.init) ?? "")
            .lowercased()
        switch suffix {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "tiff", "ico":
            return .image
        case "pdf": return .pdf
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff": return .audio
        case "ttf", "otf", "woff", "woff2", "ttc": return .font
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return .archive
        default: break
        }
        // 拡張子で分からなければ、中身の先頭で見る。
        guard let data, let guess = HexDump.fileTypeGuess(data) else { return .other }
        if guess.contains("画像") { return .image }
        if guess.contains("PDF") { return .pdf }
        if guess.contains("動画") { return .video }
        if guess.contains("音声") { return .audio }
        if guess.contains("フォント") { return .font }
        if guess.contains("ZIP") || guess.contains("gzip") { return .archive }
        return .other
    }

    /// PDF の枚数を数える (`/Type /Page` の数)。
    public static func pdfPageCount(_ data: Data) -> Int? {
        guard let text = latin1(data) else { return nil }
        guard text.hasPrefix("%PDF") else { return nil }
        // `/Type /Pages` (目次) は数えず、`/Type /Page` だけを数える。
        let count = text.components(separatedBy: "/Type").dropFirst().filter { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("/Page") && !trimmed.hasPrefix("/Pages")
        }.count
        return count > 0 ? count : nil
    }

    /// PDF の題名。
    public static func pdfTitle(_ data: Data) -> String? {
        guard let text = latin1(data, limit: 1 << 20),
              let range = text.range(of: #"/Title\s*\(([^)]*)\)"#,
                                     options: .regularExpression) else { return nil }
        let piece = String(text[range])
        guard let open = piece.firstIndex(of: "("),
              let close = piece.lastIndex(of: ")") else { return nil }
        let title = decodeTitle(String(piece[piece.index(after: open)..<close]))
        return title.isEmpty ? nil : title
    }

    /// 題名の文字コードを直す。
    ///
    /// バイトとして読んだものを、UTF-16BE (PDF の決まり) か UTF-8 として
    /// 読み直せるならそちらを使う。
    static func decodeTitle(_ latin1Text: String) -> String {
        let bytes = Data(latin1Text.unicodeScalars.map { UInt8($0.value & 0xFF) })
        if bytes.count >= 2, bytes[bytes.startIndex] == 0xFE,
           bytes[bytes.index(after: bytes.startIndex)] == 0xFF,
           let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: bytes, encoding: .utf8),
           text.unicodeScalars.contains(where: { !$0.isASCII }) {
            return text
        }
        return latin1Text
    }

    /// バイトを 1 つずつ文字として読む (Latin-1)。
    ///
    /// PDF やフォントのように、テキストとバイナリが混ざったものを
    /// 「文字として探す」ために使う。Latin-1 はバイトと文字が 1 対 1 なので、
    /// どんなバイト列でも必ず読めて、位置もずれない。
    /// (`String(data:encoding:.isoLatin1)` は Linux の Foundation では使えない。)
    static func latin1(_ data: Data, limit: Int? = nil) -> String? {
        let bytes = limit.map { data.prefix($0) } ?? data[...]
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }
}

// MARK: - 176. フォントのプレビュー

/// フォントから読み取れたこと。
public struct FontInfo: Equatable, Sendable {
    public var format: String
    /// 入っている字の数。
    public var glyphCount: Int?
    /// 名前 (取れれば)。
    public var familyName: String?
    public var byteCount: Int

    public init(format: String, glyphCount: Int? = nil, familyName: String? = nil,
                byteCount: Int) {
        self.format = format
        self.glyphCount = glyphCount
        self.familyName = familyName
        self.byteCount = byteCount
    }

    public var summary: String {
        var parts = [format]
        if let familyName { parts.append(familyName) }
        if let glyphCount { parts.append("\(glyphCount) 字") }
        parts.append(OfflineCache.sizeText(byteCount))
        return parts.joined(separator: " · ")
    }
}

/// フォントのヘッダを読む。
public enum FontInspector {

    /// プレビューに使う見本の文章。
    public static let sampleTexts: [String] = [
        "あいうえお かきくけこ さしすせそ",
        "アイウエオ カキクケコ サシスセソ",
        "日本語の見本 東京 京都 大阪",
        "The quick brown fox jumps over the lazy dog",
        "0123456789 !@#$%^&*()_+-=[]{}|;:'\",.<>/?",
        "iIlL1 oO0 rn m  ' \" ` ´"
    ]

    public static func info(from data: Data) -> FontInfo? {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 12 else { return nil }

        let format: String
        switch Array(bytes.prefix(4)) {
        case [0x77, 0x4F, 0x46, 0x46]: format = "WOFF"
        case [0x77, 0x4F, 0x46, 0x32]: format = "WOFF2"
        case [0x4F, 0x54, 0x54, 0x4F]: format = "OpenType (CFF)"
        case [0x74, 0x74, 0x63, 0x66]: format = "TrueType Collection"
        case [0x00, 0x01, 0x00, 0x00], [0x74, 0x72, 0x75, 0x65]: format = "TrueType"
        default: return nil
        }

        return FontInfo(format: format, glyphCount: glyphCount(data, format: format),
                        familyName: familyName(data), byteCount: data.count)
    }

    /// `maxp` テーブルから字の数を読む (TrueType / OpenType のみ)。
    static func glyphCount(_ data: Data, format: String) -> Int? {
        guard format.hasPrefix("TrueType") || format.hasPrefix("OpenType") else {
            return nil
        }
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }
        let tableCount = Int(bytes[4]) << 8 | Int(bytes[5])
        var offset = 12
        for _ in 0..<tableCount {
            guard offset + 16 <= bytes.count else { break }
            let tag = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            if tag == "maxp" {
                let tableOffset = ImageInspector.int32(bytes, at: offset + 8)
                guard tableOffset + 6 <= bytes.count else { return nil }
                return Int(bytes[tableOffset + 4]) << 8 | Int(bytes[tableOffset + 5])
            }
            offset += 16
        }
        return nil
    }

    /// 見つかった読める名前 (ざっくり)。
    static func familyName(_ data: Data) -> String? {
        guard let text = MediaClassifier.latin1(data, limit: 1 << 16) else { return nil }
        // name テーブルの中に ASCII で名前が入っていることが多い。
        // ヘッダ部分は飛ばしてから探す。
        let start = text.index(text.startIndex, offsetBy: Swift.min(64, text.count))
        let body = String(text[start...])
        guard let range = body.range(of: #"[A-Za-z][A-Za-z0-9 \-]{3,40}"#,
                                     options: .regularExpression) else { return nil }
        let name = String(body[range]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - 178. 巨大ファイルの遅延読み込み

/// 大きなファイルを、少しずつ見せるための区切り。
public struct ChunkedText: Equatable, Sendable {
    public var lines: [String]
    /// 一度に見せる行数。
    public var chunkSize: Int
    /// いま何行目まで見せているか。
    public private(set) var visibleCount: Int

    public init(text: String, chunkSize: Int = 2000) {
        self.lines = text.components(separatedBy: "\n")
        self.chunkSize = Swift.max(1, chunkSize)
        self.visibleCount = Swift.min(self.chunkSize, self.lines.count)
    }

    public var totalLines: Int { lines.count }
    public var hasMore: Bool { visibleCount < lines.count }
    public var remaining: Int { Swift.max(0, lines.count - visibleCount) }

    /// いま見せている部分。
    public var visibleText: String {
        lines.prefix(visibleCount).joined(separator: "\n")
    }

    /// もう 1 区切り見せる。
    public mutating func loadMore() {
        visibleCount = Swift.min(lines.count, visibleCount + chunkSize)
    }

    /// 全部見せる。
    public mutating func loadAll() { visibleCount = lines.count }

    /// ある行まで見せる。
    public mutating func reveal(line: Int) {
        guard line > visibleCount else { return }
        visibleCount = Swift.min(lines.count, line + chunkSize / 2)
    }

    /// 「2,000 / 120,000 行」。
    public var progressText: String {
        "\(RunFormatting.number(visibleCount)) / \(RunFormatting.number(totalLines)) 行"
    }

    /// そもそも区切って見せる必要があるか。
    public static func needsChunking(_ text: String, threshold: Int = 5000) -> Bool {
        var count = 0
        for character in text where character == "\n" {
            count += 1
            if count > threshold { return true }
        }
        return false
    }
}

// MARK: - 172. SQLite のテーブル閲覧

/// SQLite のファイルから読み取れたこと。
///
/// 中身を読むには SQLite を開く必要があるので、ここではヘッダだけを見て
/// 「本物か」「ページの大きさ」「テーブルらしき名前」を取り出す。
public struct SQLiteInfo: Equatable, Sendable {
    public var pageSize: Int
    public var pageCount: Int
    /// 見つかったテーブルの名前。
    public var tableNames: [String]
    public var byteCount: Int

    public init(pageSize: Int, pageCount: Int, tableNames: [String], byteCount: Int) {
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.tableNames = tableNames
        self.byteCount = byteCount
    }

    public var summary: String {
        "SQLite · \(tableNames.count) テーブル · \(OfflineCache.sizeText(byteCount))"
    }
}

public enum SQLiteInspector {
    static let magic = Array("SQLite format 3\0".utf8)

    public static func isSQLite(_ data: Data) -> Bool {
        Array(data.prefix(16)) == magic
    }

    public static func info(from data: Data) -> SQLiteInfo? {
        guard isSQLite(data), data.count >= 100 else { return nil }
        let bytes = [UInt8](data)
        // 16 バイト目からページの大きさ (1 なら 65536)。
        var pageSize = Int(bytes[16]) << 8 | Int(bytes[17])
        if pageSize == 1 { pageSize = 65536 }
        let pageCount = ImageInspector.int32(bytes, at: 28)
        return SQLiteInfo(pageSize: pageSize, pageCount: pageCount,
                          tableNames: tableNames(in: data), byteCount: data.count)
    }

    /// `CREATE TABLE 名前` の並びから名前を拾う。
    ///
    /// スキーマは平文で入っているので、これだけで一覧が作れる。
    public static func tableNames(in data: Data) -> [String] {
        guard let text = MediaClassifier.latin1(data, limit: 1 << 20) else { return [] }
        var names: [String] = []
        for part in text.components(separatedBy: "CREATE TABLE ").dropFirst() {
            var name = ""
            for character in part {
                if character == "(" || character == " " || character == "\n" { break }
                name.append(character)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[] "))
            guard !name.isEmpty, !names.contains(name),
                  !name.hasPrefix("sqlite_") else { continue }
            names.append(name)
        }
        return names
    }
}
