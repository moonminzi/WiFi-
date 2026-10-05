import SwiftUI

@main
struct WifiScanApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("와이파이 스캔", systemImage: "wifi") }

                VPNView()
                    .tabItem { Label("VPN", systemImage: "lock.shield") }
            }
        }
    }
}
