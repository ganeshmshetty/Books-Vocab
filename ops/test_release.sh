#!/usr/bin/env bash
# test_release.sh — release.sh 結構與行為驗證（不打 git 遠端；對齊 test_asc.sh 慣例）
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
REL="$WORKSPACE/ops/release.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section(){ echo ""; echo "── $* ──"; }

# ── 1. Syntax ───────────────────────────────────────────────────────────────
section "Syntax"
[[ -f "$REL" ]] && ok "release.sh exists" || fail_t "release.sh missing"
bash -n "$REL"   && ok "release.sh syntax" || fail_t "release.sh syntax error"

# ── 2. 子命令 dispatch 齊全 ─────────────────────────────────────────────────
section "Subcommand dispatch"
for sub in status changelog bump bump-build tag publish release promote shipped resubmit finalize; do
  grep -qE "^[[:space:]]*$sub\)" "$REL" \
    && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
done

# ── 3. release 家族集中 ops/（primitives 已 git mv 進來，scripts/ 舊路徑消失） ─
section "Primitives consolidated into ops/"
[[ -f "$WORKSPACE/ops/release_bump.sh" ]] \
  && ok "ops/release_bump.sh exists"        || fail_t "ops/release_bump.sh missing"
[[ -f "$WORKSPACE/ops/release_changelog.sh" ]] \
  && ok "ops/release_changelog.sh exists"   || fail_t "ops/release_changelog.sh missing"
[[ ! -e "$WORKSPACE/scripts/bump-version.sh" ]] \
  && ok "old scripts/bump-version.sh gone"  || fail_t "scripts/bump-version.sh still present (move incomplete)"
[[ ! -e "$WORKSPACE/scripts/generate-changelog.sh" ]] \
  && ok "old scripts/generate-changelog.sh gone" || fail_t "scripts/generate-changelog.sh still present"

# ── 3b. non-ASC ops test runner exists and keeps help comment-only ───────────
section "Non-ASC ops test runner"
OPS_TEST="$WORKSPACE/ops/test_ops.sh"
[[ -x "$OPS_TEST" ]] \
  && ok "ops/test_ops.sh executable" || fail_t "ops/test_ops.sh missing or not executable"
ops_help="$(bash "$OPS_TEST" --help 2>&1)"
grep -qE 'set -euo pipefail|^ROOT=|^UV_BIN=' <<<"$ops_help" \
  && fail_t "test_ops help leaks shell code" \
  || ok "test_ops help is comment-only"
ops_list="$(bash "$OPS_TEST" --list 2>&1)"
grep -q '^release$' <<<"$ops_list" \
  && ok "test_ops lists release group" || fail_t "test_ops --list missing release"
grep -q '^podcast-ops$' <<<"$ops_list" \
  && ok "test_ops lists podcast-ops group" || fail_t "test_ops --list missing podcast-ops"

# ── 4. release.sh 僅在非 API transaction 路徑委派 bump primitive ─────────────
section "Primitive boundaries"
grep -q 'release_bump.sh' "$REL" \
  && ok "dry-run/iOS bump paths retain release_bump primitive" \
  || fail_t "release.sh lost release_bump primitive for non-transaction paths"
grep -q 'prepare_api_version_transaction' "$REL" \
  && grep -q 'commit_api_version_transaction' "$REL" \
  && ok "API --yes bump is owned by bounded three-file transaction" \
  || fail_t "release.sh missing API three-file transaction authority"
grep -q 'release_changelog.sh' "$REL" \
  && ok "changelog delegates to release_changelog.sh" || fail_t "release.sh not calling release_changelog.sh"

# ── 5. tag 寫入 gate：dry-run 預設，--yes 才 push（對外副作用明示） ───────────
section "Tag gate (dry-run by default)"
grep -q -- '--yes' "$REL" \
  && ok "has --yes confirm flag"            || fail_t "missing --yes flag"
grep -qE 'YES=(0|"")|YES=$' "$REL" \
  && ok "YES defaults to off (dry-run)"     || fail_t "YES not defaulting to dry-run"
tag_body="$(awk '/^cmd_tag\(\)/,/^}/' "$REL")"
# 真正的 push 標的＝`push origin`（script 用 git -C "$ROOT" push origin，dry-run 用中文「推送 origin」不撞）
grep -q 'push origin' <<<"$tag_body" \
  && ok "tag has real push origin"          || fail_t "tag missing push origin"
# 真正的 push/commit/tag 必須在 YES gate 之內
grep -qE 'if \[\[ \$YES -eq 1 \]\]|if \[ "\$YES"' <<<"$tag_body" \
  && ok "tag guards side-effects behind --yes" || fail_t "tag missing --yes guard"
# 負控（鎖不變量）：push origin 不可洩進 dry-run/else 分支 —— 否則無 --yes 也會推
grep -q 'push origin' <<<"$(awk '/else/,/fi/' <<<"$tag_body")" \
  && fail_t "push origin leaked into dry-run branch (would push without --yes)" \
  || ok "dry-run branch contains no push origin"

# ── 5b. detached HEAD 守衛（避免 push origin HEAD；review footgun 回歸） ──────
grep -q 'detached HEAD' <<<"$tag_body" \
  && ok "tag guards detached HEAD"          || fail_t "tag missing detached-HEAD guard (would push origin HEAD)"
grep -q 'backend/uv.lock' <<<"$tag_body" \
  && ok "api tag includes synchronized uv.lock" || fail_t "api tag would leave synchronized uv.lock uncommitted"

# ── 5c. release 統一入口 gate：dry-run 預設、須在 main、委派 deploy/upload ────
section "Release verb gate (unified backend/ios)"
rel_body="$(awk '/^cmd_release\(\)/,/^}/' "$REL")"
grep -q 'orchestrate deploy' "$REL" \
  && fail_t "release.sh references the nonexistent 'orchestrate deploy'; the only prod route is promote" \
  || ok "no dead 'orchestrate deploy' reference (prod advance = promote)"
grep -q 'ios_release.sh' <<<"$rel_body" \
  && ok "release ios delegates to ios_release.sh --upload" || fail_t "release missing ios_release delegation"
grep -qE 'branch.*== main|== main.*branch|"\$branch" == main' <<<"$rel_body" \
  && ok "release guards on-main"            || fail_t "release missing on-main guard"
# 負控：生產觸點（deploy/upload）不可洩進 dry-run 分支（--yes 前 return）
grep -qE 'push origin.*prod|--upload' <<<"$(awk '/YES -ne 1/,/return 0/' <<<"$rel_body")" \
  && fail_t "production touch leaked into release dry-run branch" \
  || ok "release dry-run branch contains no production touch"

# ── 6. 版號格式守衛（x.y.z） ────────────────────────────────────────────────
section "Version format guard"
grep -qE '\[0-9\]\+\\?\.\[0-9\]|[0-9]+\.[0-9]+\.[0-9]+' "$REL" \
  && ok "validates semver x.y.z"            || fail_t "no semver format guard"

# ── 6b. (retired) Bash set -u + non-ASCII boundary guard ───────────────────
# This check now has exactly one owner: `ops/tests/test_script_help.sh`. The copy
# that used to live here was strictly worse and disagreed with it in production:
#   * it matched `$VAR<non-ASCII>` anywhere, including inside `#` comments — bash
#     never expands those, so it flagged the comment in kg_reconcile.sh that
#     *documents* this very hazard (main was red on exactly that, 2026-08-06);
#   * it had no exemption mechanism, so there was no way to say "this is the
#     documentation of the rule" (`# fw-allow: <reason>` is the owner's);
#   * it had no positive control, so if `rg`'s pattern ever stopped matching it
#     would have gone quietly green forever — the owner asserts on a fixture
#     first and refuses to report a clean tree if it scanned < 10 files;
#   * its coverage was a hardcoded `-g '!...'` exclusion list; the owner walks
#     `git ls-files '*.sh'`, which is strictly broader (it covers devops.sh and
#     the ASC scripts this one excluded).
# Two implementations of one rule cannot stay in agreement, and the one without a
# positive control is the one you cannot trust when they disagree.

# ── 7. status / changelog 唯讀（不得碰遠端 / 不寫檔） ────────────────────────
section "Read-only commands stay read-only"
status_body="$(awk '/^cmd_status\(\)/,/^}/' "$REL")"
# 只看「被執行的」git 寫入，不看被印出來的字串：status 印 remediation 提示（例如
# 誤標 tag 的刪除指令）是它的職責，不是副作用。先剔除 echo/printf 行再掃。
status_exec_body() { grep -vE '^[[:space:]]*(echo|printf)\b' <<<"$status_body"; }
status_exec="$(status_exec_body)"
grep -qE 'git push|git commit|git tag ' <<<"$status_exec" \
  && fail_t "status has a write/remote op (must be read-only)" \
  || ok "status is read-only"
# 守衛本身不得被上面的剔除規則掏空：植入一個真正的寫入語句必須仍被抓到。
bare_write="$(printf '%s\n' '  git push origin main')"
guard_out="$(grep -vE '^[[:space:]]*(echo|printf)\b' <<<"$bare_write")"
grep -qE 'git push|git commit|git tag ' <<<"$guard_out" \
  && ok "read-only guard still catches a real write op" \
  || fail_t "read-only guard was defanged — a bare git push now slips through"

# ── 8. 不謊稱 CI 自動發版（無 tag-triggered workflow，驗證先於宣稱） ─────────
section "No false CI claim"
! grep -qE 'GitHub Actions 正在執行|CI 正在發版|自動建立 GitHub Release' "$REL" \
  && ok "no aspirational CI-runs claim"     || fail_t "claims CI auto-releases (no such workflow exists)"

# ── 9. --help 不洩漏 shell 程式碼（dogfood A-F6/C：usage sed 範圍越界回歸） ──
section "Help output stays comment-only"
help_out="$(bash "$REL" --help 2>&1)"
grep -qE 'set -euo pipefail|^ROOT=|^YES=' <<<"$help_out" \
  && fail_t "help leaks shell code (set/ROOT/YES bled into usage)" \
  || ok "help is comment-only (no shell code leak)"

# ── 10. status 漂移警示（dogfood A-F2/C：tag↔檔內版號不一致須警告） ──────────
section "Status drift warning"
grep -q '版號漂移' <<<"$status_body" \
  && ok "status warns on tag↔file version drift" || fail_t "status missing drift warning"

# ── 11. status 長清單截斷（dogfood A-F3：234 筆 commit 不該吐成 688 行牆） ────
section "Status truncates long commit list"
grep -q 'head -15' <<<"$status_body" \
  && ok "status caps commit list (head -15)" || fail_t "status dumps full commit wall (no truncation)"

# ── 12. release_bump.sh ios 的 sed 必須錨定，不得全域掃 ────────────────────
# 2026-08 起版號提升到 project-level build settings，六個 target-level 覆寫已刪除，所以
# 真實 pbxproj 裡這兩個 key 各只剩兩行、測試 bundle 靠繼承跟進。這個 fixture 因此**不再
# 是現況的縮影**，而是一個刻意保留的反例：檔內存在「不同值的同名 key」時，錨定的 sed
# 不得掃到它。這條守的是「日後有人把某個 target-level 覆寫加回來」的誤傷面。
# 注意它守不住的形狀：覆寫若加回**相同字面值**，錨定 sed 一樣會命中——那要靠 pbxproj
# 結構 lint（另有專用測試），不是這條。
section "bump ios sed stays anchored (never sweeps the file)"
BUMP="$WORKSPACE/ops/release_bump.sh"
# 結構：不得殘留無錨點的全域 sed（[^;]* 不綁當前值＝會掃中所有 target）
grep -q 'MARKETING_VERSION = \[\^;\]\*/MARKETING_VERSION' "$BUMP" \
  && fail_t "release_bump still has unanchored global MARKETING_VERSION sed" \
  || ok "no unanchored global MARKETING_VERSION sed"
# 行為：fixture pbxproj（app=9.9 在前、測試 bundle=1.2.0 在後），bump 後只有 app 變、測試 bundle 不動
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ios/BooksAndVocab.xcodeproj"
cat > "$TMP/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<'PBX'
/* app Debug */    MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
/* app Release */  MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
/* tests Debug */  MARKETING_VERSION = 1.2.0; CURRENT_PROJECT_VERSION = 1;
/* tests Release */MARKETING_VERSION = 1.2.0; CURRENT_PROJECT_VERSION = 1;
PBX
KG_ROOT="$TMP" bash "$BUMP" ios 9.9.1 --yes >/dev/null 2>&1 || fail_t "bump ios fixture run failed"
got_app="$(grep -c 'MARKETING_VERSION = 9.9.1;' "$TMP/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)"
got_test="$(grep -c 'MARKETING_VERSION = 1.2.0;' "$TMP/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)"
got_build="$(grep -c 'CURRENT_PROJECT_VERSION = 8;' "$TMP/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)"
[[ "$got_app" -eq 2 ]]  && ok "anchored MARKETING_VERSION → 9.9.1 (2 處)" || fail_t "app bump wrong count: $got_app"
[[ "$got_test" -eq 2 ]] && ok "differently-valued MARKETING_VERSION untouched (still 1.2.0 ×2)" || fail_t "sed swept a differently-valued line: 1.2.0 count=$got_test"
[[ "$got_build" -eq 2 ]] && ok "anchored CURRENT_PROJECT_VERSION → 8 (2 處)" || fail_t "app build bump wrong count: $got_build"

# ── 12b. pbxproj 版號必須只存在於 project-level build configs ─────────────
section "pbxproj version settings are project-level only"
VERSION_LINT="$WORKSPACE/ops/pbxproj_version_lint.py"
PBX="$WORKSPACE/ios/BooksAndVocab.xcodeproj/project.pbxproj"
[[ -x "$VERSION_LINT" ]] \
  && ok "pbxproj version lint exists and is executable" \
  || fail_t "pbxproj version lint missing or not executable"
[[ -f "$PBX" ]] \
  && ok "real pbxproj exists" \
  || fail_t "real pbxproj missing"
if [[ -x "$VERSION_LINT" && -f "$PBX" ]]; then
  "$VERSION_LINT" "$PBX" >/dev/null 2>&1 \
    && ok "real pbxproj passes structural version lint" \
    || fail_t "real pbxproj failed structural version lint"

  VERSION_LINT_TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "$TMP2" "$VERSION_LINT_TMP"' EXIT
  cp "$PBX" "$VERSION_LINT_TMP/duplicate.pbxproj"
  awk '
    !inserted && /MARKETING_VERSION = / {
      print
      print "\t\t\t\tMARKETING_VERSION = 2.0.0;"
      inserted = 1
      next
    }
    { print }
  ' "$PBX" > "$VERSION_LINT_TMP/duplicate.pbxproj.tmp"
  mv "$VERSION_LINT_TMP/duplicate.pbxproj.tmp" "$VERSION_LINT_TMP/duplicate.pbxproj"
  if "$VERSION_LINT" "$VERSION_LINT_TMP/duplicate.pbxproj" >/dev/null 2>&1; then
    fail_t "duplicate MARKETING_VERSION was accepted"
  else
    ok "duplicate MARKETING_VERSION is rejected"
  fi

  awk '
    !removed && /MARKETING_VERSION = / {
      removed = 1
      next
    }
    { print }
    !inserted && /PRODUCT_BUNDLE_IDENTIFIER = / {
      print "\t\t\t\tMARKETING_VERSION = 2.0.0;"
      inserted = 1
    }
  ' "$PBX" > "$VERSION_LINT_TMP/target-level.pbxproj"
  target_marketing_count="$(grep -c 'MARKETING_VERSION = ' "$VERSION_LINT_TMP/target-level.pbxproj" || true)"
  if [[ "$target_marketing_count" -eq 2 ]] &&
     "$VERSION_LINT" "$VERSION_LINT_TMP/target-level.pbxproj" >/dev/null 2>&1; then
    fail_t "same-count target-level MARKETING_VERSION was accepted"
  elif [[ "$target_marketing_count" -eq 2 ]]; then
    ok "same-count target-level MARKETING_VERSION is rejected"
  else
    fail_t "structural fixture changed MARKETING_VERSION count: $target_marketing_count"
  fi
fi

# ── 13. bump 寫入 gate：dry-run 預設、--yes 才寫（對齊 publish / asc.sh set 慣例） ──
section "Bump gate (dry-run by default)"
TMP2="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2"' EXIT
mkdir -p "$TMP2/ios/BooksAndVocab.xcodeproj" "$TMP2/backend/src/kg"
cat > "$TMP2/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<'PBX'
/* app Debug */    MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
/* app Release */  MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
PBX
cat > "$TMP2/backend/pyproject.toml" <<'TOML'
[project]
version = "0.1.0"
TOML
cat > "$TMP2/backend/src/kg/api.py" <<'PY'
app = FastAPI(title="kg", version="0.1.0")
PY
cat > "$TMP2/backend/uv.lock" <<'LOCK'
version = 1

[[package]]
name = "kg"
version = "0.1.0"
source = { editable = "." }

[[package]]
name = "kg"
version = "8.8.8"
source = { registry = "https://example.invalid/simple" }

[[package]]
name = "unrelated"
version = "9.9.9"
source = { registry = "https://example.invalid/simple" }
LOCK
cp "$TMP2/backend/uv.lock" "$TMP2/backend/uv.lock.before"
chmod 0644 "$TMP2/backend/uv.lock"
lock_mode_before="$(stat -c '%a' "$TMP2/backend/uv.lock" 2>/dev/null || stat -f '%Lp' "$TMP2/backend/uv.lock")"

# 13a. dry-run（無 --yes）：exit 0、不改任何檔
dry_out="$(KG_ROOT="$TMP2" bash "$BUMP" ios 9.9.1 2>&1)" \
  && ok "bump ios dry-run exits 0" || fail_t "bump ios dry-run exited non-zero"
grep -q 'MARKETING_VERSION = 9.9;' "$TMP2/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ! grep -q '9\.9\.1' "$TMP2/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ok "dry-run leaves pbxproj untouched" || fail_t "dry-run modified pbxproj (must not write without --yes)"
# 13b. dry-run 輸出：舊→新 + 指引 --yes
grep -q '9.9 → 9.9.1' <<<"$dry_out" \
  && ok "dry-run prints old→new version" || fail_t "dry-run missing old→new preview: $dry_out"
grep -q -- '--yes' <<<"$dry_out" \
  && ok "dry-run points to --yes" || fail_t "dry-run does not mention --yes"
# 13c. api dry-run：兩檔皆不動、輸出含舊→新
api_dry="$(KG_ROOT="$TMP2" bash "$BUMP" api 0.2.0 2>&1)" \
  && ok "bump api dry-run exits 0" || fail_t "bump api dry-run exited non-zero"
grep -q 'version = "0.1.0"' "$TMP2/backend/pyproject.toml" \
  && grep -q 'version="0.1.0"' "$TMP2/backend/src/kg/api.py" \
  && ok "api dry-run leaves pyproject+api.py untouched" || fail_t "api dry-run modified version files"
grep -q '0.1.0 → 0.2.0' <<<"$api_dry" \
  && ok "api dry-run prints old→new" || fail_t "api dry-run missing old→new preview: $api_dry"
# 13d0. wrapper 無 --yes：dry-run 不寫檔（wrapper 路徑，非只測 primitive）
KG_ROOT="$TMP2" bash "$REL" bump api 0.2.0 >/dev/null 2>&1 \
  && ok "release.sh bump（無 --yes）exits 0" || fail_t "release.sh bump dry-run exited non-zero"
grep -q 'version = "0.1.0"' "$TMP2/backend/pyproject.toml" \
  && ok "release.sh bump（無 --yes）不寫檔" || fail_t "release.sh bump without --yes wrote files"
cmp -s "$TMP2/backend/uv.lock.before" "$TMP2/backend/uv.lock" \
  && ok "release.sh bump api dry-run leaves uv.lock untouched" || fail_t "release.sh bump api dry-run modified uv.lock"
# 13d1. 多餘 positional 拒絕（不得靜默忽略）
KG_ROOT="$TMP2" bash "$BUMP" ios 9.9.1 extra >/dev/null 2>&1 \
  && fail_t "extra positional silently accepted" || ok "bump 拒絕多餘 positional"
# 13d. --yes 經 release.sh wrapper 傳遞到 primitive（全域 --yes flag 生效）
KG_ROOT="$TMP2" bash "$REL" bump api 0.2.0 --yes >/dev/null 2>&1 \
  || fail_t "release.sh bump api --yes failed"
grep -q 'version = "0.2.0"' "$TMP2/backend/pyproject.toml" \
  && grep -q 'version="0.2.0"' "$TMP2/backend/src/kg/api.py" \
  && ok "release.sh bump --yes writes both api version files" || fail_t "release.sh bump --yes did not write api files"
editable_kg_version="$(awk 'BEGIN { RS="" } /name = "kg"/ && /source = \{ editable = "\." \}/ { if (match($0, /version = "[^"]+"/)) print substr($0, RSTART + 11, RLENGTH - 12) }' "$TMP2/backend/uv.lock")"
registry_kg_version="$(awk 'BEGIN { RS="" } /name = "kg"/ && /source = \{ registry = / { if (match($0, /version = "[^"]+"/)) print substr($0, RSTART + 11, RLENGTH - 12) }' "$TMP2/backend/uv.lock")"
unrelated_version="$(awk 'BEGIN { RS="" } /name = "unrelated"/ { if (match($0, /version = "[^"]+"/)) print substr($0, RSTART + 11, RLENGTH - 12) }' "$TMP2/backend/uv.lock")"
[[ "$editable_kg_version" == "0.2.0" \
   && "$registry_kg_version" == "8.8.8" \
   && "$unrelated_version" == "9.9.9" ]] \
  && ok "release.sh bump api updates only editable kg entry in uv.lock" \
  || fail_t "uv.lock scope wrong: editable=$editable_kg_version registry=$registry_kg_version unrelated=$unrelated_version"
