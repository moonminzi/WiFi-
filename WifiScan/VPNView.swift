import NetworkExtension
import SwiftUI

struct VPNView: View {
    @State private var vpn = VPNManager()

    // 서버 주소는 고른 국가에 따라 API로 받아 온다. 나머지 설정은 settings 탭(같은 키)에 있다.
    // 비밀번호는 전달용 IPA에 내장된 값(VPNPreset) → 키체인 순으로 쓴다.
    @AppStorage("vpnRegion") private var region: VPNRegion = .kr
    /// 시스템 VPN 설정에 실제로 저장된(= 연결되는) 국가. 선택 줄과 다를 수 있다.
    @AppStorage("vpnSavedRegion") private var savedRegion: VPNRegion = .kr
    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnFastMode") private var fastMode = true
    @AppStorage("vpnAdblock") private var adblock = false
    @AppStorage("vpnProtocol") private var proto: VPNProto = .auto
    @AppStorage("wgEngine") private var wgEngine = "neptun"
    @AppStorage("vpnAutoConnect") private var autoConnect: VPNAutoConnect = .off
    @AppStorage("vpnKillSwitch") private var killSwitch = false
    @AppStorage("vpnAllowLAN") private var allowLAN = true
    @AppStorage("vpnCustomDNS") private var customDNS = ""

    @State private var busy = false
    /// `jp: booting…` 같은 진행 상황 한 줄
    @State private var phase: String?
    @State private var errorText: String?

    var body: some View {
        TermPage(path: "vpn") {
            statusBlock
            exitBlock
            connectButton
        }
        .task { await vpn.reload() }
    }

    /// 자동 연결·킬 스위치는 우리 터널(wg)로만 한다(서버 깨우기, IP 추적).
    private var effectiveProto: VPNProto {
        autoConnect != .off || killSwitch ? .wireguard : proto
    }

    /// `wg/neptun · adblock · kill-switch` 처럼 지금 설정 한 줄
    private var flags: String {
        var parts = [effectiveProto == .wireguard ? "wg/\(wgEngine)" : effectiveProto.label]
        if adblock {
            parts.append("adblock")
        } else if effectiveProto != .ikev2, let dns = DNSList.parse(customDNS) {
            parts.append("dns " + dns.joined(separator: ","))
        }
        if killSwitch { parts.append("kill-switch") }
        if autoConnect != .off { parts.append("auto:\(autoConnect.label)") }
        return parts.joined(separator: " · ")
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

            Text(flags)
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)

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
            NagoLog.add("disconnect")
            await vpn.disconnect()
            return
        }
        busy = true
        defer {
            busy = false
            phase = nil
        }
        let user = trimmed(username)
        guard let key = VPNPreset.key(username: user) else {
            fail("password required → settings")
            return
        }
        do {
            step("\(region.rawValue): checking server…")
            let target = try await resolveTarget(key: key)
            if target.justBooted {
                step("\(region.rawValue): up, waiting for ike…")
                try await Task.sleep(for: .seconds(5))
            }
            switch effectiveProto {
            case .ikev2:
                try await connectIKE(target, user: user, key: key)
            case .wireguard:
                try await connectWG(target, user: user, key: key)
            case .auto:
                try await connectIKE(target, user: user, key: key)
                step("\(region.rawValue): ikev2 handshake…")
                if !(await vpn.waitForIKE(seconds: 12)) {
                    await vpn.disconnect()
                    step("\(region.rawValue): ikev2 timeout → wg")
                    try await Task.sleep(for: .seconds(1))
                    try await connectWG(target, user: user, key: key)
                }
            }
            savedRegion = region
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func step(_ text: String) {
        phase = text
        NagoLog.add(text)
    }

    private func fail(_ message: String) {
        errorText = message
        NagoLog.add("✗ \(message)")
    }

    private func connectIKE(_ target: RegionAPI.Target, user: String, key: String) async throws {
        step("\(region.rawValue): ikev2 → \(target.address)")
        try await vpn.save(server: target.address, remoteIdentifier: target.identifier,
                           username: user, password: key, fastMode: fastMode, adblock: adblock)
        try vpn.connect()
    }

    /// 이 폰의 WireGuard 키를 (처음이면) 서버에 등록하고, 고른 국가 서버로 터널을 연다.
    private func connectWG(_ target: RegionAPI.Target, user: String, key: String) async throws {
        step("\(region.rawValue): wg register…")
        let reg = try await WGClient.registration(apiKey: key, name: "\(user) iphone app")
        guard let serverPub = target.wgPub ?? reg.servers[region.rawValue]?.pub else {
            throw PeerAPI.Failure.server("no wireguard key for \(region.rawValue)")
        }
        let endpoint = "\(target.address):\(target.wgPort)"
        step("\(region.rawValue): wg/\(wgEngine) → \(endpoint)")
        try await vpn.saveWireGuard(privateKey: reg.privateKey, address: reg.address + "/32",
                                    serverPub: serverPub, endpoint: endpoint, dns: wgDNS, engine: wgEngine,
                                    region: region.rawValue, apiKey: key,
                                    autoConnect: autoConnect, killSwitch: killSwitch, allowLAN: allowLAN)
        try vpn.connectWireGuard()
    }

    /// 광고 차단 DNS → 직접 넣은 DNS → 1.1.1.1
    private var wgDNS: [String] {
        if adblock { return ["10.53.53.53"] }
        return DNSList.parse(customDNS) ?? ["1.1.1.1"]
    }

    /// 고른 국가 서버를 켜고 주소를 받는다. 비밀번호가 틀린 게 아니면 한국 서버는 고정 IP로 대신 시도한다.
    private func resolveTarget(key: String) async throws -> RegionAPI.Target {
        do {
            return try await RegionAPI.waitUntilReady(region, key: key) { step($0) }
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
