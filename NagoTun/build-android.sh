#!/bin/sh
# 안드로이드 앱 Gradle(buildNagoTun 작업)이 부른다.
# NepTUN 엔진(Rust)을 libnago_tun.so로 빌드해 <출력 폴더>/<ABI>/에 둔다. NDK와 Rust가 필요하다.
# 사용: build-android.sh <출력 jniLibs 폴더> [ABI ...]   (기본: arm64-v8a armeabi-v7a)
set -eu

OUT="$1"
shift
ABIS="${*:-arm64-v8a armeabi-v7a}"
API=33   # 앱 minSdk와 같게

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  NDK=$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)
fi
[ -d "$NDK" ] || { echo "nago_tun: Android NDK not found (ANDROID_NDK_HOME or \$ANDROID_HOME/ndk)" >&2; exit 1; }
HOST=$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64
BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"

cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

for abi in $ABIS; do
  case "$abi" in
    arm64-v8a) TARGET=aarch64-linux-android; CLANG=aarch64-linux-android$API-clang ;;
    armeabi-v7a) TARGET=armv7-linux-androideabi; CLANG=armv7a-linux-androideabi$API-clang ;;
    x86_64) TARGET=x86_64-linux-android; CLANG=x86_64-linux-android$API-clang ;;
    *) echo "nago_tun: unsupported ABI $abi" >&2; exit 1 ;;
  esac
  rustup target add "$TARGET" >/dev/null 2>&1 || true
  VAR=$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')
  T=$(echo "$TARGET" | tr '-' '_')
  # 링크는 NDK clang, ring(C 코드)도 같은 clang으로. 16KB 페이지 기기(안드로이드 15+)에서도 로드되게 정렬.
  env "CARGO_TARGET_${VAR}_LINKER=$BIN/$CLANG" "CC_$T=$BIN/$CLANG" "AR_$T=$BIN/llvm-ar" \
    cargo rustc --release --locked --lib --target "$TARGET" --crate-type cdylib -- \
      -C strip=symbols -C link-arg=-Wl,-z,max-page-size=16384
  mkdir -p "$OUT/$abi"
  cp "target/$TARGET/release/libnago_tun.so" "$OUT/$abi/libnago_tun.so"
  echo "nago_tun: $OUT/$abi/libnago_tun.so"
done
