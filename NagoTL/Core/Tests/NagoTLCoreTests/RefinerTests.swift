import XCTest
@testable import NagoTLCore

final class RefinerTests: XCTestCase {
    /// 흰 말풍선(검은 테두리) 안 세로쓰기: 상자가 어긋나도 글자만 다 지우고 테두리는 남긴다
    func testClosedBubbleErasesTextKeepsOutline() {
        for (dx, dy, dw, dh) in [(0, 0, 0, 0), (-12, 8, 10, -14), (9, -10, -8, 16), (5, 5, 20, 20)] {
            var cv = Canvas(width: 500, height: 600)
            // 바깥 그림 선
            cv.line(20, 40, 480, 70, width: 3, RGBA(30, 30, 30))
            cv.line(30, 560, 470, 500, width: 4, RGBA(20, 20, 20))
            cv.ellipse(cx: 250, cy: 300, rx: 130, ry: 200, outline: 4, line: .black, fill: .white)
            let box = cv.verticalText(right: 300, top: 160, columns: [7, 6, 4], size: 30, seed: 1)
            let outlineBefore = darkPixels(cv.bmp, outside: IRect(x: 125, y: 105, w: 250, h: 390))
            let jittered = IRect(x: box.x + dx, y: box.y + dy, w: box.w + dw, h: box.h + dh)
            let r = Refiner.refine(cv.bmp, box: jittered, kind: .speech)
            XCTAssertEqual(r.mode, .clean)
            XCTAssertTrue(r.closedBubble, "jitter \(dx),\(dy)")
            var out = cv.bmp
            Refiner.erase(&out, [r])
            XCTAssertGreaterThan(cv.erasedFraction(out, background: .white), 0.995, "jitter \(dx),\(dy)")
            // 말풍선 테두리·바깥 그림은 그대로
            XCTAssertEqual(darkPixels(out, outside: IRect(x: 125, y: 105, w: 250, h: 390)), outlineBefore)
            // 번역 자리는 말풍선 안쪽, 원문 상자보다 넓다
            XCTAssertGreaterThan(r.layoutRect.w, box.w)
            XCTAssertTrue(IRect(x: 120, y: 100, w: 260, h: 400).coverage(of: r.layoutRect) > 0.99)
            XCTAssertEqual(r.glyphSize, 30, accuracy: 2)
        }
    }

    /// 테두리 없는 글자(흰 바탕): 글자만 지우고 바로 옆 그림 선은 남긴다
    func testOpenTextKeepsNearbyArt() {
        var cv = Canvas(width: 400, height: 300)
        let box = cv.verticalText(right: 250, top: 60, columns: [5, 5], size: 26, seed: 7)
        // 글자 상자 옆을 지나가는 긴 선(그림)
        cv.line(box.maxX + 14, 10, box.maxX + 14, 290, width: 3, RGBA(10, 10, 10))
        cv.line(10, box.maxY + 20, 390, box.maxY + 20, width: 3, RGBA(10, 10, 10))
        let r = Refiner.refine(cv.bmp, box: box.expanded(by: 4), kind: .narration)
        XCTAssertEqual(r.mode, .clean)
        XCTAssertFalse(r.closedBubble)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        XCTAssertGreaterThan(cv.erasedFraction(out, background: .white), 0.99)
        // 선은 끊기지 않았다
        for y in 10..<290 { XCTAssertLessThan(out.color(box.maxX + 14, y).luminance, 60, "y \(y)") }
        for x in 10..<390 { XCTAssertLessThan(out.color(x, box.maxY + 20).luminance, 60, "x \(x)") }
    }

    /// 사진처럼 복잡한 바탕 위 글자는 라벨로 덮는다(둘레 색을 매끈하게 이어서)
    func testTexturedBackgroundBecomesLabel() {
        var cv = Canvas(width: 300, height: 200)
        var rnd = SeededRandom(3)
        for y in 0..<200 {
            for x in 0..<300 {
                // 왼쪽 어둡고 오른쪽 밝은 그러데이션 + 거친 잡음
                let base = 60 + x / 2
                let n = rnd.int(-45...45)
                let v = UInt8(min(255, max(0, base + n)))
                cv.dot(x, y, RGBA(v, UInt8(min(255, Int(v) + 20)), v))
            }
        }
        cv.rect(IRect(x: 100, y: 80, w: 100, h: 30), .white, text: true)
        let r = Refiner.refine(cv.bmp, box: IRect(x: 96, y: 76, w: 108, h: 38), kind: .sign)
        XCTAssertEqual(r.mode, .label)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        // 하얀 글자는 사라지고, 덮은 면은 왼쪽→오른쪽으로 밝아진다
        XCTAssertLessThan(out.color(150, 95).luminance, 200)
        XCTAssertLessThan(out.color(105, 95).luminance, out.color(195, 95).luminance)
        XCTAssertEqual(Double(out.color(105, 95).luminance), Double(60 + 52 + 12), accuracy: 30)
    }

