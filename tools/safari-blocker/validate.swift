// Safari 콘텐츠 차단 규칙(JSON)을 macOS WebKit으로 실제 컴파일해 본다. iOS Safari는 규칙 하나라도 컴파일이
// 안 되면 목록 전체를 버리므로, 안 되는 규칙을 반씩 나눠 찾아 빼고 같은 파일에 다시 쓴다(CI에서 실행).
//   swift validate.swift blockerList.json
import Foundation
import WebKit

let path = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
var rules = try! JSONSerialization.jsonObject(with: data) as! [Any]
let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("nago-cb-\(getpid())")
try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
let store = WKContentRuleListStore(url: storeDir)!
var counter = 0

func compiles(_ part: [Any]) -> (Bool, String) {
    let json = String(data: try! JSONSerialization.data(withJSONObject: part), encoding: .utf8)!
    var done = false, ok = false, message = ""
    counter += 1
    store.compileContentRuleList(forIdentifier: "nago\(counter)", encodedContentRuleList: json) { list, error in
        ok = list != nil
        message = error.map { "\($0)" } ?? ""
        done = true
    }
    while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    store.removeContentRuleList(forIdentifier: "nago\(counter)") { _ in }
    return (ok, message)
}

var dropped = 0
func clean(_ part: [Any]) -> [Any] {
    if compiles(part).0 { return part }
    if part.count == 1 {
        dropped += 1
        if dropped > 3000 {   // 이만큼 많으면 변환기 쪽 문제다 — 고치고 다시
            print("error: more than 3000 rules fail to compile, fix convert.py")
            exit(1)
        }
        if dropped <= 20 {
            let text = String(data: try! JSONSerialization.data(withJSONObject: part[0]), encoding: .utf8)!
            print("drop: \(text.prefix(200))")
        }
        return []
    }
    let mid = part.count / 2
    return clean(Array(part[..<mid])) + clean(Array(part[mid...]))
}

let started = Date()
let (allOK, firstError) = compiles(rules)
if allOK {
    print("ok: \(rules.count) rules compile (\(Int(Date().timeIntervalSince(started)))s)")
    exit(0)
}
print("whole list failed: \(firstError) — searching bad rules")
var kept: [Any] = []
let chunk = 2000
var i = 0
while i < rules.count {
    kept += clean(Array(rules[i..<min(i + chunk, rules.count)]))
    i += chunk
}
// 따로따로는 되는데 합치면 안 되는 경우(한도 등)에 대비해 마지막으로 한 번 더
guard compiles(kept).0 else {
    print("error: cleaned list still does not compile")
    exit(1)
}
let out = try! JSONSerialization.data(withJSONObject: kept)
try! out.write(to: URL(fileURLWithPath: path))
print("ok: kept \(kept.count), dropped \(dropped) rules (\(Int(Date().timeIntervalSince(started)))s)")
