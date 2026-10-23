import SwiftUI
import WebKit
import NagoDLCore

/// WKWebView를 그대로 보여 준다(모델이 들고 있는 같은 인스턴스)
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var router: Router
    @StateObject private var model = BrowserModel()
    @State private var showMedia = false
    @State private var showLinks = false
    @State private var links: [PageLink] = []
    @State private var loadingLinks = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressLine
            WebViewHost(webView: model.webView)
                .ignoresSafeArea(.container, edges: .bottom)
            toolbar
        }
        .background(Term.bg.ignoresSafeArea())
        .onAppear {
            model.attach(store: store, router: router)
            if let url = router.browse {
                router.browse = nil
                model.load(url)
            } else if model.currentURL == nil {
                model.goHome()
            }
        }
        .onChange(of: router.browse) { _, url in
            guard let url else { return }
            router.browse = nil
            model.load(url)
        }
        .sheet(isPresented: $showMedia) {
            MediaSheet(model: model)
                .environmentObject(store)
                .environmentObject(router)
        }
        .sheet(isPresented: $showLinks) {
            LinkSheet(model: model, links: links)
                .environmentObject(store)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Text(model.currentURL?.scheme == "https" ? "🔒" : "~")
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            TextField("", text: $model.address, prompt: Text("주소 또는 검색어").foregroundStyle(Term.muted.opacity(0.6)))
                .font(Term.mono(14))
                .foregroundStyle(Term.text)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit { model.submit(model.address) }
            if addressFocused {
                Button("취소") {
                    addressFocused = false
                    model.address = model.currentURL?.absoluteString ?? ""
                }
                .font(Term.mono(13))
                .tint(Term.green)
            } else if model.isLoading {
                Button { model.webView.stopLoading() } label: { Image(systemName: "xmark") }
                    .tint(Term.muted)
            } else {
                Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .tint(Term.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Term.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Term.border).frame(height: 1) }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Term.green)
                .frame(width: geo.size.width * (model.isLoading ? max(0.05, model.progress) : 0))
                .animation(.easeOut(duration: 0.2), value: model.progress)
        }
        .frame(height: 2)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton("chevron.left", enabled: model.canGoBack) { model.webView.goBack() }
            toolButton("chevron.right", enabled: model.canGoForward) { model.webView.goForward() }
            toolButton("house", enabled: true) { model.goHome() }
            Button {
                loadingLinks = true
                Task {
                    links = await model.collectLinks()
                    loadingLinks = false
                    showLinks = true
                }
            } label: {
                Image(systemName: loadingLinks ? "hourglass" : "link")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(Term.text)
            Button { showMedia = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "film")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    if !model.media.isEmpty {
                        Text("\(model.media.count)")
                            .font(Term.mono(10, .bold))
                            .foregroundStyle(Term.bg)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Term.green, in: Capsule())
                            .offset(x: -14, y: 4)
                    }
                }
            }
            .tint(model.media.isEmpty ? Term.muted : Term.green)
            Menu {
                if let url = model.currentURL {
                    Button {
                        model.offer(url)
                    } label: { Label("이 주소 받기", systemImage: "arrow.down.circle") }
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        store.show("주소를 복사했어요")
                    } label: { Label("주소 복사", systemImage: "doc.on.doc") }
                }
                Button {
                    let desktop = !UserDefaults.standard.bool(forKey: Pref.desktopMode)
                    UserDefaults.standard.set(desktop, forKey: Pref.desktopMode)
                    model.applyDesktopMode()
                    model.webView.reload()
                    store.show(desktop ? "데스크톱 사이트로" : "모바일 사이트로")
                } label: { Label("데스크톱/모바일 전환", systemImage: "desktopcomputer") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(Term.text)
        }
        .font(.system(size: 17, weight: .medium))
        .background(Term.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Term.border).frame(height: 1) }
    }

    private func toolButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(enabled ? Term.text : Term.muted.opacity(0.5))
        .disabled(!enabled)
    }
}

