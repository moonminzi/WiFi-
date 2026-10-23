#!/bin/sh
# NAGO signer Lambda(server/signer)에 넣을 rcodesign(apple-codesign, MPL-2.0)을 정적(musl)으로 빌드한다.
# Lambda(Amazon Linux 2023)의 glibc가 낮아서 보통 빌드는 돌지 않는다.
#
#   sudo apt-get install -y musl-tools     # Ubuntu
#   tools/build-rcodesign-lambda.sh build/rcodesign
#   → build/rcodesign/bin/rcodesign (약 22MB, static-pie)
set -eu
ROOT="${1:-build/rcodesign}"
rustup target add x86_64-unknown-linux-musl
CC_x86_64_unknown_linux_musl=musl-gcc CARGO_PROFILE_RELEASE_STRIP=true \
  cargo install apple-codesign --version 0.29.0 --locked --target x86_64-unknown-linux-musl --root "$ROOT"
file "$ROOT/bin/rcodesign"
