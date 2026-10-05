import SwiftUI

@main
struct WifiScanApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                WiFiScanView()
                    .tabItem { Label("와이파이", systemImage: "wifi") }
                AccountScanView()
                    .tabItem { Label("계좌번호", systemImage: "creditcard") }
                QRShareView()
                    .tabItem { Label("QR 공유", systemImage: "qrcode") }
            }
        }
    }
}