lock_mode_after="$(stat -c '%a' "$TMP2/backend/uv.lock" 2>/dev/null || stat -f '%Lp' "$TMP2/backend/uv.lock")"
[[ "$lock_mode_after" == "$lock_mode_before" ]] \
  && ok "release.sh bump api preserves uv.lock mode" \
  || fail_t "uv.lock mode changed: before=$lock_mode_before after=$lock_mode_after"

# 13e. malformed lock preflight must be all-or-nothing: neither zero nor
# duplicate editable kg entries may leave pyproject/api.py partially bumped.
for lock_shape in zero duplicate; do
  fx="$TMP2/failure-$lock_shape"
  mkdir -p "$fx/backend/src/kg"
  cat > "$fx/backend/pyproject.toml" <<'TOML'
[project]
version = "0.1.0"
TOML
  cat > "$fx/backend/src/kg/api.py" <<'PY'
app = FastAPI(title="kg", version="0.1.0")
PY
  cat > "$fx/backend/uv.lock" <<'LOCK'
version = 1

[[package]]
name = "unrelated"
version = "9.9.9"
source = { registry = "https://example.invalid/simple" }
LOCK
  if [[ "$lock_shape" == duplicate ]]; then
    cat >> "$fx/backend/uv.lock" <<'LOCK'

[[package]]
name = "kg"
version = "0.1.0"
source = { editable = "." }

[[package]]
name = "kg"
version = "0.1.0"
source = { editable = "." }
LOCK
  fi
  cp "$fx/backend/pyproject.toml" "$fx/backend/pyproject.toml.before"
  cp "$fx/backend/src/kg/api.py" "$fx/backend/src/kg/api.py.before"
  cp "$fx/backend/uv.lock" "$fx/backend/uv.lock.before"
  malformed_rc=0
  KG_ROOT="$fx" bash "$REL" bump api 0.2.0 --yes >/dev/null 2>&1 || malformed_rc=$?
  [[ "$malformed_rc" -ne 0 \
     && "$(cmp -s "$fx/backend/pyproject.toml.before" "$fx/backend/pyproject.toml"; echo $?)" -eq 0 \
     && "$(cmp -s "$fx/backend/src/kg/api.py.before" "$fx/backend/src/kg/api.py"; echo $?)" -eq 0 \
     && "$(cmp -s "$fx/backend/uv.lock.before" "$fx/backend/uv.lock"; echo $?)" -eq 0 \
     && -z "$(find "$fx/backend" -name 'uv.lock.tmp.*' -print -quit)" ]] \
    && ok "malformed uv.lock ($lock_shape editable entries) rejects before any version mutation" \
    || fail_t "malformed uv.lock ($lock_shape) left a partial bump or temp file"
done

# 13f. A readonly destination must fail before any of the three version files
# changes. The old order mutated pyproject/api.py first, then failed while
# copying uv.lock, leaving a partial release bump behind.
readonly_fx="$TMP2/failure-readonly"
mkdir -p "$readonly_fx/backend/src/kg"
cat > "$readonly_fx/backend/pyproject.toml" <<'TOML'
[project]
version = "0.1.0"
TOML
cat > "$readonly_fx/backend/src/kg/api.py" <<'PY'
app = FastAPI(title="kg", version="0.1.0")
PY
cat > "$readonly_fx/backend/uv.lock" <<'LOCK'
version = 1

[[package]]
name = "kg"
version = "0.1.0"
source = { editable = "." }
LOCK
for version_file in \
  "$readonly_fx/backend/pyproject.toml" \
  "$readonly_fx/backend/src/kg/api.py" \
  "$readonly_fx/backend/uv.lock"; do
  cp "$version_file" "$version_file.before"
done
chmod 0444 "$readonly_fx/backend/uv.lock"
readonly_rc=0
KG_ROOT="$readonly_fx" bash "$REL" bump api 0.2.0 --yes >/dev/null 2>&1 || readonly_rc=$?
[[ "$readonly_rc" -ne 0 \
   && "$(cmp -s "$readonly_fx/backend/pyproject.toml.before" "$readonly_fx/backend/pyproject.toml"; echo $?)" -eq 0 \
   && "$(cmp -s "$readonly_fx/backend/src/kg/api.py.before" "$readonly_fx/backend/src/kg/api.py"; echo $?)" -eq 0 \
   && "$(cmp -s "$readonly_fx/backend/uv.lock.before" "$readonly_fx/backend/uv.lock"; echo $?)" -eq 0 \
   && -z "$(find "$readonly_fx/backend" -name '*.tmp.*' -print -quit)" ]] \
  && ok "readonly API version destination rejects without a partial bump" \
  || fail_t "readonly API version destination left a partial bump or temp file"
chmod 0644 "$readonly_fx/backend/uv.lock"

# 13g. Exercise the rollback path itself: fail the second candidate install
# once through PATH, after slot 1 has already been atomically replaced.
rollback_fx="$TMP2/failure-second-rename"
mkdir -p "$rollback_fx/backend/src/kg" "$rollback_fx/fakebin"
cat > "$rollback_fx/backend/pyproject.toml" <<'TOML'
[project]
version = "0.1.0"
TOML
cat > "$rollback_fx/backend/src/kg/api.py" <<'PY'
app = FastAPI(title="kg", version="0.1.0")
PY
cat > "$rollback_fx/backend/uv.lock" <<'LOCK'
version = 1

[[package]]
name = "kg"
version = "0.1.0"
source = { editable = "." }
LOCK
for version_file in \
  "$rollback_fx/backend/pyproject.toml" \
  "$rollback_fx/backend/src/kg/api.py" \
  "$rollback_fx/backend/uv.lock"; do
  cp "$version_file" "$version_file.before"
done
cat > "$rollback_fx/fakebin/mv" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "${2:-}" == *.tmp.* ]]; then
  count=0
  [[ ! -f "$KG_FAKE_MV_STATE" ]] || count="$(<"$KG_FAKE_MV_STATE")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$KG_FAKE_MV_STATE"
  [[ "$count" -ne 2 ]] || exit 73
fi
exec /bin/mv "$@"
SH
chmod +x "$rollback_fx/fakebin/mv"
rollback_rc=0
rollback_out="$(PATH="$rollback_fx/fakebin:$PATH" \
  KG_FAKE_MV_STATE="$rollback_fx/mv-count" \
  KG_ROOT="$rollback_fx" \
  bash "$REL" bump api 0.2.0 --yes 2>&1)" || rollback_rc=$?
rollback_residue="$(find "$rollback_fx/backend" \( -name '*.tmp.*' -o -name '*.bak.*' \) -print -quit)"
rollback_count="missing"
[[ ! -f "$rollback_fx/mv-count" ]] || rollback_count="$(<"$rollback_fx/mv-count")"
rollback_py_cmp="$(cmp -s "$rollback_fx/backend/pyproject.toml.before" "$rollback_fx/backend/pyproject.toml"; echo $?)"
rollback_api_cmp="$(cmp -s "$rollback_fx/backend/src/kg/api.py.before" "$rollback_fx/backend/src/kg/api.py"; echo $?)"
rollback_lock_cmp="$(cmp -s "$rollback_fx/backend/uv.lock.before" "$rollback_fx/backend/uv.lock"; echo $?)"
[[ "$rollback_rc" -ne 0 \
   && "$rollback_count" -eq 2 \
   && "$rollback_py_cmp" -eq 0 \
   && "$rollback_api_cmp" -eq 0 \
   && "$rollback_lock_cmp" -eq 0 \
   && -z "$rollback_residue" ]] \
  && ok "second rename failure rolls back all three API version files" \
  || fail_t "second rename rollback failed: rc=$rollback_rc mv_count=$rollback_count cmp=$rollback_py_cmp/$rollback_api_cmp/$rollback_lock_cmp residue=${rollback_residue:-none} out=$rollback_out"

# 13h. A backup copy failure happens after mktemp has created the .bak path.
# The failed slot must already belong to transaction cleanup.
backup_fx="$TMP2/failure-backup-copy"
mkdir -p "$backup_fx/backend/src/kg" "$backup_fx/fakebin"
cp "$rollback_fx/backend/pyproject.toml.before" "$backup_fx/backend/pyproject.toml"
cp "$rollback_fx/backend/src/kg/api.py.before" "$backup_fx/backend/src/kg/api.py"
cp "$rollback_fx/backend/uv.lock.before" "$backup_fx/backend/uv.lock"
for version_file in \
  "$backup_fx/backend/pyproject.toml" \
  "$backup_fx/backend/src/kg/api.py" \
  "$backup_fx/backend/uv.lock"; do
  cp "$version_file" "$version_file.before"
done
cat > "$backup_fx/fakebin/cp" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "${3:-}" != *.bak.* ]] || exit 74
exec /bin/cp "$@"
SH
chmod +x "$backup_fx/fakebin/cp"
backup_rc=0
backup_out="$(PATH="$backup_fx/fakebin:$PATH" \
  KG_ROOT="$backup_fx" \
  bash "$REL" bump api 0.2.0 --yes 2>&1)" || backup_rc=$?
backup_residue="$(find "$backup_fx/backend" \( -name '*.tmp.*' -o -name '*.bak.*' \) -print -quit)"
[[ "$backup_rc" -ne 0 \
   && "$(cmp -s "$backup_fx/backend/pyproject.toml.before" "$backup_fx/backend/pyproject.toml"; echo $?)" -eq 0 \
   && "$(cmp -s "$backup_fx/backend/src/kg/api.py.before" "$backup_fx/backend/src/kg/api.py"; echo $?)" -eq 0 \
   && "$(cmp -s "$backup_fx/backend/uv.lock.before" "$backup_fx/backend/uv.lock"; echo $?)" -eq 0 \
   && -z "$backup_residue" ]] \
  && ok "backup copy failure leaves no API mutation or transaction residue" \
  || fail_t "backup copy failure cleanup failed: rc=$backup_rc residue=${backup_residue:-none} out=$backup_out"

# 13i. API version transactions can run inside release's shared lock. The
# transaction EXIT trap must compose with, not replace, the outer lock cleanup.
outer_lock_fx="$TMP2/outer-release-lock"
mkdir -p "$outer_lock_fx/ops/lib" "$outer_lock_fx/backend/src/kg"
cp "$REL" "$outer_lock_fx/ops/release.sh"
cp "$WORKSPACE/ops/lib/release_tags.sh" "$outer_lock_fx/ops/lib/release_tags.sh"
cp "$rollback_fx/backend/pyproject.toml.before" "$outer_lock_fx/backend/pyproject.toml"
cp "$rollback_fx/backend/src/kg/api.py.before" "$outer_lock_fx/backend/src/kg/api.py"
cp "$rollback_fx/backend/uv.lock.before" "$outer_lock_fx/backend/uv.lock"
git init -q -b main "$outer_lock_fx"
outer_lock_rc=0
outer_lock_out="$(KG_ROOT="$outer_lock_fx" bash -c '
  source "$1"
  YES=1
  acquire_release_lock
  prepare_api_version_transaction 0.2.0
  commit_api_version_transaction
  [[ -n "$RELEASE_LOCK_DIR" ]]
' bash "$outer_lock_fx/ops/release.sh" 2>&1)" || outer_lock_rc=$?
[[ "$outer_lock_rc" -eq 0 && ! -d "$outer_lock_fx/.git/kg-release.lock" \
   && "$(grep -c 'version = "0.2.0"' "$outer_lock_fx/backend/pyproject.toml")" -eq 1 ]] \
  && ok "API transaction preserves outer release lock cleanup on success" \
  || fail_t "API transaction success left outer lock: rc=$outer_lock_rc out=$outer_lock_out"

outer_fail_fx="$TMP2/outer-release-lock-failure"
mkdir -p "$outer_fail_fx/ops/lib" "$outer_fail_fx/backend/src/kg" "$outer_fail_fx/fakebin"
cp "$REL" "$outer_fail_fx/ops/release.sh"
cp "$WORKSPACE/ops/lib/release_tags.sh" "$outer_fail_fx/ops/lib/release_tags.sh"
cp "$rollback_fx/backend/pyproject.toml.before" "$outer_fail_fx/backend/pyproject.toml"
cp "$rollback_fx/backend/src/kg/api.py.before" "$outer_fail_fx/backend/src/kg/api.py"
cp "$rollback_fx/backend/uv.lock.before" "$outer_fail_fx/backend/uv.lock"
cp "$rollback_fx/fakebin/mv" "$outer_fail_fx/fakebin/mv"
git init -q -b main "$outer_fail_fx"
outer_fail_rc=0
outer_fail_out="$(PATH="$outer_fail_fx/fakebin:$PATH" KG_FAKE_MV_STATE="$outer_fail_fx/mv-count" KG_ROOT="$outer_fail_fx" bash -c '
  source "$1"
  YES=1
  acquire_release_lock
  prepare_api_version_transaction 0.2.0
  commit_api_version_transaction
' bash "$outer_fail_fx/ops/release.sh" 2>&1)" || outer_fail_rc=$?
[[ "$outer_fail_rc" -ne 0 && ! -d "$outer_fail_fx/.git/kg-release.lock" \
   && "$(cmp -s "$outer_fail_fx/backend/pyproject.toml" "$rollback_fx/backend/pyproject.toml.before"; echo $?)" -eq 0 \
   && "$(cmp -s "$outer_fail_fx/backend/src/kg/api.py" "$rollback_fx/backend/src/kg/api.py.before"; echo $?)" -eq 0 \
   && "$(cmp -s "$outer_fail_fx/backend/uv.lock" "$rollback_fx/backend/uv.lock.before"; echo $?)" -eq 0 ]] \
  && ok "API transaction preserves outer release lock cleanup on rollback" \
  || fail_t "API transaction rollback left outer lock or mutation: rc=$outer_fail_rc out=$outer_fail_out"

KG_ROOT="$TMP2" bash "$REL" bump ios 9.9.1 --yes >/dev/null 2>&1 \
  || fail_t "release.sh bump ios --yes failed"
grep -q 'MARKETING_VERSION = 9.9.1;' "$TMP2/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ok "release.sh bump --yes writes pbxproj" || fail_t "release.sh bump ios --yes did not write pbxproj"

# ── 14. bump-build：同 MARKETING_VERSION 重送、只 bump CURRENT_PROJECT_VERSION ──
section "Bump-build gate (build number only; App Review resubmit)"
TMP3="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2" "$TMP3"' EXIT
mkdir -p "$TMP3/ios/BooksAndVocab.xcodeproj"
cat > "$TMP3/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<'PBX'
/* app Debug */    MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
/* app Release */  MARKETING_VERSION = 9.9; CURRENT_PROJECT_VERSION = 7;
/* tests Debug */  MARKETING_VERSION = 1.2.0; CURRENT_PROJECT_VERSION = 1;
/* tests Release */MARKETING_VERSION = 1.2.0; CURRENT_PROJECT_VERSION = 1;
PBX
# 14a. dry-run（無 --yes）：exit 0、印舊→新 build、不寫檔
bb_dry="$(KG_ROOT="$TMP3" bash "$REL" bump-build ios 2>&1)" \
  && ok "bump-build ios dry-run exits 0" || fail_t "bump-build ios dry-run exited non-zero: $bb_dry"
grep -q '7 → 8' <<<"$bb_dry" \
  && ok "dry-run prints old→new build" || fail_t "dry-run missing old→new build preview: $bb_dry"
grep -q -- '--yes' <<<"$bb_dry" \
  && ok "dry-run points to --yes" || fail_t "dry-run does not mention --yes"
grep -q 'CURRENT_PROJECT_VERSION = 7;' "$TMP3/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ! grep -q 'CURRENT_PROJECT_VERSION = 8;' "$TMP3/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ok "dry-run leaves pbxproj untouched" || fail_t "bump-build dry-run modified pbxproj"
# 14b. --yes 經 wrapper：只動 app CURRENT_PROJECT_VERSION，MARKETING_VERSION 與測試 bundle 不動
KG_ROOT="$TMP3" bash "$REL" bump-build ios --yes >/dev/null 2>&1 \
  || fail_t "release.sh bump-build ios --yes failed"
bb_pbx="$TMP3/ios/BooksAndVocab.xcodeproj/project.pbxproj"
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 8;' "$bb_pbx" || true)" -eq 2 ]] \
  && ok "anchored CURRENT_PROJECT_VERSION → 8 (2 處)" || fail_t "app build bump wrong count"
[[ "$(grep -c 'MARKETING_VERSION = 9.9;' "$bb_pbx" || true)" -eq 2 ]] \
  && ok "MARKETING_VERSION 不動 (still 9.9 ×2)" || fail_t "MARKETING_VERSION was touched by bump-build"
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 1;' "$bb_pbx" || true)" -eq 2 ]] \
  && ok "differently-valued CURRENT_PROJECT_VERSION untouched (still 1 ×2)" || fail_t "sed swept a differently-valued line"
# 14c. api 拒絕（api 無 build number 概念），錯誤訊息給可行動指引
bb_api="$(KG_ROOT="$TMP3" bash "$REL" bump-build api 2>&1)" \
  && fail_t "bump-build api should be rejected" \
  || { grep -q 'bump api' <<<"$bb_api" \
         && ok "bump-build api 拒絕且指向 bump api" || fail_t "bump-build api error not actionable: $bb_api"; }
# 14d. 多餘 positional 拒絕（不得靜默忽略）
KG_ROOT="$TMP3" bash "$REL" bump-build ios 9.9.1 >/dev/null 2>&1 \
  && fail_t "bump-build extra positional silently accepted" || ok "bump-build 拒絕多餘 positional"
# 14e. primitive 直呼也拒絕 api build-only
KG_ROOT="$TMP3" bash "$BUMP" api --build-only >/dev/null 2>&1 \
  && fail_t "release_bump --build-only api should be rejected" || ok "primitive 拒絕 api --build-only"

# ── 15. iOS 新 marketing version guard + false-tag transaction guard ────────
# `--new-version-after-ready` 存在的唯一理由，是舊 ios/<x.y.z> tag 不代表「上架」，
# 所以只能請 operator 用 typed attestation 背書。新語意下該 tag 由 `shipped ios` 依 ASC
# 驗證後才物化，**它存在本身就是上架證據**，guard 因此可以變成真檢查。
section "iOS new-version guard (verified, not attested) and false-tag guard"
TMP4="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$TMP4"' EXIT

make_ios_release_fixture() {
  local fixture="$1" remote="$2"
  mkdir -p "$fixture/ops/lib" "$fixture/ios/BooksAndVocab.xcodeproj"
  cp "$REL" "$BUMP" "$fixture/ops/"
  # release.sh source 它；漏了會在 fixture 裡變成「找不到 release_last_tag」而非測到行為。
  cp "$WORKSPACE/ops/lib/release_tags.sh" "$fixture/ops/lib/"
  cat > "$fixture/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<'PBX'
/* app Debug */    MARKETING_VERSION = 2.0.0; CURRENT_PROJECT_VERSION = 5;
/* app Release */  MARKETING_VERSION = 2.0.0; CURRENT_PROJECT_VERSION = 5;
PBX
  cat > "$fixture/ops/ios_release.sh" <<'STUB'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
  touch "$root/upload.called"
  count=0
  [[ -f "$root/upload.count" ]] && count="$(<"$root/upload.count")"
  printf '%s\n' "$((count + 1))" > "$root/upload.count"
  if [[ -n "${STUB_UPLOAD_SLEEP_SECS:-}" ]]; then
    sleep "$STUB_UPLOAD_SLEEP_SECS"
  fi
  if [[ -n "${STUB_REMOTE_TAG:-}" ]]; then
    git -C "$root" push -q origin "HEAD^:refs/tags/$STUB_REMOTE_TAG"
  fi
echo "stub upload invoked" >&2
exit "${STUB_UPLOAD_EXIT:-0}"
STUB
  cat > "$fixture/ops/asc.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == build ]]; then
  [[ "${ASC_EXACT_BUILD_EXIT:-0}" == 0 ]] || exit "$ASC_EXACT_BUILD_EXIT"
  printf '{"schema":"kg.asc.build.v1","id":"%s-%s","version":"%s","build":"%s","platform":"IOS","processingState":"%s"}\n' \
    "${ASC_EXACT_BUILD_ID_PREFIX:-build}" "${2:-unknown}" "${2:-unknown}" "${3:-unknown}" "${ASC_EXACT_BUILD_STATE:-VALID}"
  exit 0
fi
[[ "${1:-}" == builds ]] || exit 64
if [[ "${ASC_BUILDS_EXIT:-0}" != 0 ]]; then
  exit "$ASC_BUILDS_EXIT"
fi
echo "TestFlight 最新 build number: ${ASC_LATEST_BUILD:-5}"
STUB
  printf 'upload.called\nupload.count\n' > "$fixture/.gitignore"
  chmod +x "$fixture/ops/ios_release.sh" "$fixture/ops/release_bump.sh" "$fixture/ops/asc.sh"
  git init -q -b main "$fixture"
  git -C "$fixture" config user.name "Release Test"
  git -C "$fixture" config user.email "release-test@example.invalid"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm "fixture: ios 2.0.0"
  git -C "$fixture" tag ios/2.0.0
  git init -q --bare "$remote"
  git -C "$fixture" remote add origin "$remote"
  git -C "$fixture" push -q origin main ios/2.0.0
  # Release/resubmit/finalize behavior fixtures must model the supported
  # dedicated owner lane. Tests that need protected main explicitly checkout
  # main; the fixture default must never make main the release execution lane.
  git -C "$fixture" checkout -q -b fixture-release-lane
}

