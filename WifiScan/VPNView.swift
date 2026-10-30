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
    @AppStorage("wgLoops") private var wgLoops = 1
    /// nagotun(neptun) 모드에서 막힌 망 우회(nagoing) 켜기
    @AppStorage(NagoingSettings.Key.on) private var nagoOn = false
    @AppStorage("vpnAutoConnect") private var autoConnect: VPNAutoConnect = .off
    @AppStorage("vpnKillSwitch") private var killSwitch = false
    /// isp·exit 줄의 IP를 가린다(줄을 누르면 바뀜)
    @AppStorage("hideIP") private var hideIP = false
    @AppStorage("vpnAllowLAN") private var allowLAN = true
    @AppStorage("vpnCustomDNS") private var customDNS = ""
    /// 접어 둔 패널(net scan · speed test · 임시 서버 나라). 처음엔 접혀 있다
    @AppStorage("foldScan") private var foldScan = true
    @AppStorage("foldSpeed") private var foldSpeed = true
    @AppStorage("foldOnDemand") private var foldOnDemand = true

    @State private var busy = false
    /// `jp: booting…` 같은 진행 상황 한 줄
    @State private var phase: String?
    @State private var errorText: String?
    /// 이번 연결 한 번의 진행 단계(단계마다 햅틱). 기록은 settings → logs에 남는다(NagoLog).
    @State private var steps: [Step] = []
    /// wg/유니콘 터널이 알려 주는 핸드셰이크·주고받은 양(연결돼 있는 동안 5초마다)
    @State private var linkStats: String?
    /// 진행 중인 연결. 해외 서버는 켜지는 데 몇 분 걸려서 그동안 버튼으로 취소할 수 있다.
    @State private var connectTask: Task<Void, Never>?
    /// 실패 줄을 누르면 연결 기록(settings → logs와 같은 화면)
    @State private var showLogs = false
    /// 나라별 실제 왕복 시간(카드에 표시)
    @State private var probe = LatencyProbe()
    /// 밖에서 보이는 내 IP·나라. 연결되면 나가는 서버 것이어야 한다.
    @State private var exitInfo: ExitInfo?
    /// 연결된 채로 다른 나라를 누르면 갈아탈지 묻는다
    @State private var hopTarget: VPNRegion?
    /// 터널로 오가는 속도(1초마다)
    @State private var traffic = TrafficMeter()
    /// 지금 네트워크 검사(앱을 열면 한 번 돈다)
    @State private var scan = NetScan()
    /// 속도 측정(설정을 바꿔 가며 비교)
    @State private var speed = SpeedTest()

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
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        // 스크린샷용: 맨 위에서 아래로 당긴 모습(Debug + `-nagoPull 90`)
                        if Demo.pull > 0 {
                            Color.clear.frame(height: Demo.pull)
                        }
                        hero(top: top, height: heroHeight(geo.size.height + top))
                        console
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 24)
                            .background(alignment: .top) { sheet }
                            .termColumn()
                            .padding(.top, -Self.overlap)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                // 지도 위로 스크롤 막대가 지나가면 지저분하다
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .task {
                    guard Demo.scrollToEnd else { return }
                    try? await Task.sleep(for: .seconds(1.6))
                    reader.scrollTo("end", anchor: .bottom)
                }
            }
        }
        .statusBarScrim()
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .tint(Term.green)
        .sensoryFeedback(.selection, trigger: region)
        .sensoryFeedback(trigger: vpn.status) { old, new in
            if new == .connected { return .success }
            if old.isActive, new == .disconnected { return .impact(weight: .light) }
            return nil
        }
        .task {
            await vpn.reload()
            await runScan()
        }
        .task(id: vpn.status == .connected) { await pollLink() }
        .task(id: vpn.status) { await statusSettled() }
        .onAppear(perform: applyDemo)
    }

    /// 스크린샷용 데모 상태(Debug 빌드 + `-nagoDemo`)
    private func applyDemo() {
        guard let state = Demo.state else { return }
        let now = Date()
        let demoSteps = Demo.steps.map { Step(at: now.addingTimeInterval(-$0.ago), text: $0.text) }
        switch state {
        case "connecting":
            region = .jp
            busy = true
            steps = demoSteps
            phase = demoSteps.last?.text
        case "connected":
            region = Demo.region ?? .jp
            savedRegion = region
            // 연결된 시각(Demo.since) 바로 전에 찍힌 단계들
            steps = Demo.steps.map { Step(at: Demo.since.addingTimeInterval(-$0.ago + Demo.steps[0].ago - 26), text: $0.text) }
            linkStats = Demo.linkStats
            traffic.fillDemo()
            speed.showDemo()
        case "scan":
            region = .jp
            scan.showDemo(running: true)
        case "failed":
            region = .us
            steps = Array(demoSteps.prefix(2)).map { Step(at: $0.at, text: $0.text.replacingOccurrences(of: "jp", with: "us")) }
            errorText = "timeout: server not up after 4m, retry"
        default:
            region = Demo.region ?? .jp
        }
    }

    /// 화면의 절반쯤을 지도로. 너무 작거나(가로 아이폰) 너무 크지(아이패드) 않게.
    private func heroHeight(_ screen: CGFloat) -> CGFloat {
        min(max(screen * 0.52, 320), 560)
    }

    /// 킬 스위치는 우리 터널(wg)로만 한다. 자동 연결은 ikev2로 못 하니 wg로 민다.
    /// 유니콘 HTTPS도 우리 터널이라 자동 연결은 그대로 된다.
    /// 임시 서버는 WireGuard만 있다.
    private var effectiveProto: VPNProto {
        if killSwitch { return .wireguard }
        if proto == .unicorn { return .unicorn }
        if region.onDemand { return .wireguard }
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
        var parts = [effectiveProto == .wireguard ? "wg/\(VPNView.engineName(wgEngine))" : effectiveProto.label]
        if effectiveProto == .wireguard, wgEngine == "neptun" { parts[0] += " ×\(wgLoops)" }
        if effectiveProto == .wireguard, wgEngine == "neptun", nagoOn {
            parts.append("nagoing \(NagoingSettings.fromDefaults().prefer.label)")
        }
        if fastMode, effectiveProto != .wireguard { parts.append("gcm") }
        if adblock {
            parts.append(region.onDemand ? "adblock n/a · temp server" : "adblock")
        } else if effectiveProto != .ikev2, let dns = DNSList.parse(customDNS) {
            parts.append("dns " + dns.joined(separator: ","))
        }
        if killSwitch { parts.append("kill-switch") }
        if autoConnect != .off { parts.append("auto:\(autoConnect.label)") }
        return parts
    }

    /// 나라를 못 고르는 때(연결하는 중). 연결돼 있을 때 고르면 갈아타기(hop)를 묻는다.
    private var locked: Bool { busy || vpn.status.isBusy }
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
                     onSelect: locked || effectiveProto == .unicorn ? nil : { select($0) },
                     flowDown: traffic.current?.down ?? 0,
                     flowUp: traffic.current?.up ?? 0,
                     scanning: scan.running)
                // 위로 밀면 지도는 천천히 따라간다(패럴랙스). 아래로 당길 때는 아래 hero 전체가 제자리에 선다
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView).minY
                    return content.offset(y: y < 0 ? -y * 0.45 : 0)
                }

            // 상태 빛: 머리줄 쪽에서 상태 색이 은은하게 번진다
            StateGlow(kind: pillKind)
                .frame(height: height)
                .allowsHitTesting(false)

            HStack(alignment: .center, spacing: 0) {
                Text("~/").foregroundStyle(Term.muted)
                Text("vpn").foregroundStyle(Term.green)
                Text(" $ ").foregroundStyle(Term.muted)
                BlinkingCursor()
                Spacer(minLength: 12)
                scanButton
                    .padding(.trailing, 8)
                StatusPill(kind: pillKind, text: pillText)
            }
            .font(Term.mono(22, .bold))
            .padding(.horizontal, 16)
            .padding(.top, top + 10)
            .termColumn()
        }
        .frame(height: height)
        // 패럴랙스로 내려간 지도가 아래 콘솔 옆으로 비어져 나오지 않게 아래만 자른다
        .mask(alignment: .bottom) { Rectangle().frame(height: height + 2000) }
        // 맨 위에서 아래로 당기면 지도·머리줄(~/vpn $ · 스캔 · 상태)은 화면 위에 그대로 두고 패널만 내려온다.
        // 예전엔 지도를 키워 빈 곳을 메웠는데, 그러면 머리줄이 나라 점 위로 내려오고 지도 글자(좌표·거리)까지
        // 커져 양옆이 잘렸다. 지도 아래 끝은 배경색으로 흐려지니 패널 위로 벌어지는 틈도 이어져 보인다
        .visualEffect { content, proxy in
            let y = proxy.frame(in: .scrollView).minY
            return content.offset(y: y > 0 ? -y : 0)
        }
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
            .shadow(color: Term.shadow, radius: 18, y: -6)
            // 아래쪽 테두리·그림자는 화면 밖으로 밀어 낸다(아이패드처럼 내용이 짧아도 화면 끝까지)
            .padding(.bottom, -1200)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionPanel
            connectButton
            // 진행은 연결 버튼(지금 단계)과 단계 막대로 보이고, 단계 기록은 settings → logs로 갔다.
            // 실패하면 버튼 바로 아래 이유 한 줄만 — 누르면 기록 전체
            if let errorText, !busy {
                failureLine(errorText)
                    .padding(.top, -6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if onDevice {
                unicornPanel
            } else {
                exitPanel
            }
            if scan.running || !scan.checks.isEmpty {
                scanPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // 속도 측정(설정끼리 비교하는 도구)은 관리자용에만
            if !Edition.isUser {
                speedPanel
            }
        }
        .padding(.top, 8)
        // 패널이 생기고 사라질 때 툭 끊기지 않게
        .animation(.snappy(duration: 0.35), value: errorText)
        .animation(.snappy(duration: 0.35), value: scan.running)
        .sheet(isPresented: $showLogs) { LogsView(vpn: vpn) }
    }

    /// 검사가 끝나면 등급에 따라 햅틱(문제 없음 성공 · 있으면 경고)
    private var scanPanel: some View {
        ScanPanel(scan: scan, vpnOn: vpn.status == .connected, folded: $foldScan) { Task { await runScan() } }
            .sensoryFeedback(trigger: scan.finishedAt) { _, finished in
                guard finished != nil else { return nil }
                return scan.hasProblems ? .warning : .success
            }
    }

    private var speedPanel: some View {
        SpeedPanel(test: speed, via: speedVia, folded: $foldSpeed) {
            let via = speedVia
            Task { await speed.run(via: via) }
        }
        .sensoryFeedback(.success, trigger: speed.last?.at)
    }

    /// 머리줄의 레이더 단추: 지금 네트워크를 검사한다
    private var scanButton: some View {
        Button {
            Task { await runScan() }
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(scan.running ? Term.amber : Term.text)
                .frame(width: 30, height: 30)
                .background(Term.surface.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(scan.running ? Term.amber.opacity(0.5) : Term.border, lineWidth: 1))
                .symbolEffect(.variableColor.iterative, isActive: scan.running)
        }
        .buttonStyle(.plain)
        .disabled(scan.running)
        .accessibilityLabel("scan this network")
    }

    /// 속도 측정 결과에 남길 설정 이름: 연결돼 있으면 "wg/neptun ×2 · jp", 아니면 "direct"
    private var speedVia: String {
        guard vpn.status == .connected else { return "direct" }
        switch vpn.activeProto {
        case .unicorn?: return "unicorn"
        case .ikev2?: return "ikev2 · \(savedRegion.rawValue)"
        default:
            let engine = wgEngine == "neptun" ? "wg/NagoTun ×\(wgLoops)" : "wg/\(wgEngine)"
            return "\(engine) · \(savedRegion.rawValue)"
        }
    }

    private func runScan() async {
        let on = vpn.status == .connected
        await scan.run(vpnOn: on, expected: on && vpn.activeProto != .unicorn ? savedRegion : nil)
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
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            DotFlag(region: shownRegion, width: 38)
                                .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
                            Text(shownRegion.geo.city)
                        }
                    }
                }
                .font(Term.mono(28, .bold))
                .foregroundStyle(vpn.status == .connected ? Term.green : Term.num)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // 나라를 바꾸면 이름이 부드럽게 바뀐다
                .contentTransition(.interpolate)
                .animation(.snappy(duration: 0.35), value: shownRegion)
                Spacer(minLength: 8)
                if let since = vpn.connectedSince, vpn.status == .connected {
                    SessionClock(since: since)
                } else if !onDevice {
                    Text(distanceText(shownRegion))
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: shownRegion)
                }
            }

            if busy || vpn.status.isBusy {
                PhasePipeline(index: pipelineIndex, onDevice: onDevice)
                    .transition(.opacity)
            } else {
                exitLine
                    .transition(.opacity)
            }
            if !busy, vpn.status == .connected, traffic.hasData {
                TrafficPanel(meter: traffic)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !busy, vpn.status == .connected, !Edition.isUser {
                Text(linkStats.map { "link · " + $0 } ?? (vpn.activeProto == .ikev2 ? "link · ikev2 system tunnel" : "link · waiting for stats…"))
                    .font(Term.mono(12))
                    .foregroundStyle(linkStats == nil ? Term.muted : Term.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // 지금 설정(wg/neptun ×2 · adblock …) 꼬리표는 관리자용에만
            if !Edition.isUser {
                FlagRow(flags: flags)
            }
        }
        .animation(.snappy(duration: 0.35), value: busy)
        .animation(.snappy(duration: 0.35), value: vpn.status)
    }

    /// `exit 54.199.12.4 · JP ✓` — 밖에서 보이는 IP가 고른 나라인지. 연결 전엔 지금 회선(isp) IP.
    /// 누르면 IP 뒷부분을 가리거나 다시 보여 주고(스크린샷용, 기억해 둠), 길게 누르면 다시 잰다.
    private var exitLine: some View {
        let connected = vpn.status == .connected
        let label = connected ? "exit" : "isp"
        let line: Text
        if let exitInfo {
            let head = Text("\(label) ").foregroundStyle(Term.muted)
                + Text(hideIP ? ExitInfo.masked(exitInfo.ip) : exitInfo.ip).foregroundStyle(Term.num)
                + Text(" · \(exitInfo.country)").foregroundStyle(Term.muted)
                + Text(exitInfo.colo.isEmpty ? "" : " \(exitInfo.colo)").foregroundStyle(Term.muted)
            if !connected {
                line = head
            } else if onDevice {
                line = head + Text(" · same line, sni split").foregroundStyle(Term.muted.opacity(0.7))
            } else if exitInfo.country == savedRegion.countryCode {
                line = head + Text(" ✓ matches").foregroundStyle(Term.green)
            } else {
                line = head + Text(" ! not \(savedRegion.countryCode) — leak?").foregroundStyle(Term.amber)
            }
        } else {
            line = Text("\(label) checking…").foregroundStyle(Term.muted)
        }
        return line
            .font(Term.mono(12))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentShape(Rectangle())
            .onTapGesture { hideIP.toggle() }
            .onLongPressGesture { Task { exitInfo = await ExitInfo.fetch() } }
            .sensoryFeedback(.selection, trigger: hideIP)
            .accessibilityHint(hideIP ? "tap to show the ip, hold to check again" : "tap to hide the ip, hold to check again")
    }

    /// 상태가 자리를 잡으면 출구 IP를 다시 보고, 끊겼으면 나라별 지연도 다시 잰다.
    /// (연결된 직후엔 경로가 바뀌는 중이라 잠깐 기다린다)
    private func statusSettled() async {
        switch vpn.status {
        case .connected:
            exitInfo = nil
            if Demo.on { await probe.measure() }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            var info = await ExitInfo.fetch()
            // 막 붙었을 때 한 번 다르게 나오면 3초 뒤 한 번 더 본다(경로가 자리 잡는 중일 수 있다) — 그래도 다르면 leak?
            if let first = info, !onDevice, first.country != savedRegion.countryCode {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                info = await ExitInfo.fetch() ?? first
            }
            exitInfo = info
        case .disconnected, .invalid:
            exitInfo = nil
            async let info = ExitInfo.fetch()
            await probe.measure()
            let fetched = await info
            if !Task.isCancelled { exitInfo = fetched }
        default:
            break
        }
    }

    /// 지도·카드에서 나라를 골랐을 때. 연결돼 있으면 갈아탈지 묻는다.
    private func select(_ choice: VPNRegion) {
        guard !locked else { return }
        if vpn.status == .connected {
            if choice != savedRegion, !onDevice { hopTarget = choice }
        } else {
            region = choice
        }
    }

    /// 지금 연결을 끊고 다른 나라로 다시 붙는다.
    private func hop(to target: VPNRegion) async {
        let from = savedRegion
        NagoLog.add("hop \(from.rawValue) → \(target.rawValue)")
        busy = true
        phase = "hop: \(from.rawValue) → \(target.rawValue)"
        await vpn.disconnect()
        var waited = 0
        while (vpn.status.isActive || vpn.status == .disconnecting) && waited < 40 && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        busy = false
        phase = nil
        guard !Task.isCancelled else { return }
        region = target
        await saveAndConnect()
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
            if Edition.isUser { return "up → \(savedRegion.rawValue)" }
            return "up → \(savedRegion.rawValue)" + (vpn.activeProto.map { " · \($0.label)" } ?? "")
        case .connecting: return "connecting"
        case .reasserting: return "reconnecting"
        case .disconnecting: return "disconnecting"
        case .invalid: return "not set up · first connect asks once"
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

    /// 설정 값 "neptun"(예전 이름 그대로 저장)은 화면에 우리 엔진 이름 NagoTun으로
    static func engineName(_ value: String) -> String {
        value == "neptun" ? "NagoTun" : value
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
                Text(exitHint)
                    .foregroundStyle(Term.muted.opacity(0.7))
            }
            .font(Term.mono(11))

            HStack(spacing: 8) {
                ForEach(VPNRegion.fixed) { option in
                    regionCard(option)
                }
            }
            .disabled(locked)
            .opacity(locked ? 0.55 : 1)
            .accessibilityHint(shownRegion.detail)
            // 임시 서버 나라: 고르면 그 나라에 서버를 새로 만든다
            onDemandPanel
                .padding(.top, 2)
        }
        .confirmationDialog("hop to \(hopTarget?.geo.city ?? "")?", isPresented: hopping,
                            titleVisibility: .visible, presenting: hopTarget) { target in
            Button("hop → \(target.rawValue) · \(target.geo.city)") {
                connectTask = Task { await hop(to: target) }
            }
            Button("stay on \(savedRegion.rawValue)", role: .cancel) {}
        } message: { target in
            Text(target.onDemand
                 ? "disconnects \(savedRegion.rawValue), then makes a new server in \(target.geo.city) (~1m)"
                 : "disconnects \(savedRegion.rawValue), then connects \(target.rawValue)")
        }
    }

    /// 임시 서버 나라: 처음엔 한 줄로 접혀 있고(고른 나라만 보임), 펴면 작은 칸으로 두 줄
    private var onDemandPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                FoldChevron(folded: foldOnDemand)
                Text("// on demand").foregroundStyle(Term.muted)
                Text("+\(VPNRegion.allCases.filter(\.onDemand).count) · new server ~1m")
                    .foregroundStyle(Term.muted.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                // 접혀 있어도 지금 고른 임시 나라는 보이게
                if foldOnDemand, shownRegion.onDemand {
                    regionChip(shownRegion)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
            }
            .font(Term.mono(11))
            .frame(minHeight: 22)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.3)) { foldOnDemand.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(foldOnDemand ? "on demand countries, collapsed" : "on demand countries")
            if !foldOnDemand {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(VPNRegion.allCases.filter(\.onDemand)) { option in
                        regionChip(option)
                    }
                }
                .disabled(locked)
                .opacity(locked ? 0.55 : 1)
                .transition(.opacity)
                onDemandFootnote
                    .font(Term.mono(10))
                    .foregroundStyle(Term.muted.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    /// 고른 임시 나라가 있으면 그 나라 왕복 시간을 숫자로(칸에는 막대만 있다), 없으면 누르는 법
    private var onDemandFootnote: Text {
        guard shownRegion.onDemand else {
            return Text("hold a chip for rtt · wg only · gone after 30m idle")
        }
        let measured = probe.rtt[shownRegion]
        let ms = Text(measured.map { "\($0)ms" } ?? "~\(RegionCard.rtt(shownRegion))ms")
            .foregroundStyle(measured.map(RegionCard.rttTint) ?? Term.muted)
        return Text("› \(shownRegion.rawValue) \(shownRegion.geo.city) ").foregroundStyle(Term.text)
            + ms + Text(" · gone after 30m idle")
    }

    private func regionChip(_ option: VPNRegion) -> some View {
        RegionChip(region: option,
                   selected: option == shownRegion,
                   live: option == savedRegion && vpn.status == .connected,
                   measured: probe.rtt[option]) {
            select(option)
        }
    }

    private func regionCard(_ option: VPNRegion) -> some View {
        RegionCard(region: option,
                   selected: option == shownRegion,
                   live: option == savedRegion && vpn.status == .connected,
                   measured: probe.rtt[option],
                   fastest: option == fastestRegion) {
            select(option)
        }
    }

    /// 잰 것 중 가장 빠른 나라(둘 이상 쟀을 때만)
    private var fastestRegion: VPNRegion? {
        guard probe.rtt.count > 1 else { return nil }
        return probe.rtt.min { $0.value < $1.value }?.key
    }

    private var exitHint: String {
        if locked { return "locked while linking" }
        if vpn.status == .connected { return "tap another to hop" }
        if probe.measuring { return "pinging…" }
        return probe.rtt.isEmpty ? "tap map or card · rtt est." : "tap map or card · rtt live"
    }

    private var hopping: Binding<Bool> {
        Binding(get: { hopTarget != nil }, set: { if !$0 { hopTarget = nil } })
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

    private func failureLine(_ message: String) -> some View {
        Button {
            showLogs = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("✗").foregroundStyle(Term.red)
                Text(message)
                    .foregroundStyle(Term.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Text("log ›").foregroundStyle(Term.muted)
            }
            .font(Term.mono(12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("opens the connection log")
    }

    // MARK: 연결 버튼

    /// 연결 중에는 같은 버튼이 취소 버튼이 된다(지금 단계 + cancel).
    private var connectButton: some View {
        Button {
            if busy {
                connectTask?.cancel()
            } else {
                connectTask = Task { await saveAndConnect() }
            }
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(Term.amber)
                    Text(phase.map { $0.replacingOccurrences(of: "…", with: "") } ?? "working")
                        .foregroundStyle(Term.text)
                    Spacer(minLength: 6)
                    Text("cancel").foregroundStyle(Term.amber)
                    Image(systemName: "xmark").foregroundStyle(Term.amber)
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
        .buttonStyle(TermButtonStyle(kind: buttonKind, fill: true))
        .overlay {
            if busy {
                ScanSweep(tint: Term.amber).clipShape(RoundedRectangle(cornerRadius: 6)).allowsHitTesting(false)
            }
        }
        // 연결 중(connecting)에도 끊을 수 있게 둔다. 끊는 중에만 막는다.
        .disabled(vpn.status == .disconnecting
                  || (!busy && !vpn.status.isActive && effectiveProto != .unicorn && username.isEmpty))
        // 단계(웨이포인트)가 하나 찍힐 때마다 가볍게 톡, 실패하면 오류 진동
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: steps.count) { old, new in new > old }
        .sensoryFeedback(.error, trigger: errorText) { _, new in new != nil }
    }

    private var buttonKind: TermButtonStyle.Kind {
        if busy { return .secondary }
        return vpn.status.isActive ? .danger : .primary
    }

    /// 연결돼 있는 동안 터널 확장에 상태를 묻는다(ikev2는 시스템 터널이라 답이 없다). 이 탭이 보이는 동안 1초마다.
    /// 속도 그래프는 터널이 쌓아 둔 최근 1분을 그대로 받아서, 탭을 오가거나 앱을 나갔다 와도 이어진다.
    private func pollLink() async {
        guard vpn.status == .connected else {
            linkStats = nil
            if !Demo.on { traffic.reset() }
            return
        }
        guard !Demo.on else { return }
        while !Task.isCancelled {
            if let report = await vpn.tunnelReport() {
                if let stats = report.stats, !stats.isEmpty { linkStats = stats }
                if let rx = report.rx, let tx = report.tx {
                    if let history = report.history {
                        traffic.load(history: history, rx: rx, tx: tx)
                    } else {
                        traffic.add(rx: rx, tx: tx)   // 예전 터널 확장(기록 없음)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
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
                    try Task.checkCancellation()
                    await vpn.disconnect()
                    step("\(region.rawValue): ikev2 timeout → wg")
                    try await Task.sleep(for: .seconds(1))
                    try await connectWG(target, user: user, key: key)
                }
            case .unicorn:
                break       // 서버가 없어서 위에서 먼저 처리한다(여기까지 오지 않는다)
            }
            // 시스템이 '연결 중'을 알려 올 때까지 busy를 유지해 화면이 한 번 끊겼다 다시 그려지지 않게
            await vpn.waitUntilStarted(seconds: 3)
            savedRegion = region
        } catch {
            if Task.isCancelled {
                await cancelConnect()
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    /// 버튼으로 취소: 이미 저장·시작한 연결이 있으면 내린다.
    private func cancelConnect() async {
        phase = nil
        steps.append(Step(at: Date(), text: "cancelled"))
        NagoLog.add("cancelled")
        await vpn.disconnect()
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
            await vpn.waitUntilStarted(seconds: 3)
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
        // nagotun(neptun) 모드에서 막힌 망 우회가 켜져 있으면 WG를 nagoing 전송(443)으로 감싼다.
        if nagoOn, wgEngine == "neptun" {
            let ns = NagoingSettings.fromDefaults()
            step("\(region.rawValue): nagoing → \(target.address):\(ns.udpPort)")
            try await vpn.saveNagoing(privateKey: reg.privateKey, address: reg.address + "/32",
                                      serverPub: serverPub, serverIP: target.address, wgPort: target.wgPort, dns: wgDNS,
                                      loops: wgLoops, region: region.rawValue, apiKey: key, settings: ns,
                                      autoConnect: autoConnect, killSwitch: killSwitch, allowLAN: allowLAN)
            try vpn.connectTunnel()
            return
        }
        let endpoint = "\(target.address):\(target.wgPort)"
        step("\(region.rawValue): wg/\(wgEngine) → \(endpoint)")
        try await vpn.saveWireGuard(privateKey: reg.privateKey, address: reg.address + "/32",
                                    serverPub: serverPub, endpoint: endpoint, dns: wgDNS, engine: wgEngine,
                                    loops: wgLoops, region: region.rawValue, apiKey: key,
                                    autoConnect: autoConnect, killSwitch: killSwitch, allowLAN: allowLAN)
        try vpn.connectTunnel()
    }

    /// 광고 차단 DNS → 직접 넣은 DNS → 1.1.1.1. 임시 서버엔 차단 DNS가 없다.
    private var wgDNS: [String] {
        if adblock, !region.onDemand { return ["10.53.53.53"] }
        return DNSList.parse(customDNS) ?? ["1.1.1.1"]
    }

    /// 고른 국가 서버를 켜고 주소를 받는다. 비밀번호가 틀린 게 아니면 한국 서버는 고정 IP로 대신 시도한다.
    private func resolveTarget(key: String) async throws -> RegionAPI.Target {
        do {
            return try await RegionAPI.waitUntilReady(region, key: key) { step($0) }
        } catch RegionAPI.APIError.forbidden {
            throw RegionAPI.APIError.forbidden
        } catch {
            // 취소했으면 고정 IP로 넘어가지 않는다
            try Task.checkCancellation()
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
