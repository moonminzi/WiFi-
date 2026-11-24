#!/usr/bin/env python3
"""NAGO share — 서울 서버에 파일을 올리고 친구에게 기간 한정 다운로드 링크를 주는 서버.

Caddy(8443)가 /share* 를 이 서버(127.0.0.1:8091)로 넘긴다. 표준 라이브러리만 쓴다.

GET  /share/?t=<TOKEN>                관리 페이지(올리기 · 목록 · 링크 복사 · 연장 · 삭제)
POST /share/api/new    {name, size, hours} → {id, link}      ┐
PUT  /share/up/<id>    파일 본문(Content-Length = size)       │ 헤더 x-nago-token: <TOKEN>
POST /share/api/list   {}            → {files, used, quota}   │ TOKEN은 대시보드와 같다
POST /share/api/delete {id}                                   │ (/etc/nago/control.json의 token)
POST /share/api/extend {id, hours}                            ┘
GET  /share/d/<id>                    받는 사람용 페이지(이름 · 크기 · 남은 기간 · 받기 버튼)
GET  /share/d/<id>/<파일 이름>         파일 본문(Range 지원 — 이어받기). 기간이 지나면 404
GET  /share/healthz

파일은 /var/lib/nago-share/<id>/{meta.json, data} 에 두고 기간이 지나면 지운다.
링크의 <id>는 추측할 수 없는 무작위 12자(72비트)라 토큰 없이 받을 수 있다.
누가 받아 가면 /etc/nago/alert.json 의 ntfy 주소로 알림을 보낸다(설정이 없으면 안 보냄).
"""
import html
import json
import os
import re
import secrets
import shutil
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("SHARE_LISTEN", "127.0.0.1:8091")
PREFIX = "/share"
DATA = os.environ.get("SHARE_DATA", "/var/lib/nago-share")
CONTROL_JSON = os.environ.get("NAGO_CONTROL", "/etc/nago/control.json")
ALERT_JSON = os.environ.get("NAGO_ALERT", "/etc/nago/alert.json")
QUOTA = int(float(os.environ.get("SHARE_MAX_GB", "25")) * 1e9)       # 올려 둔 파일 합계 한도
MIN_FREE = int(float(os.environ.get("SHARE_MIN_FREE_GB", "8")) * 1e9)  # 디스크는 이만큼 늘 남긴다(VPN·signer 몫)
MAX_HOURS = 30 * 24
HOURS = (1, 24, 72, 168, 720)            # 페이지에서 고르는 기간
DEFAULT_HOURS = 72
PENDING_SEC = 6 * 3600                   # 만들어 놓고 다 못 올린 항목은 이만큼 지나면 지운다
NOTIFY_EVERY = 600                       # 같은 파일 받기 알림은 10분에 한 번만
ID_RE = re.compile(r"[A-Za-z0-9_-]{12}")

_cache = {}
_lock = threading.Lock()
_notified = {}


class Failure(Exception):
    def __init__(self, msg, code=400):
        super().__init__(msg)
        self.code = code


def log(*a):
    print(*a, flush=True)


def token():
    """대시보드와 같은 토큰. SHARE_TOKEN 환경변수가 있으면 그것."""
    t = os.environ.get("SHARE_TOKEN")
    if t:
        return t
    hit = _cache.get("token")
    if hit and time.time() - hit[0] < 60:
        return hit[1]
    try:
        with open(CONTROL_JSON, encoding="utf-8") as f:
            t = json.load(f).get("token") or ""
    except (OSError, ValueError):
        t = ""
    _cache["token"] = (time.time(), t)
    return t


def same(a, b):
    return bool(a) and bool(b) and secrets.compare_digest(a.encode(), b.encode())


def public_base():
    try:
        with open(CONTROL_JSON, encoding="utf-8") as f:
            url = json.load(f).get("public_url") or ""
    except (OSError, ValueError):
        url = ""
    return url.rstrip("/") or "https://141.164.54.197:8443"


# MARK: - 알림 (ntfy)

