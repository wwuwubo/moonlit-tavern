#!/usr/bin/env bash
# 真机（iphoneos）Release 构建，不签名。产物供全能签等工具重新签名。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs build

{
  echo "== 构建环境 =="
  xcodebuild -version
  swift --version 2>&1 | head -2
  echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
  sw_vers
} | tee logs/environment.log

set -o pipefail
xcodebuild \
  -project MoonlitTavern.xcodeproj \
  -scheme MoonlitTavern \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-0}" \
  build 2>&1 | tee logs/xcodebuild.log

APP="build/DerivedData/Build/Products/Release-iphoneos/MoonlitTavern.app"
test -d "$APP" || { echo "未找到 $APP"; exit 1; }
echo "构建成功：$APP"
