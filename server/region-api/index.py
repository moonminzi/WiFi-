"""NAGO VPN 국가 선택 API.

GET /region?r=<kr|jp|us|uk>  (헤더 x-nago-key: VPN 비밀번호)
→ 꺼져 있으면 켜고, {"state", "ready", "ip", "id"}를 돌려준다.
앱은 ready가 true가 될 때까지 몇 초마다 다시 부르고, ip/id로 IKEv2 설정을 만든다.
WireGuard용으로 그 서버의 공개키/포트(wgPub, wgPort)도 준다. 서버가 준비되면 대시보드 Lambda에
피어 동기화를 부탁한다(꺼져 있는 동안 바뀐 피어 목록을 맞춤).

GET /region?r=<sg|de|fr|...>  임시 서버 나라(ONDEMAND)
→ 떠 있는 서버가 없으면 그 리전에 새로 만든다(WireGuard만, 1분쯤). 서버는 30분 동안 거의 안 쓰면
스스로 꺼지는데 종료 동작이 terminate라 그대로 지워진다(24시간이 지나도 지워짐). 안 쓰는 동안 드는 돈이 없다.
서버 키는 여기서 만들어 user-data로 넘기고, 피어 목록은 만들 때의 /nago/wg/peers를 넣는다.
"""
import base64
import concurrent.futures as cf
import datetime
import time
import hashlib
import hmac
import json
import os
import re

import boto3
from botocore.exceptions import ClientError

REGIONS = json.loads(os.environ["REGIONS"])
KEY_SHA = os.environ["KEY_SHA256"]
# 켜진 지 이만큼 지나면 SSM 확인 없이도 준비된 걸로 본다.
BOOT_GRACE_SEC = 100
WG_PORT = 443          # 서버에서 51820으로 넘겨 준다. 잘 안 막히는 포트
DASH_FUNCTION = os.environ.get("DASH_FUNCTION", "nago-dash")
_wg = {"t": 0, "v": {}}

# 임시 서버 나라: {"sg": {"region": "ap-southeast-1"}, ...}
ONDEMAND = json.loads(os.environ.get("ONDEMAND", "{}"))
OD_TYPE = os.environ.get("ONDEMAND_TYPE", "c7g.medium")
# 한꺼번에 떠 있을 수 있는 임시 서버 수(키가 새도 서버를 마구 못 만들게)
OD_MAX = int(os.environ.get("ONDEMAND_MAX", "2"))
OD_TAG = "nago:ondemand"
OD_PUB_TAG = "nago:wgpub"
OD_SG = "nago-ondemand"
OD_AMI = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
OD_READY = "NAGO_WG_READY"
# 가속(haproxy)까지 켜졌다는 표시(준비 판단에는 쓰지 않는다 — 연결은 그 전부터 된다)
OD_ACCEL_READY = "NAGO_ACCEL_READY"
# 콘솔 출력을 못 읽어도 켜진 지 이만큼 지나면 준비된 걸로 본다
OD_GRACE_SEC = 150
PEER_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
PEER_IP_RE = re.compile(r"^10\.9\.0\.([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$")

_clients = {}


def client(service, region):
    k = (service, region)
    if k not in _clients:
        _clients[k] = boto3.client(service, region_name=region)
    return _clients[k]


def resp(code, body):
    return {
        "statusCode": code,
        "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def wg_servers():
    if time.time() - _wg["t"] > 300:
        try:
            value = client("ssm", "ap-northeast-2").get_parameter(Name="/nago/wg/servers")["Parameter"]["Value"]
            _wg.update(t=time.time(), v=json.loads(value))
        except Exception:
            pass
    return _wg["v"]


def request_sync(code):
    try:
        client("lambda", "ap-northeast-2").invoke(
            FunctionName=DASH_FUNCTION, InvocationType="Event",
            Payload=json.dumps({"nago_internal": "sync", "node": code}).encode())
    except Exception:
        pass


def is_ready(cfg, inst):
    launched = inst["LaunchTime"]
    up = (datetime.datetime.now(datetime.timezone.utc) - launched).total_seconds()
    if up > BOOT_GRACE_SEC:
        return True
    # 막 켜진 경우: SSM 에이전트가 이번 부팅 이후에 접속했으면 부팅이 끝난 것(strongSwan도 함께 뜸).
    try:
        info = client("ssm", cfg["region"]).describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [cfg["iid"]]}]
        )["InstanceInformationList"]
    except Exception:
        return False
    return bool(info) and info[0].get("PingStatus") == "Online" and info[0]["LastPingDateTime"] >= launched


