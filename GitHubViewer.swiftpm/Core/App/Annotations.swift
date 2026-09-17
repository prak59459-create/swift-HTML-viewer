import Foundation

// MARK: - 189. Apple Pencil でのメモ

/// 手書きや文字のメモ 1 つ。
public struct Annotation: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Equatable, Codable, Sendable {
        /// 手書き。
        case drawing
        /// 打ち込んだ文字。
        case note
        /// 線を引いた場所。
        case highlight

        public var displayName: String {
            switch self {
            case .drawing: return "手書き"
            case .note: return "メモ"
            case .highlight: return "ハイライト"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// どのファイルに付けたか。
    public var fileKey: String
    /// どの行に付けたか。
    public var line: Int
    /// 文字のメモの中身。
    public var text: String
    /// 手書きのデータ (PencilKit が作るもの)。
    public var drawingData: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: Kind, fileKey: String, line: Int,
                text: String = "", drawingData: Data? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.fileKey = fileKey
        self.line = line
        self.text = text
        self.drawingData = drawingData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (drawingData?.isEmpty ?? true)
    }

    /// 一覧に出す 1 行。
    public var summary: String {
        let body = text.components(separatedBy: "\n").first ?? ""
        if !body.isEmpty { return body }
        return kind == .drawing ? "手書きのメモ" : "(空のメモ)"
    }
}

/// メモの入れ物。
public final class AnnotationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: Annotation] = [:]
    private let persist: (@Sendable (Data) -> Void)?

    public init(annotations: [Annotation] = [],
                persist: (@Sendable (Data) -> Void)? = nil) {
        for annotation in annotations { items[annotation.id] = annotation }
        self.persist = persist
    }

    public convenience init(json: Data?, persist: (@Sendable (Data) -> Void)? = nil) {
        let loaded = json.flatMap {
            try? JSONDecoder().decode([Annotation].self, from: $0)
        }
        self.init(annotations: loaded ?? [], persist: persist)
    }

    public var all: [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { ($0.fileKey, $0.line) < ($1.fileKey, $1.line) }
    }

    /// あるファイルのメモ。
    public func annotations(forFile key: String) -> [Annotation] {
        all.filter { $0.fileKey == key }
    }

    /// ある行のメモ。
    public func annotations(forFile key: String, line: Int) -> [Annotation] {
        all.filter { $0.fileKey == key && $0.line == line }
    }

    /// メモの付いている行。
    public func lines(forFile key: String) -> [Int] {
        Array(Set(annotations(forFile: key).map(\.line))).sorted()
    }

    public func save(_ annotation: Annotation) {
        lock.lock()
        if annotation.isEmpty {
            items[annotation.id] = nil
        } else {
            var updated = annotation
            updated.updatedAt = Date()
            items[updated.id] = updated
        }
        let snapshot = Array(items.values)
        lock.unlock()
        write(snapshot)
    }

    public func remove(id: UUID) {
        lock.lock()
        items[id] = nil
        let snapshot = Array(items.values)
        lock.unlock()
        write(snapshot)
    }

    /// あるファイルのメモを全部消す。
    @discardableResult
    public func removeAll(forFile key: String) -> Int {
        lock.lock()
        let targets = items.filter { $0.value.fileKey == key }
        for id in targets.keys { items[id] = nil }
        let snapshot = Array(items.values)
        lock.unlock()
        write(snapshot)
        return targets.count
    }

    public func removeAll() {
        lock.lock()
        items.removeAll()
        lock.unlock()
        write([])
    }

    /// 行を足したり消したりしたときに、メモの位置をずらす。
    public func shift(fileKey: String, afterLine line: Int, by delta: Int) {
        guard delta != 0 else { return }
        lock.lock()
        for (id, annotation) in items
        where annotation.fileKey == fileKey && annotation.line > line {
            var updated = annotation
            updated.line = Swift.max(1, annotation.line + delta)
            items[id] = updated
        }
        let snapshot = Array(items.values)
        lock.unlock()
        write(snapshot)
    }

    public func encoded() -> Data? {
        lock.lock()
        let snapshot = Array(items.values)
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }

    private func write(_ snapshot: [Annotation]) {
        guard let persist, let data = try? JSONEncoder().encode(snapshot) else { return }
        persist(data)
    }
}

