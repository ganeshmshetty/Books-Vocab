# ios_run_verdict.sh — per-invocation verdict paths for ios_build.sh /
# ios_test.sh / ios_release.sh. Sourceable; bash 3.2+; safe under
# `set -euo pipefail`.
#
# Why: the verdict files used to live at ONE fixed path per kind
# (`${TMPDIR}/kg_ios_<kind>_verdict(.json)`). With several sessions/worktrees
# building or testing concurrently, a session could read another session's
# verdict and claim a green it never earned (third occurrence 2026-06-11).
#
# Contract:
#   - kg_ios_verdict_init <kind> <cwd>
#       Sets, in the caller's scope:
#         VERDICT_FILE              per-invocation UNIQUE path:
#                                   <latest>.<epochTs>-<pid>-<initSeq>
#                                   (or $KG_IOS_VERDICT_FILE when a wrapper
#                                   pins it to read back its own run race-free)
#         VERDICT_JSON_FILE         "$VERDICT_FILE.json"
#         VERDICT_LATEST_FILE       historical fixed path (latest pointer)
#         VERDICT_LATEST_JSON_FILE  "$VERDICT_LATEST_FILE.json"
#       The run files are the session's own evidence; nothing else writes them.
#   - kg_ios_verdict_identity_kv
#       Prints `ts=<epoch> pid=<pid> cwd=<cwd>` for embedding in the legacy
#       one-line verdict, so a stale / foreign verdict is recognizable at a
#       glance.
#   - kg_ios_verdict_publish
#       Copies the run files onto the latest pointers (last-writer-wins BY
#       DESIGN — `ios_ops.sh runs` wants "most recent run on this machine").
#       Never fails the caller: a lost latest pointer must not flip a verdict.
#
# Consumers that must identify THEIR OWN run read the unique path (printed on
# stdout as `verdict=...`) or pin it via KG_IOS_VERDICT_FILE; the fixed path is
# only a convenience pointer to the machine-wide latest run.

kg_ios_verdict_init() {
  local kind="$1" cwd="${2:-$PWD}" base="${TMPDIR:-/tmp}"
  base="${base%/}"
  KG_VERDICT_CWD="$cwd"
  VERDICT_LATEST_FILE="$base/kg_ios_${kind}_verdict"
  VERDICT_LATEST_JSON_FILE="$VERDICT_LATEST_FILE.json"
  if [[ -n "${KG_IOS_VERDICT_FILE:-}" ]]; then
    VERDICT_FILE="$KG_IOS_VERDICT_FILE"
  else
    # Seconds plus PID is not unique when one shell initializes multiple runs
    # in the same second. Keep a process-local sequence for that contract.
    case "${KG_IOS_VERDICT_INIT_SEQUENCE:-}" in
      ''|*[!0-9]*) KG_IOS_VERDICT_INIT_SEQUENCE=0 ;;
    esac
    KG_IOS_VERDICT_INIT_SEQUENCE=$((KG_IOS_VERDICT_INIT_SEQUENCE + 1))
    VERDICT_FILE="$VERDICT_LATEST_FILE.$(date +%s)-$$-$KG_IOS_VERDICT_INIT_SEQUENCE"
  fi
  VERDICT_JSON_FILE="$VERDICT_FILE.json"
}

kg_ios_verdict_identity_kv() {
  printf 'ts=%s pid=%s cwd=%s' "$(date +%s)" "$$" "${KG_VERDICT_CWD:-$PWD}"
}

# Names the commit under test on every verdict line (#2906); unknown outside a repo.
# tree=dirty|clean says whether that commit is what the run actually saw (#3218):
# uncommitted changes make a clean-looking commit= a lie. Same rule as
# ios_test.sh write_json_verdict: a `git status` that cannot answer is not "clean".
kg_ios_verdict_commit_kv() {
  local root="${1:-$PWD}" sha tree status_out
  sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$sha" == unknown ]]; then
    tree=unknown
  elif status_out="$(git -C "$root" status --porcelain 2>/dev/null)"; then
    if [[ -n "$status_out" ]]; then tree=dirty; else tree=clean; fi
  else
    tree=unknown
  fi
  printf 'commit=%s tree=%s' "$sha" "$tree"
}

kg_ios_verdict_publish() {
  if [[ -f "$VERDICT_FILE" && "$VERDICT_FILE" != "$VERDICT_LATEST_FILE" ]]; then
    cp -f "$VERDICT_FILE" "$VERDICT_LATEST_FILE" 2>/dev/null || true
  fi
  if [[ -f "$VERDICT_JSON_FILE" && "$VERDICT_JSON_FILE" != "$VERDICT_LATEST_JSON_FILE" ]]; then
    cp -f "$VERDICT_JSON_FILE" "$VERDICT_LATEST_JSON_FILE" 2>/dev/null || true
  fi
  return 0
}
