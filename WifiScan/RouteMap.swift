import SwiftUI

/// vpn 탭의 `// route` 지도. 점으로 찍은 세계 지도 위에 you → 나갈 국가 경로를 그린다.
/// - 대기: 고른 국가까지 점선 경로. 국가를 바꾸면 카메라가 그쪽으로 날아간다
/// - 연결 중: 단계(`hop`)가 바뀔 때마다 웨이포인트가 하나씩 찍히고, 깜빡이는 블록 커서가 경로를 따라간다
/// - 연결됨: 경로를 끝까지 긋고 그 나라로 확대, 나라 점이 초록으로 켜지고 신호가 퍼진다
/// - 실패: 커서가 멈추고 빨갛게 됐다가 사라진다
/// - 대기 중엔 다른 나라로 가는 길도 옅게 그어 두고, 나라 점을 누르면(`onSelect`) 그 나라를 고른다
/// - 연결돼 있으면 실제 주고받는 양만큼 경로 위로 점이 흐른다(받는 건 초록 ← · 보내는 건 하늘색 →)
/// - 네트워크 검사 중엔 you 둘레를 레이더가 돈다
struct RouteMap: View {
    enum Stage: Equatable {
        case idle, connecting, connected, failed
        /// 유니콘 HTTPS: 서버로 안 나간다
        case onDevice
    }

    /// 지도를 어디에 까는지
    enum Chrome: Equatable {
        /// `// route` 상자 안
        case boxed
        /// 화면 위쪽을 꽉 채우는 배경. 위(머리줄)·아래(겹쳐 올라오는 패널)에 가려지는 높이만큼 비켜서 그린다
        case hero(top: CGFloat, bottom: CGFloat)
    }

    let destination: VPNRegion
    let stage: Stage
    /// 지금 진행 단계 한 줄. 값이 바뀔 때마다 웨이포인트를 찍는다.
    let hop: String?
    var chrome: Chrome = .boxed
    /// nil이면 상자용 높이(아이폰 220 · 아이패드 300)
    var height: CGFloat?
    /// 나라 점(또는 그 나라에 있는 you)을 누르면 부른다. nil이면 누를 수 없다.
    var onSelect: ((VPNRegion) -> Void)?
    /// 지금 받는·보내는 속도(바이트/초). 연결돼 있을 때 경로 위 흐름의 양
    var flowDown: Double = 0
    var flowUp: Double = 0
    /// 네트워크 검사 중(레이더)
    var scanning = false

    @State private var model = RouteMapModel()
    /// 움직일 게 없으면 TimelineView를 멈춰 둔다(배터리)
    @State private var awake = true
    @State private var awakeUntil = Date.distantPast
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 한 식이 길면 타입 검사가 시간 안에 안 끝나서(Xcode 16) 지도·누르기·변화 감지를 나눠 둔다
    var body: some View {
        tappableMap
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .onChange(of: stage) { _, newStage in wake(for: newStage == .connected ? 10 : 3.5) }
            .onChange(of: destination) { _, _ in wake(for: 2.5) }
            .onChange(of: hop) { _, _ in wake(for: 2) }
            // 레이더가 켜지고 꺼질 때 서서히(꺼지는 동안 그릴 시간)
            .onChange(of: scanning) { _, _ in wake(for: 1.2) }
            // 주고받는 게 멈추면 흐르던 점이 서서히 사라지는 동안 더 그린다
            .onChange(of: flowing) { _, now in if !now { wake(for: 2.5) } }
            .task(id: awakeUntil) { await sleepWhenIdle() }
    }

    private var tappableMap: some View {
        map
            .frame(maxWidth: .infinity)
            .frame(height: mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in tapped(at: point) }
    }

    private func tapped(at point: CGPoint) {
        guard let onSelect, let region = model.region(near: point) else { return }
        onSelect(region)
    }

    /// 깨워 둔 시간이 지나면 타임라인을 멈춘다
    private func sleepWhenIdle() async {
        let wait = awakeUntil.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        awake = false
    }

    private var map: some View {
        TimelineView(schedule) { timeline in
            Canvas { ctx, size in
                // 멈춰 있던 타임라인의 날짜는 예전 값일 수 있어서 지금 시각과 비교해 늦은 쪽을 쓴다
                let now = max(timeline.date, Date())
                model.sync(stage: stage, destination: destination, hop: hop, chrome: chrome,
                           reduceMotion: reduceMotion, now: now)
                model.flow(down: flowDown, up: flowUp, scanning: scanning, now: now)
                model.draw(&ctx, size: size, now: now)
            }
        }
    }

    /// 60fps로 묶는다(프로모션 120Hz에서 무거운 지도를 매번 그리다 프레임이 튀지 않게)
    private var schedule: AnimationTimelineSchedule {
        let paused = !awake && stage != .connecting && !moving
        return .animation(minimumInterval: 1.0 / 60.0, paused: paused)
    }

