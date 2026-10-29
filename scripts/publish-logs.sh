#!/usr/bin/env bash
# 把本次构建的日志推送到仓库的 ci-logs/<标签> 分支（每次覆盖），
# 并把编译错误输出为 GitHub 注解。日志分支便于离线查看完整编译输出。
set -uo pipefail

LABEL="${1:?需要标签，例如 xcode26}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
LOGS="$ROOT/logs"
[[ -d "$LOGS" ]] || { echo "没有 logs 目录"; exit 0; }

# 汇总诊断信息
for BUILD_LOG in "$LOGS/xcodebuild.log" "$LOGS/uitest.log"; do
  [[ -f "$BUILD_LOG" ]] || continue
  grep -E "(: error: |: warning: |error: |BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|\*\* |Test Case .* (passed|failed)|XCTAssert)" "$BUILD_LOG" | sort -u >> "$LOGS/diagnostics.txt" || true
  grep -E ": error: " "$BUILD_LOG" | sort -u | head -30 | while IFS= read -r line; do
    echo "::error::${line}"
  done
done
{
  echo "run: ${GITHUB_RUN_NUMBER:-local} (${GITHUB_RUN_ID:-})"
  echo "sha: ${GITHUB_SHA:-}"
  echo "label: ${LABEL}"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$LOGS/run-info.txt"

[[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || { echo "非 CI 环境，跳过推送"; exit 0; }

TMP="$(mktemp -d)"
cp -R "$LOGS/." "$TMP/"
cd "$TMP"
# 测试失败时 xcresult 会附带整段录屏，超过 GitHub 单文件 100 MB 的上限会让整次推送失败
find . -type f -size +40M -print | while IFS= read -r big; do
  echo "${big#./}（$(du -h "$big" | cut -f1)）" >> skipped-large-files.txt
  rm -f "$big"
done
[[ -f skipped-large-files.txt ]] && { echo "以下大文件没有推送："; cat skipped-large-files.txt; }
git init -q
git checkout -q --orphan "ci-logs/${LABEL}"
git add -A
git -c user.name="ci" -c user.email="ci@users.noreply.github.com" commit -qm "构建日志 #${GITHUB_RUN_NUMBER:-} ${LABEL}"
git push -q --force "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/ci-logs/${LABEL}" \
  && echo "日志已推送到分支 ci-logs/${LABEL}" || echo "::warning::日志推送到 ci-logs/${LABEL} 失败（不影响构建结果）"
exit 0
