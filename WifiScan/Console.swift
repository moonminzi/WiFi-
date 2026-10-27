import SwiftUI

// vpn 탭 콘솔(지도 위로 올라오는 패널)에 쓰는 조각들.

/// 머리줄 오른쪽 `● secured` 알약. 연결돼 있으면 불이 숨을 쉰다.
struct StatusPill: View {
    enum Kind { case on, busy, error, off }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            // 켜져 있으면 천천히 숨 쉬고(빛 번짐), 연결 중이면 빠르게 깜빡인다
            Pulse(period: kind == .busy ? 1.1 : 2.6, active: kind == .on || kind == .busy) { phase in
                PillDot(color: color, phase: phase, halo: kind == .on, blink: kind == .busy)
            }
            Text(text)
                .font(Term.mono(12, .semibold))
                .foregroundStyle(kind == .off ? Term.muted : color)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Term.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(kind == .off ? Term.border : color.opacity(0.45), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: kind)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch kind {
        case .on: Term.green
        case .busy: Term.amber
        case .error: Term.red
        case .off: Term.muted
        }
    }
}

/// 알약 안 점: 켜져 있으면 둘레로 빛이 번졌다 잦아들고(halo), 연결 중이면 깜빡인다(blink)
private struct PillDot: View {
    let color: Color
    let phase: Double
    let halo: Bool
    let blink: Bool

    var body: some View {
        let ring = CGFloat(7 + 8 * phase)
        let haloAlpha = halo ? 0.35 * (1 - phase) : 0
        let dotAlpha = blink ? 1 - 0.6 * phase : 1
        return ZStack {
            Circle().fill(color.opacity(haloAlpha)).frame(width: ring, height: ring)
            Circle().fill(color).frame(width: 7, height: 7).opacity(dotAlpha)
        }
        .frame(width: 15, height: 15)
    }
}

/// 지도 위 머리줄 쪽에서 번지는 상태 빛. secured 초록 · linking 노랑(숨 쉼) · failed 빨강, exposed는 없음.
/// 상태가 바뀌면 0.9초에 걸쳐 서로 스며든다.
struct StateGlow: View {
    let kind: StatusPill.Kind

    var body: some View {
        ZStack {
            glow(Term.green).opacity(kind == .on ? 1 : 0)
            Pulse(period: 1.8, active: kind == .busy) { phase in
                glow(Term.amber).opacity(kind == .busy ? 0.55 + 0.45 * phase : 0)
            }
            glow(Term.red).opacity(kind == .error ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.9), value: kind)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color) -> some View {
        RadialGradient(colors: [color.opacity(0.22), color.opacity(0)],
                       center: UnitPoint(x: 0.82, y: 0), startRadius: 4, endRadius: 340)
    }
}

/// 접속 시간 `12:34` — 숫자가 바뀔 때 굴러가듯
struct SessionClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            let seconds = Int(max(0, timeline.date.timeIntervalSince(since)))
            Text(VPNView.clock(TimeInterval(seconds)))
                .font(Term.mono(22, .semibold))
                .foregroundStyle(Term.num)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: seconds)
        }
    }
}

/// 카드처럼 누르는 것: 누르면 살짝 작아졌다가 튕겨 돌아온다
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 접었다 펴는 패널 머리줄의 화살표(▸ 접힘 · ▾ 펼침)
struct FoldChevron: View {
    let folded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Term.muted)
            .rotationEffect(.degrees(folded ? 0 : 90))
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

/// 연결 진행 `api › boot › tunnel › up`. 지난 칸은 초록, 지금 칸은 노랗게 깜빡인다.
struct PhasePipeline: View {
    let index: Int
    /// 유니콘 HTTPS는 서버를 켜지 않는다
    var onDevice = false

    private var labels: [String] { onDevice ? ["config", "local", "tunnel", "up"] : ["api", "boot", "tunnel", "up"] }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    Pulse(period: 1.1, active: i == index) { phase in
                        Capsule()
                            .fill(fill(i))
                            .frame(height: 3)
                            .opacity(1 - 0.65 * phase)
                    }
                    .frame(height: 3)
                    Text(labels[i])
                        .font(Term.mono(10, i == index ? .semibold : .regular))
                        .foregroundStyle(i <= index ? (i == index ? Term.amber : Term.green) : Term.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.3), value: index)
        .accessibilityElement()
        .accessibilityLabel("step \(min(index, labels.count - 1) + 1) of \(labels.count): \(labels[min(index, labels.count - 1)])")
    }

    private func fill(_ i: Int) -> Color {
        if i < index { return Term.green }
        if i == index { return Term.amber }
        return Term.track
    }
}

