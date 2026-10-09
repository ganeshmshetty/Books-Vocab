#!/usr/bin/env bash
# ci_scope_router.sh — route only demonstrably affected non-blocking CI suites.
#
# This is deliberately fail-closed: an unclassified path selects every slow
# confidence suite.  It is a policy helper for pr-gate, not a work tracker.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ops/ci_scope_router.sh (--base <commit> --head <commit> | --paths-stdin | --all) [--format json|github-output]

Classify changed paths into the non-blocking backend, ops, and iOS confidence
suites. Unknown paths select every suite so a new runtime surface cannot
silently lose validation. With --base/--head the changed paths are the diff
from `git merge-base <base> <head>` to <head>, so commits that landed on the
base branch after the fork never count as this change; no merge base selects
every suite.

The plan also carries macos_ops and ui_smoke (Issue #2641): the macOS native ops
job and the ui-smoke leg run only when their own scope changed, or on any
fail-closed fan-out.

The iOS suite additionally carries ios_mode=full|targeted. Targeted is admitted
only for exactly one changed top-level ios/BooksAndVocabUITests/*UITests.swift
file whose `ios_test.sh --ui --list --file` discovery returns fully qualified
Target/Suite/Method selectors and that no ios/BooksAndVocabTests source
contract reads by path; every other input stays ios_mode=full with an empty
ios_selectors. KG_CI_IOS_SELECTOR_DISCOVERY overrides the discovery
command for contract tests only.
EOF
}

base=''
head=''
source=''
format='json'

while (($# > 0)); do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    --head)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      head="$2"
      shift 2
      ;;
    --paths-stdin)
      [[ -z "$source" ]] || { usage >&2; exit 2; }
      source='stdin'
      shift
      ;;
    --all)
      [[ -z "$source" ]] || { usage >&2; exit 2; }
      source='all'
      shift
      ;;
    --format)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      format="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$format" in
  json|github-output) ;;
  *)
    printf 'unsupported format: %s\n' "$format" >&2
    exit 2
    ;;
esac

if [[ -n "$source" && ( -n "$base" || -n "$head" ) ]]; then
  printf 'choose either a commit range or an explicit change source\n' >&2
  usage >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISCOVERY="${KG_CI_IOS_SELECTOR_DISCOVERY:-$ROOT/ops/ios_test.sh}"

backend=false
ops=false
ios=false
# macOS runner scope (Issue #2641). The runner pool is small, so the two
# macOS-only extras are routed separately from `ops`/`ios`: macos_ops gates the
# macOS native ops job, ui_smoke gates the ui-smoke leg of ios-quality.
macos_ops=false
ui_smoke=false
path_count=0
single_path=''
ios_mode=full
ios_selectors=''

select_all() {
  backend=true
  ops=true
  ios=true
  macos_ops=true
  ui_smoke=true
}

classify_path() {
  local path="$1"
  [[ -n "$path" ]] || return
  path_count=$((path_count + 1))
  single_path="$path"

  # macOS-only extras (ios/ paths are inert here: ops-suite only runs when
  # ops=true, so ios-only changes were never ops-suite scope). Flag-only: no return, so the normal tree selection below
  # still applies. macos_ops covers the groups ops-suite runs natively
  # (ios-ops, ios-sentry-wiring, lldb-forensics) and what they read.
  case "$path" in
    ops/ios_*|ops/test_ios_*|ops/lib/*|ops/lldb_*|ops/install_lldb_forensics.sh|ops/tests/test_ios_*|ops/tests/test_lldb_*|ops/tests/lldb_*|ops/tests/test_sentry_wiring.sh|ops/test_ops.sh|.github/workflows/ops-suite.yml|ops/review_flip_probe.sh|ops/ui_quality_plane.py|ops/ui_world_manifest.py|ops/app_review/*|ops/app_review_evidence.py|ops/app_review_gate.py|ops/asc.sh|ops/asc_text_bundle.py|ops/sentry_release.sh|ops/sentry_tool.py|ops/sentry_api.py|ops/kg_disk_guard.sh|ops/kg_reconcile.sh|ops/backup_verify.sh|ops/release.sh|ops/p9_review_calendar_evidence.py|ops/tests/test_lib_sourcing.sh|ops/tests/test_ops_ci_coverage.sh)
      macos_ops=true
      ;;
  esac
  # ui_smoke: anything that can change what the app or the UI test harness
  # does. Unit-test-only sources (ios/BooksAndVocabTests) do not.
  case "$path" in
    ios/BooksAndVocabTests/*) ;;
    ios/*|ops/ios_*|ops/lib/ios_*|ops/lib/signal_traps.sh|ops/lib/project_python.sh|ops/lib/fixture_dataset_env.sh|ops/lib/userland_compat.sh|ops/lib/provenance.py|ops/fixtures/ui_worlds/*|ops/ui_world_manifest.py|ops/review_calendar_clock.py|.github/workflows/ios-quality.yml)
      ui_smoke=true
      ;;
  esac

  # Router, verdict, and contract-test changes alter either test selection or
  # the meaning of a confidence result. They must receive a complete fan-out.
  case "$path" in
    ops/ci_scope_router.sh|ops/ci_confidence_verdict.sh|ops/tests/test_ci_scope_router.sh|ops/tests/test_ci_confidence_verdict.sh|ops/tests/test_github_workflows.sh|.github/workflows/pr-gate.yml)
      select_all
      return
      ;;
  esac

  # This skill declares the backend ops CLI roster exercised by backend tests.
  # Keep the contract on backend confidence without broadening all agent skills.
  case "$path" in
    .claude/skills/devops/SKILL.md)
      backend=true
      return
      ;;
  esac

  # Cross-tree test dependencies (Issue #2326). Backend tests read these files
  # from outside backend/, and ops tests drive these backend files. Neither case
  # returns, so the path still gets its normal tree selection below. Keep both
  # lists aligned with backend-quality.yml / ops-suite.yml push.paths.
  case "$path" in
    ops/data_inspect.py|ops/official_decks/*|ops/seeds/marketing_demo.json|docs/registry.yml|docs/reference/testing/backend_strategy.md|ios/BooksAndVocab/Views/Podcast/PodcastAccess.swift)
      backend=true
      ;;
    backend/ops_cli.py|backend/ops_edit.py|backend/src/kg/ops_*|backend/tests/ops_helpers.py)
      ops=true
      ;;
  esac

  # lab/podcast tests run in the Linux ops suite (lab-podcast group, Issue #2064);
  # the rest of lab/ keeps routing fail-closed.
  case "$path" in
    lab/podcast/*)
      ops=true
      return
      ;;
  esac

  # These scripts are covered by the Linux ops suite but live outside ops/.
  case "$path" in
    devops.sh|start.sh|backend/restart_kg.sh|backend/view_logs.sh|lab/podcast/start.sh|scripts/ios_token_lint.sh|.claude/skills/app-debug/find-polluter.sh|.claude/skills/ios-simulator-verification/scripts/run_ui_evidence.sh|.claude/skills/ios-simulator-verification/scripts/test_run_ui_evidence.sh)
      ops=true
      return
      ;;
  esac

  case "$path" in
    .github/workflows/backend-quality.yml)
      backend=true
      ops=true
      return
      ;;
    .github/workflows/ops-suite.yml)
      ops=true
      return
      ;;
    .github/workflows/ios-quality.yml)
      ops=true
      ios=true
      return
      ;;
    .github/workflows/*)
      ops=true
      return
      ;;
  esac

  # These files feed the real iOS build/test entrypoints or UI World fixture
  # validation. Keep this closure aligned with ios-quality.yml push.paths.
  case "$path" in
    ios/*)
      ios=true
      return
      ;;
    ops/ios_*.sh|ops/lib/ios_*.sh|ops/lib/signal_traps.sh|ops/lib/project_python.sh|ops/lib/fixture_dataset_env.sh|ops/lib/userland_compat.sh|ops/lib/provenance.py|ops/fixtures/ui_worlds/*|ops/ui_world_manifest.py|ops/review_calendar_clock.py)
      ops=true
      ios=true
      return
      ;;
  esac

  case "$path" in
    backend/*)
      backend=true
      return
      ;;
    ops/*|.claude/*)
      ops=true
      return
      ;;
  esac

  # Documentation and GitHub metadata have their own required checks. They do
  # not justify compiling an unrelated application target. lab/llm_eval is
  # covered by the llm-eval job that pr-gate runs on every PR (Issue #2319).
  case "$path" in
    docs/*|README.md|LICENSE|.github/ISSUE_TEMPLATE/*|.github/PULL_REQUEST_TEMPLATE.md|lab/llm_eval/*)
      return
      ;;
    CLAUDE.md|AGENTS.md|.githooks/*|.gitignore|.gitattributes|.github/dependabot.yml)
      ops=true
      return
      ;;
  esac

  # A new root/runtime surface has no proven ownership yet. Prefer extra CI to
  # a false-green confidence result.
  select_all
}

# Targeted iOS admission. Every failure path returns non-zero and leaves the
# default ios_mode=full / empty selectors untouched (fail-closed).
discover_targeted_selectors() {
  local path="$1" base out line suite_method selectors='' count=0 header_count=''
  base="${path##*/}"

  [[ "$path" =~ ^ios/BooksAndVocabUITests/[A-Za-z0-9_+.-]+UITests\.swift$ ]] || return 1
  case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
    *fixture*|*helper*|*page*|*support*) return 1 ;;
  esac
  [[ -f "$ROOT/$path" && ! -L "$ROOT/$path" ]] || return 1

  # A BooksAndVocabTests source contract that reads this file by path (for
  # example ReviewCardEvidenceContractTests) makes it unit-lane input, and the
  # targeted lane skips that lane. Any grep result other than "no match"
  # (including a read error) keeps full mode.
  local contract_status=0
  grep -rqF --include='*.swift' -- "${path#ios/}" "$ROOT/ios/BooksAndVocabTests" || contract_status=$?
  [[ "$contract_status" -eq 1 ]] || return 1

  out="$(cd "$ROOT" && "$DISCOVERY" --ui --list --file "$path" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1

  while IFS= read -r line; do
    # Only fully qualified method selectors (plus ios_test.sh's own single
    # "matched N tests" header); anything else (suite-only, unknown target,
    # blank/noise line) rejects the whole discovery.
    if [[ "$line" =~ ^-only-testing:BooksAndVocabUITests/([A-Za-z0-9_]+/[A-Za-z0-9_]+)$ ]]; then
      suite_method="${BASH_REMATCH[1]}"
      selectors="${selectors:+$selectors }$suite_method"
      count=$((count + 1))
    elif [[ "$line" =~ ^\[ios_test\]\ matched\ ([0-9]+)\ tests?\ in\ file\  && -z "$header_count" ]]; then
      header_count="${BASH_REMATCH[1]}"
    else
      return 1
    fi
  done <<<"$out"

  [[ -n "$selectors" ]] || return 1
  # A header that disagrees with the selector lines means discovery is not
  # self-consistent; do not trust either side.
  [[ -z "$header_count" || "$header_count" -eq "$count" ]] || return 1
  ios_selectors="$selectors"
  ios_mode=targeted
}

