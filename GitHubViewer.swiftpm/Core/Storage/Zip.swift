import Foundation

// MARK: - 219. zip の読み書き

/// zip の中の 1 ファイル。
public struct ZipEntry: Identifiable, Equatable, Sendable {
    public var path: String
    public var data: Data
    /// 更新日時。
    public var modifiedAt: Date?

    public var id: String { path }

    public init(path: String, data: Data, modifiedAt: Date? = nil) {
        self.path = path
        self.data = data
        self.modifiedAt = modifiedAt
    }

    public init(path: String, text: String, modifiedAt: Date? = nil) {
        self.init(path: path, data: Data(text.utf8), modifiedAt: modifiedAt)
    }

    public var text: String? { ContentClassifier.text(from: data) }
    public var byteCount: Int { data.count }
}

public enum ZipError: LocalizedError, Equatable {
    case notAZip
    case damaged(String)
    case unsupportedCompression(Int)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "zip ファイルではないようです。"
        case .damaged(let detail): return "zip を読めませんでした: \(detail)"
        case .unsupportedCompression(let method):
            return "この圧縮方式 (\(method)) には対応していません。"
        }
    }
}

/// zip を読み書きする。
///
/// 書き出しは無圧縮 (store)。読み込みは無圧縮と deflate に対応する。
public enum Zip {

    // MARK: - 書き出し

    /// ファイルをまとめて zip にする。
    public static func archive(_ entries: [ZipEntry]) -> Data {
        var output = Data()
        var directory = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(output.count)
            let name = Array(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let (time, date) = dosDateTime(entry.modifiedAt ?? Date())

            // ローカルヘッダ。
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.append(uint16(20))                 // 必要な版
            output.append(uint16(0))                  // フラグ
            output.append(uint16(0))                  // 無圧縮
            output.append(uint16(time))
            output.append(uint16(date))
            output.append(uint32(crc))
            output.append(uint32(UInt32(entry.data.count)))
            output.append(uint32(UInt32(entry.data.count)))
            output.append(uint16(UInt16(name.count)))
            output.append(uint16(0))                  // 追加データなし
            output.append(contentsOf: name)
            output.append(entry.data)
        }

        // 中央ディレクトリ。
        for (index, entry) in entries.enumerated() {
            let name = Array(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let (time, date) = dosDateTime(entry.modifiedAt ?? Date())

            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(uint16(20))              // 作った版
            directory.append(uint16(20))              // 必要な版
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(time))
            directory.append(uint16(date))
            directory.append(uint32(crc))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint16(UInt16(name.count)))
            directory.append(uint16(0))               // 追加データ
            directory.append(uint16(0))               // コメント
            directory.append(uint16(0))               // ディスク番号
            directory.append(uint16(0))               // 内部属性
            directory.append(uint32(0))               // 外部属性
            directory.append(uint32(UInt32(offsets[index])))
            directory.append(contentsOf: name)
        }

        let directoryOffset = output.count
        output.append(directory)