/// 나라 국기를 지도와 같은 점(LED)으로 찍는다. 이모지 국기는 기기·글꼴마다 모양이 달라서 터미널 화면에서 튄다.
/// 15×9 점 그림. kr jp us uk는 안드로이드(DotFlag.kt)와 같다. 라이트에선 판을 조금 어둡게 해서 흰 점이 보이게.
struct DotFlag: View {
    let region: VPNRegion
    /// 판 너비(pt). 높이는 15:9 비율에 여백을 더한 만큼
    var width: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    static let cols = 15
    static let rows = 9

    /// W 흰 · R 빨강 · B 파랑(태극) · N 남색(성조기) · U 파랑(유니언 잭) · K 검정(괘)
    /// G 초록 · Y 노랑 · O 주황 · S 하늘색(스웨덴)
    static let art: [VPNRegion: [String]] = [
        .kr: ["WWKWWWWWWWWWKWW", "WKKKWWWWWWWKKKW", "WKKWWWRRRWWWKKW", "WWWWWRRRBBWWWWW", "WWWWWRRRBBWWWWW",
              "WWWWWRRBBBWWWWW", "WKKWWWBBBWWWKKW", "WKKKWWWWWWWKKKW", "WWKWWWWWWWWWKWW"],
        .jp: ["WWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWW", "WWWWWWRRRWWWWWW", "WWWWWRRRRRWWWWW", "WWWWWRRRRRWWWWW",
              "WWWWWRRRRRWWWWW", "WWWWWWRRRWWWWWW", "WWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWW"],
        .us: ["NNNNNNRRRRRRRRR", "NWNWNWWWWWWWWWW", "NNNNNNRRRRRRRRR", "NWNWNWWWWWWWWWW", "NNNNNNRRRRRRRRR",
              "WWWWWWWWWWWWWWW", "RRRRRRRRRRRRRRR", "WWWWWWWWWWWWWWW", "RRRRRRRRRRRRRRR"],
        .uk: ["RRWUUUWRWUUUWRR", "WWRWWUWRWUWWRWW", "UUWRRWWRWWRRWUU", "WWWWWWWRWWWWWWW", "RRRRRRRRRRRRRRR",
              "WWWWWWWRWWWWWWW", "UUWRRWWRWWRRWUU", "WWRWWUWRWUWWRWW", "RRWUUUWRWUUUWRR"],
        .sg: ["RRWWRRWRRRRRRRR", "RWRRRWRWRRRRRRR", "RWRRRRRRRRRRRRR", "RRWWRWRWRRRRRRR", "RRRRRRRRRRRRRRR",
              "WWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWW"],
        .de: ["KKKKKKKKKKKKKKK", "KKKKKKKKKKKKKKK", "KKKKKKKKKKKKKKK", "RRRRRRRRRRRRRRR", "RRRRRRRRRRRRRRR",
              "RRRRRRRRRRRRRRR", "YYYYYYYYYYYYYYY", "YYYYYYYYYYYYYYY", "YYYYYYYYYYYYYYY"],
        .fr: ["BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR",
              "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR", "BBBBBWWWWWRRRRR"],
        .ie: ["GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO",
              "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO", "GGGGGWWWWWOOOOO"],
        .se: ["SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS", "YYYYYYYYYYYYYYY",
              "SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS", "SSSSSYSSSSSSSSS"],
        .ca: ["RRRRWWWWWWWRRRR", "RRRRWWWRWWWRRRR", "RRRRWRWRWRWRRRR", "RRRRWRRRRRWRRRR", "RRRRWRRRRRWRRRR",
              "RRRRWWRRRWWRRRR", "RRRRWWWRWWWRRRR", "RRRRWWWRWWWRRRR", "RRRRWWWWWWWRRRR"],
        .br: ["GGGGGGGYGGGGGGG", "GGGGGYYYYYGGGGG", "GGGYYYNNNYYYGGG", "GGYYYNNNNNYYYGG", "GYYYYNWWWNYYYYG",
              "GGYYYNNNNNYYYGG", "GGGYYYNNNYYYGGG", "GGGGGYYYYYGGGGG", "GGGGGGGYGGGGGGG"],
        .au: ["WNNRNNWNNNNWNNN", "NWNRNWNNNNNNNNN", "RRRRRRRNNNNNNWN", "NWNRNWNNNWNNNNN", "WNNRNNWNNNNNWNN",
              "NNNNNNNNNNNNNNN", "NNNWNNNNNNNWNNN", "NNWWWNNNNNNNNNN", "NNNWNNNNNNNNNNN"],
        .in: ["OOOOOOOOOOOOOOO", "OOOOOOOOOOOOOOO", "OOOOOOOOOOOOOOO", "WWWWWWWNWWWWWWW", "WWWWWWNWNWWWWWW",
              "WWWWWWWNWWWWWWW", "GGGGGGGGGGGGGGG", "GGGGGGGGGGGGGGG", "GGGGGGGGGGGGGGG"],
    ]

