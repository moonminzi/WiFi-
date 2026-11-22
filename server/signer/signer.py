#!/usr/bin/env python3
"""NAGO signer — IPA를 내 인증서로 서명해서 아이폰·아이패드 Safari에서 바로 설치(OTA)하게 해 주는 서버.

2026-11에 AWS(Lambda + S3 + Secrets Manager + CloudFront)에서 서울 Vultr 서버로 옮겼다.
Caddy(8443)가 /sign* 를 이 서버(127.0.0.1:8090)로 넘긴다. 표준 라이브러리만 쓴다.

GET  /sign/?t=<TOKEN>                  → 터미널 스타일 페이지(깃허브 빌드 목록 · IPA 주소 · 파일 올리기)
POST /sign/api/upload {name}           → 파일을 올릴 PUT 주소(같은 서버, 서명된 1시간 링크)
PUT  /sign/up/<key>?e=&s=              → 올린 IPA를 디스크에 바로 쓴다
POST /sign/api/sign   {source, bundle, cert} → 백그라운드 작업 시작, {job}
     source: "release:<tag>/<파일>" | "release:<tag>"(첫 IPA) | "url:<https://….ipa>" | "upload:<키>"
     bundle: "profile"(기본, 프로파일의 앱 ID로 바꿈) | "keep"(원래 번들 ID 유지)
     cert:   인증서 번호(/etc/nago/sign/certs/*.json 이름 순, 기본 0)
POST /sign/api/job    {job}            → 진행 상황, 끝나면 result.install(itms-services) · result.ipa
GET  /sign/f/<pub>/<파일>?e=&s=         → 서명본 IPA · manifest.plist (설치기가 토큰 없이 받으므로 링크에 서명)
POST 요청은 헤더 x-nago-token: <TOKEN>. TOKEN은 대시보드와 같다(/etc/nago/control.json의 token).

인증서는 /etc/nago/sign/certs/<번호>-<이름>.json: {"p12": base64, "password": "…", "profile": base64}
서명은 rcodesign(apple-codesign 0.29, musl 정적 빌드)을 부른다. 서명본·올린 파일·작업 기록은
/var/lib/nago-sign 아래에 두고 하루 뒤 지운다.

엔타이틀먼트: 앱이 원래 요청한 것 중 프로파일이 허락하는 것만 남기고, 앱 ID·팀·키체인 그룹은 프로파일에 맞춘다.
프로파일이 앱 ID 하나(와일드카드 아님)면 확장도 그 앱 ID로 서명한다(아이패드에서 설치·VPN 확인).
"""
import base64
import fnmatch
import glob
import hashlib
import hmac
import html
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("SIGN_LISTEN", "127.0.0.1:8090")
PREFIX = "/sign"
RCODESIGN = os.environ.get("RCODESIGN", "/opt/nago-sign/bin/rcodesign")
CERT_DIR = os.environ.get("SIGN_CERTS", "/etc/nago/sign/certs")
DATA = os.environ.get("SIGN_DATA", "/var/lib/nago-sign")
CONTROL_JSON = os.environ.get("NAGO_CONTROL", "/etc/nago/control.json")
GH_REPO = os.environ.get("GH_REPO", "moonminzi/WiFi-,moonminzi/Nintendo-2")
# GH_REPO 에 쉼표로 여러 저장소를 적으면 모두의 릴리스를 모아 보여준다.
GH_REPOS = [r.strip() for r in GH_REPO.split(",") if r.strip()] or [GH_REPO]
LINK_TTL = int(os.environ.get("LINK_TTL", "3600"))
KEEP_SEC = int(os.environ.get("SIGN_KEEP_SEC", str(24 * 3600)))
MAX_IPA = int(os.environ.get("MAX_IPA_MB", "8192")) * 1024 * 1024
TMP = os.path.join(DATA, "work")
# 이보다 큰 파일은 가장 빠른 압축(레벨 1)으로 묶는다(무압축은 쓰지 않는다: 받으면서 푸는 설치기 호환)
FAST_OVER = 16 * 1024 * 1024
# 깃허브 릴리스 태그 → IPA 파일 이름(목록 API가 막혔을 때 대신 쓴다)
ASSET_BY_PREFIX = {"build-": "WifiScan.ipa", "nagodl-": "NagoDL.ipa"}
# 앱 ID·팀·키체인처럼 프로파일에 맞춰 새로 정하는 키
REBUILT_KEYS = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
                "get-task-allow", "com.apple.security.application-groups", "aps-environment"}
NAME_RE = r"[A-Za-z0-9._-]+"
UPLOAD_RE = re.compile(r"uploads/[0-9a-f]{32}/%s\.ipa" % NAME_RE)
JOB_RE = re.compile(r"[0-9a-f]{32}")

_cache = {}
# 한 번에 서명 하나(디스크·CPU를 나눠 쓰지 않게). 나머지는 "대기 중"
WORKERS = ThreadPoolExecutor(max_workers=int(os.environ.get("SIGN_WORKERS", "1")))


class Failure(Exception):
    pass


def log(*a):
    print(*a, flush=True)


def token():
    """대시보드와 같은 토큰. SIGN_TOKEN 환경변수가 있으면 그것."""
    t = os.environ.get("SIGN_TOKEN")
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
    return hmac.compare_digest(hashlib.sha256(a.encode()).digest(), hashlib.sha256(b.encode()).digest())


# MARK: - 서명된 링크 (설치기·업로드는 토큰 헤더를 못 붙이므로 경로+만료에 HMAC)

def link_sig(path, exp):
    key = hashlib.sha256(("nago-sign-link:" + token()).encode()).digest()
    return hmac.new(key, ("%s|%d" % (path, exp)).encode(), hashlib.sha256).hexdigest()[:40]


def signed_path(path, ttl=LINK_TTL):
    exp = int(time.time()) + ttl
    return "%s?e=%d&s=%s" % (path, exp, link_sig(path, exp))


def link_ok(path, query):
    try:
        exp = int(query.get("e", ["0"])[0])
    except ValueError:
        return False
    s = query.get("s", [""])[0]
    return bool(token()) and exp >= time.time() and hmac.compare_digest(s, link_sig(path, exp))