        // 終わりの印。
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.append(uint16(0))
        output.append(uint16(0))
        output.append(uint16(UInt16(entries.count)))
        output.append(uint16(UInt16(entries.count)))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(UInt32(directoryOffset)))
        output.append(uint16(0))                      // コメントなし
        return output
    }

    /// ファイル名 → 中身 から作る。
    public static func archive(files: [String: String],
                               modifiedAt: Date? = nil) -> Data {
        archive(files.keys.sorted().map {
            ZipEntry(path: $0, text: files[$0] ?? "", modifiedAt: modifiedAt)
        })
    }

    // MARK: - 読み込み

    /// zip を開く。
    public static func entries(in data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notAZip }

        // 終わりの印を後ろから探す。
        var endIndex: Int?
        var cursor = bytes.count - 22
        let lowest = Swift.max(0, bytes.count - 22 - 65536)
        while cursor >= lowest {
            if bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
               bytes[cursor + 2] == 0x05, bytes[cursor + 3] == 0x06 {
                endIndex = cursor
                break
            }
            cursor -= 1
        }
        guard let end = endIndex else { throw ZipError.notAZip }

        let count = Int(read16(bytes, end + 10))
        var offset = Int(read32(bytes, end + 16))
        var result: [ZipEntry] = []

        for _ in 0..<count {
            guard offset + 46 <= bytes.count else {
                throw ZipError.damaged("中央ディレクトリが短すぎます")
            }
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x4B,
                  bytes[offset + 2] == 0x01, bytes[offset + 3] == 0x02 else {
                throw ZipError.damaged("中央ディレクトリの印が違います")
            }
            let method = Int(read16(bytes, offset + 10))
            let time = read16(bytes, offset + 12)
            let date = read16(bytes, offset + 14)
            let compressedSize = Int(read32(bytes, offset + 20))
            let uncompressedSize = Int(read32(bytes, offset + 24))
            let nameLength = Int(read16(bytes, offset + 28))
            let extraLength = Int(read16(bytes, offset + 30))
            let commentLength = Int(read16(bytes, offset + 32))
            let localOffset = Int(read32(bytes, offset + 42))

            guard offset + 46 + nameLength <= bytes.count else {
                throw ZipError.damaged("名前が読めません")
            }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)],
                              as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // フォルダは飛ばす。
            if name.hasSuffix("/") { continue }

            // ローカルヘッダから中身の位置を求める。
            guard localOffset + 30 <= bytes.count else {
                throw ZipError.damaged("中身の位置が範囲外です")
            }
            let localNameLength = Int(read16(bytes, localOffset + 26))
            let localExtraLength = Int(read16(bytes, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= bytes.count else {
                throw ZipError.damaged("中身が途中で切れています")
            }
            let payload = Array(bytes[start..<(start + compressedSize)])

            let content: Data
            switch method {
            case 0:
                content = Data(payload)
            case 8:
                content = Data(try Inflate.decompress(payload,
                                                      expectedSize: uncompressedSize))
            default:
                throw ZipError.unsupportedCompression(method)
            }

            result.append(ZipEntry(path: name, data: content,
                                   modifiedAt: parseDosDateTime(time: time, date: date)))
        }
        return result
    }

    /// 文字として読めるものだけを取り出す。
    public static func textFiles(in data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in try entries(in: data) {
            guard let text = entry.text else { continue }
            result[entry.path] = text
        }
        return result
    }

    /// zip らしいか。
    public static func looksLikeZip(_ data: Data) -> Bool {
        Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
            || Array(data.prefix(4)) == [0x50, 0x4B, 0x05, 0x06]
    }

    // MARK: - 数の読み書き

    static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    static func read16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        guard index + 1 < bytes.count else { return 0 }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    static func read32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index + 3 < bytes.count else { return 0 }
        return UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
    }

    /// MS-DOS の日時に直す。
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = Swift.max(1980, parts.year ?? 1980) - 1980
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = (parts.second ?? 0) / 2
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1

        let timeValue: Int = (hour << 11) | (minute << 5) | second
        let dateValue: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: timeValue),
                UInt16(truncatingIfNeeded: dateValue))
    }

    static func parseDosDateTime(time: UInt16, date: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var parts = DateComponents()
        parts.year = Int(date >> 9) + 1980
        parts.month = Int((date >> 5) & 0x0F)
        parts.day = Int(date & 0x1F)
        parts.hour = Int(time >> 11)
        parts.minute = Int((time >> 5) & 0x3F)
        parts.second = Int(time & 0x1F) * 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: parts)
    }
}

// MARK: - CRC32

/// zip が中身の確かめに使う検査値。
public enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}

// MARK: - deflate の展開

/// zip の中でよく使われる deflate を展開する。
///
/// 圧縮はしない (書き出しは無圧縮)。読むときだけ必要なので、
/// RFC 1951 の展開だけを実装している。
public enum Inflate {

    public static func decompress(_ input: [UInt8],
                                  expectedSize: Int = 0) throws -> [UInt8] {
        var reader = BitReader(input)
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize > 0 ? expectedSize : input.count * 4)

