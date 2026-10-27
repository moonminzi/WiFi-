#!/bin/sh
# 시뮬레이터에 UIShots 앱을 깔고 탭·데모 상태마다 스크린샷을 찍는다.
# 사용: shoot.sh <앱 경로> <출력 폴더>
set -eu
APP="$1"
OUT="$2"
BUNDLE=com.nago.uishots
mkdir -p "$OUT"

# 이름에 이 글자가 들어간 사용 가능한 기기 중 첫 번째
pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
want = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if want in d["name"]:
            print(d["udid"]); sys.exit(0)
sys.exit(1)' "$1"
}

shoot() {  # 기기 이름표, udid, 장면 이름, 실행 인자…
  label="$1"; udid="$2"; scene="$3"; shift 3
  # 기본 화면 모양은 system이고 시뮬레이터는 라이트라서, 따로 정하지 않은 장면은 다크로 찍는다
  case " $* " in *" -appearance "*) ;; *) set -- "$@" -appearance dark ;; esac
  xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$BUNDLE" "$@" >/dev/null
  sleep 5
  xcrun simctl io "$udid" screenshot "$OUT/$label-$scene.png" >/dev/null
  echo "shot $label-$scene"
}

run_device() {  # 이름표, 찾을 이름
  label="$1"
  udid=$(pick "$2") || { echo "no simulator matching $2"; return 0; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 || true
  xcrun simctl install "$udid" "$APP"
  for demo in idle connecting connected failed scan; do
    shoot "$label" "$udid" "vpn-$demo" -nagoTab 0 -nagoDemo "$demo" -nagoScrollEnd NO
  done
  shoot "$label" "$udid" vpn-connected-end -nagoTab 0 -nagoDemo connected -nagoScrollEnd YES
  shoot "$label" "$udid" vpn-idle-end -nagoTab 0 -nagoDemo idle -nagoScrollEnd YES
  shoot "$label" "$udid" dash -nagoTab 1 -nagoDemo connected
  shoot "$label" "$udid" settings -nagoTab 2 -nagoDemo idle
  # 라이트 모드(settings → appearance와 같은 키를 실행 인자로)
  shoot "$label" "$udid" light-vpn-connected -nagoTab 0 -nagoDemo connected -nagoScrollEnd NO -appearance light
  shoot "$label" "$udid" light-vpn-connected-end -nagoTab 0 -nagoDemo connected -nagoScrollEnd YES -appearance light
  shoot "$label" "$udid" light-dash -nagoTab 1 -nagoDemo connected -appearance light
  shoot "$label" "$udid" light-settings -nagoTab 2 -nagoDemo idle -appearance light
  # 유저용(친구에게 주는 판)
  shoot "$label" "$udid" user-vpn-connected -nagoTab 0 -nagoDemo connected -nagoScrollEnd NO -nagoEdition user
  shoot "$label" "$udid" user-vpn-connected-end -nagoTab 0 -nagoDemo connected -nagoScrollEnd YES -nagoEdition user
  shoot "$label" "$udid" user-settings -nagoTab 2 -nagoDemo idle -nagoEdition user
  xcrun simctl shutdown "$udid" || true
}

run_device iphone "iPhone 16 Pro"
run_device iphone-se "iPhone SE"
run_device ipad "iPad Pro 13"
