#!/usr/bin/env python3
"""NAGO VPN 컨트롤 서버. 서울 Vultr 서버에서 돌고, AWS 시절 Lambda 두 개(국가 API, 대시보드)를 대신한다.

    GET  /region?r=<code>   + 헤더 x-nago-key → {"region","state","ready","ip","id","wgPub","wgPort"}
                                                임시 서버 나라(sg de …)면 없을 때 새로 만든다(+ "onDemand", "launched")
    GET  /?t=<TOKEN>                          → 터미널 스타일 HTML (브라우저)
    GET  /?format=json      + 헤더 x-nago-key → JSON (앱)
    POST / {op, ...}        + 헤더 x-nago-key → 피어 관리 add|kick|reset|remove|rename|flags
                                                서버 관리 start|stop|reboot|wake (node), 임시 서버 지우기 drop
    GET  /agent/<file>                        → 임시 서버가 받아 가는 nago-agent.py / setup-agent.sh (공개 파일)
    GET  /healthz                             → ok

응답 모양은 Lambda 때와 같아서 앱은 주소만 바꾸면 된다.

임시 서버(ondemand): AWS 때는 서버가 30분 유휴 시 스스로 꺼지면(종료 동작 = terminate) 지워졌다.
Vultr에는 그런 동작이 없고 꺼 둬도 요금이 나가서, 이 서버의 정리 스레드가 1분마다 임시 서버를 보고
30분 유휴(서버의 nago-idle 카운터, SSH로 읽음)거나 24시간이 지나면 Vultr API로 지운다.

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
NODE_OPS = ("start", "stop", "reboot", "wake", "drop")
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

# 임시 서버
OD_LABEL = "nago-od-"           # Vultr 라벨: nago-od-<code>
OD_STATE = "ondemand.json"      # {instance_id: {code, pub, created}} — 만든 서버의 wg 공개키
OD_USAGE = "ondemand-usage.json"  # {instance_id: {code, created, gone, tx}} — 이번 달 비용·송신량용 기록
OD_READY = "NAGO_WG_READY"
OD_GRACE_SEC = 240              # 준비 표시를 못 읽어도 만든 지 이만큼 지나면 준비된 걸로 본다(Vultr는 만들기가 느림)
OD_IDLE_MIN = 30                # 이만큼(분) 거의 안 쓰면 지운다
OD_TTL_SEC = 24 * 3600          # 이만큼 지나면 무조건 지운다
OD_REAP_EVERY = 60
AGENT_FILES = ("nago-agent.py", "setup-agent.sh")
PEER_IP_RE = re.compile(r"^10\.9\.0\.([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$")

CFG = {}
NODES = []
_cache = {}
_last_net = {}      # 서버가 잠깐 안 닿아도 마지막 송신량은 보여 준다
_last_sync = {}
_store_lock = threading.Lock()
_od_lock = threading.Lock()     # 앱이 몇 초마다 다시 물어도 같은 나라에 서버를 둘 만들지 않게


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
    for code, rc in ((cfg.get("ondemand") or {}).get("regions") or {}).items():
        if not rc.get("region"):
            raise SystemExit("config: ondemand region %r has no 'region'" % code)
        if any(n["code"] == code for n in cfg["nodes"]):
            raise SystemExit("config: %r is both a node and an ondemand region" % code)
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
        if node.get("ephemeral"):
            # 임시 서버: Vultr가 IP를 다른 서버에 다시 주므로 호스트 키를 기억하면 다음 서버에서 막힌다
            hosts = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
        else:
            hosts = ["-o", "StrictHostKeyChecking=accept-new",
                     "-o", "UserKnownHostsFile=" + os.path.join(STATE_DIR, "known_hosts")]
        cmd = ["ssh", "-i", CFG.get("ssh_key", "/etc/nago/id_ed25519"), "-o", "BatchMode=yes", *hosts,
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
    """{"state", "ip", "type", "created"} — Vultr API가 없거나 안 되면 설정값(항상 켜져 있다고 봄).
    created는 설정의 "created"(ISO 시각, 서버를 만든 때)로 줄 수 있다. 없으면 이번 달 1일부터로 셈."""
    base = {"state": "running", "ip": node["addr"], "type": node.get("plan", "-"),
            "created": parse_time(node.get("created"))}
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
            "created": parse_time(i.get("date_created")) or base["created"]}


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

    def od_live():
        if not (CFG.get("vultr_api_key") and od_regions()):
            return {}
        try:
            return {i["code"]: i for i in sorted(od_instances(), key=lambda i: i["created"] or now)}
        except Exception as e:   # 임시 서버 집계가 안 돼도 나머지는 보여 준다
            log("ondemand live: %r" % e)
            return {}

    descs, stats = cached("live", LIVE_TTL, live)
    od = cached("od_live", LIVE_TTL, od_live)
    return build(now, descs, stats, od, od_month(now) if od_regions() else {})


# ---------------------------------------------------------------- 정리(JSON 모양 — 앱의 DashData와 같음)

def build(now, descs, stats, od=None, odm=None):
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

    # 임시 서버 나라: 지금 떠 있거나 이번 달에 쓴 나라만
    od, odm = od or {}, odm or {}
    od_hourly = float(od_cfg().get("hourly_usd", 0.007))
    for code, rc in od_regions().items():
        live, m = od.get(code), odm.get(code)
        if not live and not m:
            continue
        m = m or {"minutes": 0.0, "bytes": 0.0, "servers": 0}
        hours = m["minutes"] / 60
        egress = m["bytes"] / 1e9
        egress_total += egress
        if live:
            state = "running" if live["status"] == "active" and live["power"] == "running" else "pending"
        else:
            state = "stopped"
        usd = hours * od_hourly
        fixed += usd
        nodes.append({
            "code": code, "city": rc.get("city", code), "region": rc["region"],
            "type": live["plan"] if live else od_cfg().get("plan", "vc2-1c-1gb"), "state": state,
            "ip": live["ip"] if live else None,
            "up": int((now - live["created"]).total_seconds()) if live and state == "running" and live["created"] else None,
            "idle": None, "idleLimit": OD_IDLE_MIN, "ike": 0, "leases": [], "load": None,
            "hours": round(hours, 2), "egressGB": round(egress, 3), "usd": round(usd, 2),
            "onDemand": True, "servers": m["servers"],
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

    # 최근 8시간을 빈 시간 없이 채운다(기록이 없는 시간은 0) — 앱·사이트 막대그래프가 늘 8칸으로 그려지게
    cutoff = now.replace(minute=0, second=0, microsecond=0) - datetime.timedelta(hours=7)
    hourly = []
    for i in range(8):
        ts = cutoff + datetime.timedelta(hours=i)
        hourly.append({"h": ts.astimezone(KST).strftime("%H"), "gb": round(hourly_total.get(ts, 0.0) / 1e9, 3)})
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
    od = x.get("onDemand")
    head = "%s %s  %s %s" % (span("k", x["code"]), span("dim", x["city"].ljust(7)), span(tag[0], tag[1]),
                             span("num", x["ip"] or ("no server" if od and x["state"] == "stopped" else x["state"])))
    if od:
        if x["state"] == "running":
            bits = [x["type"], "up " + dur(x["up"])] if x["up"] is not None else [x["type"]]
            return head + "\n   " + span("dim", " · ".join(bits + ["on demand · deletes after %dm idle" % x["idleLimit"]]))
        return head + "\n   " + span("dim", "on demand · %d server%s this month · made on connect"
                                     % (x.get("servers", 0), "" if x.get("servers") == 1 else "s"))
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
    """서버 켜기/끄기/재부팅, 유휴 카운터 0으로(wake). 켜기는 Vultr API가 있어야 된다. 임시 서버 나라는 drop만."""
    op = req.get("op")
    if req.get("node") in od_regions() and not node_by_code(req.get("node")):
        return od_admin(req)
    if op == "drop":
        raise ApiError(400, "drop is only for on-demand countries")
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


# ---------------------------------------------------------------- 임시 서버 나라 (ondemand)

def od_cfg():
    return CFG.get("ondemand") or {}


def od_regions():
    """{"sg": {"region": "sgp", "city": "singapore"}, ...}"""
    return od_cfg().get("regions") or {}


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(t):
    return t.isoformat() if t else None


_P = 2 ** 255 - 19


def x25519_public(private):
    """WireGuard 공개키(RFC 7748 X25519, 기준점 9). 표준 라이브러리만으로 계산한다."""
    k = bytearray(private)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    n = int.from_bytes(k, "little")
    x1, x2, z2, x3, z3, swap = 9, 1, 0, 9, 1, 0
    for t in reversed(range(255)):
        bit = (n >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % _P, (x2 - z2) % _P
        aa, bb = a * a % _P, b * b % _P
        e = (aa - bb) % _P
        c, d = (x3 + z3) % _P, (x3 - z3) % _P
        da, cb = d * a % _P, c * b % _P
        x3, z3 = (da + cb) ** 2 % _P, x1 * (da - cb) ** 2 % _P
        x2, z2 = aa * bb % _P, e * (aa + 121665 * e) % _P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, _P - 2, _P) % _P).to_bytes(32, "little")


def wg_keypair():
    private = bytearray(os.urandom(32))
    private[0] &= 248
    private[31] = (private[31] & 127) | 64
    return base64.b64encode(bytes(private)).decode(), base64.b64encode(x25519_public(private)).decode()


# 임시 서버가 첫 부팅 때 한 번 돌리는 스크립트(Vultr user-data). AWS 때와 같은 구성이고 다른 점은
#   - Vultr 우분투 이미지의 ufw를 끈다(켜져 있으면 wg가 막힘)
#   - 유휴 검사는 카운터만 올리고 끄지 않는다(지우는 건 컨트롤 서버 몫). 컨트롤 서버 SSH 키를 넣는다
#   - nago-agent 파일은 깃허브 대신 컨트롤 서버(@AGENT_URL@)에서 받는다
OD_SCRIPT = r"""#!/bin/bash
# NAGO VPN 임시 서버(@CODE@). WireGuard를 먼저 올리고(바로 연결됨), TCP 분할 가속(haproxy)·광고 차단 DNS·nago-agent는
# 그 뒤에 백그라운드로 깐다. 30분 동안 거의 안 쓰거나 24시간이 지나면 서울 컨트롤 서버가 Vultr API로 지운다.
exec > >(tee -a /var/log/nago-ondemand.log) 2>&1
command -v ufw >/dev/null && ufw --force disable
install -d -m 700 /root/.ssh
echo '@SSHKEY@' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
DEFIF=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

