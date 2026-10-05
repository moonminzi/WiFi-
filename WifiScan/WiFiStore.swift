import Foundation
import Observation

struct SavedNetwork: Codable, Identifiable, Hashable {
    var ssid: String
    var password: String
    var savedAt: Date

    var id: String { ssid }
}

/// 이 앱으로 연결에 성공했거나 직접 추가한 와이파이 목록. QR 탭에서 다시 공유할 때 쓴다.
@MainActor
@Observable
final class WiFiStore {
    static let shared = WiFiStore()

    private(set) var networks: [SavedNetwork] = []
    private let key = "savedNetworks"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedNetwork].self, from: data) {
            networks = decoded
        }
    }

    func save(ssid: String, password: String) {
        let ssid = ssid.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else { return }
        networks.removeAll { $0.ssid == ssid }
        networks.insert(SavedNetwork(ssid: ssid, password: password, savedAt: .now), at: 0)
        persist()
    }

    func delete(_ network: SavedNetwork) {
        networks.removeAll { $0.ssid == network.ssid }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(networks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
