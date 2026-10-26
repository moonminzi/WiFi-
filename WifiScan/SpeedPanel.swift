import SwiftUI

/// `// speed test`: 받기·올리기 Mbps, 쉬는 동안·받는 동안 핑, 최근 결과(어떤 설정이었는지와 함께).
/// settings에서 loops·engine을 바꿔 가며 같은 나라로 재 보면 어느 쪽이 빠른지 바로 비교된다.
struct SpeedPanel: View {
    let test: SpeedTest
    /// 지금 재면 남을 설정 이름("wg/neptun ×2 · jp", "direct" …)
    let via: String
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if test.running {
                live
            } else if let last = test.last {
                summary(last)
            }
            if test.phase == .failed, let error = test.errorText {
                Text("✗ " + error)
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.red)
            }
            if test.history.count > 1 {
                history
            }
            Text("via \(via) · speed.cloudflare.com · up to ~\(SpeedTest.maxUsageMB) MB")
                .font(Term.mono(10))
                .foregroundStyle(Term.muted.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("// speed test").foregroundStyle(Term.muted)
            Spacer()
            Button(action: run) {
                Text(test.running ? test.phase.rawValue + "…" : "run ▸")
                    .foregroundStyle(test.running ? Term.amber : Term.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(test.running ? Term.amber.opacity(0.5) : Term.green.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(test.running)
            .accessibilityLabel(test.running ? "speed test running" : "run speed test")
        }
        .font(Term.mono(11))
    }

    /// 재는 중: 지금 단계와 흐르는 속도, 진행 막대
    private var live: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(arrow(test.phase))
                    .foregroundStyle(test.phase == .upload ? Term.key : Term.green)
                Text(Self.mbps(test.liveMbps))
                    .foregroundStyle(Term.num)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: test.liveMbps)
                Text("Mbps").font(Term.mono(11)).foregroundStyle(Term.muted)
            }
            .font(Term.mono(24, .bold))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Term.track)
                    Capsule().fill(Term.amber.opacity(0.8))
                        .frame(width: max(3, geo.size.width * test.progress))
                }
            }
            .frame(height: 3)
            Text(phaseText)
                .font(Term.mono(10.5))
                .foregroundStyle(Term.muted)
        }
    }

    private func summary(_ result: SpeedTest.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                figure("↓", result.downMbps, Term.green)
                figure("↑", result.upMbps, Term.key)
            }
            Text(pingText(result))
                .font(Term.mono(11))
                .foregroundStyle(Term.muted)
        }
    }

    private func figure(_ arrow: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(arrow).foregroundStyle(color)
            Text(Self.mbps(value)).foregroundStyle(Term.num).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.5), value: value)
            Text("Mbps").font(Term.mono(10.5)).foregroundStyle(Term.muted)
        }
        .font(Term.mono(20, .bold))
    }

    /// 최근 결과: 시각 · 설정 · 받기 · 올리기 · 받는 동안 핑. 가장 빨리 받은 줄은 초록
    private var history: some View {
        let best = test.history.map(\.downMbps).max() ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(test.history) { result in
                HStack(spacing: 8) {
                    Text(Self.time.string(from: result.at)).foregroundStyle(Term.muted)
                    Text(result.via)
                        .foregroundStyle(result.downMbps == best ? Term.green : Term.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text("↓\(Int(result.downMbps.rounded()))").foregroundStyle(Term.num)
                    Text("↑\(Int(result.upMbps.rounded()))").foregroundStyle(Term.muted)
                    Text(result.loadedMs.map { "\(Int($0.rounded()))ms" } ?? "--").foregroundStyle(Term.muted)
                }
                .font(Term.mono(10.5))
            }
        }
    }

    private var phaseText: String {
        switch test.phase {
        case .ping: return "ping · idle latency"
        case .download: return "download · 4 connections · 7s"
        case .upload: return "upload · 4 connections · 7s"
        default: return ""
        }
    }

    private func arrow(_ phase: SpeedTest.Phase) -> String {
        phase == .upload ? "↑" : (phase == .ping ? "·" : "↓")
    }

    private func pingText(_ result: SpeedTest.Result) -> String {
        guard let idle = result.idleMs else { return "ping --" }
        var text = "ping \(Int(idle.rounded())) ms idle"
        if let loaded = result.loadedMs {
            text += " · \(Int(loaded.rounded())) ms loaded (+\(Int(max(loaded - idle, 0).rounded())))"
        }
        return text
    }

    static func mbps(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
