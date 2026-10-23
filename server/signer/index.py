"""NAGO signer — IPA를 내 인증서로 서명해서 아이패드 Safari에서 바로 설치(OTA)하게 해 주는 Lambda.

GET  /?t=<TOKEN>                       → 터미널 스타일 페이지(깃허브 빌드 목록 · IPA 주소 · 파일 올리기)
POST /api/upload  {name}               → S3에 바로 올릴 PUT 주소(파일이 커서 Lambda를 거치지 않는다)
POST /api/sign    {source, bundle}     → 서명하고 {install, ipa, title, version, bundle_id, expires}
     source: "release:<tag>" | "url:<https://….ipa>" | "upload:<S3 키>"
     bundle: "profile"(기본, 프로파일의 앱 ID로 바꿈) | "keep"(원래 번들 ID 유지)
     cert:   SECRET_ID 목록의 번호(기본 0)
POST 요청은 헤더 x-nago-token: <TOKEN>.

인증서는 Secrets Manager(SECRET_ID)에 JSON으로 둔다: {"p12": base64, "password": "…", "profile": base64}
SECRET_ID에 쉼표로 여러 개를 적으면 페이지에서 고른다(POST /api/sign의 cert: 0부터 세는 번호, 기본 0).
서명은 rcodesign(apple-codesign, musl 정적 빌드)을 bin/에 같이 넣어 부른다(tools/build-rcodesign-lambda.sh).
서명본과 올린 파일은 BUCKET의 signed/, uploads/에 두고, 버킷 수명 주기 규칙이 하루 뒤 지운다.

엔타이틀먼트: 앱이 원래 요청한 것 중 프로파일이 허락하는 것만 남기고, 앱 ID·팀·키체인 그룹은 프로파일에 맞춘다.
프로파일이 앱 ID 하나(와일드카드 아님)면 확장도 그 앱 ID로 서명한다(아이패드에서 설치·VPN 확인).
"""
import base64
import fnmatch
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
import time
import urllib.request
import uuid
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RCODESIGN = os.environ.get("RCODESIGN", os.path.join(HERE, "bin", "rcodesign"))
TOKEN = os.environ.get("TOKEN", "")
BUCKET = os.environ.get("BUCKET", "")
SECRET_IDS = [s.strip() for s in os.environ.get("SECRET_ID", "nago/sign/cert").split(",") if s.strip()]
GH_REPO = os.environ.get("GH_REPO", "moonminzi/WiFi-")
LINK_TTL = int(os.environ.get("LINK_TTL", "3600"))
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
TMP = os.environ.get("WORK_DIR", "/tmp")
MAX_IPA = 1500 * 1024 * 1024
# 깃허브 릴리스 태그 → IPA 파일 이름(목록 API가 막혔을 때 대신 쓴다)
ASSET_BY_PREFIX = {"build-": "WifiScan.ipa", "nagodl-": "NagoDL.ipa"}
# 앱 ID·팀·키체인처럼 프로파일에 맞춰 새로 정하는 키
REBUILT_KEYS = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
                "get-task-allow", "com.apple.security.application-groups", "aps-environment"}

_cache = {}


class Failure(Exception):
    pass


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


def identity(index=0):
    if not 0 <= index < len(SECRET_IDS):
        raise Failure("unknown cert: %d" % index)
    key = "identity:" + SECRET_IDS[index]
    if key not in _cache:
        import boto3
        raw = boto3.client("secretsmanager", region_name=REGION).get_secret_value(SecretId=SECRET_IDS[index])["SecretString"]
        s = json.loads(raw)
        _cache[key] = Identity(base64.b64decode(s["p12"]), s["password"], base64.b64decode(s["profile"]))
    return _cache[key]


# MARK: - 엔타이틀먼트

ENTITLEMENTS_MAGIC = 0xFADE7171


def entitlements_of(executable):
    """Mach-O 서명 안의 XML 엔타이틀먼트 블롭(0xfade7171)을 읽는다. 없으면 {}."""
    try:
        data = open(executable, "rb").read()
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
    if "com.apple.security.application-groups" in original and ident.ents.get("com.apple.security.application-groups"):
        out["com.apple.security.application-groups"] = list(ident.ents["com.apple.security.application-groups"])
    return out


# MARK: - IPA 풀기/묶기 (실행 권한과 심볼릭 링크를 지킨다)

