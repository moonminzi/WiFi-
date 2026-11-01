import Foundation
import SafariServices
import SwiftUI

/// Safari 콘텐츠 차단기(WifiScanBlocker) 상태: 켜져 있는지, 규칙 몇 개인지.
/// 켜고 끄는 건 iOS 설정에서만 된다(설정 → 앱 → Safari → 확장 프로그램 → NAGO Blocker).
@MainActor
@Observable
final class SafariBlocker {
    struct Info: Decodable {
        let rules: Int
        let lists: String
        let built: String
    }

    private(set) var enabled: Bool?
    let info: Info? = {
        guard let url = Bundle.main.url(forResource: "BlockerInfo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }()

    /// 재서명하면 앱 번들 ID가 바뀌므로 앱 ID + ".blocker"로 찾는다
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.example.wifiscan") + ".blocker" }

    func refresh() async {
        enabled = await withCheckedContinuation { cont in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: Self.identifier) { state, _ in
                cont.resume(returning: state?.isEnabled)
            }
        }
    }
}

/// settings의 `// safari` 블록: 배너 광고·광고 칸을 Safari 안에서 숨긴다(서버 DNS가 못 지우는 사이트 자기 배너까지)
struct SafariBlockerBlock: View {
    @State private var blocker = SafariBlocker()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TermBlock(label: "safari") {
            HStack {
                Text("banner blocker").foregroundStyle(Term.muted)
                Spacer()
                Text(status).foregroundStyle(blocker.enabled == true ? Term.green : Term.amber)
            }
            .font(Term.mono(13))
            if let info = blocker.info {
                Text("\(AdblockPanel.grouped(info.rules)) rules · \(info.lists)\(info.built.isEmpty ? "" : " · " + info.built)")
                    .font(Term.mono(11))
                    .foregroundStyle(Term.muted)
            }
            Text(blocker.enabled == true
                 ? "hides banner ads and empty ad boxes inside pages · safari only"
                 : "turn on: iOS Settings → Apps → Safari → Extensions → NAGO Blocker → on · works in safari only (not kakao/chrome in-app browsers)")
                .font(Term.mono(11.5))
                .foregroundStyle(Term.muted)
                .fixedSize(horizontal: false, vertical: true)
            if blocker.enabled != true {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack {
                        Text("open settings")
                        Spacer()
                        Text("→ apps → safari → extensions").foregroundStyle(Term.muted)
                    }
                }
                .buttonStyle(TermButtonStyle(fill: true))
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