# 15a. 被移除的 flag 必須硬報錯並指路。靜默忽略最糟：operator 以為自己仍在背書，
#      實際上那個字串不再影響任何判斷。
fx_a="$TMP4/removed-flag"; remote_a="$TMP4/removed-flag.git"
make_ios_release_fixture "$fx_a" "$remote_a"
head_a="$(git -C "$fx_a" rev-parse HEAD)"
noatt_rc=0
noatt_out="$(bash "$fx_a/ops/release.sh" release ios 2.0.1 --new-version-after-ready 2.0.0 --yes 2>&1)" || noatt_rc=$?
[[ "$noatt_rc" -ne 0 ]] \
  && ok "removed --new-version-after-ready hard-errors instead of being ignored" \
  || fail_t "removed --new-version-after-ready was silently accepted"
grep -q 'shipped ios' <<<"$noatt_out" \
  && ok "removed-flag error points at the verb that replaced it" \
  || fail_t "removed-flag error does not name the shipped verb: $noatt_out"
[[ "$(git -C "$fx_a" rev-parse HEAD)" == "$head_a" ]] \
  && grep -q 'MARKETING_VERSION = 2.0.0;' "$fx_a/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && [[ -z "$(git -C "$fx_a" tag -l 'ios/2.0.1*')" ]] \
  && [[ -z "$(git --git-dir="$remote_a" tag -l 'ios/2.0.1*')" ]] \
  && [[ ! -e "$fx_a/upload.called" ]] \
  && ok "removed-flag rejection is pre-mutation (pbx/commit/tag/upload untouched)" \
  || fail_t "removed-flag rejection happened after a mutation"

# 15b. 完全沒有上架 tag 時不得猜。有 build tag 也不算數——那只代表出過 archive。
fx_b="$TMP4/no-shipped-tag"; remote_b="$TMP4/no-shipped-tag.git"
make_ios_release_fixture "$fx_b" "$remote_b"
git -C "$fx_b" tag -d ios/2.0.0 >/dev/null
git -C "$fx_b" tag "ios/2.0.0+5"
mismatch_rc=0
mismatch_out="$(bash "$fx_b/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || mismatch_rc=$?
[[ "$mismatch_rc" -ne 0 ]] \
  && grep -q 'shipped ios' <<<"$mismatch_out" \
  && ok "no shipped tag: refuses and points at the shipped verb instead of guessing" \
  || fail_t "missing shipped tag was not actionably rejected: $mismatch_out"
[[ ! -e "$fx_b/upload.called" ]] \
  && ok "no-shipped-tag refusal is pre-upload" || fail_t "uploaded before the shipped-tag check"

# 15c. candidate 建立與恢復邊界：release 本身不 upload，candidate 必須保留
#      在 dedicated lane，並把外部副作用留給 exact merged resume。
fx_c="$TMP4/upload-failure"; remote_c="$TMP4/upload-failure.git"
make_ios_release_fixture "$fx_c" "$remote_c"
head_c="$(git -C "$fx_c" rev-parse HEAD)"
upload_rc=0
upload_out="$(STUB_UPLOAD_EXIT=23 bash "$fx_c/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || upload_rc=$?
[[ "$upload_rc" -eq 0 && ! -e "$fx_c/upload.called" ]] \
  && ok "release candidate does not upload before PR/queue handback" \
  || fail_t "release candidate unexpectedly uploaded: $upload_out"
candidate_c="$(git -C "$fx_c" rev-parse HEAD)"
[[ "$candidate_c" != "$head_c" \
   && "$(git -C "$fx_c" log -1 --format=%s)" == "ops: prepare ios 2.0.1 build 6" \
   && -z "$(git -C "$fx_c" tag -l 'ios/2.0.1*')" \
   && -z "$(git --git-dir="$remote_c" tag -l 'ios/2.0.1*')" \
   && "$(git --git-dir="$remote_c" rev-parse refs/heads/main)" == "$head_c" ]] \
   && ok "candidate preserves provenance without changing protected main" \
   || fail_t "candidate boundary was not preserved"
[[ "$(STUB_UPLOAD_EXIT=23 bash "$fx_c/ops/release.sh" release ios 2.0.1 --yes 2>&1 || true)" == *"finalize ios 2.0.1 6"* ]] \
  && ok "pending candidate blocks rerun and points to finalize" \
  || fail_t "pending candidate rerun did not point to finalize"

# 15c.1. upload 失敗後只重跑 finalize 不得重新 upload；若 upload 成功但 ASC 尚未
#       顯示 exact build，也必須保留 candidate，稍後 finalize 可無副作用恢復。
finalize_c_rc=0
finalize_c_out="$(bash "$fx_c/ops/release.sh" finalize ios 2.0.1 6 --yes 2>&1)" || finalize_c_rc=$?
[[ "$finalize_c_rc" -ne 0 && "$finalize_c_out" == *"exact --pr"* \
   && ! -e "$fx_c/upload.called" ]] \
  && ok "finalize refuses a pre-merge candidate without exact receipt" \
  || fail_t "finalize accepted an unmerged candidate: $finalize_c_out"

fx_rpending="$TMP4/asc-pending"; remote_rpending="$TMP4/asc-pending.git"
make_ios_release_fixture "$fx_rpending" "$remote_rpending"
pending_asc_rc=0
pending_asc_out="$(ASC_EXACT_BUILD_EXIT=3 KG_RELEASE_ASC_WAIT_SECS=0 bash "$fx_rpending/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || pending_asc_rc=$?
candidate_rpending="$(git -C "$fx_rpending" rev-parse HEAD)"
[[ "$pending_asc_rc" -eq 0 \
   && ! -e "$fx_rpending/upload.count" \
   && "$(git -C "$fx_rpending" log -1 --format=%s)" == "ops: prepare ios 2.0.1 build 6" \
   && -z "$(git -C "$fx_rpending" tag -l 'ios/2.0.1+6')" \
   && "$(git --git-dir="$remote_rpending" rev-parse refs/heads/main)" != "$candidate_rpending" ]] \
  && ok "release leaves ASC propagation to post-merge resume" \
  || fail_t "candidate path performed ASC work: $pending_asc_out"
pending_dry_rc=0
pending_dry_out="$(bash "$fx_rpending/ops/release.sh" finalize ios 2.0.1 6 2>&1)" || pending_dry_rc=$?
[[ "$pending_dry_rc" -ne 0 \
   && -z "$(git -C "$fx_rpending" tag -l 'ios/2.0.1+6')" \
   && "$pending_dry_out" == *"exact --pr"* ]] \
  && ok "finalize dry-run refuses without exact PR receipt" \
  || fail_t "finalize dry-run did not fail closed: $pending_dry_out"
pending_finalize_rc=0
pending_finalize_out="$(bash "$fx_rpending/ops/release.sh" finalize ios 2.0.1 6 --yes 2>&1)" || pending_finalize_rc=$?
[[ "$pending_finalize_rc" -ne 0 \
   && "$pending_finalize_out" == *"exact --pr"* \
   && ! -e "$fx_rpending/upload.called" ]] \
  && ok "finalize remains side-effect free before exact PR/source evidence" \
  || fail_t "finalize crossed the evidence gate: $pending_finalize_out"

# 15c.2. A candidate must not touch a remote tag or branch before queue merge.
fx_remote_collision="$TMP4/remote-tag-collision"; remote_remote_collision="$TMP4/remote-tag-collision.git"
make_ios_release_fixture "$fx_remote_collision" "$remote_remote_collision"
head_remote_collision="$(git -C "$fx_remote_collision" rev-parse HEAD)"
remote_collision_rc=0
remote_collision_out="$(STUB_REMOTE_TAG=ios/2.0.1+6 bash "$fx_remote_collision/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || remote_collision_rc=$?
candidate_remote_collision="$(git -C "$fx_remote_collision" rev-parse HEAD)"
[[ "$remote_collision_rc" -eq 0 \
   && ! -e "$fx_remote_collision/upload.count" \
   && -z "$(git -C "$fx_remote_collision" tag -l 'ios/2.0.1+6')" \
   && -z "$(git --git-dir="$remote_remote_collision" tag -l 'ios/2.0.1+6')" \
   && "$(git --git-dir="$remote_remote_collision" rev-parse refs/heads/main)" == "$head_remote_collision" ]] \
  && ok "candidate leaves remote-only tag collision untouched before merge" \
  || fail_t "candidate crossed the remote tag boundary: $remote_collision_out"

# 15c.3. A second release invocation must not pass preflight while the first
#      transaction owns the shared release lock.
fx_lock="$TMP4/release-lock"; remote_lock="$TMP4/release-lock.git"
make_ios_release_fixture "$fx_lock" "$remote_lock"
lock_base="$(git --git-dir="$remote_lock" rev-parse refs/heads/main)"
lock_first_out="$TMP4/release-lock-first.out"
STUB_UPLOAD_SLEEP_SECS=2 bash "$fx_lock/ops/release.sh" release ios 2.0.1 --yes >"$lock_first_out" 2>&1 &
lock_first_pid=$!
for _ in {1..20}; do
  [[ -d "$fx_lock/.git/kg-release.lock" ]] && break
  sleep 0.1
done
lock_second_rc=0
lock_second_out="$(bash "$fx_lock/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || lock_second_rc=$?
lock_first_rc=0
wait "$lock_first_pid" || lock_first_rc=$?
[[ "$lock_first_rc" -eq 0 \
   && "$lock_second_rc" -ne 0 \
   && "$lock_second_out" == *"release lock"* \
   && ! -e "$fx_lock/upload.count" \
   && -z "$(git --git-dir="$remote_lock" tag -l 'ios/2.0.1+6')" \
   && "$(git --git-dir="$remote_lock" rev-parse refs/heads/main)" == "$lock_base" ]] \
  && ok "shared release lock prevents a concurrent duplicate candidate" \
  || fail_t "concurrent release was not serialized: first=$lock_first_rc second=$lock_second_out"

# 15c.4. A held lock whose owner file is absent must still refuse as a lock.
fx_noowner="$TMP4/release-lock-noowner"; remote_noowner="$TMP4/release-lock-noowner.git"
make_ios_release_fixture "$fx_noowner" "$remote_noowner"
mkdir "$fx_noowner/.git/kg-release.lock"
noowner_rc=0
noowner_out="$(bash "$fx_noowner/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || noowner_rc=$?
[[ "$noowner_rc" -ne 0 \
   && "$noowner_out" == *"release lock 已被占用"* \
   && "$noowner_out" != *"No such file or directory"* ]] \
  && ok "lock dir without owner file refuses with the lock message" \
  || fail_t "owner-less lock did not refuse cleanly: rc=$noowner_rc out=$noowner_out"

# 15c.5. An owner file that cannot be read at refusal time (the race where the
#      holder's cleanup removes it between the test and the read) must still
#      fall through to the lock refusal, not abort under set -e.
fx_unreadable="$TMP4/release-lock-unreadable"; remote_unreadable="$TMP4/release-lock-unreadable.git"
make_ios_release_fixture "$fx_unreadable" "$remote_unreadable"
mkdir "$fx_unreadable/.git/kg-release.lock"
printf 'pid=1\nroot=x\n' >"$fx_unreadable/.git/kg-release.lock/owner"
chmod 000 "$fx_unreadable/.git/kg-release.lock/owner"
unreadable_rc=0
unreadable_out="$(bash "$fx_unreadable/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || unreadable_rc=$?
[[ "$unreadable_rc" -ne 0 \
   && "$unreadable_out" == *"release lock 已被占用"* \
   && "$unreadable_out" != *"Permission denied"* \
   && "$unreadable_out" != *"No such file or directory"* ]] \
  && ok "unreadable owner file still refuses with the lock message" \
  || fail_t "owner read error replaced the lock refusal: rc=$unreadable_rc out=$unreadable_out"

# 15d. direct tag 也是外部 release marker，必須吃同一個 guard——否則 bump→tag 兩步
#      就是一條繞過 release 的旁路。這裡用倒退版號當探針。
fx_d="$TMP4/direct-tag"; remote_d="$TMP4/direct-tag.git"
make_ios_release_fixture "$fx_d" "$remote_d"
head_d="$(git -C "$fx_d" rev-parse HEAD)"
direct_rc=0
direct_out="$(bash "$fx_d/ops/release.sh" bump ios 1.9.9 --yes 2>&1 && bash "$fx_d/ops/release.sh" tag ios 1.9.9 --yes 2>&1)" || direct_rc=$?
[[ "$direct_rc" -ne 0 \
   && "$(git -C "$fx_d" rev-parse HEAD)" == "$head_d" \
   && ! -e "$fx_d/upload.called" ]] \
  && [[ -z "$(git -C "$fx_d" tag -l 'ios/1.9.9*')" ]] \
  && [[ -z "$(git --git-dir="$remote_d" tag -l 'ios/1.9.9*')" ]] \
  && ok "direct iOS tag enforces the same new-version guard as release" \
  || fail_t "direct iOS tag bypassed the guard: $direct_out"

# 15e. 已上架 tag 存在也不授權 semver 倒退。
fx_e="$TMP4/downgrade"; remote_e="$TMP4/downgrade.git"
make_ios_release_fixture "$fx_e" "$remote_e"
head_e="$(git -C "$fx_e" rev-parse HEAD)"
downgrade_rc=0
downgrade_out="$(bash "$fx_e/ops/release.sh" release ios 1.9.9 --yes 2>&1)" || downgrade_rc=$?
[[ "$downgrade_rc" -ne 0 \
   && "$(git -C "$fx_e" rev-parse HEAD)" == "$head_e" \
   && ! -e "$fx_e/upload.called" ]] \
  && grep -q '高於.*2.0.0' <<<"$downgrade_out" \
  && ok "iOS new marketing version must increase monotonically" \
  || fail_t "iOS downgrade was not safely rejected: $downgrade_out"

# 15f. 版號若已在一個尚未以 live main 為基底的 local commit，不能把它
#      當成合法 release lane；必須重新 materialize exact live main，避免把
#      未審查的來源帶進 release PR。
fx_f="$TMP4/already-committed"; remote_f="$TMP4/already-committed.git"
make_ios_release_fixture "$fx_f" "$remote_f"
perl -pi -e 's/MARKETING_VERSION = 2.0.0;/MARKETING_VERSION = 2.0.1;/g; s/CURRENT_PROJECT_VERSION = 5;/CURRENT_PROJECT_VERSION = 6;/g' \
  "$fx_f/ios/BooksAndVocab.xcodeproj/project.pbxproj"
git -C "$fx_f" add ios/BooksAndVocab.xcodeproj/project.pbxproj
git -C "$fx_f" commit -qm "fixture: version already committed"
committed_head="$(git -C "$fx_f" rev-parse HEAD)"
committed_rc=0
committed_out="$(bash "$fx_f/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || committed_rc=$?
committed_candidate="$(git -C "$fx_f" rev-parse HEAD)"
[[ "$committed_rc" -ne 0 \
   && "$committed_out" == *"exact live origin/main"* \
   && "$committed_candidate" == "$committed_head" \
   && "$(grep -c 'CURRENT_PROJECT_VERSION = 6;' "$fx_f/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 \
   && ! -e "$fx_f/upload.called" \
   && -z "$(git -C "$fx_f" tag -l 'ios/2.0.1+6')" \
   && -z "$(git --git-dir="$remote_f" tag -l 'ios/2.0.1+6')" ]] \
  && ok "already-committed version requires a fresh live-based release lane" \
  || fail_t "already-committed stale lane was not rejected: $committed_out"

# 15g. 事故本體：有一個版本出過 build、卻還沒有上架 tag，就直接發下一版。
#      2.0.1 事故就是這個形狀——2.0.0 還在審（build 5 已上傳），卻已 bump 成 2.0.1。
#      build tag 讓這件事**第一次變成可檢查的**：介於已上架版本與本次版本之間、
#      有 build tag 卻沒有上架 tag 的版本 = 尚未確認上架，不得跳過。
fx_g="$TMP4/pending-version"; remote_g="$TMP4/pending-version.git"
make_ios_release_fixture "$fx_g" "$remote_g"
git -C "$fx_g" tag -d ios/2.0.0 >/dev/null
git -C "$fx_g" tag "ios/1.6.0"            # 真正上架的是 1.6.0
git -C "$fx_g" tag "ios/2.0.0+5"          # 2.0.0 出過 build，但沒人確認它上架了
git -C "$fx_g" tag "ios/2.0.0+6"
head_g="$(git -C "$fx_g" rev-parse HEAD)"
pending_rc=0
pending_out="$(bash "$fx_g/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || pending_rc=$?
[[ "$pending_rc" -ne 0 && ! -e "$fx_g/upload.called" \
   && "$(git -C "$fx_g" rev-parse HEAD)" == "$head_g" ]] \
  && ok "skipping a version that has builds but no shipped tag is refused pre-upload" \
  || fail_t "released past an unconfirmed version (the 2.0.1 incident shape): $pending_out"
grep -q '2\.0\.0' <<<"$pending_out" \
  && ok "pending-version error names the version that was about to be skipped" \
  || fail_t "pending-version error does not name 2.0.0: $pending_out"
# 正控：補上 2.0.0 的上架 tag 後，同一條 candidate 命令必須放行。
git -C "$fx_g" tag "ios/2.0.0"
allow_rc=0
allow_out="$(bash "$fx_g/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || allow_rc=$?
[[ "$allow_rc" -eq 0 && ! -e "$fx_g/upload.called" \
   && -z "$(git -C "$fx_g" tag -l 'ios/2.0.1+6')" \
   && "$(git -C "$fx_g" log -1 --format=%s)" == "ops: prepare ios 2.0.1 build 6" ]] \
  && ok "same command emits a candidate once the intermediate version is confirmed shipped" \
  || fail_t "guard blocks even after the pending version is resolved: $allow_out"

# ── 版號漂移分類（ios/2.0.1 誤標事故：tag 高於檔內 = 版號被撤回，不是待對齊）──
# 事故形狀：`ops: release ios 2.0.1` 打了 tag，其後 `ios: correct 2.0.0 build 6
# resubmission` 把 MARKETING_VERSION 還原成 2.0.0，2.0.1 從未上架。留著的 tag 讓
# last_tag 回 ios/2.0.1，於是 --new-version-after-ready 逼 operator attest 一個
# 不存在的版本、且新版號被強制 > 2.0.1（2.0.1 永久燒掉）。舊的單一漂移警示只會
# 說「發版前先 bump 對齊」——照做會復活被撤回的版號，方向剛好相反。
drift_fn="$(sed -n '/^classify_version_drift()/,/^}/p' "$REL")"
if [[ -n "$drift_fn" ]]; then
  drift_probe() {
    bash -lc "$(sed -n '/^valid_semver()/,/^}/p' "$REL")
$(sed -n '/^semver_gt()/,/^}/p' "$REL")
$drift_fn
classify_version_drift '$1' '$2'"
  }
  [[ "$(drift_probe 2.0.0 2.0.0)" == none ]] \
    && ok "drift: equal versions report none" || fail_t "drift equal invalid: $(drift_probe 2.0.0 2.0.0)"
  [[ "$(drift_probe 2.0.0 2.0.1)" == ahead ]] \
    && ok "drift: file ahead of tag is a pending bump" || fail_t "drift ahead invalid: $(drift_probe 2.0.0 2.0.1)"
  [[ "$(drift_probe 2.0.1 2.0.0)" == mistagged ]] \
    && ok "drift: tag ahead of file is a withdrawn version (mistagged)" \
    || fail_t "drift mistagged invalid: $(drift_probe 2.0.1 2.0.0)"
  [[ "$(drift_probe 2.0 2.0.0)" == none ]] \
    && ok "drift: two-segment ios version normalizes before comparison" \
    || fail_t "drift 2-seg normalization invalid: $(drift_probe 2.0 2.0.0)"
  [[ "$(drift_probe '' 2.0.0)" == none ]] \
    && ok "drift: unknown tag version stays quiet" || fail_t "drift empty-tag invalid: $(drift_probe '' 2.0.0)"
else
  fail_t "release.sh has no classify_version_drift seam (ios/2.0.1 mistag stays undiagnosed)"
fi
grep -q 'classify_version_drift' <<<"$status_body" \
  && ok "status classifies drift instead of always advising a bump" \
  || fail_t "status still emits a single undirected drift warning"
grep -q '誤標' <<<"$status_body" \
  && ok "status names the mistagged case" || fail_t "status has no mistagged branch"

# ── 16. last_tag 只認 released 形狀（build tag 不得污染） ────────────────────
# `git tag -l "ios/*"` 的 `*` 會跨 `/` 比對，而 `--sort=-v:refname` 把 ios/2.0.0+6
# 排在 ios/2.0.0 之上。所以一旦開始記 build tag，未收緊的 last_tag 會回 build tag，
# 讓 guard / status / changelog range 全部改讀一個不是「已上架版本」的東西。
section "last_tag recognizes only the released x.y.z shape"

# 直接對規則的 owner 取證，不再從 release.sh 抽函式體：抽取式 probe 只證明「那段程式碼
# 這樣寫」，證不到任何呼叫端——所以它可以在 release_changelog.sh 靜默壞掉時全綠。
# 呼叫端由下面的 status 斷言與 §18 的 changelog 斷言各自覆蓋。
last_tag_probe() {  # $1=fixture root  $2=component
  bash -c "set -euo pipefail
. '$WORKSPACE/ops/lib/release_tags.sh'
release_last_tag '$2' '$1'"
}

TMP5="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$TMP4" "$TMP5"' EXIT
fx_lt="$TMP5/last-tag"
mkdir -p "$fx_lt"
git init -q -b main "$fx_lt"
git -C "$fx_lt" config user.name "Release Test"
git -C "$fx_lt" config user.email "release-test@example.invalid"
git -C "$fx_lt" commit -q --allow-empty -m "fixture"
for t in ios/1.6.0 ios/2.0.0 ios/2.0.0+5 ios/2.0.0+6 api/2.0.1; do
  git -C "$fx_lt" tag "$t"
