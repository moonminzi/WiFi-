#!/usr/bin/env python3
"""광고 차단 목록(AdBlock Plus 문법: EasyList · List-KR)을 Safari 콘텐츠 차단 규칙(JSON)으로 바꾼다.

    python3 convert.py out.json list1.txt list2.txt ...

- 주소 규칙(||ads.example.com^ · /banner/ads.*$image,third-party · $domain=)은 url-filter 정규식으로
- 요소 숨기기(##.banner · example.com##div.ad)는 css-display-none으로 — 사이트 자기 도메인의 배너·빈칸도 지운다
- 예외(@@ · #@#)는 Safari 방식(ignore-previous-rules · unless-domain)으로. 순서가 중요해서 아래 순서로 쓴다:
  일반 숨기기 → $generichide 예외 → 주소 차단 → 사이트별 숨기기 → 주소 예외 → 사이트 통째 예외($document · $elemhide)
- Safari가 못 하는 것(정규식 규칙, redirect·csp·removeparam, :has-text 같은 확장 문법, 스크립틀릿)은 건너뛴다.
  Safari는 규칙 하나라도 컴파일이 안 되면 목록 전체를 버리므로, 애매하면 넣지 않는다.
  (CI에서 validate.swift가 macOS WebKit으로 실제 컴파일해 보고 안 되는 규칙을 한 번 더 걸러 낸다)
"""
import json
import re
import sys

MAX_RULES = 145000          # Safari 한 차단기 한도(150,000) 아래로
GENERIC_GROUP = 40          # 일반 숨기기 선택자를 이만큼씩 한 규칙으로(규칙 수를 줄인다)
SPECIFIC_GROUP = 20

TYPES = {
    "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
    "font": "font", "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch",
    "subdocument": "document", "frame": "document", "popup": "popup", "ping": "ping",
    "websocket": "websocket", "other": "other", "object": "other",
}
ALL_TYPES = ["script", "image", "style-sheet", "font", "media", "fetch", "document", "popup", "ping",
             "websocket", "other"]
IGNORED_OPTS = {"important", "match-case", "~match-case", "~important"}
PAGE_EXCEPTIONS = {"document", "doc", "elemhide", "ehide", "content", "urlblock", "all"}
GENERICHIDE = {"generichide", "ghide"}
BAD_PSEUDO = re.compile(
    r":(-abp-|has-text|contains|xpath|upward|matches-css|matches-attr|matches-path|matches-property|"
    r"matches-media|min-text-length|watch-attr|style\(|remove|others|if\(|if-not|nth-ancestor|"
    r"shadow|remove-attr|remove-class|properties|is-empty-cart)", re.I)
DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def domain_ok(d):
    try:
        d = d.encode("idna").decode("ascii") if not d.isascii() else d
    except UnicodeError:
        return None
    d = d.lower().strip(".")
    return d if DOMAIN_RE.match(d) else None


def split_domains(text, sep):
    """'a.com,~b.a.com' → (['*a.com'], ['*b.a.com']). 정규식·와일드카드(example.*) 도메인이 있으면 None"""
    inc, exc = [], []
    for raw in filter(None, (x.strip() for x in text.split(sep))):
        neg = raw.startswith("~")
        raw = raw[1:] if neg else raw
        if raw.startswith("/") or "*" in raw:
            return None
        d = domain_ok(raw)
        if not d:
            return None
        (exc if neg else inc).append("*" + d)
    return inc, exc


def selector_ok(sel):
    if not sel or len(sel) > 1000 or not sel.isascii():
        return False
    if BAD_PSEUDO.search(sel) or "{" in sel or "}" in sel or sel.startswith(("+js", "^", "%", "$")):
        return False
    # 괄호·대괄호·따옴표 짝
    depth = {"(": 0, "[": 0}
    quote = None
    for ch in sel:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "([":
            depth[ch] += 1
        elif ch == ")":
            depth["("] -= 1
        elif ch == "]":
            depth["["] -= 1
        if depth["("] < 0 or depth["["] < 0:
            return False
    return quote is None and depth["("] == 0 and depth["["] == 0


SPECIAL = set(".+?{}()[]\\$")