def public_base():
    """https://<서울 IP>:8443 (control.json의 public_url)"""
    try:
        with open(CONTROL_JSON, encoding="utf-8") as f:
            url = json.load(f).get("public_url") or ""
    except (OSError, ValueError):
        url = ""
    return url.rstrip("/") or "https://141.164.54.197:8443"


# MARK: - 진행 상황 (백그라운드 작업이 jobs/<job>.json 에 쓰고, 페이지가 1초마다 읽는다)

# (단계, 전체 중 비중 %)
PHASES = (("download", 25), ("unzip", 15), ("sign", 15), ("zip", 45))
LOCAL_PHASES = (("unzip", 30), ("sign", 20), ("zip", 50))


def job_file(job):
    return os.path.join(DATA, "jobs", job + ".json")


def write_json(path, obj):
    tmp = "%s.%s.tmp" % (path, uuid.uuid4().hex[:6])
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


class Progress:
    def __init__(self, job=None, source=""):
        self.path = job_file(job) if job else None
        now = time.time()
        self.s = {"job": job, "source": source, "status": "running", "phase": "queued", "done": 0, "total": 0,
                  "estimated": False, "percent": 0.0, "rate": 0.0, "eta": None,
                  "started": now, "phase_started": now, "updated": now}
        self._lock = threading.Lock()
        self._last = 0.0
        self.phases = PHASES

    def phase(self, name, total=0, estimated=False):
        with self._lock:
            self.s.update(phase=name, done=0, total=int(total or 0), estimated=estimated,
                          phase_started=time.time(), rate=0.0, eta=None)
        self.flush(force=True)

    def _set(self, done):
        s = self.s
        s["done"] = done
        el = time.time() - s["phase_started"]
        s["rate"] = done / el if el > 0.5 else 0.0
        s["eta"] = round((s["total"] - done) / s["rate"]) if s["rate"] > 0 and s["total"] > done else None
        if s["estimated"] and s["total"] and done >= int(0.95 * s["total"]):
            s["eta"] = None  # 어림치를 넘겼다: "마무리 중"으로 보인다

    def add(self, n):
        with self._lock:
            self._set(self.s["done"] + n)
        self.flush()

    def set(self, done):
        with self._lock:
            self._set(done)
        self.flush()

    def percent(self):
        acc = 0.0
        for name, weight in self.phases:
            if name == self.s["phase"]:
                frac = self.s["done"] / self.s["total"] if self.s["total"] else 0.0
                return round(acc + weight * min(1.0, frac), 1)
            acc += weight
        return 100.0 if self.s["status"] == "done" else 0.0

    def flush(self, force=False):
        if not self.path:
            return
        with self._lock:
            now = time.time()
            if not force and now - self._last < 1.0:
                return
            self._last = now
            self.s["updated"] = now
            self.s["percent"] = self.percent()
            snap = dict(self.s)
        try:
            write_json(self.path, snap)
        except OSError as e:
            log("progress write failed:", repr(e))

    def finish(self, **fields):
        with self._lock:
            self.s.update(fields)
        self.flush(force=True)


NOPROG = Progress()


# MARK: - 인증서/프로파일

def plist_in(data):
    """서명(CMS)으로 감싼 프로비저닝 프로파일에서 plist만 꺼낸다."""
    start, end = data.find(b"<?xml"), data.find(b"</plist>")
    if start < 0 or end < 0:
        raise Failure("provisioning profile: plist not found")
    return plistlib.loads(data[start:end + len(b"</plist>")])


class Identity:
    def __init__(self, p12, password, profile):
        self.p12, self.password, self.profile_data = p12, password, profile
        self.profile = plist_in(profile)
        ents = self.profile.get("Entitlements", {})
        self.ents = ents
        self.team = (self.profile.get("TeamIdentifier") or [""])[0]
        full = ents.get("application-identifier", "")
        self.app_id = full.split(".", 1)[1] if "." in full else full
        self.wildcard = self.app_id.endswith("*")
        self.devices = self.profile.get("ProvisionedDevices") or []
        self.expires = self.profile.get("ExpirationDate")

    @property
    def kind(self):
        if self.profile.get("ProvisionsAllDevices"):
            return "enterprise"
        return "development" if self.ents.get("get-task-allow") else "ad-hoc"

    def summary(self):
        days = int((self.expires.timestamp() - time.time()) // 86400) if self.expires else None
        return {"team": self.profile.get("TeamName", ""), "team_id": self.team, "app_id": self.app_id,
                "kind": self.kind, "devices": self.devices,
                "expires": self.expires.strftime("%Y-%m-%d") if self.expires else "", "days_left": days}


def cert_files():
    return sorted(glob.glob(os.path.join(CERT_DIR, "*.json")))


def cert_name(path):
    return re.sub(r"^\d+-", "", os.path.basename(path)[:-5])


def identity(index=0):
    files = cert_files()
    if not 0 <= index < len(files):
        raise Failure("unknown cert: %d" % index)
    path = files[index]
    mtime = os.path.getmtime(path)
    key = "identity:" + path
    hit = _cache.get(key)
    if not hit or hit[0] != mtime:
        with open(path, encoding="utf-8") as f:
            s = json.load(f)
        hit = (mtime, Identity(base64.b64decode(s["p12"]), s["password"], base64.b64decode(s["profile"])))
        _cache[key] = hit
    return hit[1]


# MARK: - 엔타이틀먼트

ENTITLEMENTS_MAGIC = 0xFADE7171


def entitlements_of(executable):
    """Mach-O 서명 안의 XML 엔타이틀먼트 블롭(0xfade7171)을 읽는다. 없으면 {}."""
    try:
        with open(executable, "rb") as f:
            data = f.read()
    except OSError:
        return {}
    i = data.find(struct.pack(">I", ENTITLEMENTS_MAGIC))
    while i >= 0:
        (length,) = struct.unpack(">I", data[i + 4:i + 8])
        body = data[i + 8:i + length]
        if body.lstrip().startswith(b"<?xml"):
            try:
                return plistlib.loads(body)
            except Exception:
                pass
        i = data.find(struct.pack(">I", ENTITLEMENTS_MAGIC), i + 4)
    return {}


def allowed(value, rule):
    """프로파일 값(rule)이 앱이 요청한 값(value)을 허락하는지. 허락된 부분만 돌려준다(없으면 None)."""
    if isinstance(rule, bool):
        return value if rule else None
    if isinstance(rule, str):
        if rule == "*" or (rule.endswith("*") and isinstance(value, str) and fnmatch.fnmatch(value, rule)):
            return value
        return value if value == rule else None
    if isinstance(rule, list):
        patterns = [r for r in rule if isinstance(r, str)]
        items = value if isinstance(value, list) else [value]
        kept = [v for v in items if v in rule or (isinstance(v, str) and any(fnmatch.fnmatch(v, p) for p in patterns))]
        if not kept:
            return None
        return kept if isinstance(value, list) else kept[0]
    return value if value == rule else None


def entitlements_for(original, ident, app_identifier):
    out = {}
    for key, value in original.items():
        if key in REBUILT_KEYS or key not in ident.ents:
            continue
        kept = allowed(value, ident.ents[key])
        if kept is not None:
            out[key] = kept
    out["application-identifier"] = app_identifier
    out["com.apple.developer.team-identifier"] = ident.team
    out["keychain-access-groups"] = [app_identifier]
    out["get-task-allow"] = bool(ident.ents.get("get-task-allow", False))
    if "aps-environment" in original and "aps-environment" in ident.ents:
        out["aps-environment"] = ident.ents["aps-environment"]
    # 앱 그룹은 원래 앱에 없어도 프로파일에 있으면 넣는다: 같은 인증서로 서명한 게임들이 공유 창고(세이브 통합 보관)를 쓰게
    if ident.ents.get("com.apple.security.application-groups"):
        out["com.apple.security.application-groups"] = list(ident.ents["com.apple.security.application-groups"])
    return out


# MARK: - IPA 풀기/묶기 (실행 권한과 심볼릭 링크를 지킨다)

_PUNCH = True


def punch(fd, off, length):
    """파일의 [off, off+length) 디스크 공간을 돌려준다(파일 크기는 그대로). 지원 안 되면 조용히 넘어간다."""
    global _PUNCH
    if not _PUNCH or length <= 0:
        return
    try:
        if _PUNCH is True:
            import ctypes
            import ctypes.util
            libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
            libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]
            _PUNCH = libc.fallocate
        if _PUNCH(fd, 0x01 | 0x02, off, length) != 0:  # FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
            _PUNCH = None
    except Exception:
        _PUNCH = None