    private var mapHeight: CGFloat {
        if let height { return height }
        return sizeClass == .regular ? 300 : 220
    }

    private var corner: CGFloat { chrome == .boxed ? 8 : 0 }

    /// 계속 그려야 하는 움직임(흐름·레이더). 흐름은 주고받는 게 있을 때만 — 가만있으면 멈춰서 배터리를 아낀다
    private var moving: Bool {
        if reduceMotion { return false }
        return scanning || flowing
    }

    private var flowing: Bool {
        stage == .connected && max(flowDown, flowUp) > RouteMapModel.FlowLane.floor
    }

    private func wake(for seconds: Double) {
        awake = true
        awakeUntil = Date().addingTimeInterval(seconds)
    }

    private var accessibilityText: String {
        let here = GeoPoint.here
        if stage == .onDevice { return "route: \(here.city), on-device" }
        let to = destination.geo
        let km = RouteMath.grouped(Int(here.km(to: to)))
        return "route: \(here.city) to \(to.city), \(km) km, \(stage)"
    }
}

/// 지도 상태와 그리기. Canvas가 매 프레임 읽고 고친다(화면 갱신을 부르지 않게 관찰하지 않는 클래스로 둔다).
final class RouteMapModel {
    private enum Framing { case route, focus, origin }

    private let origin = GeoPoint.here
    /// 나라마다 you에서 가는 길(대기 중에 고르지 않은 나라도 옅게 긋는다)
    private let arcs: [VPNRegion: RouteArc] = Dictionary(
        uniqueKeysWithValues: VPNRegion.allCases.map { ($0, RouteArc(from: GeoPoint.here, to: $0.geo)) })
    private var started = false
    private var stage: RouteMap.Stage = .idle
    private var stageAt = Date.distantPast
    private var destination: VPNRegion = .kr
    private var arc = RouteArc(from: GeoPoint.here, to: VPNRegion.kr.geo)
    private var lastHop: String?
    private var run: RouteRun?
    private var framing: Framing = .route
    private var flight: Flight?
    /// 연결되면 경로를 다 그은 뒤 목적지로 확대한다
    private var focusAt: Date?
    private var size = CGSize.zero
    private var reduceMotion = false
    private var chrome: RouteMap.Chrome = .boxed
    private var down = FlowLane()
    private var up = FlowLane()
    private var flowAt: Date?
    private var scanning = false
    private var scanAt = Date.distantPast
    /// 검사가 끝난 시각(레이더가 서서히 사라진다)
    private var scanEndAt: Date?
    /// 카메라가 가만있으면 점 지도 모양은 그대로라 다시 만들지 않는다(레이더·흐름만 움직일 때)
    private var dotKey: [Double] = []
    private var dotLayers: [(land: Path, lit: Path, alpha: Double)] = []
    /// 마지막으로 그린 나라 점의 화면 자리(누른 곳에서 가장 가까운 나라를 찾는다)
    private var hits: [(region: VPNRegion, point: CGPoint)] = []

    /// 배경색: 상자 안은 상자 색, 화면 배경으로 깔면 화면 색
    private var paper: Color { chrome == .boxed ? Term.surface : Term.bg }
    /// 위·아래에 가려지는 높이
    private var insets: (top: Double, bottom: Double) {
        if case .hero(let top, let bottom) = chrome { return (Double(top), Double(bottom)) }
        return (0, 0)
    }

    /// 상단 HUD·하단 줄과 가장자리 흐림 높이
    private static let edgeFade: CGFloat = 34
    /// 같은 도시(서울에서 kr)일 때 목적지를 도는 고리 반지름
    private static let orbit: Double = 22

    // MARK: - 상태 맞추기

    func sync(stage newStage: RouteMap.Stage, destination newDestination: VPNRegion, hop: String?,
              chrome newChrome: RouteMap.Chrome, reduceMotion: Bool, now: Date) {
        self.reduceMotion = reduceMotion
        if newChrome != chrome {
            chrome = newChrome
            flight = nil
        }
        if !started {
            started = true
            destination = newDestination
            arc = arcs[newDestination] ?? RouteArc(from: origin, to: newDestination.geo)
            framing = newStage == .onDevice ? .origin : .route
            stage = newStage == .onDevice ? .onDevice : .idle
        }
        if newDestination != destination {
            let from = camera(at: now)
            destination = newDestination
            arc = arcs[newDestination] ?? RouteArc(from: origin, to: newDestination.geo)
            fly(from: from, now: now)
            // 연결 중에 나라가 바뀌면(갈아타기) 새 길에서 처음부터
            if stage == .connecting, newStage == .connecting { run = RouteRun(start: now) }
        }
        if newStage != stage {
            transition(to: newStage, now: now)
        }
        if hop != lastHop {
            lastHop = hop
            if hop != nil, stage == .connecting { run?.hop(now) }
        }
    }

