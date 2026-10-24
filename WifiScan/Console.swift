import SwiftUI

// vpn 탭 콘솔(지도 위로 올라오는 패널)에 쓰는 조각들.

/// 머리줄 오른쪽 `● secured` 알약. 연결돼 있으면 불이 숨을 쉰다.
struct StatusPill: View {
    enum Kind { case on, busy, error, off }
    let kind: Kind
    let text: String

    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: kind == .off ? .clear : color.opacity(0.9), radius: breathe ? 5 : 1.5)
                .opacity(kind == .busy && breathe ? 0.35 : 1)
            Text(text)
                .font(Term.mono(12, .semibold))
                .foregroundStyle(kind == .off ? Term.muted : color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Term.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(kind == .off ? Term.border : color.opacity(0.45), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: kind)
        .onAppear { startBreathing() }
        .onChange(of: kind) { _, _ in startBreathing() }
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

    private func startBreathing() {
        breathe = false
        guard !reduceMotion, kind == .on || kind == .busy else { return }
        withAnimation(.easeInOut(duration: kind == .busy ? 0.6 : 1.6).repeatForever()) { breathe = true }
    }
}

/// 연결 진행 `api › boot › tunnel › up`. 지난 칸은 초록, 지금 칸은 노랗게 깜빡인다.
struct PhasePipeline: View {
    let index: Int
    /// 유니콘 HTTPS는 서버를 켜지 않는다
    var onDevice = false

    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var labels: [String] { onDevice ? ["config", "local", "tunnel", "up"] : ["api", "boot", "tunnel", "up"] }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(fill(i))
                        .frame(height: 3)
                        .opacity(i == index && blink ? 0.35 : 1)
                    Text(labels[i])
                        .font(Term.mono(10, i == index ? .semibold : .regular))
                        .foregroundStyle(i <= index ? (i == index ? Term.amber : Term.green) : Term.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.3), value: index)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever()) { blink = true }
        }
        .accessibilityElement()
        .accessibilityLabel("step \(min(index, labels.count - 1) + 1) of \(labels.count): \(labels[min(index, labels.count - 1)])")
    }

    private func fill(_ i: Int) -> Color {
        if i < index { return Term.green }
        if i == index { return Term.amber }
        return Term.track
    }
}

/// 나갈 국가 카드 한 장: 깃발, 코드, 도시, 대략 왕복 시간
struct RegionCard: View {
    let region: VPNRegion
    let selected: Bool
    /// 지금 이 나라로 붙어 있다
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(region.flag).font(.system(size: 18))
                    Spacer(minLength: 2)
                    if live {
                        Circle().fill(Term.green).frame(width: 6, height: 6)
                            .shadow(color: Term.green, radius: 3)
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
                Text("~\(Self.rtt(region))ms")
                    .font(Term.mono(10))
                    .foregroundStyle(selected ? Term.key : Term.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Term.green.opacity(0.08) : Term.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Term.green : Term.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityLabel("\(region.geo.city), about \(Self.rtt(region)) milliseconds")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 빛이 광섬유로 1ms에 200km쯤 가니 왕복은 km/100ms. 장비·우회 몫으로 조금 더한다(어림값).
    static func rtt(_ region: VPNRegion) -> Int {
        let km = GeoPoint.here.km(to: region.geo)
        return Int((km / 100 * 1.3 + 6).rounded())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation) { timeline in
                GeometryReader { geo in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let band = geo.size.width * 0.35
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * t)
                }
            }
        }
    }
}