    static func height(for width: CGFloat) -> CGFloat {
        let pad = width * 0.06
        return (width - 2 * pad) / CGFloat(cols) * CGFloat(rows) + 2 * pad
    }

    var body: some View {
        let dark = scheme == .dark
        Canvas { ctx, size in
            let pad = size.width * 0.06
            let pitch = (size.width - 2 * pad) / CGFloat(Self.cols)
            let dot = pitch * 0.78
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: max(2, pitch * 1.1)),
                     with: .color(dark ? Term.chrome : Term.border))
            for (j, row) in (Self.art[region] ?? []).enumerated() {
                for (i, ch) in row.enumerated() {
                    let rect = CGRect(x: pad + CGFloat(i) * pitch + (pitch - dot) / 2,
                                      y: pad + CGFloat(j) * pitch + (pitch - dot) / 2, width: dot, height: dot)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: dot * 0.28), with: .color(Self.color(ch, dark: dark)))
                }
            }
        }
        .frame(width: width, height: Self.height(for: width))
        .accessibilityHidden(true)
    }

    private static func color(_ ch: Character, dark: Bool) -> Color {
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch ch {
        case "R": return rgb(0xD63440)
        case "B": return rgb(0x284AAA)
        case "N": return rgb(0x2C3878)
        case "U": return rgb(0x243E8C)
        case "K": return rgb(dark ? 0x3A403A : 0x1C1E1C)
        case "G": return rgb(0x1E9A50)
        case "Y": return rgb(0xF2C230)
        case "O": return rgb(0xF08A3C)
        case "S": return rgb(0x2B6CB0)
        default: return rgb(dark ? 0xE8ECE5 : 0xFFFFFF)
        }
    }
}

/// 나갈 국가 카드 한 장: 깃발, 코드, 도시, 대략 왕복 시간
struct RegionCard: View {
    let region: VPNRegion
    let selected: Bool
    /// 지금 이 나라로 붙어 있다
    let live: Bool
    /// 실제로 잰 왕복 시간(ms). 없으면 거리로 어림한다.
    var measured: Int?
    /// 잰 것 중 가장 빠른 나라
    var fastest = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    DotFlag(region: region, width: 28)
                    Spacer(minLength: 2)
                    if live {
                        Circle().fill(Term.green).frame(width: 6, height: 6)
                            .shadow(color: Term.green, radius: 3)
                    } else if fastest {
                        Text("fast")
                            .font(Term.mono(8.5, .semibold))
                            .foregroundStyle(Term.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Term.green.opacity(0.6), lineWidth: 1))
                    }
                }
                Text(region.rawValue)
                    .font(Term.mono(16, .bold))
                    .foregroundStyle(selected ? Term.green : Term.num)
                Text(region.geo.city)
                    .font(Term.mono(10))
                    .foregroundStyle(Term.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(measured.map { "\($0)ms" } ?? "~\(Self.rtt(region))ms")
                    .font(Term.mono(10, measured == nil ? .regular : .semibold))
                    .foregroundStyle(rttColor)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: measured)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Term.green.opacity(0.08) : Term.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Term.green : Term.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressScale())
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityLabel("\(region.geo.city), \(measured.map { "\($0)" } ?? "about \(Self.rtt(region))") milliseconds")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 잰 값은 빠를수록 초록 → 노랑 → 빨강
    private var rttColor: Color {
        guard let measured else { return selected ? Term.key : Term.muted }
        if measured < 80 { return Term.green }
        if measured < 180 { return Term.amber }
        return Term.red
    }

    /// 빛이 광섬유로 1ms에 200km쯤 가니 왕복은 km/100ms. 장비·우회 몫으로 조금 더한다(어림값).
    static func rtt(_ region: VPNRegion) -> Int {
        let km = GeoPoint.here.km(to: region.geo)
        return Int((km / 100 * 1.3 + 6).rounded())
    }
}