FREE_EVERY = 64 << 20


def _extract(z, info, dest, prog, fd=None):
    name = info.filename
    if name.startswith("/") or ".." in name.split("/"):
        raise Failure("bad path in ipa: " + name)
    target = os.path.join(dest, name)
    mode = (info.external_attr >> 16) & 0xFFFF
    if name.endswith("/"):
        os.makedirs(target, exist_ok=True)
        return
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if stat.S_ISLNK(mode):
        os.symlink(z.read(info).decode(), target)
        return
    with z.open(info) as src, open(target, "wb") as dst:
        last, since = info.header_offset, 0
        while chunk := src.read(1 << 20):
            dst.write(chunk)
            prog.add(len(chunk))
            since += len(chunk)
            if fd is not None and since >= FREE_EVERY:
                since = 0
                try:
                    safe = src._fileobj.tell() - (4 << 20)  # 이미 읽어 들인 원본 위치(읽기 버퍼만큼 여유)
                except Exception:
                    safe = 0
                if safe - last >= (32 << 20):
                    punch(fd, last, safe - last)
                    last = safe
    os.chmod(target, (mode & 0o777) or 0o644)


def unzip(path, dest, prog=None, free=False):
    """free=True: 다 푼 항목의 자리는 원본 IPA에서 바로 비운다(원본과 풀린 파일이 디스크를 두 배로 먹지 않게)."""
    prog = prog or NOPROG
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        raise Failure("not an ipa (not a zip file)")
    with z:
        infos = sorted(z.infolist(), key=lambda i: i.header_offset)
        prog.phase("unzip", sum(i.file_size for i in infos))
        ends = [i.header_offset for i in infos[1:]] + [z.start_dir]
        fd = os.open(path, os.O_RDWR) if free else None
        try:
            for info, end in zip(infos, ends):
                _extract(z, info, dest, prog, fd)
                if fd is not None:
                    punch(fd, info.header_offset, end - info.header_offset)
        finally:
            if fd is not None:
                os.close(fd)


def zip_dir(src, path, prog=None, consume=False):
    """consume=True: zip에 넣은 파일은 바로 지운다(풀린 파일과 새 IPA가 디스크를 두 배로 먹지 않게)."""
    prog = prog or NOPROG
    total = 0
    for root, _, files in os.walk(src):
        for f in files:
            st = os.lstat(os.path.join(root, f))
            if not stat.S_ISLNK(st.st_mode):
                total += st.st_size
    prog.phase("zip", total)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            for d in dirs:
                full = os.path.join(root, d)
                info = zipfile.ZipInfo(os.path.relpath(full, src) + "/")
                info.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                z.writestr(info, b"")
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src)
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    info = zipfile.ZipInfo(rel)
                    info.external_attr = (stat.S_IFLNK | 0o755) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    z.writestr(info, os.readlink(full))
                else:
                    info = zipfile.ZipInfo.from_file(full, rel, strict_timestamps=False)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    level = 1 if st.st_size >= FAST_OVER else 6
                    try:
                        info.compress_level = level      # Python 3.13+
                    except AttributeError:
                        pass
                    info._compresslevel = level          # Python 3.10~3.12
                    with open(full, "r+b" if consume else "rb") as fsrc, z.open(info, "w") as fdst:
                        last, since = 0, 0
                        while chunk := fsrc.read(1 << 20):
                            fdst.write(chunk)
                            prog.add(len(chunk))
                            since += len(chunk)
                            if consume and since >= FREE_EVERY:
                                since = 0
                                pos = fsrc.tell()
                                punch(fsrc.fileno(), last, pos - last)
                                last = pos
                    if consume:
                        os.remove(full)


# MARK: - 서명

def bundles_in(app):
    """서명할 실행 번들(메인 앱 + 확장/워치/앱 클립), 바깥쪽부터. (상대 경로, 절대 경로)"""
    found = [("", app)]
    for root, dirs, _ in os.walk(app):
        for d in sorted(dirs):
            if d.endswith((".appex", ".app")) and os.path.exists(os.path.join(root, d, "Info.plist")):
                full = os.path.join(root, d)
                found.append((os.path.relpath(full, app), full))
    return found


