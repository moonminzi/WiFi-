import Foundation
import XCTest
@testable import NagoTLCore

/// 효과음·추임새(ニヤニヤ♥, ガタッ 같은 것): 판으로 덮지 않는다 — 원래 모양으로 다시 쓰거나 원문 그대로
final class SFXTests: XCTestCase {
    static let pink = RGBA(225, 60, 120)

    /// 분홍 글자 + 흰 테두리 세로 추임새 → 글자·테두리를 지우고 같은 색·테두리·세로로 다시 쓴다
    func testOutlinedSFXRedrawnInStyle() {
        for hints in [true, false] {
            var cv = ArtFixtures.illustration(220, 420)
            let (box, truth) = ArtFixtures.outlinedText(&cv, right: 150, top: 60, columns: [4], size: 28, fill: Self.pink,
                                                        outline: .white, width: 3, seed: 31)
            let block = PageBlock(box: box, kind: .sfx, fill: hints ? Self.pink : nil, outline: hints ? .white : nil,
                                  vertical: hints)
            let r = Refiner.refinePage(cv.bmp, blocks: [block])[0]
            XCTAssertEqual(r.mode, .art, "hints \(hints)")
            XCTAssertLessThan(r.ink.distance2(Self.pink), 20 * 20, "fill \(r.ink)")
            XCTAssertLessThan(r.outline.map { $0.distance2(.white) } ?? .max, 20 * 20, "outline \(String(describing: r.outline))")
            var out = cv.bmp
            Refiner.erase(&out, [r])
            var left = 0, total = 0
            for i in truth.bits.indices where truth.bits[i] {
                total += 1
                let c = out.color(i % out.width, i / out.width)
                if c.distance2(Self.pink) < 60 * 60 || c.distance2(.white) < 40 * 40 { left += 1 }
            }
            XCTAssertLessThan(Double(left) / Double(total), 0.02, "hints \(hints) left \(left)/\(total)")
            let p = Typesetter.place("히죽히죽♥", for: r, kind: .sfx, metrics: ApproxMetrics())
            XCTAssertFalse(p.layout.vertical)
            XCTAssertFalse(p.layout.lines.isEmpty)
            XCTAssertNil(p.plate)
            XCTAssertEqual(p.outline, r.outline)
        }
    }

    /// 흰 테두리 글자 바로 아래에 흰 옷깃(그림)이 붙어 있어도: 테두리는 지우고 옷깃은 남긴다
    func testWhiteArtTouchingOutlinedSFXIsKept() {
        var cv = ArtFixtures.illustration(240, 420)
        let (box, truth) = ArtFixtures.outlinedText(&cv, right: 150, top: 60, columns: [4], size: 28, fill: Self.pink,
                                                    outline: .white, width: 3, seed: 7)
        // 옷깃: 글자 테두리 바로 밑에서 시작해 상자 밖으로 넓게
        let collar = IRect(x: 40, y: box.maxY, w: 200, h: 90)
        cv.rect(collar, .white)
        let r = Refiner.refinePage(cv.bmp, blocks: [PageBlock(box: box, kind: .sfx, fill: Self.pink, outline: .white,
                                                              vertical: true)])[0]
        XCTAssertEqual(r.mode, .art)
        guard let m = r.eraseMask else { return XCTFail("no mask") }
        // 옷깃은 글자에서 조금만 떨어져도 지울 곳이 아니다
        let nearText = truth.dilated(12)
        var wrong = 0, collarPixels = 0
        for y in collar.y..<collar.maxY {
            for x in collar.x..<collar.maxX where !nearText.get(x, y) {
                collarPixels += 1
                if m.get(x, y) { wrong += 1 }
            }
        }
        XCTAssertEqual(wrong, 0, "collar pixels in erase mask \(wrong)/\(collarPixels)")
        // 글자·테두리는 다 지운다
        var hit = 0, total = 0
        for i in truth.bits.indices where truth.bits[i] {
            total += 1
            if m.get(i % cv.bmp.width, i / cv.bmp.width) { hit += 1 }
        }
        XCTAssertGreaterThan(Double(hit) / Double(total), 0.97)
    }

