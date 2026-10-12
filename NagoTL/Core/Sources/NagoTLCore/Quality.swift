import Foundation

/// 번역을 그림에 제대로 앉혔는지 보고, 못 앉힌 덩어리가 있는 쪽은 다른 AI의 답과 합친다
public enum Quality {
    /// 번역이 그림에 제대로 안 들어간 덩어리: 원문이 그대로 남았거나, AI가 테두리 글자라고 한 것을 상자 근처에서 못 찾아
    /// 상자째 덮었거나(상자가 엉뚱한 곳을 가리킨 것), 깨알처럼 작게 들어간 것. 효과음은 원문 그대로 두는 게 정상이라 뺀다
    public static func failed(_ block: PageBlock, _ r: Refined, _ p: PlacedText) -> Bool {
        if block.kind == .sfx { return false }
        if r.mode == .keep { return true }
        if r.fallback, outlined(block), [.speech, .thought, .narration, .caption].contains(block.kind) { return true }
        if !p.layout.lines.isEmpty, p.layout.fontSize < max(10, r.glyphSize * 0.5) { return true }
        return false
    }

    static func outlined(_ b: PageBlock) -> Bool {
        guard let f = b.fill, let o = b.outline else { return false }
        return f.distance2(o) >= 100 * 100
    }

    /// 두 자리가 겹치는가(작은 쪽의 30% 넘게)
    static func overlaps(_ a: IRect, _ b: IRect) -> Bool {
        let i = a.intersection(b).area
        return i > 0 && Double(i) >= 0.3 * Double(max(1, min(a.area, b.area)))
    }

    /// 기본 AI의 답에서 잘 들어간 덩어리는 그대로 두고, 못 들어간 자리·빠뜨린 자리는 다른 AI의 덩어리로 채운다.
    /// areas: 기본 답 덩어리마다 실제로 차지한 자리(그림에서 찾은 글자 범위와 AI 상자를 합친 것).
    /// 돌려주는 것: 합친 답, 다른 AI에서 가져온 덩어리 수
    public static func merge(_ primary: PageAnswer, failed: Set<Int>, areas: [IRect],
                             with other: PageAnswer) -> (answer: PageAnswer, added: Int) {
        let kept = primary.blocks.indices.filter { !failed.contains($0) }
        var added: [PageAnswer.Block] = []
        for b in other.blocks {
            let r = b.box.rect
            guard r.area > 0, !b.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // 잘 들어간 덩어리 자리는 건드리지 않는다
            if kept.contains(where: { $0 < areas.count && overlaps(areas[$0], r) }) { continue }
            if added.contains(where: { overlaps($0.box.rect, r) }) { continue }
            added.append(b)
        }
        guard !added.isEmpty else { return (primary, 0) }
        // 못 들어간 덩어리는 다른 AI의 덩어리가 그 자리를 맡으면 뺀다(맡지 않으면 그대로 둔다)
        let dropped = Set(failed.filter { i in
            i < areas.count && added.contains { overlaps(areas[i], $0.box.rect) }
        })
        var out = primary
        out.blocks = primary.blocks.enumerated().filter { !dropped.contains($0.offset) }.map(\.element) + added
        out.new_terms = GlossaryEntry.merge(primary.new_terms, adding: other.new_terms)
        return (out, added.count)
    }
}
