import NetworkExtension
import SwiftUI

struct VPNView: View {
    @State private var vpn = VPNManager()

    // 사용자 이름은 공개 정보라 기본값을 넣어 둔다(수정 가능).
    // 비밀번호는 기기 키체인에만 저장하고 소스에는 넣지 않는다.
    // 서버 주소는 고른 국가에 따라 API로 받아 온다.
    @AppStorage("vpnRegion") private var region: VPNRegion = .kr
    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnFastMode") private var fastMode = true
    @State private var password = ""

    @State private var busy = false
    /// 서버 켜는 중 같은 진행 상황 문구.
    @State private var phase: String?
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                serverSection
                actionSection
                helpSection
            }
            .navigationTitle("VPN")
            .task { await vpn.reload() }
        }
    }

    // MARK: - 상태

    private var statusSection: some View {
        Section {
            HStack {
                Label("상태", systemImage: "lock.shield")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(vpn.status.koreanLabel)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let phase {
                Text(phase).foregroundStyle(.orange)
            } else if let message {
                Text(message).foregroundStyle(messageIsError ? .red : .green)
            }
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        default: return .secondary
        }
    }

    // MARK: - 서버 설정

    private var serverSection: some View {
        Section {
            Picker("국가", selection: $region) {
                ForEach(VPNRegion.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .disabled(busy || vpn.status.isActive)
            LabeledContent("사용자 이름") {
                TextField("wifiscan", text: $username)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SecureField("비밀번호", text: $password)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
            Toggle("빠른 모드", isOn: $fastMode)
                .disabled(vpn.status.isActive)
        } header: {
            Text("서버")
        } footer: {
            Text("AES-256-GCM(하드웨어 AES)과 큰 패킷(MTU 1400)으로 연결해요. 연결이 안 되면 끄고 다시 연결해 보세요.")
        }
    }

    // MARK: - 동작

    private var actionSection: some View {
        Section {
            Button {
                Task { await saveAndConnect() }
            } label: {
                HStack {
                    Spacer()
                    if busy || vpn.status.isBusy {
                        ProgressView()
                    } else {
                        Label(vpn.status.isActive ? "연결 끊기" : "연결",
                              systemImage: vpn.status.isActive ? "stop.circle" : "bolt.horizontal.circle")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(busy || vpn.status.isBusy || username.isEmpty)
        } footer: {
            Text("처음 연결할 때 “VPN 구성 추가” 허용 창이 한 번 뜹니다. 서버가 꺼져 있으면 자동으로 켜서 1~2분 걸려요. 연결하려면 서버의 CA 인증서를 기기가 신뢰해야 해요(아래 참고).")
        }
    }

    // MARK: - 안내

    private var helpSection: some View {
        Section("CA 인증서 신뢰 (최초 1회)") {
            Label("WifiScanVPN.mobileconfig 파일을 아이폰으로 열어 프로파일 설치", systemImage: "1.circle")
            Label("설정 → 일반 → VPN 및 기기 관리 에서 프로파일 설치 완료", systemImage: "2.circle")
            Label("설정 → 일반 → 정보 → 인증서 신뢰 설정 에서 'WifiScan VPN Root CA' 스위치 켜기", systemImage: "3.circle")
        }
    }

    // MARK: - 로직

    private func saveAndConnect() async {
        message = nil
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
        // 비밀번호 칸을 비워 두면 키체인에 저장해 둔 것을 쓴다.
        guard let key = password.isEmpty ? KeychainHelper.read(account: user) : Optional(password),
              !key.isEmpty else {
            show("비밀번호를 입력해 주세요.", isError: true)
            return
        }
        do {
            phase = "\(region.name) 서버 확인 중…"
            let target = try await resolveTarget(key: key)
            if target.justBooted {
                phase = "\(region.name) 서버 준비 완료, 연결 중…"
                try await Task.sleep(for: .seconds(5))
            }
            try await vpn.save(server: target.address, remoteIdentifier: target.identifier,
                               username: user, password: key, fastMode: fastMode)
            try vpn.connect()
        } catch {
            show(error.localizedDescription, isError: true)
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

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

#Preview {
    VPNView()
}
