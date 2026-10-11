import XCTest
@testable import NagoTLCore

final class TypesetterTests: XCTestCase {
    let m = ApproxMetrics()

    func ellipseRegion(cx: Int, cy: Int, rx: Int, ry: Int) -> RegionMask {
        var r = RegionMask(rect: IRect(x: cx - rx, y: cy - ry, w: 2 * rx, h: 2 * ry))
        for y in r.rect.y..<r.rect.maxY {
            for x in r.rect.x..<r.rect.maxX {
                let dx = (Double(x) + 0.5 - Double(cx)) / Double(rx), dy = (Double(y) + 0.5 - Double(cy)) / Double(ry)
                if dx * dx + dy * dy <= 1 { r.put(x, y, true) }
            }
        }
        return r
    }

    /// 타원 말풍선: 모든 줄이 타원 안, 가운데 줄이 더 길다, 크기 상한을 지킨다
    func testEllipseFitsInside() {
        let region = ellipseRegion(cx: 200, cy: 200, rx: 110, ry: 160)
        let shape = LayoutShape(region: region)
        let text = "야, 기다려! 어디 가는 거야? 오늘이야말로 결판을 내주마!"
        let l = Typesetter.layout(text, shape: shape, maxSize: 34, minSize: 10, metrics: m)
        XCTAssertFalse(l.overflow)
        XCTAssertLessThanOrEqual(l.fontSize, 34)
        XCTAssertGreaterThan(l.fontSize, 18)
        XCTAssertEqual(l.lines.map(\.text).joined(separator: " "), text)
        for line in l.lines {
            let y0 = line.y + (l.lineHeight - l.fontSize) / 2
            for y in [y0, y0 + l.fontSize - 1] {
                for x in [line.x, line.x + line.width - 1] {
                    XCTAssertTrue(region.get(Int(x), Int(y)), "corner (\(x),\(y)) of \(line.text) outside")
                }
            }
        }
        // 가운데 맞춤: 덩어리 가운데가 타원 가운데 근처
        let b = l.bounds
        XCTAssertEqual(b.y + b.h / 2, 200, accuracy: l.lineHeight)
        XCTAssertEqual(b.x + b.w / 2, 200, accuracy: 12)
    }

    /// 짧은 말은 원문 글자 크기를 넘지 않는다
    func testShortTextCappedAtGlyphSize() {
        let shape = LayoutShape(rect: IRect(x: 0, y: 0, w: 300, h: 300))
        let l = Typesetter.layout("응!", shape: shape, maxSize: 30, minSize: 8, metrics: m)
        XCTAssertEqual(l.fontSize, 30)
        XCTAssertEqual(l.lines.count, 1)
    }

    /// 긴 낱말은 글자 단위로 자르되, 문장부호가 줄 머리에 오지 않는다
    func testLongWordBreaksWithKinsoku() {
        let shape = LayoutShape(rect: IRect(x: 0, y: 0, w: 100, h: 400))
        let l = Typesetter.layout("가나다라마바사아자차카타!!", shape: shape, maxSize: 30, minSize: 30, metrics: m)
        for line in l.lines.dropFirst() {
            XCTAssertFalse(Typesetter.noStart.contains(line.text.first!), "line starts with \(line.text)")
        }
        XCTAssertEqual(l.lines.map(\.text).joined(), "가나다라마바사아자차카타!!")
    }

    /// 줄바꿈 문자는 강제 줄바꿈
    func testHardBreaks() {
        let shape = LayoutShape(rect: IRect(x: 0, y: 0, w: 500, h: 300))
        let l = Typesetter.layout("첫째 줄\n둘째 줄", shape: shape, maxSize: 30, minSize: 8, metrics: m)
        XCTAssertEqual(l.lines.map(\.text), ["첫째 줄", "둘째 줄"])
    }

    /// 줄 길이가 고르게(마지막 줄만 덩그러니 짧지 않게)
    func testBalancedLines() {
        let shape = LayoutShape(rect: IRect(x: 0, y: 0, w: 400, h: 400))
        let l = Typesetter.layout("그런 건 몰라 나는 아무것도 모른다고 몇 번이나 말했잖아", shape: shape, maxSize: 40, minSize: 40, metrics: m)
        XCTAssertGreaterThan(l.lines.count, 1)
        let widths = l.lines.map(\.width)
        XCTAssertLessThan(widths.max()! - widths.min()!, 40 * 3.2)
    }

    /// 아무리 줄여도 안 들어가면 넘침 표시를 하고 모두 배치한다
    func testOverflow() {
        let shape = LayoutShape(rect: IRect(x: 0, y: 0, w: 60, h: 40))
        let text = "아주 긴 번역문이라서 작은 말풍선에 도저히 들어가지 않는 경우"
        let l = Typesetter.layout(text, shape: shape, maxSize: 20, minSize: 10, metrics: m)
        XCTAssertTrue(l.overflow)
        XCTAssertEqual(l.lines.map(\.text).joined(separator: " ").replacingOccurrences(of: " ", with: ""),
                       text.replacingOccurrences(of: " ", with: ""))
    }
}
