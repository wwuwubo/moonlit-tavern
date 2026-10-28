#!/usr/bin/env bash
# 下载 llama.cpp 官方发布的预编译 XCFramework（含 iOS arm64 与 macOS 切片，Metal 着色器已内嵌），
# 校验 SHA-256 后解压到 Vendor/llama.xcframework。
set -euo pipefail

TAG="${LLAMA_TAG:-b11960}"
SHA256="${LLAMA_SHA256:-feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759}"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"

if [[ -d llama.xcframework && -f llama.xcframework/.tag && "$(cat llama.xcframework/.tag)" == "$TAG" ]]; then
  echo "llama.xcframework ${TAG} 已存在，跳过下载"
  exit 0
fi

echo "下载 ${URL}"
curl -fL --retry 3 --retry-delay 5 -o llama.zip "$URL"
echo "${SHA256}  llama.zip" | shasum -a 256 -c -

rm -rf llama.xcframework build-apple
unzip -q llama.zip
mv build-apple/llama.xcframework ./llama.xcframework
rm -rf build-apple llama.zip
echo "$TAG" > llama.xcframework/.tag

echo "XCFramework 切片："
ls llama.xcframework
