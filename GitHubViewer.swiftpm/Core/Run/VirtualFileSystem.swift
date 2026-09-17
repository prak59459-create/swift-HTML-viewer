import Foundation

/// プログラムから読み書きできる、メモリの中だけのファイル置き場。
///
/// 本物のファイルには触らせたくないので、`open` などの組み込み関数は
/// すべてここを通す。
public final class VirtualFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    /// 1 ファイルの上限。
    public let maximumFileBytes: Int
    /// 全体の上限。
    public let maximumTotalBytes: Int

    public init(files: [String: String] = [:], maximumFileBytes: Int = 1 << 20,
                maximumTotalBytes: Int = 8 << 20) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        for (name, text) in files { storage[Self.normalize(name)] = Data(text.utf8) }
    }

    /// `./a.txt` と `a.txt` を同じものとして扱う。
    static func normalize(_ path: String) -> String {
        var clean = path
        while clean.hasPrefix("./") { clean.removeFirst(2) }
        while clean.hasPrefix("/") { clean.removeFirst() }
        return clean
    }

    public var fileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    public var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.reduce(0) { $0 + $1.count }
    }

    public func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.normalize(path)] != nil
    }

    public func data(at path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.normalize(path)]
    }

    public func read(_ path: String) -> String? {
        data(at: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 書き込む。上限を超えたら false。
    @discardableResult
    public func write(_ text: String, to path: String) -> Bool {
        write(Data(text.utf8), to: path)
    }

    @discardableResult
    public func write(_ data: Data, to path: String) -> Bool {
        guard data.count <= maximumFileBytes else { return false }
        let key = Self.normalize(path)
        lock.lock()
        defer { lock.unlock() }
        let others = storage.reduce(0) { $0 + ($1.key == key ? 0 : $1.value.count) }
        guard others + data.count <= maximumTotalBytes else { return false }
        storage[key] = data
        return true
    }

    /// 末尾に足す。
    @discardableResult
    public func append(_ text: String, to path: String) -> Bool {
        let key = Self.normalize(path)
        let existing = data(at: key) ?? Data()
        return write(existing + Data(text.utf8), to: key)
    }

    @discardableResult
    public func remove(_ path: String) -> Bool {
        let key = Self.normalize(path)
        lock.lock()
        defer { lock.unlock() }
        return storage.removeValue(forKey: key) != nil
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    /// 中身をまとめて取り出す (保存や表示用)。
    public func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: String] = [:]
        for (name, data) in storage { result[name] = String(decoding: data, as: UTF8.self) }
        return result
    }

    /// 行の一覧 (`readlines` 相当)。
    public func lines(at path: String) -> [String]? {
        guard let text = read(path) else { return nil }
        var parts = text.components(separatedBy: "\n")
        // 末尾の改行で空行が増えるのを避ける。
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }
}