// MARK: - 190. スクリブル (手書き入力)

/// 手書きで書いた文字を、どこに入れるか。
public enum Scribble {

    /// 書いた文字を入れた結果。
    public static func insert(_ recognized: String, into text: String,
                              at location: Int, length: Int = 0) -> EditResult {
        let cleaned = clean(recognized)
        return EditResult(location: location, length: length, replacement: cleaned,
                          selectionLocation: location + cleaned.utf16.count,
                          selectionLength: 0)
    }

    /// 手書きで入りがちな全角の記号を、半角に直す。
    ///
    /// 日本語の入力では全角になりやすく、そのままだとコードが通らない。
    public static func clean(_ text: String) -> String {
        var result = ""
        for character in text {
            result.append(replacements[character] ?? character)
        }
        return result
    }

    static let replacements: [Character: Character] = [
        "（": "(", "）": ")", "｛": "{", "｝": "}", "［": "[", "］": "]",
        "＜": "<", "＞": ">", "＝": "=", "＋": "+", "－": "-", "＊": "*",
        "／": "/", "％": "%", "！": "!", "？": "?", "＆": "&", "｜": "|",
        "＾": "^", "～": "~", "＠": "@", "＃": "#", "＄": "$", "＿": "_",
        "；": ";", "：": ":", "，": ",", "．": ".", "＂": "\"", "＇": "'",
        "｀": "`", "＼": "\\", "　": " "
    ]

    /// 直したところがあるか。
    public static func needsCleaning(_ text: String) -> Bool {
        text.contains { replacements[$0] != nil }
    }
}

// MARK: - 197 / 218. 端末とクラウドの置き場

/// ファイルを置く場所。
public enum StorageLocation: String, CaseIterable, Identifiable, Codable, Equatable,
                             Sendable {
    /// アプリの中だけ。
    case local
    /// iCloud Drive (ほかの端末からも見える)。
    case iCloud
    /// ファイル App から選んだ場所。
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return "この iPad の中"
        case .iCloud: return "iCloud Drive"
        case .files: return "ファイル App"
        }
    }

    /// ほかの端末からも見えるか。
    public var isShared: Bool { self == .iCloud }
}

/// 自分で作るプロジェクト 1 つ。
public struct LocalProject: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// ファイル名 → 中身。
    public var files: [String: String]
    /// 最初に開くファイル。
    public var entryFile: String?
    public var languageID: String?
    public var storage: StorageLocation
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, files: [String: String] = [:],
                entryFile: String? = nil, languageID: String? = nil,
                storage: StorageLocation = .local, createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.files = files
        self.entryFile = entryFile
        self.languageID = languageID
        self.storage = storage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var fileNames: [String] { files.keys.sorted() }
    public var byteCount: Int { files.values.reduce(0) { $0 + $1.utf8.count } }

    /// 実行できる形にする。
    public var runProject: RunProject? {
        guard let languageID, let entryFile, files[entryFile] != nil else { return nil }
        return RunProject(languageID: languageID, files: files, entryFile: entryFile)
    }

    /// テンプレートから作る。
    public static func fromTemplate(_ template: FileTemplate,
                                    name: String? = nil) -> LocalProject {
        LocalProject(name: name ?? template.name,
                     files: [template.fileName: template.body],
                     entryFile: template.fileName, languageID: template.languageID)
    }

    /// 「3 ファイル · 1.2 KB」。
    public var summary: String {
        "\(files.count) ファイル · \(OfflineCache.sizeText(byteCount))"
    }

    public mutating func setFile(_ name: String, text: String?) {
        if let text { files[name] = text } else { files[name] = nil }
        if entryFile == name, text == nil { entryFile = files.keys.sorted().first }
        updatedAt = Date()
    }

    public mutating func rename(file oldName: String, to newName: String) {
        guard let text = files[oldName], files[newName] == nil else { return }
        files[oldName] = nil
        files[newName] = text
        if entryFile == oldName { entryFile = newName }
        updatedAt = Date()
    }
}
