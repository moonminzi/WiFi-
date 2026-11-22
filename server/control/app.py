#!/usr/bin/env python3
"""NAGO VPN 컨트롤 서버. 서울 Vultr 서버에서 돌고, AWS 시절 Lambda 두 개(국가 API, 대시보드)를 대신한다.

    GET  /region?r=<code>   + 헤더 x-nago-key → {"region","state","ready","ip","id","wgPub","wgPort"}
    GET  /?t=<TOKEN>                          → 터미널 스타일 HTML (브라우저)
    GET  /?format=json      + 헤더 x-nago-key → JSON (앱)
    POST / {op, ...}        + 헤더 x-nago-key → 피어 관리 add|kick|reset|remove|rename|flags
                                                서버 관리 start|stop|reboot|wake (node)
    GET  /healthz                             → ok

응답 모양은 Lambda 때와 같아서 앱은 주소만 바꾸면 된다.

- 설정: /etc/nago/control.json (NAGO_CONFIG로 바꿀 수 있음). control.example.json 참고
- 상태: /var/lib/nago/ (NAGO_STATE) — wg-peers.json(피어 목록의 기준), wg-servers.json(서버별 wg 공개키)
- 다른 서버에는 SSH(root, ssh_key)로 셸 스크립트를 보낸다. "local": true인 서버(서울 자신)는 바로 실행
- vultr_api_key가 있으면 서버 상태·켜기·끄기·재부팅에 Vultr API를 쓰고, 없으면 SSH만으로 동작한다
- 송신량은 각 서버의 nago-netout 타이머(setup-region.sh)가 5분마다 남기는 기록에서 읽는다

HTTPS는 앞에 둔 Caddy가 맡고, 이 서버는 127.0.0.1에서만 받는다(setup-control.sh).
"""
import base64
import concurrent.futures as cf
import datetime
import hashlib
import hmac
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("NAGO_CONFIG", "/etc/nago/control.json")
STATE_DIR = os.environ.get("NAGO_STATE", "/var/lib/nago")
with open(os.path.join(HERE, "nago-peer.py"), encoding="utf-8") as _fh:
    PEER_ADMIN = _fh.read()

PEER_OPS = ("add", "kick", "reset", "remove", "rename", "flags")
NODE_OPS = ("start", "stop", "reboot", "wake")
WG_PEERS = "wg-peers.json"
WG_SERVERS = "wg-servers.json"
WG_NET = "10.9.0."
WG_PORT = 443          # 앱이 붙는 포트. 서버에서 51820으로 넘겨 준다(잘 안 막히는 포트)
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
KST = datetime.timezone(datetime.timedelta(hours=9))
VULTR_API = "https://api.vultr.com/v2"
# Vultr는 한 달 672시간(28일)까지 시간 단가로 받고 그 뒤로는 월 요금에서 멈춘다.
VULTR_MONTH_HOURS = 672.0

LIVE_TTL = 10       # 서버 상태/SSH 결과 재사용 시간(초)
SYNC_EVERY = 300    # 국가 API가 같은 서버에 피어 동기화를 다시 보내기까지(초)

CFG = {}
NODES = []
_cache = {}
_last_net = {}      # 서버가 잠깐 안 닿아도 마지막 송신량은 보여 준다
_last_sync = {}
_store_lock = threading.Lock()


def configure(cfg):
    """설정을 읽어 전역에 올린다(테스트에서도 부름)."""
    for k in ("token", "key_sha256", "nodes"):
        if not cfg.get(k):
            raise SystemExit("config: '%s' is missing" % k)
    for n in cfg["nodes"]:
        for k in ("code", "city", "addr", "id"):
            if not n.get(k):
                raise SystemExit("config: node %r has no '%s'" % (n.get("code"), k))
    if not any(n["code"] == "kr" for n in cfg["nodes"]):
        raise SystemExit("config: a node with code 'kr' is required (peer admin runs there)")
    CFG.clear()
    CFG.update(cfg)
    NODES[:] = cfg["nodes"]
    _cache.clear()


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def cached(name, ttl, fn):
    hit = _cache.get(name)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    value = fn()
    _cache[name] = (time.time(), value)
    return value


def node_by_code(code):
    return next((n for n in NODES if n["code"] == code), None)


# ---------------------------------------------------------------- 저장소 (SSM 파라미터 대신)