modprobe tcp_bbr 2>/dev/null
modprobe nf_conntrack 2>/dev/null
printf '%s\n' net.ipv4.ip_forward=1 net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr \
  net.ipv4.tcp_mtu_probing=1 net.core.rmem_max=67108864 net.core.wmem_max=67108864 \
  'net.ipv4.tcp_rmem=4096 131072 67108864' 'net.ipv4.tcp_wmem=4096 65536 67108864' \
  net.ipv4.tcp_slow_start_after_idle=0 net.ipv4.tcp_fastopen=3 net.netfilter.nf_conntrack_max=262144 \
  > /etc/sysctl.d/99-nago.conf
sysctl -q -p /etc/sysctl.d/99-nago.conf

wg_up() {
  umask 027
  printf '%s\n' '[NetDev]' 'Name=wg0' 'Kind=wireguard' 'MTUBytes=1420' '' '[WireGuard]' \
    'PrivateKey=@KEY@' 'ListenPort=51820' > /etc/systemd/network/90-nago-wg0.netdev
  printf '@PEERS@' >> /etc/systemd/network/90-nago-wg0.netdev
  chgrp systemd-network /etc/systemd/network/90-nago-wg0.netdev
  umask 022
  printf '[Match]\nName=wg0\n\n[Network]\nAddress=10.9.0.1/24\n' > /etc/systemd/network/90-nago-wg0.network
  networkctl reload
  for i in $(seq 1 40); do ip -4 addr show wg0 2>/dev/null | grep -q 10.9.0.1 && return 0; sleep 0.5; done
  return 1
}
if ! wg_up; then
  apt-get -o DPkg::Lock::Timeout=60 update -y && apt-get -o DPkg::Lock::Timeout=60 install -y "linux-modules-extra-$(uname -r)"
  modprobe wireguard
  wg_up
