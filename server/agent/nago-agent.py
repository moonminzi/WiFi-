#!/usr/bin/env python3
"""nago-agent: VPN 안쪽에서만 닿는 작은 HTTP 서버(10.53.53.53:8053). 표준 라이브러리만 쓴다.

앱(연결된 폰)이 터널 안에서 묻는다. 누가 묻는지는 요청의 출발 주소(터널 주소: wg 10.9.0.x · IKEv2 10.10.10.x)로 안다 —
그 주소는 WireGuard 키나 IKEv2 비밀번호로 이미 인증된 것이라 따로 로그인이 없고, 남의 기록은 볼 수 없다.

1) 광고 차단 통계 · 실시간 도메인 (adblock DNS를 쓰는 사람만)
   dnsmasq가 /run/nago-dns/queries.log(tmpfs, 디스크에 안 남음)에 쓰는 질의 기록을 읽어 사람별로 메모리에만 센다:
   오늘(KST) 질의·차단 수, 많이 막힌 도메인, 최근 300개 도메인 흐름. 읽은 기록은 지운다(파일이 계속 비워짐).
     GET  /v1/me            → 오늘 숫자 · 많이 막힌 도메인 · 지금 출구 · 집 출구 목록
     GET  /v1/feed?after=N  → N 다음부터 도메인 흐름

2) 친구 집 출구(home exit) — 서울(kr)처럼 늘 켜 둔 서버에서
   친구 리눅스 PC(nago-home.sh)가 이 서버의 wg 피어로 붙어 "출구"로 자기를 알린다. 서버는 그 피어와 터널 안쪽
   IP-in-IP(nagoh<n>)를 만들고, 그 출구를 고른 사람의 트래픽만 정책 라우팅으로 거기 넘긴다(친구 집이 NAT해서 내보냄).
   새 포트를 열지 않는다(이미 열린 wg 안에서 IP-in-IP). 출구가 끊기면(핸드셰이크 3분 넘게 없음) 서버로 되돌아가고,
   다시 붙으면 저절로 다시 넘긴다. 고르는 건 wg(고정 주소)만 — IKEv2 주소는 연결마다 바뀌어 남에게 넘어갈 수 있다.
     POST /v1/exit {"via": "server" | "<집 id>"}
     POST /v1/home {"name": "minji-pc"}   (집 노드가 자기를 출구로 알림) · {"off": true}  (내림)

상태(집 목록 · 누가 어느 출구)는 /var/lib/nago-agent/state.json — 도메인 기록은 저장하지 않는다.
"""
import collections
import http.server
import ipaddress
import json
import os
import re
import socketserver
import subprocess
import threading
import time
import urllib.parse

LISTEN = ("10.53.53.53", 8053)
LOG = "/run/nago-dns/queries.log"
STATE = "/var/lib/nago-agent/state.json"
WG_NET = ipaddress.ip_network("10.9.0.0/24")
WG_SELF = "10.9.0.1"
KST = 9 * 3600
FEED = 300
TOP_KEEP = 500
HOME_STALE = 180          # 핸드셰이크가 이보다 오래 없으면 집 출구가 끊긴 것
RULE_PRIO = 5000
TABLE_BASE = 2000

lock = threading.Lock()          # 통계·상태
rec_lock = threading.Lock()      # 터널·규칙 바꾸기(HTTP 요청과 15초 루프가 겹치지 않게)


# ------------------------------------------------------------------ DNS 통계

class Client:
    __slots__ = ("day", "queries", "blocked", "top", "sites", "feed", "recent", "last")

    def __init__(self, day):
        self.day = day
        self.queries = 0
        self.blocked = 0
        self.top = collections.Counter()      # 막힌 도메인
        self.sites = collections.Counter()    # 열린 도메인(앞 두 마디)
        self.feed = collections.deque(maxlen=FEED)
        self.recent = {}                      # 도메인 → 마지막 시각(A·AAAA·HTTPS 세 번 묻는 걸 한 번으로)
        self.last = time.time()


clients = {}
pending = {}            # dnsmasq 질의 번호 → 흐름 항목(뒤에 오는 config 줄로 '막힘' 표시)
seq = 0

LINE = re.compile(r"dnsmasq\[\d+\]: (\d+) ([0-9a-fA-F.:]+)/\d+ (query\[[A-Z0-9]+\]|config|cached|reply|forwarded) (\S+)(?: (?:is|from|to) (\S+))?")
BLOCKED = ("NXDOMAIN", "NODATA", "NODATA-IPv4", "NODATA-IPv6", "0.0.0.0", "::")


