#!/usr/bin/env bash
# docs_lint.sh — docs gate / audit / registry checks
#
# This script validates document contracts only: registry paths, live registry
# source hints, metadata, reachable anchors, conflict markers, generated equality
# and freshness warnings. Source liveness comes from `ops/docs_impact.py
# --check-sources` (KG_DOCS_IMPACT_BIN overrides that path for tests).
# GitHub owns Issues, Projects, PRs and merge state; this script owns no workflow data.
#
# Usage:
#   ops/docs_lint.sh                 # changed-document gate
#   ops/docs_lint.sh --changed       # changed-document gate
#   ops/docs_lint.sh --since <rev>   # changed docs since a revision
#   ops/docs_lint.sh --files <docs...>
#   ops/docs_lint.sh <docs/...md> ...
#   ops/docs_lint.sh --registry      # registry only
#   ops/docs_lint.sh --audit|--all   # all active docs, freshness warnings included
#   STALE_THRESHOLD=10 ops/docs_lint.sh --audit
#
# Exit code:
#   0 — all checks passed
#   1 — lint/tool execution failure
#   2 — one or more document errors
#   3 — warnings only
#   64 — command-line usage error
#
# Compatible with macOS bash 3.2; do not use mapfile/readarray.

set -euo pipefail

EXIT_OK=0
EXIT_TOOL_ERROR=1
EXIT_BLOCK=2
EXIT_WARN=3
EXIT_USAGE=64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS_IMPACT="${KG_DOCS_IMPACT_BIN:-$SCRIPT_DIR/docs_impact.py}"
cd "$(git rev-parse --show-toplevel)"
LINT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kg_docs_lint.XXXXXX")"
trap 'rm -rf "$LINT_TMP"' EXIT
STALE_THRESHOLD="${STALE_THRESHOLD:-30}"
MODE="gate"
SINCE_REV=""
FILE_ARGS=()
STRICT=0
errors=0
warnings=0
ok=0

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --changed) MODE="gate"; shift ;;
    --since)
      [ "$#" -ge 2 ] || { echo "Missing value for --since" >&2; exit "$EXIT_USAGE"; }
      MODE="gate"; SINCE_REV="$2"; shift 2 ;;
    --files)
      MODE="files"; shift
      while [ "$#" -gt 0 ]; do
        case "$1" in --*) break ;; *) FILE_ARGS+=("$1"); shift ;; esac
      done
      ;;
    --registry) MODE="registry"; shift ;;
    --audit|--all) MODE="audit"; shift ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    --*) echo "Unknown arg: $1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    *) MODE="files"; FILE_ARGS+=("$1"); shift ;;
  esac
done

if [ "${#FILE_ARGS[@]}" -eq 0 ] && [ "$MODE" = "files" ]; then
  echo "--files 需要至少一個 docs/*.md 路徑" >&2
  exit "$EXIT_USAGE"
fi

doc_meta_value() {
  file="$1"
  key="$2"
  awk -v wanted="$key" '
    /^<!-- doc-meta/ { inside=1; next }
    inside && /^-->/ { exit }
    inside && $0 ~ "^" wanted ":" {
      value=$0
      sub("^" wanted ":[[:space:]]*", "", value)
      print value
      exit
    }
  ' "$file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//'
}