fi

if command -v iptables >/dev/null; then
  iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "$DEFIF" -j MASQUERADE
  iptables -A FORWARD -i wg0 -j ACCEPT
  iptables -A FORWARD -o wg0 -j ACCEPT
  iptables -t nat -A PREROUTING -i "$DEFIF" -p udp --dport @PORT@ -j REDIRECT --to-ports 51820
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
else
  printf '%s\n' 'table ip nago {' \
    "  chain pre { type nat hook prerouting priority dstnat; iifname \"$DEFIF\" udp dport @PORT@ redirect to :51820; }" \
    "  chain post { type nat hook postrouting priority srcnat; ip saddr 10.9.0.0/24 oifname \"$DEFIF\" masquerade; }" \
    '  chain fwd { type filter hook forward priority mangle; tcp flags syn tcp option maxseg size set rt mtu; }' \
    '}' | nft -f -
fi

# 매분: 분당 송신 300KB 미만인 분이 이어지면 카운터를 올린다(/run이라 부팅마다 0부터). 끄지는 않는다 —
# 컨트롤 서버가 SSH로 읽어서 30이 넘으면 지운다
printf '%s\n' '#!/bin/bash' \
  'DEV=$(ip route get 1.1.1.1 | awk '"'"'{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'"'"')' \
  'S=/run/nago-idle; mkdir -p "$S"' \
  'tx=$(cat "/sys/class/net/$DEV/statistics/tx_bytes")' \
  'last=$(cat "$S/tx" 2>/dev/null || echo "$tx")' \
  'echo "$tx" > "$S/tx"' \
  'idle=$(cat "$S/idle" 2>/dev/null || echo 0)' \
  'if [ $((tx - last)) -lt 300000 ]; then idle=$((idle + 1)); else idle=0; fi' \
  'echo "$idle" > "$S/idle"' \
  > /usr/local/sbin/nago-idle
