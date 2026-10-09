"""NAGO VPN 통합 대시보드 (모든 국가 서버).

GET /?t=<TOKEN>                → 터미널 스타일 HTML (브라우저)
GET /?format=json  + 헤더 x-nago-key: <VPN 비밀번호>  → JSON (앱)
POST / {op, ...}   + 헤더 x-nago-key                 → 서울 WireGuard 피어 관리 (nago-peer.py)

보여 주는 것: 서버별 상태/IP/가동 시간/유휴 카운터/IKEv2 접속, 서울 WireGuard 피어,
시간별 송신량(전체 합), 이번 달 송신량과 비용 추정.
"""
import base64
import concurrent.futures as cf
import datetime
import hashlib
import hmac
import html
import json
import os
import time

import boto3

TOKEN = os.environ["TOKEN"]
KEY_SHA = os.environ.get("KEY_SHA256", "")
# [{"code","city","region","iid","idle_limit","eip"}]
NODES = json.loads(os.environ["NODES"])
PEER_ADMIN = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "nago-peer.py")).read()
PEER_OPS = ("add", "kick", "reset", "remove", "rename")
_last_peers = []   # 서울 서버가 꺼져 있을 때 보여 줄 마지막 피어 목록

# 비용 추정용 단가(USD). 리눅스 온디맨드 / 디스크 8GB / 공인 IPv4 / 무료 100GB 초과 송신.
HOURLY = {
    "c6i.large@ap-northeast-2": 0.096,
    "c7g.medium@ap-northeast-1": 0.0455,
    "c7g.medium@us-west-2": 0.0363,
    "c7g.medium@eu-west-2": 0.0429,
}
DISK_MONTH = {"ap-northeast-2": 8 * 0.114, "ap-northeast-1": 8 * 0.096, "us-west-2": 8 * 0.08, "eu-west-2": 8 * 0.0928}
IPV4_H = 0.005
EGRESS_GB_USD = 0.126
FREE_GB = 100.0
KST = datetime.timezone(datetime.timedelta(hours=9))

LIVE_TTL = 10      # 상태/SSM 결과 재사용 시간(초)
METRIC_TTL = 120   # CloudWatch 결과 재사용 시간(초)
_cache = {}
_clients = {}

STATUS_SCRIPT = r"""I=$(cat /run/nago-idle/idle 2>/dev/null || echo -1)
echo "IDLE $I"
echo "UP $(cut -d. -f1 /proc/uptime)"
echo "LOAD $(cut -d' ' -f1 /proc/loadavg)"
echo "IKE $(ipsec status 2>/dev/null | grep -c ESTABLISHED)"
ipsec leases 2>/dev/null | awk '$2=="online"{print "LEASE "$1}'
if command -v wg >/dev/null 2>&1; then wg show wg0 dump 2>/dev/null | tail -n +2 | sed 's/^/WG /'; fi
echo "NAMES $(tr -d '\n' < /etc/wireguard/nago-names.json 2>/dev/null || echo '{}')"
"""


def client(service, region):
    k = (service, region)
    if k not in _clients:
        _clients[k] = boto3.client(service, region_name=region)
    return _clients[k]


def cached(name, ttl, fn):
    hit = _cache.get(name)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    value = fn()
    _cache[name] = (time.time(), value)
    return value


# ---------------------------------------------------------------- 수집

def describe(node):
    i = client("ec2", node["region"]).describe_instances(InstanceIds=[node["iid"]])["Reservations"][0]["Instances"][0]
    # 루트 디스크가 붙은 시각 = 서버를 만든 시각 (LaunchTime은 켤 때마다 바뀜)
    attached = [b["Ebs"]["AttachTime"] for b in i.get("BlockDeviceMappings", []) if "Ebs" in b]
    return {"state": i["State"]["Name"], "ip": i.get("PublicIpAddress"), "type": i["InstanceType"],
            "launched": i["LaunchTime"], "created": min(attached) if attached else i["LaunchTime"]}


