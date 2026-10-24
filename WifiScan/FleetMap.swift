import SwiftUI

/// dash 탭 위쪽의 서버 지도. 태평양을 가운데 둔 점 세계 지도 한 장에
/// - 서버 네 대: 켜짐(초록, 숨 쉬는 고리) · 켜지는 중/끄는 중(노랑 깜빡) · 꺼짐(빈 칸)
/// - 이번 달 송신량만큼 서버 둘레에 옅은 원
/// - 지금 이 폰이 붙어 있는 서버까지 you에서 경로
struct FleetMap: View {
    let nodes: [DashData.Node]
    /// 지금 붙어 있는 서버 코드(없으면 nil)
    let liveCode: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 런던(0°)부터 오리건(-120° = 240°)까지가 들어오는 띠. 가운데는 태평양 서쪽.
    private static let centerLon = 120.0
    private static let lonSpan = 300.0
    private static let latTop = 66.0
    private static let latBottom = -12.0
    /// 이 띠의 가로세로 비(뷰 높이를 정할 때 쓴다)
    static let aspect = lonSpan / (RouteMath.mercY(latTop) - RouteMath.mercY(latBottom)) * 0.86

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                draw(&ctx, size: size, now: timeline.date)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(nodes.map { "\($0.code) \($0.state)" }.joined(separator: ", "))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let w = Double(size.width), h = Double(size.height)
        let yTop = RouteMath.mercY(Self.latTop), yBottom = RouteMath.mercY(Self.latBottom)
        // 띠가 상자를 꽉 채우게(남는 쪽은 잘린다)
        let k = max(w / Self.lonSpan, h / (yTop - yBottom))
        let cy = (yTop + yBottom) / 2
        func sx(_ lon: Double) -> Double {
            w / 2 + (RouteMath.unwrap(lon, near: Self.centerLon) - Self.centerLon) * k
        }
        func sy(_ y: Double) -> Double { h / 2 - (y - cy) * k }
        func point(_ geo: GeoPoint) -> CGPoint { CGPoint(x: sx(geo.lon), y: sy(RouteMath.mercY(geo.lat))) }

        // 점 간격이 4pt 넘게 되는 가장 고운 단계
        let levels = WorldDots.levels
        let level = levels.first { $0.cell * k >= 4 } ?? levels[levels.count - 1]
        let dot = max(1.2, min(2.6, level.cell * k * 0.45))
        var land = Path()
        for row in 0..<level.rows {
            let y = sy(WorldDots.yTop - (Double(row) + 0.5) * level.cell)
            guard y > -4, y < h + 4 else { continue }
            for col in 0..<level.cols where level.value(col: col, row: row) != 0 {
                let x = sx(-180 + (Double(col) + 0.5) * level.cell)
                land.addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
            }
        }
        ctx.fill(land, with: .color(Term.dot.opacity(0.8)))

        let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
        let maxGB = max(nodes.map(\.egressGB).max() ?? 0, 1)

        // you → 붙어 있는 서버
        let you = point(GeoPoint.here)
        if let liveCode, let region = VPNRegion(rawValue: liveCode) {
            let arc = RouteArc(from: GeoPoint.here, to: region.geo)
            if !arc.local {
                func screen(_ p: WorldPoint) -> CGPoint { CGPoint(x: sx(p.x), y: sy(p.y)) }
                var path = Path()
                for i in 0...48 {
                    let q = screen(arc.point(at: Double(i) / 48))
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                ctx.stroke(path, with: .color(Term.green.opacity(0.2)), lineWidth: 4)
                ctx.stroke(path, with: .color(Term.green), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                // 경로 위를 흐르는 점 셋
                for i in 0..<3 {
                    let f = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let q = screen(arc.point(at: f))
                    ctx.fill(Path(CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3)),
                             with: .color(Term.green.opacity(0.4 + 0.6 * sin(.pi * f))))
                }
            }
        }

        for node in nodes {
            guard let region = VPNRegion(rawValue: node.code) else { continue }
            let p = point(region.geo)
            let color = Self.color(node.state)

            // 이번 달 송신량 원(넓이가 양에 비례)
            if node.egressGB > 0 {
                let r = 6 + 22 * sqrt(node.egressGB / maxGB)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(color.opacity(0.08)))
            }
            switch node.state {
            case "running":
                let seed = Double(node.code.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 7) / 7
                let u = (t / 2.2 + seed).truncatingRemainder(dividingBy: 1)
                ring(&ctx, p, 5 + 14 * u, color.opacity(0.6 * (1 - u)))
            case "pending", "stopping":
                ring(&ctx, p, 8, color.opacity(0.35 + 0.35 * cos(t * 5)))
            default:
                break
            }
            let rect = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            let filled = node.state == "running" || node.state == "pending" || node.state == "stopping"
            ctx.fill(Path(rect), with: .color(filled ? color : Term.surface))
            ctx.stroke(Path(rect), with: .color(color), lineWidth: 1.2)
            // 오른쪽 가까이에 다른 서버가 있으면(서울 옆 도쿄) 이름을 왼쪽에 단다
            let crowded = nodes.contains { other in
                guard other.code != node.code, let r = VPNRegion(rawValue: other.code) else { return false }
                let q = point(r.geo)
                return q.x > p.x && q.x - p.x < 44 && abs(q.y - p.y) < 16
            }
            label(&ctx, node.code, at: CGPoint(x: crowded ? p.x - 8 : p.x + 8, y: p.y - 6),
                  anchor: crowded ? .trailing : .leading, weight: .semibold,
                  color: node.code == liveCode ? Term.green : Term.text)
        }

        // you: 점은 서버 밑에 숨을 수 있어서 이름은 아래 가운데에
        ctx.fill(Path(ellipseIn: CGRect(x: you.x - 2.5, y: you.y - 2.5, width: 5, height: 5)), with: .color(Term.text))
        ring(&ctx, you, 7, Term.text.opacity(0.4))
        label(&ctx, "you", at: CGPoint(x: you.x, y: you.y + 14), anchor: .center, size: 9, color: Term.text)
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "running": return Term.green
        case "pending", "stopping": return Term.amber
        case "stopped": return Term.muted
        default: return Term.red
        }
    }

    private func ring(_ ctx: inout GraphicsContext, _ center: CGPoint, _ radius: Double, _ color: Color) {
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                   with: .color(color), lineWidth: 1)
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at point: CGPoint, anchor: UnitPoint = .leading,
                       size: CGFloat = 10, weight: Font.Weight = .regular, color: Color) {
        var resolved = ctx.resolve(Text(text).font(Term.mono(size, weight)))
        resolved.shading = .color(color)
        ctx.draw(resolved, at: point, anchor: anchor)
    }
}
