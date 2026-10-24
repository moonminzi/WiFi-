import SwiftUI

@main
struct WifiScanApp: App {
    init() {
        // 탭 바도 터미널 배경색 + 대시보드 사이트와 같은 고정폭 글꼴로
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Term.bg)
        appearance.shadowColor = UIColor(Term.border)
        let font = Term.uiMono(11, .semibold)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.muted)]
            item.normal.iconColor = UIColor(Term.muted)
            item.selected.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.green)]
            item.selected.iconColor = UIColor(Term.green)
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        NagoLog.shared.observeVPN()
    }

    /// 처음 보여 줄 탭. 보통은 vpn이고, 스크린샷 때 `-nagoTab 1`처럼 실행 인자로 고른다.
    @State private var tab = UserDefaults.standard.integer(forKey: "nagoTab")

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                VPNView()
                    .tabItem { Label("vpn", systemImage: "lock.shield") }
                    .tag(0)

                DashView()
                    .tabItem { Label("dash", systemImage: "chart.bar.xaxis") }
                    .tag(1)

                SettingsView()
                    .tabItem { Label("settings", systemImage: "gearshape") }
                    .tag(2)
            }
            .tint(Term.green)
            .preferredColorScheme(.dark)
        }
    }
}
