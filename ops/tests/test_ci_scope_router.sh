#!/usr/bin/env bash
# test_ci_scope_router.sh — prove confidence routing is selective but fail-closed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTER="$ROOT/ops/ci_scope_router.sh"

failures=0
pass() {
  printf '✓ %s\n' "$1"
}

fail() {
  printf '✗ %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_plan() {
  local label="$1"
  local paths="$2"
  local expected="$3"
  local actual

  if ! actual="$(printf '%s\n' "$paths" | "$ROUTER" --paths-stdin --format json)"; then
    fail "$label: router command failed"
    return
  fi

  # Only the three suite booleans are asserted here; iOS selector routing has
  # its own assertions below (assert_ios_route).
  if jq -e -n --argjson actual "$actual" --argjson expected "$expected" \
    '($actual | {backend, ops, ios}) == $expected' >/dev/null; then
    pass "$label"
  else
    fail "$label: expected $expected, got $actual"
  fi
}

assert_plan 'backend source selects only backend confidence' \
  'backend/src/kg/app.py' \
  '{"backend":true,"ops":false,"ios":false}'
assert_plan 'iOS source selects only iOS confidence' \
  'ios/BooksAndVocab/App.swift' \
  '{"backend":false,"ops":false,"ios":true}'
assert_plan 'ordinary ops source stays off macOS' \
  'ops/backup_verify.sh' \
  '{"backend":false,"ops":true,"ios":false}'
assert_plan 'iOS shared helper selects ops plus iOS' \
  'ops/lib/project_python.sh' \
  '{"backend":false,"ops":true,"ios":true}'
assert_plan 'lab/podcast source selects only ops confidence (Issue #2064)' \
  'lab/podcast/pipeline.py' \
  '{"backend":false,"ops":true,"ios":false}'
assert_plan 'lab/podcast monitor test selects only ops confidence (Issue #2064)' \
  'lab/podcast/monitor/test_server.py' \
  '{"backend":false,"ops":true,"ios":false}'
assert_plan 'docs-only change avoids unrelated confidence suites' \
  'docs/reference/testing/smoke_checklist.md' \
  '{"backend":false,"ops":false,"ios":false}'
assert_plan 'PR-gate policy change reruns all confidence suites' \
  '.github/workflows/pr-gate.yml' \
  '{"backend":true,"ops":true,"ios":true}'
assert_plan 'confidence verdict policy change reruns all confidence suites' \
  'ops/ci_confidence_verdict.sh' \
  '{"backend":true,"ops":true,"ios":true}'
assert_plan 'confidence verdict contract test reruns all confidence suites' \
  'ops/tests/test_ci_confidence_verdict.sh' \
  '{"backend":true,"ops":true,"ios":true}'
assert_plan 'devops skill roster change selects only backend confidence' \
  '.claude/skills/devops/SKILL.md' \
  '{"backend":true,"ops":false,"ios":false}'
assert_plan 'unknown source fails closed to all confidence suites' \
  'new-top-level-runtime-config.toml' \
  '{"backend":true,"ops":true,"ios":true}'
assert_plan 'PR template (#2319) selects no suite' \
  '.github/PULL_REQUEST_TEMPLATE.md' \
  '{"backend":false,"ops":false,"ios":false}'
assert_plan 'lab/llm_eval is covered by the always-on llm-eval job (#2319)' \
  'lab/llm_eval/runner.py' \
  '{"backend":false,"ops":false,"ios":false}'
for p in CLAUDE.md AGENTS.md .githooks/pre-commit .gitignore .gitattributes .github/dependabot.yml; do
  assert_plan "agent/repo meta $p selects only ops (#2319)" \
    "$p" \
    '{"backend":false,"ops":true,"ios":false}'
done
assert_plan 'unknown new root dir still fails closed (#2319)' \
  'newdir/x' \
  '{"backend":true,"ops":true,"ios":true}'
for p in ops/data_inspect.py ops/official_decks/build_official.py ops/seeds/marketing_demo.json; do
  assert_plan "$p is read by backend tests: ops plus backend (#2326)" \
    "$p" \
    '{"backend":true,"ops":true,"ios":false}'
done
for p in docs/registry.yml docs/reference/testing/backend_strategy.md; do
  assert_plan "$p is read by backend tests: backend only (#2326)" \
    "$p" \
    '{"backend":true,"ops":false,"ios":false}'
