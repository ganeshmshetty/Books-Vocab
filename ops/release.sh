#!/usr/bin/env bash
# release.sh — KG 版號發布統一入口（對標 backend/ops_cli.py 的單入口 + 乾淨 subcommand）
#
# 統一 backend／iOS 的版本與發布入口；命令實作集中在本檔。
# 寫入面（bump/candidate/tag）一律 dry-run 預設、--yes 才落地（同 asc.sh set 紀律）。
# 注意：目前無 tag-triggered CI workflow，tag 為「版本標記」，GitHub Release 須手動建。
#
# GitHub main 是合併後的產品主幹；release candidate 先在 dedicated lane 產生，
# 經 IM PR + required/native merge queue 後，才由 approved owner 以 exact merged
# evidence resume 外部發布。tag 只推 tag ref，非 branch ref。
#
# Usage:
#   ./ops/release.sh status                      # 各 component 待發版 commit + released gap（本地唯讀）
#   ./ops/release.sh changelog <api|ios>         # 印 markdown changelog 預覽（唯讀）
#   ./ops/release.sh bump <api|ios> <x.y.z>      # 改本地版號檔（api: pyproject+api.py+uv.lock / ios: pbxproj；dry-run 預設，--yes 才寫）
#   ./ops/release.sh bump-build ios              # 只 +1 pbxproj CURRENT_PROJECT_VERSION（App Review 被拒同版重送；dry-run 預設，--yes 才寫）
#   ./ops/release.sh tag <api|ios> <x.y.z>       # commit 版號檔 + tag-only push（ios 封的是 ios/<x.y.z>+<build>）
#   ./ops/release.sh release <backend|ios> <x.y.z>  # dedicated lane candidate；dry-run 預設
#   ./ops/release.sh promote backend <merged-main-sha> [--same-version <reason>] [--wait]
#                                                # 唯一推進 origin/prod 的路徑（FF-only，永不 force）；dry-run 預設，--yes 才 push；
#                                                # 守衛：完整 SHA 在 live refs/heads/main、prod 為其 ancestor、backend 版號提升、backend-quality 每個 run 皆 success；push 帶 --force-with-lease；
#                                                # --wait 輪詢 /api/system/info 至 version==短 SHA（KG_PROMOTE_WAIT_SECS 600 / KG_PROMOTE_POLL_SECS 15）
#   ./ops/release.sh resume ios <x.y.z> <build> --pr <n> --merged-source <sha>
#                                                # merged main 後，dry-run 預設；--yes 才 upload
#   ./ops/release.sh shipped ios                 # 查 ASC 上架版本 → join build tag → 打 ios/<x.y.z>（dry-run 預設）
#   ./ops/release.sh resubmit ios                # dedicated lane：ASC 對帳 → candidate（dry-run 預設）
#   ./ops/release.sh finalize ios <x.y.z> <build> --pr <n> --merged-source <sha>
#                                                # exact merged/ASC evidence 後只封 tag（dry-run 預設）
#   ./ops/release.sh publish <api|ios> <x.y.z>   # 已改名 tag 的別名（相容保留）
#
# iOS 版號的兩種 tag（語意不同，別混）：
#   ios/<x.y.z>          該 marketing version **上架 App Store** 的那顆 commit。
#                        只由 `shipped ios` 依 ASC 驗證後物化；immutable，不移動。
#   ios/<x.y.z>+<build>  該 (version, build) 的封版 commit。由 tag/release/resubmit 產生；
#                        immutable，同版可多顆並存（Apple 的 build number 每個版本重新計數，
#                        單獨沒有意義，必須成對）。
# `--new-version-after-ready` 已移除：ios/<x.y.z> 現在代表上架，tag 存在本身就是證據。
#
# 全域 flag：--yes（bump/tag/candidate/upload 真寫；release/resume/resubmit 真執行）
#           --commit <sha>（shipped：build tag 不存在時人工指定封版 commit，標記為人工斷言；tag api <v>：補打歷史版本 tag，須 pyproject 版號==<v> 且為 origin/prod ancestor）
#           --pr <number> --merged-source <sha>（resume/finalize 的 exact merge evidence）
# 其他：-h|--help
# env knob：KG_RELEASE_WAIT_SECS（預設 480）/ KG_RELEASE_POLL_SECS（10）/ KG_PUBLIC_URL
#           —— release backend 收斂等待的上限與輪詢間隔。設 0 秒不會關閉等待，只會讓它
#           立刻逾時。
#           KG_ASC_BUILDS_CMD（測試注入；預設 ops/asc.sh builds）供 resubmit 查 TestFlight 最新 build。
#           KG_ASC_BUILD_CMD（測試注入；預設 ops/asc.sh build <version> <build>）供 iOS finalize
#           查 ASC 精確 build；KG_RELEASE_ASC_WAIT_SECS（預設 120）/KG_RELEASE_ASC_POLL_SECS（5）
#           控制 upload 後 ASC propagation 的 bounded wait。
#           KG_PR_CMD（測試注入；預設 gh pr view <number> --json ...）供 resume/finalize
#           做 exact merged PR readback；輸出必須是單一 gh PR JSON object。
# App Store 側（正交）：出 build → ops/ios_release.sh；查/改文案 → ops/asc.sh；細節見 docs/sop/ios.md §發版。

set -euo pipefail

# BASH_SOURCE 而非 $0：本檔會被 ops/tests/test_release.sh source 以取純函式，而 source
# 時 $0 是呼叫端的路徑 → ROOT 解成 ops/ 自己 → 下面那行 lib 就找不到。用 BASH_SOURCE
# 兩種情境都對。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YES=0
SHIPPED_COMMIT=""
RELEASE_PR=""
MERGED_SOURCE=""
IOS_SAME_VERSION_RESUBMIT=0
PROMOTE_WAIT=0
PROMOTE_SAME_VERSION=""
KG_GH_REPO="${KG_GH_REPO:-Books-Vocab/Books-Vocab}"

# ── 部署收斂 seam（測試注入；預設即生產）──────────────────────────────────
CURL_BIN="${CURL_BIN:-curl}"
KG_PUBLIC_URL="${KG_PUBLIC_URL:-https://wordnexus.lol}"
# 480s：backend image rebuild 實測 2-3 分，加上 reconciler 最多 90s tick 延遲與三段
# 健康 gate（含 external smoke 的重試預算）。抓兩倍餘裕，寧可等也不要在還在 build 時
# 就宣告失敗——假紅會讓下一個人學會忽略這個閘。
KG_RELEASE_WAIT_SECS="${KG_RELEASE_WAIT_SECS:-480}"
KG_RELEASE_POLL_SECS="${KG_RELEASE_POLL_SECS:-10}"
KG_RELEASE_ASC_WAIT_SECS="${KG_RELEASE_ASC_WAIT_SECS:-120}"
KG_RELEASE_ASC_POLL_SECS="${KG_RELEASE_ASC_POLL_SECS:-5}"

# shellcheck source=lib/release_tags.sh
. "$ROOT/ops/lib/release_tags.sh"

err()  { echo "✗ $*" >&2; exit 1; }
# 只印開頭連續註解區（停在第一個非 # 行），避免把 set -euo pipefail / ROOT= / YES= 洩進 help。
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

# ---- component → tag/commit prefix + 版號檔（單一真相，與 release_bump.sh 對映） ----
tag_prefix()    { case "$1" in api) echo "api/";; ios) echo "ios/";; *) err "未知 component: $1（api|ios）";; esac; }
commit_prefix() { case "$1" in api) echo "api:";; ios) echo "ios:";; esac; }

current_version() {  # 從版號檔讀目前 marketing 版本
  case "$1" in
    api) grep -m1 '^version = ' "$ROOT/backend/pyproject.toml" | sed -E 's/.*"([^"]+)".*/\1/' ;;
    ios) grep -m1 'MARKETING_VERSION = ' "$ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ' ;;
  esac
}

current_build() {  # iOS app target 的 CURRENT_PROJECT_VERSION（主 app＝檔內第一個，同 release_bump.sh 口徑）
  grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
    | sed -E 's/.*= *//'
}

valid_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# ---- build tag：(marketing version, build number) → 封版 commit ----
# Apple 端沒有這個事實可查：appStoreVersions 只留「當前」一筆，versionString 是可變欄位
# （1.4→1.5→…→2.0.0 反覆改寫同一筆記錄），build number 又每個 marketing version 重新
# 計數。所以「哪顆 commit 產生了哪顆 build」只有 repo 知道，且必須在出 archive 的當下
# 捕捉——事後無從重建。這個 tag 是 immutable 的：同一 (version, build) 不會有第二顆
# archive，若真有，那是必須人工釐清的歧義，不是可覆蓋的重複。
ios_build_tag() { printf 'ios/%s+%s\n' "$1" "$2"; }   # `+` 在 git ref name 合法

IOS_BUILD_TAG_STATE=""
# $1=build tag，其餘=本次會被 commit 的 pathspec。pathspec 由呼叫端傳入而不是在這裡再寫
# 一次：這個判斷的意思是「接下來會不會生出新 commit」，唯有和 cmd_tag 真正 commit 的
# 那組檔案是同一份，答案才有效。（重複實作正是 last_tag/changelog 那次事故的形狀。）
check_ios_build_tag() {  # 設 IOS_BUILD_TAG_STATE=new|idempotent，衝突則 err
  local tag="$1"; shift
  local existing head_now
  existing="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" || true)"
  if [[ -z "$existing" ]]; then IOS_BUILD_TAG_STATE=new; return 0; fi
  head_now="$(git -C "$ROOT" rev-parse HEAD)"
  # 冪等只在「tag 已指向 HEAD 且這些檔案沒有待 commit 的改動」時成立：還髒代表接下來會
  # 生出新 commit，那顆 tag 就會落在不同 commit 上，屬於下面的歧義。
  # 已量測（別再重推一次）：`diff --quiet HEAD -- <path>` 對 staged-only、unstaged-only，
  # 以及「git rm --cached 後檔案仍在磁碟上」三種狀態都回非零＝髒。最後那種曾被懷疑會被
  # 誤判成乾淨而留下錯誤 tag，實測 rc=1，不成立。
  if [[ "$existing" == "$head_now" ]] && git -C "$ROOT" diff --quiet HEAD -- "$@"; then
    IOS_BUILD_TAG_STATE=idempotent; return 0
  fi
  err "build tag ${tag} 已存在且指向 $(git -C "$ROOT" rev-parse --short "$existing")，但本次要封的是另一顆 commit。
   同一 (version, build) 從兩顆不同 commit 出過 archive = 真正的歧義，不靜默覆蓋。
   若這次是新的 archive，先 ./ops/release.sh bump-build ios --yes 取得新 build number；
   若是既有那顆的補封，請確認哪顆 commit 才是上傳的那顆再人工處理 tag。"
}

# release 交易只能以 tracked-clean 的 primary 開始。candidate commit 會把版號檔
# 的唯一預期變更收進來；任何 operator 或其他 session 的變更都必須先離開 release
# 臨界區，否則 upload provenance 會無法判定。
ensure_release_primary_clean() {
  local dirty
  dirty="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$dirty" ]] || err "release primary 必須 clean；先處理以下變更再重試：
${dirty}"
}

# release 是跨 local git + ASC 的長交易；iOS archive 自己的 shlock 只保護 Xcode
# 資源，不能防止兩個 release invocation 同時 bump / upload 同一個 tuple。用 git
# dir 下的 mkdir 做 primary-local mutex：取得失敗就停，不猜 stale owner，也不讓
# 第二個 invocation 靠 candidate 檢查的偶然順序來「看似」去重。
RELEASE_LOCK_DIR=""

release_lock_cleanup() {
  local dir="$RELEASE_LOCK_DIR"
  [[ -n "$dir" ]] || return 0
  RELEASE_LOCK_DIR=""
  rm -f "$dir/owner"
  rmdir "$dir" 2>/dev/null || true
}

api_version_exit_cleanup() {
  api_version_rollback
  release_lock_cleanup
}

api_version_restore_exit_cleanup() {
  if [[ -n "$RELEASE_LOCK_DIR" ]]; then
    trap release_lock_cleanup EXIT
  else
    trap - EXIT
  fi
}

