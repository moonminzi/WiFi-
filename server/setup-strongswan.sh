#!/usr/bin/env bash
#
# WifiScan VPN - IKEv2/EAP-MSCHAPv2 서버(strongSwan) 자동 구축 스크립트
# 대상: Ubuntu 22.04 (amd64). root로 실행하세요.
#
# 하는 일
#   1) strongSwan + 필요한 플러그인(eap-mschapv2) 설치
#   2) 자체 CA + 서버 인증서 생성(서버 공인 IP를 SAN에 넣음). 이미 있으면 재사용.
#   3) IKEv2 커넥션/EAP 사용자 구성
#   4) IP 포워딩 + NAT(MASQUERADE)로 클라이언트가 인터넷을 쓰도록 설정
#   5) 서비스 기동
#
# 끝나면 /etc/ipsec.d/cacerts/ca-cert.pem (CA 인증서)을 아이폰에 설치해 신뢰해야 합니다.
# 앱(VPN 탭)에는 서버 공인 IP / 사용자 이름 / 비밀번호를 넣습니다.
#
# 사용법:
#   sudo VPN_PUBLIC_IP=1.2.3.4 VPN_EAP_USER=wifiscan VPN_EAP_PASS=비밀번호 ./setup-strongswan.sh
#   (VPN_EAP_PASS 생략 시 임의 생성해서 마지막에 출력)
#
set -euo pipefail

VPN_PUBLIC_IP="${VPN_PUBLIC_IP:?VPN_PUBLIC_IP(서버 공인 IP)를 지정하세요}"
VPN_EAP_USER="${VPN_EAP_USER:-wifiscan}"
VPN_EAP_PASS="${VPN_EAP_PASS:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)}"
VPN_POOL="${VPN_POOL:-10.10.10.0/24}"

export DEBIAN_FRONTEND=noninteractive

echo ">> 패키지 설치"
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait || true
for i in $(seq 1 30); do apt-get update -y && break || sleep 10; done
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install -y strongswan strongswan-pki libcharon-extra-plugins \
    libcharon-extauth-plugins libstrongswan-extra-plugins iptables-persistent openssl

mkdir -p /etc/ipsec.d/cacerts /etc/ipsec.d/certs /etc/ipsec.d/private

if [ ! -f /etc/ipsec.d/cacerts/ca-cert.pem ]; then
    echo ">> CA + 서버 인증서 생성 (SAN=IP:${VPN_PUBLIC_IP})"
    openssl genrsa -out /etc/ipsec.d/private/ca-key.pem 3072
    openssl req -x509 -new -nodes -key /etc/ipsec.d/private/ca-key.pem -sha256 -days 3650 \
        -subj "/CN=WifiScan VPN Root CA/O=WifiScan" -out /etc/ipsec.d/cacerts/ca-cert.pem

    openssl genrsa -out /etc/ipsec.d/private/server-key.pem 3072
    openssl req -new -key /etc/ipsec.d/private/server-key.pem \
        -subj "/CN=${VPN_PUBLIC_IP}/O=WifiScan" -out /tmp/server.csr
    cat > /tmp/server-ext.cnf <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:${VPN_PUBLIC_IP}
EXT
    openssl x509 -req -in /tmp/server.csr \
        -CA /etc/ipsec.d/cacerts/ca-cert.pem -CAkey /etc/ipsec.d/private/ca-key.pem -CAcreateserial \
        -out /etc/ipsec.d/certs/server-cert.pem -days 1825 -sha256 -extfile /tmp/server-ext.cnf
    rm -f /tmp/server.csr /tmp/server-ext.cnf
    chmod 600 /etc/ipsec.d/private/*.pem
else
    echo ">> 기존 인증서 재사용"
fi

echo ">> /etc/ipsec.conf 작성"
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=never

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=${VPN_PUBLIC_IP}
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=${VPN_POOL}
    rightdns=1.1.1.1,8.8.8.8
    rightsendcert=never
    eap_identity=%identity
    ike=aes256gcm16-prfsha256-ecp256,aes256-sha256-modp2048,aes256-sha256-ecp256,aes128-sha256-modp2048
    esp=aes256gcm16-ecp256,aes256-sha256,aes128-sha256
EOF

echo ">> /etc/ipsec.secrets 작성"
cat > /etc/ipsec.secrets <<EOF
: RSA "server-key.pem"
${VPN_EAP_USER} : EAP "${VPN_EAP_PASS}"
EOF
chmod 600 /etc/ipsec.secrets

echo ">> IP 포워딩"
cat > /etc/sysctl.d/99-vpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF
sysctl -p /etc/sysctl.d/99-vpn.conf

echo ">> NAT(MASQUERADE)"
DEFIF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -s "${VPN_POOL}" -o "$DEFIF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${VPN_POOL}" -o "$DEFIF" -j MASQUERADE
iptables -C FORWARD -s "${VPN_POOL}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "${VPN_POOL}" -j ACCEPT
iptables -C FORWARD -d "${VPN_POOL}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "${VPN_POOL}" -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
netfilter-persistent save

echo ">> strongSwan 기동"
systemctl enable strongswan-starter
systemctl restart strongswan-starter
sleep 4
ipsec statusall || true

cat <<DONE

========================================================================
 WifiScan VPN 서버 준비 완료
------------------------------------------------------------------------
 서버 공인 IP : ${VPN_PUBLIC_IP}
 사용자 이름   : ${VPN_EAP_USER}
 비밀번호      : ${VPN_EAP_PASS}
 CA 인증서     : /etc/ipsec.d/cacerts/ca-cert.pem  (아이폰에 설치 후 신뢰)
------------------------------------------------------------------------
 방화벽/보안그룹에서 UDP 500, UDP 4500 인바운드를 열어야 합니다.
 (NAT 게이트웨이 역할이므로 클라우드에서는 source/dest check도 꺼야 합니다.)
========================================================================
DONE
