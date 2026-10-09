import NetworkExtension
import SwiftUI

struct VPNView: View {
    @State private var vpn = VPNManager()

    // 사용자 이름은 공개 정보라 기본값을 넣어 둔다(수정 가능).
    // 비밀번호는 직접 입력 → 전달용 IPA에 내장된 값(VPNPreset) → 키체인 순으로 쓴다.
    // 서버 주소는 고른 국가에 따라 API로 받아 온다.
    @AppStorage("vpnRegion") private var region: VPNRegion = .kr
    /// 시스템 VPN 설정에 실제로 저장된(= 연결되는) 국가. 선택 줄과 다를 수 있다.
    @AppStorage("vpnSavedRegion") private var savedRegion: VPNRegion = .kr
    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnFastMode") private var fastMode = true
    @AppStorage("vpnAdblock") private var adblock = false
    @AppStorage("vpnProtocol") private var proto: VPNProto = .auto
    @State private var password = ""

    @State private var busy = false
    /// `jp: booting…` 같은 진행 상황 한 줄
    @State private var phase: String?
    @State private var errorText: String?

    private let preset = VPNPreset.password

    var body: some View {
        TermPage(path: "vpn") {
            statusBlock
            exitBlock
            protoBlock
            authBlock

            Toggle(isOn: $fastMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("--fast" + (proto == .wireguard ? " (ikev2 only)" : ""))
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                    Text("aes-256-gcm · pfs · mtu 1400")
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted.opacity(0.6))
                }
            }
            .tint(Term.green)
            .disabled(busy || vpn.status.isActive)

