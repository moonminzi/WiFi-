import Foundation
import NetworkExtension
import Observation

/// 앱 쪽 연결 로그(설정 → logs). 최근 300줄을 UserDefaults에 둔다.
/// 진행 단계·오류는 화면 코드가 남기고, VPN 상태 변화와 끊긴 이유는 여기서 직접 듣는다.
@Observable
final class NagoLog {
    static let shared = NagoLog()

    private(set) var lines: [String]
    private static let key = "nagoLog"
    private static let limit = 300
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    @ObservationIgnored private var lastStatus: [String: NEVPNStatus] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    static func add(_ text: String) {
        shared.add(text)
    }

    func add(_ text: String) {
        lines.append("\(Self.stamp.string(from: Date())) \(text)")
        if lines.count > Self.limit {
            lines.removeFirst(lines.count - Self.limit)
        }
        UserDefaults.standard.set(lines, forKey: Self.key)
    }

    func clear() {
        lines = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// 앱이 켜져 있는 동안 VPN 상태 변화를 로그에 남긴다.
    /// 같은 설정을 여러 화면이 따로 불러와 알림이 겹쳐 오므로 프로토콜 이름 기준으로 한 번만 쓴다.
    func observeVPN() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            self?.statusChanged(connection)
        }
    }

    private func statusChanged(_ connection: NEVPNConnection) {
        let name = connection is NETunnelProviderSession ? "wg" : "ikev2"
        let now = connection.status
        let previous = lastStatus[name]
        lastStatus[name] = now
        guard previous != now else { return }
        if previous == nil, now == .disconnected || now == .invalid { return }
        add("\(name): \(now.logLabel)")
        guard now == .disconnected, previous?.isActive == true else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.add("✗ \(name): \(error.localizedDescription)") }
        }
    }
}

extension NEVPNStatus {
    var logLabel: String {
        switch self {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reconnecting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}
