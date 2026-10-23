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

    var body: some Scene {
        WindowGroup {
            TabView {
                VPNView()
                    .tabItem { Label("vpn", systemImage: "lock.shield") }

                DashView()
                    .tabItem { Label("dash", systemImage: "chart.bar.xaxis") }

                SettingsView()
                    .tabItem { Label("settings", systemImage: "gearshape") }
            }
            .tint(Term.green)
            .preferredColorScheme(.dark)
        }
    }
}
