import Foundation
import XCTest
@testable import NagoTLCore

/// AI 상자가 어긋나도(옆 열로 밀리거나, 일부만 덮거나) 그림에서 테두리 글자를 찾아 상자를 옮기는지
final class LocatorTests: XCTestCase {
    static let magenta = ArtFixtures.magenta

    /// 지운 뒤 남은 테두리 글자 조각 픽셀 수
    func leftover(_ bmp: Bitmap, in r: IRect, fill: RGBA, outline: RGBA) -> Int {
        Locator.findPieces(bmp, in: r.clamped(width: bmp.width, height: bmp.height), fill: fill, outline: outline)
            .reduce(0) { $0 + $1.count }
    }

    func testShiftedAndShrunkBoxesSnapToTheText() {
        // 열 하나만큼 옆으로 밀린 상자, 글자 위쪽만 덮은 상자, 열 하나를 빠뜨린 상자
        let size = 30, pitch = size + size / 4
        for (k, shape) in ["shifted", "top", "narrow"].enumerated() {
            var cv = ArtFixtures.illustration(380, 480)
            let (box, _) = ArtFixtures.outlinedText(&cv, right: 320, top: 40, columns: [9, 7, 8], size: size,
                                                    fill: Self.magenta, outline: .white, width: 4, seed: 30 + k)
            let model: IRect
            switch shape {
            case "shifted": model = IRect(x: box.x - pitch * 4 / 5, y: box.y + 10, w: box.w, h: box.h - 20)
            case "top": model = IRect(x: box.x, y: box.y, w: box.w, h: box.h / 5)
            default: model = IRect(x: box.x + pitch, y: box.y, w: box.w - pitch, h: box.h)
            }
            let block = PageBlock(box: model, kind: .speech, fill: RGBA(200, 60, 140), outline: .white, vertical: true,
                                  chars: 24)
            XCTAssertGreaterThan(leftover(cv.bmp, in: box, fill: Self.magenta, outline: .white), 1000)
            let r = Refiner.refinePage(cv.bmp, blocks: [block])[0]
            XCTAssertTrue(r.located, shape)
            XCTAssertEqual(r.mode, .art, shape)
            XCTAssertGreaterThan(r.textBox.iou(box), 0.8, "\(shape) \(r.textBox) vs \(box)")
            var out = cv.bmp
            Refiner.erase(&out, [r])
            XCTAssertLessThan(leftover(out, in: box.expanded(by: 6), fill: Self.magenta, outline: .white), 40, shape)
            // 글자 크기는 원문 글자 크기 근처(상자가 틀려도 터무니없이 크거나 작지 않게)
            XCTAssertEqual(r.glyphSize, Double(size), accuracy: Double(size) * 0.35, shape)
            let p = Typesetter.place("그러니까 이건 돌려받을게요. 그럼 안녕히 계세요♥", for: r, kind: .speech, metrics: ApproxMetrics())
            XCTAssertFalse(p.layout.vertical, shape)
            XCTAssertGreaterThan(p.layout.fontSize, Double(size) * 0.6, shape)
        }
    }

    func testNeighbourBlocksKeepTheirOwnColumns() {
        // 두 덩어리 사이가 글자 두 개쯤. 왼쪽 덩어리 상자가 오른쪽으로, 오른쪽 덩어리 상자가 왼쪽으로 밀려도 제 열을 찾는다
        let size = 28
        var cv = ArtFixtures.illustration(420, 420)
        let (right, _) = ArtFixtures.outlinedText(&cv, right: 380, top: 30, columns: [8, 6], size: size,
                                                  fill: Self.magenta, outline: .white, width: 4, seed: 51)
        let (left, _) = ArtFixtures.outlinedText(&cv, right: right.x - size * 2, top: 50, columns: [7], size: size,
                                                 fill: Self.magenta, outline: .white, width: 4, seed: 52)
        let blocks = [
            PageBlock(box: IRect(x: right.x - 20, y: right.y, w: right.w, h: right.h), kind: .speech, fill: Self.magenta,
                      outline: .white, vertical: true, chars: 14),
            PageBlock(box: IRect(x: left.x + 18, y: left.y, w: left.w, h: left.h), kind: .speech, fill: Self.magenta,
                      outline: .white, vertical: true, chars: 7),
        ]
        let snaps = Locator.snap(cv.bmp, blocks: blocks)
        XCTAssertTrue(snaps[0].located && snaps[1].located)
        XCTAssertGreaterThan(snaps[0].box.iou(right), 0.8, "\(snaps[0].box) vs \(right)")
        XCTAssertGreaterThan(snaps[1].box.iou(left), 0.8, "\(snaps[1].box) vs \(left)")
        XCTAssertEqual(snaps[0].box.intersection(snaps[1].box).area, 0)
    }

