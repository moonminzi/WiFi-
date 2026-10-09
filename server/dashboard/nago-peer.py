#!/usr/bin/env python3
"""서울 서버 WireGuard 피어 관리. 대시보드 Lambda가 SSM으로 설치하고 부른다.

    nago-peer <base64(JSON)>      → 결과 JSON 한 줄
    nago-peer restore <ip>        → kick 뒤 되살리기(systemd 타이머가 부름)

JSON op:
    add     {pub, name}         새 피어(공개키만 받음, 개인키는 폰에만 있음) → {ip, serverPub, port}
    kick    {ip, seconds}       잠깐 끊었다가 seconds 뒤 같은 키로 되살림
    reset   {ip}                사용량 카운터만 0으로(키·설정 그대로)
    remove  {ip}                영구 삭제(wg0.conf에서도 지움)
    rename  {ip, name}
"""
import base64
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile

IFACE = os.environ.get("NAGO_WG_IFACE", "wg0")
CONF = os.environ.get("NAGO_WG_CONF", "/etc/wireguard/wg0.conf")
NAMES = os.environ.get("NAGO_WG_NAMES", "/etc/wireguard/nago-names.json")
RUN = os.environ.get("NAGO_WG_RUN", "/run")
SELF = "/usr/local/sbin/nago-peer"
NET = ipaddress.ip_network("10.9.0.0/24")
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")


class Fail(Exception):
    pass


