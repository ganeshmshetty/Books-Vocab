#!/usr/bin/env bash
# Regression tests for the document contract gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
DOC_FIXTURE_PREFIX="docs/.lint_test_$$"
cleanup() {
  rm -f "${DOC_FIXTURE_PREFIX}"-*.md
  rm -rf "$TMP"
}
trap cleanup EXIT

run_capture() {
  local out="$1"; shift
  set +e
  "$@" >"$out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    echo "command failed rc=$rc: $*" >&2
    sed -n '1,120p' "$out" >&2
    exit "$rc"
  fi
}

require_grep() {
  local pattern="$1" file="$2"
  grep -q "$pattern" "$file" || {
    echo "missing pattern '$pattern' in $file" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  }
}

grep -q "docs/registry.yml" CLAUDE.md
grep -q "ops/docs_impact.py" CLAUDE.md
grep -q "ops/docs_lint.sh" CLAUDE.md
grep -q "GitHub Issue" CLAUDE.md

./ops/docs_lint.sh --help >"$TMP/help"
require_grep "docs_lint.sh — docs gate / audit / registry checks" "$TMP/help"
require_grep "Exit code:" "$TMP/help"
require_grep "Compatible with macOS bash 3.2" "$TMP/help"

run_capture "$TMP/registry" ./ops/docs_lint.sh --registry
require_grep "REGISTRY OK" "$TMP/registry"
require_grep "ERROR: 0" "$TMP/registry"

run_capture "$TMP/files" ./ops/docs_lint.sh --files docs/reference/tech_index.md docs/sop/architecture.md
require_grep "ERROR: 0" "$TMP/files"

run_capture "$TMP/audit" ./ops/docs_lint.sh --audit
require_grep "mode=audit" "$TMP/audit"
require_grep "ERROR: 0" "$TMP/audit"

run_capture "$TMP/default" ./ops/docs_lint.sh
require_grep "mode=gate" "$TMP/default"
if grep -q "mode=audit" "$TMP/default"; then
  echo "default docs_lint mode unexpectedly became audit" >&2
  exit 1
fi

if ./ops/docs_lint.sh --definitely-not-a-real-flag >"$TMP/bad" 2>&1; then
  echo "docs_lint accepted an unknown flag" >&2
  exit 1
fi
require_grep "Unknown arg" "$TMP/bad"

if ./ops/docs_lint.sh --files README.md >"$TMP/nondoc" 2>&1; then
  echo "docs_lint accepted a non-document path" >&2
  exit 1
fi
require_grep "只接受 docs/.*.md" "$TMP/nondoc"

if ./ops/docs_lint.sh --files docs/does-not-exist.md >"$TMP/missing" 2>&1; then
  echo "docs_lint accepted a missing document" >&2
  exit 1
fi
require_grep "路徑不存在" "$TMP/missing"

make_meta() {
  local file="$1" anchor="$2"
  cat >"$file" <<EOF
<!-- doc-meta
tier: reference
authority: derived
update_trigger: manual
scope:
  - ops/docs_lint.sh
verified_against: $anchor
-->
# Fixture
EOF
}

conflict="${DOC_FIXTURE_PREFIX}-conflict.md"
make_meta "$conflict" "$(git rev-parse HEAD)"
left_marker="$(printf '%s' '<' '<' '<' '<' '<' '<' '<')"
middle_marker="$(printf '%s' '=' '=' '=' '=' '=' '=' '=')"
right_marker="$(printf '%s' '>' '>' '>' '>' '>' '>' '>')"
printf '%s\n' "$left_marker HEAD" "ours" "$middle_marker" "theirs" "$right_marker branch" >>"$conflict"
if ./ops/docs_lint.sh --files "$conflict" >"$TMP/conflict.out" 2>&1; then
  echo "docs_lint did not reject conflict markers" >&2
  exit 1
fi
require_grep "衝突標記" "$TMP/conflict.out"

setext="${DOC_FIXTURE_PREFIX}-setext.md"
make_meta "$setext" "$(git rev-parse HEAD)"
setext_marker="$middle_marker"
printf '%s\n' "Setext heading" "$setext_marker" "This is ordinary Markdown." >>"$setext"
run_capture "$TMP/setext.out" ./ops/docs_lint.sh --files "$setext"
require_grep "ERROR: 0" "$TMP/setext.out"

orphan="${DOC_FIXTURE_PREFIX}-orphan.md"
orphan_sha="$(git -c user.email=docs-lint@example.test -c user.name='docs-lint fixture' commit-tree 'HEAD^{tree}' -m 'docs lint orphan fixture')"
if git merge-base --is-ancestor "$orphan_sha" HEAD; then
  echo "fixture commit unexpectedly reachable" >&2
  exit 1
fi
make_meta "$orphan" "$orphan_sha"
if ./ops/docs_lint.sh --files "$orphan" >"$TMP/orphan.out" 2>&1; then
  echo "docs_lint did not reject unreachable verified_against" >&2
  exit 1
fi
require_grep "不可達" "$TMP/orphan.out"
require_grep "re-anchor" "$TMP/orphan.out"

reachable="${DOC_FIXTURE_PREFIX}-reachable.md"
make_meta "$reachable" "$(git rev-parse HEAD)"
run_capture "$TMP/reachable.out" ./ops/docs_lint.sh --files "$reachable"
require_grep "ERROR: 0" "$TMP/reachable.out"


# #2820: scratch files live in a private mktemp dir cleaned by an EXIT trap,
# never at predictable /tmp paths.
if grep -n '/tmp/kg_docs_' ops/docs_lint.sh; then
  echo "docs_lint.sh still uses fixed /tmp/kg_docs_* paths" >&2
  exit 1
fi
mkdir "$TMP/scratch"
TMPDIR="$TMP/scratch" run_capture "$TMP/scratch.out" ./ops/docs_lint.sh --files docs/reference/tech_index.md
if [ -n "$(ls -A "$TMP/scratch")" ]; then
  echo "docs_lint.sh leaked scratch files into TMPDIR:" >&2
  ls -A "$TMP/scratch" >&2
  exit 1
fi

echo "docs-lint tests: PASS"
