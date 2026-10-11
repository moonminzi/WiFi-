import UIKit
import UniformTypeIdentifiers

/// 공유 메뉴 → NAGO DL: 링크를 꺼내 앱을 nagodl://add?url=… 로 연다.
/// 앱을 못 열면 링크를 클립보드에 복사해 두고 알려 준다(앱을 열면 붙여넣기 단추가 뜬다).
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.04, alpha: 0.96)
        label.textColor = UIColor(red: 0.79, green: 0.83, blue: 0.77, alpha: 1)
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "NAGO DL로 보내는 중…"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { @MainActor [weak self] in
            let url = await Self.findURL(items)
            self?.send(url)
        }
    }

    private func send(_ url: URL?) {
        guard let url else {
            finish(message: "링크를 찾지 못했어요")
            return
        }
        var components = URLComponents()
        components.scheme = "nagodl"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let appURL = components.url, openContainingApp(appURL) {
            finish(message: nil)
        } else {
            UIPasteboard.general.string = url.absoluteString
            finish(message: "링크를 복사했어요.\nNAGO DL을 열면 바로 받을 수 있어요.")
        }
    }

    private func finish(message: String?) {
        if let message {
            label.text = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// 확장에서는 UIApplication.open을 직접 못 부른다. 응답 체인에서 앱 객체를 찾아 같은 메서드를 부른다.
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let function = unsafeBitCast(current.method(for: selector), to: OpenFunction.self)
                function(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// 공유된 것에서 첫 http(s) 링크(URL 항목 → 글 속 링크 순)
    nonisolated private static func findURL(_ items: [NSExtensionItem]) async -> URL? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(p), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(p), let url = firstURL(in: text) { return url }
        }
        return nil
    }

    nonisolated private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                var url = item as? URL
                if url == nil, let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                cont.resume(returning: url)
            }
        }
    }

    nonisolated private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                cont.resume(returning: text)
            }
        }
    }

    nonisolated private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        }
        return nil
    }
}