def read_json(name, default):
    try:
        with open(os.path.join(STATE_DIR, name), encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default


def write_json(name, value):
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".nago-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(STATE_DIR, name))


def wg_peers():
    return read_json(WG_PEERS, {"peers": []})["peers"]


def wg_servers():
    return read_json(WG_SERVERS, {})


def remember_wg_pub(code, pub):
    if not pub or not KEY_RE.match(pub):
        return
    with _store_lock:
        servers = wg_servers()
        cur = servers.get(code) or {}
        if cur.get("pub") == pub:
            return
        cur["pub"] = pub
        cur.setdefault("port", 51820)
        servers[code] = cur
        write_json(WG_SERVERS, servers)


# ---------------------------------------------------------------- 서버에서 명령 실행 (SSM 대신 SSH)

class RunResult:
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err

    @property
    def ok(self):
        return self.rc == 0


def run_on(node, script, timeout):
    """node에서 bash 스크립트를 돌린다. 서울(local)은 바로, 나머지는 SSH로."""
    if node.get("local"):
        cmd = ["bash", "-s"]
    else:
        cmd = ["ssh", "-i", CFG.get("ssh_key", "/etc/nago/id_ed25519"),
               "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
               "-o", "UserKnownHostsFile=" + os.path.join(STATE_DIR, "known_hosts"),
               "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "LogLevel=ERROR",
               "%s@%s" % (node.get("ssh_user", "root"), node["addr"]), "bash -s"]
    try:
        r = subprocess.run(cmd, input=script, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return RunResult(124, "", "timed out after %ds" % timeout)
    except OSError as e:
        return RunResult(127, "", str(e))
    return RunResult(r.returncode, r.stdout, r.stderr)


# ---------------------------------------------------------------- Vultr API (EC2 대신)

def vultr_enabled(node):
    return bool(CFG.get("vultr_api_key") and node.get("vultr_id"))


def vultr(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(VULTR_API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + CFG["vultr_api_key"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


def parse_time(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def describe(node):
    """{"state", "ip", "type", "created"} — Vultr API가 없거나 안 되면 설정값(항상 켜져 있다고 봄)."""
    base = {"state": "running", "ip": node["addr"], "type": node.get("plan", "-"), "created": None}
    if not vultr_enabled(node):
        return base
    try:
        i = vultr("GET", "/instances/" + node["vultr_id"])["instance"]
    except Exception as e:
        log("vultr describe %s: %s" % (node["code"], e))
        return base   # API가 잠깐 안 돼도 접속은 막지 않는다
    status, power = i.get("status"), i.get("power_status")
    if status in ("pending", "resizing"):
        state = "pending"
    elif status != "active":
        state = status or "unknown"          # suspended 등
    elif power == "stopped":
        state = "stopped"
    elif i.get("server_status") == "installingbooting":
        state = "pending"
    else:
        state = "running"
    return {"state": state, "ip": i.get("main_ip") or node["addr"], "type": i.get("plan") or base["type"],
            "created": parse_time(i.get("date_created"))}


# ---------------------------------------------------------------- 수집

STATUS_SCRIPT = r"""I=$(cat /run/nago-idle/idle 2>/dev/null || echo -1)
echo "IDLE $I"
echo "UP $(cut -d. -f1 /proc/uptime)"
echo "LOAD $(cut -d' ' -f1 /proc/loadavg)"
echo "IKE $(ipsec status 2>/dev/null | grep -c ESTABLISHED)"
ipsec leases 2>/dev/null | awk '$2=="online"{print "LEASE "$1}'
if command -v wg >/dev/null 2>&1; then
  echo "WGPUB $(wg show wg0 public-key 2>/dev/null)"
  wg show wg0 dump 2>/dev/null | tail -n +2 | sed 's/^/WG /'
fi
echo "NAMES $(tr -d '\n' < /etc/wireguard/nago-names.json 2>/dev/null || echo '{}')"
if [ -f /var/lib/nago/netout ]; then
  MS=$(date -u -d "$(date -u +%Y-%m-01)" +%s); NOW=$(date -u +%s)
  awk -v ms="$MS" -v cut=$((NOW - 8 * 3600)) \
    '$1 >= ms {m += $2} $1 >= cut {h[int($1 / 3600) * 3600] += $2}
     END {printf "NETMONTH %.0f\n", m; for (k in h) printf "NET %d %.0f\n", k, h[k]}' /var/lib/nago/netout
fi
"""


def parse_status(text):
    r = {"idle": None, "up": None, "load": None, "ike": 0, "leases": [], "wg": [], "names": {},
         "wgpub": None, "net_hourly": {}, "net_month": None}
    for line in (text or "").splitlines():
        key, _, val = line.partition(" ")
        val = val.strip()
        try:
            if key == "IDLE":
                n = int(val)
                r["idle"] = n if n >= 0 else None
            elif key == "UP":
                r["up"] = int(val)
            elif key == "LOAD":
                r["load"] = val
            elif key == "IKE":
                r["ike"] = int(val)
            elif key == "LEASE":
                r["leases"].append(val)
            elif key == "WGPUB":
                r["wgpub"] = val or None
            elif key == "NAMES":
                names = json.loads(val or "{}")
                r["names"] = names if isinstance(names, dict) else {}
            elif key == "NETMONTH":
                r["net_month"] = float(val)
            elif key == "NET":
                ts, b = val.split()
                hour = datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc)
                r["net_hourly"][hour] = float(b)
            elif key == "WG":
                f = val.split("\t")
                if len(f) >= 7:
                    r["wg"].append({"pub": f[0], "ip": f[3].split("/")[0], "ep": f[2], "hs": int(f[4] or 0),
                                    "rx": int(f[5] or 0), "tx": int(f[6] or 0)})
        except ValueError:
            continue
    return r


def node_status(node):
    r = run_on(node, STATUS_SCRIPT, 15)
    if not r.ok and not r.out:
        log("status %s: rc=%d %s" % (node["code"], r.rc, r.err.strip()[:200]))
        return None
    s = parse_status(r.out)
    remember_wg_pub(node["code"], s["wgpub"])
    if s["net_month"] is not None:
        _last_net[node["code"]] = {"hourly": s["net_hourly"], "month": s["net_month"]}
    return s


def collect():
    now = datetime.datetime.now(datetime.timezone.utc)

    def live():
        with cf.ThreadPoolExecutor(max_workers=8) as ex:
            descs = dict(zip([n["code"] for n in NODES], ex.map(describe, NODES)))
            running = [n for n in NODES if descs[n["code"]]["state"] == "running"]
            stats = dict(zip([n["code"] for n in running], ex.map(node_status, running)))
        return descs, stats

    descs, stats = cached("live", LIVE_TTL, live)
    return build(now, descs, stats)


# ---------------------------------------------------------------- 정리(JSON 모양 — 앱의 DashData와 같음)

def build(now, descs, stats):
    mstart = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    nodes, hourly_total, egress_total, fixed = [], {}, 0.0, 0.0
    for n in NODES:
        d, s = descs[n["code"]], stats.get(n["code"])
        net = _last_net.get(n["code"], {"hourly": {}, "month": 0.0})
        # 꺼져 있어도 요금은 나간다(Vultr). 서버를 만들기 전 시간만 뺀다.
        since = max(mstart, d["created"]) if d.get("created") else mstart
        hours = max(0.0, (now - since).total_seconds() / 3600)
        monthly = float(n.get("monthly_usd") or 0.0)
        usd = min(monthly, hours * monthly / VULTR_MONTH_HOURS)
        fixed += usd
        egress = net["month"] / 1e9
        egress_total += egress
        for ts, v in net["hourly"].items():
            hourly_total[ts] = hourly_total.get(ts, 0.0) + v
        nodes.append({
            "code": n["code"], "city": n["city"], "region": n.get("region", "-"), "type": d["type"],
            "state": d["state"], "ip": d["ip"], "up": s["up"] if s else None,
            "idle": s["idle"] if s else None, "idleLimit": n.get("idle_limit"),
            "ike": s["ike"] if s else 0, "leases": s["leases"] if s else [], "load": s["load"] if s else None,
            "hours": round(hours, 2), "egressGB": round(egress, 3), "usd": round(usd, 2),
        })

    now_s = int(now.timestamp())
    # 같은 피어가 여러 서버에 붙을 수 있으니 서버별 카운터를 더하고, 가장 최근 핸드셰이크 서버를 표시한다
    agg = {}
    for code, s in stats.items():
        for p in (s or {}).get("wg", []):
            a = agg.setdefault(p["pub"], {"rx": 0, "tx": 0, "hs": 0, "ep": None, "node": None})
            a["rx"] += p["rx"]
            a["tx"] += p["tx"]
            if p["hs"] > a["hs"]:
                a.update(hs=p["hs"], node=code,
                         ep=p["ep"].rsplit(":", 1)[0] if p["ep"] not in ("", "(none)") else None)
    peers = []
    for x in sorted(wg_peers(), key=lambda x: int(x["ip"].rsplit(".", 1)[1])):
        a = agg.get(x["pub"], {"rx": 0, "tx": 0, "hs": 0, "ep": None, "node": None})
        peers.append({"n": str(int(x["ip"].rsplit(".", 1)[1]) - 1), "ip": x["ip"], "name": x.get("name"),
                      "adblock": bool(x.get("adblock")),
                      "hsAgo": (now_s - a["hs"]) if a["hs"] > 0 else None,
                      "rx": a["rx"], "tx": a["tx"], "ep": a["ep"], "node": a["node"]})

    cutoff = now.replace(minute=0, second=0, microsecond=0) - datetime.timedelta(hours=7)
    hourly = [{"h": ts.astimezone(KST).strftime("%H"), "gb": round(v / 1e9, 3)}
              for ts, v in sorted(hourly_total.items()) if ts >= cutoff]
    # Vultr는 서버들 포함 대역폭을 한 계정에서 합쳐 쓴다(풀). 넘으면 GB당 단가.
    free_gb = float(sum(float(n.get("bandwidth_gb") or 0) for n in NODES) or 1000.0)
    egress_usd = max(0.0, egress_total - free_gb) * float(CFG.get("egress_usd_per_gb", 0.01))
    return {
        "ts": now.astimezone(KST).strftime("%m-%d %H:%M:%S"),
        "nodes": nodes,
        "peers": peers,
        "hourly": hourly,
        "month": {"egressGB": round(egress_total, 3), "freeGB": free_gb, "egressUSD": round(egress_usd, 2),
                  "fixedUSD": round(fixed, 2), "usd": round(fixed + egress_usd, 2)},
    }


# ---------------------------------------------------------------- HTML (사이트)

def hb(n):
    n = float(n)
    if n >= 1e9:
        return "%.2f GB" % (n / 1e9)
    if n >= 1e6:
        return "%.1f MB" % (n / 1e6)
    if n >= 1e3:
        return "%.0f KB" % (n / 1e3)
    return "%d B" % int(n)


def dur(sec):
    sec = int(sec)
    if sec < 3600:
        return "%dm" % (sec // 60)
    if sec < 86400:
        return "%dh%02dm" % (sec // 3600, sec % 3600 // 60)
    return "%dd%dh" % (sec // 86400, sec % 86400 // 3600)


def ago(sec):
    if sec < 60:
        return "%ds ago" % sec
    if sec < 3600:
        return "%dm ago" % (sec // 60)
    if sec < 86400:
        return "%dh ago" % (sec // 3600)
    return "%dd ago" % (sec // 86400)


def span(cls, text):
    return '<span class="%s">%s</span>' % (cls, html.escape(str(text)))


def bar(value, maximum, width):
    n = 0 if maximum <= 0 else int(round(value / maximum * width))
    if value > 0 and n == 0:
        n = 1
    n = min(n, width)
    return span("bar", "█" * n) + span("track", "░" * (width - n))


def node_lines(x):
    tag = {"running": ("ok", "[ OK ]"), "pending": ("warn", "[ .. ]"), "stopping": ("warn", "[ .. ]"),
           "stopped": ("dim", "[ -- ]")}.get(x["state"], ("err", "[FAIL]"))
    head = "%s %s  %s %s" % (span("k", x["code"]), span("dim", x["city"].ljust(7)), span(tag[0], tag[1]),
                             span("num", x["ip"] or x["state"]))
    if x["state"] == "running":
        bits = [x["type"]]
        if x["up"] is not None:
            bits.append("up " + dur(x["up"]))
        else:
            bits.append("ssh: no answer")
        if x["idle"] is not None and x["idleLimit"]:
            bits.append("idle %d/%dm" % (x["idle"], x["idleLimit"]))
        bits.append("ike %d" % x["ike"])
        return head + "\n   " + span("dim", " · ".join(bits))
    return head + "\n   " + span("dim", "%s · %s" % (x["type"], x["state"]))


def render_html(d):
    nodes = "\n".join(node_lines(x) for x in d["nodes"])
    peers = []
    for p in d["peers"]:
        head = '%s %s %s ' % (span("k", "[peer %s]" % p["n"]), p["ip"], span("path", p.get("name") or ""))
        if p.get("adblock"):
            head += span("ok", "adblock") + " "
        if p["hsAgo"] is None:
            peers.append(head + span("dim", "○ idle") + "\n  " + span("dim", "no handshake since boot"))
            continue
        st = span("ok", "● online") if p["hsAgo"] < 180 else span("warn", "○ idle")
        peers.append(head + st + "\n  " + span("dim", "↓ tx") + " " + span("num", hb(p["tx"]).rjust(10)) +
                     "   " + span("dim", "↑ rx") + " " + span("num", hb(p["rx"]).rjust(9)) + "\n  " +
                     span("dim", "hs") + " " + ago(p["hsAgo"]) + " " + span("dim", "· ep") + " " + (p["ep"] or "-") +
                     (" " + span("k", "@" + p["node"]) if p.get("node") else ""))
    hourly = d["hourly"]
    mx = max([h["gb"] for h in hourly] or [0]) or 1.0
    bars = "\n".join("%s:00 %s %s" % (h["h"], span("num", "%6.2f GB" % h["gb"]), bar(h["gb"], mx, 22))
                     for h in hourly) or span("dim", "# no datapoints yet")
    m = d["month"]
    quota = "[%s] %s/%.0fGB %.0f%%" % (bar(min(m["egressGB"], m["freeGB"]), m["freeGB"], 18),
                                       span("num", "%.1f" % m["egressGB"]), m["freeGB"],
                                       min(m["egressGB"] / m["freeGB"] * 100, 100))
    by = " · ".join("%s %.1f" % (x["code"], x["egressGB"]) for x in d["nodes"])
    cost = "\n".join("%s %s %s  %s" % (span("k", x["code"]), span("dim", x["type"].ljust(12)),
                                        span("num", ("%.1fh" % x["hours"]).rjust(7)), span("num", "$%.2f" % x["usd"]))
                     for x in d["nodes"])
    cost += "\n%s %s" % (span("dim", ("egress >%.0fGB" % m["freeGB"]).ljust(25)), span("num", "$%.2f" % m["egressUSD"]))
    cost += "\n%s %s %s" % (span("k", "total"), span("dim", "≈"), span("ok", "$%.2f" % m["usd"]))
    up = sum(1 for x in d["nodes"] if x["state"] == "running")
    return (PAGE.replace("{{TS}}", d["ts"]).replace("{{UP}}", "%d/%d" % (up, len(d["nodes"])))
            .replace("{{NODES}}", nodes).replace("{{PEERS}}", "\n\n".join(peers)).replace("{{BARS}}", bars)
            .replace("{{QUOTA}}", quota).replace("{{BY}}", by).replace("{{COST}}", cost))


# ---------------------------------------------------------------- 피어 관리

class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def peer_script(req):
    """nago-peer.py를 서버에 깔고 req를 실행하는 셸 스크립트"""
    arg = base64.b64encode(json.dumps(req).encode()).decode()
    return ("cat > /usr/local/sbin/nago-peer <<'NAGO_PEER_EOF'\n%s\nNAGO_PEER_EOF\n"
            "chmod 0755 /usr/local/sbin/nago-peer\n/usr/local/sbin/nago-peer %s\n") % (PEER_ADMIN.rstrip("\n"), arg)


def push_sync(codes=None):
    """서버들의 WireGuard 피어를 목록에 맞춘다. 뒤에서 돌고 기다리지 않는다."""
    req = {"op": "sync", "peers": [{"pub": x["pub"], "ip": x["ip"], "adblock": bool(x.get("adblock"))}
                                   for x in wg_peers()]}
    script = peer_script(req)
    targets = [n for n in NODES if not codes or n["code"] in codes]

    def one(node):
        r = run_on(node, script, 60)
        if not r.ok:
            log("sync %s: rc=%d %s" % (node["code"], r.rc, (r.err or r.out).strip()[:200]))

    for n in targets:
        threading.Thread(target=one, args=(n,), daemon=True).start()
    return [n["code"] for n in targets]


def maybe_sync(code):
    """국가 API에서: 꺼져 있던 동안 놓친 변경이 있을 수 있으니 가끔 한 번씩 맞춘다."""
    if time.time() - _last_sync.get(code, 0) > SYNC_EVERY:
        _last_sync[code] = time.time()
        push_sync([code])


def default_name(ip):
    return "peer %d" % (int(ip.rsplit(".", 1)[1]) - 1)


def peer_list_admin(op, req):
    name = "".join(ch for ch in str(req.get("name") or "") if ch.isprintable()).strip()[:20]
    with _store_lock:
        data = read_json(WG_PEERS, {"peers": []})
        peers = data["peers"]
        if op == "add":
            pub = str(req.get("pub") or "")
            if not KEY_RE.match(pub):
                raise ApiError(400, "bad public key")
            mine = next((x for x in peers if x["pub"] == pub), None)
            changed = mine is None
            if changed:
                used = {x["ip"] for x in peers}
                ip = next((WG_NET + str(i) for i in range(2, 255) if WG_NET + str(i) not in used), None)
                if not ip:
                    raise ApiError(409, "no free address")
                mine = {"pub": pub, "ip": ip, "name": name or default_name(ip)}
                peers.append(mine)
                write_json(WG_PEERS, data)
        else:
            ip = str(req.get("ip") or "")
            mine = next((x for x in peers if x["ip"] == ip), None)
            if mine is None:
                raise ApiError(404, "no peer at %s" % ip)
            if op == "remove":
                peers.remove(mine)
            elif op == "flags":
                if "adblock" in req:
                    if str(req["adblock"]).strip().lower() in ("1", "true", "yes", "on"):
                        mine["adblock"] = True
                    else:
                        mine.pop("adblock", None)
            else:   # rename
                mine["name"] = name or default_name(ip)
            write_json(WG_PEERS, data)

    if op == "add":
        if changed:
            push_sync()
        servers = wg_servers()
        kr = node_by_code("kr")
        kr_srv = servers.get("kr", {})
        return {"ok": True, "ip": mine["ip"], "name": mine.get("name"), "servers": servers,
                "serverPub": kr_srv.get("pub"),
                "endpoint": "%s:%s" % (describe(kr).get("ip") or kr["addr"], kr_srv.get("port", 51820))}
    if op == "remove":
        return {"ok": True, "ip": ip, "pushed": push_sync()}
    if op == "flags":
        return {"ok": True, "ip": ip, "adblock": bool(mine.get("adblock")), "pushed": push_sync()}
    return {"ok": True, "ip": ip, "name": mine["name"]}


def peer_admin(req):
    """add/remove/rename/flags는 피어 목록 파일, kick/reset은 서울 서버에서 nago-peer로."""
    op = req.get("op")
    if op not in PEER_OPS:
        raise ApiError(400, "unknown op")
    allowed = {"op", "pub", "name", "ip", "seconds", "adblock"}
    req = {k: str(v)[:100] for k, v in req.items() if k in allowed}
    if op in ("add", "remove", "rename", "flags"):
        out = peer_list_admin(op, req)
        _cache.pop("live", None)
        return out
    kr = node_by_code("kr")
    state = describe(kr)["state"]
    if state != "running":
        raise ApiError(409, "kr is %s - start it first, then retry" % state)
    r = run_on(kr, peer_script(req), 30)
    lines = r.out.strip().splitlines()
    try:
        out = json.loads(lines[-1])
    except (IndexError, ValueError):
        raise ApiError(502, "server: " + (r.err.strip() or "rc=%d" % r.rc)[:200])
    if not out.get("ok"):
        raise ApiError(400, out.get("error") or "failed")
    _cache.pop("live", None)   # 다음 조회에 바로 반영
    return out


def node_admin(req):
    """서버 켜기/끄기/재부팅, 유휴 카운터 0으로(wake). 켜기는 Vultr API가 있어야 된다."""
    op = req.get("op")
    node = node_by_code(req.get("node"))
    if not node:
        raise ApiError(400, "unknown node")
    state = describe(node)["state"]
    api = vultr_enabled(node)
    if op == "start":
        if state in ("running", "pending"):
            pass
        elif not api:
            raise ApiError(409, "start needs vultr_api_key/vultr_id in control.json (or the Vultr console)")
        elif state == "stopped":
            vultr("POST", "/instances/%s/start" % node["vultr_id"])
            state = "pending"
        else:
            raise ApiError(409, "%s is %s - try again in a moment" % (node["code"], state))
    elif state != "running":
        if op == "stop" and state == "stopped":
            return {"ok": True, "node": node["code"], "state": state}
        raise ApiError(409, "%s is %s" % (node["code"], state))
    elif op == "stop":
        if node.get("local"):
            raise ApiError(409, "kr runs this control server - stop it from the Vultr console")
        if api:
            vultr("POST", "/instances/halt", {"instance_ids": [node["vultr_id"]]})
        else:
            run_on(node, "systemd-run --on-active=2 systemctl poweroff", 15)
        state = "stopping"
    elif op == "reboot":
        if api and not node.get("local"):
            vultr("POST", "/instances/reboot", {"instance_ids": [node["vultr_id"]]})
        else:
            # 응답을 먼저 돌려줄 수 있게 2초 뒤에 재부팅한다(서울은 이 서버 자신이라 특히)
            run_on(node, "systemd-run --on-active=2 systemctl reboot", 15)
    elif op == "wake":
        r = run_on(node, "mkdir -p /run/nago-idle && echo 0 > /run/nago-idle/idle && echo done", 20)
        if not r.ok:
            raise ApiError(502, "server: " + (r.err.strip() or "rc=%d" % r.rc)[:200])
    _cache.pop("live", None)
    return {"ok": True, "node": node["code"], "state": state}


# ---------------------------------------------------------------- 요청 처리 (Lambda 이벤트와 같은 모양의 dict)

def json_response(status, data):
    return {"statusCode": status, "headers": {"content-type": "application/json; charset=utf-8",
                                              "cache-control": "no-store"},
            "body": json.dumps(data, ensure_ascii=False)}


def key_ok(event):
    key = event["headers"].get("x-nago-key", "")
    sha = CFG.get("key_sha256", "")
    return bool(sha and key) and hmac.compare_digest(hashlib.sha256(key.encode()).hexdigest(), sha)


def token_ok(event):
    t = event["query"].get("t", "")
    return bool(t) and hmac.compare_digest(t, CFG["token"])


def handle_region(event):
    if not key_ok(event):
        return json_response(403, {"error": "forbidden"})
    code = event["query"].get("r", "")
    node = node_by_code(code)
    if not node:
        return json_response(404, {"error": "unknown region", "regions": sorted(n["code"] for n in NODES)})
    d = cached("describe:" + code, LIVE_TTL, lambda: describe(node))
    ready = d["state"] == "running"
    srv = wg_servers().get(code, {})
    if ready:
        maybe_sync(code)
        if not srv.get("pub"):   # 처음 한 번: 서버에 물어서 기억해 둔다
            r = run_on(node, "wg show wg0 public-key", 10)
            remember_wg_pub(code, r.out.strip())
            srv = wg_servers().get(code, {})
    return json_response(200, {
        "region": code, "state": d["state"], "ready": ready,
        "ip": d["ip"] if ready else None, "id": node["id"],
        "wgPub": srv.get("pub"), "wgPort": WG_PORT,
    })


def handle_post(event):
    # 바꾸는 요청은 비밀번호(x-nago-key)로만. 사이트 토큰(?t=)으로는 볼 수만 있다.
    if not key_ok(event):
        return json_response(403, {"ok": False, "error": "forbidden"})
    try:
        req = json.loads(event.get("body") or "{}")
        if not isinstance(req, dict):
            raise ValueError
    except ValueError:
        return json_response(400, {"ok": False, "error": "bad json"})
    try:
        if req.get("op") in NODE_OPS:
            return json_response(200, node_admin(req))
        return json_response(200, peer_admin(req))
    except ApiError as e:
        return json_response(e.status, {"ok": False, "error": str(e)})
    except urllib.error.HTTPError as e:
        return json_response(502, {"ok": False, "error": "vultr api: http %d" % e.code})
    except Exception as e:
        log("post %s: %r" % (req.get("op"), e))
        return json_response(500, {"ok": False, "error": str(e)[:300]})


def handle_dash(event):
    want_json = event["query"].get("format") == "json"
    if not (token_ok(event) or key_ok(event)):
        if want_json:
            return json_response(403, {"error": "forbidden"})
        return {"statusCode": 403, "headers": {"content-type": "text/plain; charset=utf-8"},
                "body": "403 forbidden: bad token\n"}
    try:
        data = collect()
    except Exception as e:
        log("collect: %r" % e)
        if want_json:
            return json_response(500, {"error": str(e)[:300]})
        return {"statusCode": 200, "headers": {"content-type": "text/html; charset=utf-8"},
                "body": '<pre style="background:#0a0d0a;color:#f87171;padding:16px;font-family:monospace">'
                        'panic: %s</pre>' % html.escape(str(e))}
    if want_json:
        return json_response(200, data)
    return {"statusCode": 200, "headers": {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"},
            "body": render_html(data)}


def route(method, path, query, headers, body):
    event = {"query": query, "headers": headers, "body": body}
    if method == "GET" and path == "/healthz":
        return {"statusCode": 200, "headers": {"content-type": "text/plain"}, "body": "ok\n"}
    if method == "GET" and path == "/region":
        return handle_region(event)
    if path == "/":
        if method == "POST":
            return handle_post(event)
        if method == "GET":
            return handle_dash(event)
        return json_response(405, {"error": "method not allowed"})
    return json_response(404, {"error": "not found"})


class Handler(BaseHTTPRequestHandler):
    server_version = "nago"
    sys_version = ""
    MAX_BODY = 64 * 1024

    def _dispatch(self, method):
        u = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(u.query).items()}
        headers = {k.lower(): v for k, v in self.headers.items()}
        body = ""
        if method == "POST":
            n = int(self.headers.get("content-length") or 0)
            if n > self.MAX_BODY:
                return self._send(json_response(413, {"error": "too large"}))
            body = self.rfile.read(n).decode("utf-8", "replace")
        try:
            resp = route(method, u.path, query, headers, body)
        except Exception as e:
            log("unhandled %s %s: %r" % (method, u.path, e))
            resp = json_response(500, {"error": "internal"})
        self._send(resp)

    def _send(self, resp):
        body = resp["body"].encode("utf-8")
        self.send_response(resp["statusCode"])
        for k, v in resp["headers"].items():
            self.send_header(k, v)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def log_message(self, fmt, *args):
        # 주소줄의 ?t=<토큰>이 로그에 남지 않게 경로만 적는다
        log("%s %s -> %s" % (self.command, urlsplit(self.path).path, args[1] if len(args) > 1 else "-"))


def main():
    with open(CONFIG_PATH, encoding="utf-8") as fh:
        configure(json.load(fh))
    host, _, port = CFG.get("listen", "127.0.0.1:8080").rpartition(":")
    os.makedirs(STATE_DIR, exist_ok=True)
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    srv.daemon_threads = True
    log("nago-control on %s:%s, nodes: %s" % (host, port, ", ".join(n["code"] for n in NODES)))
    srv.serve_forever()


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0d0a">
<meta name="referrer" content="no-referrer">
<title>nago@vpn</title>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&display=swap">
<style>
/* single dark theme on purpose: it's a terminal */
:root{--bg:#0a0d0a;--win:#0d110d;--chrome:#141a14;--edge:#1f2a1f;--fg:#c9d4c5;--dim:#5f6f5f;
--ok:#4ade80;--warn:#fbbf24;--err:#f87171;--key:#67e8f9;--path:#93c5fd;--num:#e7ece5;--track:#1c261c;color-scheme:dark}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg)}
body{color:var(--fg);font-family:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
font-size:13px;line-height:1.6;padding-top:env(safe-area-inset-top,0);padding-bottom:env(safe-area-inset-bottom,0)}
.wrap{max-width:780px;margin:0 auto;padding-inline:16px;padding-block:20px 32px}
.win{border:1px solid var(--edge);border-radius:8px;background:var(--win);overflow:hidden}
.bar-top{display:flex;align-items:center;gap:7px;padding:9px 12px;background:var(--chrome);border-bottom:1px solid var(--edge);color:var(--dim);font-size:11.5px}
.bar-top i{width:10px;height:10px;border-radius:50%;display:inline-block;background:#3a463a}
.bar-top span{margin-left:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
pre.term{margin:0;padding:14px 14px 18px;white-space:pre;overflow-x:auto;font:inherit;-webkit-overflow-scrolling:touch}
.p{color:var(--ok);font-weight:700}.path{color:var(--path)}.k{color:var(--key)}
.dim{color:var(--dim)}.ok{color:var(--ok)}.warn{color:var(--warn)}.err{color:var(--err)}
.num{color:var(--num)}.bar{color:var(--ok)}.track{color:var(--track)}
.cursor{display:inline-block;width:.6em;background:var(--ok);color:transparent;animation:blink 1.1s steps(1) infinite}
@keyframes blink{50%{opacity:0}}
@media (prefers-reduced-motion:reduce){.cursor{animation:none}}
.hint{color:var(--dim);font-size:11.5px;margin-top:10px;text-align:right}
</style></head><body><div class="wrap"><div class="win">
<div class="bar-top"><i></i><i></i><i></i><span>nago@vpn: ~ — all nodes — live</span></div>
<pre class="term"><span class="p">nago@vpn</span>:<span class="path">~</span>$ ./status --all
<span class="dim"># {{TS}} KST · nodes up {{UP}}</span>

<span class="p">$</span> nodes
{{NODES}}

<span class="p">$</span> wg show wg0 <span class="dim"># all nodes · since boot</span>
{{PEERS}}

<span class="p">$</span> netout --hourly --tz=KST <span class="dim"># all nodes</span>
{{BARS}}

<span class="p">$</span> quota --egress --month
{{QUOTA}}
<span class="dim">{{BY}} GB</span>

<span class="p">$</span> cost --month --est
{{COST}}

<span class="p">nago@vpn</span>:<span class="path">~</span>$ <span class="cursor">_</span></pre>
</div><div class="hint">↻ pull to refresh</div></div></body></html>"""


if __name__ == "__main__":
    main()
