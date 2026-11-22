#!/usr/bin/env bash
#
# setup-region.sh에 넘길 번들(서버 인증서 + 비밀번호 파일)을 기존 CA로 만든다.
# CA 개인키가 있는 내 PC에서 실행한다(윈도우는 Git Bash). CA 키는 서버에 올리지 않는다.
#
#   VPN_EAP_USER=wifiscan VPN_EAP_PASS='<VPN 비밀번호>' \
#     ./make-bundle.sh <ca-cert.pem> <ca-key.pem> <id> [추가 IP ...]
#
#   해외: ./make-bundle.sh ca-cert.pem ca-key.pem jp.nago.vpn
#   서울: ./make-bundle.sh ca-cert.pem ca-key.pem 141.164.x.x     (ID = 서울 공인 IP)
#
# 결과: ./bundle-<id>/ (ca-cert.pem server-cert.pem server-key.pem ipsec.secrets id)
#  → scp -r bundle-<id> root@<서버>:/root/  후 서버에서  sudo ./setup-region.sh /root/bundle-<id>
#
# 번들에는 비밀번호와 서버 개인키가 들어 있으니 서버에 설치한 뒤 지우고, 레포에 올리지 마세요.
set -euo pipefail
# Git Bash가 -subj "/CN=..."를 윈도우 경로로 바꾸지 않게(그 인자만 뺀다. 다른 절대 경로는 그대로 바뀌어야 함)
export MSYS2_ARG_CONV_EXCL="/CN="

CA_CERT="${1:?ca-cert.pem 경로}"
CA_KEY="${2:?ca-key.pem 경로}"
ID="${3:?서버 ID (예: jp.nago.vpn 또는 서울 IP)}"
shift 3
: "${VPN_EAP_USER:?VPN_EAP_USER가 필요합니다}"
: "${VPN_EAP_PASS:?VPN_EAP_PASS가 필요합니다}"

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

SAN=""
if is_ip "$ID"; then SAN="IP:${ID}"; else SAN="DNS:${ID}"; fi
for extra in "$@"; do
    if is_ip "$extra"; then SAN="${SAN},IP:${extra}"; else SAN="${SAN},DNS:${extra}"; fi
done

OUT="bundle-${ID}"
[ -e "$OUT" ] && { echo "${OUT}가 이미 있습니다. 지우고 다시 실행하세요."; exit 1; }
mkdir "$OUT"
chmod 700 "$OUT" 2>/dev/null || true   # Git Bash(윈도우)에서는 권한 변경이 안 될 수 있다
umask 077

openssl genrsa -out "$OUT/server-key.pem" 3072 2>/dev/null
openssl req -new -key "$OUT/server-key.pem" -subj "/CN=${ID}/O=WifiScan" -out "$OUT/server.csr"
cat > "$OUT/ext.cnf" <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,1.3.6.1.5.5.8.2.2
subjectAltName=${SAN}
EXT
openssl x509 -req -in "$OUT/server.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -CAserial "$OUT/ca.srl" -out "$OUT/server-cert.pem" -days 1825 -sha256 -extfile "$OUT/ext.cnf" 2>/dev/null
rm -f "$OUT/server.csr" "$OUT/ext.cnf" "$OUT/ca.srl"

cp "$CA_CERT" "$OUT/ca-cert.pem"
printf '%s\n' "$ID" > "$OUT/id"
printf ': RSA "server-key.pem"\n%s : EAP "%s"\n' "$VPN_EAP_USER" "$VPN_EAP_PASS" > "$OUT/ipsec.secrets"

openssl verify -CAfile "$OUT/ca-cert.pem" "$OUT/server-cert.pem"
openssl x509 -noout -subject -ext subjectAltName -enddate -in "$OUT/server-cert.pem"
echo "-> ${OUT}/"
