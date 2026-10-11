import Foundation
import XCTest
@testable import NagoTLCore

/// 이상한 입력(그림 밖 상자, 0 크기, 잡음 그림, 깨진 ZIP, 빈 번역…)에도 죽지 않는지
final class FuzzTests: XCTestCase {
    func randomBitmap(_ rnd: inout SeededRandom) -> Bitmap {
        let w = rnd.int(1...260), h = rnd.int(1...260)
        var cv = Canvas(width: w, height: h, fill: RGBA(UInt8(rnd.int(0...255)), UInt8(rnd.int(0...255)), UInt8(rnd.int(0...255))))
        switch rnd.int(0...3) {
        case 0:
            // 잡음
            for y in 0..<h {
                for x in 0..<w { cv.dot(x, y, RGBA(UInt8(rnd.int(0...255)), UInt8(rnd.int(0...255)), UInt8(rnd.int(0...255)))) }
            }
        case 1:
            // 말풍선 + 글자
            cv.ellipse(cx: Double(w) / 2, cy: Double(h) / 2, rx: Double(w) / 2.5 + 1, ry: Double(h) / 2.5 + 1,
                       outline: 3, line: .black, fill: .white)
            if w > 40 && h > 40 { cv.verticalText(right: w / 2 + 12, top: h / 3, columns: [2, 1], size: 10, seed: rnd.int(0...99)) }
        case 2:
            // 선들
            for _ in 0..<rnd.int(0...20) {
                cv.line(rnd.int(0...w), rnd.int(0...h), rnd.int(0...w), rnd.int(0...h), width: rnd.int(1...4), .black)
            }
        default:
            break
        }
        return cv.bmp
    }

    func testRefineEraseLayoutNeverCrash() {
        // NAGOTL_FUZZ=반복수 로 더 오래 돌릴 수 있다
        let rounds = Int(ProcessInfo.processInfo.environment["NAGOTL_FUZZ"] ?? "") ?? 160
        var rnd = SeededRandom(UInt64(ProcessInfo.processInfo.environment["NAGOTL_FUZZ_SEED"] ?? "") ?? 2024)
        let m = ApproxMetrics()
        let texts = ["", " ", "가", "아주아주아주아주아주아주긴낱말이라서한줄에안들어감", "줄\n바꿈\n\n여럿", "!!!", "…", "a b c d e f g",
                     "😀 이모지", "  앞뒤 띄어쓰기  "]
        for _ in 0..<rounds {
            let bmp = randomBitmap(&rnd)
            var blocks: [PageBlock] = []
            for _ in 0..<rnd.int(0...4) {
                let box = IRect(x: rnd.int(-40...bmp.width + 20), y: rnd.int(-40...bmp.height + 20),
                                w: rnd.int(-5...bmp.width + 40), h: rnd.int(-5...bmp.height + 40))
                blocks.append(PageBlock(box: box, kind: BlockKind.allCases[rnd.int(0...BlockKind.allCases.count - 1)]))
            }
            let refined = Refiner.refinePage(bmp, blocks: blocks)
            XCTAssertEqual(refined.count, blocks.count)
            var out = bmp
            Refiner.erase(&out, refined)
            XCTAssertEqual(out.pixels.count, bmp.pixels.count)
            for (k, r) in refined.enumerated() {
                let placed = Typesetter.place(texts[(k + rnd.int(0...9)) % texts.count], for: r, kind: blocks[k].kind, metrics: m)
                for line in placed.layout.lines {
                    XCTAssertFalse(line.x.isNaN || line.y.isNaN || line.width.isNaN)
                }
                XCTAssertTrue(placed.layout.fontSize.isFinite)
            }
        }
    }

    func testShapesWithHolesAndEmptyRows() {
        // 가운데가 끊긴 모양(행이 비는 곳), 아주 작은 모양
        var r = RegionMask(rect: IRect(x: 0, y: 0, w: 120, h: 200))
        for y in 0..<200 where !(80..<120).contains(y) {
            for x in 10..<110 { r.put(x, y, true) }
        }
        for text in ["두 덩어리로 나뉜 말풍선에 넣는 꽤 긴 번역문입니다", "가", ""] {
            let l = Typesetter.layout(text, shape: LayoutShape(region: r), maxSize: 30, minSize: 8, metrics: ApproxMetrics())
            for line in l.lines where !line.text.isEmpty {
                let y0 = line.y + (l.lineHeight - l.fontSize) / 2
                if !l.overflow { XCTAssertFalse((80.0..<120.0).contains(y0 + l.fontSize / 2), "줄이 빈 곳에: \(line.text)") }
            }
        }
        var tiny = RegionMask(rect: IRect(x: 5, y: 5, w: 3, h: 3))
        tiny.put(6, 6, true)
        let l = Typesetter.layout("안녕하세요", shape: LayoutShape(region: tiny), maxSize: 20, minSize: 8, metrics: ApproxMetrics())
        XCTAssertTrue(l.overflow)
        XCTAssertFalse(l.lines.isEmpty)
    }

    func testCorruptZipsThrowNotCrash() {
        let good = [UInt8](Data(base64Encoded: ZipVectors.zip)!)
        var rnd = SeededRandom(99)
        for i in 0..<300 {
            var bytes = good
            switch i % 3 {
            case 0:
                for _ in 0..<rnd.int(1...12) { bytes[rnd.int(0...bytes.count - 1)] = UInt8(rnd.int(0...255)) }
            case 1:
                bytes = Array(bytes.prefix(rnd.int(0...bytes.count)))
            default:
                bytes = (0..<rnd.int(0...400)).map { _ in UInt8(rnd.int(0...255)) }
            }
            if let z = try? ZipReader(data: Data(bytes)) {
                for e in z.entries { _ = try? z.extract(e) }
            }
        }
        var rnd2 = SeededRandom(5)
        for _ in 0..<300 {
            let junk = (0..<rnd2.int(0...300)).map { _ in UInt8(rnd2.int(0...255)) }
            _ = try? Inflate.inflate(junk)
        }
    }

    func testTilerOddSizes() {
        for (w, h) in [(1, 1), (1, 10000), (800, 1921), (800, 1922), (700, 30000), (3000, 100)] {
            let tiles = Tiler.tiles(width: w, height: h)
            XCTAssertFalse(tiles.isEmpty)
            XCTAssertEqual(tiles.first?.y, 0)
            XCTAssertEqual(tiles.last?.maxY, h)
            for t in tiles { XCTAssertGreaterThan(t.h, 0) }
        }
    }
}