def unzip(path, dest):
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            name = info.filename
            if name.startswith("/") or ".." in name.split("/"):
                raise Failure("bad path in ipa: " + name)
            target = os.path.join(dest, name)
            mode = (info.external_attr >> 16) & 0xFFFF
            if name.endswith("/"):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if stat.S_ISLNK(mode):
                os.symlink(z.read(info).decode(), target)
                continue
            with z.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
            os.chmod(target, (mode & 0o777) or 0o644)


def zip_dir(src, path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            for d in dirs:
                full = os.path.join(root, d)
                info = zipfile.ZipInfo(os.path.relpath(full, src) + "/")
                info.external_attr = (stat.S_IFDIR | 0o755) << 16
                z.writestr(info, b"")
            for f in sorted(files):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src)
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    info = zipfile.ZipInfo(rel)
                    info.external_attr = (stat.S_IFLNK | 0o755) << 16
                    z.writestr(info, os.readlink(full))
                else:
                    z.write(full, rel)


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


def sign_ipa(src_ipa, out_ipa, ident, bundle_mode="profile", log=print):
    work = os.path.join(TMP, "sign-" + uuid.uuid4().hex[:8])
    os.makedirs(work)
    try:
        unzip(src_ipa, work)
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
            with open(path, "wb") as f:
                f.write(data)
            os.chmod(path, 0o600)

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
        run = subprocess.run(args, capture_output=True, text=True, timeout=600)
        if run.returncode != 0:
            raise Failure("rcodesign: " + (run.stderr or run.stdout)[-600:])
        for path in (p12, pw):
            os.remove(path)
        for f in os.listdir(work):
            if f.startswith("ent-"):
                os.remove(os.path.join(work, f))
        zip_dir(work, out_ipa)
        return {"bundle_id": new_main, "title": main_info.get("CFBundleDisplayName") or main_info.get("CFBundleName") or apps[0][:-4],
                "version": main_info.get("CFBundleShortVersionString", ""), "build": main_info.get("CFBundleVersion", "")}
    finally:
        shutil.rmtree(work, ignore_errors=True)


# MARK: - 가져오기

def http_get(url, dest=None, limit=MAX_IPA):
    if not url.startswith("https://"):
        raise Failure("https only")
    req = urllib.request.Request(url, headers={"User-Agent": "nago-signer", "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=60) as r:
        if dest is None:
            return r.read(limit)
        total = 0
        with open(dest, "wb") as f:
            while chunk := r.read(1 << 20):
                total += len(chunk)
                if total > limit:
                    raise Failure("ipa too large")
                f.write(chunk)
        return total


def releases():
    """최근 깃허브 릴리스 중 IPA가 있는 것. 5분 캐시, API가 막히면 Atom 피드로."""
    hit = _cache.get("releases")
    if hit and time.time() - hit[0] < 300:
        return hit[1]
    out = []
    try:
        data = json.loads(http_get("https://api.github.com/repos/%s/releases?per_page=12" % GH_REPO, limit=4 << 20))
        for r in data:
            for a in r.get("assets", []):
                if a["name"].endswith(".ipa"):
                    out.append({"tag": r["tag_name"], "date": (r.get("published_at") or "")[:10],
                                "asset": a["name"], "size": a.get("size", 0), "url": a["browser_download_url"]})
    except Exception:
        feed = http_get("https://github.com/%s/releases.atom" % GH_REPO, limit=4 << 20).decode("utf-8", "replace")
        for entry in feed.split("<entry>")[1:]:
            tag = re.search(r"/releases/tag/([^\"<]+)\"", entry)
            date = re.search(r"<updated>(\d{4}-\d\d-\d\d)", entry)
            tag, date = (tag.group(1) if tag else ""), (date.group(1) if date else "")
            asset = next((n for p, n in ASSET_BY_PREFIX.items() if tag.startswith(p)), None)
            if asset:
                out.append({"tag": tag, "date": date, "asset": asset, "size": 0,
                            "url": "https://github.com/%s/releases/download/%s/%s" % (GH_REPO, tag, asset)})
    _cache["releases"] = (time.time(), out)
    return out


def fetch(source, dest):
    kind, _, value = source.partition(":")
    if kind == "release":
        try:
            hit = next((r for r in releases() if r["tag"] == value), None)
        except Exception:
            hit = None
        if hit:
            url = hit["url"]
        else:
            asset = next((n for p, n in ASSET_BY_PREFIX.items() if value.startswith(p)), None)
            if not asset or not re.fullmatch(r"[A-Za-z0-9._-]+", value):
                raise Failure("unknown release: " + value)
            url = "https://github.com/%s/releases/download/%s/%s" % (GH_REPO, value, asset)
        return http_get(url, dest)
    if kind == "url":
        return http_get(value, dest)
    if kind == "upload":
        if not re.fullmatch(r"uploads/[0-9a-f]{32}/[A-Za-z0-9._-]+\.ipa", value):
            raise Failure("bad upload key")
        s3().download_file(BUCKET, value, dest)
        return os.path.getsize(dest)
    raise Failure("unknown source")


# MARK: - S3 / 설치 링크

def s3():
    if "s3" not in _cache:
        import boto3
        from botocore.config import Config
        _cache["s3"] = boto3.client("s3", region_name=REGION,
                                    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}))
    return _cache["s3"]