# ---------------------------------------------------------------- 임시 서버

_P = 2 ** 255 - 19


def x25519_public(private):
    """WireGuard 공개키(RFC 7748 X25519, 기준점 9). Lambda에 암호 라이브러리가 없어서 직접 계산한다."""
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


# 서버가 첫 부팅 때 한 번 돌리는 스크립트. 패키지를 깔지 않는다(커널 wireguard + systemd-networkd).
OD_SCRIPT = r"""#!/bin/bash
# NAGO VPN 임시 서버(@CODE@). WireGuard를 먼저 올리고(바로 연결됨), TCP 분할 가속(haproxy)은 그 뒤에
# 백그라운드로 깔아 켠다. 30분 동안 거의 안 쓰거나 24시간이 지나면 스스로 끈다(종료 동작이 terminate라 서버가 지워진다).
exec > >(tee -a /var/log/nago-ondemand.log /dev/console) 2>&1
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
  # 커널 모듈이 extra 패키지에 들어 있는 이미지면 그때만 깐다
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

# 매분: 분당 송신 300KB 미만인 분이 30분 이어지면 끈다. 카운터는 /run이라 부팅마다 0부터
printf '%s\n' '#!/bin/bash' \
  'DEV=$(ip route get 1.1.1.1 | awk '"'"'{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'"'"')' \
  'S=/run/nago-idle; mkdir -p "$S"' \
  'tx=$(cat "/sys/class/net/$DEV/statistics/tx_bytes")' \
  'last=$(cat "$S/tx" 2>/dev/null || echo "$tx")' \
  'echo "$tx" > "$S/tx"' \
  'idle=$(cat "$S/idle" 2>/dev/null || echo 0)' \
  'if [ $((tx - last)) -lt 300000 ]; then idle=$((idle + 1)); else idle=0; fi' \
  'echo "$idle" > "$S/idle"' \
  'if [ "$idle" -ge 30 ]; then logger -t nago-idle "idle ${idle}m -> poweroff"; systemctl poweroff; fi' \
  > /usr/local/sbin/nago-idle
chmod +x /usr/local/sbin/nago-idle
printf '[Unit]\nDescription=NAGO idle check\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/nago-idle\n' \
  > /etc/systemd/system/nago-idle.service
printf '[Unit]\nDescription=NAGO idle check every minute\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=5s\n[Install]\nWantedBy=timers.target\n' \
  > /etc/systemd/system/nago-idle.timer
systemctl daemon-reload
systemctl enable --now nago-idle.timer
systemd-run --unit nago-ttl --on-active=24h /usr/bin/systemctl poweroff

echo "@READY@ wg0=$(cat /sys/class/net/wg0/operstate 2>/dev/null || echo missing) peers=@NPEERS@"

# ---- TCP 분할 가속(고정 서버의 nago-accel과 같음): wg0 사용자의 TCP를 haproxy가 받아 서버에서 새로 잇는다.
# 먼 경로(폰↔서버)는 서버의 BBR·큰 버퍼로, 서버↔목적지는 짧은 경로로 따로 돈다. 사설망은 빼고, 12345는 REDIRECT로
# 들어온 연결만 받는다(직접 붙으면 자기 자신에게 무한 연결). haproxy가 멈추면 BindsTo로 규칙도 같이 내려간다
# (안 그러면 모든 TCP가 죽은 포트로 간다). 설치는 위 WireGuard와 따로 돈다 — 그동안에도 연결은 된다.
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
exec > >(tee -a /var/log/nago-ondemand.log /dev/console) 2>&1
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
"""


def od_find(code, cfg):
    """그 나라에 지금 떠 있는(켜지는 중 포함) 임시 서버"""
    r = client("ec2", cfg["region"]).describe_instances(Filters=[
        {"Name": "tag:" + OD_TAG, "Values": [code]},
        {"Name": "instance-state-name", "Values": ["pending", "running"]}])
    found = [i for x in r["Reservations"] for i in x["Instances"]]
    return max(found, key=lambda i: i["LaunchTime"]) if found else None


