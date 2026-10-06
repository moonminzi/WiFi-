import NetworkExtension
import SwiftUI

struct VPNView: View {
    @State private var vpn = VPNManager()

    // 서버 주소/사용자 이름은 공개 정보라 기본값을 넣어 둔다(수정 가능).
    // 비밀번호는 기기 키체인에만 저장하고 소스에는 넣지 않는다.
    @AppStorage("vpnServer") private var server = "3.38.243.135"
    @AppStorage("vpnUsername") private var username = "wifiscan"
    @AppStorage("vpnFastCipher") private var fastCipher = true
    @State private var password = ""

    @State private var busy = false
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
            if let message {
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
            LabeledContent("주소") {
                TextField("3.38.243.135", text: $server)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
            }
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
            Toggle("빠른 암호 (AES-GCM)", isOn: $fastCipher)
                .disabled(vpn.status.isActive)
        } header: {
            Text("서버")
        } footer: {
            Text("하드웨어 AES로 처리해서 더 빨라요. 연결이 안 되면 끄고 다시 연결해 보세요.")
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
            .disabled(busy || vpn.status.isBusy || server.isEmpty || username.isEmpty)

            if !vpn.status.isActive {
                Button("설정만 저장") {
                    Task { await saveOnly() }
                }
                .disabled(busy || password.isEmpty)
            }
        } footer: {
            Text("처음 저장할 때 “VPN 구성 추가” 허용 창이 한 번 뜹니다. 연결하려면 서버의 CA 인증서를 기기가 신뢰해야 해요(아래 참고).")
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
        defer { busy = false }
        do {
            // 비밀번호를 비워 두고 눌렀고 이미 저장돼 있으면 기존 설정으로 바로 연결.
            // 단, 암호 토글을 바꿨으면 저장된 비밀번호로 설정만 다시 저장한다.
            if !password.isEmpty || !vpn.isConfigured || vpn.usesFastCipher != fastCipher {
                try await vpn.save(server: trimmed(server), username: trimmed(username),
                                   password: password, fastCipher: fastCipher)
            }
            try vpn.connect()
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func saveOnly() async {
        message = nil
        busy = true
        defer { busy = false }
        do {
            try await vpn.save(server: trimmed(server), username: trimmed(username),
                               password: password, fastCipher: fastCipher)
            show("설정을 저장했어요.", isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
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