    func testLineArtNextToTextIsNotTakenAsText() {
        // 글자 바로 옆 흰 옷(검은 가는 선·작은 점이 있는 그림)은 흰 테두리 검은 글자처럼 보여도 붙이지 않는다
        let size = 30
        var cv = ArtFixtures.illustration(360, 420)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 330, top: 30, columns: [8, 8], size: size, fill: .black,
                                                outline: .white, width: 4, seed: 61)
        let shirt = IRect(x: box.x - 90, y: 20, w: 86, h: 380)
        cv.rect(shirt, RGBA(246, 246, 248))
        cv.line(shirt.x + 20, shirt.y + 10, shirt.x + 30, shirt.maxY - 10, width: 2, RGBA(30, 30, 35))
        cv.line(shirt.x + 60, shirt.y + 40, shirt.x + 50, shirt.maxY - 40, width: 2, RGBA(30, 30, 35))
        cv.rect(IRect(x: shirt.x + 70, y: shirt.y + 120, w: 6, h: 6), RGBA(30, 30, 35))
        let block = PageBlock(box: IRect(x: box.x - 30, y: box.y, w: box.w, h: box.h), kind: .narration, fill: .black,
                              outline: .white, vertical: true, chars: 16)
        let s = Locator.snap(cv.bmp, blocks: [block])[0]
        XCTAssertTrue(s.located)
        XCTAssertGreaterThanOrEqual(s.box.x, box.x - 4, "\(s.box) vs \(box)")
        let r = Refiner.refinePage(cv.bmp, blocks: [block])[0]
        var out = cv.bmp
        Refiner.erase(&out, [r])
        // 옷의 선은 그대로
        var changed = 0
        for y in shirt.y..<shirt.maxY {
            for x in shirt.x..<(shirt.maxX - 6) where out.color(x, y).distance2(cv.bmp.color(x, y)) > 30 * 30 { changed += 1 }
        }
        XCTAssertLessThan(changed, 20)
    }

    func testBubbleTextIsLeftToTheBubblePath() {
        // 흰 말풍선 안 검은 글자: AI가 "흰 테두리"라고 해도 테두리 글자로 보지 않는다(말풍선 찾기에 맡긴다)
        var cv = Canvas(width: 300, height: 300)
        cv.ellipse(cx: 150, cy: 150, rx: 120, ry: 130, outline: 3, line: .black, fill: .white)
        let box = cv.verticalText(right: 200, top: 60, columns: [5, 5], size: 26, seed: 7)
        let block = PageBlock(box: box.expanded(by: 4), kind: .speech, fill: .black, outline: .white, vertical: true, chars: 10)
        XCTAssertFalse(Locator.snap(cv.bmp, blocks: [block])[0].located)
        let r = Refiner.refinePage(cv.bmp, blocks: [block])[0]
        XCTAssertEqual(r.mode, .clean)
        XCTAssertTrue(r.closedBubble)
    }

    func testOutlineSameAsFillIsGuessed() {
        // AI가 테두리색을 글자색과 같다고 잘못 말해도(검정/검정) 검은 글자 + 흰 테두리로 찾는다
        var cv = ArtFixtures.illustration(240, 400)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 200, top: 40, columns: [6], size: 34, fill: .black,
                                                outline: .white, width: 4, seed: 71)
        let block = PageBlock(box: IRect(x: box.x + 14, y: box.y + 40, w: box.w, h: box.h - 60), kind: .speech,
                              fill: .black, outline: .black, vertical: true, chars: 6)
        let s = Locator.snap(cv.bmp, blocks: [block])[0]
        XCTAssertTrue(s.located)
        XCTAssertGreaterThan(s.box.iou(box), 0.8, "\(s.box) vs \(box)")
    }
}