def kst_day(now):
    return time.strftime("%Y-%m-%d", time.gmtime(now + KST))


def site(domain):
    parts = domain.split(".")
    return ".".join(parts[-3:]) if len(parts) > 2 and len(parts[-2]) <= 3 and len(parts[-1]) == 2 else ".".join(parts[-2:])


def trim(counter):
    if len(counter) > TOP_KEEP * 4:
        keep = counter.most_common(TOP_KEEP)
        counter.clear()
        counter.update(dict(keep))


def handle_line(line):
    global seq
    m = LINE.search(line)
    if not m:
        return
    serial, ip, kind, domain, value = m.groups()
    now = time.time()
    domain = domain.rstrip(".").lower()
    if kind.startswith("query["):
        if kind not in ("query[A]", "query[AAAA]", "query[HTTPS]"):
            return
        c = clients.get(ip)
        day = kst_day(now)
        if c is None or c.day != day:
            c = clients[ip] = Client(day)
        c.last = now
        if now - c.recent.get(domain, 0) < 3:
            pending[serial] = (c, None)        # 같은 도메인을 연달아 물은 것: 숫자는 한 번만
            return
        c.recent[domain] = now
        if len(c.recent) > 2000:
            c.recent = {d: t for d, t in c.recent.items() if now - t < 3}
        c.queries += 1
        seq += 1
        item = {"s": seq, "t": int(now), "d": domain, "b": False}
        c.feed.append(item)
        c.sites[site(domain)] += 1
        trim(c.sites)
        pending[serial] = (c, item)
        if len(pending) > 5000:
            for k in list(pending)[:2500]:
                pending.pop(k, None)
        return
    if kind == "config" and value in BLOCKED:
        c, item = pending.pop(serial, (None, None))
        if c is None or item is None or item["b"]:
            return
        item["b"] = True
        c.blocked += 1
        c.top[domain] += 1
        c.sites[site(domain)] -= 1
        trim(c.top)


def tail():
    """질의 기록을 따라 읽는다. 다 읽으면 파일을 비운다(tmpfs라도 커지지 않게, 기록이 남지 않게)."""
    while True:
        try:
            with open(LOG, "r", errors="replace") as f:
                f.seek(0, os.SEEK_END)
                while True:
                    line = f.readline()
                    if line:
                        with lock:
                            handle_line(line)
                        continue
                    time.sleep(0.25)
                    try:
                        size = os.path.getsize(LOG)
                    except OSError:
                        break
                    if size < f.tell():
                        f.seek(0)
                    elif size > 1 << 20 and f.tell() >= size:
                        os.truncate(LOG, 0)
                        f.seek(0)
        except FileNotFoundError:
            time.sleep(2)
        except Exception:
            time.sleep(2)


def forget_idle():
    now = time.time()
    with lock:
        for ip in [ip for ip, c in clients.items() if now - c.last > 36 * 3600]:
            del clients[ip]


# ------------------------------------------------------------------ 집 출구

state = {"homes": {}, "exits": {}}     # homes: {id: {name, ip, since}} · exits: {client ip: home id}


def load_state():
    global state
    try:
        with open(STATE) as f:
            data = json.load(f)
        state = {"homes": data.get("homes") or {}, "exits": data.get("exits") or {}}
    except (OSError, ValueError):
        pass


def save_state():
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def run(*args, check=False):
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("%s: %s" % (" ".join(args), (r.stderr or r.stdout).strip()[:200]))
    return r


def handshakes():
    """wg0 피어 주소 → 마지막 핸드셰이크(초, 없으면 0)"""
    out = {}
    r = run("wg", "show", "wg0", "dump")
    for line in r.stdout.splitlines()[1:]:
        cols = line.split("\t")
        if len(cols) < 5:
            continue
        for net in cols[3].split(","):
            if net.endswith("/32"):
                out[net[:-3]] = int(cols[4] or 0)
    return out


def home_id(ip):
    return "h%s" % ip.rsplit(".", 1)[1]


def dev_of(ip):
    return "nagoh%s" % ip.rsplit(".", 1)[1]


def table_of(ip):
    return TABLE_BASE + int(ip.rsplit(".", 1)[1])


