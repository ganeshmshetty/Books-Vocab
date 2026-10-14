#!/bin/bash
# release_bump.sh — 更新 backend 或 iOS 版本號（release.sh bump / bump-build 的 primitive）
# 用法: ops/release_bump.sh <api|ios> <new-version> [--yes]（一般經 ops/release.sh bump 呼叫）
#       ops/release_bump.sh ios --build-only [--yes]（只 +1 CURRENT_PROJECT_VERSION、
#         MARKETING_VERSION 不動；App Review 被拒同版重送用，經 release.sh bump-build 呼叫）
#       ops/release_bump.sh ios --build-only --build-number=<n> [--yes]（內部精確目標）
# 預設 dry-run：只印將改的檔與「舊 → 新」版號，不寫檔；加 --yes 才落地
# （對齊 release.sh publish / asc.sh set 的 --yes 寫入慣例）。
set -euo pipefail

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
}

# Portable in-place sed (BSD `sed -i ''` and GNU `sed -i` differ): write via a
# temp file, then copy back so the target keeps its inode and mode.
sed_inplace() {
  local expr="$1" file="$2" tmp
  tmp="$(mktemp)"
  sed "$expr" "$file" >"$tmp" && cat "$tmp" >"$file"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

YES=0
MODE=full   # full=marketing+build / build=只 +1 CURRENT_PROJECT_VERSION
TARGET_BUILD=""
TARGET_BUILD_SET=0
POS=()
for arg in "$@"; do
  case "$arg" in
    -h|--help)    usage; exit 0 ;;
    --yes)        YES=1 ;;
    --build-only) MODE=build ;;
    --build-number=*) TARGET_BUILD="${arg#*=}"; TARGET_BUILD_SET=1 ;;
    -*)           echo "✗ unknown option: ${arg}" >&2; exit 1 ;;
    *)            POS+=("$arg") ;;
  esac
done

COMPONENT="${POS[0]:?用法: ops/release_bump.sh <api|ios> <version> [--yes] | ios --build-only [--yes]}"
KG_ROOT="${KG_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"   # 可由 env 覆寫（測試指向 fixture）