chmod +x /usr/local/sbin/nago-idle
printf '[Unit]\nDescription=NAGO idle counter\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/nago-idle\n' \
  > /etc/systemd/system/nago-idle.service
printf '[Unit]\nDescription=NAGO idle counter every minute\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=5s\n[Install]\nWantedBy=timers.target\n' \
  > /etc/systemd/system/nago-idle.timer
systemctl daemon-reload
systemctl enable --now nago-idle.timer

echo "@READY@ wg0=$(cat /sys/class/net/wg0/operstate 2>/dev/null || echo missing) peers=@NPEERS@"

# ---- TCP 분할 가속(고정 서버의 nago-accel과 같음)
cat > /usr/local/sbin/nago-accel <<'SH'
#!/bin/bash
GUARD="INPUT -p tcp --dport 12345 -m conntrack ! --ctstate DNAT -j DROP"
WG_MATCH="-i wg0 -p tcp"
case "$1" in
on)
  iptables -t nat -N NAGO_ACCEL 2>/dev/null; iptables -t nat -F NAGO_ACCEL
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10; do
    iptables -t nat -A NAGO_ACCEL -d $n -j RETURN
  done
  iptables -t nat -A NAGO_ACCEL -p tcp -j REDIRECT --to-ports 12345
  iptables -C $GUARD 2>/dev/null || iptables -I $GUARD
  iptables -t nat -C PREROUTING $WG_MATCH -j NAGO_ACCEL 2>/dev/null || iptables -t nat -I PREROUTING $WG_MATCH -j NAGO_ACCEL ;;
off)
  iptables -t nat -D PREROUTING $WG_MATCH -j NAGO_ACCEL 2>/dev/null
  iptables -D $GUARD 2>/dev/null
  iptables -t nat -F NAGO_ACCEL 2>/dev/null; iptables -t nat -X NAGO_ACCEL 2>/dev/null ;;
