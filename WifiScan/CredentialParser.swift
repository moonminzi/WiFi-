import Foundation

/// OCR 한 줄. `box`는 Vision 좌표계(0~1 정규화, 원점 왼쪽 아래)를 따른다.
struct OCRLine {
    var text: String
    var candidates: [String]
    var box: CGRect
}

struct ParsedCredentials {
    var ssid: String?
    var password: String?
    var ssidAlternatives: [String] = []
    var passwordAlternatives: [String] = []

    var isComplete: Bool { ssid != nil && password != nil }
    var fieldCount: Int { (ssid == nil ? 0 : 1) + (password == nil ? 0 : 1) }
}

/// "ID / PW" 형태의 와이파이 안내문에서 SSID와 비밀번호를 뽑아낸다.
enum CredentialParser {
    private static let ssidLabel = #"(?:ssid|[i1l|]\s?d|아이디|와이파이|wi-?fi|네트워크|network)"#
    private static let passwordLabel = #"(?:password|passwd|pass|pwd|p\s?/?\s?w|pvv|비밀번호|비번|암호|패스워드|key)"#
    private static let separator = #"\s*(?:[:：=]\s*|\s+|$)"#

    private static let ssidLabelRegex = try! NSRegularExpression(
        pattern: "^\\s*" + ssidLabel + separator, options: [.caseInsensitive])
    private static let passwordLabelRegex = try! NSRegularExpression(
        pattern: "^\\s*" + passwordLabel + separator, options: [.caseInsensitive])
    /// 한 줄에 "ID: xxx PW: yyy"처럼 같이 적힌 경우. 값 안의 "pw"와 헷갈리지 않도록 구분자를 필수로 둔다.
    private static let inlinePasswordRegex = try! NSRegularExpression(
        pattern: "(?:^|[\\s/,|])" + passwordLabel + #"\s*[:：=]\s*"#, options: [.caseInsensitive])

    /// 통신사 기본 SSID 등, 라벨이 없을 때 SSID로 볼 만한 패턴.
    private static let knownSSIDRegex = try! NSRegularExpression(
        pattern: #"(?:^U\s*[+t十]?\s*Net|KT_|SK_|iptime|olleh|_5G|_2G|_2\.4G|5G$|2G$)"#,
        options: [.caseInsensitive])

    static func parse(_ lines: [OCRLine]) -> ParsedCredentials {
        var result = ParsedCredentials()
        var ssidLabelLines: [Int] = []
        var passwordLabelLines: [Int] = []
        var usedAsValue = Set<Int>()

        for (i, line) in lines.enumerated() {
            // 1) 한 줄 안에 ID와 PW가 모두 있는 경우
            if let split = splitInline(line.text) {
                if result.ssid == nil, let value = stripLabel(split.ssidPart, regex: ssidLabelRegex),
                   !value.isEmpty {
                    result.ssid = cleanSSID(value)
                }
                if result.password == nil, !split.passwordPart.isEmpty {
                    result.password = cleanPassword(split.passwordPart)
                }
                usedAsValue.insert(i)
                continue
            }
            // 2) 라벨과 값이 같은 줄에 있는 경우 / 라벨만 있는 경우
            if let value = stripLabel(line.text, regex: passwordLabelRegex) {
                if value.isEmpty {
                    passwordLabelLines.append(i)
                } else if result.password == nil {
                    result.password = cleanPassword(value)
                    result.passwordAlternatives = alternatives(line, regex: passwordLabelRegex, clean: cleanPassword)
                    usedAsValue.insert(i)
                }
            } else if let value = stripLabel(line.text, regex: ssidLabelRegex) {
                if value.isEmpty {
                    ssidLabelLines.append(i)
                } else if result.ssid == nil {
                    result.ssid = cleanSSID(value)
                    result.ssidAlternatives = alternatives(line, regex: ssidLabelRegex, clean: cleanSSID)
                    usedAsValue.insert(i)
                }
            }
        }

        let labelLines = Set(ssidLabelLines + passwordLabelLines)

        // 3) 라벨만 있는 줄 → 오른쪽(같은 행) 또는 바로 아래 줄에서 값을 찾는다
        if result.ssid == nil {
            for li in ssidLabelLines {
                if let vi = valueLine(for: li, in: lines, excluding: labelLines.union(usedAsValue)) {
                    result.ssid = cleanSSID(lines[vi].text)
                    result.ssidAlternatives = alternatives(lines[vi], regex: nil, clean: cleanSSID)
                    usedAsValue.insert(vi)
                    break
                }
            }
        }
        if result.password == nil {
            for li in passwordLabelLines {
                if let vi = valueLine(for: li, in: lines, excluding: labelLines.union(usedAsValue)) {
                    result.password = cleanPassword(lines[vi].text)
                    result.passwordAlternatives = alternatives(lines[vi], regex: nil, clean: cleanPassword)
                    usedAsValue.insert(vi)
                    break
                }
            }
        }

        // 4) 라벨이 없을 때: 알려진 SSID 패턴 + 비밀번호처럼 생긴 줄
        let remaining = lines.indices.filter { !labelLines.contains($0) && !usedAsValue.contains($0) }
        if result.ssid == nil,
           let vi = remaining.first(where: { matches(knownSSIDRegex, lines[$0].text) }) {
            result.ssid = cleanSSID(lines[vi].text)
            result.ssidAlternatives = alternatives(lines[vi], regex: nil, clean: cleanSSID)
            usedAsValue.insert(vi)
        }
        if result.password == nil {
            let candidates = remaining
                .filter { !usedAsValue.contains($0) }
                .map { ($0, cleanPassword(lines[$0].text)) }
                .filter { looksLikePassword($0.1) }
            if let best = candidates.max(by: { $0.1.count < $1.1.count }) {
                result.password = best.1
                result.passwordAlternatives = alternatives(lines[best.0], regex: nil, clean: cleanPassword)
            }
        }

        if let ssid = result.ssid { result.ssidAlternatives.removeAll { $0 == ssid } }
        if let pw = result.password { result.passwordAlternatives.removeAll { $0 == pw } }
        return result
    }

    // MARK: - 정리 규칙

    static func cleanSSID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ":：=")))
        // U+Net의 위첨자 '+'는 't', '十', 공백 등으로 잘못 읽히기 쉽다
        if let r = s.range(of: #"^U\s*[+t十]?\s*Net"#, options: [.regularExpression, .caseInsensitive]) {
            s.replaceSubrange(r, with: "U+Net")
            s = s.replacingOccurrences(of: " ", with: "")
        }
        s = s.replacingOccurrences(of: #"\s*([_\-])\s*"#, with: "$1", options: .regularExpression)
        return s
    }

    static func cleanPassword(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^[:：=]+"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    static func looksLikePassword(_ s: String) -> Bool {
        guard (8...63).contains(s.count) else { return false }
        let hasDigit = s.rangeOfCharacter(from: .decimalDigits) != nil
        let hasLetter = s.rangeOfCharacter(from: .letters) != nil
        return hasDigit && (hasLetter || s.allSatisfy(\.isNumber))
    }

    // MARK: - 내부 도우미

    /// 라벨로 시작하면 라벨 뒤 값을 반환(라벨만 있으면 빈 문자열). 라벨이 아니면 nil.
    private static func stripLabel(_ text: String, regex: NSRegularExpression) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespaces)
    }

    private static func splitInline(_ text: String) -> (ssidPart: String, passwordPart: String)? {
        let ns = text as NSString
        guard ssidLabelRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil,
              let m = inlinePasswordRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range.location > 0
        else { return nil }
        let ssidPart = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "/,|")))
        let passwordPart = ns.substring(from: m.range.upperBound)
        return (ssidPart, passwordPart)
    }

    private static func alternatives(
        _ line: OCRLine, regex: NSRegularExpression?, clean: (String) -> String
    ) -> [String] {
        var seen = Set<String>()
        return line.candidates.compactMap { cand -> String? in
            let value = regex.map { stripLabel(cand, regex: $0) ?? cand } ?? cand
            let cleaned = clean(value)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    /// 라벨 줄의 같은 행 오른쪽, 없으면 바로 아래 줄을 찾는다.
    private static func valueLine(for labelIndex: Int, in lines: [OCRLine], excluding: Set<Int>) -> Int? {
        let label = lines[labelIndex].box
        let others = lines.indices.filter { $0 != labelIndex && !excluding.contains($0) }

        let sameRow = others.filter { i in
            let b = lines[i].box
            let overlap = min(b.maxY, label.maxY) - max(b.minY, label.minY)
            return overlap > 0.4 * min(b.height, label.height) && b.midX > label.midX
        }
        if let i = sameRow.min(by: { lines[$0].box.minX < lines[$1].box.minX }) { return i }

        let below = others.filter { i in
            let b = lines[i].box
            let horizontalOverlap = min(b.maxX, label.maxX + 0.3) - max(b.minX, label.minX - 0.05)
            return b.maxY <= label.midY && horizontalOverlap > 0 && label.minY - b.maxY < 3 * label.height
        }
        return below.max(by: { lines[$0].box.maxY < lines[$1].box.maxY })
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