    /// 경로 위 흐름 한 줄(받기 또는 보내기). 속도가 1초마다 바뀌어도 점이 튀지 않게 상태를 이어 간다:
    /// 자리(phase)는 매 프레임 속도만큼 더해 가고, 양·속도는 목표값을 부드럽게 따라가며,
    /// 주고받는 게 멈추면 점이 계속 흐르면서 1.5초쯤에 걸쳐 사라진다.
    struct FlowLane {
        /// 이보다 느리면(바이트/초) 흐름이 없는 것으로 본다
        static let floor = 400.0
        static let slots = 18
        /// 점이 늘거나 줄 때 앞에서부터 켜고 끄는 자리. 몇 개를 켜든 경로 위에 고르게 퍼진다(반전 비트 순서).
        static let offsets: [Double] = (0..<slots).map { i in
            var x = 0.0, f = 0.5, n = i
            while n > 0 { if n & 1 == 1 { x += f }; f /= 2; n >>= 1 }
            return x
        }

        /// 로그 눈금 속도: 400 B/s → 0, 4 MB/s → 4
        var level = 0.0
        /// 보이는 정도 0…1
        var amount = 0.0
        /// 지금까지 흐른 거리(경로 한 번 = 1)
        var phase = 0.0

        /// 속도에 맞는 점 개수
        var count: Double { min(Double(Self.slots), max(2, 2 + level * 3.5)) }
        /// 지금 보이는 점 개수. count를 1초에 4개씩만 따라가서 점 하나가 0.25초에 걸쳐 나타나고 사라진다
        var shown = 2.0

        mutating func step(rate: Double, active: Bool, dt: Double) {
            let on = active && rate > Self.floor
            if on {
                let target = min(4, log10(rate / Self.floor))
                level += (target - level) * (1 - exp(-dt / 0.8))
            }
            amount += ((on ? 1 : 0) - amount) * (1 - exp(-dt / (on ? 0.35 : 0.5)))
            if amount < 0.002, !on { amount = 0 }
            phase = (phase + (0.22 + 0.08 * level) * dt).truncatingRemainder(dividingBy: 1)
            shown += min(4 * dt, max(-4 * dt, count - shown))
        }
    }

    func flow(down: Double, up: Double, scanning newScanning: Bool, now: Date) {
        // 멈춰 있던 뒤 첫 프레임에 한꺼번에 건너뛰지 않게
        let dt = min(0.1, max(0, flowAt.map { now.timeIntervalSince($0) } ?? 0))
        flowAt = now
        let active = stage == .connected
        self.down.step(rate: down, active: active, dt: dt)
        self.up.step(rate: up, active: active, dt: dt)
        if newScanning, !scanning {
            // 사라지는 중에 다시 켜지면 각도가 튀지 않게 이어 간다
            let resuming = scanEndAt.map { now.timeIntervalSince($0) < 0.6 } ?? false
            if !resuming { scanAt = now }
            scanEndAt = nil
        } else if !newScanning, scanning {
            scanEndAt = now
        }
        scanning = newScanning
    }

    /// 연결 중에 상태가 잠깐 '대기'로 튀었다 돌아와도 경로를 지우지 않고 기다리는 시간
    private static let idleGrace = 1.0

    /// 사라지기로 했지만 아직 유예 시간 안이라 이어 갈 수 있는 경로인지
    private func resumable(at now: Date) -> Bool {
        guard let run, run.failure == nil, run.finish == nil, let gone = run.gone else { return false }
        return gone > now
    }

    private func transition(to newStage: RouteMap.Stage, now: Date) {
        let previous = stage
        stage = newStage
        stageAt = now
        switch newStage {
        case .connecting:
            // 잠깐 대기로 튀었던 거면 같은 경로를 그대로 이어 간다(웨이포인트·커서가 처음부터 다시 그려지지 않게)
            if resumable(at: now) {
                run?.gone = nil
            } else {
                run = RouteRun(start: now)
            }
            focusAt = nil
            setFraming(.route, now: now)
        case .connected:
            if resumable(at: now) { run?.gone = nil }
            // 앱을 연 순간 이미 연결돼 있었거나 실패·사라진 경로만 처음부터 빠르게 긋는다
            if run == nil || run?.failure != nil || run?.gone != nil { run = RouteRun(start: now) }
            run?.complete(now)
            focusAt = now.addingTimeInterval(reduceMotion ? 0 : 0.6)
        case .failed:
            run?.fail(now)
            if run?.gone == nil { run?.gone = now.addingTimeInterval(2.5) }
        case .idle:
            // 연결 중에서 바로 넘어온 거면 유예 시간 동안은 그대로 두었다가 사라진다(그새 다시 연결 중이 되면 이어 간다)
            if run != nil, run?.gone == nil {
                run?.gone = now.addingTimeInterval(previous == .connecting ? Self.idleGrace : 0)
            }
            focusAt = nil
            // 유예 중엔 카메라도 그대로(끊겼다 돌아올 때 화면이 들썩이지 않게)
            if previous != .connecting { setFraming(.route, now: now) }
        case .onDevice:
            run = nil
            focusAt = nil
            setFraming(.origin, now: now)
        }
    }

