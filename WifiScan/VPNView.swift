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
    @AppStorage("wgQueue") private var wgQueue = 8
    @AppStorage("vpnAutoConnect") private var autoConnect: VPNAutoConnect = .off
    @AppStorage("vpnKillSwitch") private var killSwitch = false
    @AppStorage("vpnAllowLAN") private var allowLAN = true
    @AppStorage("vpnCustomDNS") private var customDNS = ""

    @State private var busy = false
    /// `jp: booting…` 같은 진행 상황 한 줄
    @State private var phase: String?
    @State private var errorText: String?
    /// 이번 연결 한 번의 진행 단계. 콘솔의 `// boot log`에 시각과 함께 쌓인다.
    @State private var steps: [Step] = []
    /// wg/유니콘 터널이 알려 주는 핸드셰이크·주고받은 양(연결돼 있는 동안 5초마다)
    @State private var linkStats: String?

    struct Step: Identifiable {
        let id = UUID()
        let at: Date
        let text: String
    }

    /// 지도 위로 겹쳐 올라오는 패널 높이
    private static let overlap: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            ScrollView {
                VStack(spacing: 0) {
                    hero(top: top, height: heroHeight(geo.size.height + top))
                    console
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                        .background(alignment: .top) { sheet }
                        .termColumn()
                        .padding(.top, -Self.overlap)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .ignoresSafeArea(edges: .top)
        }
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .tint(Term.green)
        .sensoryFeedback(.selection, trigger: region)
        .sensoryFeedback(trigger: vpn.status) { old, new in
            if new == .connected { return .success }
            if old.isActive, new == .disconnected { return .impact(weight: .light) }
            return nil
        }
        .task { await vpn.reload() }
        .task(id: vpn.status == .connected) { await pollLink() }
    }

    /// 화면의 절반쯤을 지도로. 너무 작거나(가로 아이폰) 너무 크지(아이패드) 않게.
    private func heroHeight(_ screen: CGFloat) -> CGFloat {
        min(max(screen * 0.52, 320), 560)
    }

    /// 킬 스위치는 우리 터널(wg)로만 한다. 자동 연결은 ikev2로 못 하니 wg로 민다.
    /// 유니콘 HTTPS도 우리 터널이라 자동 연결은 그대로 된다.
    private var effectiveProto: VPNProto {
        if killSwitch { return .wireguard }
        if proto == .unicorn { return .unicorn }
        return autoConnect != .off ? .wireguard : proto
    }

    /// 유니콘 HTTPS는 서버를 거치지 않아서 광고 차단 DNS(서버 안쪽 주소)는 쓸 수 없다.
    private var unicornSettings: UnicornSettings {
        UnicornSettings.fromDefaults(plainDNS: DNSList.parse(customDNS) ?? ["1.1.1.1"])
    }

    /// `wg/neptun · adblock · kill-switch` 처럼 지금 설정 한 줄
    private var flags: [String] {
        if effectiveProto == .unicorn {
            var parts = ["unicorn", unicornSettings.summary]
            if autoConnect != .off { parts.append("auto:\(autoConnect.label)") }
            return parts
        }
        var parts = [effectiveProto == .wireguard ? "wg/\(wgEngine)" : effectiveProto.label]
        if effectiveProto == .wireguard, wgEngine == "neptun", wgQueue != 8 { parts[0] += " q\(wgQueue)" }
        if fastMode, effectiveProto != .wireguard { parts.append("gcm") }
        if adblock {
            parts.append("adblock")
        } else if effectiveProto != .ikev2, let dns = DNSList.parse(customDNS) {
            parts.append("dns " + dns.joined(separator: ","))
        }
        if killSwitch { parts.append("kill-switch") }
        if autoConnect != .off { parts.append("auto:\(autoConnect.label)") }
        return parts
    }

    /// 나갈 국가를 못 바꾸는 때(연결 중·연결됨)
    private var locked: Bool { busy || vpn.status.isActive }
    /// 지도·카드에 보여 줄 나라: 연결돼 있으면 실제로 붙은 나라
    private var shownRegion: VPNRegion { vpn.status.isActive && !busy ? savedRegion : region }
    private var onDevice: Bool { routeStage == .onDevice }

    // MARK: - 지도(화면 위쪽 배경)

    /// you → 나갈 국가. 진행 단계(phase)가 바뀔 때마다 경로에 웨이포인트가 하나씩 찍힌다.
    /// 머리줄은 지도 위에 띄우고, 나라 점을 누르면 그 나라를 고른다.
    private func hero(top: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RouteMap(destination: shownRegion,
                     stage: routeStage,
                     hop: phase ?? (vpn.status.isBusy ? statusText : nil),
                     chrome: .hero(top: top + 56, bottom: Self.overlap),
                     height: height,
                     onSelect: locked || effectiveProto == .unicorn ? nil : { region = $0 })

            HStack(alignment: .center, spacing: 0) {
                Text("~/").foregroundStyle(Term.muted)
                Text("vpn").foregroundStyle(Term.green)
                Text(" $ ").foregroundStyle(Term.muted)
                BlinkingCursor()
                Spacer(minLength: 12)
                StatusPill(kind: pillKind, text: pillText)
            }
            .font(Term.mono(22, .bold))
            .padding(.horizontal, 16)
            .padding(.top, top + 10)
            .termColumn()
        }
        .frame(height: height)
    }

    private var routeStage: RouteMap.Stage {
        if effectiveProto == .unicorn || (vpn.status.isActive && vpn.activeProto == .unicorn) { return .onDevice }
        if busy || vpn.status == .connecting || vpn.status == .reasserting { return .connecting }
        if vpn.status == .connected { return .connected }
        return errorText != nil ? .failed : .idle
    }

    private var pillKind: StatusPill.Kind {
        switch vpn.status {
        case .connected: return .on
        case .connecting, .reasserting, .disconnecting: return .busy
        default: return busy ? .busy : (errorText != nil ? .error : .off)
        }
    }

    private var pillText: String {
        switch pillKind {
        case .on: return onDevice ? "shielded" : "secured"
        case .busy: return vpn.status == .disconnecting ? "closing" : "linking"
        case .error: return "failed"
        case .off: return "exposed"
        }
    }

    // MARK: - 콘솔(지도 위로 올라오는 패널)

    /// 지도 위에 겹쳐 올라오는 판. 위쪽만 둥글고 손잡이가 달린 시트 모양.
    private var sheet: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18)
        return shape.fill(Term.bg)
            .overlay(shape.stroke(Term.border, lineWidth: 1))
            .overlay(alignment: .top) {
                Capsule().fill(Term.border).frame(width: 36, height: 4).padding(.top, 7)
            }
            .shadow(color: .black.opacity(0.5), radius: 18, y: -6)
            // 아래쪽 테두리·그림자는 화면 밖으로 밀어 낸다
            .padding(.bottom, -40)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionPanel
            connectButton
            if onDevice {
                unicornPanel
            } else {
                exitPanel
            }
            if !steps.isEmpty || errorText != nil {
                bootLog
            }
        }
        .padding(.top, 8)
    }

    // MARK: 세션

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusTag).foregroundStyle(statusColor)
                Text(statusText).foregroundStyle(vpn.status == .connected ? Term.text : Term.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(Term.mono(13, .semibold))

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Group {
                    if onDevice {
                        Text("on-device")
                    } else {
                        Text(shownRegion.flag + " ") + Text(shownRegion.geo.city)
                    }
                }
                .font(Term.mono(28, .bold))
                .foregroundStyle(vpn.status == .connected ? Term.green : Term.num)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if let since = vpn.connectedSince, vpn.status == .connected {
                    TimelineView(.periodic(from: since, by: 1)) { timeline in
                        Text(Self.clock(timeline.date.timeIntervalSince(since)))
                            .font(Term.mono(22, .semibold))
                            .foregroundStyle(Term.num)
                            .monospacedDigit()
                    }
                } else if !onDevice {
                    Text(distanceText(shownRegion))
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                }
            }

            if busy || vpn.status.isBusy {
                PhasePipeline(index: pipelineIndex, onDevice: onDevice)
            } else if vpn.status == .connected {
                Text(linkStats.map { "link · " + $0 } ?? (vpn.activeProto == .ikev2 ? "link · ikev2 system tunnel" : "link · waiting for stats…"))
                    .font(Term.mono(12))
                    .foregroundStyle(linkStats == nil ? Term.muted : Term.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            FlagRow(flags: flags)
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
        case .connected:
            if vpn.activeProto == .unicorn { return "up → on-device · unicorn" }
            return "up → \(savedRegion.rawValue)" + (vpn.activeProto.map { " · \($0.label)" } ?? "")
        case .connecting: return "connecting"
        case .reasserting: return "reconnecting"
        case .disconnecting: return "disconnecting"
        case .invalid: return "not configured"
        default: return "disconnected · traffic goes out direct"
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return Term.green
        case .connecting, .reasserting, .disconnecting: return Term.amber
        default: return Term.muted
        }
    }

    /// 진행 단계 문구로 어디까지 왔는지(api → boot → tunnel → up)
    private var pipelineIndex: Int {
        if vpn.status == .connected && !busy { return 3 }
        let text = phase ?? ""
        if text.hasPrefix("unicorn") { return 2 }
        if text.contains("ikev2") || text.contains("wg") { return 2 }
        if text.contains("boot") || text.contains("stopping") || text.contains("retry") || text.contains("waiting") { return 1 }
        return vpn.status.isBusy && phase == nil ? 2 : 0
    }

    private func distanceText(_ region: VPNRegion) -> String {
        let km = GeoPoint.here.km(to: region.geo)
        return km < 150 ? "local" : "\(RouteMath.grouped(Int(km))) km"
    }

    /// 1:02:03 / 12:34
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 나갈 국가

    private var exitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("// exit node").foregroundStyle(Term.muted)
                Spacer()
                Text(locked ? "locked while up" : "tap map or card · rtt est.")
                    .foregroundStyle(Term.muted.opacity(0.7))
            }
            .font(Term.mono(11))

            HStack(spacing: 8) {
                ForEach(VPNRegion.allCases) { option in
                    RegionCard(region: option,
                               selected: option == shownRegion,
                               live: option == savedRegion && vpn.status == .connected) {
                        region = option
                    }
                }
            }
            .disabled(locked)
            .opacity(locked ? 0.55 : 1)

            Text(shownRegion.detail)
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
        }
    }

    private var unicornPanel: some View {
        TermBlock(label: "mode") {
            Text("on-device · no server")
                .font(Term.mono(14, .semibold))
                .foregroundStyle(Term.green)
            Text("tls hello를 쪼개 보내서 sni 차단을 지나간다. 트래픽은 평소 회선으로 그대로 나간다.")
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
        }
    }

    // MARK: 진행 기록

    private var bootLog: some View {
        TermBlock(label: "boot log") {
            VStack(alignment: .leading, spacing: 4) {
                let start = steps.first?.at ?? Date()
                ForEach(steps.suffix(7)) { item in
                    let last = item.id == steps.last?.id
                    logLine(offset: item.at.timeIntervalSince(start), symbol: symbol(last: last),
                            text: item.text, color: last ? lastColor : Term.text)
                }
                if vpn.status == .connected, !busy, let since = vpn.connectedSince, !steps.isEmpty {
                    logLine(offset: since.timeIntervalSince(start), symbol: ("✓", Term.green),
                            text: "tunnel up", color: Term.green)
                }
                if let errorText {
                    logLine(offset: nil, symbol: ("✗", Term.red), text: errorText, color: Term.red)
                }
            }
        }
    }

    private func symbol(last: Bool) -> (String, Color) {
        guard last else { return ("✓", Term.green) }
        if errorText != nil { return ("✗", Term.red) }
        if busy { return (">", Term.amber) }
        return ("✓", Term.green)
    }

    private var lastColor: Color { errorText != nil ? Term.red : Term.text }

    private func logLine(offset: TimeInterval?, symbol: (String, Color), text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(offset.map { String(format: "+%5.1fs", max(0, $0)) } ?? "       ")
                .foregroundStyle(Term.muted)
            Text(symbol.0).foregroundStyle(symbol.1)
            Text(text).foregroundStyle(color)
                .lineLimit(2)
        }
        .font(Term.mono(12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 연결 버튼

    private var connectButton: some View {
        Button {
            Task { await saveAndConnect() }
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(Term.bg)
                    Text(phase.map { $0.replacingOccurrences(of: "…", with: "") } ?? "working")
                } else if vpn.status.isActive {
                    Image(systemName: "stop.circle")
                    Text("disconnect")
                } else {
                    Image(systemName: "bolt.horizontal")
                    Text(onDevice ? "nago up --on-device" : "nago up \(region.rawValue)")
                }
            }
            .frame(height: 32)
        }
        .buttonStyle(TermButtonStyle(kind: vpn.status.isActive && !busy ? .danger : .primary, fill: true))
        .overlay {
            if busy { ScanSweep().clipShape(RoundedRectangle(cornerRadius: 6)).allowsHitTesting(false) }
        }
        .disabled(busy || vpn.status.isBusy || (effectiveProto != .unicorn && username.isEmpty))
    }

    /// 연결돼 있는 동안 터널 확장에 상태를 묻는다(ikev2는 시스템 터널이라 답이 없다).
    private func pollLink() async {
        guard vpn.status == .connected else {
            linkStats = nil
            return
        }
        while !Task.isCancelled {
            if let stats = await vpn.tunnelReport()?.stats, !stats.isEmpty { linkStats = stats }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - 로직

    private func saveAndConnect() async {
        errorText = nil
        if vpn.status.isActive {
            NagoLog.add("disconnect")
            steps = []
            await vpn.disconnect()
            return
        }
        steps = []
        busy = true
        defer {
            busy = false
            phase = nil
        }
        if effectiveProto == .unicorn {
            await connectUnicorn()
            return
        }
        let user = trimmed(username)
        guard let key = VPNPreset.key(username: user) else {
            fail("password required → settings")
            return
        }
        // 지난번에 못 붙은 킬 스위치 설정이 남아 있으면 아래 서버 확인 요청부터 막힌다.
        await vpn.releaseKillSwitch()
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
            case .unicorn:
                break       // 서버가 없어서 위에서 먼저 처리한다(여기까지 오지 않는다)
            }
            savedRegion = region
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 유니콘 HTTPS: 서버도 비밀번호도 없다. 설정만 저장하고 바로 띄운다.
    private func connectUnicorn() async {
        let settings = unicornSettings
        guard settings.strategy != .off else {
            fail("split off → settings")
            return
        }
        do {
            step("unicorn: \(settings.summary)")
            try await vpn.saveUnicorn(settings, autoConnect: autoConnect)
            try vpn.connectTunnel()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func step(_ text: String) {
        phase = text
        steps.append(Step(at: Date(), text: text))
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
                                    queue: wgQueue, region: region.rawValue, apiKey: key,
                                    autoConnect: autoConnect, killSwitch: killSwitch, allowLAN: allowLAN)
        try vpn.connectTunnel()
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
