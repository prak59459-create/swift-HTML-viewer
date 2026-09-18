import XCTest
@testable import GitHubViewerCore

final class ZipTests: XCTestCase {

    // MARK: - 書き出し

    func testRoundTrip() throws {
        let data = Zip.archive(files: ["a.txt": "あいう", "dir/b.txt": "かきく"])
        let entries = try Zip.entries(in: data)
        XCTAssertEqual(entries.map(\.path), ["a.txt", "dir/b.txt"])
        XCTAssertEqual(entries[0].text, "あいう")
        XCTAssertEqual(entries[1].text, "かきく")
    }

    func testEmptyArchive() throws {
        XCTAssertTrue(try Zip.entries(in: Zip.archive([])).isEmpty)
    }

    func testBinaryContent() throws {
        let bytes = Data((0..<256).map { UInt8($0) })
        let data = Zip.archive([ZipEntry(path: "x.bin", data: bytes)])
        XCTAssertEqual(try Zip.entries(in: data).first?.data, bytes)
    }

    func testEmptyFile() throws {
        let data = Zip.archive([ZipEntry(path: "empty.txt", data: Data())])
        let entries = try Zip.entries(in: data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].byteCount, 0)
    }

    func testModifiedDateIsKept() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Zip.archive([ZipEntry(path: "a", text: "x", modifiedAt: when)])
        let read = try Zip.entries(in: data).first?.modifiedAt
        XCTAssertNotNil(read)
        // MS-DOS の時刻は 2 秒きざみなので、そのぶんの差は許す。
        XCTAssertEqual(read!.timeIntervalSince1970, when.timeIntervalSince1970,
                       accuracy: 2)
    }

    func testLooksLikeZip() {
        XCTAssertTrue(Zip.looksLikeZip(Zip.archive(files: ["a": "b"])))
        XCTAssertFalse(Zip.looksLikeZip(Data("ただの文字".utf8)))
    }

    func testTextFilesOnly() throws {
        let data = Zip.archive([ZipEntry(path: "a.txt", text: "文字"),
                                ZipEntry(path: "b.bin",
                                         data: Data([0x00, 0x01, 0x02, 0xFF]))])
        let files = try Zip.textFiles(in: data)
        XCTAssertEqual(files.keys.sorted(), ["a.txt"])
    }

    // MARK: - 壊れているもの

    func testNotAZip() {
        XCTAssertThrowsError(try Zip.entries(in: Data("これは zip ではありません".utf8))) {
            XCTAssertEqual($0 as? ZipError, .notAZip)
        }
    }

    func testTooShort() {
        XCTAssertThrowsError(try Zip.entries(in: Data([0x50, 0x4B])))
    }

    func testTruncatedArchive() {
        let data = Zip.archive(files: ["a.txt": "あいうえお"])
        let cut = data.prefix(data.count - 10)
        XCTAssertThrowsError(try Zip.entries(in: Data(cut)))
    }

    // MARK: - 本物の zip との突き合わせ

    /// `zip -9` が作った deflate 圧縮の書庫。
    ///
    /// 中身は `a.txt` (72 バイト) と `b.txt` (12 バイト)。
    static let realArchive = Data(base64Encoded: """
    UEsDBBQAAgAIAPe6MV2NzclpNgAAAEgAAAAFABwAYS50eHRVVAkAA4J2rGqCdqxqdXgLAAEEAAAA\
    AAQAAAAAbcbBCQAhDATAv1Vsa3LukUAwhy6kfS3gYB5jjEhUrhhN5htXh7iF14Mol2HxYxfHT56c\
    4lQ7UEsDBAoAAgAAAPe6MV2C/3LkDAAAAAwAAAAFABwAYi50eHRVVAkAA4J2rGqCdqxqdXgLAAEE\
    AAAAAAQAAAAAc2Vjb25kIGZpbGUKUEsBAh4DFAACAAgA97oxXY3NyWk2AAAASAAAAAUAGAAAAAAA\
    AQAAAKSBAAAAAGEudHh0VVQFAAOCdqxqdXgLAAEEAAAAAAQAAAAAUEsBAh4DCgACAAAA97oxXYL/\
    cuQMAAAADAAAAAUAGAAAAAAAAQAAAKSBdQAAAGIudHh0VVQFAAOCdqxqdXgLAAEEAAAAAAQAAAAA\
    UEsFBgAAAAACAAIAlgAAAMAAAAAAAA==
    """)!

    func testReadsRealDeflateArchive() throws {
        let entries = try Zip.entries(in: ZipTests.realArchive)
        XCTAssertEqual(entries.map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(entries.first { $0.path == "a.txt" }?.text,
                       "hello world\n"
                           + "this is a test file with repeated repeated repeated content\n")
        XCTAssertEqual(entries.first { $0.path == "b.txt" }?.text, "second file\n")
    }

    func testRealArchiveKeepsTheExactBytes() throws {
        let entries = try Zip.entries(in: ZipTests.realArchive)
        let a = entries.first { $0.path == "a.txt" }
        XCTAssertEqual(a?.byteCount, 72)
        // 展開したものの検査値が、zip の中の値と合うことは
        // 読み込みの中で確かめている。ここでは長さで確かめる。
        XCTAssertEqual(entries.first { $0.path == "b.txt" }?.byteCount, 12)
    }
}

final class InflateTests: XCTestCase {
    /// 無圧縮の塊 (type 0)。
    func testStoredBlock() throws {
        // 最終ブロック + type 0、長さ 3、補数、"abc"。
        let input: [UInt8] = [0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63]
        let output = try Inflate.decompress(input)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "abc")
    }

    func testTruncatedInputThrows() {
        XCTAssertThrowsError(try Inflate.decompress([0x01, 0x03, 0x00]))
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try Inflate.decompress([]))
    }

    func testFixedHuffmanTablesAreBuilt() {
        // 表が作れること (作れなければ落ちる)。
        XCTAssertEqual(Inflate.Huffman.fixedLiterals.symbols.count, 288)
        XCTAssertEqual(Inflate.Huffman.fixedDistances.symbols.count, 30)
    }
}

final class CRC32Tests: XCTestCase {
    func testKnownValues() {
        // よく知られた検査値。
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("a".utf8)), 0xE8B7_BE43)
    }

    func testDifferentDataGivesDifferentValues() {
        XCTAssertNotEqual(CRC32.checksum(Data("abc".utf8)),
                          CRC32.checksum(Data("abd".utf8)))
    }
}
