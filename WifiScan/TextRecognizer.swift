import UIKit
import Vision

enum TextRecognizer {
    /// 사진에서 와이파이 정보를 찾는다. 영문 모델로 먼저 읽고, 부족하면 한글 라벨(비밀번호 등)까지 읽도록 한 번 더 시도한다.
    static func recognizeCredentials(in image: UIImage) async -> (ParsedCredentials, [OCRLine]) {
        let english = (try? await recognize(image, languages: ["en-US"])) ?? []
        let first = CredentialParser.parse(english)
        if first.isComplete { return (first, english) }

        let korean = (try? await recognize(image, languages: ["ko-KR", "en-US"])) ?? []
        let second = CredentialParser.parse(korean)
        return second.fieldCount > first.fieldCount ? (second, korean) : (first, english)
    }

    /// 사진 속 글자를 위에서 아래 순서의 여러 줄 텍스트로 돌려준다(같은 행에 있는 조각은 한 줄로 합침).
    static func recognizeText(in image: UIImage) async -> String {
        let lines = (try? await recognize(image, languages: ["ko-KR", "en-US"])) ?? []
        return AccountParser.joinRows(lines)
    }

    static func recognize(_ image: UIImage, languages: [String]) async throws -> [OCRLine] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // 비밀번호를 '단어'로 교정해버리지 않도록
            request.recognitionLanguages = languages

            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])

            return (request.results ?? []).compactMap { observation -> OCRLine? in
                let candidates = observation.topCandidates(3).map(\.string)
                guard let best = candidates.first else { return nil }
                return OCRLine(text: best, candidates: candidates, box: observation.boundingBox)
            }
        }.value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