def read_info(bundle):
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        return plistlib.load(f)


def write_info(bundle, info):
    with open(os.path.join(bundle, "Info.plist"), "wb") as f:
        plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)


def sign_ipa(src_ipa, out_ipa, ident, bundle_mode="profile", prog=None):
    """src_ipa(지워도 되는 사본)를 풀어 서명하고 out_ipa(경로, 또는 meta를 받아 경로를 돌려주는 함수)에 묶는다."""
    prog = prog or NOPROG
    work = os.path.join(TMP, "sign-" + uuid.uuid4().hex[:8])
    os.makedirs(work)
    try:
        unzip(src_ipa, work, prog, free=True)
        # 원본·풀린 것·새 IPA가 동시에 디스크에 있지 않게: 풀고 나면 원본은 지운다
        try:
            os.remove(src_ipa)
        except OSError:
            pass
        apps = [d for d in os.listdir(os.path.join(work, "Payload")) if d.endswith(".app")] \
            if os.path.isdir(os.path.join(work, "Payload")) else []
        if len(apps) != 1:
            raise Failure("not an ipa (Payload/*.app not found)")
        app = os.path.join(work, "Payload", apps[0])
        main_info = read_info(app)
        old_main = main_info["CFBundleIdentifier"]
        rename = bundle_mode == "profile" and not ident.wildcard
        new_main = ident.app_id if rename else old_main

        p12 = os.path.join(work, "cert.p12")
        pw = os.path.join(work, "p12pass")
        for path, data in ((p12, ident.p12), (pw, ident.password.encode())):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)

        args = [RCODESIGN, "sign", "--p12-file", p12, "--p12-password-file", pw, "--timestamp-url", "none"]
        for rel, bundle in bundles_in(app):
            info = read_info(bundle)
            old_id = info.get("CFBundleIdentifier", "")
            if rename:
                new_id = new_main if not rel else (
                    new_main + old_id[len(old_main):] if old_id.startswith(old_main + ".")
                    else new_main + "." + old_id.rsplit(".", 1)[-1])
            else:
                new_id = old_id
            if new_id != old_id:
                info["CFBundleIdentifier"] = new_id
            if rename and info.get("WKCompanionAppBundleIdentifier") == old_main:
                info["WKCompanionAppBundleIdentifier"] = new_main
            write_info(bundle, info)
            app_identifier = ident.team + "." + (new_id if ident.wildcard else ident.app_id)
            exe = os.path.join(bundle, info.get("CFBundleExecutable", ""))
            ents = entitlements_for(entitlements_of(exe), ident, app_identifier)
            ent_path = os.path.join(work, "ent-%d.plist" % len(args))
            with open(ent_path, "wb") as f:
                plistlib.dump(ents, f)
            with open(os.path.join(bundle, "embedded.mobileprovision"), "wb") as f:
                f.write(ident.profile_data)
            shutil.rmtree(os.path.join(bundle, "_CodeSignature"), ignore_errors=True)
            # 실행 파일에만(번들 전체에 주면 안에 든 프레임워크까지 엔타이틀먼트가 붙는다)
            args += ["-e", os.path.join(rel, info.get("CFBundleExecutable", "")) + ":" + ent_path]
            log("bundle %s → %s" % (old_id, new_id))
        args.append(app)
        # rcodesign은 진행률을 내지 않으므로 앱 크기로 걸릴 시간을 어림해 보여준다(최대 95%)
        app_bytes = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(app) for f in fs
                        if not os.path.islink(os.path.join(r, f)))
        prog.phase("sign", app_bytes, estimated=True)
        guess = max(10.0, app_bytes / (60 * 1024 * 1024))
        logf = work + ".rcodesign.log"
        try:
            with open(logf, "w+") as lf:
                proc = subprocess.Popen(args, stdout=lf, stderr=subprocess.STDOUT, text=True)
                t0 = time.time()
                while proc.poll() is None:
                    if time.time() - t0 > 1800:
                        proc.kill()
                        raise Failure("rcodesign: timed out")
                    prog.set(int(app_bytes * min(0.95, (time.time() - t0) / guess)))
                    time.sleep(1)
                lf.seek(0)
                output = lf.read()
        finally:
            for path in (p12, pw, logf):
                try:
                    os.remove(path)
                except OSError:
                    pass
        if proc.returncode != 0:
            raise Failure("rcodesign: " + output[-600:])
        prog.set(app_bytes)
        for f in os.listdir(work):
            if f.startswith("ent-"):
                os.remove(os.path.join(work, f))
        meta = {"bundle_id": new_main, "title": main_info.get("CFBundleDisplayName") or main_info.get("CFBundleName") or apps[0][:-4],
                "version": main_info.get("CFBundleShortVersionString", ""), "build": main_info.get("CFBundleVersion", "")}
        target = out_ipa(meta) if callable(out_ipa) else out_ipa
        try:
            zip_dir(work, target, prog, consume=True)
        except BaseException:
            try:
                os.remove(target)
            except OSError:
                pass
            raise
        return meta
    finally:
        shutil.rmtree(work, ignore_errors=True)


# MARK: - 가져오기