def notify(title, message, priority=3, tags=None, click=None):
    """/etc/nago/alert.json {"ntfy": "https://ntfy.sh/<topic>"} 로 보낸다. 실패해도 조용히 넘어간다."""
    def go():
        try:
            with open(ALERT_JSON, encoding="utf-8") as f:
                cfg = json.load(f)
            url = (cfg.get("ntfy") or "").rstrip("/")
            if not url:
                return
            base, topic = url.rsplit("/", 1)
            body = {"topic": topic, "title": title, "message": message, "priority": priority}
            if tags:
                body["tags"] = tags
            if click:
                body["click"] = click
            req = urllib.request.Request(base + "/", data=json.dumps(body).encode(), method="POST",
                                         headers={"Content-Type": "application/json"})
            if cfg.get("ntfy_token"):
                req.add_header("Authorization", "Bearer " + cfg["ntfy_token"])
            urllib.request.urlopen(req, timeout=10).read()
        except FileNotFoundError:
            pass
        except Exception as e:
            log("notify:", repr(e))
    threading.Thread(target=go, daemon=True).start()


# MARK: - 저장

def item_dir(fid):
    return os.path.join(DATA, fid)


def read_meta(fid):
    try:
        with open(os.path.join(item_dir(fid), "meta.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_meta(meta):
    path = os.path.join(item_dir(meta["id"]), "meta.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    os.replace(tmp, path)


def all_items():
    out = []
    for fid in os.listdir(DATA):
        if ID_RE.fullmatch(fid):
            m = read_meta(fid)
            if m:
                out.append(m)
    return sorted(out, key=lambda m: m["created"], reverse=True)


def remove(fid):
    shutil.rmtree(item_dir(fid), ignore_errors=True)


def disk_free():
    st = os.statvfs(DATA)
    return st.f_bavail * st.f_frsize


def used_bytes(items=None):
    return sum(m["size"] for m in (items if items is not None else all_items()))


def clean_name(name):
    name = os.path.basename(str(name or "").replace("\\", "/"))
    name = re.sub(r"[\x00-\x1f\x7f/]+", "", name).strip().strip(".") or "file"
    if len(name) > 180:
        root, ext = os.path.splitext(name)
        name = root[:180 - len(ext[:20])] + ext[:20]
    return name


def link_of(m):
    return "%s%s/d/%s" % (public_base(), PREFIX, m["id"])


def public(m, now=None):
    now = now or time.time()
    return {"id": m["id"], "name": m["name"], "size": m["size"], "state": m["state"],
            "created": m["created"], "expires": m["expires"], "left": max(0, int(m["expires"] - now)),
            "downloads": m.get("downloads", 0), "last_dl": m.get("last_dl"), "link": link_of(m)}


def hours_of(body):
    try:
        h = int(body.get("hours") or DEFAULT_HOURS)
    except (TypeError, ValueError):
        raise Failure("bad hours")
    if not 1 <= h <= MAX_HOURS:
        raise Failure("hours must be 1..%d" % MAX_HOURS)
    return h


# MARK: - API

def api_new(body):
    name = clean_name(body.get("name"))
    try:
        size = int(body.get("size"))
    except (TypeError, ValueError):
        raise Failure("bad size")
    if size <= 0:
        raise Failure("빈 파일은 올릴 수 없어요")
    hours = hours_of(body)
    with _lock:
        items = all_items()
        used = used_bytes(items)
        if used + size > QUOTA:
            raise Failure("공간 부족: 올려 둔 파일 %s + 이 파일 %s > 한도 %s. 안 쓰는 파일을 지우세요." % (
                gb(used), gb(size), gb(QUOTA)), 413)
        if disk_free() - size < MIN_FREE:
            raise Failure("서버 디스크가 부족해요(남은 %s, %s는 늘 남겨 둠)" % (gb(disk_free()), gb(MIN_FREE)), 413)
        fid = secrets.token_urlsafe(9)
        os.makedirs(item_dir(fid), mode=0o700)
        now = time.time()
        meta = {"id": fid, "name": name, "size": size, "state": "pending", "created": now,
                "expires": now + hours * 3600, "downloads": 0, "last_dl": None}
        write_meta(meta)
    return {"id": fid, "link": link_of(meta)}


def api_list(body):
    now = time.time()
    items = [m for m in all_items() if m["state"] == "ready"]
    return {"files": [public(m, now) for m in items], "used": used_bytes(items), "quota": QUOTA,
            "free": disk_free(), "min_free": MIN_FREE, "hours": HOURS}


def get_ready(body):
    fid = str(body.get("id") or "")
    m = read_meta(fid) if ID_RE.fullmatch(fid) else None
    if not m:
        raise Failure("없는 파일", 404)
    return m


def api_delete(body):
    m = get_ready(body)
    remove(m["id"])
    log("delete %s %s" % (m["id"], m["name"]))
    return {"ok": True}


def api_extend(body):
    hours = hours_of(body)
    with _lock:
        m = get_ready(body)
        m["expires"] = time.time() + hours * 3600
        write_meta(m)
    return public(m)


def gb(n):
    n = float(n)
    if n >= 1e9:
        return "%.2fGB" % (n / 1e9)
    if n >= 1e6:
        return "%.1fMB" % (n / 1e6)
    return "%.0fKB" % (n / 1e3)


def left_text(sec):
    if sec >= 86400:
        return "%d일 %d시간" % (sec // 86400, sec % 86400 // 3600)
    if sec >= 3600:
        return "%d시간 %d분" % (sec // 3600, sec % 3600 // 60)
    return "%d분" % max(1, sec // 60)


# MARK: - 정리

def cleanup_once(now=None):
    now = now or time.time()
    n = 0
    for m in all_items():
        stale = m["state"] != "ready" and now - m["created"] > PENDING_SEC
        if now > m["expires"] or stale:
            remove(m["id"])
            n += 1
            log("expire %s %s (%s)" % (m["id"], m["name"], m["state"]))
    # meta가 없는 폴더(쓰다 만 것)
    for fid in os.listdir(DATA):
        p = item_dir(fid)
        if os.path.isdir(p) and not os.path.exists(os.path.join(p, "meta.json")) and now - os.path.getmtime(p) > 600:
            shutil.rmtree(p, ignore_errors=True)
    return n


def cleaner():
    while True:
        try:
            cleanup_once()
        except Exception as e:
            log("cleanup:", repr(e))
        time.sleep(300)


# MARK: - HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "nago-share"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json", extra=None):
        if not isinstance(body, (bytes, str)):
            body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str):
            body = body.encode("utf-8")
            ctype += "; charset=utf-8"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def parts(self):
        u = urllib.parse.urlsplit(self.path)
        return u.path, urllib.parse.parse_qs(u.query)

    def authorized(self, query=None):
        t = self.headers.get("x-nago-token") or ((query or {}).get("t") or [""])[0]
        return same(t, token())

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1 << 16:
            raise Failure("body too large")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            raise Failure("bad json")
        if not isinstance(body, dict):
            raise Failure("bad json")
        return body

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, query = self.parts()
        try:
            if path == PREFIX + "/healthz":
                return self.send(200, {"ok": True, "files": len(all_items()), "free": disk_free()})
            if path in (PREFIX, PREFIX + "/"):
                if not self.authorized(query):
                    return self.send(403, "403 forbidden: bad token\n", "text/plain")
                return self.send(200, ADMIN.replace("{{P}}", PREFIX), "text/html")
            if path.startswith(PREFIX + "/d/"):
                return self.download(path[len(PREFIX + "/d/"):])
            return self.send(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log("GET panic:", repr(e))
            traceback.print_exc()
            self.send(500, {"error": "internal"})

    def do_POST(self):
        path, _ = self.parts()
        if not self.authorized():
            return self.send(403, {"error": "forbidden"})
        fn = {PREFIX + "/api/new": api_new, PREFIX + "/api/list": api_list,
              PREFIX + "/api/delete": api_delete, PREFIX + "/api/extend": api_extend}.get(path)
        if not fn:
            return self.send(404, {"error": "not found"})
        try:
            return self.send(200, fn(self.body_json()))
        except Failure as e:
            return self.send(e.code, {"error": str(e)})
        except Exception as e:
            log("POST panic:", repr(e))
            traceback.print_exc()
            return self.send(500, {"error": "internal"})

    def do_PUT(self):
        path, _ = self.parts()
        fid = path[len(PREFIX + "/up/"):] if path.startswith(PREFIX + "/up/") else ""
        if not ID_RE.fullmatch(fid) or not self.authorized():
            return self.send(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            n = -1
        with _lock:
            m = read_meta(fid)
            if not m or m["state"] != "pending":
                return self.send(409, {"error": "이미 올렸거나 없는 항목"})
            if n != m["size"]:
                return self.send(400, {"error": "size mismatch (%d != %d)" % (n, m["size"])})
            m["state"] = "uploading"
            write_meta(m)
        dest = os.path.join(item_dir(fid), "data")
        tmp = dest + ".part"
        left, t0 = n, time.time()
        try:
            with open(tmp, "wb") as f:
                while left > 0:
                    chunk = self.rfile.read(min(1 << 20, left))
                    if not chunk:
                        raise ConnectionResetError("upload cut")
                    f.write(chunk)
                    left -= len(chunk)
            os.replace(tmp, dest)
        except Exception as e:
            remove(fid)
            log("upload failed %s: %r" % (fid, e))
            self.close_connection = True
            return
        with _lock:
            m = read_meta(fid) or m
            m["state"] = "ready"
            write_meta(m)
        log("upload %s %s %s in %.0fs" % (fid, m["name"], gb(n), time.time() - t0))
        self.send(200, public(m))

    def download(self, rest):
        fid, _, _name = rest.partition("/")
        m = read_meta(fid) if ID_RE.fullmatch(fid) else None
        now = time.time()
        if not m or m["state"] != "ready" or now > m["expires"]:
            return self.send(404, GONE, "text/html")
        if not _name:
            return self.send(200, landing(m, now), "text/html")
        full = os.path.join(item_dir(fid), "data")
        size = os.path.getsize(full)
        start, end, code = 0, size - 1, 200
        rng = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if rng and size and (rng.group(1) or rng.group(2)):
            if rng.group(1):
                start = int(rng.group(1))
                end = min(int(rng.group(2)), size - 1) if rng.group(2) else size - 1
            else:
                start = max(0, size - int(rng.group(2)))
            if start > end or start >= size:
                return self.send(416, b"", "text/plain", {"Content-Range": "bytes */%d" % size})
            code = 206
        ascii_name = re.sub(r'[^A-Za-z0-9._ -]+', "_", m["name"]) or "file"
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Disposition", "attachment; filename=\"%s\"; filename*=UTF-8''%s" % (
            ascii_name, urllib.parse.quote(m["name"])))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command == "HEAD":
            return
        if start == 0:
            self.count(m)
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(1 << 20, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)

    def count(self, m):
        with _lock:
            cur = read_meta(m["id"])
            if not cur:
                return
            cur["downloads"] = int(cur.get("downloads") or 0) + 1
            cur["last_dl"] = time.time()
            write_meta(cur)
        if time.time() - _notified.get(m["id"], 0) > NOTIFY_EVERY:
            _notified[m["id"]] = time.time()
            notify("📥 파일을 받아 갔어요", "%s (%s)\n%d번째 · 남은 기간 %s" % (
                cur["name"], gb(cur["size"]), cur["downloads"], left_text(int(cur["expires"] - time.time()))),
                priority=2, tags=["inbox_tray"])


# MARK: - 페이지

STYLE = """<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0d0a"><meta name="referrer" content="no-referrer">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&display=swap">
<style>
:root{--bg:#0a0d0a;--win:#0d110d;--edge:#1f2a1f;--fg:#c9d4c5;--dim:#5f6f5f;--ok:#4ade80;--warn:#fbbf24;--err:#f87171;--key:#67e8f9;color-scheme:dark}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg)}
body{font:14px/1.6 "JetBrains Mono",ui-monospace,Menlo,monospace;padding:24px max(16px,env(safe-area-inset-right)) 48px max(16px,env(safe-area-inset-left))}
main{max-width:680px;margin:0 auto;display:flex;flex-direction:column;gap:18px}
h1{font-size:22px;margin:8px 0 0}h1 .d{color:var(--dim)}h1 .p{color:var(--ok)}
.cur{display:inline-block;width:11px;height:22px;background:var(--ok);vertical-align:-4px;animation:b 1.1s ease-in-out infinite}
@keyframes b{50%{opacity:0}}
.label{font-size:12px;color:var(--dim);margin-bottom:8px}
.box{background:var(--win);border:1px solid var(--edge);border-radius:8px;padding:12px;display:flex;flex-direction:column;gap:10px}
.dim{color:var(--dim)}.ok{color:var(--ok)}.err{color:var(--err)}.warn{color:var(--warn)}.key{color:var(--key)}
button,.btn,select{font:600 13px "JetBrains Mono",ui-monospace,monospace;color:var(--fg);background:var(--win);border:1px solid var(--edge);
border-radius:6px;padding:8px 12px;cursor:pointer;white-space:nowrap;text-decoration:none;text-align:center}
button:focus-visible,.btn:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--ok);outline-offset:2px}
button:disabled{opacity:.35;cursor:default}
.primary{display:block;background:var(--ok);border-color:var(--ok);color:var(--bg);padding:12px;font-size:14px}
.line{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.line input[type=file]{flex:1;min-width:0}
.file{display:flex;flex-direction:column;gap:6px;overflow-wrap:anywhere}.file+.file{border-top:1px solid var(--edge);padding-top:10px}
.acts{display:flex;gap:6px;flex-wrap:wrap}.acts button{padding:6px 10px;font-size:12px}
#log{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}
.bar{height:8px;background:var(--edge);border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;width:0;background:var(--ok);transition:width .4s}
@media (prefers-reduced-motion:reduce){.cur{animation:none}}
</style>"""


def landing(m, now):
    esc = html.escape
    name = esc(m["name"])
    href = "%s/d/%s/%s" % (PREFIX, m["id"], urllib.parse.quote(m["name"]))
    return ("""<!doctype html><html lang="ko"><head><meta charset="utf-8">%s
<meta property="og:title" content="%s"><meta property="og:description" content="%s · %s 남음">
<meta name="robots" content="noindex"><title>%s</title></head><body><main>
<h1><span class="d">~/</span><span class="p">share</span><span class="d"> $ </span><span class="cur"></span></h1>
<section><div class="label">// file</div><div class="box">
<div style="overflow-wrap:anywhere"><span class="key">%s</span></div>
<div class="dim">%s · 남은 기간 %s</div>
<a class="btn primary" href="%s" download>받기</a>
<div class="dim">끊기면 다시 누르면 이어받아요(브라우저가 지원하면). 기간이 지나면 링크가 사라져요.</div>
</div></section></main></body></html>""") % (
        STYLE, name, gb(m["size"]), left_text(int(m["expires"] - now)), name, name, gb(m["size"]),
        left_text(int(m["expires"] - now)), esc(href))


GONE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">{{STYLE}}<meta name="robots" content="noindex">
<title>없는 링크</title></head><body><main>
<h1><span class="d">~/</span><span class="p">share</span><span class="d"> $ </span><span class="cur"></span></h1>
<section><div class="box"><div class="err">✗ 404 — 기간이 지났거나 지운 파일이에요.</div>
<div class="dim">보낸 사람에게 링크를 다시 달라고 하세요.</div></div></section></main></body></html>""".replace("{{STYLE}}", STYLE)


ADMIN = """<!doctype html><html lang="ko"><head><meta charset="utf-8">{{STYLE}}<meta name="robots" content="noindex">
<title>nago@share</title></head><body><main>
<h1><span class="d">~/</span><span class="p">share</span><span class="d"> $ </span><span class="cur"></span></h1>

<section><div class="label">// upload</div><div class="box">
<div class="line"><input type="file" id="file" multiple>
<select id="hours" aria-label="기간"><option value="1">1시간</option><option value="24">1일</option>
<option value="72" selected>3일</option><option value="168">7일</option><option value="720">30일</option></select>
<button id="go">올리기</button></div>
<div id="log" class="dim">파일을 고르고 기간을 정하세요. 올리고 나면 링크를 복사해서 보내면 돼요.</div>
<div class="bar" id="bar" hidden><i id="fill"></i></div>
</div></section>

<section><div class="label" id="usage">// files</div><div class="box" id="list"><div class="dim">loading…</div></div></section>
</main>
<script>
const P = "{{P}}";
const T = new URLSearchParams(location.search).get("t") || "";
const $ = s => document.querySelector(s);
const fmt = n => n >= 1e9 ? (n / 1e9).toFixed(2) + "GB" : n >= 1e6 ? (n / 1e6).toFixed(1) + "MB" : Math.max(1, Math.round(n / 1e3)) + "KB";
const left = s => s >= 86400 ? Math.floor(s / 86400) + "일 " + Math.floor(s % 86400 / 3600) + "시간" : s >= 3600 ? Math.floor(s / 3600) + "시간 " + Math.floor(s % 3600 / 60) + "분" : Math.max(1, Math.floor(s / 60)) + "분";
const dur = s => s >= 60 ? Math.floor(s / 60) + "분 " + Math.round(s % 60) + "초" : Math.round(s) + "초";
const log = (t, cls) => { const el = $("#log"); el.className = cls || ""; el.textContent = t; };
function bar(p) { const b = $("#bar"); if (p == null) { b.hidden = true; return; } b.hidden = false; $("#fill").style.width = Math.max(0, Math.min(100, p)) + "%"; }
async function api(path, body) {
  const r = await fetch(P + path, { method: "POST", headers: { "content-type": "application/json", "x-nago-token": T }, body: JSON.stringify(body || {}) });
  const j = await r.json().catch(() => ({ error: "http " + r.status }));
  if (!r.ok || j.error) throw new Error(j.error || ("http " + r.status));
  return j;
}
async function copy(text, btn) {
  try { await navigator.clipboard.writeText(text); } catch (e) {
    const t = document.createElement("textarea"); t.value = text; document.body.append(t); t.select(); document.execCommand("copy"); t.remove();
  }
  const o = btn.textContent; btn.textContent = "복사됨 ✓"; setTimeout(() => btn.textContent = o, 1500);
}
function row(f) {
  const d = document.createElement("div"); d.className = "file";
  const name = document.createElement("div"); name.className = "key"; name.textContent = f.name;
  const info = document.createElement("div"); info.className = "dim";
  info.textContent = fmt(f.size) + " · 남은 기간 " + left(f.left) + " · 받아 감 " + f.downloads + "번";
  const link = document.createElement("div"); link.className = "dim"; link.textContent = f.link;
  const acts = document.createElement("div"); acts.className = "acts";
  const b = (label, fn) => { const x = document.createElement("button"); x.textContent = label; x.onclick = () => fn(x); acts.append(x); };
  b("링크 복사", x => copy(f.link, x));
  if (navigator.share) b("공유", () => navigator.share({ title: f.name, url: f.link }).catch(() => {}));
  b("+7일", async () => { await api("/api/extend", { id: f.id, hours: 168 }).catch(e => alert(e.message)); load(); });
  b("삭제", async () => { if (!confirm(f.name + " 을(를) 지울까요? 링크도 바로 막혀요.")) return; await api("/api/delete", { id: f.id }).catch(e => alert(e.message)); load(); });
  d.append(name, info, link, acts);
  return d;
}
async function load() {
  try {
    const j = await api("/api/list");
    $("#usage").textContent = "// files · " + fmt(j.used) + " / " + fmt(j.quota) + " 사용 · 서버 디스크 " + fmt(j.free) + " 남음";
    const box = $("#list"); box.innerHTML = "";
    if (!j.files.length) { box.innerHTML = '<div class="dim">올린 파일이 없어요.</div>'; return; }
    j.files.forEach(f => box.append(row(f)));
  } catch (e) { $("#list").innerHTML = ""; const x = document.createElement("div"); x.className = "err"; x.textContent = "✗ " + e.message; $("#list").append(x); }
}
function put(id, f, onp) {
  return new Promise((ok, no) => {
    const x = new XMLHttpRequest(); x.open("PUT", P + "/up/" + id); x.setRequestHeader("x-nago-token", T);
    x.upload.onprogress = e => e.lengthComputable && onp(e.loaded, e.total);
    x.onload = () => x.status < 300 ? ok(JSON.parse(x.responseText)) : no(new Error("upload http " + x.status + " " + x.responseText));
    x.onerror = () => no(new Error("업로드 네트워크 오류"));
    x.send(f);
  });
}
$("#go").onclick = async () => {
  const files = [...$("#file").files]; if (!files.length) return;
  const hours = Number($("#hours").value);
  $("#go").disabled = true; const links = [];
  try {
    for (let i = 0; i < files.length; i++) {
      const f = files[i], tag = files.length > 1 ? "(" + (i + 1) + "/" + files.length + ") " : "";
      const n = await api("/api/new", { name: f.name, size: f.size, hours });
      const t0 = Date.now(); bar(0);
      await put(n.id, f, (done, total) => {
        const rate = done / Math.max((Date.now() - t0) / 1000, 0.1);
        bar(done / total * 100);
        log("> " + tag + f.name + "\\n  " + fmt(done) + " / " + fmt(total) + " · " + fmt(rate) + "/s · 남은 시간 " + dur((total - done) / rate) + "\\n  (올리는 동안 이 화면을 켜 두세요)", "dim");
      });
      links.push(f.name + "\\n" + n.link);
    }
    bar(100); log("[ OK ] 올렸어요. 아래 목록에서 링크를 복사하세요.\\n\\n" + links.join("\\n\\n"), "ok");
    $("#file").value = "";
  } catch (e) { bar(null); log("✗ " + e.message, "err"); }
  $("#go").disabled = false; load();
};
load(); setInterval(load, 30000);
</script></body></html>""".replace("{{STYLE}}", STYLE)


def main():
    os.makedirs(DATA, mode=0o700, exist_ok=True)
    # 서버가 재시작되면 올리던 파일은 끊긴다
    for m in all_items():
        if m["state"] == "uploading":
            remove(m["id"])
    threading.Thread(target=cleaner, daemon=True).start()
    host, port = LISTEN.rsplit(":", 1)
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    log("nago-share on %s, data %s, quota %s, keep free %s" % (LISTEN, DATA, gb(QUOTA), gb(MIN_FREE)))
    srv.serve_forever()


if __name__ == "__main__":
    main()