/// 임시 서버 나라 한 칸: 작은 깃발 · 코드 · 왕복 시간. 카드보다 훨씬 작게(여러 개가 두 줄에 들어가게)
struct RegionChip: View {
    let region: VPNRegion
    let selected: Bool
    let live: Bool
    var measured: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                DotFlag(region: region, width: 18)
                Text(region.rawValue)
                    .font(Term.mono(12, .bold))
                    .foregroundStyle(selected ? Term.green : Term.num)
                if live {
                    Circle().fill(Term.green).frame(width: 5, height: 5)
                        .shadow(color: Term.green, radius: 2)
                } else {
                    // 좁은 화면(SE)에선 칸이 좁아 "238ms"가 잘린다 — 들어가지 않으면 숫자만
                    let ms = measured.map { "\($0)" } ?? "~\(RegionCard.rtt(region))"
                    ViewThatFits(in: .horizontal) {
                        Text(ms + "ms")
                        Text(ms)
                    }
                    .font(Term.mono(9, measured == nil ? .regular : .semibold))
                    .foregroundStyle(Term.muted)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Term.green.opacity(0.08) : Term.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Term.green : Term.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressScale())
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityLabel("\(region.geo.city), on demand, \(measured.map { "\($0)" } ?? "about \(RegionCard.rtt(region))") milliseconds")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `wg/neptun` `adblock` 처럼 지금 설정을 칩으로
struct FlagRow: View {
    let flags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(flags, id: \.self) { flag in
                    Text(flag)
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.border, lineWidth: 1))
                }
            }
        }
        .scrollClipDisabled()
    }
}

/// 연결 중 버튼 위를 훑고 지나가는 빛
struct ScanSweep: View {
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation) { timeline in
                GeometryReader { geo in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let band = geo.size.width * 0.35
                    LinearGradient(colors: [tint.opacity(0), tint.opacity(0.22), tint.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * t)
                }
            }
        }
    }
}

/// 연결돼 있는 동안 `↓ 2.4 MB/s  ↑ 120 KB/s` + 최근 1분 막대
struct TrafficPanel: View {
    let meter: TrafficMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                speed("↓", meter.current?.down ?? 0, Term.green)
                speed("↑", meter.current?.up ?? 0, Term.key)
                Spacer(minLength: 0)
                Text("\(TrafficMeter.bytes(meter.totalDown)) ↓ · \(TrafficMeter.bytes(meter.totalUp)) ↑")
                    .font(Term.mono(10.5))
                    .foregroundStyle(Term.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Sparkline(history: meter.history)
                .frame(height: 34)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func speed(_ arrow: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(arrow).foregroundStyle(color)
            Text(TrafficMeter.speed(value)).foregroundStyle(Term.num)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .font(Term.mono(15, .semibold))
    }
}

/// 받은 양(초록 면)과 보낸 양(하늘색 선). 오른쪽 끝이 지금이다.
struct Sparkline: View {
    let history: [TrafficMeter.Rate]

    var body: some View {
        Canvas { ctx, size in
            let n = TrafficMeter.window
            let peak = max(history.map { max($0.down, $0.up) }.max() ?? 0, 50_000)
            let step = size.width / CGFloat(n - 1)
            let offset = n - history.count
            func point(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: CGFloat(i + offset) * step, y: size.height - CGFloat(v / peak) * (size.height - 2) - 1)
            }
            // 바닥선
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Term.border), lineWidth: 1)
            guard history.count > 1 else { return }

            var down = Path()
            var area = Path()
            for (i, rate) in history.enumerated() {
                let p = point(i, rate.down)
                if i == 0 {
                    down.move(to: p)
                    area.move(to: CGPoint(x: p.x, y: size.height))
                }
                down.addLine(to: p)
                area.addLine(to: p)
            }
            area.addLine(to: CGPoint(x: point(history.count - 1, 0).x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Term.green.opacity(0.35), Term.green.opacity(0.02)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(down, with: .color(Term.green), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))

            var up = Path()
            for (i, rate) in history.enumerated() {
                let p = point(i, rate.up)
                if i == 0 { up.move(to: p) } else { up.addLine(to: p) }
            }
            ctx.stroke(up, with: .color(Term.key.opacity(0.8)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

            if let last = history.last {
                let p = point(history.count - 1, last.down)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Term.green))
            }
        }
    }
}