if [[ "$MODE" == build ]]; then
  [[ "$COMPONENT" == ios ]] || { echo "✗ --build-only 只支援 ios（api 無 build number；改版號用 ops/release.sh bump api <x.y.z>）" >&2; exit 1; }
  [[ ${#POS[@]} -le 1 ]] || { echo "✗ 多餘參數：${POS[*]:1}（--build-only 不吃版本號，build number 由旗標決定或自動 +1）" >&2; exit 1; }
  VERSION=""   # build-only 不用 marketing 版號
else
  (( TARGET_BUILD_SET == 0 )) || { echo "✗ --build-number 只支援 ios --build-only（內部精確 build 目標）" >&2; exit 1; }
  VERSION="${POS[1]:?請提供版本號，例如 1.3.0}"
  [[ ${#POS[@]} -le 2 ]] || { echo "✗ 多餘參數：${POS[*]:2}（用法: ops/release_bump.sh <api|ios> <version> [--yes]）" >&2; exit 1; }
  # 驗證版本號格式
  if ! grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$VERSION"; then
    echo "✗ 版本號格式錯誤：${VERSION}（需要 x.y.z）" >&2
    exit 1
  fi
fi

bump_api() {
  local pyproject="$KG_ROOT/backend/pyproject.toml"
  local api_py="$KG_ROOT/backend/src/kg/api.py"

  # 先讀當前值：dry-run 與 --yes 都印「舊 → 新」計畫（寫面自解）
  local cur_py cur_api
  cur_py="$(grep -m1 '^version = ' "$pyproject" | sed -E 's/.*"([^"]+)".*/\1/')"
  cur_api="$(grep -m1 -o 'version="[^"]*"' "$api_py" | sed 's/version="//;s/"$//')"
  [[ -n "$cur_py" && -n "$cur_api" ]] || { echo "✗ 讀不到當前版本（pyproject/api.py 結構異常）" >&2; exit 1; }
  echo "將改 backend/pyproject.toml：version ${cur_py} → ${VERSION}"
  echo "將改 backend/src/kg/api.py：version ${cur_api} → ${VERSION}"
  [[ $YES -eq 1 ]] || return 0

  # pyproject.toml
  sed_inplace "s/^version = \".*\"/version = \"$VERSION\"/" "$pyproject"
  echo "✓ pyproject.toml → $VERSION"

  # api.py
  sed_inplace "s/version=\"[^\"]*\"/version=\"$VERSION\"/" "$api_py"
  echo "✓ api.py → $VERSION"

  # 驗證
  grep -q "version = \"$VERSION\"" "$pyproject" || { echo "✗ pyproject.toml 更新失敗" >&2; exit 1; }
  grep -q "version=\"$VERSION\"" "$api_py" || { echo "✗ api.py 更新失敗" >&2; exit 1; }
}

bump_ios() {
  local pbxproj="$KG_ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj"

  # 以『當前版號值』為錨，只命中帶該值的那幾行，而不是全域 sed 掃 MARKETING_VERSION。
  # 注意語意在 2026-08 變了：版號已提升到 **project-level build settings**，六個
  # target-level 覆寫全數刪除，所以檔內這兩個 key 各恰好出現兩次（Debug + Release），
  # 測試 bundle 改為**繼承**——它們現在會跟著一起前進，這是刻意的（版號只有一個 owner）。
  # 錨定仍然保留：它擋的是「有人日後把某個 target-level 覆寫加回來」時的誤傷。
  # 當前值＝檔內第一個（與 release.sh current_version 的 grep -m1 同口徑）。
  local cur_mv cur_build new_build
  cur_mv=$(grep -o 'MARKETING_VERSION = [^;]*' "$pbxproj" | head -1 | sed 's/MARKETING_VERSION = //')
  cur_build=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$pbxproj" | head -1 | grep -o '[0-9]*')
  [[ -n "$cur_mv" && -n "$cur_build" ]] || { echo "✗ 讀不到 app target 當前版號（pbxproj 結構異常）" >&2; exit 1; }
  new_build=$((cur_build + 1))

  echo "將改 ios/BooksAndVocab.xcodeproj/project.pbxproj："
  echo "  MARKETING_VERSION ${cur_mv} → ${VERSION}（project-level；測試 bundle 依繼承跟進）"
  echo "  CURRENT_PROJECT_VERSION ${cur_build} → ${new_build}"
  [[ $YES -eq 1 ]] || return 0

  # 以「= 當前值;」精準錨定，只命中與主 app 同值的 config（Debug+Release 兩處），不碰異值的測試 bundle。
  sed_inplace "s/MARKETING_VERSION = ${cur_mv};/MARKETING_VERSION = $VERSION;/g" "$pbxproj"
  sed_inplace "s/CURRENT_PROJECT_VERSION = ${cur_build};/CURRENT_PROJECT_VERSION = $new_build;/g" "$pbxproj"

  # 驗證 + 回報實際命中數（不再謊稱「6 處」）
  local count
  count=$(grep -c "MARKETING_VERSION = $VERSION;" "$pbxproj")
  [[ "$count" -ge 1 ]] || { echo "✗ MARKETING_VERSION 更新失敗（錨值 $cur_mv 未命中）" >&2; exit 1; }
  echo "✓ MARKETING_VERSION → ${VERSION}（${count} 處；測試 bundle 依繼承跟進）"
  echo "✓ CURRENT_PROJECT_VERSION → $new_build"
}

bump_ios_build() {
  local pbxproj="$KG_ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj"

  # 同 bump_ios 的錨定邏輯：當前值＝檔內第一個，以「= 當前值;」錨定，命中 project-level
  # 的 Debug+Release 兩處；測試 bundle 依繼承跟進。MARKETING_VERSION 完全不碰。
  local cur_mv cur_build new_build
  cur_mv=$(grep -o 'MARKETING_VERSION = [^;]*' "$pbxproj" | head -1 | sed 's/MARKETING_VERSION = //')
  cur_build=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$pbxproj" | head -1 | grep -o '[0-9]*')
  [[ -n "$cur_build" ]] || { echo "✗ 讀不到 app target 當前 build number（pbxproj 結構異常）" >&2; exit 1; }
  if (( TARGET_BUILD_SET )); then
    [[ "$TARGET_BUILD" =~ ^[0-9]+$ ]] \
      || { echo "✗ --build-number 必須是非負整數：${TARGET_BUILD}" >&2; exit 1; }
    local target_dec=$((10#$TARGET_BUILD))
    (( target_dec > cur_build )) \
      || { echo "✗ --build-number 必須大於當前 build ${cur_build}：${TARGET_BUILD}" >&2; exit 1; }
    new_build="$target_dec"
  else
    new_build=$((cur_build + 1))
  fi

  echo "將改 ios/BooksAndVocab.xcodeproj/project.pbxproj："
  echo "  CURRENT_PROJECT_VERSION ${cur_build} → ${new_build}（project-level；測試 bundle 依繼承跟進）"
  echo "  MARKETING_VERSION ${cur_mv} 不動（同版重送只 bump build）"
  [[ $YES -eq 1 ]] || return 0

  sed_inplace "s/CURRENT_PROJECT_VERSION = ${cur_build};/CURRENT_PROJECT_VERSION = $new_build;/g" "$pbxproj"

  local count
  count=$(grep -c "CURRENT_PROJECT_VERSION = $new_build;" "$pbxproj")
  [[ "$count" -ge 1 ]] || { echo "✗ CURRENT_PROJECT_VERSION 更新失敗（錨值 $cur_build 未命中）" >&2; exit 1; }
  echo "✓ CURRENT_PROJECT_VERSION → ${new_build}（${count} 處；MARKETING_VERSION 不動）"
}

case "$COMPONENT" in
  api)  bump_api ;;
  ios)  if [[ "$MODE" == build ]]; then bump_ios_build; else bump_ios; fi ;;
  *)    echo "✗ 未知 component: ${COMPONENT}（需要 api 或 ios）" >&2; exit 1 ;;
esac

if [[ $YES -eq 1 ]]; then
  if [[ "$MODE" == build ]]; then
    echo "✓ build number 更新完成：ios（MARKETING_VERSION 不動）"
  else
    echo "✓ 版本更新完成：$COMPONENT $VERSION"
  fi
else
  echo "[dry-run] 未寫入。確認無誤後加 --yes 才會改檔："
  if [[ "$MODE" == build ]]; then
    echo "  ./ops/release.sh bump-build ios --yes"
  else
    echo "  ./ops/release.sh bump $COMPONENT $VERSION --yes"
  fi
fi