done

# 負控先行：確認未收緊的 glob 真的會撈到 build tag，否則下面那條測試沒在測東西。
[[ "$(git -C "$fx_lt" tag -l 'ios/*' --sort=-v:refname | head -1)" == "ios/2.0.0+6" ]] \
  && ok "raw ios/* glob does rank the build tag first (guard is load-bearing)" \
  || fail_t "fixture does not reproduce build-tag pollution — the last_tag test proves nothing"

lt_ios="$(last_tag_probe "$fx_lt" ios)"
[[ "$lt_ios" == "ios/2.0.0" ]] \
  && ok "last_tag ios skips build tags and returns ios/2.0.0" \
  || fail_t "last_tag ios returned '${lt_ios}' (build tag leaked into released-version lookup)"
lt_api="$(last_tag_probe "$fx_lt" api)"
[[ "$lt_api" == "api/2.0.1" ]] \
  && ok "last_tag api unaffected" || fail_t "last_tag api returned '${lt_api}'"

# 沒有任何 released tag 時必須「回空且 exit 0」：呼叫端在 set -e 下用 lt="$(last_tag …)"，
# 一個非零 exit 會讓 status 整個中斷，而不是走「（尚未發版）」分支。
fx_lt_empty="$TMP5/last-tag-empty"
mkdir -p "$fx_lt_empty"
git init -q -b main "$fx_lt_empty"
git -C "$fx_lt_empty" config user.name "Release Test"
git -C "$fx_lt_empty" config user.email "release-test@example.invalid"
git -C "$fx_lt_empty" commit -q --allow-empty -m "fixture"
git -C "$fx_lt_empty" tag "ios/2.0.0+6"
empty_rc=0
lt_empty="$(last_tag_probe "$fx_lt_empty" ios)" || empty_rc=$?
[[ "$empty_rc" -eq 0 && -z "$lt_empty" ]] \
  && ok "last_tag with build tags but no released tag returns empty and exits 0" \
  || fail_t "last_tag build-tag-only repo: rc=$empty_rc out='${lt_empty}' (would abort status under set -e)"

# 呼叫端取證：release.sh status 必須報 released tag，而不是排在它前面的 build tag。
mkdir -p "$fx_lt/ops/lib" "$fx_lt/ios/BooksAndVocab.xcodeproj" "$fx_lt/backend/src/kg"
cp "$REL" "$fx_lt/ops/"
cp "$WORKSPACE/ops/lib/release_tags.sh" "$fx_lt/ops/lib/"
cat > "$fx_lt/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<'PBX'
MARKETING_VERSION = 2.0.0; CURRENT_PROJECT_VERSION = 6;
MARKETING_VERSION = 2.0.0; CURRENT_PROJECT_VERSION = 6;
PBX
printf '[project]\nversion = "2.0.1"\n' > "$fx_lt/backend/pyproject.toml"
status_fx="$(bash "$fx_lt/ops/release.sh" status 2>&1)"
ios_status_lines="$(grep -E '^■ ios' <<<"$status_fx")"
grep -q 'ios/2.0.0+6' <<<"$ios_status_lines" \
  && fail_t "status reports the build tag as the last released version: $ios_status_lines" \
  || ok "status caller reports the released tag, not the build tag"

# A current project tuple with an existing build tag is already sealed.  Status
# must measure only iOS commits after that build tag; counting from the shipped
# marketing tag turns a completed build into a false pending backlog.
fx_status_sealed="$TMP5/status-sealed-build"
cp -R "$fx_lt" "$fx_status_sealed"
perl -pi -e 's/MARKETING_VERSION = 2.0.0;/MARKETING_VERSION = 2.0.1;/g; s/CURRENT_PROJECT_VERSION = 6;/CURRENT_PROJECT_VERSION = 12;/g' \
  "$fx_status_sealed/ios/BooksAndVocab.xcodeproj/project.pbxproj"
git -C "$fx_status_sealed" add ios/BooksAndVocab.xcodeproj/project.pbxproj
git -C "$fx_status_sealed" commit -q -m "ios: prepare ios 2.0.1 build 12"
git -C "$fx_status_sealed" tag "ios/2.0.1+12"
status_sealed="$(bash "$fx_status_sealed/ops/release.sh" status 2>&1)"
grep -q 'ios/2.0.1+12' <<<"$status_sealed" \
  && ok "status exposes the current sealed iOS build tag" \
  || fail_t "status omitted the current sealed iOS build tag: $status_sealed"
grep -q '自最新 build tag 無未封版 ios: commit' <<<"$status_sealed" \
  && ok "status measures unsealed iOS delta after the current build tag" \
  || fail_t "status treated the sealed build as a pending iOS backlog: $status_sealed"
grep -q '待發版 1 筆 ios: commit' <<<"$status_sealed" \
  && fail_t "status still reports shipped-range commits as pending after build sealing" \
  || ok "status does not report shipped-range commits as pending after build sealing"

# ── 17. build tag：(version, build) → 封版 commit ───────────────────────────
# Apple 只保留「當前」appStoreVersion，versionString 是可變欄位，build number 每個
# marketing version 重新計數。所以「哪顆 commit 產生了哪顆 build」這個事實只有 repo
# 能保存，而且必須在出 archive 的當下捕捉——事後無從重建（ios/2.0.0 指向 build 5 的
# commit、實際上架 build 6 的事故，就是靠 pbxproj 編輯時戳夾送審時戳硬反推出來的）。
section "iOS build tag records which commit produced (version, build)"

# 17a. release ios 只建立 candidate；ios/<ver>+<build> 必須由 merged resume/finalize
#      的 tag-only route 產生，且**不得**順手打 ios/<ver>。
fx_bt="$TMP5/build-tag"; remote_bt="$TMP5/build-tag.git"
make_ios_release_fixture "$fx_bt" "$remote_bt"
bt_rc=0
bt_out="$(bash "$fx_bt/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || bt_rc=$?
bt_head="$(git -C "$fx_bt" rev-parse HEAD)"
[[ "$bt_rc" -eq 0 && ! -e "$fx_bt/upload.called" ]] \
  && ok "release ios creates candidate without upload" || fail_t "release ios candidate failed: $bt_out"
[[ -z "$(git -C "$fx_bt" rev-parse -q --verify 'refs/tags/ios/2.0.1+6^{commit}' 2>/dev/null)" ]] \
  && ok "candidate does not create a build tag before merged finalize" \
  || fail_t "candidate created a build tag before merge: $bt_out"
git -C "$fx_bt" rev-parse -q --verify refs/tags/ios/2.0.1 >/dev/null \
  && fail_t "release minted ios/2.0.1 — repo claimed a shipped fact it cannot know at upload time" \
  || ok "release does not mint the shipped tag it cannot know yet"
[[ -z "$(git --git-dir="$remote_bt" rev-parse -q --verify 'refs/tags/ios/2.0.1+6^{commit}' 2>/dev/null)" \
   && "$(git --git-dir="$remote_bt" rev-parse refs/heads/main)" != "$bt_head" ]] \
  && ok "candidate leaves remote tag/main refs unchanged" \
  || fail_t "candidate crossed the remote publication boundary"

# 17b. 同一 (version, build) 從兩顆不同 commit 出 archive = 真歧義，必須 refuse，
#      而且要在 upload 之前——TestFlight upload 不可逆，先確定封得下去再送。
fx_bc="$TMP5/build-tag-conflict"; remote_bc="$TMP5/build-tag-conflict.git"
make_ios_release_fixture "$fx_bc" "$remote_bc"
sealed_bc="$(git -C "$fx_bc" rev-parse HEAD)"
git -C "$fx_bc" tag "ios/2.0.1+6"
conflict_rc=0
conflict_out="$(bash "$fx_bc/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || conflict_rc=$?
[[ "$conflict_rc" -ne 0 ]] \
  && ok "conflicting build tag is refused" || fail_t "conflicting build tag was silently accepted: $conflict_out"
[[ ! -e "$fx_bc/upload.called" ]] \
  && ok "conflict refusal happens before the irreversible upload" \
  || fail_t "uploaded to TestFlight before discovering we could not seal the result"
[[ "$(git -C "$fx_bc" rev-parse 'refs/tags/ios/2.0.1+6^{commit}')" == "$sealed_bc" \
   && "$(git -C "$fx_bc" rev-parse HEAD)" == "$sealed_bc" ]] \
  && ok "conflict leaves the existing build tag and HEAD untouched" \
  || fail_t "conflict moved the existing build tag or HEAD"
# 這條斷言必須綁在**同一行**同時出現 tag 名與既有 commit：只 grep 短 sha 會被 git 的
# push range 行（`84b9bb5..312e381 main -> main`）滿足，於是在完全沒有拒絕訊息時也變綠。
grep -q "ios/2.0.1+6.*$(git -C "$fx_bc" rev-parse --short "$sealed_bc")" <<<"$conflict_out" \
  && ok "conflict error names both the build tag and the commit it already points at" \
  || fail_t "conflict error is not actionable (no single line naming tag + existing commit): $conflict_out"

# 17c. 冪等：同一 (version, build) 已封在這顆 commit → noop，不是錯誤。
#      重跑一次收尾（例如 push 中斷後補跑）不該逼人手動刪 tag。
fx_bi="$TMP5/build-tag-idempotent"; remote_bi="$TMP5/build-tag-idempotent.git"
make_ios_release_fixture "$fx_bi" "$remote_bi"
bash "$fx_bi/ops/release.sh" bump ios 2.0.1 --yes >/dev/null 2>&1 \
  || fail_t "idempotent fixture bump failed"
git -C "$fx_bi" add ios/BooksAndVocab.xcodeproj/project.pbxproj
git -C "$fx_bi" commit -qm "ios: seal 2.0.1 build 6"
sealed_bi="$(git -C "$fx_bi" rev-parse HEAD)"
git -C "$fx_bi" tag "ios/2.0.1+6"
idem_rc=0
idem_out="$(bash "$fx_bi/ops/release.sh" tag ios 2.0.1 --yes 2>&1)" || idem_rc=$?
[[ "$idem_rc" -eq 0 \
   && "$(git -C "$fx_bi" rev-parse HEAD)" == "$sealed_bi" \
   && "$(git -C "$fx_bi" rev-parse 'refs/tags/ios/2.0.1+6^{commit}')" == "$sealed_bi" \
   && "$(git --git-dir="$remote_bi" rev-parse -q --verify 'refs/tags/ios/2.0.1+6^{commit}' 2>/dev/null)" == "$sealed_bi" ]] \
  && ok "re-sealing the same (version, build) at the same commit is a noop that still pushes" \
  || fail_t "idempotent re-tag failed: rc=$idem_rc out=$idem_out"

# ── 18. changelog 也吃同一條「released tag」規則 ────────────────────────────
# §16 只證明了 release.sh 裡的 last_tag 函式，證不到任何呼叫端——而 release_changelog.sh
# 帶著同一段邏輯的第二份逐字副本。build tag 一存在，`changelog ios` 就靜默錨在它上面、
# 把整份 changelog 清空（無錯誤訊息），而 status 的結尾提示正是 bump → changelog → release。
# 兩份實作就是這次事故的根因，所以除了行為，也釘住「不得再有第三份」。
section "changelog shares the released-tag rule (no second implementation)"
CHANGELOG="$WORKSPACE/ops/release_changelog.sh"
TAGLIB="$WORKSPACE/ops/lib/release_tags.sh"

[[ -f "$TAGLIB" ]] \
  && ok "ops/lib/release_tags.sh exists (single owner of the tag rule)" \
  || fail_t "ops/lib/release_tags.sh missing — release.sh and release_changelog.sh still carry two copies"
grep -q 'git tag -l' "$CHANGELOG" \
  && fail_t "release_changelog.sh still enumerates tags itself (second implementation of the released-tag rule)" \
  || ok "release_changelog.sh no longer enumerates tags itself"

fx_cl="$TMP5/changelog"
mkdir -p "$fx_cl/ops/lib"
cp "$CHANGELOG" "$fx_cl/ops/"
[[ ! -f "$TAGLIB" ]] || cp "$TAGLIB" "$fx_cl/ops/lib/"
git init -q -b main "$fx_cl"
git -C "$fx_cl" config user.name "Release Test"
git -C "$fx_cl" config user.email "release-test@example.invalid"
git -C "$fx_cl" commit -q --allow-empty -m "ios: before shipping"
git -C "$fx_cl" tag ios/2.0.0
git -C "$fx_cl" commit -q --allow-empty -m "ios: 新增 after shipping"
git -C "$fx_cl" tag "ios/2.0.0+6"          # build tag 指向較新的 commit
cl_out="$(bash "$fx_cl/ops/release_changelog.sh" ios 2>&1)"
grep -q '自 ios/2\.0\.0[^+]' <<<"$cl_out" && ! grep -q '2\.0\.0+6' <<<"$cl_out" \
  && ok "changelog anchors on the released tag, not the build tag" \
  || fail_t "changelog anchored on a build tag: $cl_out"
grep -q 'after shipping' <<<"$cl_out" \
  && ok "changelog still lists commits made after the released tag" \
  || fail_t "changelog silently emptied itself (no error, just no content): $cl_out"

# 分類器：test 不是功能、feat(ios) 與純路徑 iOS commit 都算（舊版只認 `ios:` 前綴且把 test 當功能）
section "changelog classifier: test is not a feature, feat(ios) and path-only ios count"
git -C "$fx_cl" commit -q --allow-empty -m "test(ios): add login coverage"
git -C "$fx_cl" commit -q --allow-empty -m "feat(ios): dark app icon"
mkdir -p "$fx_cl/ios/BooksAndVocab"; echo x > "$fx_cl/ios/BooksAndVocab/A.swift"
git -C "$fx_cl" add ios && git -C "$fx_cl" commit -q -m "tidy the reader margins"
cl_d="$(bash "$fx_cl/ops/release_changelog.sh" ios --draft 2>&1)"
cl_new="$(awk '/^#### New/{f=1;next} /^#/{f=0} f&&/^- /' <<<"$cl_d")"
grep -q 'login coverage' <<<"$cl_new" \
  && fail_t "test commit counted as feature: $cl_new" || ok "test(ios) commit is not a feature"
grep -q 'dark app icon' <<<"$cl_new" && ok "feat(ios) title counted as New" || fail_t "feat(ios) missed: $cl_d"
grep -q 'tidy the reader margins' <<<"$cl_d" && ok "path-only ios commit counted" || fail_t "path-only ios commit missed: $cl_d"
grep -q '^## Unreleased' <<<"$cl_d" && ok "--draft prints an Unreleased section" || fail_t "no Unreleased header: $cl_d"

# 真 merge-commit 路徑：merge body 首行常是 PR 最後一個 commit 主旨（#2411 body=test(...) 實為 entitlement 修復）。
section "changelog: real PR titles, needs-curation list, word boundaries, bad input"
fx_cm="$TMP5/changelog-api"
mkdir -p "$fx_cm/ops/lib" "$fx_cm/backend/src/kg"
cp "$CHANGELOG" "$fx_cm/ops/"
[[ ! -f "$TAGLIB" ]] || cp "$TAGLIB" "$fx_cm/ops/lib/"
git init -q -b main "$fx_cm"
git -C "$fx_cm" config user.name "Release Test"
git -C "$fx_cm" config user.email "release-test@example.invalid"
echo 0 > "$fx_cm/backend/src/kg/billing.py"
git -C "$fx_cm" add -A && git -C "$fx_cm" commit -q -m "chore: seed"
cm_run() { KG_PR_TITLES_FILE="${CM_TITLES:-/dev/null}" bash "$fx_cm/ops/release_changelog.sh" "$@"; }
cm_empty="$(cm_run api 2>&1)"
grep -q '自 initial' <<<"$cm_empty" && grep -q 'seed' <<<"$cm_empty" \
  && ok "no tag: whole history is the range ('initial')" || fail_t "no-tag range wrong: $cm_empty"
git -C "$fx_cm" tag api/1.0.0
cm_empty="$(cm_run api --draft 2>&1)" && cm_rc=0 || cm_rc=$?
grep -q '無變更（自 api/1.0.0' <<<"$cm_empty" && [ "$cm_rc" = 0 ] \
  && ok "empty range prints 無變更 and exits 0" || fail_t "empty range wrong rc=$cm_rc: $cm_empty"
cm_pr() {  # <n> <branch> <file-content> <commit-subject> ：在 branch 上改 billing.py 後 --no-ff 合併，body 首行 = commit 主旨
  git -C "$fx_cm" checkout -q -b "$2"
  echo "$3" >> "$fx_cm/backend/src/kg/billing.py"
  git -C "$fx_cm" commit -q -am "$4"
  git -C "$fx_cm" checkout -q main
  git -C "$fx_cm" merge -q --no-ff -m "Merge pull request #$1 from Books-Vocab/$2" -m "$4" "$2"
}
cm_pr 2411 lane-grace x1 "test(billing): grace-period entitlement fixture"   # lane PR：真 GitHub 標題也是 test(...)，實為 entitlement 修復
cm_pr 2412 lane-cache x2 "speed up the latest cache lookups"
cm_pr 2413 lane-zh x3 "新增 發票匯出"
cm_pr 2414 lane-cursor x4 "wip: cursor tweak"                               # 一般 PR：body 首行失真，真標題才對
printf '2411\ttest(billing): grace-period entitlement fixture\n2413\t新增 發票匯出\n2414\tfix(api): reject empty cursor\n' > "$TMP5/cm_titles.tsv"
cm_off="$(cm_run api --draft 2>&1)"
grep -q 'reject empty cursor' <<<"$(awk '/^#### Fixed/{f=1;next} /^#/{f=0} f' <<<"$cm_off")" \
  && fail_t "no title map, yet the real title appeared: $cm_off" \
  || ok "without a title map an ordinary PR falls back to its (misleading) merge body"
cm_on="$(CM_TITLES="$TMP5/cm_titles.tsv" cm_run api --draft 2>&1)"
grep -q 'reject empty cursor.*#2414' <<<"$(awk '/^#### Fixed/{f=1;next} /^#/{f=0} f' <<<"$cm_on")" \
  && ok "real PR title (seam) classifies an ordinary PR as Fixed, with the PR number appended" || fail_t "real title ignored: $cm_on"
for cm_which in off on; do
  cm_txt="$cm_off"; [ "$cm_which" = on ] && cm_txt="$cm_on"
  grep -q 'grace-period entitlement' <<<"$(awk '/^#### Fixed/{f=1;next} /^#/{f=0} f' <<<"$cm_txt")" \
    && fail_t "lane PR with a test(...) title was classified Fixed ($cm_which): $cm_txt" \
    || ok "lane PR titled test(...) is not auto-classified as a fix ($cm_which)"
  grep -q 'grace-period entitlement.*#2411' <<<"$(awk '/^### Needs curation/{f=1;next} /^###/{f=0} f' <<<"$cm_txt")" \
    && ok "lane PR #2411 lands in Needs curation ($cm_which)" || fail_t "#2411 missing from Needs curation ($cm_which): $cm_txt"
done
grep -q 'reject empty cursor' <<<"$(awk '/^### Needs curation/{f=1;next} /^###/{f=0} f' <<<"$cm_on")" \
  && fail_t "correctly classified merge still listed as needs-curation: $cm_on" || ok "correctly classified merge is not in needs-curation"
grep -q 'latest cache' <<<"$(awk '/^#### Improved/{f=1;next} /^#/{f=0} f' <<<"$cm_on")" \
  && ok "'latest' does not match the test keyword (word boundary)" || fail_t "'speed up the latest cache' misclassified: $cm_on"
grep -q '共 1 項' <<<"$(awk '/^### Internal/{f=1;next} /^###/{f=0} f' <<<"$cm_on")" \
  && ok "only the lane test(...) PR is counted internal" || fail_t "internal count wrong: $cm_on"
# gh --limit 撞頂：較舊 PR 標題會靜默退回 merge body → 必須警告（用 count seam KG_PR_TITLES_LIMIT）
cm_warn="$(KG_PR_TITLES_LIMIT=3 KG_PR_TITLES_FILE="$TMP5/cm_titles.tsv" bash "$fx_cm/ops/release_changelog.sh" api --draft 2>&1 >/dev/null)" || true
grep -q '已達上限' <<<"$cm_warn" \
  && ok "titles count == limit warns on stderr" || fail_t "no limit warning: $cm_warn"
cm_warn="$(KG_PR_TITLES_LIMIT=4 KG_PR_TITLES_FILE="$TMP5/cm_titles.tsv" bash "$fx_cm/ops/release_changelog.sh" api --draft 2>&1 >/dev/null)" || true
grep -q '已達上限' <<<"$cm_warn" \
  && fail_t "warned below the limit: $cm_warn" || ok "titles count below the limit does not warn"
grep -q '新增 發票匯出' <<<"$cm_on" \
  && ok "non-ASCII PR title survives the title map and classifier" || fail_t "non-ASCII title lost: $cm_on"
grep -q '新增 發票匯出' <<<"$(awk '/^#### New/{f=1;next} /^#/{f=0} f' <<<"$cm_on")" \
  && ok "新增 title is classified New" || fail_t "新增 title misclassified: $cm_on"
cm_bad="$(cm_run api --draft no-such-ref 2>&1 >/dev/null)" && cm_rc=0 || cm_rc=$?
{ [ "$cm_rc" -ne 0 ] && grep -q 'no-such-ref' <<<"$cm_bad"; } \
  && ok "invalid since-ref: clear stderr message and non-zero exit" || fail_t "invalid ref rc=$cm_rc: $cm_bad"
cm_bad="$(cm_run api --drat 2>&1 >/dev/null)" && cm_rc=0 || cm_rc=$?
{ [ "$cm_rc" -ne 0 ] && grep -q '用法' <<<"$cm_bad"; } \
  && ok "unknown second argument rejected with usage" || fail_t "--drat accepted rc=$cm_rc: $cm_bad"