    private func setFraming(_ newFraming: Framing, now: Date) {
        guard newFraming != framing else { return }
        let from = camera(at: now)
        framing = newFraming
        fly(from: from, now: now)
    }

    // MARK: - 카메라

    private func fly(from: Camera, now: Date) {
        guard size.width > 0, !reduceMotion else {
            flight = nil
            return
        }
        flight = Flight(from: from, to: target(), width: Double(size.width), start: now)
    }

    /// 지금 보여 줄 카메라(날아가는 중이면 중간)
    private func camera(at now: Date) -> Camera {
        let to = target()
        guard let flight else { return to }
        guard let cam = flight.camera(to: to, at: now) else {
            self.flight = nil
            return to
        }
        return cam
    }

    private func target() -> Camera {
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let pad = insets
        // 가려지지 않은 가운데에 오도록 화면에서 이만큼(pt) 내려 그린다
        let shift = (pad.top - pad.bottom) / 2
        let focusZ = log2(min(16, max(9, w / 30)))
        func at(_ p: WorldPoint, z: Double) -> Camera {
            Camera(x: p.x, y: p.y + shift / pow(2, z), z: z)
        }
        switch framing {
        case .origin:
            return at(origin.world, z: focusZ - 0.6)
        case .focus:
            return at(arc.b, z: focusZ)
        case .route:
            if arc.local { return at(arc.b, z: focusZ - 0.35) }
            let apex = arc.point(at: 0.5)
            let xs = [arc.a.x, arc.b.x, apex.x], ys = [arc.a.y, arc.b.y, apex.y]
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let fit = min(max(w - 96, 60) / max(maxX - minX, 1),
                          max(h - pad.top - pad.bottom - 72, 60) / max(maxY - minY, 1),
                          pow(2, focusZ))
            let k = max(fit, w / 400)
            return Camera(x: (minX + maxX) / 2, y: (minY + maxY) / 2 - 4 / k + shift / k, z: log2(k))
        }
    }

    /// 누른 자리에서 가장 가까운 나라(32pt 안)
    func region(near point: CGPoint) -> VPNRegion? {
        func distance(_ p: CGPoint) -> CGFloat { hypot(p.x - point.x, p.y - point.y) }
        let nearest = hits.min { distance($0.point) < distance($1.point) }
        guard let nearest, distance(nearest.point) < 32 else { return nil }
        return nearest.region
    }

    // MARK: - 그리기

    private struct Viewport {
        let cam: Camera
        let k: Double
        let w: Double
        let h: Double

        var x0: Double { cam.x - w / 2 / k }
        var x1: Double { cam.x + w / 2 / k }
        var y0: Double { cam.y - h / 2 / k }
        var y1: Double { cam.y + h / 2 / k }

        func sx(_ x: Double) -> Double { w / 2 + (x - cam.x) * k }
        func sy(_ y: Double) -> Double { h / 2 - (y - cam.y) * k }
        func point(_ p: WorldPoint) -> CGPoint { CGPoint(x: sx(p.x), y: sy(p.y)) }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        guard size.width > 0, size.height > 0 else { return }
        if self.size != size {
            self.size = size
            flight = nil    // 화면 크기가 바뀌면(회전) 바로 새 자리로
        }
        if let focusAt, now >= focusAt {
            self.focusAt = nil
            setFraming(.focus, now: now)
        }
        let cam = camera(at: now)
        let view = Viewport(cam: cam, k: cam.scale, w: Double(size.width), h: Double(size.height))
        hits.removeAll(keepingCapacity: true)

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
        drawDots(&ctx, view: view, now: now)
        drawEdgeFade(&ctx, size: size)
        let radar = radarAlpha(now)
        if (scanning || scanEndAt != nil), radar > 0.005 { drawRadar(&ctx, view: view, now: now, alpha: radar) }
        if stage == .onDevice {
            drawNodes(&ctx, view: view, highlighted: nil)
            drawYou(&ctx, view: view)
        } else {
            drawRoute(&ctx, view: view, now: now)
        }
        drawHUD(&ctx, view: view)
    }

