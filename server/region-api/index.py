"""NAGO VPN 국가 선택 API.

GET /region?r=<kr|jp|us|uk>  (헤더 x-nago-key: VPN 비밀번호)
→ 꺼져 있으면 켜고, {"state", "ready", "ip", "id"}를 돌려준다.
앱은 ready가 true가 될 때까지 몇 초마다 다시 부르고, ip/id로 IKEv2 설정을 만든다.
WireGuard용으로 그 서버의 공개키/포트(wgPub, wgPort)도 준다. 서버가 준비되면 대시보드 Lambda에
피어 동기화를 부탁한다(꺼져 있는 동안 바뀐 피어 목록을 맞춤).
"""
import datetime
import time
import hashlib
import hmac
import json
import os

import boto3

REGIONS = json.loads(os.environ["REGIONS"])
KEY_SHA = os.environ["KEY_SHA256"]
# 켜진 지 이만큼 지나면 SSM 확인 없이도 준비된 걸로 본다.
BOOT_GRACE_SEC = 100
WG_PORT = 443          # 서버에서 51820으로 넘겨 준다. 잘 안 막히는 포트
DASH_FUNCTION = os.environ.get("DASH_FUNCTION", "nago-dash")
_wg = {"t": 0, "v": {}}

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


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    key = headers.get("x-nago-key", "")
    if not hmac.compare_digest(hashlib.sha256(key.encode()).hexdigest(), KEY_SHA):
        return resp(403, {"error": "forbidden"})

    code = (event.get("queryStringParameters") or {}).get("r", "")
    cfg = REGIONS.get(code)
    if not cfg:
        return resp(404, {"error": "unknown region", "regions": sorted(REGIONS)})

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
