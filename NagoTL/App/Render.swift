import CoreText
import Foundation
import ImageIO
import NagoTLCore
import UIKit
import UniformTypeIdentifiers

/// 그림 ↔ 픽셀 배열, 크기 맞추기, JPEG
enum Pixels {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Working {
        let cg: CGImage
        let bitmap: Bitmap
    }

    /// 번역·그리기에 쓸 크기: 보통 그림은 Claude가 그대로 받는 한도 안(좌표가 1:1),
    /// 세로로 긴 웹툰은 폭만 줄여(조각내서 보낸다)
    static func workingSize(_ w: Int, _ h: Int) -> (Int, Int) {
        guard w > 0, h > 0 else { return (w, h) }
        if Double(h) > Double(w) * Tiler.tallRatio {
            // 폭이 좁은 웹툰은 900px까지 키우고, 넓으면 1400px로 줄인다
            let s = min(max(1, 900 / Double(w)), 1400 / Double(w), (36_000_000 / (Double(w) * Double(h))).squareRoot())
            return (max(1, Int(Double(w) * s)), max(1, Int(Double(h) * s)))
        }
        // 작은 그림(저해상도 스캔·캡처)은 키워서 읽는다: 작은 글자도 또렷이, 번역 글자도 매끈하게
        let long = Double(max(w, h))
        if long < 1600 {
            let s = min(2, 1600 / long)
            return ClaudeAPI.fittedSize(width: Int(Double(w) * s), height: Int(Double(h) * s))
        }
        return ClaudeAPI.fittedSize(width: w, height: h)
    }

