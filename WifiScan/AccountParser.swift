import Foundation

struct AccountCandidate: Identifiable {
    let id = UUID()   // 번호를 고쳐도 화면에서 같은 항목으로 유지되도록 고정 ID
    var bank: String?
    var number: String
    var holder: String?

    var digits: String { number.filter(\.isNumber) }
}

/// 단톡방 캡처나 공지 사진에서 "은행 + 계좌번호(+ 예금주)"를 찾는다.
enum AccountParser {
    private struct Bank {
        let name: String
        /// 이것만 있어도 은행으로 확신할 수 있는 이름. 바로 윗줄·아랫줄에 있어도 짝지어 준다.
        let strong: [String]
        /// "우리", "하나"처럼 일반 단어와 겹치는 이름. 계좌번호와 같은 줄에 있을 때만 쓴다.
        let weak: [String]
    }

    private static let banks: [Bank] = [
        Bank(name: "KB국민", strong: ["KB국민", "국민은행", "KB은행"], weak: ["국민", "KB"]),
        Bank(name: "신한", strong: ["신한은행"], weak: ["신한"]),
        Bank(name: "우리", strong: ["우리은행"], weak: ["우리"]),
        Bank(name: "하나", strong: ["하나은행", "KEB하나"], weak: ["하나"]),
        Bank(name: "NH농협", strong: ["NH농협", "농협은행", "지역농협", "단위농협"], weak: ["농협", "NH"]),
        Bank(name: "IBK기업", strong: ["IBK기업", "기업은행", "IBK"], weak: ["기업"]),
        Bank(name: "카카오뱅크", strong: ["카카오뱅크", "카뱅", "kakaobank"], weak: ["카카오"]),
        Bank(name: "토스뱅크", strong: ["토스뱅크"], weak: ["토스"]),
        Bank(name: "케이뱅크", strong: ["케이뱅크", "K뱅크", "Kbank"], weak: []),
        Bank(name: "SC제일", strong: ["SC제일", "제일은행", "SC은행"], weak: ["SC"]),
        Bank(name: "씨티", strong: ["씨티은행", "한국씨티", "시티은행"], weak: ["씨티", "citi"]),
        Bank(name: "새마을금고", strong: ["새마을금고", "MG새마을"], weak: ["새마을", "MG"]),
        Bank(name: "신협", strong: ["신협"], weak: []),
        Bank(name: "우체국", strong: ["우체국"], weak: []),
        Bank(name: "수협", strong: ["수협"], weak: []),
        Bank(name: "부산", strong: ["부산은행", "BNK부산"], weak: ["부산"]),
        Bank(name: "경남", strong: ["경남은행", "BNK경남"], weak: ["경남"]),
        Bank(name: "iM뱅크", strong: ["iM뱅크", "아이엠뱅크", "대구은행", "DGB"], weak: ["대구"]),
        Bank(name: "광주", strong: ["광주은행"], weak: ["광주"]),
        Bank(name: "전북", strong: ["전북은행"], weak: ["전북"]),
        Bank(name: "제주", strong: ["제주은행"], weak: ["제주"]),
        Bank(name: "KDB산업", strong: ["산업은행", "KDB"], weak: ["산업"]),
    ]

    static let bankNames: [String] = banks.map(\.name)