def http_get(url, dest=None, limit=MAX_IPA, prog=None):
    if not url.startswith("https://"):
        raise Failure("https only")
    req = urllib.request.Request(url, headers={"User-Agent": "nago-signer", "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=60) as r:
        if dest is None:
            return r.read(limit)
        prog = prog or NOPROG
        length = int(r.headers.get("Content-Length") or 0)
        if length > limit:
            raise Failure("ipa too large")
        prog.phase("download", length)
        total = 0
        with open(dest, "wb") as f:
            while chunk := r.read(1 << 20):
                total += len(chunk)
                if total > limit:
                    raise Failure("ipa too large")
                f.write(chunk)
                prog.add(len(chunk))
        return total


def releases():
    """GH_REPOS 각 저장소의 최근 릴리스 중 IPA가 있는 것. 5분 캐시, API가 막히면 Atom 피드로."""
    hit = _cache.get("releases")
    if hit and time.time() - hit[0] < 300:
        return hit[1]
    out = []
    for repo in GH_REPOS:
        try:
            data = json.loads(http_get("https://api.github.com/repos/%s/releases?per_page=12" % repo, limit=4 << 20))
            for r in data:
                for a in r.get("assets", []):
                    if a["name"].endswith(".ipa"):
                        out.append({"repo": repo, "tag": r["tag_name"], "date": (r.get("published_at") or "")[:10],
                                    "asset": a["name"], "size": a.get("size", 0), "url": a["browser_download_url"]})
        except Exception:
            try:
                feed = http_get("https://github.com/%s/releases.atom" % repo, limit=4 << 20).decode("utf-8", "replace")
                for entry in feed.split("<entry>")[1:]:
                    tag = re.search(r"/releases/tag/([^\"<]+)\"", entry)
                    date = re.search(r"<updated>(\d{4}-\d\d-\d\d)", entry)
                    tag, date = (tag.group(1) if tag else ""), (date.group(1) if date else "")
                    asset = next((n for p, n in ASSET_BY_PREFIX.items() if tag.startswith(p)), None)
                    if asset:
                        out.append({"repo": repo, "tag": tag, "date": date, "asset": asset, "size": 0,
                                    "url": "https://github.com/%s/releases/download/%s/%s" % (repo, tag, asset)})
            except Exception:
                pass
    out.sort(key=lambda r: r["date"], reverse=True)
    _cache["releases"] = (time.time(), out)
    return out


def check_source(source):
    kind, _, value = source.partition(":")
    if kind not in ("upload", "release", "url") or not value:
        raise Failure("unknown source")
    if kind == "upload" and not UPLOAD_RE.fullmatch(value):
        raise Failure("bad upload key")
    if kind == "url" and not value.startswith("https://"):
        raise Failure("https only")
    if kind == "release":
        tag, _, want = value.partition("/")
        if not re.fullmatch(NAME_RE, tag) or (want and not re.fullmatch(NAME_RE + r"\.ipa", want)):
            raise Failure("bad release")
    return kind, value


def fetch(source, dest, prog=None):
    """dest에 IPA 사본을 둔다. 올린 파일은 옮기기만 한다(내려받기 단계 없음 → True)."""
    prog = prog or NOPROG
    kind, value = check_source(source)
    if kind == "upload":
        path = os.path.join(DATA, value)
        if not os.path.isfile(path):
            raise Failure("upload not found (expired?)")
        os.replace(path, dest)
        shutil.rmtree(os.path.dirname(path), ignore_errors=True)
        return os.path.getsize(dest), True
    if kind == "release":
        # 릴리스 하나에 IPA가 여럿일 수 있다(유저용·관리자용) — 파일 이름까지 맞춰 고른다
        tag, _, want = value.partition("/")
        try:
            hit = next((r for r in releases() if r["tag"] == tag and (not want or r["asset"] == want)), None)
        except Exception:
            hit = None
        if hit:
            url = hit["url"]
        else:
            asset = want or next((n for p, n in ASSET_BY_PREFIX.items() if tag.startswith(p)), None)
            if not asset:
                raise Failure("unknown release: " + tag)
            url = "https://github.com/%s/releases/download/%s/%s" % (GH_REPOS[0], tag, asset)
        return http_get(url, dest, prog=prog), False
    return http_get(value, dest, prog=prog), False


# MARK: - 설치 링크

def manifest(ipa_url, meta):
    return plistlib.dumps({"items": [{
        "assets": [{"kind": "software-package", "url": ipa_url}],
        "metadata": {"bundle-identifier": meta["bundle_id"], "bundle-version": meta["version"] or meta["build"] or "1",
                     "kind": "software", "title": meta["title"]},
    }]})


def fresh_links(r):
    """완료된 작업을 나중에 다시 열어도 설치되도록 링크를 새로 만든다(manifest 안의 IPA 링크도)."""
    base = public_base()
    ipa_url = base + signed_path(PREFIX + "/f/" + r["ipa_key"])
    meta = {k: r.get(k, "") for k in ("bundle_id", "title", "version", "build")}
    write_bytes(os.path.join(DATA, "signed", r["man_key"]), manifest(ipa_url, meta))
    r["ipa"] = ipa_url
    r["install"] = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(
        base + signed_path(PREFIX + "/f/" + r["man_key"]), safe="")
    r["expires"] = int(time.time()) + LINK_TTL
    return r


def write_bytes(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


# MARK: - API

def api_upload(body):
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.basename(body.get("name") or "app.ipa")).strip("-")
    if not name.endswith(".ipa"):
        name += ".ipa"
    key = "uploads/%s/%s" % (uuid.uuid4().hex, name)
    return {"key": key, "url": signed_path(PREFIX + "/up/" + key, ttl=6 * 3600)}


def api_sign(body):
    """서명은 백그라운드 작업으로 돌린다. 작업 번호를 바로 돌려준다."""
    source = str(body.get("source") or "")
    check_source(source)
    mode = "keep" if body.get("bundle") == "keep" else "profile"
    try:
        cert = int(body.get("cert") or 0)
    except (TypeError, ValueError):
        raise Failure("bad cert")
    if not 0 <= cert < len(cert_files()):
        raise Failure("unknown cert: %d" % cert)
    job = uuid.uuid4().hex
    Progress(job, source).flush(force=True)
    WORKERS.submit(run_job, job, source, mode, cert)
    return {"job": job}


def run_job(job, source, mode, cert):
    prog = Progress(job, source)
    prog.phase("starting")
    work = os.path.join(TMP, "job-" + job[:8])
    os.makedirs(work, exist_ok=True)
    t0 = time.time()
    try:
        ident = identity(cert)
        src = os.path.join(work, "in.ipa")
        if source.startswith("upload:"):
            prog.phases = LOCAL_PHASES
        size, _ = fetch(source, src, prog)
        pub = uuid.uuid4().hex
        made = []

        def target(meta):
            safe = re.sub(r"[^A-Za-z0-9._-]+", "-", meta["title"]).strip("-") or "app"
            os.makedirs(os.path.join(DATA, "signed", pub), exist_ok=True)
            made.append("%s/%s.ipa" % (pub, safe))
            return os.path.join(DATA, "signed", made[0])
        meta = sign_ipa(src, target, ident, mode, prog=prog)
        result = fresh_links({**meta, "ipa_key": made[0], "man_key": "%s/manifest.plist" % pub})
        result.update(source=source, size=size, seconds=round(time.time() - t0, 1))
        prog.finish(status="done", phase="done", result=result, eta=None)
        log("job %s done: %s %s in %.0fs" % (job[:8], meta["bundle_id"], meta["version"], time.time() - t0))
    except Exception as e:
        log("job %s failed: %r" % (job[:8], e))
        if not isinstance(e, Failure):
            traceback.print_exc()
        msg = str(e) if isinstance(e, Failure) else "%s: %s" % (type(e).__name__, str(e)[:300])
        prog.finish(status="error", error=msg, eta=None)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def api_job(body):
    job = str(body.get("job") or "")
    if not JOB_RE.fullmatch(job):
        raise Failure("bad job")
    try:
        with open(job_file(job), encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        raise Failure("unknown job")
    # 대기 중인 작업은 앞 작업이 끝날 때까지 기록이 안 바뀐다 → 멈춤으로 보지 않는다
    if st.get("status") == "running" and st.get("phase") != "queued" and time.time() - st.get("updated", 0) > 180:
        st.update(status="error", error="작업이 멈췄어요(시간 초과 또는 서버 재시작). 다시 시도하세요.")
    if st.get("status") == "done" and (st.get("result") or {}).get("man_key"):
        try:
            st["result"] = fresh_links(st["result"])
        except Exception as e:
            log("refresh links failed:", repr(e))
            st.update(status="error", error="서명본이 지워졌어요(하루 지남). 다시 서명하세요.")
    st["now"] = time.time()
    return st


# MARK: - 정리 (하루 지난 서명본·올린 파일·작업 기록, 서버가 재시작돼 끊긴 작업 파일)

def cleanup_once(now=None):
    now = now or time.time()
    for sub in ("signed", "uploads", "jobs"):
        root = os.path.join(DATA, sub)
        for name in os.listdir(root):
            path = os.path.join(root, name)
            try:
                if now - os.path.getmtime(path) > KEEP_SEC:
                    shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) else os.remove(path)
            except OSError:
                pass


def cleaner():
    while True:
        try:
            cleanup_once()
        except Exception as e:
            log("cleanup:", repr(e))
        time.sleep(3600)


# MARK: - HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "nago-sign"
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
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def parts(self):
        u = urllib.parse.urlsplit(self.path)
        return u.path, urllib.parse.parse_qs(u.query)

    def authorized(self, query):
        t = self.headers.get("x-nago-token") or query.get("t", [""])[0]
        return bool(token()) and same(t, token())

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1 << 20:
            raise Failure("body too large")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            raise Failure("bad json")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path, query = self.parts()
        try:
            if path.startswith(PREFIX + "/f/"):
                return self.serve_file(path, query)
            if path == PREFIX + "/healthz":
                return self.send(200, {"ok": True, "certs": len(cert_files())})
            if path in (PREFIX, PREFIX + "/"):
                if not self.authorized(query):
                    return self.send(403, "403 forbidden: bad token\n", "text/plain")
                return self.send(200, render(), "text/html")
            return self.send(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log("GET panic:", repr(e))
            traceback.print_exc()
            self.send(500, {"error": "%s: %s" % (type(e).__name__, str(e)[:300])})

    def do_POST(self):
        path, query = self.parts()
        if not self.authorized(query):
            return self.send(403, {"error": "forbidden"})
        try:
            fn = {PREFIX + "/api/upload": api_upload, PREFIX + "/api/sign": api_sign,
                  PREFIX + "/api/job": api_job}.get(path)
            if not fn:
                return self.send(404, {"error": "not found"})
            return self.send(200, fn(self.body_json()))
        except Failure as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:
            log("POST panic:", repr(e))
            traceback.print_exc()
            return self.send(500, {"error": "%s: %s" % (type(e).__name__, str(e)[:300])})

    def do_PUT(self):
        path, query = self.parts()
        key = path[len(PREFIX + "/up/"):] if path.startswith(PREFIX + "/up/") else ""
        if not UPLOAD_RE.fullmatch(key) or not link_ok(path, query):
            return self.send(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            n = -1
        if n < 0:
            return self.send(411, {"error": "content-length required"})
        if n > MAX_IPA:
            return self.send(413, {"error": "ipa too large"})
        dest = os.path.join(DATA, key)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".part"
        left = n
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
            shutil.rmtree(os.path.dirname(dest), ignore_errors=True)
            log("upload failed:", repr(e))
            self.close_connection = True
            return
        log("upload %s %.1fMB" % (key, n / 1048576))
        self.send(200, {"ok": True, "size": n})

    def serve_file(self, path, query):
        rel = path[len(PREFIX + "/f/"):]
        if not re.fullmatch(r"[0-9a-f]{32}/%s" % NAME_RE, rel) or not link_ok(path, query):
            return self.send(403, "403 forbidden: link expired\n", "text/plain")
        full = os.path.join(DATA, "signed", rel)
        if not os.path.isfile(full):
            return self.send(404, "404: gone (signed builds are kept 1 day)\n", "text/plain")
        size = os.path.getsize(full)
        ctype = "text/xml" if rel.endswith(".plist") else "application/octet-stream"
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
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        if rel.endswith(".ipa"):
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % rel.split("/", 1)[1])
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(1 << 20, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


# MARK: - 페이지

def render():
    try:
        rels, rel_err = releases(), ""
    except Exception as e:
        rels, rel_err = [], str(e)
    esc = html.escape
    certs, files, picked = [], cert_files(), False
    for i, path in enumerate(files):
        try:
            who = identity(i).summary()
        except Exception as e:
            certs.append('<label class="cert"><input type="radio" name="cert" value="%d" disabled> '
                         '<span class="err">✗ %s</span> <span class="dim">%s</span></label>' % (i, esc(cert_name(path)), esc(str(e)[:200])))
            continue
        # 첫 번째로 쓸 수 있는 인증서를 기본 선택
        pick = "" if picked else " checked"
        picked = True
        dev = who["devices"]
        days = who["days_left"]
        certs.append(('<label class="cert"><input type="radio" name="cert" value="%d"%s> <span>'
                      '<span class="ok">[ OK ]</span> %s <span class="dim">(%s)</span><br>'
                      '<span class="dim">%s · %s · expires %s%s</span><br>'
                      '<span class="dim">app id <span class="key">%s</span></span></span></label>') % (
            i, pick, esc(who["team"]), esc(who["team_id"]), esc(who["kind"]),
            ("%d device" % len(dev) + ("s" if len(dev) != 1 else "") + (" (" + esc(dev[0][-8:]) + ")" if len(dev) == 1 else ""))
            if dev else "all devices",
            esc(who["expires"]), (" (%dd left)" % days) if days is not None else "", esc(who["app_id"])))
    if not certs:
        certs.append('<div class="err">✗ no cert in %s</div>' % esc(CERT_DIR))
    rows = []
    for r in rels[:10]:
        size = (" · %.1fMB" % (r["size"] / 1048576)) if r["size"] else ""
        rows.append('<div class="rel"><div><span class="key">%s</span> <span class="dim">%s · %s%s</span></div>'
                    '<button data-src="release:%s/%s">sign</button></div>' % (
                        esc(r["tag"]), esc(r["asset"]), esc(r["date"]), size, esc(r["tag"]), esc(r["asset"])))
    if not rows:
        rows.append('<div class="row dim">no releases%s</div>' % ((" (" + esc(rel_err) + ")") if rel_err else ""))
    return PAGE.replace("{{CERT}}", "".join(certs)).replace("{{RELEASES}}", "".join(rows)).replace(
        "{{REPO}}", esc(", ".join(GH_REPOS))).replace("{{TTL}}", str(LINK_TTL // 60)).replace("{{P}}", PREFIX)


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0d0a"><meta name="referrer" content="no-referrer"><title>nago@sign</title>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&display=swap">
<style>
/* 대시보드·앱과 같은 터미널 팔레트(다크 하나) */
:root{--bg:#0a0d0a;--win:#0d110d;--edge:#1f2a1f;--fg:#c9d4c5;--dim:#5f6f5f;--ok:#4ade80;--warn:#fbbf24;--err:#f87171;
--key:#67e8f9;color-scheme:dark}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg)}
body{font:14px/1.6 "JetBrains Mono",ui-monospace,Menlo,monospace;padding:24px max(16px,env(safe-area-inset-right)) 48px max(16px,env(safe-area-inset-left))}
main{max-width:680px;margin:0 auto;display:flex;flex-direction:column;gap:18px}
h1{font-size:22px;margin:8px 0 0}h1 .d{color:var(--dim)}h1 .p{color:var(--ok)}
.cur{display:inline-block;width:11px;height:22px;background:var(--ok);vertical-align:-4px;animation:b 1.1s ease-in-out infinite}
@keyframes b{50%{opacity:0}}
.label{font-size:12px;color:var(--dim);margin-bottom:8px}
.box{background:var(--win);border:1px solid var(--edge);border-radius:8px;padding:12px;display:flex;flex-direction:column;gap:10px}
.dim{color:var(--dim)}.ok{color:var(--ok)}.err{color:var(--err)}.warn{color:var(--warn)}.key{color:var(--key)}
.rel{display:flex;justify-content:space-between;align-items:center;gap:10px;min-width:0}
.rel>div{min-width:0;overflow-wrap:anywhere}
button,.btn{font:600 13px "JetBrains Mono",ui-monospace,monospace;color:var(--fg);background:var(--win);border:1px solid var(--edge);
border-radius:6px;padding:8px 12px;cursor:pointer;white-space:nowrap}
button:focus-visible,.btn:focus-visible,input:focus-visible{outline:2px solid var(--ok);outline-offset:2px}
button:disabled{opacity:.35;cursor:default}
.primary{display:block;text-align:center;text-decoration:none;background:var(--ok);border-color:var(--ok);color:var(--bg);padding:12px;font-size:14px}
input[type=url]{width:100%;font:13px "JetBrains Mono",ui-monospace,monospace;color:var(--fg);background:var(--bg);border:1px solid var(--edge);border-radius:6px;padding:8px}
.line{display:flex;gap:8px}.line input{flex:1;min-width:0}
.opts label{margin-right:14px;white-space:nowrap}
.cert{display:flex;gap:10px;align-items:flex-start;cursor:pointer;overflow-wrap:anywhere}.cert input{margin-top:5px}
.cert+.cert{border-top:1px solid var(--edge);padding-top:10px}
#log{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}
.bar{height:8px;background:var(--edge);border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;width:0;background:var(--ok);transition:width .4s}
@media (prefers-reduced-motion:reduce){.cur{animation:none}}
</style></head><body><main>
<h1><span class="d">~/</span><span class="p">sign</span><span class="d"> $ </span><span class="cur"></span></h1>

<section><div class="label">// cert</div><div class="box">{{CERT}}</div></section>

<section><div class="label">// builds · github.com/{{REPO}}</div><div class="box">{{RELEASES}}</div></section>

<section><div class="label">// ipa url</div><div class="box"><div class="line">
<input type="url" id="url" placeholder="https://…/app.ipa"><button id="urlgo">sign</button></div></div></section>

<section><div class="label">// upload</div><div class="box"><div class="line">
<input type="file" id="file" accept=".ipa"><button id="upgo">sign</button></div></div></section>

<section><div class="label">// bundle id</div><div class="box opts">
<div><label><input type="radio" name="bundle" value="profile" checked> profile app id</label>
<label><input type="radio" name="bundle" value="keep"> keep original</label></div>
<div class="dim">profile: 프로파일 앱 ID로 바꿔서 서명(아이패드에서 확인한 방식). 같은 ID라 앱을 바꿔 깔면 덮어쓴다.
keep: 원래 ID 그대로 — 여러 앱을 같이 둘 때.</div></div></section>

<section><div class="label">// output</div><div class="box"><div id="log" class="dim">ready.</div><div class="bar" id="bar" hidden><i id="fill"></i></div><div id="out"></div></div></section>
</main>
<script>
const P = "{{P}}";
const T = new URLSearchParams(location.search).get("t") || "";
const $ = s => document.querySelector(s);
const log = (t, cls) => { const el = $("#log"); el.className = cls || ""; el.textContent = t; };
let busy = false;
function lock(on) { busy = on; document.querySelectorAll("button").forEach(b => b.disabled = on); }
async function api(path, body) {
  const r = await fetch(P + path, { method: "POST", headers: { "content-type": "application/json", "x-nago-token": T }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({ error: "http " + r.status }));
  if (!r.ok || j.error) throw new Error(j.error || ("http " + r.status));
  return j;
}
const PH = { queued: "대기 중(앞 작업이 끝나면 시작)", starting: "준비 중", download: "내려받는 중", unzip: "압축 푸는 중", sign: "서명 중", zip: "다시 묶는 중", done: "완료" };
const fmt = n => n >= 1073741824 ? (n / 1073741824).toFixed(2) + "GB" : n >= 1048576 ? (n / 1048576).toFixed(1) + "MB" : Math.round(n / 1024) + "KB";
const dur = s => s >= 60 ? Math.floor(s / 60) + "분 " + Math.round(s % 60) + "초" : Math.round(s) + "초";
const KEY = "nago_sign_job";
let polling = null;
function bar(p) { const b = $("#bar"); if (p == null) { b.hidden = true; return; } b.hidden = false; $("#fill").style.width = Math.max(0, Math.min(100, p)) + "%"; }
function showDone(r) {
  log("[ OK ] " + r.title + " " + r.version + " (" + r.build + ")\\n" + r.bundle_id + " · " + r.seconds + "s\\n// 설치 링크는 {{TTL}}분 동안 유효(페이지를 다시 열면 새로 발급)", "ok");
  const a = document.createElement("a"); a.className = "btn primary"; a.href = r.install; a.textContent = "설치";
  const d = document.createElement("a"); d.className = "btn"; d.href = r.ipa; d.textContent = "signed .ipa";
  d.style.textAlign = "center"; d.style.textDecoration = "none";
  $("#out").innerHTML = ""; $("#out").append(a, d);
}
function show(j) {
  const total = Math.max(0, Math.round(j.now - j.started));
  if (j.status === "done") { bar(100); showDone(j.result); return true; }
  if (j.status === "error") { bar(null); log("✗ " + j.error + "\\n> " + j.source, "err"); return true; }
  let line = "> " + j.source + "\\n> " + (PH[j.phase] || j.phase) + " · 전체 " + Number(j.percent).toFixed(1) + "%";
  if (j.total) {
    line += "\\n  " + (j.estimated ? "약 " : "") + fmt(j.done) + " / " + fmt(j.total);
    if (!j.estimated && j.rate) line += " · " + fmt(j.rate) + "/s";
    if (j.eta != null) line += " · 남은 시간 " + (j.estimated ? "약 " : "") + dur(j.eta);
    else if (j.estimated && j.done >= j.total * 0.949) line += " · 마무리 중";
  }
  line += "\\n  경과 " + dur(total) + " · 창을 닫거나 화면을 꺼도 서버에서 계속 진행돼요";
  log(line, "dim"); bar(j.percent);
  return false;
}
async function poll(job) {
  clearTimeout(polling); lock(true);
  try {
    const j = await api("/api/job", { job });
    if (show(j)) { localStorage.removeItem(KEY); lock(false); return; }
  } catch (e) {
    if (/unknown job|bad job/.test(e.message)) { localStorage.removeItem(KEY); bar(null); log("✗ " + e.message, "err"); lock(false); return; }
    log("… 연결 재시도 중 (" + e.message + ")", "warn");
  }
  polling = setTimeout(() => poll(job), 1000);
}
async function sign(source) {
  if (busy) return;
  lock(true); $("#out").innerHTML = ""; bar(0);
  log("> " + source + "\\n> 작업 시작 중…", "dim");
  try {
    const bundle = document.querySelector("input[name=bundle]:checked").value;
    const pick = document.querySelector("input[name=cert]:checked");
    const j = await api("/api/sign", { source, bundle, cert: pick ? Number(pick.value) : 0 });
    localStorage.setItem(KEY, j.job);
    poll(j.job);
  } catch (e) { bar(null); log("✗ " + e.message, "err"); lock(false); }
}
document.querySelectorAll("button[data-src]").forEach(b => b.onclick = () => sign(b.dataset.src));
$("#urlgo").onclick = () => { const u = $("#url").value.trim(); if (u) sign("url:" + u); };
$("#upgo").onclick = async () => {
  const f = $("#file").files[0]; if (!f || busy) return;
  lock(true); bar(0);
  try {
    const u = await api("/api/upload", { name: f.name });
    const t0 = Date.now();
    await new Promise((ok, no) => {
      const x = new XMLHttpRequest(); x.open("PUT", u.url);
      x.upload.onprogress = e => {
        if (!e.lengthComputable) return;
        const rate = e.loaded / Math.max((Date.now() - t0) / 1000, 0.1);
        bar(e.loaded / e.total * 100);
        log("> 파일 올리는 중 " + f.name + "\\n  " + fmt(e.loaded) + " / " + fmt(e.total) + " · " + fmt(rate) + "/s · 남은 시간 " + dur((e.total - e.loaded) / rate) + "\\n  (올리는 동안만 이 화면을 켜 두세요. 서명은 백그라운드로 진행돼요)", "dim");
      };
      x.onload = () => x.status < 300 ? ok() : no(new Error("upload http " + x.status));
      x.onerror = () => no(new Error("업로드 네트워크 오류"));
      x.send(f);
    });
    lock(false); sign("upload:" + u.key);
  } catch (e) { bar(null); log("✗ " + e.message, "err"); lock(false); }
};
document.addEventListener("visibilitychange", () => { const j = localStorage.getItem(KEY); if (document.visibilityState === "visible" && j) poll(j); });
const pending = localStorage.getItem(KEY);
if (pending) poll(pending);
</script></body></html>"""


def main():
    for sub in ("signed", "uploads", "jobs", "work"):
        os.makedirs(os.path.join(DATA, sub), exist_ok=True)
    # 서버가 재시작되면 돌던 작업은 끊긴다: 남은 작업 폴더를 치우고, 멈춘 작업은 api_job이 오류로 보여 준다
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP, exist_ok=True)
    threading.Thread(target=cleaner, daemon=True).start()
    host, port = LISTEN.rsplit(":", 1)
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    log("nago-sign on %s, certs: %s, rcodesign: %s" % (
        LISTEN, ", ".join(cert_name(p) for p in cert_files()) or "none", "ok" if os.access(RCODESIGN, os.X_OK) else "MISSING"))
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