    /// 원본을 읽어 작업 크기로(사진 방향 바로잡기, 투명한 곳은 흰 바탕)
    static func loadWorking(_ url: URL) -> Working? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? UInt32, o >= 5 { swap(&w, &h) }
        let (tw, th) = workingSize(w, h)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(tw, th),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // 썸네일은 키워 주지 않으므로 작은 그림은 따로 키운다
        if img.width < tw || img.height < th, let big = resized(img, width: tw, height: th) { img = big }
        guard let bmp = bitmap(img), let cg = cgImage(bmp) else { return nil }
        return Working(cg: cg, bitmap: bmp)
    }

    static func bitmap(_ img: CGImage) -> Bitmap? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Bitmap(width: w, height: h, pixels: pixels) : nil
    }

    static func cgImage(_ bmp: Bitmap) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bmp.pixels) as CFData) else { return nil }
        return CGImage(width: bmp.width, height: bmp.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bmp.width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 크기를 바꿔 그린다
    static func resized(_ img: CGImage, width: Int, height: Int) -> CGImage? {
        if img.width == width && img.height == height { return img }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func jpeg(_ img: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// 세로 모드: 폭이 maxWidth를 넘지 않게 줄여 읽는다
    static func displayFittingWidth(_ url: URL, maxWidth: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? UInt32, o >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { return nil }
        let s = min(1, Double(maxWidth) / Double(w))
        return display(url, maxPixel: Int(Double(max(w, h)) * s))
    }

    /// 화면에 보일 그림(너무 크면 줄여서 읽는다)
    static func display(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 한글 글꼴: 만화용 글꼴(SIL OFL, 앱에 넣음)을 쓰임(대사·효과음)마다 사용자가 고르고,
/// 간판·사진 속 글자는 시스템 Apple SD 산돌고딕 Neo(굵기가 여럿)
enum FontBook {
    enum Choice: String, CaseIterable, Identifiable {
        case jua, blackHanSans, doHyeon, nanumGothic, nanumPen, system

        var id: String { rawValue }

        var label: String {
            switch self {
            case .jua: "주아"
            case .blackHanSans: "검은고딕"
            case .doHyeon: "도현"
            case .nanumGothic: "나눔고딕 ExtraBold"
            case .nanumPen: "나눔손글씨 펜"
            case .system: "시스템 고딕(산돌고딕 Neo)"
            }
        }

        /// 앱에 넣은 글꼴의 PostScript 이름(시스템 글꼴은 굵기마다 따로라 nil)
        var postScript: String? {
            switch self {
            case .jua: "Jua-Regular"
            case .blackHanSans: "BlackHanSans-Regular"
            case .doHyeon: "DoHyeon-Regular"
            case .nanumGothic: "NanumGothicExtraBold"
            case .nanumPen: "NanumPen-Regular"
            case .system: nil
            }
        }
    }

    static let dialogueKey = "tl.font.dialogue"
    static let sfxKey = "tl.font.sfx"
    static let dialogueOptions: [Choice] = [.jua, .nanumGothic, .doHyeon, .nanumPen, .system]
    static let sfxOptions: [Choice] = [.blackHanSans, .jua, .doHyeon, .nanumGothic, .system]

    /// 쓰임마다 고른 글꼴(기본: 대사 주아, 효과음 검은고딕)
    static func choice(for face: TextFace) -> Choice {
        switch face {
        case .dialogue: Choice(rawValue: UserDefaults.standard.string(forKey: dialogueKey) ?? "") ?? .jua
        case .sfx: Choice(rawValue: UserDefaults.standard.string(forKey: sfxKey) ?? "") ?? .blackHanSans
        case .plain: .system
        }
    }

    static func systemName(_ weight: Int) -> String {
        switch weight {
        case ..<500: "AppleSDGothicNeo-Medium"
        case ..<650: "AppleSDGothicNeo-SemiBold"
        case ..<750: "AppleSDGothicNeo-Bold"
        default: "AppleSDGothicNeo-ExtraBold"
        }
    }

    static func fontName(_ choice: Choice, weight: Int) -> String { choice.postScript ?? systemName(weight) }

    static func font(face: TextFace, weight: Int, size: CGFloat) -> CTFont {
        CTFontCreateWithName(fontName(choice(for: face), weight: weight) as CFString, size, nil)
    }

    private static var metricsCache: [String: CTMetrics] = [:]
    private static let lock = NSLock()

    /// 그 쓰임의 글꼴로 잰 글자 폭(줄 나누기·크기 찾기에 쓴다)
    static func metrics(for face: TextFace) -> CTMetrics {
        let name = fontName(choice(for: face), weight: 700)
        lock.lock()
        defer { lock.unlock() }
        if let m = metricsCache[name] { return m }
        let m = CTMetrics(fontName: name)
        metricsCache[name] = m
        return m
    }
}

/// CoreText 글꼴의 실제 글자 폭(글자 크기 1 기준)
final class CTMetrics: GlyphMetrics, @unchecked Sendable {
    private let font: CTFont
    private var cache: [Character: Double] = [:]
    private let lock = NSLock()

    init(fontName: String) {
        font = CTFontCreateWithName(fontName as CFString, 100, nil)
    }

    func advance(_ c: Character) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let v = cache[c] { return v }
        let utf16 = Array(String(c).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        var value = 1.0
        if CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) {
            var adv = [CGSize](repeating: .zero, count: glyphs.count)
            value = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &adv, glyphs.count) / 100
        } else {
            // 이 글꼴에 없는 글자(이모지 등)는 CoreText가 다른 글꼴로 그린다
            let attr = NSAttributedString(string: String(c),
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            value = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil) / 100
        }
        cache[c] = value
        return value
    }
}

/// 지운 그림 위에 번역 글자를 그린다
enum Painter {
    static func color(_ c: RGBA, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(alpha))
    }

    static func draw(base: CGImage, texts: [PlacedText]) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Pixels.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 왼쪽 위가 원점(그림 좌표와 같게)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        for t in texts { draw(t, in: ctx) }
        return ctx.makeImage()
    }

    static func draw(_ t: PlacedText, in ctx: CGContext) {
        guard !t.layout.lines.isEmpty else { return }
        let size = CGFloat(t.layout.fontSize)
        let font = FontBook.font(face: t.face, weight: t.weight, size: size)
        if t.layout.vertical {
            drawVertical(t, font: font, in: ctx)
            return
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lh = CGFloat(t.layout.lineHeight)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        if let plate = t.plate {
            let b = t.layout.bounds
            let rect = CGRect(x: b.x - size * 0.35, y: b.y - size * 0.08, width: b.w + size * 0.7, height: b.h + size * 0.16)
            ctx.setFillColor(color(plate, alpha: t.plateAlpha))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
            ctx.fillPath()
        }
        for line in t.layout.lines where !line.text.isEmpty {
            let fill = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                fontKey: font, colorKey: color(t.color),
            ]))
            // 실제 폭으로 다시 가운데 맞춤(어림 폭과 조금 다를 수 있다)
            let actual = CGFloat(CTLineGetTypographicBounds(fill, nil, nil, nil))
            let x = CGFloat(line.x) + (CGFloat(line.width) - actual) / 2
            let baseline = CGFloat(line.y) + (lh - (ascent + descent)) / 2 + ascent
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if let outline = t.outline, t.outlineWidth > 0 {
                // 테두리: 글자 크기의 몇 %인지로 준다(양쪽으로 퍼지므로 두 배)
                let stroke = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                    fontKey: font,
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): t.outlineWidth * 200,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): color(outline),
                ]))
                ctx.setLineJoin(.round)
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(stroke, ctx)
            }
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(fill, ctx)
            ctx.restoreGState()
        }
    }

    /// 세로쓰기: 열은 오른쪽부터, 글자는 한 칸씩 세워서(괄호·줄표·물결은 돌리고, 쉼표·마침표는 칸 오른쪽 위)
    static func drawVertical(_ t: PlacedText, font: CTFont, in ctx: CGContext) {
        let s = CGFloat(t.layout.fontSize)
        let lh = CGFloat(t.layout.lineHeight)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        func line(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        // 세운 글자는 모두 "가"의 몸통 가운데를 칸 가운데에 맞춘다(글자마다 들쭉날쭉하지 않게)
        let ref = CTLineGetBoundsWithOptions(line("가", [fontKey: font]), .useGlyphPathBounds)

        struct Cell {
            let text: String
            let style: VerticalGlyph
            let cx: CGFloat
            let cy: CGFloat
            let advance: CGFloat
            let bounds: CGRect
        }
        let metrics = VerticalMetrics()
        var cells: [Cell] = []
        for col in t.layout.lines {
            var y = CGFloat(col.y)
            let cx = CGFloat(col.x) + lh / 2
            for ch in col.text {
                let step = CGFloat(metrics.advance(ch)) * s
                defer { y += step }
                if ch.isWhitespace { continue }
                let plain = line(String(ch), [fontKey: font])
                cells.append(Cell(text: String(ch), style: VerticalGlyph.of(ch), cx: cx, cy: y + step / 2,
                                  advance: CGFloat(CTLineGetTypographicBounds(plain, nil, nil, nil)),
                                  bounds: CTLineGetBoundsWithOptions(plain, .useGlyphPathBounds)))
            }
        }
        // 테두리를 먼저 다 그리고 글자를 그 위에(옆 글자 테두리가 글자를 덮지 않게)
        var passes: [[NSAttributedString.Key: Any]] = []
        if let outline = t.outline, t.outlineWidth > 0 {
            passes.append([
                fontKey: font,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): t.outlineWidth * 200,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): color(outline),
            ])
        }
        passes.append([fontKey: font, colorKey: color(t.color)])
        for attrs in passes {
            for c in cells {
                let glyph = line(c.text, attrs)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.setLineJoin(.round)
                switch c.style {
                case .upright:
                    ctx.textPosition = CGPoint(x: c.cx - c.advance / 2, y: c.cy + ref.midY)
                case .centered:
                    ctx.textPosition = CGPoint(x: c.cx - c.bounds.midX, y: c.cy + c.bounds.midY)
                case .corner:
                    ctx.textPosition = CGPoint(x: c.cx + s * 0.26 - c.bounds.midX, y: c.cy - s * 0.26 + c.bounds.midY)
                case .rotated:
                    // 위가 아래로 오는 그림 좌표라 +90°가 화면에서 시계 방향
                    ctx.translateBy(x: c.cx, y: c.cy)
                    ctx.rotate(by: .pi / 2)
                    ctx.textPosition = CGPoint(x: -c.bounds.midX, y: c.bounds.midY)
                }
                CTLineDraw(glyph, ctx)
                ctx.restoreGState()
            }
        }
    }
}
