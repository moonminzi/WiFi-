import NetworkExtension
import SwiftUI

struct VPNView: View {
    @State private var vpn = VPNManager()

    // 사용자 이름은 공개 정보라 기본값을 넣어 둔다(수정 가능).
    // 비밀번호는 직접 입력 → 전달용 IPA에 내장된 값(VPNPreset) → 키체인 순으로 쓴다.
    // 서버 주소는 고른 국가에 따라 API로 받아 온다.
    @AppStorage("vpnRegion") private var region: VPNRegion = .kr
    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnFastMode") private var fastMode = true
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
            authBlock

            Toggle(isOn: $fastMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("--fast")
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                    Text("aes-256-gcm · pfs · mtu 1400")
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
        case .connected: return "up → \(region.rawValue)"
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
        // 직접 입력한 값 → 내장 값 → 키체인 순으로 쓴다.
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
            phase = "\(region.rawValue): connecting \(target.address)"
            try await vpn.save(server: target.address, remoteIdentifier: target.identifier,
                               username: user, password: key, fastMode: fastMode)
            try vpn.connect()
        } catch {
            errorText = error.localizedDescription
        }
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
