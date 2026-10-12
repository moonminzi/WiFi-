import Foundation
import XCTest
@testable import NagoTLCore

/// tools/make_test_pages.py로 만든 가짜 망가 페이지(정답 글자 마스크 포함)로 지우기·배치를 확인한다.
/// NAGOTL_FIXTURES=폴더 가 있을 때만 돈다. NAGOTL_PREVIEW=폴더 를 주면 지운 그림과 배치를 남긴다(눈으로 확인용).
final class FixtureTests: XCTestCase {
    struct PageJSON: Decodable {
        struct Block: Decodable {
            var kind: String
            var box: [Int]
            var source: String
        }
        var width: Int
        var height: Int
        var blocks: [Block]
    }

    static let sampleKorean = [
        "야, 기다려! 어디 가는 거야?", "오늘이야말로 결판을 내주마", "그런 건 몰라", "배고파…",
        "선생님! 큰일 났어요!", "정말 괜찮은 거야?", "웃기지 마!", "약속했잖아",
    ]

    func testFixturePages() throws {
        guard let dir = ProcessInfo.processInfo.environment["NAGOTL_FIXTURES"] else {
            throw XCTSkip("NAGOTL_FIXTURES 없음")
        }
        let preview = ProcessInfo.processInfo.environment["NAGOTL_PREVIEW"]
        var rnd = SeededRandom(42)
        for page in 0..<3 {
            let base = URL(fileURLWithPath: dir).appendingPathComponent("page\(page)")
            guard let bmp = Bitmap.load(raw: try Data(contentsOf: base.appendingPathExtension("rgba"))) else {
                return XCTFail("rgba")
            }
            let maskData = [UInt8](try Data(contentsOf: base.appendingPathExtension("mask")))
            let truth = Array(maskData[8...])
            let info = try JSONDecoder().decode(PageJSON.self, from: Data(contentsOf: base.appendingPathExtension("json")))
            // Claude 상자처럼 조금씩 어긋나게
            var blocks: [PageBlock] = []
            for b in info.blocks {
                let w = b.box[2], h = b.box[3]
                let jx = rnd.int(-(w / 10 + 6)...(w / 10 + 6)), jy = rnd.int(-(h / 10 + 6)...(h / 10 + 6))
                let jw = rnd.int(-(w / 10)...(w / 8 + 8)), jh = rnd.int(-(h / 10)...(h / 8 + 8))
                blocks.append(PageBlock(box: IRect(x: b.box[0] + jx, y: b.box[1] + jy, w: w + jw, h: h + jh),
                                        kind: BlockKind(rawValue: b.kind) ?? .other))
            }
            let refined = Refiner.refinePage(bmp, blocks: blocks)
            var out = bmp
            Refiner.erase(&out, refined)

            for (k, b) in info.blocks.enumerated() where b.kind != "sfx" {
                let r = refined[k]
                XCTAssertEqual(r.mode, .clean, "page\(page) block\(k) \(b.kind)")
                // 이 덩어리의 정답 글자 픽셀이 다 지워졌나
                let gt = IRect(x: b.box[0], y: b.box[1], w: b.box[2], h: b.box[3]).expanded(by: 2)
                var total = 0, gone = 0
                for y in gt.y..<gt.maxY {
                    for x in gt.x..<gt.maxX where truth[y * bmp.width + x] == 1 {
                        total += 1
                        if out.color(x, y).luminance > 225 { gone += 1 }
                    }
                }
                XCTAssertGreaterThan(Double(gone) / Double(max(1, total)), 0.97, "page\(page) block\(k) \(b.kind) \(gone)/\(total)")
                if b.kind == "speech" { XCTAssertTrue(r.closedBubble, "page\(page) block\(k)") }
            }
            // 글자가 아닌 진한 픽셀(말풍선 테두리·그림)이 지워지지 않았나
            var damaged = 0, dark = 0
            for y in 0..<bmp.height {
                for x in 0..<bmp.width where bmp.color(x, y).luminance < 100 {
                    var nearText = false
                    for dy in -3...3 where !nearText {
                        for dx in -3...3 {
                            let xx = x + dx, yy = y + dy
                            if xx >= 0, yy >= 0, xx < bmp.width, yy < bmp.height, truth[yy * bmp.width + xx] == 1 {
                                nearText = true
                                break
                            }
                        }
                    }
                    if nearText { continue }
                    dark += 1
                    if out.color(x, y).luminance > 160 { damaged += 1 }
                }
            }
            XCTAssertLessThan(Double(damaged) / Double(dark), 0.002, "page\(page) damaged \(damaged)/\(dark)")

            if let preview {
                let m = ApproxMetrics()
                var layouts: [[String: Any]] = []
                for (k, r) in refined.enumerated() {
                    let text = Self.sampleKorean[(page * 3 + k) % Self.sampleKorean.count]
                    let kind = blocks[k].kind
                    let p = Typesetter.place(kind == .sfx ? "두두두" : text, for: r, kind: kind, metrics: m)
                    let l = p.layout
                    layouts.append([
                        "mode": r.mode.rawValue, "size": l.fontSize, "lh": l.lineHeight, "overflow": l.overflow,
                        "ink": [p.color.r, p.color.g, p.color.b], "bg": [r.background.r, r.background.g, r.background.b],
                        "plate": p.plate != nil ? p.plateAlpha : 0, "outline": p.outline != nil ? p.outlineWidth : 0,
                        "weight": p.weight,
                        "layout": [r.layoutRect.x, r.layoutRect.y, r.layoutRect.w, r.layoutRect.h],
                        "lines": l.lines.map { ["t": $0.text, "x": $0.x, "y": $0.y, "w": $0.width] as [String: Any] },
                    ])
                }
                let pdir = URL(fileURLWithPath: preview)
                try out.rawData().write(to: pdir.appendingPathComponent("page\(page).erased.rgba"))
                let json = try JSONSerialization.data(withJSONObject: ["blocks": layouts], options: [.prettyPrinted])
                try json.write(to: pdir.appendingPathComponent("page\(page).layout.json"))
            }
        }
    }
}
