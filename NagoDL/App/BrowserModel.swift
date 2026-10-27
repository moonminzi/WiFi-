import Foundation
import SwiftUI
import WebKit
import NagoDLCore

/// 페이지에서 찾은 동영상/음성
struct DetectedMedia: Identifiable, Equatable {
    enum Kind: String {
        case hls = "m3u8"
        case video
        case audio
    }

    var id: String { url.absoluteString }
    var url: URL
    var kind: Kind
    var how: String
    var pageURL: URL?
    var title: String

    var label: String {
        switch kind {
        case .hls: return "HLS"
        case .video, .audio:
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? (kind == .video ? "VIDEO" : "AUDIO") : ext
        }
    }
}

/// 페이지의 링크 한 줄(링크 모아 받기)
struct PageLink: Identifiable, Hashable {
    var id: String { url.absoluteString }
    var url: URL
    var text: String
}

/// 앱 안 브라우저. 다운로드 링크를 가로채고, 페이지가 불러오는 동영상(mp4/m3u8)을 찾아 둔다.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    @Published var address = ""
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var media: [DetectedMedia] = []
    @Published var currentURL: URL?

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var pendingWebDownloads: [ObjectIdentifier: (url: URL, name: String, source: URL?)] = [:]
    private var userAgent: String?
    private var lastMainFrameMethod = "GET"
    weak var store: DownloadStore?
    weak var router: Router?

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: MediaSniffer.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakScriptHandler(self), name: "nagodl")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = Term.UI.bg
        applyDesktopMode()

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.currentURL = view.url
                    if let url = view.url { self?.address = url.absoluteString }
                }
            },
        ]
    }

    func attach(store: DownloadStore, router: Router) {
        self.store = store
        self.router = router
    }

    // MARK: 이동

    func submit(_ text: String) {
        if let url = LinkProbe.urlFromAddressBar(text) {
            load(url)
        } else if let url = SearchEngine.current.url(text) {
            load(url)
        }
    }

    func load(_ url: URL) {
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goHome() {
        let home = UserDefaults.standard.string(forKey: Pref.home) ?? "https://www.google.com"
        if let url = URL(string: home) { load(url) }
    }

    func applyDesktopMode() {
        webView.customUserAgent = UserDefaults.standard.bool(forKey: Pref.desktopMode) ? Self.desktopUA : nil
        userAgent = nil
    }

    // MARK: 다운로드로 넘기기

    /// 이 주소를 받을 때 쓸 헤더(브라우저 쿠키·User-Agent·Referer)
    func headers(for url: URL) async -> [String: String] {
        var h: [String: String] = [:]
        if let ua = await currentUserAgent() { h["User-Agent"] = ua }
        if let page = webView.url { h["Referer"] = page.absoluteString }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let matched = Self.cookies(cookies, for: url)
        if let cookie = HTTPCookie.requestHeaderFields(with: matched)["Cookie"], !cookie.isEmpty {
            h["Cookie"] = cookie
        }
        return h
    }

    private func currentUserAgent() async -> String? {
        if let userAgent { return userAgent }
        if let custom = webView.customUserAgent { return custom }
        let ua = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        userAgent = ua
        return ua
    }

    static func cookies(_ all: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        return all.filter { c in
            if let expires = c.expiresDate, expires < now { return false }
            if c.isSecure && !secure { return false }
            var domain = c.domain.lowercased()
            let dotted = domain.hasPrefix(".")
            if dotted { domain.removeFirst() }
            let domainOK = host == domain || (dotted && host.hasSuffix("." + domain))
            return domainOK && path.hasPrefix(c.path)
        }
    }

    /// 다운로드 추가 화면을 띄운다(쿠키 등을 챙겨서)
    func offer(_ url: URL, suggestedName: String? = nil) {
        let page = webView.url
        Task {
            let h = await headers(for: url)
            router?.openAdd(AddRequest(text: url.absoluteString, pageURL: page, headers: h, suggestedName: suggestedName))
        }
    }

    /// 찾은 동영상 이름: 페이지 제목 + 확장자
    func suggestedName(for item: DetectedMedia) -> String? {
        let base = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let ext: String
        switch item.kind {
        case .hls: ext = "mp4"
        case .video, .audio: ext = item.url.pathExtension.isEmpty ? (item.kind == .video ? "mp4" : "m4a") : item.url.pathExtension
        }
        return FileNamer.sanitize(base) + "." + ext
    }

    /// 페이지의 모든 링크(링크 모아 받기)
    func collectLinks() async -> [PageLink] {
        let js = """
        (function(){var out=[];var seen={};var as=document.querySelectorAll('a[href]');\
        for(var i=0;i<as.length&&out.length<3000;i++){var a=as[i];var h=a.href;if(!h||seen[h])continue;seen[h]=1;\
        out.push({u:h,t:(a.textContent||a.title||'').replace(/\\s+/g,' ').trim().slice(0,120)});}\
        return JSON.stringify(out);})()
        """
        guard let json = try? await webView.evaluateJavaScript(js) as? String,
              let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let s = row["u"], let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return PageLink(url: url, text: row["t"] ?? "")
        }
    }

    static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "dmg", "img", "bin", "apk", "ipa", "exe", "msi",
        "deb", "rpm", "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "hwp", "txt", "csv",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "m3u8", "mp3", "m4a", "aac", "flac", "wav",
        "ogg", "opus", "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg", "torrent", "srt",
        "ass", "vtt", "json", "xml", "psd", "ai", "sketch", "ttf", "otf", "woff2",
    ]

    static func isFileLink(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    fileprivate func received(_ body: Any) {
        guard let dict = body as? [String: Any], (dict["kind"] as? String) == "media",
              let s = dict["url"] as? String, let url = URL(string: s) else { return }
        let ext = url.pathExtension.lowercased()
        let kind: DetectedMedia.Kind
        if ext == "m3u8" {
            kind = .hls
        } else if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) {
            kind = .audio
        } else {
            kind = .video
        }
        guard !media.contains(where: { $0.url == url }) else { return }
        let page = (dict["page"] as? String).flatMap(URL.init(string:))
        media.append(DetectedMedia(url: url, kind: kind, how: dict["how"] as? String ?? "", pageURL: page,
                                   title: dict["title"] as? String ?? ""))
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate / WKDownloadDelegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    // 결정 함수는 async 판을 쓴다(완료 클로저 판은 SDK마다 @Sendable 표기가 달라 조용히 안 불릴 수 있다)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = UserDefaults.standard.bool(forKey: Pref.desktopMode) ? .desktop : .mobile
        if navigationAction.targetFrame?.isMainFrame ?? true {
            lastMainFrameMethod = navigationAction.request.httpMethod ?? "GET"
        }
        if navigationAction.shouldPerformDownload {
            // <a download>: 일반 주소면 우리 엔진으로(여러 연결), blob:/data:/POST는 브라우저가 받는다
            if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               (navigationAction.request.httpMethod ?? "GET") == "GET" {
                offer(url)
                return (.cancel, preferences)
            }
            return (.download, preferences)
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // 다른 앱 링크(itms-apps:, tel: 등)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        let http = response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
        let mime = response.mimeType?.lowercased() ?? ""
        let url = response.url
        let isHLS = LinkProbe.hlsTypes.contains(mime) || url?.pathExtension.lowercased() == "m3u8"
        let wantsDownload = ContentDisposition.isAttachment(disposition) || !navigationResponse.canShowMIMEType || isHLS
        guard navigationResponse.isForMainFrame, wantsDownload else { return .allow }
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", lastMainFrameMethod == "GET" {
            let name = ContentDisposition.filename(from: disposition) ?? response.suggestedFilename
            offer(url, suggestedName: isHLS ? nil : name.map { FileNamer.sanitize($0) })
            return .cancel
        }
        return .download
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 새 페이지: 찾은 동영상 목록을 비운다
        media.removeAll()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // 취소(-999)와 "다운로드로 넘김"(102)은 오류가 아니다
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        store?.show(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// target=_blank 같은 새 창은 같은 화면에서 연다
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // WKDownloadDelegate: 브라우저가 직접 받는 것(blob:, data:, POST 폼)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("web-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = FileNamer.sanitize(suggestedFilename)
        let target = dir.appendingPathComponent(name)
        pendingWebDownloads[ObjectIdentifier(download)] = (target, name, response.url)
        store?.show("받는 중: \(name)")
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = pendingWebDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let source = info.source ?? webView.url ?? info.url
        store?.manager.addCompletedFile(at: info.url, name: info.name, sourceURL: source, pageURL: webView.url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingWebDownloads.removeValue(forKey: ObjectIdentifier(download))
        store?.show("브라우저 다운로드 실패: \(error.localizedDescription)")
    }
}

/// WKUserContentController는 핸들러를 강하게 잡아서, 모델을 약하게 가리키는 중간 객체를 넘긴다.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserModel?

    init(_ target: BrowserModel) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}