def parse_status(text):
    r = {"idle": None, "up": None, "load": None, "ike": 0, "leases": [], "wg": [], "names": {}}
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
            elif key == "NAMES":
                names = json.loads(val or "{}")
                r["names"] = names if isinstance(names, dict) else {}
            elif key == "WG":
                f = val.split("\t")
                if len(f) >= 7:
                    r["wg"].append({"ip": f[3].split("/")[0], "ep": f[2], "hs": int(f[4] or 0),
                                    "rx": int(f[5] or 0), "tx": int(f[6] or 0)})
        except ValueError:
            continue
    return r


def ssm_status(node):
    ssm = client("ssm", node["region"])
    try:
        cid = ssm.send_command(InstanceIds=[node["iid"]], DocumentName="AWS-RunShellScript",
                               Parameters={"commands": [STATUS_SCRIPT]}, TimeoutSeconds=30)["Command"]["CommandId"]
    except Exception:
        return None   # 막 켜져서 SSM 에이전트가 아직 안 붙은 경우 등
    deadline = time.time() + 12
    while time.time() < deadline:
        time.sleep(1.0)
        try:
            inv = ssm.get_command_invocation(CommandId=cid, InstanceId=node["iid"])
        except Exception:
            continue
        if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
            return parse_status(inv.get("StandardOutputContent", ""))
    return None


def metrics(node, now):
    """이번 달 가동 분(CPU 5분 데이터 개수), 시간별/월 송신량."""
    cw = client("cloudwatch", node["region"])
    mstart = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    dim = [{"Name": "InstanceId", "Value": node["iid"]}]

    def q(qid, name, period, stat):
        return {"Id": qid, "ReturnData": True, "MetricStat": {
            "Metric": {"Namespace": "AWS/EC2", "MetricName": name, "Dimensions": dim},
            "Period": period, "Stat": stat}}

    series = {"cpu": [], "hourly": [], "month": []}
    token = None
    while True:
        kw = {"MetricDataQueries": [q("cpu", "CPUUtilization", 300, "Average"),
                                    q("hourly", "NetworkOut", 3600, "Sum"),
                                    q("month", "NetworkOut", 86400, "Sum")],
              "StartTime": mstart, "EndTime": now, "ScanBy": "TimestampAscending"}
        if token:
            kw["NextToken"] = token
        r = cw.get_metric_data(**kw)
        for res in r["MetricDataResults"]:
            series[res["Id"]].extend(zip(res["Timestamps"], res["Values"]))
        token = r.get("NextToken")
        if not token:
            break
    return {
        "minutes": len(series["cpu"]) * 5,
        "hourly": {ts.replace(minute=0, second=0, microsecond=0): v for ts, v in series["hourly"]},
        "month_bytes": sum(v for _, v in series["month"]),
    }


def collect():
    now = datetime.datetime.now(datetime.timezone.utc)

    def live():
        with cf.ThreadPoolExecutor(max_workers=8) as ex:
            descs = dict(zip([n["code"] for n in NODES], ex.map(describe, NODES)))
            running = [n for n in NODES if descs[n["code"]]["state"] == "running"]
            stats = dict(zip([n["code"] for n in running], ex.map(ssm_status, running)))
        return descs, stats

    def all_metrics():
        with cf.ThreadPoolExecutor(max_workers=4) as ex:
            return dict(zip([n["code"] for n in NODES], ex.map(lambda n: metrics(n, now), NODES)))

    descs, stats = cached("live", LIVE_TTL, live)
    mets = cached("metrics", METRIC_TTL, all_metrics)
    return build(now, descs, stats, mets)


# ---------------------------------------------------------------- 정리(JSON 모양)

