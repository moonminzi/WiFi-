import Foundation

/// 글자의 쓰임 — 앱이 쓰임마다 사용자가 고른 글꼴로 그린다
public enum TextFace: String, Codable, Sendable, CaseIterable {
    /// 대사·생각·나레이션(만화 글꼴)
    case dialogue
    /// 효과음·추임새(굵은 글꼴)
    case sfx
    /// 간판·사진 속 글자(반듯한 고딕)
    case plain
}

/// 그릴 글자 한 덩어리 — 앱은 이걸 CoreText로 그대로 그린다
public struct PlacedText: Sendable, Codable, Equatable {
    public var layout: TextLayout
    public var color: RGBA
    /// 글씨 굵기(400 보통, 600 중간, 700 굵게, 800 아주 굵게) — 굵기가 하나뿐인 글꼴은 무시
    public var weight: Int
    /// 어떤 글꼴로 그릴지
    public var face: TextFace = .dialogue
    /// 앱이 이 글에 맞춰 정한 글꼴 이름(고른 글꼴에 없는 글자가 있으면 다른 글꼴로 바꾼 것). nil이면 쓰임으로 고른다
    public var fontName: String?
    /// 글자 테두리 색과 두께(글자 크기 배수). 말풍선 밖으로 넘칠 때·효과음에 쓴다
    public var outline: RGBA?
    public var outlineWidth: Double
    /// 글자 뒤에 까는 반투명 판(효과음 스티커)
    public var plate: RGBA?
    public var plateAlpha: Double

    public init(layout: TextLayout, color: RGBA, weight: Int, outline: RGBA? = nil, outlineWidth: Double = 0,
                plate: RGBA? = nil, plateAlpha: Double = 0, face: TextFace = .dialogue) {
        self.layout = layout
        self.color = color
        self.weight = weight
        self.face = face
        self.outline = outline
        self.outlineWidth = outlineWidth
        self.plate = plate
        self.plateAlpha = plateAlpha
    }
}

extension Typesetter {
    /// 이 덩어리를 어떤 글꼴(쓰임)로 쓸지. 앱은 이 쓰임의 글꼴 폭(metrics)으로 place를 부른다
    public static func face(for r: Refined, kind: BlockKind) -> TextFace {
        switch kind {
        case .sfx: return .sfx
        case .sign: return .plain
        case .other: return r.mode == .label ? .plain : .dialogue
        default: return .dialogue
        }
    }

    /// 덩어리 하나의 번역을 어떤 크기·색·굵기로 어디에 쓸지 정한다
    public static func place(_ text: String, for r: Refined, kind: BlockKind, metrics: GlyphMetrics) -> PlacedText {
        var p = placed(printable(text), for: r, kind: kind, metrics: metrics)
        p.face = face(for: r, kind: kind)
        return p
    }

    static func placed(_ text: String, for r: Refined, kind: BlockKind, metrics: GlyphMetrics) -> PlacedText {
        // 원문 그대로 두는 덩어리는 아무것도 그리지 않는다
        if r.mode == .keep {
            return PlacedText(layout: TextLayout(fontSize: 0, lineHeight: 0, lines: [], overflow: false), color: r.ink, weight: 400)
        }
        var (hi, lo) = sizeRange(r)
        // 효과음은 원문이 차지하던 자리를 채울 만큼 크게(획 조각으로 잰 글자 크기는 효과음 글자보다 작다)
        if kind == .sfx && r.mode == .art { hi = max(hi, Double(min(r.layoutRect.w, r.layoutRect.h)) * 0.9) }
        // 말풍선 없는 그림 위 글자는 세로 원문의 좁은 열 대신 가로로 읽기 좋은 폭(글자 8~9개)까지 양옆으로 넓혀
        // 짧은 줄이 길게 늘어서지 않게 쓴다
        var shape = r.shape
        if r.mode == .art, Double(r.layoutRect.w) < r.glyphSize * 8.5 {
            let grow = Int((r.glyphSize * 8.5 - Double(r.layoutRect.w)) / 2)
            shape = LayoutShape(rect: r.layoutRect.expanded(dx: grow, dy: 0))
        }
        let layout = Typesetter.layout(text, shape: shape, maxSize: hi, minSize: lo, metrics: metrics)
        switch r.mode {
        case .clean:
            let weight = kind == .narration || kind == .caption ? 600 : 700
            // 말풍선 없는 세로 원문 자리는 세로로(가로로 쓰면 한 줄에 두세 글자씩 쪼개진다)
            let chosen = r.closedBubble ? layout : preferVertical(text, r, layout, hi: hi, lo: lo)
            // 말풍선 밖으로 넘치면 바탕색 테두리로 읽히게
            return PlacedText(layout: chosen, color: r.ink, weight: weight,
                              outline: chosen.overflow ? r.background : nil, outlineWidth: chosen.overflow ? 0.16 : 0)
        case .label:
            return PlacedText(layout: preferVertical(text, r, layout, hi: hi, lo: lo), color: r.ink, weight: 700)
        case .keep:
            return PlacedText(layout: TextLayout(fontSize: 0, lineHeight: 0, lines: [], overflow: false), color: r.ink, weight: 400)
        case .art:
            // 그림 위 글자: 원문이 세로이고 세로가 더 크게 들어가면 한글도 세로로
            let chosen = preferVertical(text, r, layout, hi: hi, lo: lo)
            // 원문 테두리색 그대로, 테두리가 없던 글자도 그림 위에서 읽히게 얇은 테두리
            let outline = r.outline ?? (r.ink.luminance > 140 ? RGBA(25, 25, 25) : .white)
            return PlacedText(layout: chosen, color: r.ink, weight: 800, outline: outline,
                              outlineWidth: r.outline != nil ? 0.16 : 0.10)
        }
    }

    /// 그릴 글자로: 색 그림 문자 하트(❤️ — 글꼴에 없어 빨간 그림 문자로 그려진다)는 글자색으로 칠해지는 ♥로
    public static func printable(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars {
            switch u.value {
            case 0xFE0F, 0xFE0E: continue
            case 0x2764, 0x1F496, 0x1F497, 0x1F493, 0x1F495, 0x1F49E, 0x1F498, 0x1F49D, 0x1F9E1, 0x1F49B, 0x1F49A, 0x1F499, 0x1F49C:
                out.unicodeScalars.append("\u{2665}")
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// 한글은 원문이 세로쓰기여도 가로로 쓴다(짧은 줄을 가운데 맞춰 쌓는 한국 만화 식자 — 세로 한글은 읽기 어색하다)
    static func preferVertical(_ text: String, _ r: Refined, _ horizontal: TextLayout, hi: Double, lo: Double) -> TextLayout {
        horizontal
    }

    /// 글자 크기 범위(최대, 최소)
    public static func sizeRange(_ r: Refined) -> (Double, Double) {
        switch r.mode {
        case .clean:
            // 한글은 같은 글자 크기에서 원문(한자·가나)보다 조금 작아 보인다
            return (r.glyphSize * 1.15, max(9, r.glyphSize * 0.45))
        case .label:
            return (r.glyphSize * 0.85, 9)
        case .keep:
            return (10, 9)
        case .art:
            return (max(10, r.glyphSize * 1.1), max(9, r.glyphSize * 0.45))
        }
    }
}