    /// 점 간격이 화면에서 4.5pt쯤 되는 단계를 고르고, 단계가 바뀌는 언저리에서만 두 단계를 섞는다.
    private func drawDots(_ ctx: inout GraphicsContext, view: Viewport, now: Date) {
        let levels = WorldDots.levels
        let lod = min(Double(levels.count - 1), max(0, log2(4.5 / (WorldDots.step * view.k))))
        let lo = Int(lod.rounded(.down))
        let mix = lo >= levels.count - 1 ? 0 : RouteMath.smooth(0.42, 0.58, lod - Double(lo))
        let code: UInt8 = stage == .onDevice ? 0 : destination.mapCode
        let glow: Double
        switch stage {
        case .connected: glow = 0.25 + 0.65 * RouteMath.smooth(0, 0.9, now.timeIntervalSince(stageAt) - 0.5)
        case .connecting: glow = 0.45
        default: glow = 0.3
        }

        let key = [view.cam.x, view.cam.y, view.cam.z, view.w, view.h, Double(code)]
        if key != dotKey {
            dotKey = key
            dotLayers = buildDots(view: view, levels: levels, lo: lo, mix: mix, code: code)
        }
        for layer in dotLayers {
            ctx.fill(layer.land, with: .color(Term.dot.opacity(layer.alpha)))
            ctx.fill(layer.lit, with: .color(Term.green.opacity(layer.alpha * glow)))
        }
    }

    private func buildDots(view: Viewport, levels: [WorldDots.Level], lo: Int, mix: Double,
                           code: UInt8) -> [(land: Path, lit: Path, alpha: Double)] {
        var layers: [(land: Path, lit: Path, alpha: Double)] = []
        for (index, alpha) in [(lo, 1 - mix), (lo + 1, mix)] where alpha > 0.01 && index < levels.count {
            let level = levels[index]
            let cell = level.cell
            let dot = min(3.4, max(1.2, cell * view.k * 0.42))
            let i0 = Int(((view.x0 + 180) / cell).rounded(.down)) - 1
            let i1 = Int(((view.x1 + 180) / cell).rounded(.up))
            let j0 = max(0, Int(((WorldDots.yTop - view.y1) / cell).rounded(.down)) - 1)
            let j1 = min(level.rows - 1, Int(((WorldDots.yTop - view.y0) / cell).rounded(.up)))
            guard i0 <= i1, j0 <= j1 else { continue }
            var land = Path()
            var lit = Path()
            for j in j0...j1 {
                let y = view.sy(WorldDots.yTop - (Double(j) + 0.5) * cell) - dot / 2
                for i in i0...i1 {
                    let v = level.value(col: i, row: j)
                    if v == 0 { continue }
                    let rect = CGRect(x: view.sx(-180 + (Double(i) + 0.5) * cell) - dot / 2, y: y, width: dot, height: dot)
                    if v == code { lit.addRect(rect) } else { land.addRect(rect) }
                }
            }
            layers.append((land, lit, alpha))
        }
        return layers
    }

