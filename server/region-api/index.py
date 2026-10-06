"""NAGO VPN 국가 선택 API.

GET /region?r=<kr|jp|us|uk>  (헤더 x-nago-key: VPN 비밀번호)
→ 꺼져 있으면 켜고, {"state", "ready", "ip", "id"}를 돌려준다.
앱은 ready가 true가 될 때까지 몇 초마다 다시 부르고, ip/id로 IKEv2 설정을 만든다.
"""
import datetime
import hashlib
import hmac
import json
import os

import boto3

REGIONS = json.loads(os.environ["REGIONS"])
KEY_SHA = os.environ["KEY_SHA256"]
# 켜진 지 이만큼 지나면 SSM 확인 없이도 준비된 걸로 본다.
BOOT_GRACE_SEC = 100

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
    return resp(200, {
        "region": code,
        "state": state,
        "ready": ready,
        "ip": inst.get("PublicIpAddress") if state == "running" else None,
        "id": cfg["id"],
    })
