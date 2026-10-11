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
            let s = min(1, 1400 / Double(w), (36_000_000 / (Double(w) * Double(h))).squareRoot())
            return (max(1, Int(Double(w) * s)), max(1, Int(Double(h) * s)))
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
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let bmp = bitmap(img) else { return nil }
        guard let cg = cgImage(bmp) else { return nil }
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

/// 한글 글꼴(시스템 Apple SD 산돌고딕 Neo — 모든 한글 글자가 있고 굵기가 여럿)
enum FontBook {
    static func name(_ weight: Int) -> String {
        switch weight {
        case ..<500: "AppleSDGothicNeo-Medium"
        case ..<650: "AppleSDGothicNeo-SemiBold"
        case ..<750: "AppleSDGothicNeo-Bold"
        default: "AppleSDGothicNeo-ExtraBold"
        }
    }

    static func font(weight: Int, size: CGFloat) -> CTFont {
        CTFontCreateWithName(name(weight) as CFString, size, nil)
    }

    static let metrics = CTMetrics(fontName: name(700))
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
        let font = FontBook.font(weight: t.weight, size: size)
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
}
