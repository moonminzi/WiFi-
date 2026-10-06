import SwiftUI

@main
struct WifiScanApp: App {
    init() {
        // 탭 바도 터미널 배경색 + 고정폭 글꼴로
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Term.bg)
        appearance.shadowColor = UIColor(Term.border)
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.muted)]
            item.normal.iconColor = UIColor(Term.muted)
            item.selected.titleTextAttributes = [.font: font, .foregroundColor: UIColor(Term.green)]
            item.selected.iconColor = UIColor(Term.green)
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("wifi", systemImage: "wifi") }

                VPNView()
                    .tabItem { Label("vpn", systemImage: "lock.shield") }
            }
            .tint(Term.green)
            .preferredColorScheme(.dark)
        }
    }
}
