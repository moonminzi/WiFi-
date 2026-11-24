#!/usr/bin/env python3
"""NAGO alert — 서버 상태를 1분마다 보고 일이 생기면 폰(ntfy 앱)으로 알린다. 표준 라이브러리만 쓴다.

  alert.py check            서울(컨트롤 서버)에서: 서비스 · 도쿄 서버 · 임시 서버 · 접속 · 트래픽 · 비용 ·
                            디스크/메모리 · Vultr 크레딧 · signer 인증서 만료 · 재부팅 · 아침 요약
  alert.py watch <URL>...   도쿄에서: 서울이 응답하는지(서울이 죽으면 서울은 스스로 알릴 수 없으므로)
  alert.py send <제목> <내용> [우선순위 1-5]
  alert.py test

설정 /etc/nago/alert.json (레포에 넣지 않는다 — 토픽 이름을 아는 사람은 알림을 볼 수 있다):
  {"ntfy": "https://ntfy.sh/<추측 못 할 토픽>",       ← 필수
   "hourly_gb": 20, "budget_usd": 40, "credit_usd": 10, "disk_pct": 85,
   "peer_online": true, "digest_hour": 9, "services": [...]}
상태는 /var/lib/nago-alert/*.json. 같은 일은 한 번만 알리고, 나아지면 "복구"를 한 번 알린다.
알림 내용에는 IP·토큰을 넣지 않는다(ntfy.sh 공용 서버를 거치므로).
"""
import datetime
import glob
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

CONFIG = os.environ.get("NAGO_ALERT", "/etc/nago/alert.json")
CONTROL_JSON = os.environ.get("NAGO_CONTROL", "/etc/nago/control.json")
STATE_DIR = os.environ.get("NAGO_ALERT_STATE", "/var/lib/nago-alert")
CERT_DIR = os.environ.get("SIGN_CERTS", "/etc/nago/sign/certs")
DASH_URL = os.environ.get("NAGO_DASH", "http://127.0.0.1:8080/?format=json&t=")
KST = datetime.timezone(datetime.timedelta(hours=9))
SERVICES = ["strongswan-starter", "wg-quick@wg0", "haproxy", "nago-accel", "nago-dns", "nago-agent",
            "nagoing-proxy", "nago-control", "caddy", "nago-sign", "nago-share"]
DOWN_AFTER = 3          # 이만큼 연속(분) 나빠야 알린다(잠깐 끊긴 건 무시)
PEER_ONLINE_SEC = 180   # 마지막 핸드셰이크가 이 안이면 접속 중
PEER_QUIET_MIN = 30     # 이만큼 안 보이다가 다시 붙어야 "접속" 알림(재연결마다 울리지 않게)
CERT_DAYS = (30, 7, 1, 0)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(tmp, path)


def cfg():
    c = load(CONFIG, {})
    if not c.get("ntfy"):
        raise SystemExit("%s: 'ntfy' is missing" % CONFIG)
    return c