def build(now, descs, stats, mets):
    mstart = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    next_month = (mstart + datetime.timedelta(days=32)).replace(day=1)

    nodes, hourly_total, egress_total, fixed = [], {}, 0.0, 0.0
    for n in NODES:
        d, s, m = descs[n["code"]], stats.get(n["code"]), mets[n["code"]]
        hours = m["minutes"] / 60
        price = HOURLY.get("%s@%s" % (d["type"], n["region"]), 0.0)
        # 디스크와 고정 IP는 꺼져 있어도 나가지만, 서버를 만들기 전 시간은 빼야 첫 달이 부풀지 않는다
        exists = max(datetime.timedelta(0), now - max(mstart, d["created"]))
        ipv4 = (exists.total_seconds() / 3600 if n.get("eip") else hours) * IPV4_H
        disk = DISK_MONTH.get(n["region"], 0.0) * (exists / (next_month - mstart))
        fixed += disk + (ipv4 if n.get("eip") else 0.0)
        egress = m["month_bytes"] / 1e9
        egress_total += egress
        for ts, v in m["hourly"].items():
            hourly_total[ts] = hourly_total.get(ts, 0.0) + v
        up = s["up"] if s and s.get("up") is not None else (
            int((now - d["launched"]).total_seconds()) if d["state"] == "running" else None)
        nodes.append({
            "code": n["code"], "city": n["city"], "region": n["region"], "type": d["type"],
            "state": d["state"], "ip": d["ip"], "up": up,
            "idle": s["idle"] if s else None, "idleLimit": n.get("idle_limit"),
            "ike": s["ike"] if s else 0, "leases": s["leases"] if s else [], "load": s["load"] if s else None,
            "hours": round(hours, 2), "egressGB": round(egress, 3),
            "usd": round(hours * price + ipv4 + disk, 2),
        })

    global _last_peers
    now_s = int(now.timestamp())
    wg, names, seen = {}, {}, False
    for s in stats.values():
        if s and (s.get("wg") or s.get("names")):
            seen = True
            names.update(s.get("names") or {})
            for p in s.get("wg", []):
                wg[p["ip"]] = p
    if seen:
        peers = []
        for ip in sorted(wg, key=lambda a: tuple(int(x) for x in a.split("."))):
            p = wg[ip]
            peers.append({"n": str(int(ip.rsplit(".", 1)[1]) - 1), "ip": ip, "name": names.get(ip),
                          "hsAgo": (now_s - p["hs"]) if p["hs"] > 0 else None,
                          "rx": p["rx"], "tx": p["tx"],
                          "ep": p["ep"].rsplit(":", 1)[0] if p["ep"] not in ("", "(none)") else None})
        _last_peers = [dict(x, hsAgo=None, rx=0, tx=0) for x in peers]
    else:
        peers = _last_peers   # 서울 서버가 꺼져 있으면 마지막으로 본 목록(카운터 0)

    cutoff = now.replace(minute=0, second=0, microsecond=0) - datetime.timedelta(hours=7)
    hourly = [{"h": ts.astimezone(KST).strftime("%H"), "gb": round(v / 1e9, 3)}
              for ts, v in sorted(hourly_total.items()) if ts >= cutoff]
    egress_usd = max(0.0, egress_total - FREE_GB) * EGRESS_GB_USD
    total = sum(x["usd"] for x in nodes) + egress_usd
    return {
        "ts": now.astimezone(KST).strftime("%m-%d %H:%M:%S"),
        "nodes": nodes,
        "peers": peers,
        "hourly": hourly,
        "month": {"egressGB": round(egress_total, 3), "freeGB": FREE_GB, "egressUSD": round(egress_usd, 2),
                  "fixedUSD": round(fixed, 2), "usd": round(total, 2)},
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
        if x["idle"] is not None and x["idleLimit"]:
            bits.append("idle %d/%dm" % (x["idle"], x["idleLimit"]))
        bits.append("ike %d" % x["ike"])
        return head + "\n   " + span("dim", " · ".join(bits))
    return head + "\n   " + span("dim", "%s · boots on connect" % x["type"])


def render_html(d):
    nodes = "\n".join(node_lines(x) for x in d["nodes"])
    peers = []
    for p in d["peers"]:
        head = '%s %s %s ' % (span("k", "[peer %s]" % p["n"]), p["ip"], span("path", p.get("name") or ""))
        if p["hsAgo"] is None:
            peers.append(head + span("dim", "○ idle") + "\n  " + span("dim", "no handshake since boot"))
            continue
        st = span("ok", "● online") if p["hsAgo"] < 180 else span("warn", "○ idle")
        peers.append(head + st + "\n  " + span("dim", "↓ tx") + " " + span("num", hb(p["tx"]).rjust(10)) +
                     "   " + span("dim", "↑ rx") + " " + span("num", hb(p["rx"]).rjust(9)) + "\n  " +
                     span("dim", "hs") + " " + ago(p["hsAgo"]) + " " + span("dim", "· ep") + " " + (p["ep"] or "-"))
    hourly = d["hourly"]
    mx = max([h["gb"] for h in hourly] or [0]) or 1.0
    bars = "\n".join("%s:00 %s %s" % (h["h"], span("num", "%6.2f GB" % h["gb"]), bar(h["gb"], mx, 22))
                     for h in hourly) or span("dim", "# no datapoints yet")
    m = d["month"]
    quota = "[%s] %s/100GB %.0f%%" % (bar(min(m["egressGB"], 100), 100, 18), span("num", "%.1f" % m["egressGB"]),
                                      min(m["egressGB"], 100))
    by = " · ".join("%s %.1f" % (x["code"], x["egressGB"]) for x in d["nodes"])
    cost = "\n".join("%s %s %s  %s" % (span("k", x["code"]), span("dim", x["type"].ljust(10)),
                                        span("num", ("%.1fh" % x["hours"]).rjust(7)), span("num", "$%.2f" % x["usd"]))
                     for x in d["nodes"])
    cost += "\n%s %s" % (span("dim", "egress >100GB".ljust(23)), span("num", "$%.2f" % m["egressUSD"]))
    cost += "\n%s %s %s" % (span("k", "total"), span("dim", "≈"), span("ok", "$%.2f" % m["usd"]))
    up = sum(1 for x in d["nodes"] if x["state"] == "running")
    return (PAGE.replace("{{TS}}", d["ts"]).replace("{{UP}}", "%d/%d" % (up, len(d["nodes"])))
            .replace("{{NODES}}", nodes).replace("{{PEERS}}", "\n\n".join(peers)).replace("{{BARS}}", bars)
            .replace("{{QUOTA}}", quota).replace("{{BY}}", by).replace("{{COST}}", cost))


# ---------------------------------------------------------------- 피어 관리

class PeerError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def peer_admin(req):
    """서울 서버에서 nago-peer.py를 (설치하며) 실행하고 결과 JSON을 돌려준다."""
    op = req.get("op")
    if op not in PEER_OPS:
        raise PeerError(400, "unknown op")
    allowed = {"op", "pub", "name", "ip", "seconds"}
    req = {k: str(v)[:100] for k, v in req.items() if k in allowed}
    kr = next(n for n in NODES if n["code"] == "kr")
    d = describe(kr)
    if d["state"] != "running":
        raise PeerError(409, "kr is %s - connect once to boot it, then retry" % d["state"])
    arg = base64.b64encode(json.dumps(req).encode()).decode()
    script = ("cat > /usr/local/sbin/nago-peer <<'NAGO_PEER_EOF'\n%s\nNAGO_PEER_EOF\n"
              "chmod 0755 /usr/local/sbin/nago-peer\n/usr/local/sbin/nago-peer %s\n") % (PEER_ADMIN.rstrip("\n"), arg)
    ssm = client("ssm", kr["region"])
    cid = ssm.send_command(InstanceIds=[kr["iid"]], DocumentName="AWS-RunShellScript",
                           Parameters={"commands": [script]}, TimeoutSeconds=30,
                           Comment="nago-peer " + op)["Command"]["CommandId"]
    deadline = time.time() + 20
    while time.time() < deadline:
        time.sleep(1.0)
        try:
            inv = ssm.get_command_invocation(CommandId=cid, InstanceId=kr["iid"])
        except Exception:
            continue
        if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
            lines = (inv.get("StandardOutputContent") or "").strip().splitlines()
            try:
                out = json.loads(lines[-1])
            except (IndexError, ValueError):
                raise PeerError(502, "server: " + (inv.get("StandardErrorContent") or inv["Status"])[:200])
            if not out.get("ok"):
                raise PeerError(400, out.get("error") or "failed")
            if op == "add":
                out["endpoint"] = "%s:%s" % (d["ip"], out.get("port", 51820))
            _cache.pop("live", None)   # 다음 조회에 바로 반영
            return out
    raise PeerError(504, "server did not answer in time")


def json_response(status, data):
    return {"statusCode": status, "headers": {"content-type": "application/json", "cache-control": "no-store"},
            "body": json.dumps(data, ensure_ascii=False)}


def key_ok(event):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    key = headers.get("x-nago-key", "")
    return bool(KEY_SHA and key) and hmac.compare_digest(hashlib.sha256(key.encode()).hexdigest(), KEY_SHA)


def handle_post(event):
    # 바꾸는 요청은 비밀번호(x-nago-key)로만. 사이트 토큰(?t=)으로는 볼 수만 있다.
    if not key_ok(event):
        return json_response(403, {"ok": False, "error": "forbidden"})
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        req = json.loads(body)
        if not isinstance(req, dict):
            raise ValueError
    except ValueError:
        return json_response(400, {"ok": False, "error": "bad json"})
    try:
        return json_response(200, peer_admin(req))
    except PeerError as e:
        return json_response(e.status, {"ok": False, "error": str(e)})
    except Exception as e:
        return json_response(500, {"ok": False, "error": str(e)[:300]})


# ---------------------------------------------------------------- 진입점

def authorized(event):
    q = event.get("queryStringParameters") or {}
    if q.get("t") and hmac.compare_digest(q["t"], TOKEN):
        return True
    return key_ok(event)


def handler(event, context):
    event = event or {}
    if ((event.get("requestContext") or {}).get("http") or {}).get("method") == "POST":
        return handle_post(event)
    q = event.get("queryStringParameters") or {}
    want_json = q.get("format") == "json"
    if not authorized(event):
        if want_json:
            return {"statusCode": 403, "headers": {"content-type": "application/json"},
                    "body": json.dumps({"error": "forbidden"})}
        return {"statusCode": 403, "headers": {"content-type": "text/plain; charset=utf-8"},
                "body": "403 forbidden: bad token\n"}
    try:
        data = collect()
    except Exception as e:
        if want_json:
            return {"statusCode": 500, "headers": {"content-type": "application/json"},
                    "body": json.dumps({"error": str(e)[:300]})}
        return {"statusCode": 200, "headers": {"content-type": "text/html; charset=utf-8"},
                "body": '<pre style="background:#0a0d0a;color:#f87171;padding:16px;font-family:monospace">'
                        'panic: %s</pre>' % html.escape(str(e))}
    if want_json:
        return {"statusCode": 200, "headers": {"content-type": "application/json", "cache-control": "no-store"},
                "body": json.dumps(data, ensure_ascii=False)}
    return {"statusCode": 200, "headers": {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"},
            "body": render_html(data)}


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0d0a">
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

<span class="p">$</span> wg show wg0 <span class="dim"># kr · since boot</span>
{{PEERS}}

<span class="p">$</span> cw netout --hourly --tz=KST <span class="dim"># all nodes</span>
{{BARS}}

<span class="p">$</span> quota --egress --month
{{QUOTA}}
<span class="dim">{{BY}} GB</span>

<span class="p">$</span> cost --month --est
{{COST}}

<span class="p">nago@vpn</span>:<span class="path">~</span>$ <span class="cursor">_</span></pre>
</div><div class="hint">↻ pull to refresh</div></div></body></html>"""