acquire_release_lock() {
  [[ $YES -eq 1 ]] || return 0
  [[ -n "$RELEASE_LOCK_DIR" ]] && return 0
  local dir owner
  dir="$(git -C "$ROOT" rev-parse --git-path kg-release.lock)"
  [[ "$dir" = /* ]] || dir="$ROOT/$dir"
  if mkdir "$dir" 2>/dev/null; then
    printf 'pid=%s\nroot=%s\n' "$$" "$ROOT" >"$dir/owner"
    RELEASE_LOCK_DIR="$dir"
    trap release_lock_cleanup EXIT
    echo "  release lock acquired: ${dir}" >&2
    return 0
  fi
  # holder 的 release_lock_cleanup 可能在測試與讀取之間刪掉 owner；讀失敗必須
  # 落到下面的 refusal，不能在 set -e 下被讀檔錯誤取代。
  owner="$(cat "$dir/owner" 2>/dev/null || true)"
  err "release lock 已被占用：${dir}${owner:+（${owner//$'\n'/; }）}；拒絕平行 release/resubmit/finalize。確認持有者已退出後再重試。"
}

ios_remote_tag_commit() {
  local tag="$1" refs rc=0
  refs="$(git -C "$ROOT" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" || rc=$?
  (( rc == 0 )) || err "無法查詢 origin tag ${tag}（git ls-remote exit ${rc}）；fail-closed。"
  awk -v ref="refs/tags/${tag}" '
    $2 == ref "^{}" { peeled = $1 }
    $2 == ref { direct = $1 }
    END { if (peeled != "") print peeled; else if (direct != "") print direct }
  ' <<<"$refs"
}

# 精確 ref 查詢：`ls-remote --heads origin prod` 會連 refs/heads/a/prod 一起列出，NR==1 可能是別的分支。
# 這裡只問 refs/heads/<branch>，並以完整 ref 名逐行比對；沒有該 ref 回空字串。
remote_head_sha() {  # $1=branch
  local ref="refs/heads/$1" output rc=0
  output="$(git -C "$ROOT" ls-remote origin "$ref" 2>/dev/null)" || rc=$?
  (( rc == 0 )) || err "無法查詢 live origin/$1（git ls-remote exit ${rc}）；fail-closed。"
  awk -v ref="$ref" '$2 == ref { print $1; exit }' <<<"$output"
}

live_origin_main() {
  local sha
  sha="$(remote_head_sha main)" || exit $?
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || err "live origin/main 缺少 exact commit SHA；fail-closed。"
  printf '%s\n' "$sha"
}

ios_assert_merged_source() {
  local source="$1" live="$2"
  [[ "$source" =~ ^[0-9a-f]{40}$ ]] || err "--merged-source 必須是 40 字元 commit SHA"
  git -C "$ROOT" cat-file -e "${source}^{commit}" 2>/dev/null \
    || err "merged source ${source} 不在本地 object graph；先由 CM sync exact merged main 再恢復。"
  git -C "$ROOT" merge-base --is-ancestor "$source" "$live" \
    || err "merged source ${source} 不是 live origin/main=${live} 的 ancestor；拒絕 upload/tag。"
}

# A numeric PR flag is only a locator. Before any ASC upload or tag push, read
# the PR back from GitHub and bind all three GitHub identities to the live
# merged main: the PR head must be the supplied source, its merge commit must
# be an exact commit ancestor of live origin/main, and its base OID must be an
# ancestor of both. The live tip may include later merged PRs. The
# injected command is deliberately a one-argument executable (PR number) so
# tests can provide a deterministic policy fixture without mocking git/ASC.
github_assert_exact_merged_pr() {
  local pr="$1" source="$2" live="$3" output rc=0 pr_cmd="${KG_PR_CMD:-}"
  if [[ -n "$pr_cmd" ]]; then
    output="$($pr_cmd "$pr" 2>&1)" || rc=$?
  else
    command -v gh >/dev/null 2>&1 \
      || err "找不到 gh；resume/finalize 必須完成 exact GitHub PR readback，拒絕 upload/tag。"
    output="$(gh pr view "$pr" --json number,state,baseRefName,baseRefOid,headRefOid,mergeCommit 2>&1)" || rc=$?
  fi
  (( rc == 0 )) \
    || err "GitHub PR #${pr} readback 失敗（exit ${rc}）：${output:-<empty>}；拒絕 upload/tag。"

  jq -e --argjson pr "$pr" '
    type == "object" and
    (.number == $pr) and
    (.state == "MERGED") and
    (.baseRefName == "main") and
    ((.baseRefOid | type) == "string") and
    ((.headRefOid | type) == "string") and
    ((.mergeCommit | type) == "object") and
    ((.mergeCommit.oid | type) == "string")
  ' <<<"$output" >/dev/null 2>&1 \
    || err "GitHub PR #${pr} readback 不是唯一且完整的 MERGED/main PR object；拒絕 upload/tag：${output:-<empty>}"

  local readback_number state base_oid head_oid merge_oid
  readback_number="$(jq -r '.number' <<<"$output")"
  state="$(jq -r '.state' <<<"$output")"
  base_oid="$(jq -r '.baseRefOid' <<<"$output")"
  head_oid="$(jq -r '.headRefOid' <<<"$output")"
  merge_oid="$(jq -r '.mergeCommit.oid' <<<"$output")"
  [[ "$readback_number" == "$pr" && "$state" == MERGED ]] \
    || err "GitHub PR readback identity/state 不符：number=${readback_number:-<empty>} state=${state:-<empty>}；拒絕 upload/tag。"
  [[ "$head_oid" == "$source" ]] \
    || err "GitHub PR #${pr} headRefOid=${head_oid} ≠ --merged-source=${source}；拒絕 upload/tag。"
  [[ "$merge_oid" =~ ^[0-9a-f]{40}$ ]] \
    || err "GitHub PR #${pr} mergeCommit.oid 非 exact commit SHA：${merge_oid:-<empty>}；拒絕 upload/tag。"
  git -C "$ROOT" cat-file -e "${merge_oid}^{commit}" 2>/dev/null \
    || err "GitHub PR #${pr} mergeCommit=${merge_oid} 不是可驗證的 commit；拒絕 upload/tag。"
  git -C "$ROOT" merge-base --is-ancestor "$merge_oid" "$live" \
    || err "GitHub PR #${pr} mergeCommit=${merge_oid} 不是 live origin/main=${live} 的 ancestor；拒絕 upload/tag。"
  [[ "$base_oid" =~ ^[0-9a-f]{40}$ ]] \
    || err "GitHub PR #${pr} baseRefOid 非 exact SHA：${base_oid:-<empty>}；拒絕 upload/tag。"
  git -C "$ROOT" cat-file -e "${base_oid}^{commit}" 2>/dev/null \
    || err "GitHub PR #${pr} baseRefOid=${base_oid} 不在本地 object graph；拒絕 upload/tag。"
  git -C "$ROOT" merge-base --is-ancestor "$base_oid" "$source" \
    || err "GitHub PR #${pr} baseRefOid=${base_oid} 不是 merged source=${source} ancestor；拒絕 upload/tag。"
  git -C "$ROOT" merge-base --is-ancestor "$base_oid" "$live" \
    || err "GitHub PR #${pr} baseRefOid=${base_oid} 不是 live origin/main=${live} ancestor；拒絕 upload/tag。"
  echo "  exact GitHub PR readback: #${pr} state=MERGED base=${base_oid} head=${head_oid} merge=${merge_oid}" >&2
}

ios_assert_synced_main() {
  local live="$1" local_head
  local_head="$(git -C "$ROOT" rev-parse HEAD)"
  [[ "$local_head" == "$live" ]] \
    || err "release resume/finalize 需要 sync 後的 exact main；local HEAD=${local_head}、origin/main=${live}。"
}

ios_origin_main_tuple() {
  local live="$1" path="ios/BooksAndVocab.xcodeproj/project.pbxproj" content version build
  content="$(git -C "$ROOT" show "${live}:${path}" 2>/dev/null)" \
    || err "無法從 live origin/main=${live} 讀取 ${path}；fail-closed。"
  version="$(grep -m1 'MARKETING_VERSION = ' <<<"$content" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ')"
  build="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' <<<"$content" | sed -E 's/.*= *//')"
  [[ -n "$version" && "$build" =~ ^[0-9]+$ ]] || err "live origin/main 的 iOS version/build tuple 無法解析；fail-closed。"
  printf '%s+%s\n' "$version" "$build"
}

# irreversible upload 前只做存在性 collision check。正式 tag 的 commit identity
# 在 candidate commit 之後才知道；因此這個 preflight 不把既有 tag 誤判成可冪等。
assert_ios_build_tag_unused() {
  local tag="$(ios_build_tag "$1" "$2")" existing remote_tag
  existing="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" || true)"
  [[ -z "$existing" ]] || err "${tag} 已存在且指向 $(git -C "$ROOT" rev-parse --short "$existing")；在 upload 前拒絕重用 build tag。"
  remote_tag="$(ios_remote_tag_commit "$tag")"
  [[ -z "$remote_tag" ]] || err "origin 上已存在 ${tag}；在 upload 前拒絕重用 build tag。"
}

ios_candidate_subject() {
  printf 'ops: prepare ios %s build %s\n' "$1" "$2"
}

ios_refuse_pending_candidate() {
  local version="$1" build="$2" subject tag existing
  subject="$(git -C "$ROOT" log -1 --format=%s)"
  [[ "$subject" == "$(ios_candidate_subject "$version" "$build")" ]] || return 0
  tag="$(ios_build_tag "$version" "$build")"
  existing="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" || true)"
  [[ -n "$existing" ]] && return 0
  err "目前 HEAD 是未 finalize 的 iOS candidate ${version}+${build}，禁止重跑 release/resubmit 產生下一顆 build。
   若 ASC 已接受，沿用 merged receipt 執行：./ops/release.sh finalize ios ${version} ${build} --pr <number> --merged-source <sha> --yes
   若 upload 確認未接受，沿用同一 merged resume evidence 重試；不要重造 build。"
}

# candidate commit 是 upload provenance 的持久錨點：先在 dedicated lane commit，
# 由 IM 以 exact hand-back 發 PR；required/native queue merge 後才碰 ASC。
ios_commit_candidate() {
  local version="$1" build="$2" file="ios/BooksAndVocab.xcodeproj/project.pbxproj"
  local changed staged subject
  changed="$(git -C "$ROOT" diff --name-only)"
  [[ -z "$changed" || "$changed" == "ios/BooksAndVocab.xcodeproj/project.pbxproj" ]] \
    || err "iOS candidate 含非版號檔變更，拒絕混入 release commit：${changed}"
  staged="$(git -C "$ROOT" diff --cached --name-only)"
  [[ -z "$staged" ]] || err "release 開始前已有 staged 變更：${staged}"

  git -C "$ROOT" add -- "$file"
  subject="$(ios_candidate_subject "$version" "$build")"
  if git -C "$ROOT" diff --cached --quiet -- "$file"; then
    [[ "$(git -C "$ROOT" log -1 --format=%s)" == "$subject" ]] \
      || git -C "$ROOT" commit --allow-empty -m "$subject"
  else
    git -C "$ROOT" commit -m "$subject" -- "$file"
  fi
  IOS_CANDIDATE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  echo "  candidate=${IOS_CANDIDATE_SHA} (${subject})"
}

emit_candidate_handback() {
  local component="$1" version="$2" build="${3:-}" branch sha
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  echo "  candidate=${sha} branch=${branch} component=${component}${build:+ tuple=${version}+${build}}"
  echo "  hand-back: supported worktree_orchestrate hand-back -> IM publishes exact commit as PR"
  echo "  PR/queue gate: required check + native merge queue on protected main"
  if [[ "$component" == ios ]]; then
    echo "  after merged main sync: ./ops/release.sh resume ios ${version} ${build} --pr <number> --merged-source <sha> --yes"
  else
    echo "  after merged main sync: approved backend release operator resumes with exact PR/merged-source evidence"
  fi
}

assert_release_lane_branch() {
  local branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != main && "$branch" != prod && "$branch" != HEAD ]] \
    || err "release candidate 必須在 dedicated release lane 執行（目前 ${branch}）；先由 supported worktree owner lane hand-back，禁止直接操作 protected main。"
}

assert_release_lane_base() {
  local live head
  # A non-main branch is not sufficient: it may contain unmerged product
  # commits or have been forked before another main landing.  In either case
  # a version-only candidate would smuggle unrelated/stale source into the
  # release PR.  Bind the candidate lane to the live protected base immediately
  # before any version mutation or candidate commit.
  live="$(live_origin_main)"
  head="$(git -C "$ROOT" rev-parse HEAD)"
  [[ "$head" == "$live" ]] \
    || err "release candidate lane 必須以 exact live origin/main 建立；目前 HEAD=${head}、live origin/main=${live}。請重新 materialize dedicated lane；禁止在 stale 或含未合併 commit 的 branch 上產生 candidate。"
}