doc_meta_has_key() {
  awk -v wanted="$2" '
    /^<!-- doc-meta/ { inside=1; next }
    inside && /^-->/ { exit found ? 0 : 1 }
    inside && $0 ~ "^" wanted ":" { found=1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

emit_generated_diff() {
  id="$1"
  path="$2"
  generator="$3"
  expected_tmp="$LINT_TMP/expected"
  actual_tmp="$LINT_TMP/actual"
  diff_tmp="$LINT_TMP/diff"
  rm -f "$expected_tmp" "$actual_tmp"
  if sh -c "$generator" </dev/null >"$expected_tmp" 2>/dev/null && cat "$path" >"$actual_tmp"; then
    if diff -u "$expected_tmp" "$actual_tmp" >"$diff_tmp"; then
      :
    else
      echo "drift diff ($id):"
      total_lines="$(wc -l <"$diff_tmp" | tr -d ' ')"
      sed -n '1,80p' "$diff_tmp"
      if [ "$total_lines" -gt 80 ]; then
        echo "還有 $((total_lines - 80)) 行差異未顯示"
      fi
    fi
  fi
  rm -f "$expected_tmp" "$actual_tmp" "$diff_tmp"
}

# Every non-! source must be hittable by some path, judged by docs_impact's own
# matcher; a source nothing matches is an impact hint that can never fire. Fails
# closed: a tool error, or a run whose output disagrees with its exit status
# (including exit 0 with no summary), is a tool failure, never a silent pass.
validate_registry_sources() {
  reg="$1"
  src_out="$LINT_TMP/sources"
  src_err="$LINT_TMP/sources_err"
  set +e
  "$DOCS_IMPACT" --check-sources --registry "$reg" </dev/null >"$src_out" 2>"$src_err"
  src_rc=$?
  set -e
  src_summary="$(grep '^source_check: ' "$src_out" | tail -n 1 || true)"
  src_dead="$(printf '%s' "$src_summary" | sed -n 's/.* dead=\([0-9][0-9]*\)$/\1/p')"
  src_checked="$(printf '%s' "$src_summary" | sed -n 's/.* sources=\([0-9][0-9]*\) .*/\1/p')"
  dead_lines="$(grep -c "^DEAD_SOURCE$(printf '\t')" "$src_out" || true)"
  consistent=0
  if [ -n "$src_dead" ] && [ -n "$src_checked" ] && [ "$src_dead" = "$dead_lines" ]; then
    if [ "$src_rc" -eq 0 ] && [ "$src_dead" -eq 0 ]; then consistent=1; fi
    if [ "$src_rc" -eq 2 ] && [ "$src_dead" -gt 0 ]; then consistent=1; fi
  fi
  if [ "$consistent" -ne 1 ]; then
    echo "ERROR registry — source 存在性檢查無法執行 (rc=$src_rc, summary='${src_summary:-none}'): $DOCS_IMPACT"
    sed 's/^/    /' "$src_err"
    rm -f "$src_out" "$src_err"
    exit "$EXIT_TOOL_ERROR"
  fi
  while IFS="$(printf '\t')" read -r tag id source; do
    [ "$tag" = "DEAD_SOURCE" ] || continue
    echo "ERROR registry — $id source 未命中任何 path: $source"
    bad=$((bad+1))
  done <"$src_out"
  rm -f "$src_out" "$src_err"
}

validate_registry() {
  reg="docs/registry.yml"
  if [ ! -f "$reg" ]; then
    echo "ERROR registry — missing $reg"
    errors=$((errors+1))
    return
  fi
  entries_tmp="$LINT_TMP/entries"
  awk '
    function flush() { if (id != "") print "ENTRY\t" id "\t" path "\t" kind "\t" generator "\t" check }
    /^  - id:/ {
      flush()
      id=$0
      sub(/^  - id:[[:space:]]*/, "", id)
      path=""; kind=""; generator=""; check=""
      next
    }
    id != "" && /^    path:/ { path=$0; sub(/^    path:[[:space:]]*/, "", path); next }
    id != "" && /^    kind:/ { kind=$0; sub(/^    kind:[[:space:]]*/, "", kind); next }
    id != "" && /^    generator:/ { generator=$0; sub(/^    generator:[[:space:]]*/, "", generator); next }
    id != "" && /^    check:/ { check=$0; sub(/^    check:[[:space:]]*/, "", check); next }
    END { flush() }
  ' "$reg" >"$entries_tmp"

  count=0
  bad=0
  while IFS="$(printf '\t')" read -r tag id path kind generator check; do
    [ "$tag" = "ENTRY" ] || continue
    count=$((count+1))
    if [ -z "$id" ] || [ -z "$path" ] || [ -z "$kind" ]; then
      echo "ERROR registry — entry 缺 id/path/kind: id=$id path=$path kind=$kind"
      bad=$((bad+1))
      continue
    fi
    case " contract generated reference sop policy decision guide snapshot runbook archive assets " in
      *" $kind "*) ;;
      *) echo "ERROR registry — $id 非法 kind: $kind"; bad=$((bad+1)) ;;
    esac
    if [ ! -f "$path" ]; then
      echo "ERROR registry — $id path 不存在: $path"
      bad=$((bad+1))
      continue
    fi
    if [ "$kind" = "generated" ]; then
      if [ -z "$generator" ] || [ ! -f "$generator" ]; then
        echo "ERROR registry — $id kind=generated 缺少存在的 generator"
        bad=$((bad+1))
        continue
      fi
      if [ -z "$check" ]; then
        echo "ERROR registry — $id kind=generated 缺少 check"
        bad=$((bad+1))
        continue
      fi
      if ! grep -qF -- "$path" <<< "$check"; then
        echo "ERROR registry — $id check 未指名 path: $path"
        bad=$((bad+1))
        continue
      fi
      if ! sh -c "$check" </dev/null >/dev/null 2>&1; then
        echo "ERROR registry — $id 產物與 generator 輸出不一致: $path"
        emit_generated_diff "$id" "$path" "$generator"
        bad=$((bad+1))
      fi
    fi
  done <"$entries_tmp"
  rm -f "$entries_tmp"

  if [ "$count" -eq 0 ]; then
    echo "ERROR registry — no document entries"
    errors=$((errors+1))
    return
  fi
  validate_registry_sources "$reg"
  if [ "$bad" -gt 0 ]; then
    echo "ERROR registry — $bad invalid entries/sources"
    errors=$((errors+1))
    return
  fi
  echo "REGISTRY OK: $count documents, $src_checked sources live"
  ok=$((ok+1))
}

