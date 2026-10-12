import SwiftUI
import NagoDLCore

struct SettingsView: View {
    @EnvironmentObject private var store: DownloadStore
    @AppStorage(Pref.connections) private var connections = 8
    @AppStorage(Pref.maxActive) private var maxActive = 3
    @AppStorage(Pref.cellular) private var cellular = true
    @AppStorage(Pref.background) private var background = true
    @AppStorage(Pref.clipboard) private var clipboard = true
    @AppStorage(Pref.notify) private var notify = true
    @AppStorage(Pref.desktopMode) private var desktopMode = false
    @AppStorage(Pref.search) private var search = SearchEngine.google.rawValue
    @AppStorage(Pref.home) private var home = "https://www.google.com"
    @State private var usage: (used: Int64, free: Int64?) = (0, nil)

    var body: some View {
        TermPage(path: "settings") {
            TermBlock(label: "download") {
                row("conn", "파일 하나를 몇 개 연결로 나눠 받을지") {
                    TermChoice(options: [1, 2, 4, 8, 16, 32].map { (label: "\($0)", value: $0) }, selection: $connections)
                }
                TermDivider()
                row("queue", "동시에 받는 파일 수") {
                    TermChoice(options: [1, 2, 3, 5].map { (label: "\($0)", value: $0) }, selection: $maxActive)
                }
                TermDivider()
                toggle("--cellular", "셀룰러 데이터로도 받기(백그라운드는 다음 실행부터)", $cellular)
                TermDivider()
                toggle("--background", "앱을 나가도 시스템이 이어서 받기", $background)
                TermDivider()
                toggle("--notify", "다 받으면 알림", $notify)
                TermDivider()
                toggle("--clipboard", "복사한 링크가 있으면 붙여넣기 단추 보이기", $clipboard)
            }

            TermBlock(label: "browser") {
                row("search", "주소창 검색") {
                    TermChoice(options: SearchEngine.allCases.map { (label: $0.label, value: $0.rawValue) }, selection: $search)
                }
                TermDivider()
                toggle("--desktop", "데스크톱 사이트로 열기", $desktopMode)
                TermDivider()
                TermField(key: "home", text: $home, placeholder: "https://…", keyboard: .URL)
            }

            TermBlock(label: "storage") {
                line("files", "파일 앱 → 나의 iPhone → NAGO DL")
                line("used", ByteFormat.size(usage.used))
                if let free = usage.free { line("free", ByteFormat.size(free)) }
                HStack(spacing: 8) {
                    Button { store.clearCompleted() } label: { Label("완료 목록 정리", systemImage: "list.bullet") }
                        .buttonStyle(.term)
                    Button { store.pauseAll() } label: { Label("모두 멈춤", systemImage: "pause") }
                        .buttonStyle(.term)
                    Button { store.resumeAll() } label: { Label("모두 재개", systemImage: "play") }
                        .buttonStyle(.term)
                }
            }

            TermBlock(label: "about") {
                line("app", "NAGO DL \(Self.version)")
                Text("여러 연결로 나눠 받기 · 이어 받기 · m3u8 동영상 → MP4 · 공유 메뉴로 받기. DRM이 걸린 영상은 받지 않아요.")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
            }
        }
        .onAppear(perform: refreshUsage)
        .onChange(of: connections) { _, _ in store.applySettings() }
        .onChange(of: maxActive) { _, _ in store.applySettings() }
        .onChange(of: cellular) { _, _ in store.applySettings() }
    }

    private func row<Content: View>(_ key: String, _ hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(key).foregroundStyle(Term.text)
                Text(hint).foregroundStyle(Term.muted).lineLimit(2)
            }
            .font(Term.mono(13))
            content()
        }
    }

    private func toggle(_ key: String, _ hint: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key).font(Term.mono(14)).foregroundStyle(Term.text)
                Text(hint).font(Term.mono(11)).foregroundStyle(Term.muted)
            }
        }
        .tint(Term.green)
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(Term.muted).frame(width: 48, alignment: .leading)
            Text(value).foregroundStyle(Term.text)
            Spacer(minLength: 0)
        }
        .font(Term.mono(13))
    }

    private func refreshUsage() {
        Task {
            let result = await Self.measure()
            usage = result
        }
    }

    /// 메인 스레드 밖에서 폴더 크기를 잰다
    nonisolated static func measure() async -> (used: Int64, free: Int64?) {
        let paths = EnginePaths.standard()
        return (folderSize(paths.output) + folderSize(paths.support), AddDownloadView.freeSpace())
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