def wg(*args):
    r = subprocess.run(["wg", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise Fail("wg %s: %s" % (args[0], r.stderr.strip()[:200]))
    return r.stdout


def live_peers():
    """{ip: {pub, psk, ep, aips, ka}} — 지금 인터페이스에 붙어 있는 피어"""
    out = {}
    for line in wg("show", IFACE, "dump").splitlines()[1:]:
        f = line.split("\t")
        if len(f) < 8:
            continue
        for a in f[3].split(","):
            if a.endswith("/32"):
                out[a[:-3]] = {"pub": f[0], "psk": f[1], "ep": f[2], "aips": f[3], "ka": f[7]}
    return out


def check_ip(ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        raise Fail("bad ip")
    if addr not in NET or str(addr).endswith(".0") or str(addr).endswith(".1") or str(addr).endswith(".255"):
        raise Fail("ip out of range")
    return str(addr)


def clean_name(name):
    name = "".join(ch for ch in str(name or "") if ch.isprintable()).strip()
    return name[:20]


def write_atomic(path, text, mode=0o600):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".nago-")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    try:
        mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        pass
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_names():
    try:
        with open(NAMES) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def save_names(names):
    write_atomic(NAMES, json.dumps(names, ensure_ascii=False, sort_keys=True) + "\n")


def conf_sections():
    """wg0.conf를 [섹션] 단위 줄 묶음으로 나눈다(첫 묶음은 섹션 앞부분)."""
    with open(CONF) as fh:
        lines = fh.read().splitlines()
    sections, cur = [], []
    for line in lines:
        if line.strip().startswith("[") and cur:
            sections.append(cur)
            cur = []
        cur.append(line)
    if cur:
        sections.append(cur)
    return sections


def section_value(section, key):
    for line in section:
        k, sep, v = line.partition("=")
        if sep and k.strip().lower() == key.lower():
            return v.strip()
    return None


def conf_ips():
    ips = set()
    for s in conf_sections():
        for a in (section_value(s, "AllowedIPs") or "").split(","):
            a = a.strip()
            if a.endswith("/32"):
                ips.add(a[:-3])
    return ips


def conf_remove(pub):
    kept, removed = [], 0
    for s in conf_sections():
        is_peer = s and s[0].strip().lower() == "[peer]"
        if is_peer and section_value(s, "PublicKey") == pub:
            removed += 1
            continue
        kept.append(s)
    if removed:
        # 앞 섹션 끝의 빈 줄은 그대로 두고, 이어 붙인다
        write_atomic(CONF, "\n".join("\n".join(s) for s in kept).rstrip("\n") + "\n")
    return removed


def readd(ip, p):
    args = ["set", IFACE, "peer", p["pub"], "allowed-ips", p["aips"]]
    psk_file = None
    if p.get("psk") and p["psk"] != "(none)":
        fd, psk_file = tempfile.mkstemp(dir=RUN, prefix=".nago-psk-")
        with os.fdopen(fd, "w") as fh:
            fh.write(p["psk"])
        args += ["preshared-key", psk_file]
    if p.get("ka") and p["ka"] not in ("off", "0"):
        args += ["persistent-keepalive", p["ka"]]
    if p.get("ep") and p["ep"] != "(none)":
        args += ["endpoint", p["ep"]]
    try:
        wg(*args)
    finally:
        if psk_file:
            os.unlink(psk_file)


def need(ip):
    ip = check_ip(ip)
    p = live_peers().get(ip)
    if not p:
        raise Fail("no peer at %s (already kicked or removed?)" % ip)
    return ip, p


def op_add(req):
    pub = str(req.get("pub", ""))
    if not KEY_RE.match(pub):
        raise Fail("bad public key")
    live = live_peers()
    if any(p["pub"] == pub for p in live.values()):
        raise Fail("key already registered")
    used = set(live) | conf_ips() | set(load_names())
    ip = next((str(a) for a in NET.hosts() if str(a) not in used and not str(a).endswith(".1")), None)
    if not ip:
        raise Fail("no free address")
    wg("set", IFACE, "peer", pub, "allowed-ips", ip + "/32")
    with open(CONF) as fh:
        text = fh.read()
    write_atomic(CONF, text.rstrip("\n") + "\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n" % (pub, ip))
    names = load_names()
    names[ip] = clean_name(req.get("name")) or "peer %s" % (int(ip.rsplit(".", 1)[1]) - 1)
    save_names(names)
    return {"ip": ip, "serverPub": wg("show", IFACE, "public-key").strip(),
            "port": int(wg("show", IFACE, "listen-port").strip())}


def kick_state(ip):
    return os.path.join(RUN, "nago-kick-%s.json" % ip)


def op_kick(req):
    ip, p = need(req.get("ip"))
    seconds = max(10, min(int(req.get("seconds") or 60), 3600))
    unit = "nago-kick-" + ip.replace(".", "-")
    subprocess.run(["systemctl", "stop", unit + ".timer", unit + ".service"], capture_output=True)
    write_atomic(kick_state(ip), json.dumps(p))
    wg("set", IFACE, "peer", p["pub"], "remove")
    r = subprocess.run(["systemd-run", "--unit", unit, "--on-active=%ds" % seconds, SELF, "restore", ip],
                       capture_output=True, text=True)
    if r.returncode != 0:
        readd(ip, p)   # 타이머를 못 걸면 바로 되돌린다(끊긴 채로 남지 않게)
        os.unlink(kick_state(ip))
        raise Fail("timer: " + r.stderr.strip()[:200])
    return {"ip": ip, "seconds": seconds}


def op_restore(ip):
    ip = check_ip(ip)
    path = kick_state(ip)
    try:
        with open(path) as fh:
            p = json.load(fh)
    except FileNotFoundError:
        return {"ip": ip, "restored": False}
    if not any(x["pub"] == p["pub"] for x in live_peers().values()):
        readd(ip, p)
    os.unlink(path)
    return {"ip": ip, "restored": True}


def op_reset(req):
    ip, p = need(req.get("ip"))
    wg("set", IFACE, "peer", p["pub"], "remove")
    readd(ip, p)
    return {"ip": ip}


def op_remove(req):
    ip, p = need(req.get("ip"))
    wg("set", IFACE, "peer", p["pub"], "remove")
    conf_remove(p["pub"])
    names = load_names()
    if names.pop(ip, None) is not None:
        save_names(names)
    return {"ip": ip}


def op_rename(req):
    ip = check_ip(req.get("ip"))
    if ip not in live_peers() and ip not in conf_ips():
        raise Fail("no peer at %s" % ip)
    names = load_names()
    names[ip] = clean_name(req.get("name")) or "peer %s" % (int(ip.rsplit(".", 1)[1]) - 1)
    save_names(names)
    return {"ip": ip, "name": names[ip]}


OPS = {"add": op_add, "kick": op_kick, "reset": op_reset, "remove": op_remove, "rename": op_rename}


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "restore":
            out = op_restore(argv[2])
        else:
            req = json.loads(base64.b64decode(argv[1]).decode())
            fn = OPS.get(req.get("op"))
            if not fn:
                raise Fail("unknown op")
            out = fn(req)
        out["ok"] = True
    except Fail as e:
        out = {"ok": False, "error": str(e)}
    except Exception as e:  # 예상 못 한 오류도 JSON으로
        out = {"ok": False, "error": "%s: %s" % (type(e).__name__, str(e)[:200])}
    print(json.dumps(out))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