def tunnel_up(ip):
    """서버 ↔ 집: wg0 안쪽 IP-in-IP. 그 집으로 나갈 사람 트래픽이 탈 라우팅 표도 만든다."""
    dev, table = dev_of(ip), str(table_of(ip))
    if run("ip", "link", "show", dev).returncode != 0:
        run("ip", "tunnel", "add", dev, "mode", "ipip", "local", WG_SELF, "remote", ip, "ttl", "64", check=True)
    run("ip", "link", "set", dev, "mtu", "1400", "up", check=True)
    run("sysctl", "-qw", "net.ipv4.conf.%s.rp_filter=0" % dev)
    run("ip", "route", "replace", "default", "dev", dev, "table", table, check=True)
    run("ip", "route", "replace", str(WG_NET), "dev", "wg0", "table", table)
    for rule in (["FORWARD", "-i", dev, "-j", "ACCEPT"], ["FORWARD", "-o", dev, "-j", "ACCEPT"]):
        if run("iptables", "-C", *rule).returncode != 0:
            run("iptables", "-I", *rule)
    clamp = ["FORWARD", "-o", dev, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--clamp-mss-to-pmtu"]
    if run("iptables", "-t", "mangle", "-C", *clamp).returncode != 0:
        run("iptables", "-t", "mangle", "-A", *clamp)


def tunnel_down(ip):
    dev = dev_of(ip)
    run("ip", "route", "flush", "table", str(table_of(ip)))
    for rule in (["FORWARD", "-i", dev, "-j", "ACCEPT"], ["FORWARD", "-o", dev, "-j", "ACCEPT"]):
        run("iptables", "-D", *rule)
    run("iptables", "-t", "mangle", "-D", "FORWARD", "-o", dev, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN",
        "-j", "TCPMSS", "--clamp-mss-to-pmtu")
    run("ip", "link", "del", dev)


def rules_now():
    """지금 걸린 정책 규칙: 출발 주소 → 표 번호"""
    out = {}
    for line in run("ip", "rule", "show").stdout.splitlines():
        m = re.match(r"%d:\s+from (\S+) lookup (\d+)" % RULE_PRIO, line)
        if m:
            out[m.group(1).split("/")[0]] = int(m.group(2))
    return out


def accel_skip(client, on):
    """TCP 분할 가속(서버의 프록시가 대신 연결)을 빼야 집 IP로 나간다"""
    rule = ["NAGO_ACCEL", "-s", client, "-j", "RETURN"]
    has = run("iptables", "-t", "nat", "-C", *rule).returncode == 0
    if on and not has:
        run("iptables", "-t", "nat", "-I", *rule)
    elif not on and has:
        run("iptables", "-t", "nat", "-D", *rule)


def reconcile():
    """상태 파일대로 터널·규칙을 맞춘다. 끊긴 집으로 가던 사람은 서버로 되돌리고, 다시 붙으면 다시 넘긴다."""
    with rec_lock:
        return _reconcile()


def _reconcile():
    with lock:
        homes = dict(state["homes"])
        exits = dict(state["exits"])
    hs = handshakes()
    now = time.time()
    # 서버 피어 목록에서 지워진 집(대시보드에서 삭제 · 다시 등록해 주소가 바뀜)은 출구에서도 내린다.
    # wg를 못 읽었을 때(hs가 빔) 다 지우지 않게, 읽힌 때만
    if hs:
        gone = [hid for hid, h in homes.items() if h["ip"] not in hs]
        if gone:
            with lock:
                for hid in gone:
                    state["homes"].pop(hid, None)
                    for c in [c for c, x in state["exits"].items() if x == hid]:
                        state["exits"].pop(c)
                save_state()
                exits = dict(state["exits"])
            for hid in gone:
                tunnel_down(homes.pop(hid)["ip"])
    online = {hid: now - hs.get(h["ip"], 0) < HOME_STALE for hid, h in homes.items()}
    for hid, h in homes.items():
        try:
            tunnel_up(h["ip"])
        except RuntimeError:
            online[hid] = False
    want = {c: table_of(homes[hid]["ip"]) for c, hid in exits.items() if hid in homes and online.get(hid)}
    have = rules_now()
    for c, table in have.items():
        if want.get(c) != table:
            run("ip", "rule", "del", "from", "%s/32" % c, "priority", str(RULE_PRIO))
    for c, table in want.items():
        if have.get(c) != table:
            run("ip", "rule", "add", "from", "%s/32" % c, "lookup", str(table), "priority", str(RULE_PRIO))
    for c in set(exits) | set(have):
        accel_skip(c, c in want)
    run("ip", "route", "flush", "cache")
    return online


def reconcile_loop():
    while True:
        try:
            reconcile()
        except Exception:
            pass
        forget_idle()
        time.sleep(15)


def homes_view(online=None):
    hs = handshakes()
    now = time.time()
    out = []
    with lock:
        homes = dict(state["homes"])
    for hid, h in sorted(homes.items(), key=lambda kv: kv[1].get("name", "")):
        ago = now - hs.get(h["ip"], 0) if hs.get(h["ip"]) else None
        out.append({"id": hid, "name": h.get("name", hid),
                    "online": bool(online[hid]) if online and hid in online else (ago is not None and ago < HOME_STALE),
                    "seen": int(ago) if ago is not None else None})
    return out


# ------------------------------------------------------------------ HTTP

def me(ip):
    with lock:
        c = clients.get(ip)
        day = kst_day(time.time())
        dns = None
        if c is not None and c.day == day:
            dns = {"queries": c.queries, "blocked": c.blocked,
                   "top": c.top.most_common(8),
                   "sites": [(d, n) for d, n in c.sites.most_common(8) if n > 0][:5],
                   "last": c.feed[-1]["s"] if c.feed else 0}
        via = state["exits"].get(ip, "server")
    homes = homes_view()
    active = via == "server" or any(h["id"] == via and h["online"] for h in homes)
    return {"ip": ip, "day": day, "dns": dns, "exit": {"via": via, "active": active},
            "homes": homes, "exitAllowed": ipaddress.ip_address(ip) in WG_NET}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "nago-agent"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass   # 접속 기록을 남기지 않는다

    def reply(self, status, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = min(int(self.headers.get("content-length") or 0), 4096)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
            return data if isinstance(data, dict) else {}
        except ValueError:
            return {}

    def do_GET(self):
        ip = self.client_address[0]
        url = urllib.parse.urlparse(self.path)
        if url.path == "/v1/me":
            return self.reply(200, me(ip))
        if url.path == "/v1/feed":
            q = urllib.parse.parse_qs(url.query)
            try:
                after = int((q.get("after") or ["0"])[0])
            except ValueError:
                after = 0
            with lock:
                c = clients.get(ip)
                items = [dict(x) for x in (c.feed if c else []) if x["s"] > after]
                stats = {"queries": c.queries, "blocked": c.blocked} if c else None
            return self.reply(200, {"items": items[-200:], "last": items[-1]["s"] if items else after, "dns": stats})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        ip = self.client_address[0]
        path = urllib.parse.urlparse(self.path).path
        req = self.body()
        if path == "/v1/exit":
            via = str(req.get("via") or "server")
            if ipaddress.ip_address(ip) not in WG_NET:
                return self.reply(400, {"error": "home exit needs wg (ikev2 addresses change every connect)"})
            with lock:
                if via != "server" and via not in state["homes"]:
                    return self.reply(404, {"error": "no such home"})
                if via != "server" and state["homes"][via]["ip"] == ip:
                    return self.reply(400, {"error": "that home is you"})
                if via == "server":
                    state["exits"].pop(ip, None)
                else:
                    state["exits"][ip] = via
                save_state()
            reconcile()
            return self.reply(200, me(ip))
        if path == "/v1/home":
            if ipaddress.ip_address(ip) not in WG_NET or ip == WG_SELF:
                return self.reply(400, {"error": "announce from the home node over wg"})
            hid = home_id(ip)
            with lock:
                if req.get("off"):
                    state["homes"].pop(hid, None)
                    for c in [c for c, h in state["exits"].items() if h == hid]:
                        state["exits"].pop(c)
                    save_state()
                    gone = True
                else:
                    name = "".join(ch for ch in str(req.get("name") or "") if ch.isprintable()).strip()[:24] or hid
                    state["homes"][hid] = {"name": name, "ip": ip, "since": state["homes"].get(hid, {}).get("since") or int(time.time())}
                    save_state()
                    gone = False
            if gone:
                with rec_lock:
                    tunnel_down(ip)
            reconcile()
            return self.reply(200, {"ok": True, "id": hid, "homes": homes_view()})
        self.reply(404, {"error": "not found"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    load_state()
    threading.Thread(target=tail, daemon=True).start()
    threading.Thread(target=reconcile_loop, daemon=True).start()
    while True:
        try:
            Server(LISTEN, Handler).serve_forever()
        except OSError:
            time.sleep(3)    # nago-dns 주소가 아직 없을 때(부팅 직후)


if __name__ == "__main__":
    main()
