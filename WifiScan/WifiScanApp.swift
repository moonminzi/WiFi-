import SwiftUI

@main
struct WifiScanApp: App {
    init() {
        // 탭 바도 터미널 배경색 + 대시보드 사이트와 같은 고정폭 글꼴로(색은 다크·라이트에 따라 바뀜)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Term.UI.bg
        appearance.shadowColor = Term.UI.border
        let font = Term.uiMono(11, .semibold)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: font, .foregroundColor: Term.UI.muted]
            item.normal.iconColor = Term.UI.muted
            item.selected.titleTextAttributes = [.font: font, .foregroundColor: Term.UI.green]
            item.selected.iconColor = Term.UI.green
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        NagoLog.shared.observeVPN()
    }

    /// 처음 보여 줄 탭. 보통은 vpn이고, 스크린샷 때 `-nagoTab 1`처럼 실행 인자로 고른다.
    @State private var tab = UserDefaults.standard.integer(forKey: "nagoTab")
    /// settings → appearance(기본은 기기 설정을 따름)
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                VPNView()
                    .tabItem { Label("vpn", systemImage: "lock.shield") }
                    .tag(0)

                // 서버·피어·비용 관리는 관리자용에만
                if !Edition.isUser {
                    DashView()
                        .tabItem { Label("dash", systemImage: "chart.bar.xaxis") }
                        .tag(1)
                }

                SettingsView()
                    .tabItem { Label("settings", systemImage: "gearshape") }
                    .tag(2)
            }
            .tint(Term.green)
            .preferredColorScheme(appearance.scheme)
        }
    }
}
