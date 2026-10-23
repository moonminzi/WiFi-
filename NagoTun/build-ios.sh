#!/bin/sh
# Xcode의 NagoTunRust 타깃(External Build System)이 부른다.
# NepTUN 엔진(Rust)을 iOS용 정적 라이브러리 libnago_tun.a로 빌드해 CONFIGURATION_BUILD_DIR에 둔다.
set -eu

DEST="${CONFIGURATION_BUILD_DIR:?}"
if [ "${ACTION:-build}" = "clean" ]; then
  rm -f "$DEST/libnago_tun.a"
  exit 0
fi

case "${PLATFORM_NAME:-iphoneos}" in
  iphoneos) TARGET=aarch64-apple-ios ;;
  iphonesimulator) TARGET=aarch64-apple-ios-sim ;;
  *) echo "nago_tun: unsupported platform ${PLATFORM_NAME}" >&2; exit 1 ;;
esac

cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
rustup target add "$TARGET" >/dev/null 2>&1 || true

# Xcode가 넘기는 빌드 설정(SDKROOT 등)이 섞이면 build.rs(맥용)가 iOS SDK로 링크하다 깨진다.
# 깨끗한 환경에서 cargo를 돌리고, iOS SDK는 cc-rs가 xcrun으로 찾게 한다.
env -i HOME="$HOME" PATH="$PATH" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} \
  IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" \
  cargo build --release --locked --lib --target "$TARGET"

mkdir -p "$DEST"
cp "target/$TARGET/release/libnago_tun.a" "$DEST/libnago_tun.a"
echo "nago_tun: $DEST/libnago_tun.a"
