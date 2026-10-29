#!/usr/bin/env bash
# 端到端 UI 测试：在 iPad 模拟器上运行真实 App + 真实 llama.cpp + 真实 GGUF 模型。
# 1. 从源码构建 llama.cpp 的 iOS 模拟器 XCFramework（官方发布包只含真机切片）
# 2. 生成工程、下载模型、启动 iPad 模拟器
# 3. xcodebuild test 运行 MoonlitTavernUITests，收集截图
# 用法：scripts/run-simulator-test.sh <模型下载地址>
set -euo pipefail

MODEL_URL="${1:?模型地址}"
TAG="${LLAMA_TAG:-b11960}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs logs/screenshots models build

# ---- llama.cpp 模拟器切片 ----
if [[ ! -f build/llama-sim/.tag || "$(cat build/llama-sim/.tag)" != "$TAG" ]]; then
  rm -rf build/llama-src build/llama-sim
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git build/llama-src
  # 只构建 arm64 模拟器（Apple 芯片机器），编译时间减半
  perl -0pi -e 's/arm64;x86_64/arm64/' build/llama-src/build-xcframework.sh
  ( cd build/llama-src && ./build-xcframework.sh ios-sim ) > logs/llama-sim-build-full.log 2>&1 || { tail -60 logs/llama-sim-build-full.log; exit 1; }
  tail -40 logs/llama-sim-build-full.log | tee logs/llama-sim-build.log
  mkdir -p build/llama-sim
  cp -R build/llama-src/build-apple/llama.xcframework build/llama-sim/llama.xcframework
  echo "$TAG" > build/llama-sim/.tag
fi
rm -rf Vendor/llama.xcframework
mkdir -p Vendor
cp -R build/llama-sim/llama.xcframework Vendor/llama.xcframework
echo "模拟器 XCFramework 切片："; ls Vendor/llama.xcframework

# ---- 工程 ----
xcodegen generate

# ---- 模型 ----
MODEL_DIR="$ROOT/models/uitest"
if [[ "${MOONLIT_SMOKE_TEST:-0}" != "1" ]]; then
  mkdir -p "$MODEL_DIR"
  MODEL="$MODEL_DIR/$(basename "$MODEL_URL")"
  if [[ ! -f "$MODEL" ]]; then
    curl -fL --retry 3 --retry-delay 5 -o "$MODEL.part" "$MODEL_URL"
    mv "$MODEL.part" "$MODEL"
  fi
  ls -lh "$MODEL"
fi

# ---- 模拟器 ----
xcrun simctl list devices available > logs/simulators.txt
DEVICE_LINE="$(grep -m1 -E "iPad Pro 13-inch \(M[0-9]+\)" logs/simulators.txt || grep -m1 -E "iPad Pro" logs/simulators.txt || grep -m1 "iPad" logs/simulators.txt)"
UDID="$(echo "$DEVICE_LINE" | grep -oE "[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}")"
echo "使用模拟器：$DEVICE_LINE" | tee logs/simulator-device.txt
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b

# ---- 运行 UI 测试 ----
set -o pipefail
if [[ "${MOONLIT_SMOKE_TEST:-0}" != "1" ]]; then
  export TEST_RUNNER_MOONLIT_MODEL_DIR="$MODEL_DIR"
fi
export TEST_RUNNER_SCREENSHOT_DIR="$ROOT/logs/screenshots"
TEST_FILTER=()
if [[ "${MOONLIT_SMOKE_TEST:-0}" == "1" ]]; then
  TEST_FILTER=("-only-testing:MoonlitTavernUITests/MoonlitTavernUITests/testPasteJSONCharacterCard")
fi
export TEST_RUNNER_MOONLIT_MAX_TOKENS="${MAX_TOKENS:-48}"
export TEST_RUNNER_MOONLIT_CONTEXT="${CONTEXT:-2048}"
xcodebuild \
  -project MoonlitTavern.xcodeproj \
  -scheme MoonlitTavern \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/SimDerivedData \
  -resultBundlePath build/UITest.xcresult \
  CODE_SIGN_IDENTITY=- \
  "${TEST_FILTER[@]}" \
  test 2>&1 | tee logs/uitest.log