api_commit_candidate() {
  local version="$1" files=(backend/pyproject.toml backend/src/kg/api.py backend/uv.lock)
  local changed staged subject
  changed="$(git -C "$ROOT" diff --name-only)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      backend/pyproject.toml|backend/src/kg/api.py|backend/uv.lock) ;;
      *) err "backend candidate 含非版號檔變更，拒絕混入 release commit：${changed}" ;;
    esac
  done <<<"$changed"
  staged="$(git -C "$ROOT" diff --cached --name-only)"
  [[ -z "$staged" ]] || err "release 開始前已有 staged 變更：${staged}"
  git -C "$ROOT" add -- "${files[@]}"
  subject="ops: prepare api ${version}"
  if git -C "$ROOT" diff --cached --quiet -- "${files[@]}"; then
    [[ "$(git -C "$ROOT" log -1 --format=%s)" == "$subject" ]] \
      || git -C "$ROOT" commit --allow-empty -m "$subject"
  else
    git -C "$ROOT" commit -m "$subject" -- "${files[@]}"
  fi
  API_CANDIDATE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  echo "  candidate=${API_CANDIDATE_SHA} (${subject})"
}

ios_exact_asc_probe() {
  local version="$1" build="$2" output rc=0 asc_cmd="${KG_ASC_BUILD_CMD:-$ROOT/ops/asc.sh}"
  if [[ -n "${KG_ASC_BUILD_CMD:-}" ]]; then
    output="$($asc_cmd "$version" "$build" 2>&1)" || rc=$?
  else
    output="$($asc_cmd build "$version" "$build" 2>&1)" || rc=$?
  fi
  if (( rc == 0 )); then
    ios_validate_asc_build_json "$version" "$build" "$output" \
      || err "ASC exact build command 回傳 malformed/mismatched payload；不執行 upload/tag：${output:-<empty>}"
    printf '%s\n' "$output"
    return 0
  fi
  (( rc == 3 )) || err "ASC exact build lookup 失敗（exit ${rc}）：${output:-<empty>}；不執行 upload/tag"
  return 3
}

ios_validate_asc_build_json() {
  local version="$1" build="$2" payload="$3"
  jq -e --arg version "$version" --arg build "$build" '
    (.schema == "kg.asc.build.v1") and
    (.version == $version) and
    ((.build | tostring) == $build) and
    (.platform == "IOS") and
    ((.id | type) == "string") and
    ((.id | length) > 0) and
    (.processingState == "PROCESSING" or .processingState == "VALID")
  ' <<<"$payload" >/dev/null 2>&1
}

# ASC upload 成功與 ASC build 可查到之間存在 propagation window。只把 exit=3
# （目前尚未找到 exact build）當成可重試；auth/network/schema 失敗立即 hard-stop。
# 成功 payload 仍要由 release.sh 再驗一次，避免測試/替代 command 回傳錯誤 tuple。
ios_wait_for_exact_asc_build() {
  local version="$1" build="$2" output rc now deadline start
  local asc_cmd="${KG_ASC_BUILD_CMD:-$ROOT/ops/asc.sh}"
  [[ "$KG_RELEASE_ASC_WAIT_SECS" =~ ^[0-9]+$ && "$KG_RELEASE_ASC_POLL_SECS" =~ ^[0-9]+$ ]] \
    || err "KG_RELEASE_ASC_WAIT_SECS / KG_RELEASE_ASC_POLL_SECS 必須是非負整數"
  start="$(date +%s)"
  deadline=$((start + KG_RELEASE_ASC_WAIT_SECS))
  echo "  等 ASC 精確確認 ${version} build ${build}（最多 ${KG_RELEASE_ASC_WAIT_SECS}s）…" >&2
  while :; do
    output=""; rc=0
    if [[ -n "${KG_ASC_BUILD_CMD:-}" ]]; then
      output="$($asc_cmd "$version" "$build" 2>&1)" || rc=$?
    else
      output="$($asc_cmd build "$version" "$build" 2>&1)" || rc=$?
    fi
    if (( rc == 0 )); then
      ios_validate_asc_build_json "$version" "$build" "$output" \
        || err "ASC exact build command 回傳 malformed/mismatched payload；不建立 build tag：${output:-<empty>}"
      printf '%s\n' "$output"
      return 0
    fi
    (( rc == 3 )) \
      || err "ASC exact build lookup 失敗（exit ${rc}）：${output:-<empty>}；不建立 build tag"
    now="$(date +%s)"
    if (( now >= deadline )); then
      err "ASC 尚未顯示精確的 ${version} build ${build}（等待 ${KG_RELEASE_ASC_WAIT_SECS}s）；candidate 已保留。
   不要重跑 release/resubmit 產生下一顆 build；確認 ASC upload/processing 後，沿用同一 exact PR/source 重跑：
   ./ops/release.sh finalize ios ${version} ${build} --pr <number> --merged-source <sha> --yes"
    fi
    echo "    [elapsed=$((now - start))s] ASC 尚未顯示 exact build，${KG_RELEASE_ASC_POLL_SECS}s 後重試…" >&2
    sleep "$KG_RELEASE_ASC_POLL_SECS"
  done
}

# finalize 是 post-merge/post-upload recovery 的唯一正式入口：它要求 exact PR /
# merged-source evidence 與 sync 後的 main，先查 exact ASC build，再建立 immutable
# build tag。它不要求 candidate SHA 等於 origin/main，也不推送任何 branch ref。
cmd_finalize_ios() {
  local version="${1:?用法: release.sh finalize ios <x.y.z> <build> [--yes]}"
  local build="${2:-}" branch curver curbuild head subject tag existing live tuple
  local asc_json asc_id asc_state remote_tag remote_existing
  valid_semver "$version" || err "版本號格式錯誤：${version}（需 x.y.z）"
  [[ "$build" =~ ^[0-9]+$ ]] || err "build 必須是非負整數：${build:-<empty>}"
  [[ $# -le 2 ]] || err "finalize ios 不接受 candidate SHA positional；請用 --pr 與 --merged-source"
  [[ "$RELEASE_PR" =~ ^[0-9]+$ && "$RELEASE_PR" -gt 0 ]] \
    || err "finalize ios 必須提供 exact --pr <number> evidence"
  [[ -n "$MERGED_SOURCE" ]] || err "finalize ios 必須提供 exact --merged-source <sha> evidence"
  acquire_release_lock
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" == main ]] || err "finalize ios 須在 main 執行（目前 ${branch}）"
  ensure_release_primary_clean
  curver="$(current_version ios)"; curbuild="$(current_build)"
  [[ "$curver" == "$version" && "$curbuild" == "$build" ]] \
    || err "current project tuple=${curver}+${curbuild}，不是要 finalize 的 ${version}+${build}"
  head="$(git -C "$ROOT" rev-parse HEAD)"
  live="$(live_origin_main)"
  ios_assert_synced_main "$live"
  ios_assert_merged_source "$MERGED_SOURCE" "$live"
  github_assert_exact_merged_pr "$RELEASE_PR" "$MERGED_SOURCE" "$live"
  tuple="$(ios_origin_main_tuple "$live")"
  [[ "$tuple" == "${version}+${build}" ]] \
    || err "live origin/main tuple=${tuple}，不是要 finalize 的 ${version}+${build}"
  echo "  merged evidence: PR #${RELEASE_PR} source=${MERGED_SOURCE} live-main=${live}"

  tag="$(ios_build_tag "$version" "$build")"
  existing="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" || true)"
  [[ -z "$existing" || "$existing" == "$head" ]] \
    || err "${tag} 已存在且指向 $(git -C "$ROOT" rev-parse --short "$existing")，不是 merged main ${head:0:12}"
  remote_existing="$(ios_remote_tag_commit "$tag")"
  [[ -z "$remote_existing" || "$remote_existing" == "$head" ]] \
    || err "origin ${tag} 已存在且指向 ${remote_existing:0:12}，不是 merged main ${head:0:12}；拒絕 finalize"
  asc_json="$(ios_wait_for_exact_asc_build "$version" "$build")"
  asc_id="$(jq -r '.id' <<<"$asc_json")"
  asc_state="$(jq -r '.processingState' <<<"$asc_json")"
  echo "  exact ASC proof: id=${asc_id} state=${asc_state} version=${version} build=${build}"

  if [[ $YES -ne 1 ]]; then
    echo "[dry-run] 未建立 tag。確認無誤後加 --yes："
    echo "  ./ops/release.sh finalize ios ${version} ${build} --pr ${RELEASE_PR} --merged-source ${MERGED_SOURCE} --yes"
    return 0
  fi

  if [[ -z "$existing" ]]; then
    git -C "$ROOT" tag "$tag"
  else
    echo "  ${tag} 已指向 candidate ${head:0:12}，tag 建立步驟冪等略過"
  fi
  if [[ -z "$remote_existing" ]]; then
    git -C "$ROOT" push origin "$tag" \
      || err "finalize tag-only push 失敗；merged main 與 ASC proof 保留，可安全重跑 finalize"
  else
    echo "  origin ${tag} 已指向 merged main，略過重複 tag push"
  fi
  remote_tag="$(ios_remote_tag_commit "$tag")"
  [[ "$remote_tag" == "$head" ]] \
    || err "tag push 回報成功但 origin ${tag}=${remote_tag:-<missing>} ≠ ${head}"
  echo "✓ finalize ios ${version} build ${build}：PR #${RELEASE_PR} + merged source + ASC exact verified + ${tag} → ${head:0:12}（tag-only push）"
  echo "  上架後仍須另跑 ./ops/release.sh shipped ios --yes；本流程不宣稱 App Store 上架。"
}

cmd_finalize() {
  local target="${1:?用法: release.sh finalize ios <x.y.z> <build> [--yes]}"
  [[ "$target" == ios ]] || err "finalize 只支援 ios（ASC build provenance 目前只有 iOS）"
  shift
  cmd_finalize_ios "$@"
}

cmd_resume() {
  local target="${1:?用法: release.sh resume ios <x.y.z> <build> --pr <n> --merged-source <sha> [--yes]}"
  [[ "$target" == ios ]] || err "resume 目前只支援 ios；backend 仍須由 approved release operator 依 deploy SOP 執行"
  local version="${2:-}" build="${3:-}" branch curver curbuild live tuple
  valid_semver "$version" || err "版本號格式錯誤：${version}（需 x.y.z）"
  [[ "$build" =~ ^[0-9]+$ ]] || err "build 必須是非負整數：${build:-<empty>}"
  [[ $# -le 3 ]] || err "resume ios 多餘參數：${*:4}（merge evidence 用 --pr/--merged-source）"
  [[ "$RELEASE_PR" =~ ^[0-9]+$ && "$RELEASE_PR" -gt 0 ]] \
    || err "resume ios 必須提供 exact --pr <number> evidence"
  [[ -n "$MERGED_SOURCE" ]] || err "resume ios 必須提供 exact --merged-source <sha> evidence"
  acquire_release_lock
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" == main ]] || err "resume ios 須在 sync 後 main 執行（目前 ${branch}）"
  ensure_release_primary_clean
  live="$(live_origin_main)"
  ios_assert_synced_main "$live"
  ios_assert_merged_source "$MERGED_SOURCE" "$live"
  github_assert_exact_merged_pr "$RELEASE_PR" "$MERGED_SOURCE" "$live"
  curver="$(current_version ios)"; curbuild="$(current_build)"
  [[ "$curver" == "$version" && "$curbuild" == "$build" ]] \
    || err "merged main project tuple=${curver}+${curbuild}，不是要 resume 的 ${version}+${build}"
  tuple="$(ios_origin_main_tuple "$live")"
  [[ "$tuple" == "${version}+${build}" ]] || err "live origin/main tuple=${tuple}，不是 ${version}+${build}"

  echo "resume ios ${version}+${build}: PR #${RELEASE_PR} merged-source=${MERGED_SOURCE} live-main=${live}"
  echo "  plan: exact ASC probe → only if absent, ios_release.sh --upload → finalize tag-only"
  if [[ $YES -ne 1 ]]; then
    echo "[dry-run] 未 upload、未建立 tag。確認 merged/ASC evidence 後加 --yes："
    echo "  ./ops/release.sh resume ios ${version} ${build} --pr ${RELEASE_PR} --merged-source ${MERGED_SOURCE} --yes"
    return 0
  fi

  local existing_tag="$(ios_build_tag "$version" "$build")" existing_commit remote_existing tag_presealed=0
  existing_commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${existing_tag}^{commit}" || true)"
  remote_existing="$(ios_remote_tag_commit "$existing_tag")"
  if [[ -n "$existing_commit" || -n "$remote_existing" ]]; then
    [[ -z "$existing_commit" || "$existing_commit" == "$live" ]] \
      || err "${existing_tag} collision；local tag 指向 ${existing_commit:0:12}，拒絕重複 upload"
    [[ -z "$remote_existing" || "$remote_existing" == "$live" ]] \
      || err "${existing_tag} collision；origin tag 指向 ${remote_existing:0:12}，拒絕重複 upload"
    tag_presealed=1
    echo "  ${existing_tag} 已在 merged main 的 local/origin 任一側存在，resume 會跳過 upload 並重驗 exact ASC/tag receipt"
  else
    assert_ios_build_tag_unused "$version" "$build"
  fi
  local asc_probe_rc=0
  if (( tag_presealed == 1 )); then
    ios_exact_asc_probe "$version" "$build" >/dev/null
    echo "  exact ASC build 已存在，略過 upload，直接 finalize"
  elif ios_exact_asc_probe "$version" "$build" >/dev/null; then
    echo "  exact ASC build 已存在，略過 upload，直接 finalize"
  else
    asc_probe_rc=$?
    (( asc_probe_rc == 3 )) || err "ASC exact probe 非『尚未找到』結果（exit ${asc_probe_rc}）；拒絕猜測後 upload"
    if ! "$ROOT/ops/ios_release.sh" --upload; then
      echo "✗ upload 失敗；不建立 tag。保留 merged main，重試前先查 exact ASC，再沿用同一 resume 命令。" >&2
      return 1
    fi
  fi
  cmd_finalize_ios "$version" "$build"
}

# 非 x.y.z 一律 err，不回「不大於」。回 false 會讓 guard 用錯誤的理由拒絕、讓
# ios_pending_versions 靜默略過一筆——兩者都是把壞輸入變成看似正常的答案。
semver_gt() {
  local rma rmi rpa pma pmi ppa
  valid_semver "$1" && valid_semver "$2" \
    || err "semver_gt 收到非 x.y.z 的版本：'$1' vs '$2'（呼叫端應先 valid_semver）"
  IFS=. read -r rma rmi rpa <<<"$1"
  IFS=. read -r pma pmi ppa <<<"$2"
  rma=$((10#$rma)); rmi=$((10#$rmi)); rpa=$((10#$rpa))
  pma=$((10#$pma)); pmi=$((10#$pmi)); ppa=$((10#$ppa))
  (( rma > pma ||
     (rma == pma && rmi > pmi) ||
     (rma == pma && rmi == pmi && rpa > ppa) ))
}

# 版號漂移有兩種形狀，補救方向剛好相反：
#   ahead     — 檔內版號高於上個 tag：正常的「已 bump、未 tag」，發版前對齊即可。
#   mistagged — 上個 tag 高於檔內版號：那個版號被**撤回**了（tag 打了，pbxproj /
#               pyproject 隨後 revert 回去）。此時「先 bump 對齊」是錯誤指引，照做
#               會復活一個刻意撤回的版號；而且留著誤標 tag 會讓 last_tag 說謊——
#               新語意下 ios/<x.y.z> 宣稱「已上架」，一個從未上架的版號掛著這種
#               tag，會讓 guard 以它為基準，新版號也被迫跳過它。正解是刪掉那個 tag。
#               實例：ios/2.0.1（6821015a6 打 tag → f3499f3d4 還原成 2.0.0，2.0.1
#               從未上架；2.0.0 才是 READY_FOR_SALE）。
classify_version_drift() {  # $1=tag 版號 $2=檔內版號（呼叫端負責補成三段）
  if [[ "$1" == "$2" ]]; then printf 'none\n'
  elif ! valid_semver "$1" || ! valid_semver "$2"; then printf 'none\n'
  elif semver_gt "$1" "$2"; then printf 'mistagged\n'
  else printf 'ahead\n'; fi
}

bump_semver() {  # $1=x.y.z  $2=major|minor|patch
  local IFS=.; read -r MA MI PA <<<"$1"
  case "$2" in
    major) echo "$((MA+1)).0.0" ;;
    minor) echo "$MA.$((MI+1)).0" ;;
    patch) echo "$MA.$MI.$((PA+1))" ;;
  esac
}

# 「最新的 released marketing version tag」的實作在 ops/lib/release_tags.sh —— 與
# release_changelog.sh 共用同一份。`git tag -l "<prefix>*"` 的 `*` 會跨 `/` 比對，所以
# build tag 也落在 glob 內，且 `--sort=-v:refname` 把 ios/2.0.0+6 排在 ios/2.0.0 之上；
# 兩邊各自維護一份收緊規則，就是「只修了其中一份」那類事故的溫床。
last_tag() {
  local out rc=0
  out="$(release_last_tag "$1" "$ROOT")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    1) err "未知 component: $1（api|ios）" ;;
    *) err "無法列出 $1 的 tag（git 失敗）—— 不把它當成「尚未發版」處理" ;;
  esac
}

# 出過 build、但還沒有上架 tag 的 marketing version。build tag 讓這件事第一次可檢查：
# 在此之前 repo 完全不記錄「某版出過 archive」，所以「跳過一個還沒上架的版本」只能靠人記得。
ios_pending_versions() {  # $1=已上架版本 $2=本次要發的版本 → 印出待確認版本（空白分隔）
  local shipped="$1" requested="$2" all line ver out=""
  all="$(git -C "$ROOT" tag -l 'ios/*+*')" || err "無法列出 ios build tag（git 失敗）"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ver="${line#ios/}"; ver="${ver%%+*}"
    valid_semver "$ver" || continue
    [[ "$ver" != "$requested" ]] || continue
    semver_gt "$ver" "$shipped" || continue
    # 只看「夾在已上架與本次之間」的版本。高於 requested 的 build tag（例如已經在跑
    # 3.0.0 的實驗）不是被跳過的版本，把它算進來會用 2.0.1 事故的說詞擋一件沒發生的事。
    semver_gt "$requested" "$ver" || continue
    case " $out " in *" $ver "*) ;; *) out="${out:+$out }$ver" ;; esac
  done <<< "$all"
  printf '%s\n' "$out"
}

# A shipped marketing tag identifies the App Store source, while a build tag
# identifies the exact (marketing version, build) tuple already archived or
# uploaded. Once the current project tuple has a local build tag that is an
# ancestor of HEAD, status must use that build tag as the iOS pending boundary;
# otherwise the sealed candidate is reported as a new release backlog.
ios_current_build_tag() {
  local version build tag commit
  version="$(current_version ios)"
  build="$(current_build)"
  valid_semver "$version" || return 0
  [[ "$build" =~ ^[0-9]+$ ]] || return 0
  tag="$(ios_build_tag "$version" "$build")"
  commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}^{commit}" || true)"
  [[ -n "$commit" ]] || return 0
  git -C "$ROOT" merge-base --is-ancestor "$commit" HEAD || return 0
  printf '%s\n' "$tag"
}

