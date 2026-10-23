#!/usr/bin/env python3
"""NAGO DL 엔진 시험용 HTTP 서버.

실제 서버에서 만나는 상황을 흉내 낸다:
  /file/<이름>?size=N&seed=S   결정적인 N바이트(같은 seed면 같은 내용)
    rate=B        연결 하나당 초당 B바이트로 제한(분할 다운로드가 빨라지는지 확인)
    maxconn=K     같은 파일에 동시에 K개 넘게 붙으면 503
    fail=P        P 확률로 본문 중간에 연결을 끊음
    norange=1     Range를 무시하고 항상 200 전체
    chunked=1     Content-Length 없이 chunked
    etag=V        ETag 값(바꾸면 "서버 파일이 바뀜")
    cd=이름       Content-Disposition: attachment; filename*=UTF-8''...
    h2fail=K      처음 K번 요청은 403(만료된 주소 흉내)
    slowfirst=B   이 파일의 첫 요청만 초당 B바이트(느린 연결 하나 흉내 — 동적 분할 확인)
    stallat=N&stallfor=S  N번째 바이트를 지나는 첫 요청은 거기서 S초 동안 멈춤(연결이 그냥 멈추는 상황)
  /redir?to=<경로>   302로 넘긴다
  /static/<경로>     --root 폴더의 파일(HLS 시험용, Range 지원)
  /stats            경로별 최대 동시 연결 수, 요청 수(JSON)
  /reset            통계 초기화
"""
import argparse
import json
import os
import random
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATS = {}
CONTENT = {}
COUNTERS = {}


def content(seed, size):
    key = (seed, size)
    with LOCK:
        data = CONTENT.get(key)
    if data is None:
        data = random.Random(seed).randbytes(size)
        with LOCK:
            CONTENT[key] = data
    return data


def parse_range(header, size):
    if not header or not header.startswith("bytes="):
        return None
    spec = header[6:].split(",")[0].strip()
    a, _, b = spec.partition("-")
    if a == "":
        n = int(b)
        return (max(0, size - n), size - 1)
    start = int(a)
    end = int(b) if b else size - 1
    end = min(end, size - 1)
    if start >= size or start > end:
        return "unsatisfiable"
    return (start, end)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    root = "."

    def log_message(self, fmt, *args):
        pass

    def stat(self, path, delta):
        with LOCK:
            s = STATS.setdefault(path, {"active": 0, "max": 0, "requests": 0, "ranges": []})
            s["active"] += delta
            if delta > 0:
                s["requests"] += 1
                s["max"] = max(s["max"], s["active"])
                s["ranges"].append(self.headers.get("Range"))

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        try:
            if url.path == "/stats":
                with LOCK:
                    body = json.dumps(STATS).encode()
                return self.simple(200, body, "application/json")
            if url.path == "/reset":
                with LOCK:
                    STATS.clear()
                    COUNTERS.clear()
                return self.simple(200, b"ok", "text/plain")
            if url.path == "/redir":
                self.send_response(302)
                self.send_header("Location", q.get("to", "/"))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if url.path.startswith("/file/"):
                return self.serve_file(url.path, q)
            if url.path.startswith("/static/"):
                rel = urllib.parse.unquote(url.path[len("/static/"):])
                full = os.path.realpath(os.path.join(self.root, rel))
                if not full.startswith(os.path.realpath(self.root)) or not os.path.isfile(full):
                    return self.simple(404, b"not found", "text/plain")
                with open(full, "rb") as f:
                    data = f.read()
                ctype = "application/vnd.apple.mpegurl" if full.endswith(".m3u8") else "application/octet-stream"
                return self.send_body(url.path, data, ctype, q, etag='"static"')
            return self.simple(404, b"not found", "text/plain")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def simple(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_file(self, path, q):
        size = int(q.get("size", "1048576"))
        seed = int(q.get("seed", "1"))
        etag = '"' + q.get("etag", "v1") + '"'
        key = path + "?" + q.get("etag", "v1")
        h2fail = int(q.get("h2fail", "0"))
        if h2fail:
            with LOCK:
                n = COUNTERS.get(path, 0)
                COUNTERS[path] = n + 1
            if n < h2fail:
                return self.simple(403, b"expired", "text/plain")
        maxconn = int(q.get("maxconn", "0"))
        if maxconn:
            with LOCK:
                active = STATS.get(path, {}).get("active", 0)
            if active >= maxconn:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.send_header("Retry-After", "1")
                self.end_headers()
                return
        if "slowfirst" in q:
            with LOCK:
                n = COUNTERS.get(path + "#slow", 0)
                COUNTERS[path + "#slow"] = n + 1
            if n == 0:
                q = dict(q)
                q["rate"] = q["slowfirst"]
        if "stallat" in q:
            q = dict(q)
            q["_stallkey"] = path + "#stall"
        data = content(seed, size)
        extra = {}
        if "cd" in q:
            extra["Content-Disposition"] = "attachment; filename*=UTF-8''" + urllib.parse.quote(q["cd"])
        self.send_body(path, data, "application/octet-stream", q, etag=etag, extra=extra)

    def send_body(self, path, data, ctype, q, etag, extra=None):
        size = len(data)
        rate = int(q.get("rate", "0"))
        fail = float(q.get("fail", "0"))
        norange = q.get("norange") == "1"
        chunked = q.get("chunked") == "1"
        rng = None if norange else parse_range(self.headers.get("Range"), size)
        if_range = self.headers.get("If-Range")
        if rng is not None and if_range is not None and if_range != etag:
            rng = None  # 파일이 바뀜 → 전체를 200으로
        if rng == "unsatisfiable":
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if rng is None:
            start, end, code = 0, size - 1, 200
        else:
            start, end = rng
            code = 206
        body_len = end - start + 1 if size > 0 else 0
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("ETag", etag)
        if not norange:
            self.send_header("Accept-Ranges", "bytes")
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(body_len))
        self.end_headers()
        self.stat(path, +1)
        try:
            cut = None
            if fail and random.random() < fail:
                cut = start + random.randint(0, max(0, body_len - 1))
            pos = start
            step = 16384
            t0 = time.monotonic()
            sent = 0
            stall_at = int(q["stallat"]) if "stallat" in q else None
            while pos <= end and size > 0:
                n = min(step, end - pos + 1)
                if stall_at is not None and pos <= stall_at < pos + n:
                    with LOCK:
                        first = not COUNTERS.get(q["_stallkey"])
                        COUNTERS[q["_stallkey"]] = 1
                    if first:
                        self.wfile.flush()
                        time.sleep(float(q.get("stallfor", "30")))
                if cut is not None and pos + n > cut:
                    n = cut - pos
                    if n > 0:
                        self.write_piece(data[pos:pos + n], chunked)
                    self.wfile.flush()
                    self.close_connection = True
                    try:
                        self.connection.shutdown(2)
                    except OSError:
                        pass
                    return
                self.write_piece(data[pos:pos + n], chunked)
                pos += n
                sent += n
                if rate:
                    ahead = sent / rate - (time.monotonic() - t0)
                    if ahead > 0:
                        time.sleep(ahead)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        finally:
            self.stat(path, -1)

    def write_piece(self, piece, chunked):
        if chunked:
            self.wfile.write(b"%x\r\n" % len(piece) + piece + b"\r\n")
        else:
            self.wfile.write(piece)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8711)
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    Handler.root = args.root
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.daemon_threads = True
    print("listening", args.port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
