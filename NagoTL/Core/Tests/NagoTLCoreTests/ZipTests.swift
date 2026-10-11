import Foundation
import XCTest
@testable import NagoTLCore

final class ZipTests: XCTestCase {
    /// make 스크립트(파이썬)와 같은 규칙으로 만든 본문
    static func sampleText(_ n: Int) -> [UInt8] {
        let words = ["manga", "번역", "말풍선", "ドドド", "page", "panel", "the", "of", "그리고", "テスト", "abc", "0123456789"]
        var s = 12345
        var parts: [String] = []
        var total = 0
        while total < n {
            s = (s * 1_103_515_245 + 12345) & 0x7FFF_FFFF
            let w = words[(s >> 16) % words.count]
            parts.append(w)
            total += w.utf8.count + 1
        }
        return Array(Array(parts.joined(separator: " ").utf8).prefix(n))
    }

    func testInflateDynamicAndFixed() throws {
        let expected = Self.sampleText(20000)
        for b64 in [ZipVectors.deflate1, ZipVectors.deflate9] {
            let raw = [UInt8](Data(base64Encoded: b64)!)
            XCTAssertEqual(try Inflate.inflate(raw), expected)
        }
        let small = [UInt8](Data(base64Encoded: ZipVectors.fixedSmall)!)
        XCTAssertEqual(String(decoding: try Inflate.inflate(small), as: UTF8.self), "hello hello hello world")
    }

    func testInflateStoredBlocks() throws {
        // 저장 블록 두 개(마지막 아님 + 마지막)
        let a = Array("abc".utf8), b = Array("defgh".utf8)
        var raw: [UInt8] = [0x00, 3, 0, 0xFC, 0xFF]
        raw += a
        raw += [0x01, 5, 0, 0xFA, 0xFF]
        raw += b
        XCTAssertEqual(try Inflate.inflate(raw), a + b)
    }

    func testCorruptInputThrows() {
        let raw = [UInt8](Data(base64Encoded: ZipVectors.deflate9)!)
        XCTAssertThrowsError(try Inflate.inflate(Array(raw.prefix(raw.count / 2))))
        XCTAssertThrowsError(try Inflate.inflate([0x07, 0xFF]))
    }

    func testReadZipImagesInNaturalOrder() throws {
        let zip = try ZipReader(data: Data(base64Encoded: ZipVectors.zip)!)
        let images = zip.imageEntries
        XCTAssertEqual(images.map(\.name), ["vol1/p1.png", "vol1/p2.jpg", "vol1/p10.jpg"])
        let text = Self.sampleText(20000)
        XCTAssertEqual([UInt8](try zip.extract(images[0])), Array(text.prefix(3000)))
        XCTAssertEqual([UInt8](try zip.extract(images[1])), Array(text.prefix(5000)))
        XCTAssertEqual(try zip.extract(images[2]), Data(repeating: UInt8(ascii: "J"), count: 100))
    }

    func testWriterRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.cbz")
        let w = try ZipWriter(url: url)
        var pages: [Data] = []
        for i in 1...12 {
            var bytes = [UInt8](repeating: 0, count: 1000 * i)
            for k in bytes.indices { bytes[k] = UInt8(truncatingIfNeeded: k * 7 + i) }
            pages.append(Data(bytes))
        }
        for (i, p) in pages.enumerated() { try w.add(name: String(format: "번역/%03d.jpg", i + 1), data: p) }
        try w.finish()
        let r = try ZipReader(url: url)
        XCTAssertEqual(r.imageEntries.count, 12)
        for (i, e) in r.imageEntries.enumerated() {
            XCTAssertEqual(e.name, String(format: "번역/%03d.jpg", i + 1))
            let d = try r.extract(e)
            XCTAssertEqual(d, pages[i])
            XCTAssertEqual(CRC32.checksum(d), e.crc)
        }
    }

    func testNaturalSort() {
        let names = ["p10.jpg", "p2.jpg", "p1.jpg", "P3.jpg", "cover.jpg", "p02a.jpg"]
        XCTAssertEqual(names.sorted(by: naturalLess), ["cover.jpg", "p1.jpg", "p2.jpg", "p02a.jpg", "P3.jpg", "p10.jpg"])
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
