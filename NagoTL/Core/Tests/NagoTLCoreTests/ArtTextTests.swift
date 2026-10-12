import Foundation
import XCTest
@testable import NagoTLCore

/// 그림 위 글자 시험용 그림
enum ArtFixtures {
    static let magenta = RGBA(190, 50, 135)

    /// 옷 주름·그러데이션·피부·그림 선이 있는 가짜 일러스트
    static func illustration(_ w: Int, _ h: Int) -> Canvas {
        var cv = Canvas(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                // 초록 옷: 세로 그러데이션 + 대각선 주름 줄무늬
                let fold = (x + y / 2) % 26 < 5 ? -28 : 0
                let g = 110 + y * 40 / h + fold
                cv.dot(x, y, RGBA(UInt8(70 + fold / 2 + 28), UInt8(max(0, g)), UInt8(max(0, g - 8))))
            }
        }
        // 피부(타원) + 그림 선
        cv.ellipse(cx: Double(w) * 0.25, cy: Double(h) * 0.7, rx: Double(w) * 0.3, ry: Double(h) * 0.22, outline: 2,
                   line: RGBA(60, 40, 35), fill: RGBA(238, 205, 175))
        cv.line(0, h / 3, w - 1, h / 3 + 40, width: 2, RGBA(40, 50, 45))
        cv.line(w / 2, 0, w / 2 + 30, h - 1, width: 2, RGBA(40, 50, 45))
        return cv
    }

    /// 세로 글자(오른쪽 열부터)를 글자색 + 테두리로. 정답 마스크(글자+테두리)를 돌려준다
    @discardableResult
    static func outlinedText(_ cv: inout Canvas, right: Int, top: Int, columns: [Int], size: Int, fill: RGBA, outline: RGBA,
                      width: Int, seed: Int) -> (box: IRect, truth: RegionMask) {
        var glyphs = Canvas(width: cv.bmp.width, height: cv.bmp.height, fill: .white)
        let box = glyphs.verticalText(right: right, top: top, columns: columns, size: size, seed: seed, ink: .black)
        var stroke = RegionMask(rect: cv.bmp.bounds)
        for i in glyphs.truth.indices where glyphs.truth[i] { stroke.bits[i] = true }
        let ring = stroke.dilated(width)
        for i in ring.bits.indices where ring.bits[i] {
            let x = i % cv.bmp.width, y = i / cv.bmp.width
            cv.dot(x, y, stroke.bits[i] ? fill : outline, text: true)
        }
        return (box.expanded(by: width), ring)
    }
}

/// 말풍선 없이 그림 위에 쓴 글자(예: 분홍 글자 + 흰 테두리)
final class ArtTextTests: XCTestCase {
    static let magenta = ArtFixtures.magenta

