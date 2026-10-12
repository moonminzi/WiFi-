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
        var p = placed(text, for: r, kind: kind, metrics: metrics)
        p.face = face(for: r, kind: kind)
        return p
    }

    static func placed(_ text: String, for r: Refined, kind: BlockKind, metrics: GlyphMetrics) -> PlacedText {
        // 원문 그대로 두는 덩어리는 아무것도 그리지 않는다
        if r.mode == .keep {
            return PlacedText(layout: TextLayout(fontSize: 0, lineHeight: 0, lines: [], overflow: false), color: r.ink, weight: 400)
        }
        let (hi, lo) = sizeRange(r)
        let layout = Typesetter.layout(text, shape: r.shape, maxSize: hi, minSize: lo, metrics: metrics)
        switch r.mode {
        case .clean:
            let weight = kind == .narration || kind == .caption ? 600 : 700
            // 말풍선 밖으로 넘치면 바탕색 테두리로 읽히게
            return PlacedText(layout: layout, color: r.ink, weight: weight,
                              outline: layout.overflow ? r.background : nil, outlineWidth: layout.overflow ? 0.16 : 0)
        case .label:
            return PlacedText(layout: layout, color: r.ink, weight: 700)
        case .keep:
            return PlacedText(layout: TextLayout(fontSize: 0, lineHeight: 0, lines: [], overflow: false), color: r.ink, weight: 400)
        case .art:
            // 그림 위 글자: 원문이 세로이고 세로가 더 크게 들어가면 한글도 세로로
            var chosen = layout
            if r.vertical {
                let v = Typesetter.layoutVertical(text, rect: r.layoutRect, maxSize: hi, minSize: lo)
                // 좁고 긴 자리면 가로는 한 줄에 한두 글자로 쪼개진다 — 세로가 너무 작아지지 않는 한 세로
                let tall = r.layoutRect.h >= r.layoutRect.w * 3 / 2
                if !v.overflow && (chosen.overflow || v.fontSize >= chosen.fontSize * (tall ? 0.8 : 1.08)) { chosen = v }
            }
            // 원문 테두리색 그대로, 테두리가 없던 글자도 그림 위에서 읽히게 얇은 테두리
            let outline = r.outline ?? (r.ink.luminance > 140 ? RGBA(25, 25, 25) : .white)
            return PlacedText(layout: chosen, color: r.ink, weight: 800, outline: outline,
                              outlineWidth: r.outline != nil ? 0.16 : 0.10)
        }
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