cm_bad="$(cm_run api --draft api/1.0.0 extra 2>&1 >/dev/null)" && cm_rc=0 || cm_rc=$?
[ "$cm_rc" -ne 0 ] && ok "extra trailing argument rejected" || fail_t "trailing arg accepted: $cm_bad"
git -C "$fx_cm" checkout -q main

# ── 19. shipped ios：驗證式物化上架 tag（非背書式） ─────────────────────────
# 「哪顆 build 上架了」的 owner 是 ASC，「哪顆 commit 產生它」的 owner 是 repo。
# shipped 做的是這兩者的 join，而且只在確認上架後才物化成 ios/<x.y.z>。
# ASC 查詢走 KG_ASC_SHIPPED_CMD 注入點，所以這一整節離線可跑、不碰網路與憑證。
section "shipped ios materializes the shipped tag from ASC + build tag"

make_shipped_fixture() {  # $1=fixture $2=remote $3=stub 印出的內容 $4=stub exit code
  make_ios_release_fixture "$1" "$2"
  git -C "$1" tag -d ios/2.0.0 >/dev/null      # 上架 tag 由 shipped 產生，不預設存在
  cat > "$1/asc-stub.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$3"
exit ${4:-0}
STUB
  chmod +x "$1/asc-stub.sh"
}

# 19a. dry-run 預設：查得到、也 join 得到，但沒有 --yes 就不得建立 tag。
fx_s="$TMP5/shipped"; remote_s="$TMP5/shipped.git"
make_shipped_fixture "$fx_s" "$remote_s" "2.0.0 6"
sealed_s="$(git -C "$fx_s" rev-parse HEAD)"
git -C "$fx_s" tag "ios/2.0.0+6"
dry_rc=0
dry_s="$(KG_ASC_SHIPPED_CMD="$fx_s/asc-stub.sh" bash "$fx_s/ops/release.sh" shipped ios 2>&1)" || dry_rc=$?
[[ "$dry_rc" -eq 0 ]] && ok "shipped dry-run exits 0" || fail_t "shipped dry-run exited $dry_rc: $dry_s"
[[ -z "$(git -C "$fx_s" tag -l 'ios/2.0.0')" ]] \
  && ok "shipped dry-run creates no tag" || fail_t "shipped dry-run created a tag"
grep -q -- '--yes' <<<"$dry_s" \
  && ok "shipped dry-run points to --yes" || fail_t "shipped dry-run does not mention --yes: $dry_s"

# 19b. --yes：ios/2.0.0 落在 build tag 指的那顆 commit 上，並推 origin。
yes_rc=0
yes_s="$(KG_ASC_SHIPPED_CMD="$fx_s/asc-stub.sh" bash "$fx_s/ops/release.sh" shipped ios --yes 2>&1)" || yes_rc=$?
[[ "$(git -C "$fx_s" rev-parse 'refs/tags/ios/2.0.0^{commit}')" == "$sealed_s" \
   && "$(git --git-dir="$remote_s" rev-parse -q --verify 'refs/tags/ios/2.0.0^{commit}' 2>/dev/null)" == "$sealed_s" ]] \
  && ok "shipped joins (version, build) to the sealing commit and pushes" \
  || fail_t "shipped tag wrong or unpushed: $yes_s"

# 19c. 冪等：再跑一次是 noop，不是錯誤（tag 已與 ASC 一致）。
again_rc=0
again_s="$(KG_ASC_SHIPPED_CMD="$fx_s/asc-stub.sh" bash "$fx_s/ops/release.sh" shipped ios --yes 2>&1)" || again_rc=$?
[[ "$again_rc" -eq 0 && "$(git -C "$fx_s" rev-parse 'refs/tags/ios/2.0.0^{commit}')" == "$sealed_s" ]] \
  && ok "re-running shipped against an already-correct tag is a noop" \
  || fail_t "second shipped run failed or moved the tag: $again_s"

# 19d. 上架 tag 已存在但指向別顆 commit → 不移動。immutable 是這個 tag 的全部價值：
#      一個 released marketing version 只會有一顆上架 build，所以歧義必須人工裁決。
fx_sm="$TMP5/shipped-mismatch"; remote_sm="$TMP5/shipped-mismatch.git"
make_shipped_fixture "$fx_sm" "$remote_sm" "2.0.0 6"
wrong_sm="$(git -C "$fx_sm" rev-parse HEAD)"
git -C "$fx_sm" tag "ios/2.0.0" "$wrong_sm"
git -C "$fx_sm" commit -q --allow-empty -m "ios: the real sealing commit"
right_sm="$(git -C "$fx_sm" rev-parse HEAD)"
git -C "$fx_sm" tag "ios/2.0.0+6" "$right_sm"
mm_rc=0
mm_out="$(KG_ASC_SHIPPED_CMD="$fx_sm/asc-stub.sh" bash "$fx_sm/ops/release.sh" shipped ios --yes 2>&1)" || mm_rc=$?
[[ "$mm_rc" -ne 0 && "$(git -C "$fx_sm" rev-parse 'refs/tags/ios/2.0.0^{commit}')" == "$wrong_sm" ]] \
  && grep -q 'tag -d ios/2.0.0' <<<"$mm_out" \
  && ok "shipped refuses to move an existing shipped tag and prints the manual remediation" \
  || fail_t "shipped moved or silently accepted a conflicting shipped tag: $mm_out"

# 19d2. local 上架 tag 已與 ASC 一致、但 origin 缺 → 重跑要補推；origin 指向別顆 → 失敗。
fx_sp="$TMP5/shipped-localonly"; remote_sp="$TMP5/shipped-localonly.git"
make_shipped_fixture "$fx_sp" "$remote_sp" "2.0.0 6"
sealed_sp="$(git -C "$fx_sp" rev-parse HEAD)"
git --git-dir="$remote_sp" tag -d ios/2.0.0 >/dev/null 2>&1 || true
git -C "$fx_sp" tag "ios/2.0.0+6"
git -C "$fx_sp" tag "ios/2.0.0" "$sealed_sp"
sp_rc=0
sp_out="$(KG_ASC_SHIPPED_CMD="$fx_sp/asc-stub.sh" bash "$fx_sp/ops/release.sh" shipped ios --yes 2>&1)" || sp_rc=$?
[[ "$sp_rc" -eq 0 \
   && "$(git --git-dir="$remote_sp" rev-parse -q --verify 'refs/tags/ios/2.0.0^{commit}' 2>/dev/null)" == "$sealed_sp" ]] \
  && ok "shipped re-run pushes a local-only shipped tag to origin" \
  || fail_t "shipped treated a local-only tag as done: $sp_out"
fx_sq="$TMP5/shipped-remote-diff"; remote_sq="$TMP5/shipped-remote-diff.git"
make_shipped_fixture "$fx_sq" "$remote_sq" "2.0.0 6"
sealed_sq="$(git -C "$fx_sq" rev-parse HEAD)"
git -C "$fx_sq" tag "ios/2.0.0+6"
git -C "$fx_sq" tag "ios/2.0.0" "$sealed_sq"
git -C "$fx_sq" commit -q --allow-empty -m "ios: other commit"
git -C "$fx_sq" push -q -f origin "HEAD:refs/tags/ios/2.0.0"
sq_rc=0
sq_out="$(KG_ASC_SHIPPED_CMD="$fx_sq/asc-stub.sh" bash "$fx_sq/ops/release.sh" shipped ios --yes 2>&1)" || sq_rc=$?
[[ "$sq_rc" -ne 0 && "$sq_out" == *"origin ios/2.0.0"* ]] \
  && ok "shipped fails when origin shipped tag differs from local/ASC" \
  || fail_t "shipped accepted a divergent origin tag: $sq_out"

# 19e. 沒有對應 build tag（發版於本機制上線前）→ 明確說「沒有紀錄」，不猜。
fx_sn="$TMP5/shipped-norecord"; remote_sn="$TMP5/shipped-norecord.git"
make_shipped_fixture "$fx_sn" "$remote_sn" "2.0.0 6"
nr_rc=0
nr_out="$(KG_ASC_SHIPPED_CMD="$fx_sn/asc-stub.sh" bash "$fx_sn/ops/release.sh" shipped ios --yes 2>&1)" || nr_rc=$?
[[ "$nr_rc" -ne 0 && -z "$(git -C "$fx_sn" tag -l 'ios/2.0.0')" ]] \
  && grep -q -- '--commit' <<<"$nr_out" \
  && ok "missing build tag: refuses and offers the manual --commit escape hatch" \
  || fail_t "missing build tag was not actionably refused: $nr_out"

# 19f. --commit 人工覆寫可用，但必須把「這是人工斷言」印出來——它繞過的正是查證。
manual_sn="$(git -C "$fx_sn" rev-parse HEAD)"
man_rc=0
man_out="$(KG_ASC_SHIPPED_CMD="$fx_sn/asc-stub.sh" bash "$fx_sn/ops/release.sh" shipped ios --commit "$manual_sn" --yes 2>&1)" || man_rc=$?
[[ "$(git -C "$fx_sn" rev-parse 'refs/tags/ios/2.0.0^{commit}')" == "$manual_sn" ]] \
  && ok "--commit override lands the shipped tag" || fail_t "--commit override did not tag: $man_out"
grep -q '人工' <<<"$man_out" \
  && ok "--commit override announces it is a human assertion, not a verified join" \
  || fail_t "--commit override does not flag itself as manual: $man_out"

# 19g. ASC 查不到（斷網 / 憑證壞 / 無 READY_FOR_SALE）→ 硬停，不得降級成猜測。
fx_sf="$TMP5/shipped-ascfail"; remote_sf="$TMP5/shipped-ascfail.git"
make_shipped_fixture "$fx_sf" "$remote_sf" "" 1
git -C "$fx_sf" tag "ios/2.0.0+6"
af_rc=0
af_out="$(KG_ASC_SHIPPED_CMD="$fx_sf/asc-stub.sh" bash "$fx_sf/ops/release.sh" shipped ios --yes 2>&1)" || af_rc=$?
[[ "$af_rc" -ne 0 && -z "$(git -C "$fx_sf" tag -l 'ios/2.0.0')" ]] \
  && ok "ASC lookup failure refuses instead of falling back to a guess" \
  || fail_t "ASC failure produced a tag anyway: $af_out"

# 19h. ASC 回傳格式不合 → 同樣硬停（別把垃圾字串寫進 tag 名）。
fx_sg="$TMP5/shipped-garbage"; remote_sg="$TMP5/shipped-garbage.git"
make_shipped_fixture "$fx_sg" "$remote_sg" "not-a-version xyz"
gb_rc=0
gb_out="$(KG_ASC_SHIPPED_CMD="$fx_sg/asc-stub.sh" bash "$fx_sg/ops/release.sh" shipped ios --yes 2>&1)" || gb_rc=$?
[[ "$gb_rc" -ne 0 && -z "$(git -C "$fx_sg" tag -l 'ios/*' | grep -v '+' || true)" ]] \
  && ok "malformed ASC response is rejected before any tag is written" \
  || fail_t "malformed ASC response was accepted: $gb_out"

# ── 20. resubmit ios：同版號、新 build 的重送 ───────────────────────────────
# 這條路徑（bump-build + ios_release.sh --upload）原本**完全不留任何紀錄**——沒有
# commit、沒有 tag，這正是 ios/2.0.0 指向 build 5 而實際上架 build 6 的成因。
# 它現在和 release 對稱：upload 成功才封版，失敗不留 false marker。
section "resubmit ios seals the same-version rebuild"

# 20a. dry-run 預設：不 upload、不改檔，且要印出將產生的 build number。
fx_r="$TMP5/resubmit"; remote_r="$TMP5/resubmit.git"
make_ios_release_fixture "$fx_r" "$remote_r"
head_r="$(git -C "$fx_r" rev-parse HEAD)"
rdry_rc=0
rdry="$(bash "$fx_r/ops/release.sh" resubmit ios 2>&1)" || rdry_rc=$?
[[ "$rdry_rc" -eq 0 && ! -e "$fx_r/upload.called" ]] \
  && ok "resubmit dry-run exits 0 without uploading" || fail_t "resubmit dry-run misbehaved: $rdry"
grep -q 'CURRENT_PROJECT_VERSION = 5;' "$fx_r/ios/BooksAndVocab.xcodeproj/project.pbxproj" \
  && ok "resubmit dry-run leaves pbxproj untouched" || fail_t "resubmit dry-run wrote pbxproj"
grep -q 'ios/2.0.0+6' <<<"$rdry" \
  && ok "resubmit dry-run names the build tag it will create" \
  || fail_t "resubmit dry-run does not preview the build tag: $rdry"

# 20a.1. ASC latest is a remote SoT, not an advisory. If local build 5 has
# already been followed by TestFlight build 8, the next safe build is 9.
fx_rd="$TMP5/resubmit-asc-drift"; remote_rd="$TMP5/resubmit-asc-drift.git"
make_ios_release_fixture "$fx_rd" "$remote_rd"
head_rd="$(git -C "$fx_rd" rev-parse HEAD)"
rdry_drift_rc=0
rdry_drift="$(ASC_LATEST_BUILD=8 bash "$fx_rd/ops/release.sh" resubmit ios 2>&1)" || rdry_drift_rc=$?
[[ "$rdry_drift_rc" -eq 0 && ! -e "$fx_rd/upload.called" \
   && "$(grep -c 'CURRENT_PROJECT_VERSION = 5;' "$fx_rd/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 ]] \
  && ok "resubmit dry-run does not mutate under ASC drift" \
  || fail_t "ASC-drift dry-run mutated or failed: $rdry_drift"
grep -q 'ASC TestFlight latest=8' <<<"$rdry_drift" \
  && ok "resubmit dry-run prints the ASC latest build" \
  || fail_t "resubmit dry-run hides ASC latest build: $rdry_drift"
grep -q 'build 5 → 9' <<<"$rdry_drift" && grep -q 'ios/2.0.0+9' <<<"$rdry_drift" \
  && ok "ASC drift dry-run selects max(local, ASC)+1" \
  || fail_t "ASC drift dry-run still selects local+1: $rdry_drift"

rdres_drift_rc=0
rdres_drift="$(ASC_LATEST_BUILD=8 bash "$fx_rd/ops/release.sh" resubmit ios --yes 2>&1)" || rdres_drift_rc=$?
sealed_rd="$(git -C "$fx_rd" rev-parse HEAD)"
[[ "$rdres_drift_rc" -eq 0 && ! -e "$fx_rd/upload.called" \
   && "$(grep -c 'CURRENT_PROJECT_VERSION = 9;' "$fx_rd/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 \
   && "$(git -C "$fx_rd" log -1 --format=%s)" == "ops: prepare ios 2.0.0 build 9" \
   && -z "$(git -C "$fx_rd" tag -l 'ios/2.0.0+9')" \
   && -z "$(git --git-dir="$remote_rd" tag -l 'ios/2.0.0+9')" ]] \
  && ok "ASC drift resubmit preserves build-9 candidate provenance" \
  || fail_t "ASC drift resubmit did not create build-9 candidate: $rdres_drift"

# ASC failure or malformed latest build must stop before the local bump and
# irreversible upload; no fallback to local+1 is allowed.
fx_rbad="$TMP5/resubmit-asc-bad"; remote_rbad="$TMP5/resubmit-asc-bad.git"
make_ios_release_fixture "$fx_rbad" "$remote_rbad"
head_rbad="$(git -C "$fx_rbad" rev-parse HEAD)"
rbad_rc=0
rbad_out="$(ASC_BUILDS_EXIT=23 bash "$fx_rbad/ops/release.sh" resubmit ios --yes 2>&1)" || rbad_rc=$?
[[ "$rbad_rc" -ne 0 && "$(git -C "$fx_rbad" rev-parse HEAD)" == "$head_rbad" \
   && -z "$(git -C "$fx_rbad" tag -l 'ios/2.0.0+*')" \
   && ! -e "$fx_rbad/upload.called" ]] \
  && ok "ASC latest lookup failure stops before bump/upload/tag" \
  || fail_t "ASC latest lookup failure mutated release state: $rbad_out"

fx_rmal="$TMP5/resubmit-asc-malformed"; remote_rmal="$TMP5/resubmit-asc-malformed.git"
make_ios_release_fixture "$fx_rmal" "$remote_rmal"
head_rmal="$(git -C "$fx_rmal" rev-parse HEAD)"
rmal_rc=0
rmal_out="$(ASC_LATEST_BUILD=not-a-number bash "$fx_rmal/ops/release.sh" resubmit ios --yes 2>&1)" || rmal_rc=$?
[[ "$rmal_rc" -ne 0 && "$(git -C "$fx_rmal" rev-parse HEAD)" == "$head_rmal" \
   && ! -e "$fx_rmal/upload.called" ]] \
  && grep -q 'ASC' <<<"$rmal_out" \
  && ok "malformed ASC latest build is refused before mutation" \
  || fail_t "malformed ASC latest build was not fail-closed: $rmal_out"

# 20b. --yes：build +1、marketing 不動、封 ios/2.0.0+6，且不得產生上架 tag。
rres_rc=0
rres="$(bash "$fx_r/ops/release.sh" resubmit ios --yes 2>&1)" || rres_rc=$?
sealed_r="$(git -C "$fx_r" rev-parse HEAD)"
[[ "$rres_rc" -eq 0 && ! -e "$fx_r/upload.called" ]] \
  && ok "resubmit creates candidate without upload" || fail_t "resubmit candidate failed: $rres"
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 6;' "$fx_r/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 \
   && "$(grep -c 'MARKETING_VERSION = 2.0.0;' "$fx_r/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 ]] \
  && ok "resubmit bumps build only, marketing version untouched" \
  || fail_t "resubmit changed the marketing version"
[[ "$sealed_r" != "$head_r" \
   && -z "$(git -C "$fx_r" tag -l 'ios/2.0.0+6')" \
   && -z "$(git --git-dir="$remote_r" tag -l 'ios/2.0.0+6')" ]] \
  && ok "resubmit leaves build tag for merged finalize" \
  || fail_t "resubmit crossed tag boundary: $rres"
# 上架 tag 必須還是原本那顆：重送不代表上架。
[[ "$(git -C "$fx_r" rev-parse 'refs/tags/ios/2.0.0^{commit}')" == "$head_r" ]] \
  && ok "resubmit does not touch the shipped tag" || fail_t "resubmit moved ios/2.0.0"

# 20c. upload 失敗 → 保留 candidate provenance，但不留 false build tag；
#      recovery 必須只 finalize，不得再次產生 build 或隱式 upload。
fx_rf="$TMP5/resubmit-failure"; remote_rf="$TMP5/resubmit-failure.git"
make_ios_release_fixture "$fx_rf" "$remote_rf"
head_rf="$(git -C "$fx_rf" rev-parse HEAD)"
rf_rc=0
rf_out="$(STUB_UPLOAD_EXIT=23 bash "$fx_rf/ops/release.sh" resubmit ios --yes 2>&1)" || rf_rc=$?
candidate_rf="$(git -C "$fx_rf" rev-parse HEAD)"
[[ "$rf_rc" -eq 0 && ! -e "$fx_rf/upload.called" \
   && "$candidate_rf" != "$head_rf" \
   && ! -e "$fx_rf/upload.count" \
   && "$(git -C "$fx_rf" log -1 --format=%s)" == "ops: prepare ios 2.0.0 build 6" \
   && -z "$(git -C "$fx_rf" tag -l 'ios/2.0.0+6')" \
   && -z "$(git --git-dir="$remote_rf" tag -l 'ios/2.0.0+6')" \
   && "$(git --git-dir="$remote_rf" rev-parse refs/heads/main)" != "$candidate_rf" ]] \
  && ok "resubmit candidate remains recoverable without main/upload side effects" \
  || fail_t "resubmit did not preserve candidate boundary: $rf_out"
rf_finalize_rc=0
rf_finalize_out="$(bash "$fx_rf/ops/release.sh" finalize ios 2.0.0 6 --yes 2>&1)" || rf_finalize_rc=$?
[[ "$rf_finalize_rc" -ne 0 && "$rf_finalize_out" == *"exact --pr"* \
   && ! -e "$fx_rf/upload.called" ]] \
  && ok "resubmit finalize refuses before exact PR/source evidence" \
  || fail_t "resubmit finalize crossed the evidence gate: $rf_finalize_out"

# 20d. api 拒絕，且指路。
ra_rc=0
ra_out="$(bash "$fx_r/ops/release.sh" resubmit api --yes 2>&1)" || ra_rc=$?
[[ "$ra_rc" -ne 0 ]] && grep -q 'ios' <<<"$ra_out" \
  && ok "resubmit api is rejected with guidance" || fail_t "resubmit api not rejected: $ra_out"

# 20e. Candidate lane is the supported execution surface; main is reserved for
# post-queue resume/finalize, so this fixture explicitly proves no main-only path.
git -C "$fx_r" checkout -q -b side
rb_rc=0
rb_out="$(bash "$fx_r/ops/release.sh" resubmit ios --yes 2>&1)" || rb_rc=$?
[[ "$rb_rc" -ne 0 ]] && grep -q '未 finalize' <<<"$rb_out" \
  && ok "resubmit does not bypass a pending candidate on another lane" || fail_t "resubmit bypassed pending candidate: $rb_out"
git -C "$fx_r" checkout -q main

# ── 21. status 說實話：ios 專案版號 / build tag 對照；api 是否真的上生產 ────
# 舊 status 對 ios 只印「上個 tag」與「檔內版本」，兩者都是 2.0.0 → 報「無漂移」，
# 而那顆 tag 其實指著沒上架的 build 5 的 commit。版號字串相等不代表 tag 指對地方。
section "status reports build-level truth, not just version strings"