# ios/<x.y.z> 現在的語意是「這個 marketing version 上架 App Store 的那顆 commit」，由
# `shipped ios` 依 ASC 驗證後才物化。所以**它存在本身就是上架證據**，這個 guard 不再需要
# operator 的 typed attestation（`--new-version-after-ready` 因此被移除），而是真的在檢查。
guard_ios_new_version() {
  local requested="$1" shipped_tag shipped pending
  shipped_tag="$(last_tag ios)"
  [[ -n "$shipped_tag" ]] || err "找不到任何已上架 tag ios/<x.y.z>（build tag 不算——那只代表出過 archive）。
   無從判斷 ${requested} 是不是真的往前。先跑 ./ops/release.sh shipped ios 從 ASC 確認目前上架的版本。"
  shipped="${shipped_tag#ios/}"

  [[ "$requested" != "$shipped" ]] \
    || err "${requested} 已經上架（${shipped_tag}）；同版號、新 build 的重送請走 ./ops/release.sh resubmit ios --yes"
  semver_gt "$requested" "$shipped" \
    || err "iOS 新 marketing version ${requested} 必須高於已上架的 ${shipped}；禁止倒退或重用已發布版號"

  pending="$(ios_pending_versions "$shipped" "$requested")"
  [[ -z "$pending" ]] || err "以下版本出過 build、但沒有上架 tag，狀態未確認：${pending}
   （build tag：$(git -C "$ROOT" tag -l 'ios/*+*' | tr '\n' ' ')）
   跳過它去發 ${requested}，正是 ios/2.0.1 事故的形狀：2.0.0 還在審就先 bump 了下一版。
   先跑 ./ops/release.sh shipped ios 確認上架版本；若該版確實沒上架，請走 resubmit ios 重送，不要跳過。"
}

# ---- status：各 component 待發版總覽（唯讀） ----
cmd_status() {
  local ios_status_sealed=0
  for c in api ios; do
    local tp cp lt range commits n suggest curver basever sv
    local analysis_tag latest_build_tag analysis_is_build_tag
    tp="$(tag_prefix "$c")"; cp="$(commit_prefix "$c")"
    lt="$(last_tag "$c")"
    analysis_tag="$lt"
    latest_build_tag=""
    analysis_is_build_tag=0
    if [[ "$c" == ios ]]; then
      latest_build_tag="$(ios_current_build_tag || true)"
      if [[ -n "$latest_build_tag" ]]; then
        analysis_tag="$latest_build_tag"
        analysis_is_build_tag=1
        ios_status_sealed=1
      fi
    fi
    if [[ -n "$analysis_tag" ]]; then range="$analysis_tag..HEAD"; else range=""; fi
    if [[ -n "$range" ]]; then
      commits="$(git -C "$ROOT" log "$range" --oneline --no-merges 2>/dev/null | grep -iE "^[a-f0-9]+ $cp" || true)"
    else
      commits="$(git -C "$ROOT" log --oneline --no-merges 2>/dev/null | grep -iE "^[a-f0-9]+ $cp" || true)"
    fi
    n="$(printf '%s' "$commits" | grep -c . || true)"
    # 建議 bump 等級
    if grep -qiE 'breaking|重寫|!:' <<<"$commits"; then suggest=major
    elif grep -qiE 'feat|新增|支援|feature' <<<"$commits"; then suggest=minor
    else suggest=patch; fi
    curver="$(current_version "$c")"
    basever="${lt#"$tp"}"; [[ -n "$basever" ]] || basever="$curver"
    if valid_semver "$basever"; then sv="$(bump_semver "$basever" "$suggest")"; else sv="（首發，參考檔內 ${curver}）"; fi

    local lt_label="上個 tag"
    [[ "$c" != ios ]] || lt_label="已上架 tag"
    echo "■ $c  ${lt_label}：${lt:-（尚未發版）}  檔內版本：$curver"
    # 漂移警示：上個 tag 的版號與版號檔不一致（如 tag api/1.6.0 但 pyproject 0.1.0）→ 發版前先對齊。
    # 比較前把兩段版號（ios pbxproj 慣用 1.6）補成三段再比，避免「1.6 vs 1.6.0」恆觸發警報疲勞。
    local cmpcur="$curver" drift
    [[ "$cmpcur" =~ ^[0-9]+\.[0-9]+$ ]] && cmpcur="$cmpcur.0"
    drift=none
    [[ -n "$lt" ]] && drift="$(classify_version_drift "$basever" "$cmpcur")"
    case "$drift" in
      ahead)
        echo "   ⚠ 版號漂移：上個 tag=${basever} 但檔內=${curver}（發版前先 bump 對齊）" ;;
      mistagged)
        echo "   ⛔ 誤標 tag：${tp}${basever} 高於檔內 ${curver} — 該版號已被撤回，從未發布。"
        echo "      留著它等於宣稱一個從未上架的版號已上架，guard 會以它為基準，"
        echo "      且新版號被迫跳過 ${basever}。正解是刪 tag（勿 bump 對齊）："
        echo "      git push origin :refs/tags/${tp}${basever} && git tag -d ${tp}${basever}" ;;
    esac
    if [[ "$n" -eq 0 ]]; then
      if [[ "$analysis_is_build_tag" -eq 1 ]]; then
        echo "   自最新 build tag 無未封版 $cp commit（已封版 ${latest_build_tag}；不要重新建立 upload candidate）"
      else
        echo "   自上個 tag 無 $cp commit（無待發版）"
      fi
    else
      if [[ "$analysis_is_build_tag" -eq 1 ]]; then
        echo "   build tag 之後有 $n 筆尚未封版 $cp commit；建議 $suggest → $sv"
      else
        echo "   待發版 $n 筆 $cp commit；建議 $suggest → $sv"
      fi
      printf '%s\n' "$commits" | head -15 | sed 's/^/     /'
      [[ "$n" -gt 15 ]] && echo "     … 還有 $((n-15)) 筆（完整清單見 ./ops/release.sh changelog ${c}）"
    fi
    # released 面（本地唯讀；不碰遠端）：origin/prod tracking ref = 上次 fetch 的「期望部署狀態」
    if [[ "$c" == api ]]; then
      local prod_ref ahead_prod
      prod_ref="$(git -C "$ROOT" rev-parse --short origin/prod 2>/dev/null || true)"
      if [[ -n "$prod_ref" ]]; then
        ahead_prod="$(git -C "$ROOT" rev-list --count origin/prod..main 2>/dev/null || echo '?')"
        echo "   released：origin/prod=${prod_ref}；main 超前 prod ${ahead_prod} commit（release backend 才推 prod→部署）"
        # tag 存在 ≠ 該版號上了生產：tag 是版本標記，部署看的是 origin/prod。
        if [[ -n "$lt" ]]; then
          if git -C "$ROOT" merge-base --is-ancestor "$lt" origin/prod 2>/dev/null; then
            echo "   ${lt} 已在 origin/prod（該版號已上生產）"
          else
            echo "   ${lt} 尚未進 origin/prod（版號已標記，但沒部署）"
          fi
        fi
      else
        echo "   released：origin/prod 本地未知（尚未 seed 或未 fetch；見 docs/sop/release.md 切換）"
      fi
      echo "   live：curl -s https://wordnexus.lol/api/system/info（欲查生產實跑版本）"
    else
      # 版號字串相等不代表 tag 指對地方：2.0.0 事故時 status 報「無漂移」（tag 2.0.0 =
      # 檔內 2.0.0），而那顆 tag 指著沒上架的 build 5 的 commit。build tag 是唯一能讓
      # 「這顆 build 有沒有被記錄」變成可見狀態的東西，所以在這裡攤開。
      local curbuild btag_now build_tags
      curbuild="$(current_build)"
      echo "   專案版號：MARKETING_VERSION=${curver}  CURRENT_PROJECT_VERSION=${curbuild}"
      build_tags="$(git -C "$ROOT" tag -l 'ios/*+*' --sort=-v:refname | tr '\n' ' ')"
      if [[ -n "${build_tags// /}" ]]; then
        echo "   build tag 對照："
        git -C "$ROOT" tag -l 'ios/*+*' --sort=-v:refname \
          | while IFS= read -r bt; do
              [[ -n "$bt" ]] || continue
              echo "     ${bt} → $(git -C "$ROOT" rev-parse --short "${bt}^{commit}")"
            done
      else
        echo "   build tag 對照：（無）"
      fi
      if valid_semver "$curver" && [[ "$curbuild" =~ ^[0-9]+$ ]]; then
        btag_now="$(ios_build_tag "$curver" "$curbuild")"
        if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/${btag_now}^{commit}" >/dev/null; then
          echo "   ⚠ 目前的 (${curver}, build ${curbuild}) 沒有 build tag ${btag_now}"
          echo "     = 這顆 build 若出過 archive，沒有留下 build→commit 紀錄（Apple 不留歷史，事後無法重建）"
          echo "     出 build 請走 ./ops/release.sh release ios <x.y.z> 或 resubmit ios，它們會封版"
        fi
      fi
      echo "   live：./ops/asc.sh builds（TestFlight 最新 build）+ review-status"
      echo "   上架後：./ops/release.sh shipped ios --yes（依 ASC 物化 ios/<x.y.z>）"
    fi
    echo
  done
  if [[ "$ios_status_sealed" -eq 1 ]]; then
    echo "下一步：確認 ASC／上架狀態；不要重複 bump 或 upload 已封版 tuple"
  else
    echo "下一步：./ops/release.sh bump <c> <ver> --yes → changelog <c> → release <backend|ios> <ver> --yes"
  fi
}