/// 네트워크 검사 결과: 등급 + 한 줄 판정 + 검사마다 한 줄
struct ScanPanel: View {
    let scan: NetScan
    let vpnOn: Bool
    /// 접으면 머리줄 한 줄(등급·한마디)만 남는다
    @Binding var folded: Bool
    let rescan: () -> Void
    /// vpn 탭 isp 줄과 같은 설정: 켜져 있으면 exit 줄의 IP도 가린다
    @AppStorage("hideIP") private var hideIP = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !folded {
                result
            }
        }
        .padding(folded ? 10 : 12)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
    }

    /// 머리줄을 누르면 접고 편다(다시 검사 단추는 따로)
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FoldChevron(folded: folded)
            Text("// net scan").foregroundStyle(Term.muted)
            if folded, !scan.running {
                Text(scan.grade).font(Term.mono(11, .bold)).foregroundStyle(gradeColor)
                Text(verdict).foregroundStyle(gradeColor).lineLimit(1)
            }
            Spacer(minLength: 4)
            if scan.running {
                Text("scanning \(scan.current ?? "")…").foregroundStyle(Term.amber).lineLimit(1)
            } else if !folded, let at = scan.finishedAt {
                (Text(at, style: .relative) + Text(" ago")).foregroundStyle(Term.muted).lineLimit(1)
            }
            Button(action: rescan) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scan.running ? Term.muted : Term.text)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(scan.running)
            .accessibilityLabel("scan again")
        }
        .font(Term.mono(11))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.3)) { folded.toggle() } }
        .accessibilityAction(named: folded ? "expand" : "collapse") { folded.toggle() }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 0) {
                    Text(scan.running ? "…" : scan.grade)
                        .font(Term.mono(28, .bold))
                        .foregroundStyle(gradeColor)
                        .contentTransition(.interpolate)
                    Text(scan.running ? "--" : "\(scan.score)")
                        .font(Term.mono(9.5))
                        .foregroundStyle(Term.muted)
                        .contentTransition(.numericText())
                }
                .animation(.snappy(duration: 0.4), value: scan.running)
                .frame(width: 54, height: 54)
                .background(gradeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(gradeColor.opacity(0.6), lineWidth: 1.2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict)
                        .font(Term.mono(14, .semibold))
                        .foregroundStyle(scan.running ? Term.text : gradeColor)
                    Text(advice)
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(scan.checks) { check in
                    row(symbol(check.level), color(check.level), check.id,
                        hideIP && check.id == "exit" ? ExitInfo.maskIPs(in: check.detail) : check.detail,
                        detailColor: check.level == .warn || check.level == .fail ? color(check.level) : Term.text)
                }
                if scan.running {
                    ForEach(NetScan.order.filter { id in !scan.checks.contains { $0.id == id } }, id: \.self) { id in
                        row(id == scan.current ? ">" : "·", id == scan.current ? Term.amber : Term.muted, id,
                            id == scan.current ? "…" : "", detailColor: Term.muted)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: scan.checks.count)
        }
        .transition(.opacity)
    }

    private func row(_ symbol: String, _ symbolColor: Color, _ id: String, _ detail: String, detailColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(symbol).foregroundStyle(symbolColor).frame(width: 10, alignment: .leading)
            Text(id).foregroundStyle(Term.key).frame(width: 66, alignment: .leading)
            Text(detail).foregroundStyle(detailColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Term.mono(11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var verdict: String {
        if scan.running { return "probing this network" }
        switch scan.grade {
        case "A": return "clean network"
        case "B": return "mostly fine"
        case "C": return "risky network"
        default: return "hostile network"
        }
    }

    private var advice: String {
        if scan.running { return "dns · tls · portal · ipv6 · exit · quality" }
        if vpnOn { return "checked through the tunnel" }
        if scan.hasProblems { return "connect to route around it" }
        return "nothing odd · the router still sees where you go"
    }

    private var gradeColor: Color {
        if scan.running { return Term.amber }
        switch scan.grade {
        case "A", "B": return Term.green
        case "C": return Term.amber
        default: return Term.red
        }
    }

    private func symbol(_ level: NetScan.Level) -> String {
        switch level {
        case .pass: return "✓"
        case .info: return "·"
        case .warn: return "!"
        case .fail: return "✗"
        }
    }

    private func color(_ level: NetScan.Level) -> Color {
        switch level {
        case .pass: return Term.green
        case .info: return Term.muted
        case .warn: return Term.amber
        case .fail: return Term.red
        }
    }
}