def presign(key, method="get_object", **extra):
    return s3().generate_presigned_url(method, Params={"Bucket": BUCKET, "Key": key, **extra}, ExpiresIn=LINK_TTL)


def manifest(ipa_url, meta):
    return plistlib.dumps({"items": [{
        "assets": [{"kind": "software-package", "url": ipa_url}],
        "metadata": {"bundle-identifier": meta["bundle_id"], "bundle-version": meta["version"] or meta["build"] or "1",
                     "kind": "software", "title": meta["title"]},
    }]})


def publish(signed_path, meta):
    job = uuid.uuid4().hex
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", meta["title"]).strip("-") or "app"
    ipa_key = "signed/%s/%s.ipa" % (job, safe)
    s3().upload_file(signed_path, BUCKET, ipa_key)
    ipa_url = presign(ipa_key)
    man_key = "signed/%s/manifest.plist" % job
    s3().put_object(Bucket=BUCKET, Key=man_key, Body=manifest(ipa_url, meta), ContentType="text/xml")
    install = "itms-services://?action=download-manifest&url=" + urllib.request.quote(presign(man_key), safe="")
    return {**meta, "install": install, "ipa": ipa_url, "expires": int(time.time()) + LINK_TTL}


# MARK: - HTTP

def resp(code, body, ctype="application/json"):
    if not isinstance(body, str):
        body = json.dumps(body, ensure_ascii=False)
    return {"statusCode": code, "headers": {"content-type": ctype + "; charset=utf-8", "cache-control": "no-store"},
            "body": body}


def authorized(event, token=None):
    if token is None:
        headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
        token = headers.get("x-nago-token") or (event.get("queryStringParameters") or {}).get("t", "")
    return bool(TOKEN) and hmac.compare_digest(hashlib.sha256(token.encode()).digest(),
                                               hashlib.sha256(TOKEN.encode()).digest())


def body_of(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    return json.loads(raw)


def api_upload(body):
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.basename(body.get("name") or "app.ipa")).strip("-")
    if not name.endswith(".ipa"):
        name += ".ipa"
    key = "uploads/%s/%s" % (uuid.uuid4().hex, name)
    return {"key": key, "url": presign(key, "put_object")}


def api_sign(body):
    source = body.get("source") or ""
    mode = "keep" if body.get("bundle") == "keep" else "profile"
    try:
        cert = int(body.get("cert") or 0)
    except (TypeError, ValueError):
        raise Failure("bad cert")
    ident = identity(cert)
    job = os.path.join(TMP, "job-" + uuid.uuid4().hex[:8])
    os.makedirs(job)
    try:
        src, out = os.path.join(job, "in.ipa"), os.path.join(job, "out.ipa")
        t0 = time.time()
        size = fetch(source, src)
        meta = sign_ipa(src, out, ident, mode, log=lambda m: print(m))
        result = publish(out, meta)
        result.update(source=source, cert=cert, size=size, seconds=round(time.time() - t0, 1))
        return result
    finally:
        shutil.rmtree(job, ignore_errors=True)


def handler(event, context):
    event = event or {}
    http = (event.get("requestContext") or {}).get("http") or {}
    method, path = http.get("method", "GET"), event.get("rawPath") or "/"
    if not authorized(event):
        if method == "GET":
            return resp(403, "403 forbidden: bad token\n", "text/plain")
        return resp(403, {"error": "forbidden"})
    try:
        if method == "POST" and path == "/api/upload":
            return resp(200, api_upload(body_of(event)))
        if method == "POST" and path == "/api/sign":
            return resp(200, api_sign(body_of(event)))
        if method == "GET" and path == "/":
            return resp(200, render(), "text/html")
        return resp(404, {"error": "not found"})
    except Failure as e:
        return resp(400, {"error": str(e)})
    except Exception as e:
        print("panic:", repr(e))
        return resp(500, {"error": "%s: %s" % (type(e).__name__, str(e)[:300])})