            Toggle(isOn: $adblock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("--adblock")
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                    Text("ads · trackers blocked by server dns")
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted.opacity(0.6))
                }
            }
            .tint(Term.green)
            .disabled(busy || vpn.status.isActive)

            connectButton

            TermBlock(label: "first run: trust ca") {
                Group {
                    Text("1. open WifiScanVPN.mobileconfig → install")
                    Text("2. settings › general › about › certificate trust")
                    Text("3. enable 'WifiScan VPN Root CA'")
                    Text("# jp/us/uk ip changes every boot → connect from this app")
                }
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            }
        }
        .task { await vpn.reload() }
    }

    // MARK: - 상태

    private var statusBlock: some View {
        TermBlock(label: "status") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusTag)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .foregroundStyle(vpn.status == .connected ? Term.text : Term.muted)
                if vpn.status.isBusy {
                    ProgressView().controlSize(.mini).tint(Term.muted)
                }
            }
            .font(Term.mono(14, .semibold))

            if let phase {
                StatusLine(kind: .running, text: phase)
            } else if let errorText {
                StatusLine(kind: .error, text: errorText)
            }
        }
    }

    /// `[ OK ]`, `[ .. ]`, `[DOWN]` 같은 부팅 로그식 상태 꼬리표
    private var statusTag: String {
        switch vpn.status {
        case .connected: return "[ OK ]"
        case .connecting, .reasserting, .disconnecting: return "[ .. ]"
        default: return "[DOWN]"
        }
    }

    private var statusText: String {
        switch vpn.status {
        case .connected: return "up → \(savedRegion.rawValue)" + (vpn.activeProto.map { " · \($0.label)" } ?? "")
        case .connecting: return "connecting"
        case .reasserting: return "reconnecting"
        case .disconnecting: return "disconnecting"
        case .invalid: return "not configured"
        default: return "disconnected"
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return Term.green
        case .connecting, .reasserting, .disconnecting: return Term.amber
        default: return Term.muted
        }
    }

    // MARK: - 나갈 국가

    private var exitBlock: some View {
        TermBlock(label: "exit node") {
            TermChoice(options: VPNRegion.allCases.map { (label: $0.rawValue, value: $0) },
                       selection: $region)
                .disabled(busy || vpn.status.isActive)
                .opacity(busy || vpn.status.isActive ? 0.5 : 1)
            Text(region.detail)
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
        }
    }

    // MARK: - 프로토콜

    private var protoBlock: some View {
        TermBlock(label: "protocol") {
            TermChoice(options: VPNProto.allCases.map { (label: $0.label, value: $0) },
                       selection: $proto)
                .disabled(busy || vpn.status.isActive)
                .opacity(busy || vpn.status.isActive ? 0.5 : 1)
            Text(proto.detail)
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
        }
    }

    // MARK: - 계정

    private var authBlock: some View {
        TermBlock(label: "auth · ikev2/eap") {
            TermField(key: "user", text: $username, placeholder: "wifiscan")
            TermDivider()
            if preset != nil {
                HStack(spacing: 10) {
                    Text("pw")
                        .foregroundStyle(Term.muted)
                        .frame(width: 56, alignment: .leading)
                    Text("•••••••• (built-in)")
                        .foregroundStyle(Term.muted)
                }
                .font(Term.mono(15))
            } else {
                TermField(key: "pw", text: $password, placeholder: "saved in keychain", secure: true)
            }
        }
    }

    // MARK: - 연결 버튼

    private var connectButton: some View {
        Button {
            Task { await saveAndConnect() }
        } label: {
            if busy {
                ProgressView().tint(Term.bg)
            } else if vpn.status.isActive {
                Label("disconnect", systemImage: "stop.circle")
            } else {
                Label("connect", systemImage: "bolt.horizontal")
            }
        }
        .buttonStyle(TermButtonStyle(kind: vpn.status.isActive ? .danger : .primary, fill: true))
        .disabled(busy || vpn.status.isBusy || username.isEmpty)
    }

    // MARK: - 로직

    private func saveAndConnect() async {
        errorText = nil
        if vpn.status.isActive {
            vpn.disconnect()
            return
        }
        busy = true
        defer {
            busy = false
            phase = nil
        }
        let user = trimmed(username)
        // 내장 값이 있으면 입력 칸이 없으니 그걸 쓰고, 없으면 입력한 값 → 키체인 순으로 쓴다.
        let key = !password.isEmpty ? password : (preset ?? KeychainHelper.read(account: user) ?? "")
        guard !key.isEmpty else {
            errorText = "password required"
            return
        }
        do {
            phase = "\(region.rawValue): checking server…"
            let target = try await resolveTarget(key: key)
            if target.justBooted {
                phase = "\(region.rawValue): up, waiting for ike…"
                try await Task.sleep(for: .seconds(5))
            }
            switch proto {
            case .ikev2:
                try await connectIKE(target, user: user, key: key)
            case .wireguard:
                try await connectWG(target, user: user, key: key)
            case .auto:
                try await connectIKE(target, user: user, key: key)
                phase = "\(region.rawValue): ikev2 handshake…"
                if !(await vpn.waitForIKE(seconds: 12)) {
                    vpn.disconnect()
                    phase = "\(region.rawValue): ikev2 blocked here → wireguard"
                    try await Task.sleep(for: .seconds(1))
                    try await connectWG(target, user: user, key: key)
                }
            }
            savedRegion = region
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectIKE(_ target: RegionAPI.Target, user: String, key: String) async throws {
        phase = "\(region.rawValue): ikev2 → \(target.address)"
        try await vpn.save(server: target.address, remoteIdentifier: target.identifier,
                           username: user, password: key, fastMode: fastMode, adblock: adblock)
        try vpn.connect()
    }

    /// 이 폰의 WireGuard 키를 (처음이면) 서버에 등록하고, 고른 국가 서버로 터널을 연다.
    private func connectWG(_ target: RegionAPI.Target, user: String, key: String) async throws {
        phase = "\(region.rawValue): wireguard key…"
        let reg = try await WGClient.registration(apiKey: key, name: "\(user) iphone app")
        guard let serverPub = target.wgPub ?? reg.servers[region.rawValue]?.pub else {
            throw PeerAPI.Failure.server("no wireguard key for \(region.rawValue)")
        }
        let endpoint = "\(target.address):\(target.wgPort)"
        phase = "\(region.rawValue): wireguard → \(endpoint)"
        try await vpn.saveWireGuard(privateKey: reg.privateKey, address: reg.address + "/32",
                                    serverPub: serverPub, endpoint: endpoint,
                                    dns: adblock ? ["10.53.53.53"] : ["1.1.1.1"])
        try vpn.connectWireGuard()
    }

    /// 고른 국가 서버를 켜고 주소를 받는다. 비밀번호가 틀린 게 아니면 한국 서버는 고정 IP로 대신 시도한다.
    private func resolveTarget(key: String) async throws -> RegionAPI.Target {
        do {
            return try await RegionAPI.waitUntilReady(region, key: key) { phase = $0 }
        } catch RegionAPI.APIError.forbidden {
            throw RegionAPI.APIError.forbidden
        } catch {
            guard let fallback = region.fallback else { throw error }
            return fallback
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    VPNView()
}