make_status_fixture() {  # $1=fixture  $2=marketing  $3=build
  mkdir -p "$1/ops/lib" "$1/ios/BooksAndVocab.xcodeproj" "$1/backend/src/kg"
  cp "$REL" "$1/ops/"
  cp "$WORKSPACE/ops/lib/release_tags.sh" "$1/ops/lib/"
  cat > "$1/ios/BooksAndVocab.xcodeproj/project.pbxproj" <<PBX
MARKETING_VERSION = $2; CURRENT_PROJECT_VERSION = $3;
MARKETING_VERSION = $2; CURRENT_PROJECT_VERSION = $3;
PBX
  printf '[project]\nversion = "2.0.1"\n' > "$1/backend/pyproject.toml"
  git init -q -b main "$1"
  git -C "$1" config user.name "Release Test"
  git -C "$1" config user.email "release-test@example.invalid"
  git -C "$1" add .
  git -C "$1" commit -qm "ios: fixture"
}

# 21a. 專案當下的 (version, build) 沒有 build tag → 具名警告。
#      這是「這顆 build 沒被記錄」的唯一徵兆；沉默的話它就會像 2.0.0 那樣事後才被發現。
fx_st="$TMP5/status-nobuildtag"
make_status_fixture "$fx_st" 2.0.0 6
git -C "$fx_st" tag ios/2.0.0
st_out="$(bash "$fx_st/ops/release.sh" status 2>&1)"
grep -q 'MARKETING_VERSION=2.0.0' <<<"$st_out" && grep -q 'CURRENT_PROJECT_VERSION=6' <<<"$st_out" \
  && ok "status prints the project's marketing version and build number" \
  || fail_t "status does not print (version, build): $st_out"
grep -q 'ios/2.0.0+6' <<<"$st_out" \
  && ok "status names the missing build tag for the current (version, build)" \
  || fail_t "status is silent about the unrecorded build: $st_out"

# 21b. build tag 存在 → 列出對照，且不再警告「沒有紀錄」。
fx_st2="$TMP5/status-buildtags"
make_status_fixture "$fx_st2" 2.0.0 6
sealed_st="$(git -C "$fx_st2" rev-parse HEAD)"
git -C "$fx_st2" tag ios/2.0.0
git -C "$fx_st2" tag "ios/2.0.0+5"
git -C "$fx_st2" tag "ios/2.0.0+6"
st2_out="$(bash "$fx_st2/ops/release.sh" status 2>&1)"
grep -q 'ios/2.0.0+5' <<<"$st2_out" && grep -q 'ios/2.0.0+6' <<<"$st2_out" \
  && ok "status lists the known build tags" || fail_t "status does not list build tags: $st2_out"
grep -q '沒有 build tag' <<<"$st2_out" \
  && fail_t "status warns about a missing build tag that actually exists: $st2_out" \
  || ok "status does not warn when the current build is recorded"

# 21c. api：latest api/<ver> tag 是否已是 origin/prod 的祖先（= 該版號是否真的上生產）。
fx_sp="$TMP5/status-prod"
make_status_fixture "$fx_sp" 2.0.0 6
git -C "$fx_sp" tag api/2.0.1
prod_base="$(git -C "$fx_sp" rev-parse HEAD)"
git -C "$fx_sp" update-ref refs/remotes/origin/prod "$prod_base"
sp_out="$(bash "$fx_sp/ops/release.sh" status 2>&1)"
grep -q 'api/2.0.1 已在 origin/prod' <<<"$sp_out" \
  && ok "status says the api tag is already on origin/prod" \
  || fail_t "status does not report api tag→prod ancestry: $sp_out"
# 反向：prod 落後於 tag 時必須改口，否則上面那條可能是恆真字串。
git -C "$fx_sp" commit -q --allow-empty -m "api: after prod"
git -C "$fx_sp" tag -d api/2.0.1 >/dev/null
git -C "$fx_sp" tag api/2.0.1
sp2_out="$(bash "$fx_sp/ops/release.sh" status 2>&1)"
grep -q 'api/2.0.1 尚未進 origin/prod' <<<"$sp2_out" \
  && ok "status flips to 尚未進 origin/prod when the tag is not deployed" \
  || fail_t "status reports prod ancestry as a constant: $sp2_out"

# ── 22. pending 版本的上界（review 找到） ───────────────────────────────────
section "pending-version bounds"

# 22b. 高於本次版本的 build tag 不是「被跳過的版本」。把它算進 pending，會用 2.0.1
#      事故的說詞去擋一件根本沒發生的事。
fx_ub="$TMP5/pending-upper"; remote_ub="$TMP5/pending-upper.git"
make_ios_release_fixture "$fx_ub" "$remote_ub"
git -C "$fx_ub" tag "ios/3.0.0+1"          # 另一條線的實驗性 build，與本次無關
ub_rc=0
ub_out="$(bash "$fx_ub/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || ub_rc=$?
[[ "$ub_rc" -eq 0 && ! -e "$fx_ub/upload.called" \
   && "$(git -C "$fx_ub" log -1 --format=%s)" == "ops: prepare ios 2.0.1 build 6" \
   && -z "$(git -C "$fx_ub" tag -l 'ios/2.0.1+6')" ]] \
  && ok "a build tag above the requested version does not block the candidate" \
  || fail_t "3.0.0 build tag blocked an unrelated 2.0.1 release: $ub_out"

# ── 部署收斂閘：release backend 的第四步 ─────────────────────────────────────
# 這段是**行為**測試（真的執行函式），與本檔其餘結構測試並存；所有 case 都在同一個
# release regression entrypoint 執行，避免只驗文字而漏掉實際行為。
#
# 被測的是 d156c6c28 加的收斂閘：deploy 只保證 origin/prod 前進，真正的部署由 felix
# reconciler 非同步做且失敗會自動回滾，所以「什麼時候可以說成功」必須被釘住。
section "Deploy convergence gate (release backend 第四步)"

TMP6="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$TMP4" "$TMP5" "$TMP6"' EXIT

# curl stub：每次呼叫吃 responses 檔的下一行 `CODE|BODY`，用完停在最後一行。
conv_stub() {
  local name="$1"; shift
  local resp="$TMP6/resp_$name" script="$TMP6/curl_$name.sh" cursor="$TMP6/cur_$name"
  printf '%s\n' "$@" > "$resp"; echo 0 > "$cursor"
  cat >"$script" <<STUB
#!/usr/bin/env bash
i=\$(cat "$cursor"); n=\$(wc -l < "$resp" | tr -d ' ')
i=\$(( i + 1 )); (( i > n )) && i=\$n
echo "\$i" > "$cursor"
line="\$(sed -n "\${i}p" "$resp")"
printf '%s\n%s' "\${line#*|}" "\${line%%|*}"
STUB
  chmod +x "$script"; printf '%s' "$script"
}

# 在乾淨子 shell 內 source release.sh 取純函式（本檔自身帶 set -e，故子 shell 內關掉，
# 讓「預期失敗」的 case 能被斷言而不是中止測試）。
conv_run() { CURL_BIN="$1" KG_RELEASE_POLL_SECS=1 KG_RELEASE_WAIT_SECS="$2" \
             bash -c "source '$REL'; set +e; $3" 2>&1; }

# source 本身不得觸發 dispatcher（BASH_SOURCE guard 在，才有上面這些 case）
guard_rc=0; guard_out="$(bash -c "source '$REL'" 2>&1)" || guard_rc=$?
[[ $guard_rc -eq 0 && -z "$guard_out" ]] \
  && ok "source release.sh 不執行 dispatcher（BASH_SOURCE guard）" \
  || fail_t "source release.sh 有輸出/非零：rc=$guard_rc out=${guard_out:0:120}"

# paths_trigger_rollout：委派 reconciler 的正則，不另寫一份。「只有 docs／ios」那兩條
# 鎖住 orchestrate 的 `backend/` 前綴超集不能決定等不等。uv.lock 自 #2088 起 reconciler
# 會 rebuild（Dockerfile 依它安裝），所以 lock-only 範圍必須等 rollout；期望值跟著正則走。
conv_paths() {  # <label> <yes|no> <paths...>
  local label="$1" expect="$2"; shift 2
  local got
  got="$(conv_run "" 5 "printf '%s\n' $(printf '%q ' "$@") | paths_trigger_rollout && echo yes || echo no")"
  [[ "$got" == "$expect" ]] && ok "paths_trigger_rollout: $label → $expect" \
                            || fail_t "paths_trigger_rollout: $label → 得到 '$got'，期望 $expect"
}
conv_paths "backend/src"          yes backend/src/kg/api.py
conv_paths "backend/tests"        yes backend/tests/test_x.py
conv_paths "pyproject（版號 bump）" yes backend/pyproject.toml
conv_paths "只有 uv.lock（#2088）"  yes backend/uv.lock
conv_paths "只有 docs"             no  docs/sop/release.md
conv_paths "只有 ios"              no  ios/BooksAndVocab/App.swift
conv_paths "uv.lock + src 混合"     yes backend/uv.lock backend/src/kg/api.py

# live_version：抽不到一律空字串（空 ≠ 收斂），不猜
got="$(conv_run "$(conv_stub ok200 '200|{"version":"0c9e3b7c"}')" 5 'live_version')"
[[ "$got" == "0c9e3b7c" ]] && ok "live_version: 200 抽出 version" || fail_t "live_version: 200 得到 '$got'"
got="$(conv_run "$(conv_stub e500 '500|upstream error')" 5 'live_version')"
[[ -z "$got" ]] && ok "live_version: 500 → 空字串" || fail_t "live_version: 500 得到 '$got'"
got="$(conv_run "$(conv_stub e000 '000|')" 5 'live_version')"
[[ -z "$got" ]] && ok "live_version: 不可達 → 空字串" || fail_t "live_version: 不可達得到 '$got'"

CONV_WANT=da0f51f32aabbccddeeff00112233445566778899

rc=0; out="$(conv_run "$(conv_stub hit '200|{"version":"da0f51f32"}')" 5 "wait_for_rollout $CONV_WANT")" || rc=$?
[[ $rc -eq 0 ]] && ok "wait_for_rollout: 線上已是目標 sha → rc 0" \
                || fail_t "wait_for_rollout: 已收斂卻 rc=${rc}（${out}）"

rc=0; out="$(conv_run "$(conv_stub miss '200|{"version":"0c9e3b7c"}')" 2 "wait_for_rollout $CONV_WANT")" || rc=$?
[[ $rc -ne 0 ]] && ok "wait_for_rollout: 停在舊 sha 到逾時 → 非零（不謊報成功）" \
                || fail_t "wait_for_rollout: 未收斂卻 rc=0 —— 這正是本閘存在的理由"
grep -q 'kg_reconcile.err.log' <<<"$out" && ok "逾時輸出指向 reconciler log（可行動）" \
                                         || fail_t "逾時輸出沒說去哪看真相：$out"
grep -q '0c9e3b7c' <<<"$out" && ok "逾時輸出帶上實際觀測到的線上版本" \
                             || fail_t "逾時輸出沒說線上目前是什麼版本"

# 負控：沒有 7 字元下限的話，任何回傳 "d" 的壞掉端點都會命中以 d 開頭的 sha
rc=0; out="$(conv_run "$(conv_stub short '200|{"version":"d"}')" 2 "wait_for_rollout $CONV_WANT")" || rc=$?
[[ $rc -ne 0 ]] && ok "過短字串不算 prefix 命中（壞掉 ≠ 收斂）" \
                || fail_t "'d' 被當成 $CONV_WANT 的前綴 —— 假綠"

rc=0; out="$(conv_run "$(conv_stub building '200|{"version":"0c9e3b7c"}' '200|{"version":"0c9e3b7c"}' '200|{"version":"da0f51f32"}')" 8 "wait_for_rollout $CONV_WANT")" || rc=$?
[[ $rc -eq 0 ]] && ok "build 中先舊後新 → 最終 rc 0（不早退）" \
                || fail_t "先舊後新卻 rc=${rc}（${out}）"

# 找不到 reconciler 時必須 err，不得靜默當成「不用等」
fx_norecon="$TMP6/norecon"; mkdir -p "$fx_norecon/ops"
cp "$REL" "$fx_norecon/ops/release.sh"
cp -R "$WORKSPACE/ops/lib" "$fx_norecon/ops/lib"
rc=0; out="$(bash -c "source '$fx_norecon/ops/release.sh'; set +e; echo backend/src/a.py | paths_trigger_rollout" 2>&1)" || rc=$?
[[ $rc -ne 0 ]] && ok "kg_reconcile.sh 不存在 → err，不靜默降級成「不用等」" \
                || fail_t "reconciler 缺席卻靜默回答（rc=${rc}）：$out"

# ── 23. protected-main / native queue / deterministic resume（additive） ─────
# These cases are additive. The historical regression corpus above is retained
# intact. The pre-receive hook is the policy-rejecting remote; update-ref is
# only the fixture stand-in for a native merge queue completing a reviewed PR.
section "Protected-main queue state machine and recovery"

make_policy_rejecting_remote() {
  local remote="$1"
  cat > "$remote/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "$ref" == refs/heads/main ]]; then
    echo "policy fixture: protected main rejects direct update" >&2
    exit 1
  fi
done
exit 0
HOOK
  chmod +x "$remote/hooks/pre-receive"
}

queue_merge_fixture() {
  local fixture="$1" remote="$2" candidate="$3"
  # Native queue/admin merge fixture; release.sh never uses this bypass.
  git -C "$fixture" push -q origin "$candidate:refs/heads/queue-fixture"
  git --git-dir="$remote" update-ref refs/heads/main "$candidate"
  git -C "$fixture" fetch -q origin main
  git -C "$fixture" checkout -q main
  git -C "$fixture" reset -q --hard origin/main
}

# 23a. Dedicated-lane iOS release: candidate only, no upload and no main push.
fx_q="$TMP6/protected-ios"; remote_q="$TMP6/protected-ios.git"
make_ios_release_fixture "$fx_q" "$remote_q"
make_policy_rejecting_remote "$remote_q"
git -C "$fx_q" checkout -q -b feat/release-queue
q_base="$(git --git-dir="$remote_q" rev-parse refs/heads/main)"
q_dry_rc=0; q_dry_out="$(bash "$fx_q/ops/release.sh" release ios 2.0.1 2>&1)" || q_dry_rc=$?
[[ $q_dry_rc -eq 0 && "$q_dry_out" == *"hand-back"* && ! -e "$fx_q/upload.called" \
   && "$(git --git-dir="$remote_q" rev-parse refs/heads/main)" == "$q_base" ]] \
  && ok "iOS candidate dry-run is lane-only and preserves protected main" \
  || fail_t "iOS candidate dry-run crossed a boundary: $q_dry_out"
q_rc=0; q_out="$(bash "$fx_q/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || q_rc=$?
q_candidate="$(git -C "$fx_q" rev-parse HEAD)"
[[ $q_rc -eq 0 && "$q_candidate" != "$q_base" \
   && "$(git -C "$fx_q" log -1 --format=%s)" == "ops: prepare ios 2.0.1 build 6" \
   && "$q_out" == *"hand-back"* && ! -e "$fx_q/upload.called" \
   && "$(git --git-dir="$remote_q" rev-parse refs/heads/main)" == "$q_base" ]] \
  && ok "iOS --yes emits one recoverable candidate without main push/upload" \
  || fail_t "iOS candidate mutated protected main or uploaded: $q_out"

# 23a.1. A feature branch is only a release lane when it is exactly based on
# live origin/main.  Otherwise a clean branch can smuggle unmerged product
# commits (ahead) or a stale release base (behind) into the candidate PR.
fx_lane_ahead="$TMP6/release-lane-ahead"; remote_lane_ahead="$TMP6/release-lane-ahead.git"
make_ios_release_fixture "$fx_lane_ahead" "$remote_lane_ahead"
git -C "$fx_lane_ahead" checkout -q -b feat/release-queue
lane_ahead_base="$(git --git-dir="$remote_lane_ahead" rev-parse refs/heads/main)"
git -C "$fx_lane_ahead" commit --allow-empty -qm "fixture: unmerged product change"
lane_ahead_head="$(git -C "$fx_lane_ahead" rev-parse HEAD)"
lane_ahead_rc=0
lane_ahead_out="$(bash "$fx_lane_ahead/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || lane_ahead_rc=$?
[[ $lane_ahead_rc -ne 0 \
   && "$lane_ahead_out" == *"exact live origin/main"* \
   && "$(git -C "$fx_lane_ahead" rev-parse HEAD)" == "$lane_ahead_head" \
   && "$(grep -c 'CURRENT_PROJECT_VERSION = 5;' "$fx_lane_ahead/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 \
   && ! -e "$fx_lane_ahead/upload.called" \
   && "$(git --git-dir="$remote_lane_ahead" rev-parse refs/heads/main)" == "$lane_ahead_base" ]] \
  && ok "release refuses a lane ahead of live main before candidate mutation" \
  || fail_t "release accepted an ahead/stale lane: $lane_ahead_out"

fx_lane_behind="$TMP6/release-lane-behind"; remote_lane_behind="$TMP6/release-lane-behind.git"
make_ios_release_fixture "$fx_lane_behind" "$remote_lane_behind"
git -C "$fx_lane_behind" checkout -q -b feat/release-queue
lane_behind_base="$(git -C "$fx_lane_behind" rev-parse HEAD)"
git -C "$fx_lane_behind" commit --allow-empty -qm "fixture: newer live main"
lane_behind_live="$(git -C "$fx_lane_behind" rev-parse HEAD)"
git -C "$fx_lane_behind" checkout -q -B feat/release-queue "$lane_behind_base"
git -C "$fx_lane_behind" push -q origin "$lane_behind_live:refs/heads/queue-fixture"
git --git-dir="$remote_lane_behind" update-ref refs/heads/main "$lane_behind_live"
lane_behind_rc=0
lane_behind_out="$(bash "$fx_lane_behind/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || lane_behind_rc=$?
[[ $lane_behind_rc -ne 0 \
   && "$lane_behind_out" == *"exact live origin/main"* \
   && "$(git -C "$fx_lane_behind" rev-parse HEAD)" == "$lane_behind_base" \
   && "$(grep -c 'CURRENT_PROJECT_VERSION = 5;' "$fx_lane_behind/ios/BooksAndVocab.xcodeproj/project.pbxproj" || true)" -eq 2 \
   && ! -e "$fx_lane_behind/upload.called" \
   && "$(git --git-dir="$remote_lane_behind" rev-parse refs/heads/main)" == "$lane_behind_live" ]] \
  && ok "release refuses a lane behind live main before candidate mutation" \
  || fail_t "release accepted a behind/stale lane: $lane_behind_out"

# 23b. Live merged tuple blocks a second build candidate (fixture equivalent
# of the supplied merged build-12 evidence).
fx_dup="$TMP6/duplicate-tuple"; remote_dup="$TMP6/duplicate-tuple.git"
make_ios_release_fixture "$fx_dup" "$remote_dup"
perl -pi -e 's/MARKETING_VERSION = 2.0.0;/MARKETING_VERSION = 2.0.1;/g; s/CURRENT_PROJECT_VERSION = 5;/CURRENT_PROJECT_VERSION = 12;/g' \
  "$fx_dup/ios/BooksAndVocab.xcodeproj/project.pbxproj"
git -C "$fx_dup" add ios/BooksAndVocab.xcodeproj/project.pbxproj
git -C "$fx_dup" commit -qm "fixture: merged ios 2.0.1 build 12"
dup_live="$(git -C "$fx_dup" rev-parse HEAD)"
git -C "$fx_dup" push -q origin "$dup_live:refs/heads/queue-fixture"
git --git-dir="$remote_dup" update-ref refs/heads/main "$dup_live"
git -C "$fx_dup" checkout -q -b feat/release-queue
dup_head="$(git -C "$fx_dup" rev-parse HEAD)"
dup_rc=0; dup_out="$(bash "$fx_dup/ops/release.sh" release ios 2.0.1 --yes 2>&1)" || dup_rc=$?
[[ $dup_rc -ne 0 && "$dup_out" == *"已包含 iOS tuple"* \
   && "$(git -C "$fx_dup" rev-parse HEAD)" == "$dup_head" \
   && ! -e "$fx_dup/upload.called" ]] \
  && ok "merged target tuple blocks duplicate build candidate" \
  || fail_t "duplicate tuple was not refused idempotently: $dup_out"

# 23c. Exact PR/source receipt + ASC miss: upload once, no tag; retry the same
# merged source after exact ASC proof, without a second upload.
fx_rec="$TMP6/resume-recovery"; remote_rec="$TMP6/resume-recovery.git"
make_ios_release_fixture "$fx_rec" "$remote_rec"
git -C "$fx_rec" checkout -q -b feat/release-queue
bash "$fx_rec/ops/release.sh" release ios 2.0.1 --yes >/dev/null
rec_source="$(git -C "$fx_rec" rev-parse HEAD)"
queue_merge_fixture "$fx_rec" "$remote_rec" "$rec_source"
rec_base="$(git -C "$fx_rec" rev-parse "${rec_source}^")"
mkdir -p "$fx_rec/.git/pr-fixture"
cat > "$fx_rec/.git/pr-fixture/pr.json" <<JSON
{"number":1590,"state":"MERGED","baseRefName":"main","baseRefOid":"${rec_base}","headRefOid":"${rec_source}","mergeCommit":{"oid":"${rec_source}"}}
JSON
cat > "$fx_rec/.git/pr-fixture/pr-stub.sh" <<'STUB'
#!/usr/bin/env bash
cat "$(dirname "$0")/pr.json"
STUB
chmod +x "$fx_rec/.git/pr-fixture/pr-stub.sh"
rec_dry_rc=0; rec_dry_out="$(bash "$fx_rec/ops/release.sh" resume ios 2.0.1 6 2>&1)" || rec_dry_rc=$?
[[ $rec_dry_rc -ne 0 && "$rec_dry_out" == *"exact --pr"* \
   && ! -e "$fx_rec/upload.called" ]] \
  && ok "resume requires exact PR/source before its dry-run" \
  || fail_t "resume dry-run did not fail closed or was not side-effect free: $rec_dry_out"