done
assert_plan 'PodcastAccess.swift parity: ios plus backend (#2326)' \
  'ios/BooksAndVocab/Views/Podcast/PodcastAccess.swift' \
  '{"backend":true,"ops":false,"ios":true}'
for p in backend/ops_cli.py backend/ops_edit.py backend/src/kg/ops_edit_app.py backend/tests/ops_helpers.py; do
  assert_plan "$p is driven by ops tests: backend plus ops (#2326)" \
    "$p" \
    '{"backend":true,"ops":true,"ios":false}'
done

# macOS runner scope (Issue #2641). `macos_ops` gates the macOS native ops job
# and `ui_smoke` gates the ui-smoke leg; both fail closed (select_all and every
# unclassified path turn them on).
assert_macos() { # label path macos_ops ui_smoke
  local label="$1" path="$2" actual
  if ! actual="$(printf '%s\n' "$path" | "$ROUTER" --paths-stdin --format json)"; then
    fail "$label: router command failed"
    return
  fi
  if jq -e -n --argjson actual "$actual" --argjson m "$3" --argjson u "$4" \
    '$actual.macos_ops == $m and $actual.ui_smoke == $u' >/dev/null; then
    pass "$label"
  else
    fail "$label: expected macos_ops=$3 ui_smoke=$4, got $actual"
  fi
}
for p in ops/backup_verify.sh ops/doctor.py ops/tests/test_main_watch.py lab/podcast/pipeline.py backend/src/kg/app.py docs/reference/tech_index.md .github/workflows/main-watch.yml ios/BooksAndVocabTests/FooTests.swift; do
  assert_macos "no macOS job for $p (#2641)" "$p" false false
done
for p in ops/lldb_crash_forensics.py ops/install_lldb_forensics.sh ops/tests/test_ios_ops_release_heartbeat.sh ops/tests/test_lldb_crash_forensics.sh ops/tests/test_sentry_wiring.sh ops/test_ios_ops.sh ops/test_ops.sh .github/workflows/ops-suite.yml; do
  assert_macos "macOS native ops only for $p (#2641)" "$p" true false
done
for p in ios/BooksAndVocab/Views/Foo.swift ios/BooksAndVocabUITests/FooFlowUITests.swift ops/fixtures/ui_worlds/marketing_demo.json ops/ui_world_manifest.py .github/workflows/ios-quality.yml; do
  assert_macos "ui-smoke only for $p (#2641)" "$p" false true
done
for p in ops/ios_ops.sh ops/ios_test.sh ops/lib/ios_ops_core.sh ops/lib/signal_traps.sh ios/BooksAndVocab.xcodeproj/project.pbxproj ios/Info.plist ios/BooksAndVocab/Services/AppCrashReporting.swift ops/ci_scope_router.sh .github/workflows/pr-gate.yml newdir/x; do
  assert_macos "macOS native ops and ui-smoke for $p (#2641)" "$p" true true
done

if actual="$($ROUTER --all --format json)" \
  && jq -e -n --argjson actual "$actual" '$actual == {backend: true, ops: true, ios: true, macos_ops: true, ui_smoke: true, ios_mode: "full", ios_selectors: ""}' >/dev/null; then
  pass 'manual mode selects all confidence suites'
else
  fail 'manual mode does not select all confidence suites'
fi

if "$ROUTER" --format json >/dev/null 2>&1; then
  fail 'router accepts a missing change source'
else
  pass 'router rejects a missing change source'
fi

if actual="$($ROUTER --base HEAD --head HEAD --format json)" \
  && jq -e -n --argjson actual "$actual" '$actual == {backend: false, ops: false, ios: false, macos_ops: false, ui_smoke: false, ios_mode: "full", ios_selectors: ""}' >/dev/null; then
  pass 'git commit mode classifies an empty diff'
else
  fail 'git commit mode does not classify an empty diff'
fi


# ---------------------------------------------------------------------------
# iOS selector routing (Issue #1051). Targeted is an allow-list of exactly one
# shape; every other input must keep ios_mode=full with no selectors, because a
# wrong "targeted" answer silently skips confidence tests.
# ---------------------------------------------------------------------------
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