esac
SH
chmod +x /usr/local/sbin/nago-accel
cat > /usr/local/sbin/nago-accel-setup <<'SH'
#!/bin/bash
exec > >(tee -a /var/log/nago-ondemand.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3; do
  apt-get -o DPkg::Lock::Timeout=120 -q update && \
    apt-get -o DPkg::Lock::Timeout=120 -q install -y --no-install-recommends haproxy && break
  sleep 5
done
command -v haproxy >/dev/null || { echo "NAGO_ACCEL_FAIL no haproxy"; exit 1; }
cat > /etc/haproxy/haproxy.cfg <<'CFG'
global
    log /dev/log local0 warning
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    maxconn 40000

defaults
    log global
    mode tcp
    option dontlognull
    option splice-auto
    timeout connect 8s
    timeout client 6h
    timeout server 6h
    timeout client-fin 30s
    timeout server-fin 30s

frontend nago_split
    bind :12345
    default_backend nago_orig

backend nago_orig
    server orig 0.0.0.0
CFG
haproxy -c -f /etc/haproxy/haproxy.cfg || { echo "NAGO_ACCEL_FAIL config"; exit 1; }
printf '%s\n' '[Unit]' 'Description=NAGO VPN TCP split acceleration (off when haproxy stops)' \
  'After=haproxy.service' 'BindsTo=haproxy.service' '[Service]' 'Type=oneshot' \
  'ExecStart=/usr/local/sbin/nago-accel on' 'ExecStop=/usr/local/sbin/nago-accel off' 'RemainAfterExit=yes' \
  '[Install]' 'WantedBy=multi-user.target haproxy.service' > /etc/systemd/system/nago-accel.service
systemctl daemon-reload
systemctl restart haproxy && systemctl enable --now nago-accel && \
  echo "NAGO_ACCEL_READY uptime=$(cut -d. -f1 /proc/uptime)s"
SH
chmod +x /usr/local/sbin/nago-accel-setup
systemd-run --unit nago-accel-setup /usr/local/sbin/nago-accel-setup

# ---- 광고 차단 DNS + nago-agent. 다 깔릴 때까지 10.53.53.53:53은 1.1.1.1로 넘겨 두고, 에이전트가 뜨면 뗀다.
ip link add nago-dns type dummy 2>/dev/null; ip addr add 10.53.53.53/32 dev nago-dns 2>/dev/null; ip link set nago-dns up
for pr in udp tcp; do
  iptables -t nat -I PREROUTING -i wg0 -d 10.53.53.53 -p $pr --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null
done
cat > /usr/local/sbin/nago-agent-setup <<'SH'
#!/bin/bash
exec > >(tee -a /var/log/nago-ondemand.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5; do
  command -v dnsmasq >/dev/null && break
  apt-get -o DPkg::Lock::Timeout=180 -q install -y --no-install-recommends dnsmasq-base \
    || { apt-get -o DPkg::Lock::Timeout=180 -q update; sleep 5; }
done
command -v dnsmasq >/dev/null || { echo "NAGO_AGENT_FAIL no dnsmasq"; exit 1; }
mkdir -p /etc/nago-dns /var/lib/nago-dns /root/nago-agent
printf 'bind-interfaces\nlisten-address=127.0.0.1\nport=5354\nno-resolv\nserver=1.1.1.1\n' > /etc/nago-dns/dnsmasq.conf
printf '%s\n' '[Unit]' 'Description=NAGO VPN dns cache' '[Service]' \
  'ExecStartPre=-/usr/sbin/ip link add nago-dns type dummy' 'ExecStartPre=-/usr/sbin/ip addr add 10.53.53.53/32 dev nago-dns' \
  'ExecStartPre=/usr/sbin/ip link set nago-dns up' \
  'ExecStart=/usr/sbin/dnsmasq -k -C /etc/nago-dns/dnsmasq.conf --pid-file=/run/nago-dns.pid' 'Restart=always' \
  '[Install]' 'WantedBy=multi-user.target' > /etc/systemd/system/nago-dns.service
systemctl daemon-reload && systemctl enable --now nago-dns
cd /root/nago-agent
for f in nago-agent.py setup-agent.sh; do
  curl -fsSL --retry 3 --max-time 60 -o $f "@AGENT_URL@/$f" || { echo "NAGO_AGENT_FAIL download $f"; exit 1; }
done
if bash setup-agent.sh && /usr/local/sbin/nago-dns-guard; then
  for pr in udp tcp; do
    iptables -t nat -D PREROUTING -i wg0 -d 10.53.53.53 -p $pr --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null
  done
  echo "NAGO_AGENT_READY uptime=$(cut -d. -f1 /proc/uptime)s"
else
  echo "NAGO_AGENT_FAIL setup (dns stays on 1.1.1.1)"
fi
SH
chmod +x /usr/local/sbin/nago-agent-setup
systemd-run --unit nago-agent-setup /usr/local/sbin/nago-agent-setup
"""

# 정리 스레드가 SSH로 읽는 것: 유휴 카운터(분)와 기본 인터페이스 송신 바이트
OD_PROBE = r"""echo "IDLE $(cat /run/nago-idle/idle 2>/dev/null || echo 0)"
DEV=$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
echo "TX $(cat /sys/class/net/$DEV/statistics/tx_bytes 2>/dev/null || echo 0)"
grep -q NAGO_WG_READY /var/log/nago-ondemand.log 2>/dev/null && echo READY
"""


def od_node(inst):
    """run_on에 넘길 모양. 임시 서버는 IP가 다시 쓰이므로 호스트 키를 기억하지 않는다."""
    return {"code": inst["code"], "addr": inst["ip"], "ephemeral": True}


def od_instances():
    """Vultr에 있는 임시 서버(만드는 중 포함) — 라벨 nago-od-<code>"""
    out = []
    for i in vultr("GET", "/instances?per_page=500").get("instances", []):
        label = i.get("label") or ""
        code = label[len(OD_LABEL):] if label.startswith(OD_LABEL) else None
        if code not in od_regions():
            continue
        ip = i.get("main_ip")
        out.append({"id": i["id"], "code": code, "status": i.get("status"), "power": i.get("power_status"),
                    "ip": ip if ip and ip != "0.0.0.0" else None, "created": parse_time(i.get("date_created")),
                    "plan": i.get("plan") or "-", "region": i.get("region")})
    return out


def od_find(code, insts):
    mine = [i for i in insts if i["code"] == code]
    return max(mine, key=lambda i: i["created"] or utcnow()) if mine else None


def od_peers():
    """지금 피어 목록(공개키, ip). 스크립트에 그대로 들어가니 모양을 확인한다."""
    return [(p["pub"], p["ip"]) for p in wg_peers()
            if KEY_RE.match(str(p.get("pub", ""))) and PEER_IP_RE.match(str(p.get("ip", "")))]


def od_create(code):
    rc, oc = od_regions()[code], od_cfg()
    private, public = wg_keypair()
    peers = od_peers()
    with open(CFG.get("ssh_key", "/etc/nago/id_ed25519") + ".pub", encoding="utf-8") as fh:
        ssh_pub = fh.read().strip()
    script = (OD_SCRIPT.replace("@CODE@", code).replace("@KEY@", private).replace("@PORT@", str(WG_PORT))
              .replace("@READY@", OD_READY).replace("@NPEERS@", str(len(peers))).replace("@SSHKEY@", ssh_pub)
              .replace("@AGENT_URL@", CFG["public_url"].rstrip("/") + "/agent")
              # printf 서식 문자열로 들어간다: \n은 printf가 줄바꿈으로 바꾼다(키·ip에는 %나 \가 없다)
              .replace("@PEERS@", "".join("\\n[WireGuardPeer]\\nPublicKey=%s\\nAllowedIPs=%s/32\\n" % p
                                          for p in peers)))
    body = {"region": rc["region"], "plan": oc.get("plan", "vc2-1c-1gb"), "os_id": int(oc.get("os_id", 2284)),
            "label": OD_LABEL + code, "hostname": OD_LABEL + code, "tags": ["nago-ondemand"],
            "user_data": base64.b64encode(script.encode()).decode(), "enable_ipv6": False, "backups": "disabled"}
    if oc.get("firewall_group_id"):
        body["firewall_group_id"] = oc["firewall_group_id"]
    i = vultr("POST", "/instances", body)["instance"]
    created = parse_time(i.get("date_created")) or utcnow()
    with _store_lock:
        state = read_json(OD_STATE, {})
        state[i["id"]] = {"code": code, "pub": public, "created": iso(created)}
        write_json(OD_STATE, state)
        usage = read_json(OD_USAGE, {})
        usage[i["id"]] = {"code": code, "created": iso(created), "gone": None, "tx": 0}
        write_json(OD_USAGE, usage)
    log("ondemand %s: created %s in %s" % (code, i["id"], rc["region"]))
    return {"id": i["id"], "code": code, "status": i.get("status", "pending"), "power": i.get("power_status"),
            "ip": None, "created": created, "plan": body["plan"], "region": rc["region"]}


def od_probe(inst):
    """{"idle": 분, "tx": 바이트, "ready": bool} 또는 None(SSH 안 됨)"""
    r = run_on(od_node(inst), OD_PROBE, 10)
    if not r.ok:
        return None
    out = {"idle": 0, "tx": 0, "ready": False}
    for line in r.out.splitlines():
        key, _, val = line.partition(" ")
        if key in ("IDLE", "TX"):
            try:
                out[key.lower()] = int(val.strip() or 0)
            except ValueError:
                pass
        elif key == "READY":
            out["ready"] = True
    return out


def od_ready(inst):
    """WireGuard가 올라왔는지: 서버가 로그에 남긴 준비 표시를 SSH로 본다. 못 읽어도 만든 지 오래면 준비로."""
    if inst["status"] != "active" or inst["power"] != "running" or not inst["ip"]:
        return False
    p = od_probe(inst)
    if p and p["ready"]:
        return True
    return bool(inst["created"]) and (utcnow() - inst["created"]).total_seconds() > OD_GRACE_SEC


def od_destroy(iid):
    vultr("DELETE", "/instances/%s" % iid)
    log("ondemand: destroyed %s" % iid)


def handle_ondemand(code):
    if not CFG.get("vultr_api_key") or not CFG.get("public_url"):
        return json_response(503, {"error": "on-demand servers need vultr_api_key and public_url in control.json"})
    with _od_lock:
        insts = od_instances()
        inst = od_find(code, insts)
        state = None
        if not inst:
            limit = int(od_cfg().get("max", 2))
            if len(insts) >= limit:
                return json_response(409, {"error": "too many on-demand servers", "max": limit})
            inst = od_create(code)
            state = "creating"
    pub = read_json(OD_STATE, {}).get(inst["id"], {}).get("pub")
    running = inst["status"] == "active" and inst["power"] == "running"
    return json_response(200, {
        "region": code, "state": state or ("running" if running else "pending"),
        "ready": state is None and od_ready(inst),
        "ip": inst["ip"] if running else None, "id": code + ".nago.vpn",
        "wgPub": pub, "wgPort": WG_PORT, "onDemand": True, "launched": iso(inst["created"]),
    })


def od_reap_once(now=None):
    """임시 서버 정리: 30분 유휴·24시간·오래 안 닿음이면 지운다. 이번 달 기록(송신량·지운 때)도 남긴다."""
    if not (CFG.get("vultr_api_key") and od_regions()):
        return []
    now = now or utcnow()
    insts = od_instances()
    dropped = []
    with _store_lock:
        usage = read_json(OD_USAGE, {})
    for inst in insts:
        age = (now - inst["created"]).total_seconds() if inst["created"] else 0
        u = usage.setdefault(inst["id"], {"code": inst["code"], "created": iso(inst["created"]), "gone": None, "tx": 0})
        if inst["created"]:
            u["created"] = iso(inst["created"])   # 시각은 Vultr 기록이 기준
        reason = None
        if age > OD_TTL_SEC:
            reason = "24h"
        elif inst["ip"] and inst["status"] == "active" and age > 300:
            p = od_probe(inst)
            if p:
                u["tx"] = max(int(u.get("tx") or 0), p["tx"])
                u["fails"] = 0
                if p["idle"] >= OD_IDLE_MIN:
                    reason = "idle %dm" % p["idle"]
            else:
                u["fails"] = int(u.get("fails") or 0) + 1
                if u["fails"] >= 10 and age > 1800:
                    reason = "unreachable"
        if reason:
            try:
                od_destroy(inst["id"])
            except Exception as e:
                log("ondemand %s: destroy failed: %r" % (inst["code"], e))
                continue
            u["gone"] = iso(now)
            dropped.append((inst["code"], reason))
            log("ondemand %s: dropped (%s)" % (inst["code"], reason))
    live = {i["id"] for i in insts} - {iid for iid, u in usage.items() if u.get("gone")}
    cutoff = now - datetime.timedelta(days=40)
    with _store_lock:
        fresh = read_json(OD_USAGE, {})     # 그사이 새로 만든 서버 기록을 지우지 않게 합친다
        for iid, u in usage.items():
            fresh[iid] = dict(fresh.get(iid, {}), **u)
        for iid, u in list(fresh.items()):
            if not u.get("gone") and iid not in live and (parse_time(u.get("created")) or now) < now - datetime.timedelta(minutes=10):
                u["gone"] = iso(now)
            if u.get("gone") and (parse_time(u["gone"]) or now) < cutoff:
                del fresh[iid]
        write_json(OD_USAGE, fresh)
        state = read_json(OD_STATE, {})
        for iid in [k for k in state if k not in live and fresh.get(k, {}).get("gone")]:
            del state[iid]
        write_json(OD_STATE, state)
    _cache.pop("od_live", None)
    return dropped


def od_reaper():
    while True:
        time.sleep(OD_REAP_EVERY)
        try:
            od_reap_once()
        except Exception as e:
            log("ondemand reaper: %r" % e)


def od_month(now):
    """이번 달 임시 서버 사용량 {code: {"minutes", "bytes", "servers"}} — ondemand-usage.json 기록에서"""
    mstart = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    out = {}
    for u in read_json(OD_USAGE, {}).values():
        start, end = parse_time(u.get("created")), parse_time(u.get("gone")) or now
        if not start or end < mstart:
            continue
        m = out.setdefault(u.get("code"), {"minutes": 0.0, "bytes": 0.0, "servers": 0})
        m["minutes"] += max(0.0, (end - max(start, mstart)).total_seconds() / 60)
        m["bytes"] += float(u.get("tx") or 0)
        m["servers"] += 1
    return out


def od_admin(req):
    """임시 서버 나라: drop만 된다(떠 있는 서버를 바로 지움). 만드는 건 vpn 탭에서 연결할 때 국가 API가 한다."""
    code = req.get("node")
    if req.get("op") != "drop":
        raise ApiError(400, "%s is on demand - connect from the vpn tab to make a server" % code)
    if not CFG.get("vultr_api_key"):
        raise ApiError(409, "needs vultr_api_key")
    inst = od_find(code, od_instances())
    if not inst:
        return {"ok": True, "node": code, "state": "none"}
    od_destroy(inst["id"])
    with _store_lock:
        usage = read_json(OD_USAGE, {})
        if inst["id"] in usage:
            usage[inst["id"]]["gone"] = iso(utcnow())
            write_json(OD_USAGE, usage)
    _cache.pop("od_live", None)
    return {"ok": True, "node": code, "state": "stopping"}


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
    if not node and code in od_regions():
        return handle_ondemand(code)
    if not node:
        return json_response(404, {"error": "unknown region", "regions": sorted(n["code"] for n in NODES),
                                   "onDemand": sorted(od_regions())})
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
    if method == "GET" and path.startswith("/agent/"):
        # 임시 서버가 첫 부팅 때 받아 가는 파일(레포에 공개된 것과 같음). 정해진 두 파일만
        name = path[len("/agent/"):]
        if name not in AGENT_FILES:
            return json_response(404, {"error": "not found"})
        agent_dir = os.environ.get("NAGO_AGENT_DIR", os.path.join(HERE, "agent"))
        try:
            with open(os.path.join(agent_dir, name), encoding="utf-8") as fh:
                return {"statusCode": 200, "headers": {"content-type": "text/plain; charset=utf-8"}, "body": fh.read()}
        except FileNotFoundError:
            return json_response(404, {"error": "agent files not installed"})
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
    log("nago-control on %s:%s, nodes: %s, on demand: %s" % (host, port, ", ".join(n["code"] for n in NODES),
                                                              ", ".join(sorted(od_regions())) or "-"))
    if od_regions():
        threading.Thread(target=od_reaper, daemon=True).start()
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
