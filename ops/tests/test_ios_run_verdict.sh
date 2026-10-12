#!/usr/bin/env bash
# test_ios_run_verdict.sh — per-invocation verdict path isolation
# (ops/lib/ios_run_verdict.sh), offline / no Xcode.
#
# Regression guards (multi-session verdict race, 2026-06-11):
#   1. Each invocation gets a UNIQUE verdict path
#      `${TMPDIR}/kg_ios_<kind>_verdict.<epochTs>-<pid>-<initSeq>(.json)` — a session can
#      never mistake another session's verdict for its own.
#   2. The historical fixed path `${TMPDIR}/kg_ios_<kind>_verdict(.json)` is
#      kept as a LATEST POINTER: publish copies the run files onto it
#      (last-writer-wins by design, read by `ios_ops.sh runs`).
#   3. `KG_IOS_VERDICT_FILE` env pins the run path, so wrappers
#      (`ios_ops.sh build|test|archive --json`) can read back their OWN run
#      race-free.
#   4. Verdict identity fields (`ts= pid= cwd=`) make a stale / foreign
#      verdict recognizable at a glance.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$WORKSPACE/ops/lib/ios_run_verdict.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. syntax ─────────────────────────────────────────────────────────────────
section "Syntax"
bash -n "$LIB" && ok "lib syntax" || fail_t "lib syntax"

# Helper: run a snippet in a FRESH bash process (own $$) with TMPDIR=$TMP and
# the lib sourced, under the same strict mode the writers use.
in_proc() {
  TMPDIR="$TMP" bash -c "set -euo pipefail; source '$LIB'; $1"
}

# ── 2. init derives unique run path + fixed latest pointer ───────────────────
section "init path shape"
out="$(in_proc 'kg_ios_verdict_init test "/some/worktree"; printf "%s\n%s\n%s\n%s\n" "$VERDICT_FILE" "$VERDICT_JSON_FILE" "$VERDICT_LATEST_FILE" "$VERDICT_LATEST_JSON_FILE"')"
run_file="$(sed -n 1p <<<"$out")"
run_json="$(sed -n 2p <<<"$out")"
latest_file="$(sed -n 3p <<<"$out")"
latest_json="$(sed -n 4p <<<"$out")"
[[ "$latest_file" == "$TMP/kg_ios_test_verdict" ]] \
  && ok "latest pointer keeps historical fixed path" || fail_t "latest pointer wrong: $latest_file"
[[ "$latest_json" == "$TMP/kg_ios_test_verdict.json" ]] \
  && ok "latest JSON pointer keeps historical fixed path" || fail_t "latest json wrong: $latest_json"
[[ "$run_file" =~ ^"$TMP"/kg_ios_test_verdict\.[0-9]+-[0-9]+-[0-9]+$ ]] \
  && ok "run path is <latest>.<epochTs>-<pid>-<initSeq>" || fail_t "run path shape wrong: $run_file"
[[ "$run_json" == "$run_file.json" ]] \
  && ok "run JSON path is <run>.json" || fail_t "run json wrong: $run_json"
[[ "$run_file" != "$latest_file" ]] \
  && ok "run path differs from latest pointer" || fail_t "run path collides with latest pointer"

# ── 3. two concurrent invocations never share a run path ─────────────────────
section "cross-process uniqueness"
p1="$(in_proc 'kg_ios_verdict_init build "/wt/a"; printf "%s" "$VERDICT_FILE"')"
p2="$(in_proc 'kg_ios_verdict_init build "/wt/b"; printf "%s" "$VERDICT_FILE"')"
[[ -n "$p1" && -n "$p2" && "$p1" != "$p2" ]] \
  && ok "two processes get distinct run paths" || fail_t "run paths collide: $p1 vs $p2"