    func testArtTextSegmentsErasesAndRestores() {
        for (hints, jitter) in [(true, 0), (false, 0), (true, 9), (false, -7)] {
            var cv = ArtFixtures.illustration(220, 420)
            let clean = cv.bmp
            let (box, truth) = ArtFixtures.outlinedText(&cv, right: 170, top: 40, columns: [9, 7], size: 30,
                                            fill: Self.magenta, outline: .white, width: 3, seed: 21)
            let claudeBox = IRect(x: box.x + jitter, y: box.y - jitter, w: box.w - jitter / 2, h: box.h + jitter)
            let block = PageBlock(box: claudeBox, kind: .speech, fill: hints ? Self.magenta : nil,
                                  outline: hints ? .white : nil, vertical: hints)
            let r = Refiner.refine(cv.bmp, block: block)
            XCTAssertEqual(r.mode, .art, "hints \(hints) jitter \(jitter)")
            guard let m = r.eraseMask else { return XCTFail("no mask") }
            // 정답 글자·테두리 픽셀을 거의 다 잡고, 글자에서 떨어진 그림은 잡지 않는다(가장자리 1~2px 넓힌 건 괜찮다)
            let near = truth.dilated(2)
            var hit = 0, total = 0, far = 0, marked = 0
            for y in 0..<cv.bmp.height {
                for x in 0..<cv.bmp.width {
                    if truth.get(x, y) {
                        total += 1
                        if m.get(x, y) { hit += 1 }
                    }
                    if m.get(x, y) {
                        marked += 1
                        if !near.get(x, y) { far += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(Double(hit) / Double(total), 0.97, "hints \(hints) jitter \(jitter)")
            XCTAssertLessThan(Double(far) / Double(marked), 0.02, "hints \(hints) jitter \(jitter) far \(far)/\(marked)")
            XCTAssertEqual(r.ink.distance2(Self.magenta) < 50 * 50, true, "fill \(r.ink)")
            XCTAssertNotNil(r.outline)
            XCTAssertTrue(r.vertical || !hints)

            // 지운 뒤 글자 자리가 원래 그림과 얼마나 가까운가(번짐만 쓴 것보다 나아야 한다)
            var out = cv.bmp
            Refiner.erase(&out, [r])
            var diffuseOnly = cv.bmp
            Inpaint.fill(&diffuseOnly, mask: m, source: nil, fallback: .white)
            func error(_ b: Bitmap) -> Double {
                var s = 0.0, n = 0.0
                for y in 0..<b.height {
                    for x in 0..<b.width where truth.get(x, y) {
                        let a = b.color(x, y), c = clean.color(x, y)
                        s += Double(abs(Int(a.r) - Int(c.r)) + abs(Int(a.g) - Int(c.g)) + abs(Int(a.b) - Int(c.b))) / 3
                        n += 1
                    }
                }
                return s / n
            }
            let pm = error(out), df = error(diffuseOnly)
            XCTAssertLessThan(pm, 14, "patchmatch error \(pm) (diffusion \(df))")
            XCTAssertLessThanOrEqual(pm, df * 1.1, "patchmatch \(pm) vs diffusion \(df)")
            // 분홍·흰 글자가 남지 않았다
            var leftover = 0
            for y in 0..<out.height {
                for x in 0..<out.width where truth.get(x, y) {
                    let c = out.color(x, y)
                    if c.distance2(Self.magenta) < 60 * 60 || c.distance2(.white) < 40 * 40 { leftover += 1 }
                }
            }
            XCTAssertLessThan(Double(leftover) / Double(total), 0.02, "leftover \(leftover)/\(total)")
        }
    }

    /// 두꺼운 흰 테두리(테두리 픽셀이 글자 픽셀보다 많다)여도 글자색·테두리색을 바로 고르고,
    /// Claude가 준 어림 색은 그림의 실제 색으로 맞춘다
    func testThickOutlineColorsAndHintSnapping() {
        for hint in [nil, RGBA(224, 33, 138)] as [RGBA?] {
            var cv = ArtFixtures.illustration(220, 420)
            let (box, _) = ArtFixtures.outlinedText(&cv, right: 170, top: 40, columns: [9, 7], size: 30,
                                                    fill: Self.magenta, outline: .white, width: 6, seed: 12)
            let block = PageBlock(box: box, kind: .speech, fill: hint, outline: hint == nil ? nil : RGBA(240, 240, 240),
                                  vertical: hint != nil)
            let r = Refiner.refine(cv.bmp, block: block)
            XCTAssertEqual(r.mode, .art)
            XCTAssertLessThan(r.ink.distance2(Self.magenta), 12 * 12, "fill \(r.ink) hint \(String(describing: hint))")
            XCTAssertLessThan(r.outline.map { $0.distance2(.white) } ?? .max, 12 * 12,
                              "outline \(String(describing: r.outline))")
            XCTAssertTrue(r.vertical)
        }
    }

    /// 흰 테두리 그물(글자 테두리)을 말풍선으로 잘못 보지 않는다
    func testOutlineNetworkIsNotABubble() {
        var cv = ArtFixtures.illustration(220, 420)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 170, top: 40, columns: [9, 7], size: 30,
                                    fill: Self.magenta, outline: .white, width: 4, seed: 4)
        let r = Refiner.refine(cv.bmp, box: box, kind: .speech)
        XCTAssertFalse(r.closedBubble)
        XCTAssertNotEqual(r.mode, .clean)
    }

    /// 말풍선은 여전히 말풍선으로(안쪽에 넓은 빈 곳)
    func testRealBubbleStillBubble() {
        var cv = ArtFixtures.illustration(400, 500)
        cv.ellipse(cx: 200, cy: 250, rx: 120, ry: 170, outline: 4, line: .black, fill: .white)
        let box = cv.verticalText(right: 240, top: 140, columns: [6, 5], size: 28, seed: 3)
        let r = Refiner.refine(cv.bmp, box: box, kind: .speech)
        XCTAssertEqual(r.mode, .clean)
        XCTAssertTrue(r.closedBubble)
    }

    func testVerticalLayoutColumnsRightToLeft() {
        let rect = IRect(x: 100, y: 50, w: 90, h: 420)
        let l = Typesetter.layoutVertical("잘됐네요~ 다카하시 군, 오늘부터 너도 원숭이야.", rect: rect, maxSize: 34, minSize: 10)
        XCTAssertTrue(l.vertical)
        XCTAssertFalse(l.overflow)
        XCTAssertGreaterThan(l.lines.count, 1)
        XCTAssertGreaterThan(l.fontSize, 24)
        // 첫 열이 가장 오른쪽
        for (a, b) in zip(l.lines, l.lines.dropFirst()) { XCTAssertGreaterThan(a.x, b.x) }
        for col in l.lines {
            XCTAssertGreaterThanOrEqual(col.x, Double(rect.x) - 0.5)
            XCTAssertLessThanOrEqual(col.x + l.lineHeight, Double(rect.maxX) + 0.5)
            XCTAssertGreaterThanOrEqual(col.y, Double(rect.y) - 0.5)
            XCTAssertLessThanOrEqual(col.y + col.width, Double(rect.maxY) + 0.5)
        }
        XCTAssertEqual(l.lines.map(\.text).joined(separator: " "), "잘됐네요~ 다카하시 군, 오늘부터 너도 원숭이야.")
    }

    /// 세로쓰기 문장부호: 따옴표는 낫표로, 점 여러 개는 말줄임표 한 칸, 괄호·물결은 돌리고 쉼표·마침표는 오른쪽 위
    func testVerticalPunctuation() {
        XCTAssertEqual(Typesetter.verticalForm("“가자...!” 그래, ‘진짜’…… \"응\""), "「가자…!」 그래, 『진짜』… 「응」")
        XCTAssertEqual(Typesetter.verticalForm("끝."), "끝.")
        XCTAssertEqual(VerticalGlyph.of("가"), .upright)
        XCTAssertEqual(VerticalGlyph.of("A"), .upright)
        XCTAssertEqual(VerticalGlyph.of("7"), .upright)
        XCTAssertEqual(VerticalGlyph.of("("), .rotated)
        XCTAssertEqual(VerticalGlyph.of("「"), .rotated)
        XCTAssertEqual(VerticalGlyph.of("~"), .rotated)
        XCTAssertEqual(VerticalGlyph.of("…"), .rotated)
        XCTAssertEqual(VerticalGlyph.of(","), .corner)
        XCTAssertEqual(VerticalGlyph.of("。"), .corner)
        XCTAssertEqual(VerticalGlyph.of("!"), .centered)
        XCTAssertEqual(VerticalGlyph.of("♥"), .centered)
        // 세로 배치에도 바뀐 글자가 들어간다
        let l = Typesetter.layoutVertical("“좋아...”", rect: IRect(x: 0, y: 0, w: 60, h: 300), maxSize: 30, minSize: 10)
        XCTAssertEqual(l.lines.map(\.text).joined(), "「좋아…」")
    }

    /// 좁고 긴 그림 위 세로 글자는 한글도 세로가 더 크게 들어가면 세로로
    func testArtPlacementIsHorizontalKoreanWithOriginalColors() {
        var cv = ArtFixtures.illustration(220, 520)
        let (box, _) = ArtFixtures.outlinedText(&cv, right: 170, top: 30, columns: [12, 11], size: 32,
                                    fill: Self.magenta, outline: .white, width: 3, seed: 8)
        let r = Refiner.refine(cv.bmp, block: PageBlock(box: box, kind: .speech, fill: Self.magenta, outline: .white,
                                                        vertical: true))
        let p = Typesetter.place("잘됐네요~ 다카하시 군, 오늘부터 너도 원숭이야.", for: r, kind: .speech, metrics: ApproxMetrics())
        XCTAssertFalse(p.layout.vertical)
        XCTAssertEqual(p.color.distance2(Self.magenta) < 50 * 50, true)
        XCTAssertEqual(p.outline, .white)
        XCTAssertGreaterThan(p.outlineWidth, 0.1)
    }

    func testHexAndOldAnswersDecode() throws {
        XCTAssertEqual(RGBA(hex: "#E0218A"), RGBA(0xE0, 0x21, 0x8A))
        XCTAssertEqual(RGBA(hex: "fff"), .white)
        XCTAssertNil(RGBA(hex: ""))
        XCTAssertNil(RGBA(hex: "#12"))
        let old = #"{"kind":"speech","box":{"x0":1,"y0":2,"x1":30,"y1":40},"source":"あ","translation":"아","note":""}"#
        let b = try JSONDecoder().decode(PageAnswer.Block.self, from: Data(old.utf8))
        XCTAssertFalse(b.vertical)
        XCTAssertNil(b.fillColor)
        let new = ##"{"kind":"speech","box":{"x0":1,"y0":2,"x1":30,"y1":40},"source":"あ","translation":"아","note":"","##
            + ##""vertical":true,"text_color":"#C0328C","outline_color":"#FFFFFF"}"##
        let n = try JSONDecoder().decode(PageAnswer.Block.self, from: Data(new.utf8))
        XCTAssertEqual(n.pageBlock.fill, RGBA(0xC0, 0x32, 0x8C))
        XCTAssertEqual(n.pageBlock.outline, .white)
        XCTAssertTrue(n.pageBlock.vertical)
    }
}