    /// 가장자리를 배경색으로 흐려서 점이 테두리에서 잘려 보이지 않게.
    /// 화면 배경으로 깔면 머리줄·패널 밑으로 더 길게 흐린다.
    private func drawEdgeFade(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height, side: CGFloat = 28
        let top = Self.edgeFade + CGFloat(insets.top) * 0.8
        let bottom = Self.edgeFade + CGFloat(insets.bottom) * 1.2
        let fade = Gradient(colors: [paper, paper.opacity(0)])
        let bands: [(CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: 0, y: 0, width: side, height: h), CGPoint(x: 0, y: 0), CGPoint(x: side, y: 0)),
            (CGRect(x: w - side, y: 0, width: side, height: h), CGPoint(x: w, y: 0), CGPoint(x: w - side, y: 0)),
            (CGRect(x: 0, y: 0, width: w, height: top), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: top)),
            (CGRect(x: 0, y: h - bottom, width: w, height: bottom), CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - bottom)),
        ]
        for (rect, start, end) in bands {
            ctx.fill(Path(rect), with: .linearGradient(fade, startPoint: start, endPoint: end))
        }
    }

    private func drawRoute(_ ctx: inout GraphicsContext, view: Viewport, now: Date) {
        let curve = arc
        let local = curve.local
        let b = view.point(curve.b)
        func at(_ f: Double) -> CGPoint {
            if local {
                let angle = -Double.pi / 2 + f * 2 * .pi
                return CGPoint(x: b.x + Self.orbit * cos(angle), y: b.y + Self.orbit * sin(angle))
            }
            return view.point(curve.point(at: f))
        }
        func line(_ f0: Double, _ f1: Double) -> Path {
            var path = Path()
            let n = max(2, Int(((f1 - f0) * 72).rounded(.up)))
            for i in 0...n {
                let p = at(f0 + (f1 - f0) * Double(i) / Double(n))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        var fade = 1.0
        if let gone = run?.gone {
            fade = 1 - RouteMath.smooth(0, 0.6, now.timeIntervalSince(gone))
            if fade <= 0 { run = nil }
        }
        let head = run?.head(now) ?? 0
        let failed = run?.failure != nil
        let color = failed ? Term.red : Term.green

        // 고를 수 있는 다른 나라로 가는 길(아주 옅게)
        if stage == .idle || stage == .failed {
            // 임시 서버 나라까지 그으면 지도가 실선 뭉치가 된다 — 늘 있는 서버로 가는 길만
            for region in VPNRegion.fixed where region != destination {
                guard let other = arcs[region], !other.local else { continue }
                var path = Path()
                for i in 0...48 {
                    let p = view.point(other.point(at: Double(i) / 48))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(Term.muted.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
            }
        }

        // 갈 길(점선)
        if run?.finish == nil || fade < 1 {
            let alpha = run == nil ? 0.55 : 0.5 * fade
            ctx.stroke(line(run == nil ? 0 : head, 1), with: .color(Term.muted.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }

        if let run, head > 0.001 {
            // 지나온 길: 옅은 번짐 + 실선
            let path = line(0, head)
            ctx.stroke(path, with: .color(color.opacity(0.18 * fade)), lineWidth: 5)
            ctx.stroke(path, with: .color(color.opacity(fade)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            // 웨이포인트: 머리가 닿으면 찍힌다(작게 튀어나오며)
            for (i, stop) in run.stops.enumerated() where i > 0 {
                // 실패로 멈춘 머리보다 앞에 있는 자리는 찍지 않는다
                let arrive = stop.time.addingTimeInterval(RouteRun.travel)
                guard stop.f <= head + 0.0001, now >= arrive || run.finish != nil else { continue }
                let pop = reduceMotion || now < arrive ? 1 : RouteMath.easeOut(min(1, now.timeIntervalSince(arrive) / 0.26))
                let p = at(stop.f)
                let s = 5 * (1 + 0.8 * (1 - pop))
                let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                var c = ctx
                c.opacity = fade * max(pop, 0.01)
                c.fill(Path(rect), with: .color(paper))
                c.stroke(Path(rect), with: .color(failed && i == run.stops.count - 1 ? Term.red : Term.green), lineWidth: 1.2)
                // 번호는 경로 바깥쪽(위)에
                let normal: CGVector
                if local {
                    normal = CGVector(dx: (p.x - b.x) / Self.orbit, dy: (p.y - b.y) / Self.orbit)
                } else {
                    let q = at(min(1, stop.f + 0.01))
                    let tx = q.x - p.x, ty = q.y - p.y, tl = max(hypot(tx, ty), 0.001)
                    var n = CGVector(dx: ty / tl, dy: -tx / tl)
                    if n.dy > 0 { n = CGVector(dx: -n.dx, dy: -n.dy) }
                    normal = n
                }
                label(&c, String(format: "%02d", i), at: CGPoint(x: p.x + normal.dx * 11, y: p.y + normal.dy * 11),
                      anchor: .center, size: 9, color: Term.muted)
            }
        }

        // 다 그은 경로 위로 실제 주고받는 만큼 점이 흐른다(끊기면 서서히 사라지고, 경로가 지워질 땐 같이 흐려진다)
        if let run, run.finish != nil, head > 0.98, !reduceMotion, down.amount + up.amount > 0 {
            drawFlow(&ctx, at: at, fade: fade)
        }

        drawNodes(&ctx, view: view, highlighted: destination)
        drawYou(&ctx, view: view)

        // 연결되면 목적지에서 신호가 퍼진다(10초쯤 뒤엔 멈춘 고리 하나)
        if stage == .connected {
            let since = now.timeIntervalSince(stageAt) - 0.8
            if since >= 0 {
                if reduceMotion || since > 8 {
                    strokeRing(&ctx, center: b, radius: 14, color: Term.green.opacity(0.35))
                } else {
                    for offset in [0, 1.2] {
                        let p = (since + offset).truncatingRemainder(dividingBy: 2.4) / 2.4
                        strokeRing(&ctx, center: b, radius: 6 + 24 * p, color: Term.green.opacity((1 - p) * 0.55))
                    }
                }
            }
        }
        drawNode(&ctx, view: view, region: destination, on: true)

        // 머리: 머리줄의 커서와 같은 블록 커서
        if let run, run.finish == nil, fade > 0 {
            let p = at(head)
            let phase = now.timeIntervalSince(run.stops[0].time).truncatingRemainder(dividingBy: 1.1)
            let blink = failed || reduceMotion ? 1 : 0.5 + 0.5 * cos(.pi * phase / 0.55)
            var c = ctx
            c.opacity = blink * fade
            c.fill(Path(CGRect(x: p.x - 3, y: p.y - 5.5, width: 6, height: 11)), with: .color(color))
        }
    }

    /// 받는 건 목적지 → you(초록), 보내는 건 you → 목적지(하늘색). 속도가 빠를수록 점이 많고 빠르다(로그 눈금).
    private func drawFlow(_ ctx: inout GraphicsContext, at: (Double) -> CGPoint, fade: Double) {
        let lanes: [(lane: FlowLane, color: Color, toward: Bool, size: Double)] = [
            (down, Term.green, false, 3.2),
            (up, Term.key, true, 2.4),
        ]
        for (lane, color, toward, s) in lanes where lane.amount > 0 {
            let count = lane.shown
            for (i, offset) in FlowLane.offsets.enumerated() {
                // 마지막 하나는 늘고 주는 만큼만 보여서 개수가 바뀔 때도 툭 생기거나 사라지지 않는다
                let weight = min(1, count - Double(i))
                guard weight > 0 else { break }
                var f = (lane.phase + offset).truncatingRemainder(dividingBy: 1)
                if !toward { f = 1 - f }
                let alpha = (0.25 + 0.75 * sin(.pi * f)) * lane.amount * weight * fade   // 양 끝에선 흐려진다
                guard alpha > 0.01 else { continue }
                let p = at(f)
                ctx.fill(Path(CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                         with: .color(color.opacity(alpha)))
            }
        }
    }

    /// you 둘레를 도는 레이더: 퍼지는 고리 셋 + 도는 부채꼴
    /// 켜질 때 0.35초, 꺼질 때 0.6초에 걸쳐 서서히
    private func radarAlpha(_ now: Date) -> Double {
        let fadeIn = RouteMath.smooth(0, 0.35, now.timeIntervalSince(scanAt))
        let fadeOut = scanEndAt.map { 1 - RouteMath.smooth(0, 0.6, now.timeIntervalSince($0)) } ?? 1
        return fadeIn * fadeOut
    }

    /// 레이더: 테두리 원 + 퍼지는 고리 + 꼬리가 옅어지는 부채꼴(원뿔 그라디언트 한 장이라 이음매가 없다)
    private func drawRadar(_ ctx: inout GraphicsContext, view: Viewport, now: Date, alpha: Double) {
        let p = view.point(origin.world)
        let since = now.timeIntervalSince(scanAt)
        let reach = min(110, max(60, view.w * 0.22))
        let scope = Path(ellipseIn: CGRect(x: p.x - reach, y: p.y - reach, width: reach * 2, height: reach * 2))
        ctx.fill(scope, with: .color(Term.green.opacity(0.035 * alpha)))
        ctx.stroke(scope, with: .color(Term.green.opacity(0.18 * alpha)), lineWidth: 1)
        if reduceMotion {
            strokeRing(&ctx, center: p, radius: reach * 0.5, color: Term.green.opacity(0.3 * alpha))
            return
        }
        for k in 0..<2 {
            let u = (since / 2.2 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
            let e = RouteMath.easeOut(u)
            strokeRing(&ctx, center: p, radius: 6 + (reach - 6) * e, color: Term.green.opacity(0.4 * (1 - u) * alpha))
        }

        // 한 바퀴 2.6초, 꼬리 66°
        let angle = since * 2 * .pi / 2.6
        let trail = 1.15
        let span = trail / (2 * .pi)
        let sweep = Gradient(stops: [
            .init(color: Term.green.opacity(0), location: 0),
            .init(color: Term.green.opacity(0.32 * alpha), location: span),
            .init(color: Term.green.opacity(0), location: min(span + 0.003, 1)),
            .init(color: Term.green.opacity(0), location: 1),
        ])
        ctx.fill(scope, with: .conicGradient(sweep, center: p, angle: .radians(angle - trail)))

        let tip = CGPoint(x: p.x + reach * cos(angle), y: p.y + reach * sin(angle))
        var beam = Path()
        beam.move(to: p)
        beam.addLine(to: tip)
        ctx.stroke(beam, with: .color(Term.green.opacity(0.8 * alpha)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4)),
                 with: .color(Term.green.opacity(alpha)))
    }

    /// 다른 나라 노드(you 바로 밑에 있는 건 가려서 뺀다)
    private func drawNodes(_ ctx: inout GraphicsContext, view: Viewport, highlighted: VPNRegion?) {
        for region in VPNRegion.allCases where region != highlighted && origin.km(to: region.geo) > 150 {
            drawNode(&ctx, view: view, region: region, on: false)
        }
    }

    private func drawNode(_ ctx: inout GraphicsContext, view: Viewport, region: VPNRegion, on: Bool) {
        let geo = region.geo
        let base = RouteMath.unwrap(geo.lon, near: view.cam.x)
        for offset in [-360.0, 0, 360] {
            let x = view.sx(base + offset), y = view.sy(RouteMath.mercY(geo.lat))
            guard x > -40, x < view.w + 40, y > -20, y < view.h + 20 else { continue }
            hits.append((region, CGPoint(x: x, y: y)))
            // 임시 서버 나라는 고르기 전엔 작은 점만(유럽에 이름이 겹쳐 쌓이지 않게)
            if region.onDemand && !on {
                let dot = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                ctx.fill(Path(dot), with: .color(paper))
                ctx.stroke(Path(dot), with: .color(Term.muted.opacity(0.7)), lineWidth: 1)
                continue
            }
            let rect = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
            ctx.fill(Path(rect), with: .color(on ? Term.green : paper))
            ctx.stroke(Path(rect), with: .color(on ? Term.green : Term.muted), lineWidth: 1.2)
            let text = on && stage == .connected ? "\(region.rawValue) · \(geo.city)" : region.rawValue
            let dx = on && arc.local && stage != .onDevice ? Self.orbit + 7 : 8
            label(&ctx, text, at: CGPoint(x: x + dx, y: y), anchor: .leading,
                  weight: on ? .semibold : .regular, color: on ? Term.green : Term.muted)
        }
    }

    private func drawYou(_ ctx: inout GraphicsContext, view: Viewport) {
        let p = view.point(origin.world)
        // you 바로 밑에 가려진 나라(서울에서 kr)는 you를 눌러 고른다
        for region in VPNRegion.allCases where origin.km(to: region.geo) <= 150 {
            hits.append((region, p))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4)), with: .color(Term.text))
        strokeRing(&ctx, center: p, radius: 6.5, color: Term.text.opacity(0.35))
        if stage == .onDevice {
            label(&ctx, "you", at: CGPoint(x: p.x, y: p.y + 16), anchor: .center, color: Term.text)
        } else if arc.local {
            // 고리는 꼭대기에서 출발한다
            label(&ctx, "you", at: CGPoint(x: p.x, y: p.y - Self.orbit - 10), anchor: .center, color: Term.text)
        } else {
            label(&ctx, "you", at: CGPoint(x: p.x - 9, y: p.y), anchor: .trailing, color: Term.text)
        }
    }

    /// 왼쪽 위: 카메라 중심 좌표 · 오른쪽 위: 거리 · 왼쪽 아래: 도시 → 도시
    /// 화면 배경으로 깔면 위 줄은 머리줄 밑 오른쪽, 아래 줄은 패널 바로 위로 옮긴다.
    private func drawHUD(_ ctx: inout GraphicsContext, view: Viewport) {
        let hero = chrome != .boxed
        // 넓은 화면(아이패드)에선 글자를 가운데 680pt 단에 맞춘다
        let side = hero ? max(16, (view.w - 680) / 2 + 16) : 10.0
        let topY = hero ? insets.top + 6 : 13
        let bottomY = view.h - insets.bottom - (hero ? 18 : 13)
        let lat = RouteMath.lat(mercY: view.cam.y - (insets.top - insets.bottom) / 2 / view.k)
        let lon = RouteMath.normalized(view.cam.x)
        let coords = String(format: "%.2f°%@ %.2f°%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        if hero {
            label(&ctx, coords, at: CGPoint(x: view.w - side, y: topY), anchor: .trailing, color: Term.muted, backed: true)
        } else {
            label(&ctx, coords, at: CGPoint(x: side, y: topY), anchor: .leading, color: Term.muted, backed: true)
        }

        let to = destination.geo
        let distance: String
        let bottom: String
        switch stage {
        case .onDevice:
            distance = "on-device"
            bottom = "\(origin.city) · no server"
        case .connected:
            distance = arc.local ? "local" : "\(RouteMath.grouped(Int(origin.km(to: to)))) km"
            bottom = "\(origin.city) ══ \(to.city)"
        default:
            distance = arc.local ? "local" : "\(RouteMath.grouped(Int(origin.km(to: to)))) km"
            bottom = "\(origin.city) → \(to.city)"
        }
        if hero {
            label(&ctx, distance, at: CGPoint(x: view.w - side, y: bottomY), anchor: .trailing, color: Term.muted, backed: true)
        } else {
            label(&ctx, distance, at: CGPoint(x: view.w - side, y: topY), anchor: .trailing, color: Term.muted, backed: true)
        }
        label(&ctx, bottom, at: CGPoint(x: side, y: bottomY), anchor: .leading,
              color: stage == .connected ? Term.green : Term.muted, backed: true)
    }

    private func strokeRing(_ ctx: inout GraphicsContext, center: CGPoint, radius: Double, color: Color) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1)
    }

    /// `backed`: 글자 뒤에 배경색 판을 옅게 깐다(HUD — 밑에 깔린 나라 점에 글자가 묻히지 않게)
    private func label(_ ctx: inout GraphicsContext, _ text: String, at point: CGPoint, anchor: UnitPoint,
                       size: CGFloat = 10, weight: Font.Weight = .regular, color: Color, backed: Bool = false) {
        var resolved = ctx.resolve(Text(text).font(Term.mono(size, weight)))
        resolved.shading = .color(color)
        if backed {
            let box = resolved.measure(in: CGSize(width: 1000, height: 100))
            let rect = CGRect(x: point.x - anchor.x * box.width, y: point.y - anchor.y * box.height,
                              width: box.width, height: box.height).insetBy(dx: -4, dy: -2)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Term.bg.opacity(0.75)))
        }
        ctx.draw(resolved, at: point, anchor: anchor)
    }
}