# MARK: - 페이지

def _usable(index):
    try:
        identity(index)
        return True
    except Exception:
        return False


def render():
    try:
        rels, rel_err = releases(), ""
    except Exception as e:
        rels, rel_err = [], str(e)
    esc = html.escape
    certs = []
    for i in range(len(SECRET_IDS)):
        # 첫 번째로 쓸 수 있는 인증서를 기본 선택
        pick = ' checked' if i == next((j for j in range(len(SECRET_IDS)) if _usable(j)), 0) else ''
        try:
            who = identity(i).summary()
        except Exception as e:
            certs.append('<label class="cert"><input type="radio" name="cert" value="%d" disabled> '
                         '<span class="err">✗ %s</span> <span class="dim">%s</span></label>' % (i, esc(SECRET_IDS[i]), esc(str(e)[:200])))
            continue
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
    cert = "".join(certs)
    rows = []
    for r in rels[:8]:
        size = (" · %.1fMB" % (r["size"] / 1048576)) if r["size"] else ""
        rows.append('<div class="rel"><div><span class="key">%s</span> <span class="dim">%s · %s%s</span></div>'
                    '<button data-src="release:%s">sign</button></div>' % (
                        esc(r["tag"]), esc(r["asset"]), esc(r["date"]), size, esc(r["tag"])))
    if not rows:
        rows.append('<div class="row dim">no releases%s</div>' % ((" (" + esc(rel_err) + ")") if rel_err else ""))
    return PAGE.replace("{{CERT}}", cert).replace("{{RELEASES}}", "".join(rows)).replace(
        "{{REPO}}", esc(GH_REPO)).replace("{{TTL}}", str(LINK_TTL // 60))


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0d0a"><title>nago@sign</title>
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

<section><div class="label">// output</div><div class="box"><div id="log" class="dim">ready.</div><div id="out"></div></div></section>
</main>
<script>
const T = new URLSearchParams(location.search).get("t") || "";
const $ = s => document.querySelector(s);
const log = (t, cls) => { const el = $("#log"); el.className = cls || ""; el.textContent = t; };
let busy = false;
function lock(on) { busy = on; document.querySelectorAll("button").forEach(b => b.disabled = on); }
async function api(path, body) {
  const r = await fetch(path, { method: "POST", headers: { "content-type": "application/json", "x-nago-token": T }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({ error: "http " + r.status }));
  if (!r.ok || j.error) throw new Error(j.error || ("http " + r.status));
  return j;
}
async function sign(source) {
  if (busy) return;
  lock(true); $("#out").innerHTML = "";
  const t0 = Date.now();
  const tick = setInterval(() => log("> " + source + "\\n> downloading · signing… " + Math.round((Date.now() - t0) / 1000) + "s", "dim"), 500);
  try {
    const bundle = document.querySelector("input[name=bundle]:checked").value;
    const pick = document.querySelector("input[name=cert]:checked");
    const j = await api("/api/sign", { source, bundle, cert: pick ? Number(pick.value) : 0 });
    clearInterval(tick);
    log("[ OK ] " + j.title + " " + j.version + " (" + j.build + ")\\n" + j.bundle_id + " · " + j.seconds + "s\\n// 설치 링크는 {{TTL}}분 동안 유효", "ok");
    const a = document.createElement("a"); a.className = "btn primary"; a.href = j.install; a.textContent = "설치";
    const d = document.createElement("a"); d.className = "btn"; d.href = j.ipa; d.textContent = "signed .ipa";
    d.style.textAlign = "center"; d.style.textDecoration = "none";
    $("#out").append(a, d);
  } catch (e) {
    clearInterval(tick); log("✗ " + e.message, "err");
  } finally { lock(false); }
}
document.querySelectorAll("button[data-src]").forEach(b => b.onclick = () => sign(b.dataset.src));
$("#urlgo").onclick = () => { const u = $("#url").value.trim(); if (u) sign("url:" + u); };
$("#upgo").onclick = async () => {
  const f = $("#file").files[0]; if (!f || busy) return;
  lock(true);
  try {
    log("> uploading " + f.name + " (" + (f.size / 1048576).toFixed(1) + "MB)…", "dim");
    const u = await api("/api/upload", { name: f.name });
    const r = await fetch(u.url, { method: "PUT", body: f });
    if (!r.ok) throw new Error("upload http " + r.status);
    lock(false); sign("upload:" + u.key);
  } catch (e) { log("✗ " + e.message, "err"); lock(false); }
};
</script></body></html>"""