def od_count():
    """모든 임시 서버 리전에 떠 있는 수"""
    regions = sorted({c["region"] for c in ONDEMAND.values()})
    ec2s = [client("ec2", r) for r in regions]   # 클라이언트는 스레드 밖에서 만든다

    def one(ec2):
        r = ec2.describe_instances(Filters=[{"Name": "tag-key", "Values": [OD_TAG]},
                                            {"Name": "instance-state-name", "Values": ["pending", "running"]}])
        return sum(len(x["Instances"]) for x in r["Reservations"])

    with cf.ThreadPoolExecutor(max(1, len(ec2s))) as ex:
        return sum(ex.map(one, ec2s))


def od_security_group(ec2):
    """기본 VPC에 udp 443/51820만 연 보안 그룹(없으면 만든다)"""
    vpc = ec2.describe_vpcs(Filters=[{"Name": "is-default", "Values": ["true"]}])["Vpcs"][0]["VpcId"]
    flt = [{"Name": "group-name", "Values": [OD_SG]}, {"Name": "vpc-id", "Values": [vpc]}]
    found = ec2.describe_security_groups(Filters=flt)["SecurityGroups"]
    if found:
        return found[0]["GroupId"]
    try:
        gid = ec2.create_security_group(GroupName=OD_SG, Description="NAGO VPN on-demand WireGuard",
                                        VpcId=vpc)["GroupId"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidGroup.Duplicate":
            raise
        return ec2.describe_security_groups(Filters=flt)["SecurityGroups"][0]["GroupId"]
    ec2.authorize_security_group_ingress(GroupId=gid, IpPermissions=[
        {"IpProtocol": "udp", "FromPort": p, "ToPort": p, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}
        for p in sorted({WG_PORT, 51820})])
    return gid


def od_peers():
    """지금 피어 목록(공개키, ip). 스크립트에 그대로 들어가니 모양을 확인한다."""
    value = client("ssm", "ap-northeast-2").get_parameter(Name="/nago/wg/peers")["Parameter"]["Value"]
    return [(p["pub"], p["ip"]) for p in json.loads(value).get("peers", [])
            if PEER_KEY_RE.match(str(p.get("pub", ""))) and PEER_IP_RE.match(str(p.get("ip", "")))]


def od_alarm(region, iid, account):
    """서버가 멎어서 스스로 못 끄는 경우를 대비한 AWS 쪽 안전장치: 1시간 동안 송신이 5분에 1MB도 안 되면 지운다.
    서버 안의 유휴 검사(분당 300KB, 30분)보다 느슨해서 평소에는 서버가 먼저 꺼진다. 지난 서버의 경보는 여기서 치운다."""
    cw = client("cloudwatch", region)
    try:
        alive = {i["InstanceId"] for x in client("ec2", region).describe_instances(Filters=[
            {"Name": "tag-key", "Values": [OD_TAG]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}])["Reservations"]
            for i in x["Instances"]} | {iid}
        stale = [a["AlarmName"] for a in cw.describe_alarms(AlarmNamePrefix="nago-ondemand-")["MetricAlarms"]
                 if a["AlarmName"][len("nago-ondemand-"):] not in alive]
        if stale:
            cw.delete_alarms(AlarmNames=stale[:100])
        cw.put_metric_alarm(
            AlarmName="nago-ondemand-" + iid, Namespace="AWS/EC2", MetricName="NetworkOut",
            Dimensions=[{"Name": "InstanceId", "Value": iid}], Statistic="Sum", Period=300,
            EvaluationPeriods=12, Threshold=1_000_000, ComparisonOperator="LessThanThreshold",
            TreatMissingData="missing",
            # 역할(Lambda) 자격으로 EC2 동작을 걸 때는 swf 모양의 ARN을 쓴다
            AlarmActions=["arn:aws:swf:%s:%s:action/actions/AWS_EC2.InstanceId.Terminate/1.0" % (region, account)])
    except Exception as e:   # 안전장치일 뿐이라 서버 만들기는 막지 않는다
        print("alarm: %s" % e)


def od_create(code, cfg, account):
    region = cfg["region"]
    ec2 = client("ec2", region)
    ami = client("ssm", region).get_parameter(Name=OD_AMI)["Parameter"]["Value"]
    private, public = wg_keypair()
    peers = od_peers()
    script = (OD_SCRIPT.replace("@CODE@", code).replace("@KEY@", private).replace("@PORT@", str(WG_PORT))
              .replace("@READY@", OD_READY).replace("@NPEERS@", str(len(peers)))
              # printf 서식 문자열로 들어간다: \n은 printf가 줄바꿈으로 바꾼다(키·ip에는 %나 \가 없다)
              .replace("@PEERS@", "".join("\\n[WireGuardPeer]\\nPublicKey=%s\\nAllowedIPs=%s/32\\n" % p
                                          for p in peers)))
    tags = [{"Key": "Name", "Value": "nago-ondemand-" + code}, {"Key": OD_TAG, "Value": code},
            {"Key": OD_PUB_TAG, "Value": public}]
    inst = ec2.run_instances(
        ImageId=ami, InstanceType=OD_TYPE, MinCount=1, MaxCount=1,
        SecurityGroupIds=[od_security_group(ec2)],
        UserData=script, InstanceInitiatedShutdownBehavior="terminate",
        MetadataOptions={"HttpTokens": "required", "HttpEndpoint": "enabled"},
        # 앱이 몇 초마다 다시 묻다가 겹쳐 들어와도 1분 안에서는 같은 서버 하나로 끝난다
        ClientToken="nago-%s-%d" % (code, int(time.time() // 60)),
        TagSpecifications=[{"ResourceType": "instance", "Tags": tags},
                           {"ResourceType": "volume", "Tags": tags[:2]}])["Instances"][0]
    od_alarm(region, inst["InstanceId"], account)
    return inst


def od_ready(cfg, inst):
    """WireGuard가 올라왔는지: 서버가 콘솔에 남긴 준비 표시를 본다."""
    if inst["State"]["Name"] != "running":
        return False
    try:
        out = client("ec2", cfg["region"]).get_console_output(
            InstanceId=inst["InstanceId"], Latest=True).get("Output") or ""
        if OD_READY not in out:
            try:
                out = base64.b64decode(out).decode("utf-8", "replace")
            except ValueError:
                pass
        if OD_READY in out:
            return True
    except Exception:
        pass
    up = (datetime.datetime.now(datetime.timezone.utc) - inst["LaunchTime"]).total_seconds()
    return up > OD_GRACE_SEC


def ondemand(code, cfg, account):
    inst = od_find(code, cfg)
    state = None
    if not inst:
        if od_count() >= OD_MAX:
            return resp(409, {"error": "too many on-demand servers", "max": OD_MAX})
        inst = od_create(code, cfg, account)
        state = "creating"
    tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
    running = inst["State"]["Name"] == "running"
    return resp(200, {
        "region": code,
        "state": state or inst["State"]["Name"],
        "ready": od_ready(cfg, inst),
        "ip": inst.get("PublicIpAddress") if running else None,
        "id": code + ".nago.vpn",
        "wgPub": tags.get(OD_PUB_TAG),
        "wgPort": WG_PORT,
        "onDemand": True,
        "launched": inst["LaunchTime"].isoformat(),
    })


def handler(event, context):
    # 직접 호출(Lambda Invoke — IAM 권한이 있어야 함)은 비밀번호 없이 받는다: {"nago_internal": "region", "r": "sg"}.
    # API Gateway로 들어온 요청에는 늘 requestContext가 있어서 이 길로 올 수 없다.
    internal = "requestContext" not in event and event.get("nago_internal") == "region"
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    key = headers.get("x-nago-key", "")
    if not internal and not hmac.compare_digest(hashlib.sha256(key.encode()).hexdigest(), KEY_SHA):
        return resp(403, {"error": "forbidden"})

    code = event.get("r", "") if internal else (event.get("queryStringParameters") or {}).get("r", "")
    if code in ONDEMAND:
        return ondemand(code, ONDEMAND[code], context.invoked_function_arn.split(":")[4])
    cfg = REGIONS.get(code)
    if not cfg:
        return resp(404, {"error": "unknown region", "regions": sorted(REGIONS), "onDemand": sorted(ONDEMAND)})

    ec2 = client("ec2", cfg["region"])
    inst = ec2.describe_instances(InstanceIds=[cfg["iid"]])["Reservations"][0]["Instances"][0]
    state = inst["State"]["Name"]
    if state == "stopped":
        ec2.start_instances(InstanceIds=[cfg["iid"]])
        state = "pending"

    ready = state == "running" and is_ready(cfg, inst)
    if ready:
        request_sync(code)
    return resp(200, {
        "region": code,
        "state": state,
        "ready": ready,
        "ip": inst.get("PublicIpAddress") if state == "running" else None,
        "id": cfg["id"],
        "wgPub": wg_servers().get(code, {}).get("pub"),
        "wgPort": WG_PORT,
    })