def send(title, message, priority=3, tags=None):
    c = cfg()
    base, topic = c["ntfy"].rstrip("/").rsplit("/", 1)
    body = {"topic": topic, "title": title, "message": message, "priority": int(priority)}
    if tags:
        body["tags"] = tags
    req = urllib.request.Request(base + "/", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    if c.get("ntfy_token"):
        req.add_header("Authorization", "Bearer " + c["ntfy_token"])
    for attempt in range(2):
        try:
            urllib.request.urlopen(req, timeout=15).read()
            log("sent: %s" % title)
            return True
        except Exception as e:
            log("send failed (%d): %r" % (attempt + 1, e))
            time.sleep(3)
    return False


def hb(gb):
    return "%.1fGB" % gb if gb < 1000 else "%.2fTB" % (gb / 1000)


def mins(sec):
    sec = int(sec)
    if sec >= 3600:
        return "%d시간 %d분" % (sec // 3600, sec % 3600 // 60)
    return "%d분" % max(1, sec // 60)


class Edge:
    """나빠짐/나아짐을 한 번씩만 알리는 카운터. state[key] = {"bad": 연속 횟수, "on": 알림 보냄, "since": 시각}"""

    def __init__(self, state, out):
        self.state, self.out = state, out

    def __call__(self, key, bad, down_msg, up_msg, after=DOWN_AFTER, prio=4, tags=None):
        s = self.state.setdefault(key, {"bad": 0, "on": False, "since": None})
        now = time.time()
        if bad:
            s["bad"] += 1
            if s["since"] is None:
                s["since"] = now
            if not s["on"] and s["bad"] >= after:
                s["on"] = True
                self.out.append((down_msg[0], down_msg[1], prio, tags or ["rotating_light"]))
        else:
            if s["on"] and up_msg:
                self.out.append((up_msg[0], up_msg[1] + " (%s 동안)" % mins(now - (s["since"] or now)), 3,
                                 ["white_check_mark"]))
            s.update(bad=0, on=False, since=None)


# MARK: - 서울(check)

def services_state(units):
    r = subprocess.run(["systemctl", "show", "-p", "Id,LoadState,ActiveState", "--", *units],
                       capture_output=True, text=True, timeout=20)
    out, cur = {}, {}
    for line in (r.stdout + "\n").splitlines():
        if not line.strip():
            if cur.get("Id"):
                out[cur["Id"].removesuffix(".service")] = cur
            cur = {}
            continue
        k, _, v = line.partition("=")
        cur[k] = v
    return out


def dash():
    tok = load(CONTROL_JSON, {}).get("token", "")
    with urllib.request.urlopen(DASH_URL + tok, timeout=40) as r:
        return json.loads(r.read())


def vultr_credit():
    key = load(CONTROL_JSON, {}).get("vultr_api_key")
    if not key:
        return None
    req = urllib.request.Request("https://api.vultr.com/v2/account", headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=15) as r:
        a = json.loads(r.read())["account"]
    # balance가 음수면 남은 크레딧. 이번 달 쌓인 요금(pending)을 빼면 실제로 남는 돈
    return -float(a.get("balance") or 0) - float(a.get("pending_charges") or 0)


def cert_expiry():
    """[(이름, 팀, 만료 datetime)] — signer 인증서 프로파일에서"""
    out = []
    for path in sorted(glob.glob(os.path.join(CERT_DIR, "*.json"))):
        try:
            d = load(path, {})
            prof = base64.b64decode(d.get("profile") or "").decode("latin-1")
            exp = re.search(r"<key>ExpirationDate</key>\s*<date>([^<]+)</date>", prof)
            team = re.search(r"<key>TeamName</key>\s*<string>([^<]*)</string>", prof)
            if exp:
                when = datetime.datetime.fromisoformat(exp.group(1).replace("Z", "+00:00"))
                out.append((os.path.basename(path), team.group(1) if team else "?", when))
        except Exception as e:
            log("cert %s: %r" % (path, e))
    return out


def check():
    c = cfg()
    path = os.path.join(STATE_DIR, "check.json")
    st = load(path, {})
    first = not st          # 처음 한 번은 지금 상태를 기록만 한다(이미 접속한 기기마다 알림이 쏟아지지 않게)
    out = []
    edge = Edge(st.setdefault("edge", {}), out)
    now = time.time()
    kst = datetime.datetime.now(KST)

    # 재부팅
    up = float(open("/proc/uptime").read().split()[0])
    if st.get("uptime") is not None and up < st["uptime"]:
        out.append(("🔄 서울 서버가 다시 켜졌어요", "재부팅 후 %s 지남. 서비스 상태를 확인할게요." % mins(up), 4,
                    ["arrows_counterclockwise"]))
    st["uptime"] = up

    # 서비스
    units = c.get("services") or SERVICES
    try:
        svc = services_state(units)
        for u in units:
            s = svc.get(u)
            if not s or s.get("LoadState") != "loaded":
                continue        # 이 서버에 없는 서비스
            bad = s.get("ActiveState") not in ("active", "activating", "reloading")
            edge("svc:" + u, bad, ("⚠️ %s 멈춤" % u, "서울 서버의 %s 서비스가 %s 상태예요." % (u, s.get("ActiveState"))),
                 ("✅ %s 다시 돎" % u, "%s 서비스가 다시 돌아요" % u), after=2)
    except Exception as e:
        log("services: %r" % e)

    # 디스크 · 메모리
    du = shutil.disk_usage("/")
    pct = du.used * 100 / du.total
    lim = float(c.get("disk_pct", 85))
    edge("disk", pct >= lim, ("💽 서울 디스크 %.0f%% 사용" % pct, "남은 공간 %s. share 파일이나 로그를 정리하세요." % hb(du.free / 1e9)),
         ("✅ 디스크 여유 돌아옴", "지금 %.0f%% 사용" % pct), after=1, tags=["warning"])
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1)
        mem[k] = int(v.split()[0])
    avail = mem.get("MemAvailable", 0) * 100 / max(1, mem.get("MemTotal", 1))
    edge("mem", avail < 10, ("🧠 서울 메모리 부족", "남은 메모리 %.0f%%" % avail), ("✅ 메모리 여유 돌아옴", "남은 메모리 %.0f%%" % avail),
         after=5, tags=["warning"])

    # 대시보드(도쿄 · 임시 서버 · 접속 · 트래픽 · 비용)
    d = None
    try:
        d = dash()
        edge("dash", False, None, ("✅ 관리 서버 응답", "대시보드가 다시 응답해요"))
    except Exception as e:
        log("dash: %r" % e)
        edge("dash", True, ("⚠️ 관리 서버 응답 없음", "대시보드(nago-control)가 응답하지 않아요: %s" % str(e)[:120]), None)
    if d:
        nodes = d.get("nodes") or []
        for n in nodes:
            if n.get("onDemand") or n["code"] == "kr":
                continue
            bad = n.get("state") != "running" or n.get("up") is None
            why = "상태 %s" % n.get("state") if n.get("state") != "running" else "SSH·상태 확인이 안 돼요"
            edge("node:" + n["code"], bad, ("🚨 %s 서버 문제" % n["city"], "%s(%s): %s" % (n["city"], n["code"], why)),
                 ("✅ %s 서버 정상" % n["city"], "%s 서버가 다시 정상이에요" % n["city"]), prio=5)
        # 임시 서버 켜짐/꺼짐
        prev = st.get("od", {})
        cur = {n["code"]: {"city": n["city"], "t": prev.get(n["code"], {}).get("t", now)}
               for n in nodes if n.get("onDemand") and n.get("state") in ("running", "pending")}
        for code, x in cur.items():
            if code not in prev:
                out.append(("🌐 %s 임시 서버 켜짐" % x["city"], "누가 %s로 연결해서 서버를 만들었어요. 30분 안 쓰면 자동으로 지워져요." % x["city"],
                            2, ["globe_with_meridians"]))
        for code, x in prev.items():
            if code not in cur:
                out.append(("💤 %s 임시 서버 꺼짐" % x["city"], "%s 동안 켜져 있었어요." % mins(now - x["t"]), 2, ["zzz"]))
        st["od"] = cur
        # 접속(VPN 피어)
        seen = st.setdefault("peer_seen", {})
        city = {n["code"]: n["city"] for n in nodes}
        for p in d.get("peers") or []:
            online = p.get("hsAgo") is not None and p["hsAgo"] < PEER_ONLINE_SEC
            if not online:
                continue
            last = seen.get(p["ip"])
            if c.get("peer_online", True) and (last is None or now - last > PEER_QUIET_MIN * 60):
                who = p.get("name") or "VPN %s" % p["n"]
                out.append(("📶 %s 접속" % who, "%s 서버로 VPN에 붙었어요." % city.get(p.get("node"), p.get("node") or "?"),
                            2, ["signal_strength"]))
            seen[p["ip"]] = now
        # 지난 한 시간 트래픽
        hourly = d.get("hourly") or []
        if len(hourly) >= 2:
            h = hourly[-2]
            key = kst.strftime("%Y%m%d") + h["h"]
            if h["gb"] >= float(c.get("hourly_gb", 20)) and st.get("hourly_alerted") != key:
                st["hourly_alerted"] = key
                out.append(("📈 트래픽 많음", "%s시 한 시간 동안 %s 나갔어요." % (h["h"], hb(h["gb"])), 3, ["chart_with_upwards_trend"]))
        # 이번 달 비용 · 대역폭
        m = d.get("month") or {}
        mkey = kst.strftime("%Y%m")
        if m.get("usd", 0) >= float(c.get("budget_usd", 40)) and st.get("budget_alerted") != mkey:
            st["budget_alerted"] = mkey
            out.append(("💸 이번 달 예상 요금 $%.2f" % m["usd"], "설정한 한도 $%s를 넘었어요(서버 $%.2f + 초과 전송 $%.2f)." % (
                c.get("budget_usd", 40), m.get("fixedUSD", 0), m.get("egressUSD", 0)), 4, ["moneybag"]))
        free = float(m.get("freeGB") or 0)
        if free and m.get("egressGB", 0) >= free * 0.8 and st.get("egress_alerted") != mkey:
            st["egress_alerted"] = mkey
            out.append(("📶 무료 전송량 80%", "이번 달 %s / %s 썼어요. 넘으면 GB당 요금이 붙어요." % (hb(m["egressGB"]), hb(free)),
                        4, ["warning"]))

    # Vultr 크레딧(6시간마다)
    if now - st.get("credit_at", 0) > 6 * 3600:
        st["credit_at"] = now
        try:
            left = vultr_credit()
            if left is not None:
                st["credit"] = left
                low = left < float(c.get("credit_usd", 10))
                day = kst.strftime("%Y%m%d")
                if low and st.get("credit_alerted") != day:
                    st["credit_alerted"] = day
                    out.append(("💳 Vultr 크레딧 $%.2f 남음" % left, "곧 카드로 결제되거나 서버가 멈출 수 있어요. Vultr에서 충전하세요.",
                                4, ["credit_card"]))
        except Exception as e:
            log("vultr credit: %r" % e)

    # signer 인증서 만료(하루 한 번)
    day = kst.strftime("%Y%m%d")
    if st.get("cert_day") != day:
        st["cert_day"] = day
        done = st.setdefault("cert", {})
        for name, team, when in cert_expiry():
            days = (when - datetime.datetime.now(datetime.timezone.utc)).days
            hit = next((t for t in CERT_DAYS if days <= t), None)
            if hit is not None and done.get(name) != hit:
                done[name] = hit
                msg = "이미 만료됐어요" if days < 0 else "%d일 남았어요" % days
                out.append(("📜 서명 인증서 %s: %s" % (team, msg), "만료 %s. 새 인증서를 받아 signer에 넣어야 해요." % when.astimezone(KST).strftime("%Y-%m-%d"),
                            4 if days <= 7 else 3, ["scroll"]))

    # 아침 요약
    if kst.hour == int(c.get("digest_hour", 9)) and st.get("digest_day") != day:
        st["digest_day"] = day
        lines = []
        if d:
            m = d.get("month") or {}
            lines.append("이번 달 예상 $%.2f · 전송 %s / %s" % (m.get("usd", 0), hb(m.get("egressGB", 0)), hb(m.get("freeGB", 0))))
            ok = [n["city"] for n in d.get("nodes", []) if not n.get("onDemand") and n.get("state") == "running"]
            lines.append("서버: " + (", ".join(ok) or "없음"))
        day_peers = sum(1 for t in st.get("peer_seen", {}).values() if now - t < 86400)
        lines.append("어제부터 접속한 기기 %d대" % day_peers)
        lines.append("디스크 %.0f%% · 메모리 여유 %.0f%%" % (pct, avail))
        if st.get("credit") is not None:
            lines.append("Vultr 크레딧 $%.2f" % st["credit"])
        out.append(("☀️ NAGO 아침 요약", "\n".join(lines), 2, ["sunny"]))

    # 오래된 접속 기록 정리
    st["peer_seen"] = {k: v for k, v in st.get("peer_seen", {}).items() if now - v < 7 * 86400}
    save(path, st)
    if first:
        log("first run: recorded state, %d notices skipped" % len(out))
        return
    for title, msg, prio, tags in out:
        send(title, msg, prio, tags)


# MARK: - 도쿄(watch)

def watch(urls):
    path = os.path.join(STATE_DIR, "watch.json")
    st = load(path, {})
    out = []
    edge = Edge(st, out)
    for url in urls:
        err = None
        try:
            with urllib.request.urlopen(url, timeout=12) as r:
                if r.status >= 500:
                    err = "http %d" % r.status
        except Exception as e:
            err = str(e)[:120]
        edge("url:" + url, err is not None,
             ("🚨 서울 서버 응답 없음", "도쿄에서 서울 관리 서버에 %d분째 닿지 않아요(%s). VPN·대시보드·signer가 안 될 수 있어요." % (DOWN_AFTER, err)),
             ("✅ 서울 서버 응답", "도쿄에서 서울 관리 서버에 다시 닿아요"), prio=5)
    save(path, st)
    for title, msg, prio, tags in out:
        send(title, msg, prio, tags)


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)
    if a[0] == "check":
        check()
    elif a[0] == "watch":
        watch(a[1:] or ["https://141.164.54.197:8443/healthz"])
    elif a[0] == "send" and len(a) >= 3:
        sys.exit(0 if send(a[1], a[2], int(a[3]) if len(a) > 3 else 3) else 1)
    elif a[0] == "test":
        sys.exit(0 if send("🔔 NAGO 알림 테스트", "이 알림이 보이면 연결 완료예요. (%s)" % os.uname().nodename, 3, ["bell"]) else 1)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
