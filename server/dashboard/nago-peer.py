#!/usr/bin/env python3
"""WireGuard 피어 관리(서버 4대 공통). 대시보드/국가 Lambda가 SSM으로 설치하고 부른다.

    nago-peer <base64(JSON)>      → 결과 JSON 한 줄
    nago-peer restore <ip>        → kick 뒤 되살리기(systemd 타이머가 부름)

JSON op:
    add     {pub, name}         새 피어(공개키만 받음, 개인키는 폰에만 있음) → {ip, serverPub, port}
    kick    {ip, seconds}       잠깐 끊었다가 seconds 뒤 같은 키로 되살림
    reset   {ip}                사용량 카운터만 0으로(키·설정 그대로)
    remove  {ip}                영구 삭제(wg0.conf에서도 지움)
    rename  {ip, name}
    flags   {ip, adblock}       피어별 스위치. adblock을 켜면 그 피어의 DNS(53)를 차단 DNS로 돌린다
    sync    {peers: [{pub, ip, adblock}]}  피어 목록(SSM 파라미터 /nago/wg/peers)에 맞춘다. 바뀐 것만
                                  건드려서 붙어 있는 사람은 끊기지 않는다

    nago-peer apply               저장된 피어별 스위치를 iptables에 다시 올린다(재부팅 뒤 systemd가 부름)
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
FLAGS = os.environ.get("NAGO_WG_FLAGS", "/etc/wireguard/nago-flags.json")
# setup-adblock.sh가 올리는 VPN 안쪽 전용 차단 DNS(dummy 인터페이스 nago-dns)
ADBLOCK_DNS = os.environ.get("NAGO_ADBLOCK_DNS", "10.53.53.53")
DNS_CHAIN = "NAGO_DNS"
BOOT_UNIT_NAME = "nago-dns-peers.service"
BOOT_UNIT = "/etc/systemd/system/" + BOOT_UNIT_NAME
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


def load_flags():
    """{ip: {"adblock": true}} — 피어별 스위치"""
    try:
        with open(FLAGS) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def save_flags(flags):
    write_atomic(FLAGS, json.dumps(flags, ensure_ascii=False, sort_keys=True) + "\n")


def as_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def ipt(*args, soft=False):
    """iptables nat 테이블. soft면 실패해도 넘어간다(이미 있는 체인 만들기, 없는 규칙 지우기 등)."""
    r = subprocess.run(["iptables", "-t", "nat", *args], capture_output=True, text=True)
    if r.returncode != 0 and not soft:
        raise Fail("iptables %s: %s" % (" ".join(args[:2]), r.stderr.strip()[:200]))
    return r.returncode == 0


def adblock_ready():
    """이 서버에 차단 DNS가 올라와 있는지. 없는데 DNS를 돌리면 이름 해석이 아예 안 된다."""
    r = subprocess.run(["ip", "-brief", "addr", "show", "nago-dns"], capture_output=True, text=True)
    return r.returncode == 0 and ADBLOCK_DNS in r.stdout


def apply_dns(flags=None):
    """adblock을 켠 피어의 DNS(53)만 차단 DNS로 돌린다.

    체인을 비우고 다시 쌓기 때문에 몇 번 불러도 결과가 같다. PREROUTING 고리는 지웠다가
    맨 앞에 다시 넣는다 — TCP 분할 가속(NAGO_ACCEL)이 PREROUTING 맨 앞에 끼어들기 때문에,
    그 아래에 있으면 TCP 53이 가속 프록시로 끌려가 DNAT이 안 걸린다.
    """
    flags = load_flags() if flags is None else flags
    wanted = sorted(ip for ip, f in flags.items() if (f or {}).get("adblock"))

    ipt("-N", DNS_CHAIN, soft=True)     # 이미 있으면 그냥 넘어간다
    ipt("-F", DNS_CHAIN)
    for proto in ("udp", "tcp"):
        rule = ["PREROUTING", "-i", IFACE, "-p", proto, "--dport", "53", "-j", DNS_CHAIN]
        while ipt("-C", *rule, soft=True):
            ipt("-D", *rule, soft=True)
        ipt("-I", *rule)

    if not wanted:
        return []
    if not adblock_ready():
        # 죽은 DNS로 돌려 두면 그 피어들은 이름 해석이 아예 안 된다. 체인은 비운 채로 두고
        # 알린다(스위치는 파일에 남아 있어서 차단 DNS가 살아나면 다음 apply/sync 때 다시 걸린다).
        raise Fail("ad-blocking dns (%s) is not up on this server - run setup-adblock.sh" % ADBLOCK_DNS)
    for ip in wanted:
        ipt("-A", DNS_CHAIN, "-s", ip + "/32", "-j", "DNAT", "--to-destination", ADBLOCK_DNS + ":53")
    return wanted


def install_boot_unit():
    """재부팅해도 규칙이 남게 한다(wg0이 올라온 뒤 apply 한 번)."""
    # After만 건다(Wants를 걸면 wg0을 다른 방식으로 올리는 서버에서 wg-quick을 띄우려 든다).
    # -i wg0 규칙은 인터페이스가 아직 없어도 걸리니 순서만 맞추면 된다.
    unit = ("[Unit]\nDescription=NAGO VPN per-peer DNS rules\n"
            "After=network-online.target wg-quick@%s.service\n\n"
            "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=%s apply\n\n"
            "[Install]\nWantedBy=multi-user.target\n") % (IFACE, SELF)
    try:
        if not os.path.exists(BOOT_UNIT) or open(BOOT_UNIT).read() != unit:
            write_atomic(BOOT_UNIT, unit, mode=0o644)
            subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "enable", BOOT_UNIT_NAME], capture_output=True)
    except OSError:
        pass   # 규칙 자체는 이미 들어가 있으니 부팅 복원만 포기한다


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


def conf_peers():
    """wg0.conf의 {공개키: ip}"""
    out = {}
    for s in conf_sections():
        if s and s[0].strip().lower() == "[peer]":
            pub = section_value(s, "PublicKey")
            ip = next((a.strip()[:-3] for a in (section_value(s, "AllowedIPs") or "").split(",")
                       if a.strip().endswith("/32")), None)
            if pub:
                out[pub] = ip
    return out


def conf_add(pub, ip):
    with open(CONF) as fh:
        text = fh.read()
    write_atomic(CONF, text.rstrip("\n") + "\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n" % (pub, ip))


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
    flags = load_flags()
    if flags.pop(ip, None) is not None:
        save_flags(flags)
        try:
            apply_dns(flags)
        except Fail:
            pass   # 피어는 이미 지워졌다. 남은 규칙은 다음 sync/apply 때 정리된다
    return {"ip": ip}


def op_flags(req):
    """피어별 스위치를 바꾸고 바로 적용한다. 지금은 adblock 하나."""
    ip = check_ip(req.get("ip"))
    if ip not in live_peers() and ip not in conf_ips():
        raise Fail("no peer at %s" % ip)
    flags = load_flags()
    entry = dict(flags.get(ip) or {})
    if "adblock" in req:
        entry["adblock"] = as_bool(req.get("adblock"))
    if entry.get("adblock"):
        flags[ip] = entry
    else:
        flags.pop(ip, None)
    applied = apply_dns(flags)      # 실패하면(차단 DNS 없음) 저장하지 않는다
    save_flags(flags)
    install_boot_unit()
    return {"ip": ip, "adblock": bool(entry.get("adblock")), "adblockPeers": len(applied)}


def op_rename(req):
    ip = check_ip(req.get("ip"))
    if ip not in live_peers() and ip not in conf_ips():
        raise Fail("no peer at %s" % ip)
    names = load_names()
    names[ip] = clean_name(req.get("name")) or "peer %s" % (int(ip.rsplit(".", 1)[1]) - 1)
    save_names(names)
    return {"ip": ip, "name": names[ip]}


def op_sync(req):
    want = {}
    flags = {}
    for p in req.get("peers") or []:
        pub = str(p.get("pub", ""))
        if not KEY_RE.match(pub):
            raise Fail("bad key in list")
        ip = check_ip(p.get("ip"))
        want[pub] = ip
        if as_bool(p.get("adblock")):
            flags[ip] = {"adblock": True}
    live = {p["pub"]: ip for ip, p in live_peers().items()}
    conf = conf_peers()
    added = removed = 0
    for pub, ip in want.items():
        if live.get(pub) != ip:
            wg("set", IFACE, "peer", pub, "allowed-ips", ip + "/32")
            added += 1
        if conf.get(pub) != ip:
            if pub in conf:
                conf_remove(pub)
            conf_add(pub, ip)
    for pub in set(live) - set(want):
        wg("set", IFACE, "peer", pub, "remove")
        removed += 1
    for pub in set(conf) - set(want):
        conf_remove(pub)
    out = {"added": added, "removed": removed, "total": len(want)}
    # 차단 DNS가 안 깔린 서버라도 피어 동기화 자체는 성공해야 한다. 스위치만 못 건다.
    save_flags(flags)
    try:
        out["adblock"] = len(apply_dns(flags))
    except Fail as e:
        out["adblock"] = 0
        out["adblockError"] = str(e)
    install_boot_unit()
    return out


OPS = {"add": op_add, "sync": op_sync, "kick": op_kick, "reset": op_reset, "remove": op_remove,
       "rename": op_rename, "flags": op_flags}


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "restore":
            out = op_restore(argv[2])
        elif len(argv) == 2 and argv[1] == "apply":
            out = {"adblockPeers": len(apply_dns())}
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