# ---- changelog：委派 primitive（唯讀） ----
cmd_changelog() {
  local c="${1:?用法: release.sh changelog <api|ios>}"; tag_prefix "$c" >/dev/null
  "$ROOT/ops/release_changelog.sh" "$c"
}

# API release versions are one bounded three-file transaction. Each candidate
# is prepared in its destination directory, validated, and mode-matched before
# any tracked file changes. Renames are atomic per file; same-directory backups
# let EXIT/signal handling roll back an unexpected later rename failure.
API_VERSION_PATHS=()
API_VERSION_CANDIDATES=()
API_VERSION_BACKUPS=()
API_VERSION_INSTALLED=0

api_version_cleanup_temps() {
  local path candidates backups
  # macOS ships Bash 3.2, where expanding a declared-but-empty array under
  # nounset raises instead of yielding zero words.
  set +u
  candidates=("${API_VERSION_CANDIDATES[@]}")
  backups=("${API_VERSION_BACKUPS[@]}")
  for path in "${candidates[@]}" "${backups[@]}"; do
    [[ -n "$path" ]] && rm -f "$path"
  done
  set -u
  API_VERSION_CANDIDATES=()
  API_VERSION_BACKUPS=()
}

api_version_rollback() {
  local i rollback_failed=0
  for ((i=API_VERSION_INSTALLED-1; i>=0; i--)); do
    mv -f "${API_VERSION_BACKUPS[$i]}" "${API_VERSION_PATHS[$i]}" || rollback_failed=1
  done
  API_VERSION_INSTALLED=0
  api_version_cleanup_temps
  [[ $rollback_failed -eq 0 ]] || echo "✗ API 版號 transaction rollback 失敗；請立即檢查三個版號檔" >&2
}

prepare_api_version_transaction() {
  local v="$1" root="${KG_ROOT:-$ROOT}" path candidate mode i
  API_VERSION_PATHS=(
    "$root/backend/pyproject.toml"
    "$root/backend/src/kg/api.py"
    "$root/backend/uv.lock"
  )
  API_VERSION_CANDIDATES=()
  API_VERSION_BACKUPS=()
  API_VERSION_INSTALLED=0

  # A readonly target is an operator-visible refusal, even though rename could
  # technically replace it through a writable parent directory.
  for path in "${API_VERSION_PATHS[@]}"; do
    if [[ ! -f "$path" || ! -w "$path" || ! -w "$(dirname "$path")" ]]; then
      api_version_cleanup_temps
      err "API 版號檔不可寫，未修改任何檔案：${path#$root/}"
    fi
    if ! candidate="$(mktemp "${path}.tmp.XXXXXX")"; then
      api_version_cleanup_temps
      err "無法在版號檔旁建立 transaction candidate：${path#$root/}"
    fi
    API_VERSION_CANDIDATES+=("$candidate")
  done

  if ! KG_RELEASE_VERSION="$v" perl -0pe '
    $n = s{^version = "[^"]+"$}{q{version = "} . $ENV{"KG_RELEASE_VERSION"} . q{"}}gme;
    END { exit 1 unless $n == 1 }
  ' "${API_VERSION_PATHS[0]}" > "${API_VERSION_CANDIDATES[0]}"; then
    api_version_cleanup_temps
    err "backend/pyproject.toml 必須恰有一個 project version entry"
  fi
  if ! KG_RELEASE_VERSION="$v" perl -0pe '
    $n = s{version="[^"]*"}{q{version="} . $ENV{"KG_RELEASE_VERSION"} . q{"}}ge;
    END { exit 1 unless $n == 1 }
  ' "${API_VERSION_PATHS[1]}" > "${API_VERSION_CANDIDATES[1]}"; then
    api_version_cleanup_temps
    err "backend/src/kg/api.py 必須恰有一個 API version entry"
  fi
  if ! KG_RELEASE_VERSION="$v" perl -0pe '
    $n = s{(^\[\[package\]\]\nname = "kg"\nversion = ")[^"]+("\nsource = \{ editable = "\." \}$)}
           {$1 . $ENV{"KG_RELEASE_VERSION"} . $2}gme;
    END { exit 1 unless $n == 1 }
  ' "${API_VERSION_PATHS[2]}" > "${API_VERSION_CANDIDATES[2]}"; then
    api_version_cleanup_temps
    err "backend/uv.lock 必須恰有一個 editable kg package entry"
  fi

  for ((i=0; i<3; i++)); do
    path="${API_VERSION_PATHS[$i]}"
    mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
    if ! chmod "$mode" "${API_VERSION_CANDIDATES[$i]}"; then
      api_version_cleanup_temps
      err "無法保留 API 版號檔 mode：${path#$root/}"
    fi
  done
}

commit_api_version_transaction() {
  local i path backup
  for ((i=0; i<3; i++)); do
    path="${API_VERSION_PATHS[$i]}"
    if ! backup="$(mktemp "${path}.bak.XXXXXX")"; then
      api_version_cleanup_temps
      err "無法建立 API 版號 transaction backup：${path#${KG_ROOT:-$ROOT}/}"
    fi
    # Cleanup owns the path as soon as mktemp creates it, including a later
    # cp -p failure.
    API_VERSION_BACKUPS+=("$backup")
    if ! cp -p "$path" "$backup"; then
      api_version_cleanup_temps
      err "無法寫入 API 版號 transaction backup：${path#${KG_ROOT:-$ROOT}/}"
    fi
  done

  # API bump can run inside release's repo lock. Compose the transaction
  # rollback with that outer cleanup instead of replacing its EXIT trap.
  trap api_version_exit_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  for ((i=0; i<3; i++)); do
    # Count the current slot before mv so a signal in the tiny post-rename
    # window still restores it. Restoring an unchanged slot is harmless.
    API_VERSION_INSTALLED=$((i + 1))
    if ! mv -f "${API_VERSION_CANDIDATES[$i]}" "${API_VERSION_PATHS[$i]}"; then
      err "API 版號 transaction 寫入失敗；已回復先前檔案"
    fi
  done
  API_VERSION_INSTALLED=0
  trap - HUP INT TERM
  api_version_restore_exit_cleanup
  api_version_cleanup_temps
}

# ---- bump：委派 primitive（本地檔案寫入；dry-run 預設，--yes 才寫） ----
cmd_bump() {
  local c="${1:?用法: release.sh bump <api|ios> <x.y.z> [--yes]}" v="${2:-}"
  tag_prefix "$c" >/dev/null
  [[ -n "$v" ]] || err "請提供版本號 x.y.z"
  valid_semver "$v" || err "版本號格式錯誤：${v}（需 x.y.z）"
  if [[ $YES -eq 1 ]]; then
    if [[ "$c" == api ]]; then
      prepare_api_version_transaction "$v"
      commit_api_version_transaction
      echo "✓ API version transaction → ${v}（pyproject.toml + api.py + uv.lock）"
    else
      "$ROOT/ops/release_bump.sh" "$c" "$v" --yes
    fi
  else
    "$ROOT/ops/release_bump.sh" "$c" "$v"
  fi
}

# ---- bump-build：只 +1 iOS build number（被拒同版重送；委派 primitive --build-only） ----
cmd_bump_build() {
  local c="${1:?用法: release.sh bump-build ios [--yes]}"
  [[ "$c" == ios ]] || err "bump-build 只支援 ios（api 無 build number；改版號用 ./ops/release.sh bump api <x.y.z>）"
  [[ $# -le 1 ]] || err "多餘參數：${*:2}（bump-build 不吃版本號，build number 自動 +1）"
  if [[ $YES -eq 1 ]]; then
    "$ROOT/ops/release_bump.sh" ios --build-only --yes
  else
    "$ROOT/ops/release_bump.sh" ios --build-only
  fi
}

# ---- tag api <v> --commit <sha>：補打歷史版本 tag（#2666）。不 commit、不動 branch，只把 tag 指到既有 commit。
# 守衛：該 commit 的 pyproject／api.py 版號 == <v>、是 live origin/prod 的 ancestor（確實上過生產）、tag 本地與
# remote 皆不存在。push 為 tag-only；dry-run 預設，--yes 才寫。
tag_api_at_commit() {  # $1=component $2=version（SHIPPED_COMMIT = --commit 值）
  local c="$1" v="$2" sha ver prod tag remote_tag
  [[ "$c" == api ]] || err "tag --commit 只支援 api（ios 的 tag 由 shipped ios 依 ASC 物化）"
  sha="$(git -C "$ROOT" rev-parse --verify -q "${SHIPPED_COMMIT}^{commit}")" \
    || err "--commit ${SHIPPED_COMMIT} 不是有效的 commit"
  tag="$(tag_prefix api)${v}"
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    && err "tag $tag 已存在（本地）；拒絕覆寫"
  remote_tag="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" \
    || err "git ls-remote origin 失敗；無法確認 tag $tag 是否已存在；fail-closed。"
  [[ -z "$remote_tag" ]] || err "tag $tag 已存在於 origin；拒絕覆寫"
  ver="$(promote_version_at "$sha")"
  [[ "$ver" == "$v" ]] || err "${sha:0:12} 的 backend 版號是 ${ver}，非 ${v}；拒絕打錯版本的 tag"
  prod="$(remote_head_sha prod)" || exit $?
  [[ "$prod" =~ ^[0-9a-f]{40}$ ]] || err "查不到 live origin/prod；fail-closed。"
  git -C "$ROOT" fetch -q origin prod || err "git fetch origin prod 失敗；fail-closed。"
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$prod" 2>/dev/null \
    || err "${sha:0:12} 不是 live origin/prod=${prod:0:12} 的 ancestor（從未上過生產）；拒絕補 tag"
  echo "component=api  version=$v  tag=$tag  commit=${sha}（補打歷史 tag，不 commit、不動 branch）"
  if [[ $YES -eq 1 ]]; then
    git -C "$ROOT" tag "$tag" "$sha"
    git -C "$ROOT" push origin "$tag"
    echo "✓ 已 tag ${tag} → ${sha:0:12} + tag-only push。"
  else
    echo "dry-run：未寫入。確認後加 --yes 才會建 tag 並推送 origin ${tag}。"
  fi
}

# ---- tag：commit 版號檔 + 打 tag + tag-only push（版號標記，非部署；dry-run 預設）----
# tag 不觸發生產，也不更新任何 branch ref；生產部署／upload 由 resume 完成。（原名 publish）
cmd_tag() {
  local c="${1:?用法: release.sh tag <api|ios> <x.y.z> [--yes]}" v="${2:-}"
  tag_prefix "$c" >/dev/null
  [[ -n "$v" ]] || err "請提供版本號 x.y.z"
  valid_semver "$v" || err "版本號格式錯誤：${v}（需 x.y.z）"
  if [[ -n "$SHIPPED_COMMIT" ]]; then tag_api_at_commit "$c" "$v"; return; fi
  # resubmit 走的是「同一個 marketing version 的下一顆 build」，而 guard_ios_new_version
  # 專門擋「換版號」——套在重送上會擋掉唯一正確的那條路。用明示的內部旗標開洞，而不是
  # 把 guard 改成可有可無：預設一定跑，只有 cmd_resubmit 會關掉它。
  if [[ "$c" == ios && $IOS_SAME_VERSION_RESUBMIT -eq 0 ]]; then
    guard_ios_new_version "$v"
  fi

  local tp tag files curver branch build
  IOS_BUILD_TAG_STATE=""   # 每次呼叫重新判定，不吃上一次的殘值
  tp="$(tag_prefix "$c")"
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != HEAD ]] || err "detached HEAD —— 先 checkout 一個分支再發版（避免 push origin HEAD）"
  case "$c" in
    api)
      files=(backend/pyproject.toml backend/src/kg/api.py backend/uv.lock)
      tag="${tp}${v}"
      # preflight
      git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
        && err "tag $tag 已存在（重複發版？換版號或先刪 tag）"
      ;;
    ios)
      files=(ios/BooksAndVocab.xcodeproj/project.pbxproj)
      # iOS 這裡封的是 (version, build)，不是 ios/<x.y.z>。後者代表「上架」，而 upload
      # 完成的那一刻沒有任何人知道它會不會過審——那個 tag 由 `shipped ios` 依 ASC 物化。
      build="$(current_build)"
      [[ "$build" =~ ^[0-9]+$ ]] \
        || err "讀不到 pbxproj 的 CURRENT_PROJECT_VERSION（app target 結構異常）：'${build}'"
      tag="$(ios_build_tag "$v" "$build")"
      check_ios_build_tag "$tag" "${files[@]}"
      ;;
  esac
  curver="$(current_version "$c")"
  [[ "$curver" == "$v" ]] || err "版號檔目前是 ${curver}，非 ${v} —— 先跑 ./ops/release.sh bump ${c} ${v} --yes"

  echo "component=$c  version=$v  tag=$tag  branch=$branch"
  echo "  將 commit 的檔：${files[*]}"
  echo "  commit message：ops: release $c $v"
  [[ "$c" != ios ]] || echo "  ios/${v}（上架標記）不在此步驟產生 —— 過審後跑 ./ops/release.sh shipped ios"

  if [[ $YES -eq 1 ]]; then
    git -C "$ROOT" add -- "${files[@]}"
    if git -C "$ROOT" diff --cached --quiet -- "${files[@]}"; then
      echo "  版號檔已在目前 HEAD，略過空 release commit；tag 將指向 $(git -C "$ROOT" rev-parse --short HEAD)"
    else
      # pathspec 鎖住 release files，避免把 operator 預先 staged 的無關變更一起提交。
      git -C "$ROOT" commit -m "ops: release $c $v" -- "${files[@]}"
    fi
    if [[ "$IOS_BUILD_TAG_STATE" == idempotent ]]; then
      echo "  ${tag} 已指向 $(git -C "$ROOT" rev-parse --short HEAD)，略過重複 tag"
      echo "  （中斷後補跑請用 tag，不要用 release/resubmit —— 那會再 upload 一次，被 TestFlight 擋下）"
    else
      git -C "$ROOT" tag "$tag"
    fi
    git -C "$ROOT" push origin "$tag"
    echo "✓ 已 commit + tag ${tag} + tag-only push（不更新 branch；生產部署走 resume）。"
  else
    echo "[dry-run] 未送出。確認無誤後加 --yes 才會 commit + 打 tag + tag-only push："
    echo "  ./ops/release.sh tag $c $v --yes"
  fi
}