# ── 4. repeated init in one shell stays unique ───────────────────────────────
out="$(in_proc 'kg_ios_verdict_init build "/wt/repeat"; first="$VERDICT_FILE"; kg_ios_verdict_init build "/wt/repeat"; second="$VERDICT_FILE"; printf "%s\n%s\n" "$first" "$second"')"
first="$(sed -n 1p <<<"$out")"
second="$(sed -n 2p <<<"$out")"
[[ -n "$first" && -n "$second" && "$first" != "$second" ]] \
  && ok "repeated same-process init gets distinct run paths" \
  || fail_t "same-process run paths collide: $first vs $second"

# ── 5. KG_IOS_VERDICT_FILE env pins the run path ──────────────────────────────
section "env pin"
pinned="$TMP/pinned_verdict_path"
out="$(KG_IOS_VERDICT_FILE="$pinned" in_proc 'kg_ios_verdict_init test "/wt/pin"; printf "%s\n%s\n%s\n" "$VERDICT_FILE" "$VERDICT_JSON_FILE" "$VERDICT_LATEST_FILE"')"
[[ "$(sed -n 1p <<<"$out")" == "$pinned" ]] \
  && ok "env pins VERDICT_FILE" || fail_t "env pin ignored: $(sed -n 1p <<<"$out")"
[[ "$(sed -n 2p <<<"$out")" == "$pinned.json" ]] \
  && ok "env pin derives JSON path" || fail_t "env pin json wrong"
[[ "$(sed -n 3p <<<"$out")" == "$TMP/kg_ios_test_verdict" ]] \
  && ok "latest pointer unaffected by env pin" || fail_t "latest pointer drifted under env pin"

# ── 6. identity fields: ts= pid= cwd= recognizable in one glance ──────────────
section "identity kv"
kv="$(in_proc 'kg_ios_verdict_init test "/wt/identity"; kg_ios_verdict_identity_kv')"
grep -qE '(^| )ts=[0-9]+( |$)' <<<"$kv" && ok "kv has epoch ts=" || fail_t "kv missing ts=: $kv"
grep -qE '(^| )pid=[0-9]+( |$)' <<<"$kv" && ok "kv has pid=" || fail_t "kv missing pid=: $kv"
grep -qE '(^| )cwd=/wt/identity( |$)' <<<"$kv" && ok "kv has cwd= (init arg)" || fail_t "kv missing cwd=: $kv"