case "$source" in
  all)
    select_all
    ;;
  stdin)
    while IFS= read -r path || [[ -n "$path" ]]; do
      classify_path "$path"
    done
    ;;
  '')
    [[ -n "$base" && -n "$head" ]] || { usage >&2; exit 2; }
    git rev-parse --verify "${base}^{commit}" >/dev/null
    git rev-parse --verify "${head}^{commit}" >/dev/null
    # A PR's own changes start at the merge base. The base branch tip moves on
    # after the fork, and a two-point diff would add the reverse of its newer
    # commits to this PR's scope. No common ancestor cannot be scoped, so it
    # selects every suite like any other unclassifiable input.
    if diff_base="$(git merge-base "$base" "$head")"; then
      # --no-renames: a rename must list both its source and destination, or a
      # move out of backend/ would hide the backend change (Issue #2763).
      while IFS= read -r -d '' path; do
        classify_path "$path"
      done < <(git diff --no-renames --name-only -z "$diff_base" "$head")
    else
      printf 'ci_scope_router: no merge base for %s and %s; selecting every suite\n' "$base" "$head" >&2
      select_all
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "$source" != all && "$ios" == true && "$backend" == false && "$ops" == false && "$path_count" -eq 1 ]]; then
  discover_targeted_selectors "$single_path" || { ios_mode=full; ios_selectors=''; }
fi

case "$format" in
  json)
    jq -cn --argjson backend "$backend" --argjson ops "$ops" --argjson ios "$ios" \
      --argjson macos_ops "$macos_ops" --argjson ui_smoke "$ui_smoke" \
      --arg mode "$ios_mode" --arg selectors "$ios_selectors" \
      '{backend:$backend,ops:$ops,ios:$ios,macos_ops:$macos_ops,ui_smoke:$ui_smoke,ios_mode:$mode,ios_selectors:$selectors}'
    ;;
  github-output)
    printf 'backend=%s\nops=%s\nios=%s\nmacos_ops=%s\nui_smoke=%s\nios_mode=%s\nios_selectors=%s\n' \
      "$backend" "$ops" "$ios" "$macos_ops" "$ui_smoke" "$ios_mode" "$ios_selectors"
    ;;
esac
