#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
curl --fail --location --retry 3 https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.5.2.tar.gz -o "$TEMP/opus.tar.gz"
echo '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1  '"$TEMP/opus.tar.gz" | shasum -a 256 -c -
tar -xzf "$TEMP/opus.tar.gz" -C "$TEMP"
cmake -S "$TEMP/opus-1.5.2" -B "$TEMP/build" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$ROOT/Opus" \
  -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_SHARED_LIBRARY=OFF
cmake --build "$TEMP/build" --parallel 3
cmake --install "$TEMP/build"
# Opus installs headers under include/opus; C wrapper uses this stable forwarding header.
printf '#include "opus/opus.h"\n' > "$ROOT/Opus/include/opus.h"
cp "$TEMP/opus-1.5.2/COPYING" "$ROOT/Opus/LICENSE.txt"