def pattern_regex(p):
    """ABP 주소 패턴 → Safari url-filter 정규식(점·별·물음표·더하기·[]·()·^·$만 쓴다). 못 바꾸면 None"""
    if not p.isascii() or (p.startswith("/") and p.endswith("/") and len(p) > 1):
        return None
    out = ""
    if p.startswith("||"):
        out, p = "^[^:]+:(//)?([^/]+\\.)?", p[2:]
        if not p or p[0] in "*^/":
            return None
    elif p.startswith("|"):
        out, p = "^", p[1:]
    end = p.endswith("|")
    if end:
        p = p[:-1]
    if "|" in p:
        return None
    for ch in p:
        if ch == "*":
            out += ".*"
        elif ch == "^":
            out += "[^a-zA-Z0-9_.%-]"
        elif ch in SPECIAL:
            out += "\\" + ch
        else:
            out += ch
    if end:
        out += "$"
    while out.startswith(".*"):
        out = out[2:]
    return out or ".*"


def network(line):
    """주소 규칙 하나 → (종류, 규칙) 또는 None. 종류: block | allow | page | ghide"""
    allow = line.startswith("@@")
    body = line[2:] if allow else line
    opts = []
    m = re.search(r"\$(?!/)([^$]*)$", body)
    if m and not (body.startswith("/") and body.rstrip().endswith("/")):
        body, opts = body[:m.start()], [o.strip() for o in m.group(1).split(",") if o.strip()]
    trig = {}
    types, neg_types = [], []
    page = ghide = False
    for o in opts:
        key, _, val = o.partition("=")
        k = key.lower()
        if k in IGNORED_OPTS:
            continue
        if k in ("third-party", "3p", "~first-party", "~1p"):
            trig["load-type"] = ["third-party"]
        elif k in ("~third-party", "~3p", "first-party", "1p"):
            trig["load-type"] = ["first-party"]
        elif k == "domain" and val:
            doms = split_domains(val, "|")
            if doms is None:
                return None
            inc, exc = doms
            if inc:
                trig["if-domain"] = inc
            elif exc:
                trig["unless-domain"] = exc
        elif k in TYPES:
            types.append(TYPES[k])
        elif k.startswith("~") and k[1:] in TYPES:
            neg_types.append(TYPES[k[1:]])
        elif allow and k in PAGE_EXCEPTIONS:
            page = True
        elif allow and k in GENERICHIDE:
            ghide = True
        else:
            return None        # redirect·csp·removeparam 같은 건 Safari로 못 한다
    if page or ghide:
        # 사이트 통째 예외는 ||도메인^ 꼴만(그 사이트 안의 모든 걸 푼다)
        mm = re.match(r"^\|\|([^/^*|]+)\^?\|?$", body)
        d = domain_ok(mm.group(1)) if mm else None
        if not d:
            return None
        return ("ghide" if ghide and not page else "page"), [{
            "trigger": {"url-filter": ".*", "if-domain": ["*" + d]}, "action": {"type": "ignore-previous-rules"}}]
    if not body or body in ("*", "|", "||"):
        return None
    rx = pattern_regex(body)
    if rx is None or len(rx) > 500:
        return None
    trig["url-filter"] = rx
    if types:
        trig["resource-type"] = sorted(set(types))
    elif neg_types:
        trig["resource-type"] = [t for t in ALL_TYPES if t not in neg_types]
    if trig.get("resource-type") == []:
        return None
    order = ["url-filter", "resource-type", "load-type", "if-domain", "unless-domain"]
    action = {"type": "ignore-previous-rules" if allow else "block"}
    pure_domain = re.match(r"^\|\|[^/*^|]+\^?$", body) is not None
    if allow or "resource-type" in trig or pure_domain:
        # 광고 도메인 통째(||ads.com^)는 그 주소로 가는 것도 막아도 된다(DNS 차단과 같음)
        return ("allow" if allow else "block"), [{"trigger": {k: trig[k] for k in order if k in trig}, "action": action}]
    # 종류가 없는 경로 규칙: AdBlock처럼 페이지 이동(주 문서)은 막지 않는다 — 문서 말고 전부 + 남의 사이트 iframe만
    a = dict(trig, **{"resource-type": [t for t in ALL_TYPES if t != "document"]})
    rules = [{"trigger": {k: a[k] for k in order if k in a}, "action": action}]
    if trig.get("load-type") != ["first-party"]:
        b = dict(trig, **{"resource-type": ["document"], "load-type": ["third-party"]})
        rules.append({"trigger": {k: b[k] for k in order if k in b}, "action": action})
    return "block", rules