/// 페이지에서 찾은 동영상/음성 목록
struct MediaSheet: View {
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TermPage(path: "web/media") {
                if model.media.isEmpty {
                    TermWindow(title: "media — empty") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("아직 찾은 동영상이 없어요")
                                .foregroundStyle(Term.text)
                            Text("· 동영상을 한 번 재생하면 주소가 잡혀요")
                            Text("· DRM(넷플릭스 등)과 유튜브는 받을 수 없어요")
                        }
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                    }
                } else {
                    ForEach(model.media) { item in
                        Button {
                            dismiss()
                            model.offer(item.url, suggestedName: model.suggestedName(for: item))
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.label)
                                    .font(Term.mono(11, .bold))
                                    .foregroundStyle(Term.bg)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(item.kind == .hls ? Term.key : Term.green, in: RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.url.lastPathComponent.isEmpty ? (item.url.host ?? "") : item.url.lastPathComponent)
                                        .font(Term.mono(13, .semibold))
                                        .foregroundStyle(Term.text)
                                        .lineLimit(2)
                                    Text(item.url.host ?? "")
                                        .font(Term.mono(11))
                                        .foregroundStyle(Term.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(Term.green)
                            }
                            .padding(12)
                            .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .font(Term.mono(14, .semibold))
                        .tint(Term.green)
                }
            }
            .toolbarBackground(Term.bg, for: .navigationBar)
        }
    }
}

/// 링크 모아 받기: 페이지의 파일 링크를 골라 한꺼번에
struct LinkSheet: View {
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    let links: [PageLink]
    @State private var selected: Set<String> = []
    @State private var showAll = false

    private var visible: [PageLink] {
        showAll ? links : links.filter { BrowserModel.isFileLink($0.url) }
    }

    var body: some View {
        NavigationStack {
            TermPage(path: "web/links") {
                HStack(spacing: 8) {
                    TermChoice(options: [(label: "파일만", value: false), (label: "전부", value: true)], selection: $showAll)
                    Spacer(minLength: 0)
                    Button(selected.count == visible.count && !visible.isEmpty ? "선택 해제" : "모두 선택") {
                        if selected.count == visible.count {
                            selected.removeAll()
                        } else {
                            selected = Set(visible.map(\.id))
                        }
                    }
                    .font(Term.mono(13))
                    .tint(Term.green)
                }
                if visible.isEmpty {
                    Text(showAll ? "링크가 없어요" : "파일 링크가 없어요(‘전부’를 눌러 모든 링크 보기)")
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                }
                ForEach(visible) { link in
                    Button {
                        if selected.contains(link.id) { selected.remove(link.id) } else { selected.insert(link.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selected.contains(link.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(link.id) ? Term.green : Term.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.url.lastPathComponent.removingPercentEncoding ?? link.url.lastPathComponent)
                                    .font(Term.mono(13, .semibold))
                                    .foregroundStyle(Term.text)
                                    .lineLimit(2)
                                if !link.text.isEmpty {
                                    Text(link.text)
                                        .font(Term.mono(11))
                                        .foregroundStyle(Term.muted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let chosen = visible.filter { selected.contains($0.id) }
                    let page = model.currentURL
                    Task {
                        for link in chosen {
                            let headers = await model.headers(for: link.url)
                            store.add(NewDownload(url: link.url, headers: headers, pageURL: page))
                        }
                        store.show("\(chosen.count)개를 목록에 넣었어요")
                    }
                    dismiss()
                } label: {
                    Label("선택한 \(selected.count)개 받기", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                .disabled(selected.isEmpty)
                .padding(16)
                .background(Term.bg)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .font(Term.mono(14, .semibold))
                        .tint(Term.green)
                }
            }
            .toolbarBackground(Term.bg, for: .navigationBar)
        }
    }
}
