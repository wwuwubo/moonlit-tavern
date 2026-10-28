#!/usr/bin/env bash
# 检查 IPA 结构：目录布局、Info.plist、架构、动态库链接、Metal 后端、签名状态。
# 任何一项不符合都会以非零状态退出。
set -euo pipefail

IPA="${1:-build/MoonlitTavern-unsigned.ipa}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "❌ $*"; exit 1; }
pass() { echo "✅ $*"; }

unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/MoonlitTavern.app"
[[ -d "$APP" ]] && pass "Payload/MoonlitTavern.app 存在" || fail "缺少 Payload/MoonlitTavern.app"

echo "== 顶层文件 =="
ls -la "$APP" | head -40

PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] && pass "Info.plist 存在" || fail "缺少 Info.plist"
echo "== Info.plist 关键字段 =="
for key in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion MinimumOSVersion DTPlatformName DTSDKName UIDeviceFamily UIFileSharingEnabled; do
  printf "%-28s %s\n" "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null | tr '\n' ' ')"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$PLIST")" == "iphoneos" ]] && pass "平台为 iphoneos（真机，非模拟器）" || fail "平台不是 iphoneos"

EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
echo "== 主程序 =="
file "$EXE"
lipo -info "$EXE"
lipo -info "$EXE" | grep -q arm64 && pass "主程序为 arm64" || fail "主程序不是 arm64"

echo "== 动态库依赖 =="
otool -L "$EXE"
otool -L "$EXE" | grep -q "@rpath/llama.framework/llama" && pass "主程序链接 llama.framework" || fail "主程序没有链接 llama.framework"

FW="$APP/Frameworks/llama.framework/llama"
[[ -f "$FW" ]] && pass "Frameworks/llama.framework 已嵌入" || fail "llama.framework 没有嵌入"
lipo -info "$FW"
SYMS="$WORK/llama-symbols.txt"
nm -gU "$FW" > "$SYMS" 2>/dev/null || true
echo "导出符号数：$(wc -l < "$SYMS" | tr -d ' ')"
if grep -q " _ggml_backend_metal_init$" "$SYMS"; then pass "llama.framework 含 Metal 后端"; else fail "llama.framework 缺少 Metal 后端"; fi
if grep -q " _llama_decode$" "$SYMS"; then pass "llama.framework 导出 llama_decode"; else fail "缺少 llama_decode 符号"; fi
# 主程序实际引用的 llama 接口（证明推理代码被编进了 App，而不是空壳）
nm -u "$EXE" 2>/dev/null | grep -E "_llama_|_ggml_" | sort -u > "$WORK/used.txt" || true
echo "主程序引用的 llama/ggml 接口（$(wc -l < "$WORK/used.txt" | tr -d ' ') 个）："
cat "$WORK/used.txt"
for sym in _llama_model_load_from_file _llama_init_from_model _llama_decode _llama_sampler_sample _llama_tokenize _llama_memory_seq_rm; do
  grep -q "^ *U ${sym}$\|${sym}$" "$WORK/used.txt" && pass "主程序调用 ${sym}" || fail "主程序没有调用 ${sym}"
done

echo "== 签名状态 =="
if codesign -dv "$APP" 2>&1 | grep -q "not signed"; then
  pass "未签名（需用全能签等工具签名后安装）"
else
  codesign -dv "$APP" 2>&1 || true
  echo "⚠️ 检测到签名信息（可能是 ad-hoc 签名）"
fi
[[ -f "$APP/embedded.mobileprovision" ]] && echo "包含 embedded.mobileprovision" || echo "不包含描述文件（符合未签名 IPA 预期）"

echo "== 资源 =="
[[ -f "$APP/Assets.car" ]] && pass "Assets.car 存在（图标与配色）" || fail "缺少 Assets.car"
du -sh "$APP" "$IPA"
echo "IPA 结构检查全部通过"
