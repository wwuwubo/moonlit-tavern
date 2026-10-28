#!/usr/bin/env bash
# 把 .app 打成未签名 IPA（Payload/MoonlitTavern.app）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/DerivedData/Build/Products/Release-iphoneos/MoonlitTavern.app"
OUT="build/MoonlitTavern-unsigned.ipa"

rm -rf build/ipa "$OUT"
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
( cd build/ipa && zip -qry ../MoonlitTavern-unsigned.ipa Payload )
ls -lh "$OUT"
shasum -a 256 "$OUT" | tee build/MoonlitTavern-unsigned.ipa.sha256