make_stub() {
  local name="$1" body="$2"
  # Every stub also asserts the exact discovery argv the router must use.
  {
    printf '#!/usr/bin/env bash\n'
    printf '[[ "$1 $2 $3" == "--ui --list --file" ]] || { echo "bad argv: $*" >&2; exit 64; }\n'
    printf '%s\n' "$body"
  } > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

make_stub ok 'echo "[ios_test] matched 2 tests in file x (BooksAndVocabUITests)"
echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA"
echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testB"'
make_stub no-header 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA"'
make_stub fail 'echo "[ios_test] no tests discovered in file" >&2; exit 1'
make_stub fail-with-output 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA"; exit 1'
make_stub empty 'exit 0'
make_stub suite-only 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests"'
make_stub target-only 'echo "-only-testing:BooksAndVocabUITests"'
make_stub foreign-target 'echo "-only-testing:BooksAndVocabTests/OverviewFlowUITests/testA"'
make_stub noise 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA"
echo "warning: something unexpected"'
make_stub count-mismatch 'echo "[ios_test] matched 5 tests in file x (BooksAndVocabUITests)"
echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA"'
make_stub extra-segment 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/testA/extra"'
make_stub shell-meta 'echo "-only-testing:BooksAndVocabUITests/OverviewFlowUITests/test;rm"'

OVERVIEW='ios/BooksAndVocabUITests/OverviewFlowUITests.swift'

# assert_ios_route <label> <paths> <stub> <expected-mode> <expected-selectors>
assert_ios_route() {
  local label="$1" paths="$2" stub="$3" mode="$4" selectors="$5" actual

  if ! actual="$(printf '%s\n' "$paths" | KG_CI_IOS_SELECTOR_DISCOVERY="$STUBS/$stub" "$ROUTER" --paths-stdin --format json)"; then
    fail "$label: router command failed"
    return
  fi
  if jq -e -n --argjson actual "$actual" --arg mode "$mode" --arg sel "$selectors" \
    '$actual.ios_mode == $mode and $actual.ios_selectors == $sel' >/dev/null; then
    pass "$label"
  else
    fail "$label: expected mode=$mode selectors='$selectors', got $actual"
  fi
}

# Positive: the one admitted shape, with exact Suite/Method selectors (the form
# `ios_test.sh <selector>` accepts), and the plan keeps ios=true only.
assert_ios_route 'single top-level UITests file with discovered selectors is targeted' \
  "$OVERVIEW" ok targeted \
  'OverviewFlowUITests/testA OverviewFlowUITests/testB'
assert_ios_route 'discovery without the ios_test header is accepted when selectors are exact' \
  "$OVERVIEW" no-header targeted 'OverviewFlowUITests/testA'

# A UITests file that a BooksAndVocabTests source contract reads by path
# (ReviewCardEvidenceContractTests, SettingsFixturesTests) is input to the unit
# lane. Targeted mode skips that lane, so such a change must stay full or a
# contract violation merges green (Issue #2114).
for case_path in \
  'ios/BooksAndVocabUITests/ReviewCardLayoutEditorUITests.swift' \
  'ios/BooksAndVocabUITests/SettingsFlowUITests.swift'; do
  assert_ios_route "UITests file read by a unit-test source contract stays full: $case_path" \
    "$case_path" ok full ''
done

# Negative: inputs that would silently lose coverage must fall back to full.
assert_ios_route 'two UITests files fall back to full' \
  "$OVERVIEW
ios/BooksAndVocabUITests/SearchFlowUITests.swift" ok full ''
assert_ios_route 'the same UITests path twice falls back to full' \
  "$OVERVIEW
$OVERVIEW" ok full ''
assert_ios_route 'UITests file plus docs change falls back to full' \
  "$OVERVIEW
docs/reference/tech_index.md" ok full ''
assert_ios_route 'UITests file plus app source falls back to full' \
  "$OVERVIEW
ios/BooksAndVocab/App.swift" ok full ''
assert_ios_route 'UITests file plus ops source falls back to full' \
  "$OVERVIEW
ops/backup_verify.sh" ok full ''
assert_ios_route 'UITests file plus backend source falls back to full' \
  "$OVERVIEW
backend/src/kg/app.py" ok full ''
for case_path in \
  'ios/BooksAndVocabUITests/Helpers/UITestDiagnosticsUITests.swift' \
  'ios/BooksAndVocabUITests/Pages/LoginPageUITests.swift' \
  'ios/BooksAndVocabUITests/FixtureDatasetUITests.swift' \
  'ios/BooksAndVocabUITests/SharedHelperUITests.swift' \
  'ios/BooksAndVocabUITests/PageObjectUITests.swift' \
  'ios/BooksAndVocabUITests/UITestLaunchSupport.swift' \
  'ios/BooksAndVocabUITests/UITestsSupportUITests.swift' \
  'ios/BooksAndVocabUITests/Sub/NestedUITests.swift' \
  'ios/BooksAndVocabUITests/../BooksAndVocab/EvilUITests.swift' \
  'ios/BooksAndVocabUITests/OverviewFlowUITests.swift.bak' \
  'ios/BooksAndVocabUITests/OverviewFlowTests.swift' \
  'ios/BooksAndVocabUITests/Overview FlowUITests.swift' \
  'ios/BooksAndVocabUITests/Overview;FlowUITests.swift' \
  'ios/BooksAndVocabTests/OverviewFlowUITests.swift' \
  'ios/BooksAndVocab/Views/OverviewFlowUITests.swift' \
  'ios/BooksAndVocab.xcodeproj/project.pbxproj' \
  'ios/BooksAndVocab/Debug/Scenarios/StatsViewScenarios.swift' \
  'ios/BooksAndVocab/Views/Vocabulary/Scenes/StatsPresenter.swift' \
  'ios/BooksAndVocabUITests/NotARealFileUITests.swift'; do
  # A permissive stub proves the path rules, not discovery, reject these.
  assert_ios_route "ineligible iOS path falls back to full: $case_path" "$case_path" ok full ''
done
for case_path in \
  '.github/workflows/ios-quality.yml' \
  '.github/workflows/pr-gate.yml' \
  'ops/ci_scope_router.sh' \
  'ops/ci_confidence_verdict.sh' \
  'ops/ios_test.sh' \
  'ops/lib/ios_test_discovery.sh' \
  'ops/tests/test_ci_scope_router.sh' \
  'ops/tests/test_github_workflows.sh' \
  'new-top-level-runtime-config.toml'; do
  assert_ios_route "policy/unknown path falls back to full: $case_path" "$case_path" ok full ''
done
assert_ios_route 'docs-only change reports full (no iOS selection to narrow)' \
  'docs/reference/tech_index.md' ok full ''

# Discovery must be exact; any doubt returns to the full suite.
for bad_stub in fail fail-with-output empty suite-only target-only foreign-target noise count-mismatch extra-segment shell-meta; do
  assert_ios_route "discovery '$bad_stub' falls back to full" "$OVERVIEW" "$bad_stub" full ''
done
assert_ios_route 'missing discovery command falls back to full' \
  "$OVERVIEW" nonexistent-stub full ''

# Manual/--all never narrows, even with a permissive discovery stub.
if actual="$(KG_CI_IOS_SELECTOR_DISCOVERY="$STUBS/ok" "$ROUTER" --all --format github-output)" \
  && grep -qx 'ios_mode=full' <<<"$actual" && grep -qx 'ios_selectors=' <<<"$actual"; then
  pass '--all keeps ios_mode=full with empty selectors'
else
  fail '--all narrowed the iOS suite'
fi

# github-output carries both keys for the workflow, and selectors stay single-line.
if actual="$(printf '%s\n' "$OVERVIEW" | KG_CI_IOS_SELECTOR_DISCOVERY="$STUBS/ok" "$ROUTER" --paths-stdin --format github-output)" \
  && grep -qx 'ios_mode=targeted' <<<"$actual" \
  && grep -qx 'ios_selectors=OverviewFlowUITests/testA OverviewFlowUITests/testB' <<<"$actual" \
  && [[ "$(wc -l <<<"$actual" | tr -d ' ')" == 7 ]]; then
  pass 'github-output exposes ios_mode and single-line ios_selectors'
else
  fail "github-output routing keys wrong: $actual"
fi

# Commit-range mode is NUL-safe: exercise it against a throwaway repository so
# renames (two paths) and hostile filenames (embedded newline) are real diffs.
REPO="$STUBS/repo"
mkdir -p "$REPO/ios/BooksAndVocabUITests"
(
  cd "$REPO"
  git init -q
  git config user.email t@example.invalid
  git config user.name t
  printf 'a\n' > "ios/BooksAndVocabUITests/OverviewFlowUITests.swift"
  printf 'a\n' > "ios/BooksAndVocabUITests/OldNameUITests.swift"
  git add -A
  git commit -q -m base
  printf 'b\n' >> "ios/BooksAndVocabUITests/OverviewFlowUITests.swift"
  git commit -q -am single
  git mv ios/BooksAndVocabUITests/OldNameUITests.swift ios/BooksAndVocabUITests/NewNameUITests.swift
  git commit -q -m rename
  printf 'x\n' > "$(printf 'ios/BooksAndVocabUITests/Evil\nUITests.swift')"
  git add -A
  git commit -q -m newline
)
range_mode() {
  (cd "$REPO" && KG_CI_IOS_SELECTOR_DISCOVERY="$STUBS/ok" "$ROUTER" --base "$1" --head "$2" --format json | jq -r .ios_mode)
}
if [[ "$(range_mode HEAD~3 HEAD~2)" == targeted ]]; then
  pass 'commit-range mode admits a single modified UITests file'
else
  fail 'commit-range mode did not admit a single modified UITests file'
fi
if [[ "$(range_mode HEAD~2 HEAD~1)" == full ]]; then
  pass 'commit-range rename (delete+add) falls back to full'
else
  fail 'commit-range rename was narrowed'
fi
if [[ "$(range_mode HEAD~1 HEAD)" == full ]]; then
  pass 'commit-range hostile newline filename falls back to full'
else
  fail 'commit-range hostile filename was narrowed'
fi

# A rename out of backend/ changes backend: the source path must be classified
# too, so rename detection cannot hide it (Issue #2763).
RREPO="$STUBS/rename-repo"
mkdir -p "$RREPO/backend/src/kg" "$RREPO/ops"
(
  cd "$RREPO"
  git init -q
  git config user.email t@example.invalid
  git config user.name t
  printf 'import os\nprint(os.getcwd())\nx = 1\ny = 2\n' > backend/src/kg/log_format.py
  git add -A
  git commit -q -m base
  git mv backend/src/kg/log_format.py ops/log_format.py
  git commit -q -m rename
)
rename_plan="$(cd "$RREPO" && "$ROUTER" --base HEAD~1 --head HEAD --format json)"
if jq -e '.backend == true' >/dev/null <<<"$rename_plan"; then
  pass 'commit-range rename from backend/ to ops/ selects backend (#2763)'
else
  fail "commit-range rename from backend/ to ops/ dropped backend: $rename_plan"
fi

# A PR's scope is its diff from the merge base. `pull_request.base.sha` is the
# base branch tip, which moves after the PR forks; a two-point base..head diff
# would add the reverse of those newer commits (here: iOS and backend sources
# the PR never touched) and select suites the PR cannot affect.
FORK="$STUBS/fork"
mkdir -p "$FORK/backend/src" "$FORK/ios" "$FORK/docs"
(
  cd "$FORK"
  git init -q -b trunk
  git config user.email t@example.invalid
  git config user.name t
  printf 'a\n' > backend/src/a.py
  printf 'a\n' > ios/App.swift
  git add -A
  git commit -q -m fork-point
  git checkout -q -b pr
  printf 'note\n' > docs/note.md
  git add -A
  git commit -q -m docs-only-pr
  git checkout -q trunk
  printf 'b\n' >> backend/src/a.py
  printf 'b\n' >> ios/App.swift
  git commit -q -am trunk-moves-on
  git checkout -q --orphan unrelated
  git rm -rfq .
  printf 'u\n' > unrelated.txt
  git add -A
  git commit -q -m unrelated-history
)
fork_plan() {
  (cd "$FORK" && "$ROUTER" --base "$1" --head "$2" --format json 2>/dev/null | jq -c '{backend, ops, ios}')
}
if [[ "$(fork_plan trunk pr)" == '{"backend":false,"ops":false,"ios":false}' ]]; then
  pass 'commit-range diffs from the merge base, not the moved base tip'
else
  fail "commit-range leaked base-branch changes into the PR scope: $(fork_plan trunk pr)"
fi
if [[ "$(fork_plan pr trunk)" == '{"backend":true,"ops":false,"ios":true}' ]]; then
  pass 'commit-range still selects suites for the changes after the merge base'
else
  fail "commit-range lost the post-merge-base changes: $(fork_plan pr trunk)"
fi
if [[ "$(fork_plan trunk unrelated)" == '{"backend":true,"ops":true,"ios":true}' ]]; then
  pass 'commit-range without a merge base selects every suite (fail-closed)'
else
  fail "commit-range without a merge base was narrowed: $(fork_plan trunk unrelated)"
fi

if (( failures > 0 )); then
  printf 'ci scope router: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'ci scope router: PASS\n'