# ---- shipped：把「上架」這個事實從 ASC 取回，join build tag，物化成 ios/<x.y.z> ----
# 這是驗證式，不是背書式：repo 不宣稱它不擁有的事實。
#   誰上架了      → ASC（唯一權威，且只保留當前一筆 → 只能現在問，不快取成 repo 內的事實）
#   誰產生了它    → repo 的 build tag（Apple 會銷毀這個資訊）
#   ios/<x.y.z>   → 上兩者的 join，只在確認上架後才落地
#
# KG_ASC_SHIPPED_CMD 是唯一注入點（測試以 stub 覆寫，整節離線可跑）。
# 契約：stdout 一行 "<marketing-version> <build-number>"；非零 exit = 查不到。
asc_shipped_pair() {
  if [[ -n "${KG_ASC_SHIPPED_CMD:-}" ]]; then
    "$KG_ASC_SHIPPED_CMD"
  else
    "$ROOT/ops/asc_shipped.py"
  fi
}

cmd_shipped() {
  local target="${1:?用法: release.sh shipped ios [--commit <sha>] [--yes]}"
  [[ "$target" == ios ]] \
    || err "shipped 只支援 ios（api 的「已上生產」看 origin/prod，見 ./ops/release.sh status）"
  [[ $# -le 1 ]] || err "多餘參數：${*:2}（版本與 build 由 ASC 決定，不從命令列接受）"

  local pair="" rc=0 ver build btag commit vtag existing manual=0 short_commit remote_vtag="" local_only=0
  pair="$(asc_shipped_pair)" || rc=$?
  [[ "$rc" -eq 0 && -n "$pair" ]] \
    || err "查不到 App Store 上架版本（ASC 查詢失敗、憑證/網路不可用，或目前沒有 READY_FOR_SALE）。
   不降級成猜測：修好連線後重跑，或人工確認後用 --commit <sha> 指定。"
  read -r ver build _rest <<<"$pair"
  valid_semver "$ver" \
    || err "ASC 回的 versionString 不是 x.y.z：'${ver}'——不拿它去組 tag 名"
  [[ "$build" =~ ^[0-9]+$ ]] \
    || err "ASC 回的 build number 不是數字：'${build}'——不拿它去組 tag 名"

  btag="$(ios_build_tag "$ver" "$build")"
  if [[ -n "$SHIPPED_COMMIT" ]]; then
    commit="$(git -C "$ROOT" rev-parse -q --verify "${SHIPPED_COMMIT}^{commit}")" \
      || err "--commit ${SHIPPED_COMMIT} 不是有效的 commit"
    manual=1
  else
    commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${btag}^{commit}" || true)"
    [[ -n "$commit" ]] || err "App Store 上架的是 ${ver} build ${build}，但 repo 裡沒有 ${btag}。
   這顆 build 沒有留下 build→commit 紀錄（多半發版於本機制上線前）。Apple 只保留當前
   版本、不留歷史，所以這個對應關係已無法自動重建：人工判定後用
   ./ops/release.sh shipped ios --commit <sha> --yes 指定。"
  fi
  short_commit="$(git -C "$ROOT" rev-parse --short "$commit")"

  vtag="ios/${ver}"
  existing="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${vtag}^{commit}" || true)"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$commit" ]]; then
      if ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
        echo "✓ ${vtag} 已指向 ${short_commit}，與 ASC 一致，無需變更（無 origin remote）。"
        return 0
      fi
      remote_vtag="$(ios_remote_tag_commit "$vtag")"
      if [[ -z "$remote_vtag" ]]; then
        local_only=1
        echo "  ${vtag} 只存在於本機（${short_commit}），origin 尚缺——補推。"
      elif [[ "$remote_vtag" == "$commit" ]]; then
        echo "✓ ${vtag} 已指向 ${short_commit}，local 與 origin 皆與 ASC 一致，無需變更。"
        return 0
      else
        err "origin ${vtag} 指向 ${remote_vtag:0:12}，但 local 與 ASC 皆為 ${short_commit}。
   上架 tag 是 immutable 的，本工具不移動它——需要人工裁決 origin 的 tag。"
      fi
    else
    # 一個 released marketing version 最終只會有一顆上架 build（Apple 規則：released
    # 之後要再發必須提高 marketing version），所以這個 tag 天生 immutable。工具不移動它。
    err "${vtag} 已存在且指向 $(git -C "$ROOT" rev-parse --short "$existing")，但 ASC 說上架的是 ${short_commit}。
   上架 tag 是 immutable 的，本工具不移動它——兩者之一是錯的，需要人工裁決。
   確認舊 tag 是錯的之後：
     git tag -d ${vtag} && git push origin :refs/tags/${vtag}
   再重跑 ./ops/release.sh shipped ios --yes"
    fi
  fi

  echo "App Store 上架版本=${ver}  build=${build}"
  echo "  ASC 來源：${KG_ASC_SHIPPED_CMD:-ops/asc_shipped.py}"
  if [[ $manual -eq 1 ]]; then
    echo "  ⚠ commit 由 --commit 人工指定：${short_commit}（這是人工斷言，不是查證出來的 join）"
  else
    echo "  commit 來自 build tag ${btag}：${short_commit}"
  fi
  if (( local_only == 1 )); then
    echo "  將補推既有上架 tag：${vtag} → ${short_commit}"
  else
    echo "  將建立上架 tag：${vtag} → ${short_commit}"
  fi

  if [[ $YES -eq 1 ]]; then
    (( local_only == 1 )) || git -C "$ROOT" tag "$vtag" "$commit"
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$ROOT" push origin "$vtag" \
        || err "push origin ${vtag} 失敗；local tag 已保留，可安全重跑 shipped ios --yes 補推"
      remote_vtag="$(ios_remote_tag_commit "$vtag")"
      [[ "$remote_vtag" == "$commit" ]] \
        || err "push 回報成功但 origin ${vtag}=${remote_vtag:-<missing>} ≠ ${commit}"
      echo "✓ 已建立 ${vtag} 並推送 origin（另一台 clone 需要同一份紀錄）。"
    else
      echo "✓ 已建立 ${vtag}（無 origin remote，未推送）。"
    fi
  else
    echo "[dry-run] 未建立。確認無誤後加 --yes："
    echo "  ./ops/release.sh shipped ios${SHIPPED_COMMIT:+ --commit $SHIPPED_COMMIT} --yes"
  fi
}

# ---- resubmit：同版號、新 build 的重送（App Review 被拒 / 未上架就要換 binary）----
# 這條路徑原本是 `bump-build ios --yes` + `ios_release.sh --upload` 兩步手動，**不留任何
# 紀錄**：沒有 release commit、沒有 tag。ios/2.0.0 指著 build 5 的 commit、實際上架的卻是
# 五天後的 build 6，成因就是這裡——腳本從來沒有詞彙描述「同版號的第 N 顆 build」。
# 與 cmd_release 對稱：ASC 對帳 → bump → dedicated-lane candidate commit → hand-back；
# merge 後由 resume 以 exact PR/source receipt 對帳 ASC，再 upload/tag。未知 ASC 狀態硬停。
asc_latest_testflight_build() {
  local output="" rc=0 latest="" asc_cmd="${KG_ASC_BUILDS_CMD:-$ROOT/ops/asc.sh}"
  if [[ -n "${KG_ASC_BUILDS_CMD:-}" ]]; then
    output="$("$asc_cmd")" || rc=$?
  else
    output="$("$asc_cmd" builds)" || rc=$?
  fi
  (( rc == 0 )) \
    || err "查不到 TestFlight 最新 build（ASC 查詢 exit ${rc}）——不降級成 local+1，修好 ASC 後重試"
  latest="$(sed -nE 's/^TestFlight 最新 build number: *([0-9]+)$/\1/p' <<<"$output" | tail -1)"
  [[ "$latest" =~ ^[0-9]+$ ]] \
    || err "ASC TestFlight 最新 build 不是數字：${output:-（無輸出）}——不拿不確定狀態產生新 build"
  printf '%s\n' "$((10#$latest))"
}