    /// "OK저축은행", "키움증권"처럼 목록에 없는 금융사 이름
    private static let genericBankRegex = try! NSRegularExpression(
        pattern: #"[가-힣A-Za-z]{1,8}(?:저축은행|증권)"#)

    private static let hyphenNumberRegex = try! NSRegularExpression(
        pattern: #"(?<![\d-])\d{2,7}(?:-\d{1,8}){1,4}(?![\d-])"#)
    private static let plainNumberRegex = try! NSRegularExpression(
        pattern: #"(?<![\d-])\d{10,16}(?![\d-])"#)
    /// "123 456 789012"처럼 띄어 쓴 번호. 날짜·시간과 헷갈리기 쉬워 은행 이름이 같은 줄에 있을 때만 본다.
    private static let spacedNumberRegex = try! NSRegularExpression(
        pattern: #"(?<![\d-])\d{2,7}(?: \d{1,8}){1,4}(?![\d-])"#)

    private static let holderLabelRegex = try! NSRegularExpression(
        pattern: #"예금주\s*[:：]?\s*([가-힣]{2,5})"#)
    private static let holderAfterNumberRegex = try! NSRegularExpression(
        pattern: #"^[\s,/|]*\(?\s*([가-힣]{2,4}?)(?:님|입니다|이에요|예요)?\s*\)?(?![가-힣])"#)
    /// 이 단어가 들어 있으면 이름이 아니다
    private static let notNameParts = [
        "입금", "계좌", "은행", "으로", "에게", "까지", "부탁", "회비", "송금", "이체", "예금주", "보내", "주세요",
        "입니다", "이에요", "예요", "감사", "확인", "금액", "만원", "참가비", "환불", "정산", "모임", "총무", "담당",
        "번호", "드려", "합니다", "해요", "뱅크", "금고",
    ]

    // MARK: - 공개 API

    static func parse(_ text: String) -> [AccountCandidate] {
        let lines = normalize(text).components(separatedBy: .newlines)
        var results: [AccountCandidate] = []
        var seen = Set<String>()

        for (index, line) in lines.enumerated() {
            let sameLineBank = bestBank(in: line, allowWeak: true)
            for match in numberMatches(in: line, includeSpaced: sameLineBank != nil) {
                let number = match.text.replacingOccurrences(of: " ", with: "-")
                let digits = number.filter(\.isNumber)
                guard (10...16).contains(digits.count), !seen.contains(digits) else { continue }
                if isAmount(line, after: match.range) { continue }

                let bank = sameLineBank?.name
                    ?? (index > 0 ? bestBank(in: lines[index - 1], allowWeak: false)?.name : nil)
                    ?? (index + 1 < lines.count ? bestBank(in: lines[index + 1], allowWeak: false)?.name : nil)

                if bank == nil, looksLikeNonAccount(number) { continue }
                if sameLineBank == nil, isPhoneNumber(digits) { continue }

                seen.insert(digits)
                results.append(AccountCandidate(
                    bank: bank,
                    number: number,
                    holder: holder(in: lines, at: index, after: match.range)))
            }
        }
        return results
    }

    /// Vision의 줄 단위 결과를 위에서 아래, 같은 행은 왼쪽에서 오른쪽 순서로 이어 붙인다.
    static func joinRows(_ lines: [OCRLine]) -> String {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let last = rows.last?.last,
               min(last.box.maxY, line.box.maxY) - max(last.box.minY, line.box.minY)
                > 0.5 * min(last.box.height, line.box.height) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    // MARK: - 은행 이름

    private struct BankHit {
        let name: String
        let strong: Bool
        let length: Int
    }

    private static func bestBank(in line: String, allowWeak: Bool) -> BankHit? {
        var hits: [BankHit] = []
        for bank in banks {
            for alias in bank.strong where containsAlias(alias, in: line) {
                hits.append(BankHit(name: bank.name, strong: true, length: alias.count))
            }
            if allowWeak {
                for alias in bank.weak where containsAlias(alias, in: line) {
                    hits.append(BankHit(name: bank.name, strong: false, length: alias.count))
                }
            }
        }
        let ns = line as NSString
        if let m = genericBankRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            hits.append(BankHit(name: ns.substring(with: m.range), strong: true, length: m.range.length))
        }
        // 확실한 이름 우선, 그다음 더 긴 이름("카카오" < "카카오뱅크")
        return hits.max { ($0.strong ? 1 : 0, $0.length) < ($1.strong ? 1 : 0, $1.length) }
    }

    /// 영문 약어(KB, NH, SC…)는 다른 단어 안에 들어 있으면 안 된다.
    private static func containsAlias(_ alias: String, in line: String) -> Bool {
        if alias.allSatisfy({ $0.isASCII && $0.isLetter }) {
            let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: alias) + "(?![A-Za-z])"
            return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return line.range(of: alias, options: .caseInsensitive) != nil
    }

    // MARK: - 번호

    private struct NumberMatch {
        let text: String
        let range: NSRange
    }

    private static func numberMatches(in line: String, includeSpaced: Bool) -> [NumberMatch] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var regexes = [hyphenNumberRegex, plainNumberRegex]
        if includeSpaced { regexes.append(spacedNumberRegex) }

        var matches: [NumberMatch] = []
        for regex in regexes {
            for m in regex.matches(in: line, range: full)
            where !matches.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                matches.append(NumberMatch(text: ns.substring(with: m.range), range: m.range))
            }
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }

    private static func isAmount(_ line: String, after range: NSRange) -> Bool {
        let rest = (line as NSString).substring(from: NSMaxRange(range))
        return rest.trimmingCharacters(in: .whitespaces).hasPrefix("원")
    }

    private static func isPhoneNumber(_ digits: String) -> Bool {
        digits.range(of: #"^01[016789]\d{7,8}$"#, options: .regularExpression) != nil
    }

    /// 은행 이름이 없을 때 걸러낼 것들: 주민번호, 카드번호, 사업자번호, 전화번호
    private static func looksLikeNonAccount(_ number: String) -> Bool {
        let patterns = [
            #"^\d{6}-[1-4]\d{6}$"#,
            #"^\d{4}-\d{4}-\d{4}-\d{4}$"#,
            #"^\d{3}-\d{2}-\d{5}$"#,
            #"^0\d{1,2}-\d{3,4}-\d{4}$"#,
        ]
        return patterns.contains { number.range(of: $0, options: .regularExpression) != nil }
            || isPhoneNumber(number.filter(\.isNumber))
    }

    // MARK: - 예금주

    private static func holder(in lines: [String], at index: Int, after range: NSRange) -> String? {
        let line = lines[index]
        let ns = line as NSString
        let rest = ns.substring(from: NSMaxRange(range))
        if let name = firstCapture(holderAfterNumberRegex, in: rest), isPlausibleName(name) {
            return name
        }
        for i in [index, index + 1] where i < lines.count {
            if let name = firstCapture(holderLabelRegex, in: lines[i]), isPlausibleName(name) {
                return name
            }
        }
        return nil
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        !notNameParts.contains { name.contains($0) }
            && !banks.contains { $0.weak.contains(name) || $0.strong.contains(name) }
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func normalize(_ text: String) -> String {
        // OCR이 하이픈을 대시나 물결로 읽는 경우가 많다
        text.replacingOccurrences(of: #"[‐‑‒–—―~〜]"#, with: "-", options: .regularExpression)
    }
}