    /// 흰 칸(닫힌 곳) 안에 글자와 멀리 떨어진 그림이 있으면 그림은 지우지 않는다
    func testPanelWithArtIsNotTreatedAsBubble() {
        var cv = Canvas(width: 600, height: 500)
        cv.rect(IRect(x: 20, y: 20, w: 560, h: 5), .black)
        cv.rect(IRect(x: 20, y: 475, w: 560, h: 5), .black)
        cv.rect(IRect(x: 20, y: 20, w: 5, h: 460), .black)
        cv.rect(IRect(x: 575, y: 20, w: 5, h: 460), .black)
        let box = cv.verticalText(right: 160, top: 60, columns: [4, 4], size: 24, seed: 5)
        // 칸 안의 그림(글자에서 멀다): 사람 얼굴 비슷한 것들
        var art: [(Int, Int)] = []
        for k in 0..<6 {
            let ax = 330 + (k % 3) * 70, ay = 250 + (k / 3) * 90
            cv.rect(IRect(x: ax, y: ay, w: 24, h: 24), RGBA(20, 20, 20))
            art.append((ax + 12, ay + 12))
        }
        cv.ellipse(cx: 420, cy: 150, rx: 60, ry: 40, outline: 3, line: .black, fill: .white)
        let r = Refiner.refine(cv.bmp, box: box, kind: .speech)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        XCTAssertGreaterThan(cv.erasedFraction(out, background: .white), 0.99)
        for (x, y) in art { XCTAssertLessThan(out.color(x, y).luminance, 60) }
        XCTAssertLessThan(out.color(420, 110).luminance, 60)
        // 칸 전체를 말풍선으로 잡지 않았다
        XCTAssertLessThan(r.layoutRect.area, 200 * 300)
    }

    /// 이어진 말풍선 두 개(덩어리 두 개): 번역 자리를 나눠 갖고 겹치지 않는다
    func testConnectedBubblesAreSplit() {
        var cv = Canvas(width: 700, height: 500)
        // 두 타원을 검게 칠한 뒤 안쪽을 희게: 겹친 목 부분이 트인 하나의 닫힌 말풍선
        cv.ellipse(cx: 220, cy: 250, rx: 142, ry: 172, outline: 0.01, line: .black, fill: .black)
        cv.ellipse(cx: 460, cy: 230, rx: 132, ry: 162, outline: 0.01, line: .black, fill: .black)
        cv.ellipse(cx: 220, cy: 250, rx: 138, ry: 168, outline: 0.01, line: .white, fill: .white)
        cv.ellipse(cx: 460, cy: 230, rx: 128, ry: 158, outline: 0.01, line: .white, fill: .white)
        let a = cv.verticalText(right: 250, top: 150, columns: [6, 5], size: 28, seed: 11)
        let b = cv.verticalText(right: 510, top: 140, columns: [5, 5], size: 28, seed: 12)
        let rs = Refiner.refinePage(cv.bmp, blocks: [PageBlock(box: a, kind: .speech), PageBlock(box: b, kind: .speech)])
        XCTAssertTrue(rs[0].closedBubble && rs[1].closedBubble)
        guard let ra = rs[0].region, let rb = rs[1].region else { return XCTFail("no regions") }
        XCTAssertFalse(Refiner.shares(ra, rb))
        XCTAssertLessThan(ra.boundingBox.maxX, rb.boundingBox.x + 1)
        var out = cv.bmp
        Refiner.erase(&out, rs)
        XCTAssertGreaterThan(cv.erasedFraction(out, background: .white), 0.99)
    }

    /// 검은 바탕 흰 글자(나레이션 상자)
    func testInvertedBox() {
        var cv = Canvas(width: 400, height: 300)
        cv.rect(IRect(x: 60, y: 60, w: 280, h: 120), .black)
        let box = cv.verticalText(right: 260, top: 80, columns: [3, 3, 3], size: 24, seed: 9, ink: .white)
        let r = Refiner.refine(cv.bmp, box: box, kind: .narration)
        XCTAssertEqual(r.mode, .clean)
        XCTAssertGreaterThan(r.ink.luminance, 200)
        var out = cv.bmp
        Refiner.erase(&out, [r])
        XCTAssertGreaterThan(cv.erasedFraction(out, background: .black), 0.99)
    }

    func testInpaintFollowsGradient() {
        var bmp = Bitmap(width: 100, height: 40)
        for y in 0..<40 {
            for x in 0..<100 { bmp.set(x, y, RGBA(UInt8(x * 2), 100, 100)) }
        }
        var mask = RegionMask(rect: IRect(x: 30, y: 10, w: 40, h: 20))
        for i in mask.bits.indices { mask.bits[i] = true }
        for y in 10..<30 {
            for x in 30..<70 { bmp.set(x, y, .black) }
        }
        Inpaint.fill(&bmp, mask: mask, source: nil, fallback: .white)
        for x in stride(from: 32, to: 68, by: 6) {
            XCTAssertEqual(Double(bmp.color(x, 20).r), Double(x * 2), accuracy: 22, "x \(x)")
        }
    }

    private func darkPixels(_ b: Bitmap, outside inner: IRect) -> Int {
        var n = 0
        for y in 0..<b.height {
            for x in 0..<b.width where !inner.contains(x, y) && b.color(x, y).luminance < 128 { n += 1 }
        }
        return n
    }
}