cmd_resubmit() {
  local target="${1:?用法: release.sh resubmit ios [--yes]}"
  [[ "$target" == ios ]] \
    || err "resubmit 只支援 ios（api 沒有 build number 概念；改版號用 ./ops/release.sh bump api <x.y.z>）"
  [[ $# -le 1 ]] || err "多餘參數：${*:2}（resubmit 不吃版本號——版號不變才叫重送）"

  local branch curver curbuild tf_latest newbuild
  acquire_release_lock
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  assert_release_lane_branch
  curver="$(current_version ios)"
  valid_semver "$curver" \
    || err "pbxproj 的 MARKETING_VERSION 是 '${curver}'，不是 x.y.z —— 先跑 ./ops/release.sh bump ios <x.y.z> --yes 對齊成三段"
  curbuild="$(current_build)"
  [[ "$curbuild" =~ ^[0-9]+$ ]] || err "讀不到 pbxproj 的 CURRENT_PROJECT_VERSION：'${curbuild}'"
  ensure_release_primary_clean
  ios_refuse_pending_candidate "$curver" "$curbuild"
  assert_release_lane_base
  tf_latest="$(asc_latest_testflight_build)"
  newbuild=$((curbuild > tf_latest ? curbuild : tf_latest))
  newbuild=$((newbuild + 1))

  echo "resubmit ios ${curver}  build ${curbuild} → ${newbuild}  (local=${curbuild} ASC TestFlight latest=${tf_latest})  dedicated-lane=${branch}"
  echo "  candidate tuple: $(ios_build_tag "$curver" "$newbuild")"
  echo "  計畫（dry-run 預設）："
  echo "    1) bump-build ios（CURRENT_PROJECT_VERSION ${curbuild} → ${newbuild}；ASC latest=${tf_latest}；MARKETING_VERSION 不動）"
  echo "    2) candidate commit in ${branch} + supported hand-back to IM（不碰 protected main）"
  echo "    3) IM PR → required/native merge queue → CM sync exact merged main"
  echo "    4) resume after exact PR/source evidence：ASC probe → upload if absent → tag-only finalize"
  echo "  ios/${curver}（上架標記）不在本流程產生 —— 過審後跑 ./ops/release.sh shipped ios"

  if [[ $YES -ne 1 ]]; then
    echo "[dry-run] 未執行。確認無誤後加 --yes："
    echo "  ./ops/release.sh resubmit ios --yes"
    return 0
  fi

  assert_ios_build_tag_unused "$curver" "$newbuild"
  "$ROOT/ops/release_bump.sh" ios --build-only --build-number="$newbuild" --yes
  ios_commit_candidate "$curver" "$newbuild"
  emit_candidate_handback ios "$curver" "$newbuild"
}

# ---- release：前後端統一 candidate 入口。dry-run 預設，--yes 才 commit ----
# backend/ios: dedicated lane bump → candidate commit → supported hand-back → IM PR。
# 任何 upload/deploy/tag-only finalize 都必須在 merged main 的 resume/finalize route。
# ---- 部署收斂閘（release backend 的最後一哩）----------------------------------
# deploy 只保證 origin/prod 前進——那是「我要求什麼」，不是「線上跑什麼」。真正的部署
# 由 felix reconciler 非同步做，失敗會自動回滾 + poison，而它唯一的聲音是 felix 本機的
# ~/Library/Logs/kg_reconcile.err.log。在此直接印 ✓ 等於把「已回滾」宣告成「已發布」，
# 是鐵律 2 的正面違反。所以推完守著看，直到線上自報版本 == 推出去的 sha，或逾時。

# 這次 range 會不會真的觸發 rollout。**刻意委派 kg_reconcile.sh 的 paths_need_deploy**
# 而不是在這裡再寫一份正則：兩份判定必然漂移，而漂移的後果是這個閘等一場永遠不會發生
# 的 rollout（例如 range 內只有 docs／ios，reconciler 只 ff-only 不重建）。
# backend/uv.lock 自 #2088 起在 reconciler 的正則內（Dockerfile 依它安裝），
# lock-only range 也會 rebuild，所以必須等。
# 用 subshell source 取純函式，隔離它的全域（它會設 CURL_BIN / KG_PUBLIC_URL 等同名變數）。
paths_trigger_rollout() {
  # 找不到 reconciler 就 err，不靜默當成「不用等」：那會讓這個閘在最需要它的時候
  # （工具被搬動／檔名改了）安靜消失，而症狀是「release 又變回推完就 ✓」——沒人會發現。
  [[ -f "$ROOT/ops/kg_reconcile.sh" ]] \
    || err "找不到 $ROOT/ops/kg_reconcile.sh —— 收斂判定的正則來源不見了，拒絕用猜的代替"
  ( source "$ROOT/ops/kg_reconcile.sh" >/dev/null 2>&1; paths_need_deploy )
}

# 線上自報版本；非 200 或抽不到一律回空字串（空 ≠ 收斂，呼叫端據此繼續等）。
live_version() {
  local body code
  body="$("$CURL_BIN" -sS -o - -w $'\n%{http_code}' --max-time 10 \
          "$KG_PUBLIC_URL/api/system/info" 2>/dev/null || true)"
  code="$(printf '%s\n' "$body" | tail -n1)"
  body="$(printf '%s\n' "$body" | sed '$d')"
  [[ "$code" == "200" ]] || return 0
  printf '%s' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# 輪詢到線上版本 == want（reconciler 寫的是 `git rev-parse --short`，長度隨 repo 變，
# 故比 prefix 而非全等）。**下限 7 字元**：沒有這道下限，任何回傳 "d" 的壞掉端點都會
# 命中一個以 d 開頭的 sha，把「壞掉」讀成「收斂」。
wait_for_rollout() {
  local want="$1" deadline now ver last="__none__"
  deadline=$(( $(date +%s) + KG_RELEASE_WAIT_SECS ))
  echo "  等 felix reconciler 收斂（最長 ${KG_RELEASE_WAIT_SECS}s：90s tick + image rebuild + 三段健康 gate）…"
  while :; do
    ver="$(live_version)"
    if [[ ${#ver} -ge 7 && "$want" == "$ver"* ]]; then
      echo "✓ 生產已收斂：${KG_PUBLIC_URL} 自報 version=${ver}"
      return 0
    fi
    if [[ "$ver" != "$last" ]]; then
      echo "    [$(date '+%H:%M:%S')] 線上 version=${ver:-<不可達>}（期望 ${want:0:12}…）"
      last="$ver"
    fi
    now="$(date +%s)"
    (( now < deadline )) || break
    sleep "$KG_RELEASE_POLL_SECS"
  done
  echo "✗ 逾時 ${KG_RELEASE_WAIT_SECS}s：線上仍是 version=${ver:-<不可達>}，期望 ${want:0:12}…" >&2
  echo "  origin/prod 已前進（push 本身已用 ls-remote 驗過），但 reconciler 沒把它變成線上版本。" >&2
  echo "  三種可能：仍在 build／健康 gate 失敗已自動回滾（會 poison 該 sha，冷卻 3600s 後才重試）／reconciler 停擺。" >&2
  echo "  查真相：" >&2
  echo "    ./ops/devops_kg_safe.sh run \"tail -40 ~/Library/Logs/kg_reconcile.err.log\"" >&2
  echo "    ./ops/devops_kg_safe.sh run \"tail -5  ~/Library/Logs/kg_reconcile.out.log\"" >&2
  return 1
}

cmd_release() {
  local target="${1:?用法: release.sh release <backend|ios> <x.y.z> [--yes]}" v="${2:-}"
  local comp
  case "$target" in
    backend|api) comp=api ;;
    ios)         comp=ios ;;
    *) err "未知 target: ${target}（backend|ios）" ;;
  esac
  [[ -n "$v" ]] || err "請提供版本號 x.y.z"
  valid_semver "$v" || err "版本號格式錯誤：${v}（需 x.y.z）"
  # Production touches (`promote` push to origin/prod, `ios_release.sh --upload`)
  # live only after exact merged-main evidence; this candidate path contains
  # neither. The post-merge route requires `branch == main` in resume/finalize,
  # while this command requires the inverse dedicated-lane guard.
  acquire_release_lock
  if [[ "$comp" == ios ]]; then
    guard_ios_new_version "$v"
  fi

  local branch curver curbuild target_build need_bump live_main live_tuple
  assert_release_lane_branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  curver="$(current_version "$comp")"
  # need_bump 用 RAW 相等（與 cmd_tag 的 strict curver==v 檢查一致）：ios 慣用兩段 MARKETING_VERSION
  # (如 2.0)，若用正規化相等判 2.0==2.0.0 會跳過 bump，但 cmd_tag strict 比較 raw 2.0≠2.0.0 反而
  # abort。用 raw 判 → 2.0 vs 2.0.0 觸發 bump 寫成三段 → cmd_tag 一致通過。
  need_bump=0; [[ "$curver" == "$v" ]] || need_bump=1
  if [[ "$comp" == ios ]]; then
    ensure_release_primary_clean
    curbuild="$(current_build)"
    [[ "$curbuild" =~ ^[0-9]+$ ]] || err "讀不到 pbxproj 的 CURRENT_PROJECT_VERSION：'${curbuild}'"
    ios_refuse_pending_candidate "$curver" "$curbuild"
    target_build="$curbuild"
    (( need_bump == 1 )) && target_build=$((curbuild + 1))
    live_main="$(live_origin_main)"
    live_tuple="$(ios_origin_main_tuple "$live_main")"
    [[ "$live_tuple" != "${v}+${target_build}" ]] \
      || err "live origin/main=${live_main} 已包含 iOS tuple ${live_tuple}；禁止在 release lane 重造 build。先由 CM sync，再用 resume ios ${v} ${target_build} --pr <number> --merged-source <sha>。"
  fi
  assert_release_lane_base

  echo "release target=${target}（component=${comp}）version=${v}  branch=${branch}"
  echo "  計畫（dry-run 預設）："
  if [[ $need_bump -eq 1 ]]; then echo "    1) bump ${comp} ${v}（檔內 ${curver} → ${v}）"; else echo "    1) bump 略過（檔內已 ${curver}）"; fi
  if [[ "$comp" == api ]]; then
    echo "    2) candidate commit in ${branch} + supported hand-back to IM（不碰 protected main）"
    echo "    3) IM PR → required/native merge queue → CM sync exact merged main"
    echo "    4) approved backend release operator resumes via deploy SOP（本命令不 deploy）"
  else
    echo "    2) candidate commit in ${branch} + supported hand-back to IM（先保存 ${v}+${target_build} provenance）"
    echo "    3) IM PR → required/native merge queue → CM sync exact merged main"
    echo "    4) resume ios ${v} ${target_build} --pr <number> --merged-source <sha>（ASC probe → upload if absent → tag-only）"
    echo "    ios/${v}（上架標記）不在本流程產生 —— 過審後跑 ./ops/release.sh shipped ios"
  fi

  if [[ $YES -ne 1 ]]; then
    echo "[dry-run] 未執行。確認無誤後加 --yes："
    echo "  ./ops/release.sh release ${target} ${v} --yes"
    return 0
  fi

  # 執行：只在 dedicated lane 產生 candidate；不 push、upload、deploy 或 tag。
  if [[ "$comp" == api ]]; then
    if [[ "$need_bump" -eq 1 ]]; then cmd_bump "$comp" "$v"; fi
    api_commit_candidate "$v"
    emit_candidate_handback backend "$v"
  else
    assert_ios_build_tag_unused "$v" "$target_build"
    if [[ "$need_bump" -eq 1 ]]; then cmd_bump "$comp" "$v"; fi
    [[ "$(current_build)" == "$target_build" ]] \
      || err "bump 後 build drift：預期 ${target_build}，實際 $(current_build)"
    ios_commit_candidate "$v" "$target_build"
    emit_candidate_handback ios "$v" "$target_build"
  fi
}

# ---- promote：唯一推進 origin/prod 的官方路徑（felix reconciler 只認 origin/prod） ----
# 守衛全為唯讀查詢，dry-run 與 --yes 走同一組；只有最後一個 push 受 --yes 管。永不 force：
# prod 非 SHA 的 ancestor 即拒絕（reconciler 也拒絕 rewind）。
promote_version_at() {  # $1=ref → pyproject 與 api.py 的 backend 版號（兩者不一致即 err）
  local py api
  py="$(git -C "$ROOT" show "$1:backend/pyproject.toml" 2>/dev/null | sed -nE 's/^version = "([^"]+)".*/\1/p' | head -1)"
  api="$(git -C "$ROOT" show "$1:backend/src/kg/api.py" 2>/dev/null | sed -nE 's/^[[:space:]]*version="([^"]+)".*/\1/p' | head -1)"
  valid_semver "$py" || err "$1 的 backend/pyproject.toml 讀不到 x.y.z 版號：'${py}'"
  [[ "$py" == "$api" ]] || err "$1 的 pyproject(${py}) 與 api.py(${api:-<空>}) 版號不一致；拒絕 promote。"
  printf '%s\n' "$py"
}

# CI 證據（嚴格版）：server-side 不做 name 過濾（filter=all 含被 rerun 取代的舊 run），--paginate 取全頁，jq -s 合併；
# client-side 只選下方 check_pr／check_push 兩個精確名稱的 check-run。依 check_suite.id 分組：**每個 suite 內 id 最大（最新 attempt）的 run 必須
# completed/success**；同 suite 內被 rerun 取代的舊失敗 attempt 不擋（#2660），不同 suite 的失敗（另一次獨立
# CI 執行）仍拒絕。skipped／neutral／in_progress／缺席都不算綠；run 缺 id／check_suite.id 無法判定最新 attempt
# → 不算綠。total_count 與實收 run 數不符 → 視為不完整。
# 實證（#2660 P2，2026-10-10 唯讀 gh api）：run 37920482067（pr-gate）attempt 1 = failure、attempt 2 = success，
# 兩者 run_id 與 check_suite_id 皆為 102741169602；attempt 2 的 job（如 backend-quality / backend-quality，
# id 113886985309，started 2026-10-09T15:14:57Z）落在同一 suite。故「同 suite 內取 id 最大」即最新 attempt；跨 suite 不合併。
# 實證（2026-10-13 唯讀 gh api／gh run view）：main commit 0ca410d5c（backend 2.2.0）只有 push 觸發的 run 38349139156
# （workflow "backend-quality"，event push，branch main）產生的 check-run，名為 "backend-quality"；**不存在**
# "backend-quality / backend-quality"。舊版只查後者，對 push-run 得到 0 筆，已批准的 2.2.0 promote 被誤擋。
# 修法維持 fail-closed：只接受上述兩個精確名稱（其他如 "backend-quality / image-lock" 不得替代）；suite／attempt／
# total_count 的所有規則不變。pr-gate run 與 push-run 同時存在時，兩者各自所屬 suite 的最新 attempt 都必須全綠。
# seam：KG_CHECK_RUNS_JSON_CMD <sha> 回傳 raw gh JSON（可為多頁串接），讓測試走真的 jq 過濾器。
promote_assert_backend_quality() {  # $1=sha
  local sha="$1" out rc=0
  # 兩個精確名稱（不做 prefix／substring 比對）：
  #   check_pr   = "backend-quality / backend-quality"：pr-gate.yml caller → backend-quality.yml reusable job（PR／merge-queue run）
  #   check_push = "backend-quality"：backend-quality.yml 直接由 push 觸發（main commit 上實際存在的名稱）
  local check_pr="backend-quality / backend-quality" check_push="backend-quality"
  local -a names=(--arg a "$check_pr" --arg b "$check_push")
  if [[ -n "${KG_CHECK_RUNS_JSON_CMD:-}" ]]; then out="$($KG_CHECK_RUNS_JSON_CMD "$sha" 2>&1)" || rc=$?
  else
    command -v gh >/dev/null 2>&1 || err "找不到 gh；無法讀 ${sha} 的 CI 證據，拒絕 promote。"
    out="$(gh api --paginate "repos/${KG_GH_REPO}/commits/${sha}/check-runs?filter=all&per_page=100" 2>&1)" || rc=$?
  fi
  (( rc == 0 )) || err "讀取 ${sha} 的 check-runs 失敗（exit ${rc}）：${out:-<empty>}；無證據即拒絕。"
  jq -s -e 'length > 0 and all(.[]; type == "object" and (.check_runs | type) == "array")' <<<"$out" >/dev/null 2>&1 \
    || err "${sha} 的 check-runs 回應無法解析（非 JSON 或缺 check_runs）：${out:0:200}；拒絕 promote。"
  jq -s -e '([.[].check_runs[]] | length) == (.[0].total_count // -1)' <<<"$out" >/dev/null 2>&1 \
    || err "${sha} 的 check-runs 回應不完整（total_count 與實收 run 數不符，疑似分頁截斷）；拒絕 promote。"
  jq -s -e "${names[@]}" '[.[].check_runs[] | select(.name == $a or .name == $b)] | length > 0' <<<"$out" >/dev/null 2>&1 \
    || err "${sha} 沒有任何 backend-quality check-run（CI 沒跑）；拒絕 promote。選有 backend 變更且 CI 綠的 main commit。"
  jq -s -e "${names[@]}" '[.[].check_runs[] | select(.name == $a or .name == $b)]
      | all(.[]; (.id | type) == "number" and (.check_suite.id | type) == "number")
        and (group_by(.check_suite.id) | all(.[]; (map(.id) | max) as $m | [.[] | select(.id == $m)] | all(.status == "completed" and .conclusion == "success")))' <<<"$out" >/dev/null 2>&1 \
    || err "${sha} 沒有全綠的 backend-quality check-run（每個 check suite 最新 attempt 都必須 completed/success；失敗、skipped、neutral、進行中、缺 id 皆不算；同 suite 內被 rerun 取代的舊 attempt 不計）；拒絕 promote。"
}

cmd_promote() {
  local target="${1:?用法: release.sh promote backend <merged-main-sha> [--same-version <reason>] [--wait] [--yes]}"
  local sha="${2:-}" live prod_old ver_new ver_old
  [[ "$target" == backend || "$target" == api ]] || err "promote 只支援 backend（得到 '${target}'）"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || err "請提供完整 40 字元 SHA（不收縮寫／branch 名）：'${sha}'"
  live="$(live_origin_main)"
  prod_old="$(remote_head_sha prod)" || exit $?
  [[ "$prod_old" =~ ^[0-9a-f]{40}$ ]] || err "查不到 live origin/prod（首次 seed 屬拓樸遷移，見 docs/sop/release.md）；fail-closed。"
  git -C "$ROOT" fetch -q origin main prod || err "git fetch origin main prod 失敗；fail-closed。"
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$live" 2>/dev/null \
    || err "${sha} 不是 live origin/main=${live} 的 ancestor（或本地無此 object）；只能 promote 已合併的 main commit。"
  [[ "$sha" != "$prod_old" ]] || err "origin/prod 已在 ${sha}；無事可做。"
  git -C "$ROOT" merge-base --is-ancestor "$prod_old" "$sha" \
    || err "origin/prod=${prod_old} 不是 ${sha} 的 ancestor；只允許 fast-forward（永不 force，reconciler 也拒絕 rewind）。回滾請走 forward-revert，見 docs/sop/release.md。"
  ver_new="$(promote_version_at "$sha")"; ver_old="$(promote_version_at "$prod_old")"
  if semver_gt "$ver_new" "$ver_old"; then :
  elif [[ "$ver_new" == "$ver_old" && -n "$PROMOTE_SAME_VERSION" ]]; then
    echo "  同版本 redeploy（${ver_new}）；理由：${PROMOTE_SAME_VERSION}"
  else
    err "backend 版本未提升：${sha} 為 ${ver_new}，origin/prod 為 ${ver_old}。先走 release backend 發 bump；redeploy 需 --same-version <reason>。"
  fi
  promote_assert_backend_quality "$sha"

  echo "promote backend ${sha}"
  echo "  origin/prod ${prod_old:0:12} → ${sha:0:12}（fast-forward；backend ${ver_old} → ${ver_new}；backend-quality 全綠）"
  if [[ $YES -ne 1 ]]; then
    echo "  dry-run：未推送。確認後加 --yes（可再加 --wait 等 felix reconciler 收斂）。"
    return 0
  fi
  acquire_release_lock
  # lease 綁定「檢查時看到的 prod_old」：check 與 push 之間若有人前進 prod，即使對 git 仍是合法 FF 也會被拒。
  # 注意：--force-with-lease=ref:expect 是 forced update，git 會略過 client 端 non-FF 拒絕。
  # 安全性來自：上方 ancestry guard 強制 fast-forward；lease 對 prod_old 做 compare-and-swap，使 push 原子。
  git -C "$ROOT" push --force-with-lease="refs/heads/prod:${prod_old}" origin "${sha}:refs/heads/prod" \
    || err "push origin ${sha}:refs/heads/prod 失敗（prod 可能在檢查後被前進；lease=${prod_old}）"
  [[ "$(remote_head_sha prod)" == "$sha" ]] \
    || err "push 後 origin/prod 不等於 ${sha}；請人工查證。"
  if [[ -n "$PROMOTE_SAME_VERSION" ]]; then  # 稽核：理由落地到本機 ledger（.cache 已 gitignore），push 輸出也印一次
    mkdir -p "$ROOT/.cache/release"
    printf '%s promote backend %s same-version %s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "$ver_new" "$PROMOTE_SAME_VERSION" \
      >>"$ROOT/.cache/release/promote.log"
    echo "  same-version audit：reason=${PROMOTE_SAME_VERSION}（已記 .cache/release/promote.log）"
  fi
  echo "✓ origin/prod = ${sha}（felix reconciler 約 90s 內接手 deploy + health/smoke gate，失敗自動回滾）"
  echo "  驗證："
  echo "    curl -s ${KG_PUBLIC_URL}/api/system/info   # version 應為 ${sha:0:7}"
  echo "    ./ops/devops_kg_safe.sh run \"tail -40 ~/Library/Logs/kg_reconcile.err.log\""
  echo "    ./ops/devops_kg_safe.sh run \"tail -5 ~/Library/Logs/kg_reconcile.out.log\""
  echo "    docs/sop/deploy.md §標準部署流程（health／deploy.log）；rollback 見 docs/sop/release.md §felix 生產切換"
  if [[ $PROMOTE_WAIT -eq 1 ]]; then
    local KG_RELEASE_WAIT_SECS="${KG_PROMOTE_WAIT_SECS:-600}" KG_RELEASE_POLL_SECS="${KG_PROMOTE_POLL_SECS:-15}"
    wait_for_rollout "$sha"
  fi
}

# ---- 全域 flag 解析 + dispatcher ----
# 整段包在 BASH_SOURCE guard 內（同 ops/kg_reconcile.sh 的慣例）：讓 ops/tests/test_release.sh
# 能 source 本檔取純函式而不觸發 dispatcher。刻意不重新縮排，保住 git blame。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# ---- 全域 flag 解析（subcommand 前後皆可） ----
SUB=""; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)      YES=1; shift ;;
    --new-version-after-ready)
      # 靜默忽略是最糟的下場：operator 以為自己還在背書，實際上那個字串已不影響任何判斷。
      err "--new-version-after-ready 已移除。它存在的理由是舊 ios/<x.y.z> tag 不代表上架，
   只能請 operator 背書；現在該 tag 由 ./ops/release.sh shipped ios 依 ASC 驗證後才產生，
   tag 存在本身就是上架證據，guard 直接檢查、不需要 attestation。
   同版號、新 build 的重送改走 ./ops/release.sh resubmit ios。" ;;
    --commit)
      [[ $# -ge 2 && -n "${2:-}" ]] || err "--commit 需要一個 commit-ish"
      SHIPPED_COMMIT="$2"; shift 2 ;;
    --wait)     PROMOTE_WAIT=1; shift ;;
    --same-version)
      [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || err "--same-version 需要一段理由文字"
      PROMOTE_SAME_VERSION="$2"; shift 2 ;;
    --pr)
      [[ $# -ge 2 && "${2:-}" =~ ^[0-9]+$ && "${2:-}" -gt 0 ]] || err "--pr 需要正整數 PR number"
      RELEASE_PR="$2"; shift 2 ;;
    --merged-source)
      [[ $# -ge 2 && "${2:-}" =~ ^[0-9a-f]{40}$ ]] || err "--merged-source 需要 40 字元 commit SHA"
      MERGED_SOURCE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         err "unknown option: $1" ;;
    *)          if [[ -z "$SUB" ]]; then SUB="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

case "${SUB:-}" in
  # ${ARGS[@]+"${ARGS[@]}"}：空陣列→零參數（讓 cmd 的 ${1:?usage} 正常觸發），非空→保留各元素引號；
  # 不用 "${ARGS[@]:-}"（空時會誤傳一個空字串參數）。
  status)    cmd_status ;;
  changelog) cmd_changelog ${ARGS[@]+"${ARGS[@]}"} ;;
  bump)      cmd_bump ${ARGS[@]+"${ARGS[@]}"} ;;
  bump-build) cmd_bump_build ${ARGS[@]+"${ARGS[@]}"} ;;
  tag)       cmd_tag ${ARGS[@]+"${ARGS[@]}"} ;;
  publish)   cmd_tag ${ARGS[@]+"${ARGS[@]}"} ;;   # 相容別名：publish → tag
  shipped)   cmd_shipped ${ARGS[@]+"${ARGS[@]}"} ;;
  resubmit)  cmd_resubmit ${ARGS[@]+"${ARGS[@]}"} ;;
  resume)    cmd_resume ${ARGS[@]+"${ARGS[@]}"} ;;
  finalize)  cmd_finalize ${ARGS[@]+"${ARGS[@]}"} ;;
  release)   cmd_release ${ARGS[@]+"${ARGS[@]}"} ;;
  promote)   cmd_promote ${ARGS[@]+"${ARGS[@]}"} ;;
  ""|help)   usage ;;
  *)         err "unknown subcommand: ${SUB}（release.sh help 看用法）" ;;
esac

fi