# ── 7. publish copies run files onto the latest pointer ──────────────────────
section "publish → latest pointer"
in_proc '
  kg_ios_verdict_init test "/wt/pub"
  echo "RESULT=ok run-marker-A $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  echo "{\"marker\":\"A\"}" > "$VERDICT_JSON_FILE"
  kg_ios_verdict_publish
'
grep -q 'run-marker-A' "$TMP/kg_ios_test_verdict" \
  && ok "publish updates latest text pointer" || fail_t "latest text pointer not updated"
grep -q '"marker":"A"' "$TMP/kg_ios_test_verdict.json" \
  && ok "publish updates latest JSON pointer" || fail_t "latest JSON pointer not updated"
# run files survive publish (they are the per-session evidence)
ls "$TMP"/kg_ios_test_verdict.[0-9]*-[0-9]* >/dev/null 2>&1 \
  && ok "per-run verdict file persists after publish" || fail_t "per-run verdict file vanished"

# ── 8. publish is safe under set -e with partial/missing files ────────────────
section "publish robustness"
in_proc 'kg_ios_verdict_init build "/wt/none"; kg_ios_verdict_publish; echo SAFE' | grep -q SAFE \
  && ok "publish with no files does not abort (set -e)" || fail_t "publish aborted with no files"
in_proc '
  kg_ios_verdict_init build "/wt/textonly"
  echo "RESULT=fail run-marker-B" > "$VERDICT_FILE"
  kg_ios_verdict_publish
  echo SAFE
' | grep -q SAFE \
  && ok "publish with text-only verdict does not abort" || fail_t "text-only publish aborted"
grep -q 'run-marker-B' "$TMP/kg_ios_build_verdict" \
  && ok "text-only publish still updates latest pointer" || fail_t "text-only publish skipped latest"
# pin directly to the latest pointer (degenerate but allowed): cp src==dst must not error
in_proc '
  KG_IOS_VERDICT_FILE="'"$TMP"'/kg_ios_build_verdict" kg_ios_verdict_init build "/wt/degenerate"
  echo "RESULT=ok degenerate" > "$VERDICT_FILE"
  kg_ios_verdict_publish
  echo SAFE
' | grep -q SAFE \
  && ok "publish tolerates pin==latest" || fail_t "publish broke when pinned to latest path"

# ── 9. every verdict line names the commit under test (#2906) ────────────────
section "commit in verdict"
repo="$TMP/commit-repo"; mkdir -p "$repo"; git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
got="$(in_proc "kg_ios_verdict_commit_kv '$repo'" 2>/dev/null || true)"
[[ "$got" == "commit=$(git -C "$repo" rev-parse HEAD) tree=clean" && "$got" =~ ^commit=[0-9a-f]{40}\ tree=clean$ ]] \
  && ok "clean repo: commit=<40-hex HEAD> tree=clean" || fail_t "clean commit kv wrong: '$got'"
echo x > "$repo/untracked-dirty-marker"
got="$(in_proc "kg_ios_verdict_commit_kv '$repo'" 2>/dev/null || true)"
[[ "$got" =~ ^commit=[0-9a-f]{40}\ tree=dirty$ ]] \
  && ok "dirty repo (untracked file): tree=dirty after commit=" || fail_t "dirty commit kv wrong: '$got'"
rm -f "$repo/untracked-dirty-marker"
got="$(GIT_CEILING_DIRECTORIES="$TMP" in_proc "kg_ios_verdict_commit_kv '$TMP'" 2>/dev/null || true)"
[[ "$got" == "commit=unknown tree=unknown" ]] && ok "non-repo root degrades to commit=unknown tree=unknown" || fail_t "non-repo commit kv: '$got'"
# wiring: every RESULT= verdict line in the iOS entry points (echo or printf) carries the helper.
# ios_test.sh and ios_build.sh name the repo root PROJECT_ROOT; ios_release.sh names it ROOT.
# The root variable is pinned per file: a wrong name (e.g. an undefined $ROOT in build) must fail.
ios_test="$WORKSPACE/ops/ios_test.sh"
ios_entrypoints=("$ios_test" "$WORKSPACE/ops/ios_build.sh" "$WORKSPACE/ops/ios_release.sh")
ios_root_vars=("PROJECT_ROOT" "PROJECT_ROOT" "ROOT")
unwired=0
for i in "${!ios_entrypoints[@]}"; do
  ios_script="${ios_entrypoints[$i]}"
  root_call="kg_ios_verdict_commit_kv \"\$${ios_root_vars[$i]}\""
  n="$(grep -E 'RESULT=(ok|fail|inconclusive) ' "$ios_script" | grep -vcF "$root_call" || true)"
  unwired=$((unwired + n))
done
[[ "$unwired" == 0 ]] && grep -q 'all tests passed.*kg_ios_verdict_commit_kv "\$PROJECT_ROOT"' "$ios_test" \
  && ok "all RESULT= verdict lines (test/build/release) and the success summary embed the commit" || fail_t "verdict lines without commit: $unwired"
# identity stays the line tail: cwd may hold spaces, and the ops tests read cwd= as rest-of-line
misordered=0
for ios_script in "${ios_entrypoints[@]}"; do
  while IFS= read -r verdict_line; do
    if [[ "$verdict_line" == *'RESULT='* && "$verdict_line" == *'kg_ios_verdict_identity_kv'* \
          && "$verdict_line" == *'kg_ios_verdict_commit_kv'* ]]; then
      before_commit="${verdict_line%%kg_ios_verdict_commit_kv*}"
      if [[ "$before_commit" == *'kg_ios_verdict_identity_kv'* ]]; then misordered=$((misordered+1)); fi
    fi
  done < "$ios_script"
done
[[ "$misordered" == 0 ]] && ok "commit precedes identity on every verdict line (cwd= stays the tail)" \
  || fail_t "identity precedes commit on $misordered verdict line(s); cwd= would swallow commit="

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