rec_valid_dry_rc=0; rec_valid_dry_out="$(KG_PR_CMD="$fx_rec/.git/pr-fixture/pr-stub.sh" \
  bash "$fx_rec/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$rec_source" 2>&1)" || rec_valid_dry_rc=$?
[[ $rec_valid_dry_rc -eq 0 && "$rec_valid_dry_out" == *"未 upload、未建立 tag"* \
   && ! -e "$fx_rec/upload.called" ]] \
  && ok "resume exact PR/source dry-run is side-effect free" \
  || fail_t "resume exact-evidence dry-run failed: $rec_valid_dry_out"
rec_probe_rc=0; rec_probe_out="$(ASC_EXACT_BUILD_EXIT=1 KG_RELEASE_ASC_WAIT_SECS=0 \
  KG_PR_CMD="$fx_rec/.git/pr-fixture/pr-stub.sh" bash "$fx_rec/ops/release.sh" resume ios 2.0.1 6 \
  --pr 1590 --merged-source "$rec_source" --yes 2>&1)" || rec_probe_rc=$?
[[ $rec_probe_rc -ne 0 && "$rec_probe_out" == *"ASC exact build lookup 失敗（exit 1）"* \
   && ! -e "$fx_rec/upload.called" ]] \
  && ok "resume surfaces a failing ASC probe's error and does not upload" \
  || fail_t "resume swallowed the ASC probe error or uploaded: $rec_probe_out"
rec_first_rc=0; rec_first_out="$(ASC_EXACT_BUILD_EXIT=3 KG_RELEASE_ASC_WAIT_SECS=0 \
  KG_PR_CMD="$fx_rec/.git/pr-fixture/pr-stub.sh" bash "$fx_rec/ops/release.sh" resume ios 2.0.1 6 \
  --pr 1590 --merged-source "$rec_source" --yes 2>&1)" || rec_first_rc=$?
[[ $rec_first_rc -ne 0 && -e "$fx_rec/upload.called" \
   && "$(<"$fx_rec/upload.count")" == 1 \
   && -z "$(git --git-dir="$remote_rec" tag -l 'ios/2.0.1+6')" ]] \
  && ok "ASC miss retains merged candidate after exactly one upload" \
  || fail_t "ASC-miss recovery did not retain state: $rec_first_out"
rec_second_rc=0; rec_second_out="$(KG_PR_CMD="$fx_rec/.git/pr-fixture/pr-stub.sh" \
  bash "$fx_rec/ops/release.sh" resume ios 2.0.1 6 \
  --pr 1590 --merged-source "$rec_source" --yes 2>&1)" || rec_second_rc=$?
[[ $rec_second_rc -eq 0 && "$(<"$fx_rec/upload.count")" == 1 \
   && "$(git --git-dir="$remote_rec" rev-parse 'refs/tags/ios/2.0.1+6^{commit}')" == "$rec_source" \
   && "$rec_second_out" == *"tag-only"* ]] \
  && ok "resume is deterministic: exact ASC proof seals without duplicate upload" \
  || fail_t "resume duplicated upload or failed to seal: $rec_second_out"

# 23d. Backend release uses the same protected-main candidate boundary; this
# fixture copies version files only and does not deploy.
fx_api="$TMP6/protected-api"; remote_api="$TMP6/protected-api.git"
make_ios_release_fixture "$fx_api" "$remote_api"
mkdir -p "$fx_api/backend/src/kg"
cp "$WORKSPACE/backend/pyproject.toml" "$fx_api/backend/pyproject.toml"
cp "$WORKSPACE/backend/src/kg/api.py" "$fx_api/backend/src/kg/api.py"
cp "$WORKSPACE/backend/uv.lock" "$fx_api/backend/uv.lock"
git -C "$fx_api" add backend
git -C "$fx_api" commit -qm "fixture: backend baseline"
git -C "$fx_api" push -q origin "$(git -C "$fx_api" rev-parse HEAD):refs/heads/queue-fixture"
git --git-dir="$remote_api" update-ref refs/heads/main "$(git -C "$fx_api" rev-parse HEAD)"
make_policy_rejecting_remote "$remote_api"
git -C "$fx_api" checkout -q -b feat/release-queue
api_base="$(git --git-dir="$remote_api" rev-parse refs/heads/main)"
api_rc=0; api_out="$(bash "$fx_api/ops/release.sh" release backend 2.0.4 --yes 2>&1)" || api_rc=$?
[[ $api_rc -eq 0 && "$api_out" == *"hand-back"* \
   && "$(git --git-dir="$remote_api" rev-parse refs/heads/main)" == "$api_base" \
   && ! -e "$fx_api/upload.called" ]] \
  && ok "backend release emits a candidate without direct main push/deploy" \
  || fail_t "backend release crossed protected-main boundary: $api_out"

if ! rg -n 'git .*push .*origin (main|.* main)|push --atomic .*main' "$REL" >/dev/null; then
  ok "release implementation has no direct origin/main push path"
else
  fail_t "release implementation still contains a direct origin/main push path"
fi
grep -q 'resume)' "$REL" \
  && ok "dispatcher exposes resume state" \
  || fail_t "dispatcher has no resume state"

# 23e. resubmit is also a dedicated-lane candidate operation: it must not
# upload or update protected main before the IM/PR/queue handback.
fx_rs="$TMP6/protected-resubmit"; remote_rs="$TMP6/protected-resubmit.git"
make_ios_release_fixture "$fx_rs" "$remote_rs"
make_policy_rejecting_remote "$remote_rs"
git -C "$fx_rs" checkout -q -b feat/release-queue
rs_base="$(git --git-dir="$remote_rs" rev-parse refs/heads/main)"
rs_rc=0; rs_out="$(bash "$fx_rs/ops/release.sh" resubmit ios --yes 2>&1)" || rs_rc=$?
rs_candidate="$(git -C "$fx_rs" rev-parse HEAD)"
[[ $rs_rc -eq 0 && "$rs_candidate" != "$rs_base" \
   && "$rs_out" == *"hand-back"* && ! -e "$fx_rs/upload.called" \
   && "$(git --git-dir="$remote_rs" rev-parse refs/heads/main)" == "$rs_base" ]] \
  && ok "resubmit emits a dedicated-lane candidate without push/upload" \
  || fail_t "resubmit crossed protected-main boundary: $rs_out"
reject_rc=0
git -C "$fx_q" push -q origin HEAD:refs/heads/main >/dev/null 2>&1 || reject_rc=$?
[[ $reject_rc -ne 0 && "$(git --git-dir="$remote_q" rev-parse refs/heads/main)" == "$q_base" ]] \
  && ok "policy fixture rejects direct refs/heads/main push" \
  || fail_t "protected-main fixture accepted a direct main push"

# 23f. Exact PR readback is injected as one JSON object. Each invalid receipt
# must stop before ASC/upload/tag, even though the source is an ancestor and
# the iOS tuple is otherwise valid.
prepare_pr_fixture() {
  local fixture="$1" remote="$2"
  make_ios_release_fixture "$fixture" "$remote"
  git -C "$fixture" checkout -q -b feat/release-queue
  bash "$fixture/ops/release.sh" release ios 2.0.1 --yes >/dev/null
  PR_SOURCE="$(git -C "$fixture" rev-parse HEAD)"
  PR_BASE="$(git -C "$fixture" rev-parse HEAD^)"
  queue_merge_fixture "$fixture" "$remote" "$PR_SOURCE"
  PR_LIVE="$(git --git-dir="$remote" rev-parse refs/heads/main)"
  mkdir -p "$fixture/.git/pr-fixture"
  cat > "$fixture/.git/pr-fixture/pr-stub.sh" <<'STUB'
#!/usr/bin/env bash
cat "$(dirname "$0")/pr.json"
STUB
  chmod +x "$fixture/.git/pr-fixture/pr-stub.sh"
}

write_pr_receipt() {
  local fixture="$1" number="$2" state="$3" head="$4"
  cat > "$fixture/.git/pr-fixture/pr.json" <<JSON
{"number":${number},"state":"${state}","baseRefName":"main","baseRefOid":"${PR_BASE}","headRefOid":"${head}","mergeCommit":{"oid":"${PR_LIVE}"}}
JSON
}

write_pr_receipt_with_merge() {
  local fixture="$1" number="$2" state="$3" head="$4" merge="$5"
  cat > "$fixture/.git/pr-fixture/pr.json" <<JSON
{"number":${number},"state":"${state}","baseRefName":"main","baseRefOid":"${PR_BASE}","headRefOid":"${head}","mergeCommit":{"oid":"${merge}"}}
JSON
}

write_pr_receipt_with_base_and_merge() {
  local fixture="$1" number="$2" state="$3" base="$4" head="$5" merge="$6"
  cat > "$fixture/.git/pr-fixture/pr.json" <<JSON
{"number":${number},"state":"${state}","baseRefName":"main","baseRefOid":"${base}","headRefOid":"${head}","mergeCommit":{"oid":"${merge}"}}
JSON
}

pr_invalid_case() {
  local label="$1" number="$2" state="$3" head="${4:-}" fixture remote
  fixture="$TMP6/pr-${label}"; remote="$TMP6/pr-${label}.git"
  prepare_pr_fixture "$fixture" "$remote"
  [[ -n "$head" ]] || head="$PR_SOURCE"
  write_pr_receipt "$fixture" "$number" "$state" "$head"
  local rc=0 out
  out="$(KG_PR_CMD="$fixture/.git/pr-fixture/pr-stub.sh" bash "$fixture/ops/release.sh" resume ios 2.0.1 6 \
    --pr 1590 --merged-source "$PR_SOURCE" --yes 2>&1)" || rc=$?
  [[ $rc -ne 0 && "$out" == *"PR"* && ! -e "$fixture/upload.called" \
     && -z "$(git --git-dir="$remote" tag -l 'ios/2.0.1+6')" ]] \
    && ok "exact PR readback rejects ${label} before upload/tag" \
    || fail_t "invalid PR receipt ${label} was accepted: $out"
}

pr_invalid_case "wrong-number" 1591 MERGED
pr_invalid_case "open" 1590 OPEN
prepare_pr_fixture "$TMP6/pr-source-mismatch" "$TMP6/pr-source-mismatch.git"
write_pr_receipt "$TMP6/pr-source-mismatch" 1590 MERGED "$PR_BASE"
source_rc=0; source_out="$(KG_PR_CMD="$TMP6/pr-source-mismatch/.git/pr-fixture/pr-stub.sh" \
  bash "$TMP6/pr-source-mismatch/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" --yes 2>&1)" || source_rc=$?
[[ $source_rc -ne 0 && "$source_out" == *"headRefOid"* \
   && ! -e "$TMP6/pr-source-mismatch/upload.called" ]] \
  && ok "exact PR readback rejects source mismatch before upload" \
  || fail_t "source-mismatched PR receipt was accepted: $source_out"

# 23f.1. A merged PR's merge commit may be an ancestor of a later live main;
# the live tip is not required to be the PR merge commit itself.
fx_merge_ancestor="$TMP6/pr-merge-ancestor"; remote_merge_ancestor="$TMP6/pr-merge-ancestor.git"
prepare_pr_fixture "$fx_merge_ancestor" "$remote_merge_ancestor"
merge_ancestor_commit="$PR_LIVE"
git -C "$fx_merge_ancestor" commit --allow-empty -qm "fixture: subsequent main landing"
merge_ancestor_live="$(git -C "$fx_merge_ancestor" rev-parse HEAD)"
git -C "$fx_merge_ancestor" push -q origin "$merge_ancestor_live:refs/heads/queue-descendant"
git --git-dir="$remote_merge_ancestor" update-ref refs/heads/main "$merge_ancestor_live"
write_pr_receipt_with_merge "$fx_merge_ancestor" 1590 MERGED "$PR_SOURCE" "$merge_ancestor_commit"
merge_ancestor_rc=0; merge_ancestor_out="$(KG_PR_CMD="$fx_merge_ancestor/.git/pr-fixture/pr-stub.sh" \
  bash "$fx_merge_ancestor/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" 2>&1)" || merge_ancestor_rc=$?
[[ $merge_ancestor_rc -eq 0 && "$merge_ancestor_out" == *"未 upload、未建立 tag"* \
   && ! -e "$fx_merge_ancestor/upload.called" \
   && -z "$(git --git-dir="$remote_merge_ancestor" tag -l 'ios/2.0.1+6')" ]] \
  && ok "merged PR merge commit ancestor of live main is accepted" \
  || fail_t "merged ancestor receipt was rejected or mutated: $merge_ancestor_out"

pr_merge_nonancestor="$TMP6/pr-merge-nonancestor"; remote_merge_nonancestor="$TMP6/pr-merge-nonancestor.git"
prepare_pr_fixture "$pr_merge_nonancestor" "$remote_merge_nonancestor"
nonancestor_tree="$(git -C "$pr_merge_nonancestor" rev-parse "${PR_LIVE}^{tree}")"
nonancestor_merge="$(printf 'fixture: unrelated merge object\n' | git -C "$pr_merge_nonancestor" commit-tree "$nonancestor_tree")"
write_pr_receipt_with_merge "$pr_merge_nonancestor" 1590 MERGED "$PR_SOURCE" "$nonancestor_merge"
nonancestor_rc=0; nonancestor_out="$(KG_PR_CMD="$pr_merge_nonancestor/.git/pr-fixture/pr-stub.sh" \
  bash "$pr_merge_nonancestor/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" --yes 2>&1)" || nonancestor_rc=$?
[[ $nonancestor_rc -ne 0 && "$nonancestor_out" == *"ancestor"* \
   && ! -e "$pr_merge_nonancestor/upload.called" \
   && -z "$(git --git-dir="$remote_merge_nonancestor" tag -l 'ios/2.0.1+6')" ]] \
  && ok "unrelated merge commit is rejected before upload/tag" \
  || fail_t "unrelated merge commit was accepted or mutated: $nonancestor_out"

pr_merge_noncommit="$TMP6/pr-merge-noncommit"; remote_merge_noncommit="$TMP6/pr-merge-noncommit.git"
prepare_pr_fixture "$pr_merge_noncommit" "$remote_merge_noncommit"
noncommit_oid="$(git -C "$pr_merge_noncommit" rev-parse "${PR_LIVE}^{tree}")"
write_pr_receipt_with_merge "$pr_merge_noncommit" 1590 MERGED "$PR_SOURCE" "$noncommit_oid"
noncommit_rc=0; noncommit_out="$(KG_PR_CMD="$pr_merge_noncommit/.git/pr-fixture/pr-stub.sh" \
  bash "$pr_merge_noncommit/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" --yes 2>&1)" || noncommit_rc=$?
[[ $noncommit_rc -ne 0 && "$noncommit_out" == *"不是可驗證的 commit"* \
   && ! -e "$pr_merge_noncommit/upload.called" \
   && -z "$(git --git-dir="$remote_merge_noncommit" tag -l 'ios/2.0.1+6')" ]] \
  && ok "non-commit merge object is rejected before upload/tag" \
  || fail_t "non-commit merge object was accepted or mutated: $noncommit_out"

pr_merge_missing="$TMP6/pr-merge-missing"; remote_merge_missing="$TMP6/pr-merge-missing.git"
prepare_pr_fixture "$pr_merge_missing" "$remote_merge_missing"
cat > "$pr_merge_missing/.git/pr-fixture/pr.json" <<JSON
{"number":1590,"state":"MERGED","baseRefName":"main","baseRefOid":"${PR_BASE}","headRefOid":"${PR_SOURCE}","mergeCommit":null}
JSON
missing_rc=0; missing_out="$(KG_PR_CMD="$pr_merge_missing/.git/pr-fixture/pr-stub.sh" \
  bash "$pr_merge_missing/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" --yes 2>&1)" || missing_rc=$?
[[ $missing_rc -ne 0 && "$missing_out" == *"不是唯一且完整的 MERGED/main PR object"* \
   && ! -e "$pr_merge_missing/upload.called" \
   && -z "$(git --git-dir="$remote_merge_missing" tag -l 'ios/2.0.1+6')" ]] \
  && ok "missing merge commit is rejected before upload/tag" \
  || fail_t "missing merge commit was accepted or mutated: $missing_out"

pr_base_mismatch="$TMP6/pr-base-mismatch"; remote_base_mismatch="$TMP6/pr-base-mismatch.git"
prepare_pr_fixture "$pr_base_mismatch" "$remote_base_mismatch"
base_mismatch_tree="$(git -C "$pr_base_mismatch" rev-parse "${PR_LIVE}^{tree}")"
base_mismatch_oid="$(printf 'fixture: unrelated base object\n' | git -C "$pr_base_mismatch" commit-tree "$base_mismatch_tree")"
write_pr_receipt_with_base_and_merge "$pr_base_mismatch" 1590 MERGED "$base_mismatch_oid" "$PR_SOURCE" "$PR_LIVE"
base_rc=0; base_out="$(KG_PR_CMD="$pr_base_mismatch/.git/pr-fixture/pr-stub.sh" \
  bash "$pr_base_mismatch/ops/release.sh" resume ios 2.0.1 6 --pr 1590 \
  --merged-source "$PR_SOURCE" --yes 2>&1)" || base_rc=$?
[[ $base_rc -ne 0 && "$base_out" == *"baseRefOid"* \
   && ! -e "$pr_base_mismatch/upload.called" \
   && -z "$(git --git-dir="$remote_base_mismatch" tag -l 'ios/2.0.1+6')" ]] \
  && ok "base ancestry mismatch is rejected before upload/tag" \
  || fail_t "base ancestry mismatch was accepted or mutated: $base_out"

# 23g. finalize consumes the same verified PR receipt and is tag-only: dry-run
# never tags, --yes pushes only the build tag, and the policy hook still sees
# no refs/heads/main update.
fx_fin="$TMP6/finalize-tag-only"; remote_fin="$TMP6/finalize-tag-only.git"
prepare_pr_fixture "$fx_fin" "$remote_fin"
write_pr_receipt "$fx_fin" 1590 MERGED "$PR_SOURCE"
make_policy_rejecting_remote "$remote_fin"
fin_dry_rc=0; fin_dry_out="$(KG_PR_CMD="$fx_fin/.git/pr-fixture/pr-stub.sh" bash "$fx_fin/ops/release.sh" \
  finalize ios 2.0.1 6 --pr 1590 --merged-source "$PR_SOURCE" 2>&1)" || fin_dry_rc=$?
[[ $fin_dry_rc -eq 0 && "$fin_dry_out" == *"未建立 tag"* \
   && -z "$(git --git-dir="$remote_fin" tag -l 'ios/2.0.1+6')" ]] \
  && ok "finalize exact-PR dry-run is tag-free" \
  || fail_t "finalize dry-run mutated or rejected valid receipt: $fin_dry_out"
fin_rc=0; fin_out="$(KG_PR_CMD="$fx_fin/.git/pr-fixture/pr-stub.sh" bash "$fx_fin/ops/release.sh" \
  finalize ios 2.0.1 6 --pr 1590 --merged-source "$PR_SOURCE" --yes 2>&1)" || fin_rc=$?
[[ $fin_rc -eq 0 \
   && "$(git --git-dir="$remote_fin" rev-parse 'refs/tags/ios/2.0.1+6^{commit}')" == "$PR_LIVE" \
   && "$(git --git-dir="$remote_fin" rev-parse refs/heads/main)" == "$PR_LIVE" \
   && ! -e "$fx_fin/upload.called" && "$fin_out" == *"tag-only"* ]] \
  && ok "finalize verifies PR and publishes tag-only without upload/main push" \
  || fail_t "finalize was not exact-PR tag-only: $fin_out"

