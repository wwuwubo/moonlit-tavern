#!/usr/bin/env bash
# 在 macOS 上用真实 GGUF 模型运行 App 的推理引擎代码（LlamaEngine.swift 原样编译）。
# 用法：scripts/run-engine-harness.sh <模型下载地址> <标签> [上下文长度]
set -euo pipefail

MODEL_URL="${1:?模型地址}"
LABEL="${2:?标签}"
CTX="${3:-8192}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
H=Tools/EngineHarness

mkdir -p logs models
rm -rf "$H/llama.xcframework" "$H/Sources/EngineHarness/Shared"
cp -R Vendor/llama.xcframework "$H/llama.xcframework"
mkdir -p "$H/Sources/EngineHarness/Shared"
cp MoonlitTavern/Inference/LlamaEngine.swift MoonlitTavern/Inference/DeviceMetrics.swift "$H/Sources/EngineHarness/Shared/"

MODEL="models/$(basename "$MODEL_URL")"
if [[ ! -f "$MODEL" ]]; then
  echo "下载模型 $MODEL_URL"
  curl -fL --retry 3 --retry-delay 5 -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi
ls -lh "$MODEL"
head -c 4 "$MODEL" | grep -q GGUF || { echo "下载的文件不是 GGUF"; exit 1; }

{
  echo "== 主机 =="
  sysctl -n machdep.cpu.brand_string || true
  sysctl -n hw.memsize | awk '{printf "内存 %.1f GB\n", $1/1073741824}'
  sw_vers
  swift --version 2>&1 | head -1
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Metal" || true
} | tee "logs/engine-$LABEL-host.log"

set -o pipefail
( cd "$H" && swift build -c release 2>&1 ) | tee "logs/engine-$LABEL-build.log"
"$H/.build/release/EngineHarness" "$MODEL" --ctx "$CTX" --out "logs/engine-$LABEL.json" 2>&1 | tee "logs/engine-$LABEL.log"
