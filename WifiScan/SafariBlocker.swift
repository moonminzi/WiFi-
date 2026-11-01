import Foundation
import SafariServices
import SwiftUI

/// Safari 콘텐츠 차단기(WifiScanBlocker) 상태: 켜져 있는지, 규칙 몇 개인지.
/// 켜고 끄는 건 iOS 설정에서만 된다(설정 → 앱 → Safari → 확장 프로그램 → NAGO Blocker).
@MainActor
@Observable
final class SafariBlocker {
    private(set) var enabled: Bool?
    private(set) var problem: String?
    let identifier = BlockerLocator.identifier
    let info = BlockerLocator.info

    func refresh() async {
        guard let id = identifier else {
            enabled = false
            problem = "blocker extension missing from this build"
            return
        }
        let (state, error) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool?, String?), Never>) in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: id) { state, error in
                cont.resume(returning: (state?.isEnabled, error.map { ($0 as NSError).localizedDescription }))
            }
        }
        enabled = state ?? false
        problem = state == nil ? (error ?? "ios did not answer") : nil
    }
}

/// settings의 `// safari` 블록: 배너 광고·광고 칸을 Safari 안에서 숨긴다(서버 DNS가 못 지우는 사이트 자기 배너까지)
struct SafariBlockerBlock: View {
    @State private var blocker = SafariBlocker()
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    var body: some View {
        TermBlock(label: "safari") {
            HStack {
                Text("NAGO Blocker").foregroundStyle(Term.muted)
                Spacer()
                Text(status).foregroundStyle(blocker.enabled == true ? Term.green : Term.amber)
            }
            .font(Term.mono(13))
            if let info = blocker.info {
                Text("\(AdblockPanel.grouped(info.rules)) rules · \(info.lists)\(info.built.isEmpty ? "" : " · " + info.built)")
                    .font(Term.mono(11))
                    .foregroundStyle(Term.muted)
            }
            if let problem = blocker.problem {
                Text("! \(problem)" + (blocker.identifier.map { " · \($0)" } ?? ""))
                    .font(Term.mono(10.5))
                    .foregroundStyle(Term.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(blocker.enabled == true
                 ? "hides banner ads and empty ad boxes inside pages · safari only"
                 : "iOS Settings → Apps → Safari → Extensions → NAGO Blocker → on")
                .font(Term.mono(11.5))
                .foregroundStyle(Term.muted)
                .fixedSize(horizontal: false, vertical: true)
            TermDivider()
            HStack {
                Text("NAGO menu").foregroundStyle(Term.muted)
                Spacer()
                Text("in safari").foregroundStyle(Term.muted.opacity(0.8))
            }
            .font(Term.mono(13))
            Text("same Extensions page → NAGO → on, allow every website. Then in Safari tap aA (or the puzzle icon) → NAGO: blocker status, tap a banner to hide it on that site, pause per site")
                .font(Term.mono(11.5))
                .foregroundStyle(Term.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("test in safari") {
                    if let url = URL(string: "https://d3ward.github.io/toolz/adblock") { openURL(url) }
                }
                .buttonStyle(.term)
                Button("open settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.term)
                Spacer()
                Button("recheck") { Task { await blocker.refresh() } }
                    .buttonStyle(.term)
            }
        }
        .task { await blocker.refresh() }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await blocker.refresh() } }
        }
    }

    private var status: String {
        switch blocker.enabled {
        case true?: return "on"
        case false?: return "off"
        case nil: return "…"
        }
    }
}