# ── 24. promote backend：FF-only origin/prod，四道前置守衛 + dry-run 預設 ─────
section "Promote backend (FF-only origin/prod)"
TMP7="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$TMP4" "$TMP5" "$TMP6" "$TMP7"' EXIT
P_REAL_GIT="$(command -v git)"
mkdir -p "$TMP7/shim"
# git shim：記錄每次呼叫的 argv（證明「沒有 push 嘗試」與 lease 參數），再 exec 真 git。
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$KG_TEST_GITLOG"\nexec "%s" "$@"\n' "$P_REAL_GIT" > "$TMP7/shim/git"
chmod +x "$TMP7/shim/git"
# gh shim：記錄 argv，輸出 $KG_TEST_GH_OUT（驗證真實 gh 路徑的 query 參數）。
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$KG_TEST_GHLOG"\ncat "$KG_TEST_GH_OUT"\n' > "$TMP7/shim/gh"
chmod +x "$TMP7/shim/gh"
# 單一 backend-quality run / 單頁 JSON / 多頁（gh --paginate 會串接多個 JSON 物件）。
pr_run() {  # $1=status $2=conclusion(或 null) [$3=name] [$4=check_suite.id] [$5=run id]
  local c="$2"; [[ "$c" == null ]] || c="\"$c\""
  printf '{"id":%s,"name":"%s","status":"%s","conclusion":%s,"check_suite":{"id":%s}}' "${5:-100}" "${3:-backend-quality / backend-quality}" "$1" "$c" "${4:-1}"
}
pr_page() {  # $1=total_count，其餘=run JSON
  local n="$1"; shift; local IFS=,
  printf '{"total_count":%s,"check_runs":[%s]}' "$n" "$*"
}
P_OK="$(pr_page 1 "$(pr_run completed success)")"
p_commit() {  # $1=fixture $2=version $3=message → commit sha
  printf '[project]\nversion = "%s"\n' "$2" > "$1/backend/pyproject.toml"
  printf 'app = FastAPI(\n        title="kg",\n        version="%s",\n)\n' "$2" > "$1/backend/src/kg/api.py"
  git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m "$3" && git -C "$1" rev-parse HEAD
}
mk_promote_fx() {  # $1=name；設 P_FX/P_REMOTE/P_BASE(=prod)/P_TGT(=main tip, 1.0.1)
  P_FX="$TMP7/$1"; P_REMOTE="$TMP7/$1.git"
  git init -q --bare "$P_REMOTE" && git clone -q "$P_REMOTE" "$P_FX" 2>/dev/null
  git -C "$P_FX" config user.email t@t && git -C "$P_FX" config user.name t
  mkdir -p "$P_FX/ops/lib" "$P_FX/backend/src/kg"
  cp "$REL" "$P_FX/ops/release.sh"; cp "$WORKSPACE/ops/lib/release_tags.sh" "$P_FX/ops/lib/"
  P_BASE="$(p_commit "$P_FX" 1.0.0 base)"; git -C "$P_FX" branch -M main
  P_TGT="$(p_commit "$P_FX" 1.0.1 bump)"
  git -C "$P_FX" push -q origin main "$P_BASE:refs/heads/prod"
  printf '#!/usr/bin/env bash\ncat "%s/checks.json"\n' "$P_FX" > "$P_FX/checks.sh"; chmod +x "$P_FX/checks.sh"
  printf '#!/usr/bin/env bash\nprintf "{\\"version\\":\\"%%s\\"}\\n200" "$(cat "%s/live_version")"\n' "$P_FX" > "$P_FX/curl.sh"; chmod +x "$P_FX/curl.sh"
  printf '%s' "$P_OK" > "$P_FX/checks.json"; printf 'unknown' > "$P_FX/live_version"
  : > "$P_FX/git.log"
}
p_run() {  # $@=release.sh args → P_OUT/P_RC；git 呼叫記在 $P_FX/git.log
  P_RC=0
  P_OUT="$(PATH="$TMP7/shim:$PATH" KG_TEST_GITLOG="$P_FX/git.log" KG_CHECK_RUNS_JSON_CMD="$P_FX/checks.sh" \
    CURL_BIN="$P_FX/curl.sh" KG_PROMOTE_WAIT_SECS=0 KG_PROMOTE_POLL_SECS=1 \
    bash "$P_FX/ops/release.sh" promote backend "$@" 2>&1)" || P_RC=$?
}
p_prod() { git --git-dir="$P_REMOTE" rev-parse refs/heads/prod; }
p_pushed() { grep -qE '(^| )push( |$)' "$P_FX/git.log"; }  # 0 = 有 push 嘗試

mk_promote_fx happy
p_run "$P_TGT"
[[ $P_RC -eq 0 && "$(p_prod)" == "$P_BASE" && "$P_OUT" == *"dry-run"* && "$P_OUT" == *"$P_TGT"* ]] && ! p_pushed \
  && ok "promote dry-run prints plan and pushes nothing" || fail_t "promote dry-run wrong (rc=$P_RC): $P_OUT"
p_run "${P_TGT:0:12}"
[[ $P_RC -ne 0 && "$P_OUT" == *"完整 40 字元 SHA"* && "$(p_prod)" == "$P_BASE" ]] \
  && ok "promote refuses abbreviated SHA" || fail_t "abbreviated SHA accepted: $P_OUT"
p_run "$P_TGT" --yes
[[ $P_RC -eq 0 && "$(p_prod)" == "$P_TGT" && "$P_OUT" == *"/api/system/info"* ]] \
  && ok "promote --yes fast-forwards origin/prod and prints verification" || fail_t "promote --yes failed (rc=$P_RC): $P_OUT"

mk_promote_fx notmain
git -C "$P_FX" checkout -q -b side
P_SIDE="$(p_commit "$P_FX" 1.0.2 unmerged)"
p_run "$P_SIDE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"不是 live origin/main"* && "$(p_prod)" == "$P_BASE" ]] && ! p_pushed \
  && ok "promote refuses SHA not on live origin/main" || fail_t "non-main SHA accepted (rc=$P_RC): $P_OUT"

# P2：ref 必須精確比對 refs/heads/prod|main；散落的 a/prod、a/main、x/main 不可被誤認。
mk_promote_fx strayref
P_STRAY="$(git -C "$P_FX" commit-tree "$P_BASE^{tree}" -p "$P_BASE" -m stray)"
git -C "$P_FX" push -q origin "$P_STRAY:refs/heads/a/prod"
git -C "$P_FX" push -q origin "$P_BASE:refs/heads/a/main" "$P_BASE:refs/heads/x/main" "$P_BASE:refs/heads/x/prod"
p_run "$P_TGT" --yes
[[ $P_RC -eq 0 && "$(p_prod)" == "$P_TGT" ]] \
  && ok "promote uses exact refs/heads/main and refs/heads/prod (ignores a/prod, a/main, x/main)" \
  || fail_t "stray ref confused promote (rc=$P_RC): $P_OUT"
[[ "$(git --git-dir="$P_REMOTE" rev-parse refs/heads/a/prod)" != "$P_TGT" && "$(git --git-dir="$P_REMOTE" rev-parse refs/heads/a/main)" == "$P_BASE" ]] \
  && ok "stray branches untouched by promote" || fail_t "promote touched a stray branch"

# P2：non-FF 必須由 script 自己的守衛擋下（斷言 script 專屬訊息 + 零 push 嘗試；git 自身的
# non-fast-forward 拒絕訊息不含「永不 force」）。
mk_promote_fx nonff
git -C "$P_FX" checkout -q -b fork "$P_BASE"
P_FORK="$(p_commit "$P_FX" 1.0.9 fork)"; git -C "$P_FX" push -q origin "$P_FORK:refs/heads/prod" --force
p_run "$P_TGT" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"只允許 fast-forward（永不 force"* && "$(p_prod)" == "$P_FORK" ]] && ! p_pushed \
  && ok "promote refuses non-fast-forward via its own guard, with no push attempt" || fail_t "non-FF guard wrong (rc=$P_RC): $P_OUT"

# P3：check 與 push 之間 prod 被別人前進（對 git 而言仍是合法 FF）→ lease 必須擋下。
mk_promote_fx race
git -C "$P_FX" checkout -q main
P_TGT2="$(p_commit "$P_FX" 1.0.2 bump2)"; git -C "$P_FX" push -q origin main
printf '#!/usr/bin/env bash\n[[ -e "%s/raced" ]] || { touch "%s/raced"; git -C "%s" push -q origin %s:refs/heads/prod; }\ncat "%s/checks.json"\n' \
  "$P_FX" "$P_FX" "$P_FX" "$P_TGT" "$P_FX" > "$P_FX/checks.sh"
p_run "$P_TGT2" --yes
[[ $P_RC -ne 0 && "$(p_prod)" == "$P_TGT" ]] && grep -q -- "--force-with-lease=refs/heads/prod:$P_BASE" "$P_FX/git.log" \
  && ok "promote push carries a lease on the observed prod and is refused when prod moved" \
  || fail_t "lease did not protect against a concurrent prod move (rc=$P_RC prod=$(p_prod)): $P_OUT"

mk_promote_fx sameversion
git -C "$P_FX" push -q origin "$P_TGT:refs/heads/prod"
P_DOC="$(p_commit "$P_FX" 1.0.1 docs-only)"; git -C "$P_FX" push -q origin main
p_run "$P_DOC" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"backend 版本未提升"* && "$(p_prod)" == "$P_TGT" ]] \
  && ok "promote refuses un-bumped backend version" || fail_t "un-bumped version accepted (rc=$P_RC): $P_OUT"
p_run "$P_DOC" --same-version
[[ $P_RC -ne 0 && "$P_OUT" == *"--same-version 需要一段理由文字"* ]] && ok "promote --same-version requires a reason" || fail_t "--same-version without reason accepted: $P_OUT"
p_run "$P_DOC" --same-version "redeploy after rollback"
[[ $P_RC -eq 0 && ! -e "$P_FX/.cache/release/promote.log" ]] \
  && ok "same-version dry-run writes no audit ledger" || fail_t "dry-run wrote ledger or failed (rc=$P_RC): $P_OUT"
p_run "$P_DOC" --same-version "redeploy after rollback" --yes
[[ $P_RC -eq 0 && "$(p_prod)" == "$P_DOC" && "$P_OUT" == *"redeploy after rollback"* ]] \
  && ok "promote --same-version <reason> allows redeploy and echoes the reason" || fail_t "same-version redeploy failed (rc=$P_RC): $P_OUT"
grep -q "$P_DOC.*same-version.*redeploy after rollback" "$P_FX/.cache/release/promote.log" 2>/dev/null \
  && ok "same-version reason is appended to the local promote ledger" || fail_t "ledger missing same-version audit line"

# CI 證據：走真實 jq 過濾器（seam 在 raw gh JSON 層）。
mk_promote_fx ci
p_ci() {  # $1=label $2=refusal-substring(空=應通過) $3=raw JSON
  : > "$P_FX/git.log"  # 前一個放行案例的 push 不可污染本案例的「零 push」斷言
  printf '%s' "$3" > "$P_FX/checks.json"; p_run "$P_TGT" --yes
  if [[ -z "$2" ]]; then
    [[ $P_RC -eq 0 && "$(p_prod)" == "$P_TGT" ]] && ok "CI: $1" || fail_t "CI: $1 should pass (rc=$P_RC): $P_OUT"
    git -C "$P_FX" push -q --force origin "$P_BASE:refs/heads/prod"
  else
    [[ $P_RC -ne 0 && "$P_OUT" == *"$2"* && "$(p_prod)" == "$P_BASE" ]] && ! p_pushed \
      && ok "CI: $1" || fail_t "CI: $1 should refuse with '$2' (rc=$P_RC): $P_OUT"
  fi
}
P_NOTGREEN="沒有全綠的 backend-quality"
p_ci "failure refused"                 "$P_NOTGREEN" "$(pr_page 1 "$(pr_run completed failure)")"
p_ci "skipped refused"                 "$P_NOTGREEN" "$(pr_page 1 "$(pr_run completed skipped)")"
p_ci "neutral refused"                 "$P_NOTGREEN" "$(pr_page 1 "$(pr_run completed neutral)")"
p_ci "in_progress refused"             "$P_NOTGREEN" "$(pr_page 1 "$(pr_run in_progress null)")"
p_ci "failed rerun after success refused (same suite, newer id fails)" "$P_NOTGREEN" "$(pr_page 2 "$(pr_run completed success '' 1 100)" "$(pr_run completed failure '' 1 101)")"
p_ci "failed then green rerun in same suite passes (#2660)" "" "$(pr_page 2 "$(pr_run completed failure '' 1 100)" "$(pr_run completed success '' 1 101)")"
p_ci "green rerun listed before older failure still passes (order-independent)" "" "$(pr_page 2 "$(pr_run completed success '' 1 101)" "$(pr_run completed failure '' 1 100)")"
p_ci "failure in a different suite is not hidden by green rerun elsewhere" "$P_NOTGREEN" "$(pr_page 3 "$(pr_run completed failure '' 1 100)" "$(pr_run completed success '' 1 101)" "$(pr_run completed failure '' 2 200)")"
p_ci "newest attempt in_progress refused even if older one was green" "$P_NOTGREEN" "$(pr_page 2 "$(pr_run completed success '' 1 100)" "$(pr_run in_progress null '' 1 101)")"
p_ci "run without id/check_suite refused (cannot tell newest attempt)" "$P_NOTGREEN" '{"total_count":1,"check_runs":[{"name":"backend-quality / backend-quality","status":"completed","conclusion":"success"}]}'
p_ci "missing backend-quality refused" "沒有任何 backend-quality check-run" "$(pr_page 1 "$(pr_run completed success agent-review)")"
p_ci "push-run check-run 'backend-quality' (main, 2026-10-13) accepted" "" "$(pr_page 1 "$(pr_run completed success backend-quality)")"
p_ci "push-run 'backend-quality' skipped refused" "$P_NOTGREEN" "$(pr_page 1 "$(pr_run completed skipped backend-quality)")"
p_ci "push-run 'backend-quality' failed in one suite refused though pr-gate name is green elsewhere" "$P_NOTGREEN" "$(pr_page 2 "$(pr_run completed success)" "$(pr_run completed failure backend-quality 2 200)")"
p_ci "both accepted names green across suites pass" "" "$(pr_page 2 "$(pr_run completed success)" "$(pr_run completed success backend-quality 2 200)")"
p_ci "sibling 'backend-quality / image-lock' does not count (refused)" "沒有任何 backend-quality check-run" "$(pr_page 1 "$(pr_run completed success 'backend-quality / image-lock')")"
p_ci "sibling 'backend-quality / image-lock' green does not stand in for push-run failure" "$P_NOTGREEN" "$(pr_page 2 "$(pr_run completed success 'backend-quality / image-lock' 1 100)" "$(pr_run completed failure backend-quality 2 200)")"
p_ci "empty check_runs refused"        "沒有任何 backend-quality check-run" "$(pr_page 0)"
p_ci "garbage refused"                 "check-runs 回應無法解析" "not json"
p_ci "empty output refused"            "check-runs 回應無法解析" ""
p_ci "truncated page (total_count 3, 1 run) refused" "check-runs 回應不完整" "$(pr_page 3 "$(pr_run completed success)")"
p_ci "page 2 failure not hidden"       "$P_NOTGREEN" "$(pr_page 2 "$(pr_run completed success)")$(pr_page 2 "$(pr_run completed failure '' 2 200)")"
p_ci "all runs green over two pages"   ""            "$(pr_page 2 "$(pr_run completed success)")$(pr_page 2 "$(pr_run completed success '' 2 200)")"
p_ci "other checks failing are ignored" ""           "$(pr_page 2 "$(pr_run completed success)" "$(pr_run completed failure agent-review)")"
printf '#!/usr/bin/env bash\necho "boom" >&2; exit 3\n' > "$P_FX/checks.sh"
p_run "$P_TGT" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"check-runs 失敗（exit 3）"* && "$(p_prod)" == "$P_BASE" ]] \
  && ok "CI: gh failure refused (no evidence)" || fail_t "gh failure accepted (rc=$P_RC): $P_OUT"

# 真實 gh 路徑：必須 --paginate + filter=all + per_page=100，且不得做 server-side name 過濾（名稱改由 jq client-side 選取，
# 同時接受 "backend-quality / backend-quality" 與 push-run 的 "backend-quality"；2026-10-13）。用 PATH gh shim 驗 argv。
mk_promote_fx ghargs
printf '%s' "$P_OK" > "$P_FX/gh_out.json"; : > "$P_FX/gh.log"
P_RC=0; P_OUT="$(PATH="$TMP7/shim:$PATH" KG_TEST_GITLOG="$P_FX/git.log" KG_TEST_GHLOG="$P_FX/gh.log" KG_TEST_GH_OUT="$P_FX/gh_out.json" \
  bash "$P_FX/ops/release.sh" promote backend "$P_TGT" 2>&1)" || P_RC=$?
[[ $P_RC -eq 0 ]] && grep -q -- "--paginate" "$P_FX/gh.log" && ! grep -q "check_name=" "$P_FX/gh.log" \
  && grep -q "filter=all" "$P_FX/gh.log" && grep -q "per_page=100" "$P_FX/gh.log" && grep -q "commits/$P_TGT/check-runs" "$P_FX/gh.log" \
  && ok "gh query is paginated, filter=all, unfiltered by name (names selected client-side)" \
  || fail_t "gh argv wrong (rc=$P_RC): $(cat "$P_FX/gh.log") :: $P_OUT"

# --wait：收斂成功 / 逾時 / 線上版本是別的 SHA。
mk_promote_fx wait
printf '%s' "${P_TGT:0:7}" > "$P_FX/live_version"
p_run "$P_TGT" --yes --wait
[[ $P_RC -eq 0 && "$P_OUT" == *"生產已收斂"* ]] && ok "--wait: converges when live version matches the promoted SHA" || fail_t "--wait success path failed (rc=$P_RC): $P_OUT"
mk_promote_fx waitold
printf '%s' "${P_BASE:0:7}" > "$P_FX/live_version"
p_run "$P_TGT" --yes --wait
[[ $P_RC -eq 1 && "$P_OUT" == *"逾時"* && "$(p_prod)" == "$P_TGT" ]] && ok "--wait: times out with rc=1 when the live version never converges" || fail_t "--wait timeout wrong (rc=$P_RC): $P_OUT"
mk_promote_fx waitwrong
printf 'deadbee' > "$P_FX/live_version"
p_run "$P_TGT" --yes --wait
[[ $P_RC -eq 1 && "$P_OUT" == *"線上仍是 version=deadbee"* && "$P_OUT" != *"生產已收斂"* ]] \
  && ok "--wait: a wrong deployed SHA is never read as converged" || fail_t "--wait accepted wrong SHA (rc=$P_RC): $P_OUT"

# ── 25. tag api <v> --commit <sha>：補打歷史 tag（#2666） ─────────────────────
section "Tag api backfill (--commit)"
t_run() {  # $@=release.sh tag 之後的參數 → P_OUT/P_RC
  P_RC=0; P_OUT="$(PATH="$TMP7/shim:$PATH" KG_TEST_GITLOG="$P_FX/git.log" bash "$P_FX/ops/release.sh" tag "$@" 2>&1)" || P_RC=$?
}
t_remote_tag() { git --git-dir="$P_REMOTE" rev-parse -q --verify "refs/tags/$1" 2>/dev/null; }
mk_promote_fx tagfill
git -C "$P_FX" push -q origin "$P_TGT:refs/heads/prod"
# locale 回歸：deliver 以 Python 子程序啟動檢查時 LC_CTYPE 會變成 C.UTF-8；此時 bash 把全形「（」前的 $sha 併入變數名，set -u 直接失敗
P_RC=0; P_OUT="$(LC_CTYPE=C.UTF-8 PATH="$TMP7/shim:$PATH" KG_TEST_GITLOG="$P_FX/git.log" bash "$P_FX/ops/release.sh" tag api 1.0.0 --commit "$P_BASE" 2>&1)" || P_RC=$?
[[ $P_RC -eq 0 && "$P_OUT" != *"unbound variable"* ]] \
  && ok "tag api --commit dry-run survives a UTF-8 LC_CTYPE (fullwidth punctuation after \$var)" || fail_t "UTF-8 locale breaks tag --commit (rc=$P_RC): $P_OUT"
t_run api 1.0.0 --commit "$P_BASE"
[[ $P_RC -eq 0 && "$P_OUT" == *"$P_BASE"* && -z "$(git -C "$P_FX" tag -l)" ]] && ! p_pushed \
  && ok "tag api --commit dry-run prints plan, creates no tag, pushes nothing" || fail_t "tag --commit dry-run wrong (rc=$P_RC): $P_OUT"
t_run api 1.0.1 --commit "$P_BASE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"版號是 1.0.0"* && -z "$(git -C "$P_FX" tag -l)" ]] \
  && ok "tag api --commit refuses a commit whose version differs" || fail_t "wrong-version commit accepted (rc=$P_RC): $P_OUT"
t_run api 1.0.0 --commit deadbeefdeadbeef --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"不是有效的 commit"* ]] \
  && ok "tag api --commit refuses an unknown commit" || fail_t "unknown commit accepted (rc=$P_RC): $P_OUT"
t_run ios 2.0.0 --commit "$P_BASE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"只支援 api"* ]] \
  && ok "tag --commit is api-only" || fail_t "ios tag --commit accepted (rc=$P_RC): $P_OUT"
t_run api 1.0.0 --commit "$P_BASE" --yes
[[ $P_RC -eq 0 && "$(git -C "$P_FX" rev-parse api/1.0.0^{commit})" == "$P_BASE" && "$(t_remote_tag api/1.0.0)" != "" ]] \
  && ok "tag api --commit --yes tags the exact commit (not HEAD) and pushes the tag" || fail_t "backfill tag failed (rc=$P_RC): $P_OUT"
[[ "$(git -C "$P_FX" rev-parse HEAD)" == "$P_TGT" && "$(p_prod)" == "$P_TGT" ]] \
  && ok "tag api --commit leaves HEAD and origin/prod untouched" || fail_t "backfill moved HEAD or prod"
t_run api 1.0.0 --commit "$P_BASE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"已存在"* ]] \
  && ok "tag api --commit refuses an existing tag" || fail_t "existing tag accepted (rc=$P_RC): $P_OUT"
git -C "$P_FX" tag -d api/1.0.0 >/dev/null
t_run api 1.0.0 --commit "$P_BASE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"已存在於 origin"* ]] \
  && ok "tag api --commit refuses a tag that exists only on origin" || fail_t "remote-only tag accepted (rc=$P_RC): $P_OUT"
git -C "$P_FX" push -q origin :refs/tags/api/1.0.0
git -C "$P_FX" push -q --force origin "$P_BASE:refs/heads/prod"
t_run api 1.0.1 --commit "$P_TGT" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"不是 live origin/prod"* && -z "$(git -C "$P_FX" tag -l)" ]] \
  && ok "tag api --commit refuses a commit that is not an ancestor of origin/prod" || fail_t "non-prod commit accepted (rc=$P_RC): $P_OUT"
git -C "$P_FX" remote set-url origin "$P_FX/no-such-remote"
t_run api 1.0.0 --commit "$P_BASE" --yes
[[ $P_RC -ne 0 && "$P_OUT" == *"ls-remote origin 失敗"* && -z "$(git -C "$P_FX" tag -l)" ]] \
  && ok "tag api --commit fail-closes when origin is unreachable (ls-remote error is not 'no tag')" || fail_t "unreachable origin read as no remote tag (rc=$P_RC): $P_OUT"
git -C "$P_FX" remote set-url origin "$P_REMOTE"

# ── 結果 ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