    /// 검은 손글씨 효과음(ガタッ 같은 것) 옆을 지나는 같은 색 그림 선(팔 윤곽 등)은 지우지 않는다
    func testArtLineAlongsideBlackSFXIsKept() {
        var cv = ArtFixtures.illustration(260, 320)
        let ink = RGBA(15, 15, 15)
        let box = cv.verticalText(right: 140, top: 90, columns: [3], size: 26, seed: 5, ink: ink)
        // 글자 상자 바로 왼쪽을 위아래로 길게 지나가는 같은 색 선(글자와 닿지 않는다)
        cv.line(box.x - 3, 0, box.x - 3, 319, width: 2, ink)
        let r = Refiner.refinePage(cv.bmp, blocks: [PageBlock(box: box.expanded(by: 2), kind: .sfx, fill: ink)])[0]
        XCTAssertEqual(r.mode, .art)
        guard let m = r.eraseMask else { return XCTFail("no mask") }
        // 선은 거의 그대로(상자 안을 지나가는 다른 그림 선과 만나는 몇 픽셀만 지웠다 되살린다)
        var touched = 0
        for y in 0..<320 where m.get(box.x - 4, y) || m.get(box.x - 3, y) { touched += 1 }
        XCTAssertLessThan(touched, 12, "line rows in erase mask \(touched)")
        var out = cv.bmp
        Refiner.erase(&out, [r])
        var dark = 0
        for y in 0..<320 where out.color(box.x - 4, y).distance2(ink) < 60 * 60 { dark += 1 }
        XCTAssertGreaterThan(dark, 300, "line still drawn \(dark)/320")
        // 글자는 지운다
        var left = 0, total = 0
        for i in cv.truth.indices where cv.truth[i] {
            total += 1
            if out.color(i % out.width, i / out.width).distance2(ink) < 60 * 60 { left += 1 }
        }
        XCTAssertLessThan(Double(left) / Double(total), 0.03, "left \(left)/\(total)")
    }

    /// 글자색이 둘레 그림과 같아 골라낼 수 없으면 원문 그대로: 그림을 건드리지도, 아무것도 그리지도 않는다
    func testUnsureSFXIsLeftAsIs() {
        var cv = ArtFixtures.illustration(220, 420)
        // 둘레 그림에 흔한 색(옷 색)으로 쓴 효과음
        let cloth = cv.bmp.color(40, 150)
        let box = cv.verticalText(right: 170, top: 120, columns: [3], size: 26, seed: 9, ink: cloth)
        let r = Refiner.refinePage(cv.bmp, blocks: [PageBlock(box: box, kind: .sfx)])[0]
        XCTAssertEqual(r.mode, .keep)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        XCTAssertEqual(out.pixels, cv.bmp.pixels)
        let p = Typesetter.place("덜컥", for: r, kind: .sfx, metrics: ApproxMetrics())
        XCTAssertTrue(p.layout.lines.isEmpty)
        XCTAssertNil(p.plate)
    }

    /// 효과음 번역을 끄면 언제나 원문 그대로
    func testSFXTranslationOffKeepsOriginal() {
        var cv = ArtFixtures.illustration(220, 420)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 150, top: 60, columns: [4], size: 28, fill: Self.pink,
                                                outline: .white, width: 3, seed: 31)
        let blocks = [PageBlock(box: box, kind: .sfx, fill: Self.pink, outline: .white, vertical: true)]
        XCTAssertEqual(Refiner.refinePage(cv.bmp, blocks: blocks, translateSFX: false)[0].mode, .keep)
        XCTAssertEqual(Refiner.refinePage(cv.bmp, blocks: blocks, translateSFX: true)[0].mode, .art)
    }

    /// 색으로 못 골라내는 그림 위 대사도 매끈한 판(흰·단색 상자)으로 덮지 않고 둘레 그림 결로 메운다
    func testSpeechOnTexturedArtIsNotAFlatBox() {
        // 머리카락 같은 가는 줄무늬 두 색
        var cv = Canvas(width: 300, height: 360)
        let a = RGBA(120, 90, 140), b = RGBA(200, 170, 210)
        for y in 0..<360 {
            for x in 0..<300 { cv.dot(x, y, (x / 3 + y / 7) % 2 == 0 ? a : b) }
        }
        // 줄무늬와 같은 색 글자 → 색으로는 못 가려낸다
        let box = cv.verticalText(right: 200, top: 100, columns: [4, 3], size: 26, seed: 13, ink: a)
        let r = Refiner.refinePage(cv.bmp, blocks: [PageBlock(box: box, kind: .speech)])[0]
        XCTAssertNotEqual(r.mode, .label)
        XCTAssertNotEqual(r.mode, .clean)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        // 상자 안이 한 가지 색으로 칠해지지 않았다(줄무늬 결이 이어진다)
        var hist: [Int: Int] = [:]
        var lum: [Double] = []
        for y in box.y..<box.maxY {
            for x in box.x..<box.maxX {
                let c = out.color(x, y)
                hist[Refiner.colorBin(c), default: 0] += 1
                lum.append(Double(c.luminance))
            }
        }
        let top = hist.values.max() ?? 0
        XCTAssertLessThan(Double(top) / Double(box.area), 0.7, "flat fill")
        let mean = lum.reduce(0, +) / Double(lum.count)
        let sd = (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
        XCTAssertGreaterThan(sd, 15, "texture sd \(sd)")
    }

    /// 두꺼운 흰 테두리 글자에 상자가 딱 맞아 상자 안이 거의 흰색이어도, 둘레가 그림이면 "흰 바탕 글자"로 보지 않는다
    func testTightBoxOnOutlinedTextIsNotOpenText() {
        var cv = ArtFixtures.illustration(220, 420)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 170, top: 40, columns: [9, 7], size: 30, fill: Self.pink,
                                                outline: .white, width: 6, seed: 4)
        let r = Refiner.refine(cv.bmp, box: box, kind: .speech)
        XCTAssertEqual(r.mode, .art)
    }
}