tracked_docs() {
  find docs -type f -name '*.md' \
    ! -path 'docs/assets/*' ! -path 'docs/legal/*' \
    -print | sort
}

changed_docs() {
  if [ -n "$SINCE_REV" ]; then
    if ! git rev-parse --verify "$SINCE_REV^{commit}" >/dev/null 2>&1; then
      echo "ERROR --since 不是有效 commit: $SINCE_REV" >&2
      return "$EXIT_USAGE"
    fi
    git diff --name-only --diff-filter=ACMR "$SINCE_REV...HEAD" 2>/dev/null || true
  else
    git diff --name-only --diff-filter=ACMR HEAD 2>/dev/null || true
  fi
  git diff --name-only --diff-filter=ACMR --cached 2>/dev/null || true
  git ls-files --others --exclude-standard 2>/dev/null || true
}

select_docs() {
  case "$MODE" in
    audit) tracked_docs ;;
    files)
      for file in "${FILE_ARGS[@]}"; do
        case "$file" in
          docs/*.md) ;;
          *) echo "ERROR --files 只接受 docs/.*.md 路徑: $file" >&2; return "$EXIT_USAGE" ;;
        esac
        if [ ! -f "$file" ]; then
          echo "ERROR 路徑不存在: $file" >&2
          return "$EXIT_USAGE"
        fi
        printf '%s\n' "$file"
      done | sort -u
      ;;
    gate)
      changed_docs | awk '/^docs\/.*\.md$/ && $0 !~ /^docs\/assets\// && $0 !~ /^docs\/legal\// { print }' | sort -u
      ;;
  esac
}

validate_conflict_markers() {
  file="$1"
  hits="$LINT_TMP/conflict_hits"
  if grep -nE '^<<<<<<< |^>>>>>>> ' "$file" >"$hits" 2>/dev/null; then
    echo "ERROR $file — 衝突標記殘留:"
    sed 's/^/    /' "$hits"
    rm -f "$hits"
    errors=$((errors+1))
    return 1
  fi
  rm -f "$hits"
  return 0
}

validate_scope_freshness() {
  file="$1"
  verified="$2"
  [ "$MODE" = "audit" ] || return 0
  scope_paths="$(awk '
    /^scope:/ { inside=1; next }
    inside && /^  - / { sub(/^  - /, ""); print; next }
    inside && !/^  / { exit }
  ' "$file")"
  if [ -z "$scope_paths" ]; then
    echo "WARN  $file — scope 為空，無法計算 freshness"
    warnings=$((warnings+1))
    return 0
  fi
  commits=0
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    count="$(git rev-list --count "$verified..HEAD" -- "$scope" 2>/dev/null || printf '0')"
    if [ "$count" -gt "$commits" ] 2>/dev/null; then commits="$count"; fi
  done <<EOF
$scope_paths
EOF
  if [ "$commits" -gt "$STALE_THRESHOLD" ]; then
    echo "WARN  $file — scope since verified_against has $commits commits (threshold=$STALE_THRESHOLD)"
    warnings=$((warnings+1))
  fi
}

validate_doc() {
  file="$1"
  meta="$(sed -n '1,/^-->/p' "$file" 2>/dev/null || true)"
  if ! grep -q '^<!-- doc-meta' <<< "$meta"; then
    echo "ERROR $file — 缺少 doc-meta frontmatter"
    errors=$((errors+1))
    return
  fi
  missing=""
  for key in tier authority update_trigger scope verified_against; do
    doc_meta_has_key "$file" "$key" || missing="$missing $key"
  done
  if [ -n "$missing" ]; then
    echo "ERROR $file — 缺欄位:$missing"
    errors=$((errors+1))
    return
  fi
  tier="$(doc_meta_value "$file" tier)"
  verified="$(doc_meta_value "$file" verified_against)"
  case " contract generated reference sop policy decision guide snapshot runbook archive assets " in
    *" $tier "*) ;;
    *) echo "ERROR $file — 非法 tier: $tier"; errors=$((errors+1)); return ;;
  esac
  validate_conflict_markers "$file" || return
  if [ "$tier" = "archive" ] && [ "$verified" = "frozen" ]; then
    ok=$((ok+1))
    return
  fi
  verified_sha=""
  if ! verified_sha="$(git rev-parse --verify --quiet "$verified^{commit}" 2>/dev/null)"; then
    echo "ERROR $file — verified_against 不是有效 commit: $verified"
    errors=$((errors+1))
    return
  fi
  if ! git merge-base --is-ancestor "$verified_sha" HEAD 2>/dev/null; then
    if [ "$MODE" = "audit" ]; then
      echo "WARN  $file — verified_against 不可達: $verified"
      warnings=$((warnings+1))
    else
      echo "ERROR $file — verified_against 不可達: $verified"
      echo "    修法: re-anchor 到目前 HEAD 可達的 commit"
      errors=$((errors+1))
    fi
    return
  fi
  validate_scope_freshness "$file" "$verified_sha"
  ok=$((ok+1))
}

emit_impact_hints() {
  [ "$MODE" = "gate" ] || return 0
  echo "docs_lint: current checkout impact hints"
  if [ -n "$SINCE_REV" ]; then
    ./ops/docs_impact.py --since "$SINCE_REV" --explain 2>/dev/null || true
  else
    ./ops/docs_impact.py --since HEAD --explain 2>/dev/null || true
  fi
}

echo "docs_lint: mode=$MODE"
validate_registry

if [ "$MODE" = "registry" ]; then
  echo ""
  echo "─────────────────────────────────────"
  printf 'OK:    %s\n' "$ok"
  printf 'WARN:  %s\n' "$warnings"
  printf 'ERROR: %s\n' "$errors"
  echo "─────────────────────────────────────"
  [ "$errors" -gt 0 ] && exit "$EXIT_BLOCK"
  [ "$warnings" -gt 0 ] && exit "$EXIT_WARN"
  exit "$EXIT_OK"
fi

emit_impact_hints
selected="$(select_docs)" || exit $?
if [ -z "$selected" ]; then
  echo "docs_lint: no docs selected"
else
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    validate_doc "$file"
  done <<EOF
$selected
EOF
fi

echo ""
echo "─────────────────────────────────────"
printf 'OK:    %s\n' "$ok"
printf 'WARN:  %s\n' "$warnings"
printf 'ERROR: %s\n' "$errors"
echo "─────────────────────────────────────"
[ "$errors" -gt 0 ] && exit "$EXIT_BLOCK"
[ "$warnings" -gt 0 ] && exit "$EXIT_WARN"
exit "$EXIT_OK"