def convert(lines):
    generic, specific = [], {}            # 선택자 / (if, unless) → [선택자]
    hide_exc = {}                          # 선택자 → 예외 도메인(#@#)
    blocks, allows, pages, ghides = [], [], [], []
    seen = set()
    skipped = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("!", "[", "#!")) or line in seen:
            continue
        seen.add(line)
        m = re.search(r"#@?#|#[@]?[?$%]#|\$@?\$", line)
        if m:
            sep = m.group(0)
            dom, sel = line[:m.start()], line[m.end():].strip()
            if sep not in ("##", "#@#") or not selector_ok(sel):
                skipped += 1
                continue
            doms = split_domains(dom, ",") if dom else ([], [])
            if doms is None:
                skipped += 1
                continue
            inc, exc = doms
            if sep == "#@#":
                if inc:
                    hide_exc.setdefault(sel, set()).update(inc)
                continue
            if inc:
                specific.setdefault((tuple(sorted(inc)), ()), []).append(sel)
            elif exc:
                specific.setdefault(((), tuple(sorted(exc))), []).append(sel)
            else:
                generic.append(sel)
            continue
        r = network(line)
        if r is None:
            skipped += 1
            continue
        kind, rule = r
        {"block": blocks, "allow": allows, "page": pages, "ghide": ghides}[kind].extend(rule)

    def css(selectors, inc=(), exc=()):
        trig = {"url-filter": ".*"}
        if inc:
            trig["if-domain"] = list(inc)
        if exc:
            trig["unless-domain"] = list(exc)
        return {"trigger": trig, "action": {"type": "css-display-none", "selector": ", ".join(selectors)}}

    generic_rules, plain = [], []
    for sel in dict.fromkeys(generic):
        if sel in hide_exc:     # 어떤 사이트에선 숨기면 안 되는 일반 선택자 → 그 사이트만 빼고 따로
            generic_rules.append(css([sel], exc=sorted(hide_exc[sel])[:200]))
        else:
            plain.append(sel)
    for i in range(0, len(plain), GENERIC_GROUP):
        generic_rules.append(css(plain[i:i + GENERIC_GROUP]))
    specific_rules = []
    for (inc, exc), sels in specific.items():
        sels = [s for s in dict.fromkeys(sels) if not (set(inc) & hide_exc.get(s, set()))]
        for i in range(0, len(sels), SPECIFIC_GROUP):
            specific_rules.append(css(sels[i:i + SPECIFIC_GROUP], inc, exc))

    def uniq(rules):
        out, keys = [], set()
        for r in rules:
            k = json.dumps(r, sort_keys=True)
            if k not in keys:
                keys.add(k)
                out.append(r)
        return out

    parts = [uniq(generic_rules), uniq(ghides), uniq(blocks), uniq(specific_rules), uniq(allows), uniq(pages)]
    total = sum(len(p) for p in parts)
    if total > MAX_RULES:       # 넘치면 주소 차단부터 줄인다(DNS 차단이 도메인은 이미 막는다)
        cut = total - MAX_RULES
        parts[2] = parts[2][:max(0, len(parts[2]) - cut)]
    rules = [r for p in parts for r in p]
    stats = {"generic_css": len(parts[0]), "generichide": len(parts[1]), "block": len(parts[2]),
             "site_css": len(parts[3]), "allow": len(parts[4]), "site_allow": len(parts[5]),
             "selectors": len(generic) + sum(len(v) for v in specific.values()), "skipped": skipped,
             "rules": len(rules)}
    return rules, stats


def main():
    out, files = sys.argv[1], sys.argv[2:]
    lines = []
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            lines += fh.read().splitlines()
    rules, stats = convert(lines)
    with open(out, "w") as fh:
        json.dump(rules, fh, separators=(",", ":"))
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