/// 번역이 그림에 안 들어간 덩어리 찾기와 다른 AI 답 합치기
final class QualityTests: XCTestCase {
    func refined(_ mode: Refined.Mode, glyph: Double = 30, fallback: Bool = false) -> Refined {
        var r = Refiner.keep(IRect(x: 0, y: 0, w: 50, h: 200))
        r.mode = mode
        r.glyphSize = glyph
        r.fallback = fallback
        return r
    }

    func placed(size: Double) -> PlacedText {
        PlacedText(layout: TextLayout(fontSize: size, lineHeight: size * 1.2,
                                      lines: [LaidLine(text: "가", x: 0, y: 0, width: size)], overflow: false),
                   color: .black, weight: 700)
    }

    func testFailedRules() {
        let speech = PageBlock(box: IRect(x: 0, y: 0, w: 50, h: 200), kind: .speech, fill: .black, outline: .white)
        let sfx = PageBlock(box: IRect(x: 0, y: 0, w: 50, h: 200), kind: .sfx, fill: .black, outline: .white)
        let empty = PlacedText(layout: TextLayout(fontSize: 0, lineHeight: 0, lines: [], overflow: false), color: .black, weight: 400)
        // 원문 그대로 남은 대사는 실패, 효과음은 원문 그대로가 정상
        XCTAssertTrue(Quality.failed(speech, refined(.keep), empty))
        XCTAssertFalse(Quality.failed(sfx, refined(.keep), empty))
        // 깨알처럼 작게 들어간 것
        XCTAssertTrue(Quality.failed(speech, refined(.art), placed(size: 9)))
        XCTAssertFalse(Quality.failed(speech, refined(.art), placed(size: 28)))
        // 테두리 글자라고 했는데 못 찾아 상자째 덮은 대사
        XCTAssertTrue(Quality.failed(speech, refined(.label, fallback: true), placed(size: 28)))
        // 간판·사진 글자는 상자째 덮는 게 정상
        let sign = PageBlock(box: speech.box, kind: .sign, fill: .black, outline: .white)
        XCTAssertFalse(Quality.failed(sign, refined(.label, fallback: true), placed(size: 28)))
    }

    func block(_ x: Int, _ y: Int, _ text: String) -> PageAnswer.Block {
        PageAnswer.Block(kind: "speech", box: .init(x0: x, y0: y, x1: x + 50, y1: y + 200), source: text, translation: text)
    }

    func testMergeFillsOnlyFailedAndMissingPlaces() {
        let primary = PageAnswer(source_language: "ja", blocks: [block(0, 0, "A"), block(100, 0, "B"), block(200, 0, "C")],
                                 page_summary: "", new_terms: [])
        // B는 엉뚱한 곳을 가리켜 못 들어갔다
        let areas = primary.blocks.map(\.box.rect)
        let other = PageAnswer(source_language: "ja", blocks: [
            block(4, 6, "A2"),      // 잘 들어간 A 자리 — 건드리지 않는다
            block(104, 2, "B2"),    // 못 들어간 B 자리 — B 대신
            block(300, 0, "D2"),    // 기본 AI가 빠뜨린 곳 — 더한다
        ], page_summary: "", new_terms: [GlossaryEntry(source: "先生", korean: "선생님")])
        let (merged, added) = Quality.merge(primary, failed: [1], areas: areas, with: other)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(merged.blocks.map(\.translation), ["A", "C", "B2", "D2"])
        XCTAssertEqual(merged.new_terms.map(\.korean), ["선생님"])
        // 다른 AI가 새로 준 게 없으면 그대로
        let none = PageAnswer(source_language: "ja", blocks: [block(2, 2, "A3")], page_summary: "", new_terms: [])
        let (same, zero) = Quality.merge(primary, failed: [1], areas: areas, with: none)
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(same, primary)
    }

    func testPrintableHeartsAndLayoutKeptInside() {
        XCTAssertEqual(Typesetter.printable("좋아요❤️ 정말💕"), "좋아요♥ 정말♥")
        let l = TextLayout(fontSize: 40, lineHeight: 48, lines: [LaidLine(text: "가나다", x: 980, y: 80, width: 300)],
                           overflow: true, vertical: true)
        let m = l.moved(inside: IRect(x: 0, y: 0, w: 1000, h: 400))
        let b = m.bounds
        XCTAssertGreaterThanOrEqual(b.x, 0)
        XCTAssertLessThanOrEqual(b.x + b.w, 1000)
        XCTAssertLessThanOrEqual(b.y + b.h, 400)
    }
}
