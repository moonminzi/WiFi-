import SwiftUI
import UIKit

@MainActor
@Observable
final class ScanModel {
    enum Status: Equatable {
        case idle
        case scanning
        case notFound
        case joining
        case joined(String)
        case failed(String)
    }

    var image: UIImage?
    var ssid = ""
    var password = ""
    var ssidAlternatives: [String] = []
    var passwordAlternatives: [String] = []
    var status: Status = .idle

    var canJoin: Bool {
        !ssid.trimmingCharacters(in: .whitespaces).isEmpty && status != .joining && status != .scanning
    }

    func load(_ image: UIImage, autoJoin: Bool) async {
        self.image = image
        status = .scanning
        ssid = ""
        password = ""
        ssidAlternatives = []
        passwordAlternatives = []

        let (result, _) = await TextRecognizer.recognizeCredentials(in: image)
        ssid = result.ssid ?? ""
        password = result.password ?? ""
        ssidAlternatives = result.ssidAlternatives
        passwordAlternatives = result.passwordAlternatives

        guard result.ssid != nil else {
            status = .notFound
            return
        }
        status = .idle
        if autoJoin, result.isComplete { await join() }
    }

    func join() async {
        let ssid = ssid.trimmingCharacters(in: .whitespaces)
        status = .joining
        switch await WiFiJoiner.join(ssid: ssid, password: password) {
        case .joined:
            status = .joined(ssid)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .cancelled:
            status = .idle
        case .notConnected:
            status = .failed("연결되지 않았어요. 비밀번호에서 헷갈리는 글자(색으로 표시)를 확인해 보세요.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .failed(let message):
            status = .failed(message)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