/// 페이지에 넣는 스크립트: video/audio 요소, fetch/XHR, 리소스 목록에서 동영상 주소를 찾아 앱에 알린다.
enum MediaSniffer {
    static let script = #"""
    (function () {
      if (window.__nagodl) { return; }
      window.__nagodl = true;
      var seen = {};
      var MEDIA = /\.(m3u8|mp4|m4v|mov|webm|mkv|mp3|m4a|aac|flac|wav|ogg|opus)(\?|#|$)/i;
      function post(url, how) {
        try {
          if (!url || typeof url !== 'string') { return; }
          if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) { return; }
          var abs = new URL(url, document.baseURI).href;
          if (seen[abs]) { return; }
          seen[abs] = true;
          window.webkit.messageHandlers.nagodl.postMessage({ kind: 'media', url: abs, how: how, page: location.href, title: document.title || '' });
        } catch (e) {}
      }
      function scan() {
        try {
          var els = document.querySelectorAll('video, audio, video source, audio source');
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            post(el.currentSrc || el.src || el.getAttribute('src'), el.tagName.toLowerCase());
          }
        } catch (e) {}
      }
      try {
        var origFetch = window.fetch;
        if (typeof origFetch === 'function') {
          window.fetch = function (input, init) {
            try {
              var u = (typeof input === 'string') ? input : (input && input.url);
              if (u && MEDIA.test(u)) { post(u, 'fetch'); }
            } catch (e) {}
            return origFetch.apply(this, arguments);
          };
        }
      } catch (e) {}
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { if (url && MEDIA.test(String(url))) { post(String(url), 'xhr'); } } catch (e) {}
          return origOpen.apply(this, arguments);
        };
      } catch (e) {}
      ['loadedmetadata', 'loadstart', 'play'].forEach(function (name) {
        document.addEventListener(name, function (e) {
          var t = e.target;
          if (t && (t.currentSrc || t.src)) { post(t.currentSrc || t.src, 'event'); }
        }, true);
      });
      var timer = null;
      function later() {
        if (timer) { return; }
        timer = setTimeout(function () { timer = null; scan(); }, 400);
      }
      try {
        new MutationObserver(later).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
      } catch (e) {}
      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (en) { if (MEDIA.test(en.name)) { post(en.name, 'perf'); } });
        }).observe({ type: 'resource', buffered: true });
      } catch (e) {}
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """#
}
