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
if nm -gU "$FW" | grep -q "ggml_backend_metal_init"; then pass "llama.framework 含 Metal 后端"; else fail "llama.framework 缺少 Metal 后端"; fi
if nm -gU "$FW" | grep -q "_llama_decode"; then pass "llama.framework 导出 llama_decode"; else fail "缺少 llama_decode 符号"; fi

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