        while true {
            let isFinal = try reader.bit() == 1
            let type = try reader.bits(2)

            switch type {
            case 0:
                // 無圧縮。
                reader.alignToByte()
                let length = Int(try reader.bits(16))
                _ = try reader.bits(16)          // 長さの補数
                for _ in 0..<length { output.append(UInt8(try reader.bits(8))) }

            case 1:
                try inflateBlock(&reader, &output, lengths: Huffman.fixedLiterals,
                                 distances: Huffman.fixedDistances)

            case 2:
                let (literals, distances) = try readDynamicTables(&reader)
                try inflateBlock(&reader, &output, lengths: literals,
                                 distances: distances)

            default:
                throw ZipError.damaged("deflate の種類が不正です")
            }

            if isFinal { break }
        }
        return output
    }

    /// 1 つの塊を展開する。
    static func inflateBlock(_ reader: inout BitReader, _ output: inout [UInt8],
                             lengths: Huffman, distances: Huffman) throws {
        while true {
            let symbol = try lengths.decode(&reader)
            if symbol == 256 { return }
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            guard symbol <= 285 else { throw ZipError.damaged("記号が不正です") }
            let lengthIndex = symbol - 257
            let length = Int(lengthBase[lengthIndex])
                + Int(try reader.bits(lengthExtra[lengthIndex]))

            let distanceSymbol = try distances.decode(&reader)
            guard distanceSymbol < 30 else { throw ZipError.damaged("距離が不正です") }
            let distance = Int(distanceBase[distanceSymbol])
                + Int(try reader.bits(distanceExtra[distanceSymbol]))
            guard distance <= output.count else {
                throw ZipError.damaged("距離が範囲外です")
            }

            let start = output.count - distance
            for offset in 0..<length { output.append(output[start + offset]) }
        }
    }

    /// 塊ごとの表を読む。
    static func readDynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let literalCount = Int(try reader.bits(5)) + 257
        let distanceCount = Int(try reader.bits(5)) + 1
        let codeCount = Int(try reader.bits(4)) + 4

        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeCount {
            codeLengths[order[index]] = Int(try reader.bits(3))
        }
        let codeTable = try Huffman(lengths: codeLengths)

        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            let symbol = try codeTable.decode(&reader)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let last = lengths.last else {
                    throw ZipError.damaged("繰り返す前の値がありません")
                }
                let times = Int(try reader.bits(2)) + 3
                lengths += Array(repeating: last, count: times)
            case 17:
                lengths += Array(repeating: 0, count: Int(try reader.bits(3)) + 3)
            case 18:
                lengths += Array(repeating: 0, count: Int(try reader.bits(7)) + 11)
            default:
                throw ZipError.damaged("表の記号が不正です")
            }
        }
        guard lengths.count >= literalCount + distanceCount else {
            throw ZipError.damaged("表が短すぎます")
        }
        return (try Huffman(lengths: Array(lengths[0..<literalCount])),
                try Huffman(lengths: Array(lengths[literalCount..<(literalCount
                    + distanceCount)])))
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23,
                                     27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                                     163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
                                       129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                                       3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// ビットを 1 つずつ読む。
    struct BitReader {
        let bytes: [UInt8]
        var byteIndex = 0
        var bitIndex = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func bit() throws -> Int {
            guard byteIndex < bytes.count else {
                throw ZipError.damaged("データが途中で終わりました")
            }
            let value = (Int(bytes[byteIndex]) >> bitIndex) & 1
            bitIndex += 1
            if bitIndex == 8 {
                bitIndex = 0
                byteIndex += 1
            }
            return value
        }

        /// 下位ビットから順に読む。
        mutating func bits(_ count: Int) throws -> Int {
            var value = 0
            for index in 0..<count {
                value |= (try bit()) << index
            }
            return value
        }

        mutating func alignToByte() {
            if bitIndex > 0 {
                bitIndex = 0
                byteIndex += 1
            }
        }
    }

    /// ハフマン符号の表。
    struct Huffman {
        /// 符号の長さごとの、最初の符号と記号の並び。
        var counts: [Int]
        var symbols: [Int]

        init(lengths: [Int]) throws {
            counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[length] += 1 }

            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 {
                offsets[length + 1] = offsets[length] + counts[length]
            }
            symbols = [Int](repeating: 0, count: lengths.filter { $0 > 0 }.count)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1...15 {
                code |= try reader.bit()
                let count = counts[length]
                if code - first < count {
                    return symbols[index + (code - first)]
                }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw ZipError.damaged("符号を読めませんでした")
        }

        /// 決まった表 (type 1) の文字。
        static let fixedLiterals: Huffman = {
            var lengths = [Int](repeating: 8, count: 288)
            for index in 144..<256 { lengths[index] = 9 }
            for index in 256..<280 { lengths[index] = 7 }
            return try! Huffman(lengths: lengths)
        }()

        /// 決まった表の距離。
        static let fixedDistances: Huffman = {
            try! Huffman(lengths: [Int](repeating: 5, count: 30))
        }()
    }
}
