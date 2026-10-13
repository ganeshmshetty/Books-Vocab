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

# #2923: §2.5a must name the protected names the run guard enforces and list the legitimate
# maintenance commands it blocks; every 擋／允許 row must agree with devops_run_is_blocked.
require_grep '^#### 2\.5a ' docs/sop/backup_restore.md
awk '/^#### 2\.5a /{f=1;next} /^#+ /{f=0} f' docs/sop/backup_restore.md >"$TMP/sop_25a.txt"
require_grep '受保護名稱' "$TMP/sop_25a.txt"
require_grep 'rm -rf ~/kg-prod/backend/.venv' "$TMP/sop_25a.txt"
require_grep 'cd ~/kg-prod/backend && cp .env.example .env' "$TMP/sop_25a.txt"
require_grep 'VACUUM INTO' "$TMP/sop_25a.txt"
require_grep 'find \. -name __pycache__ -exec rm' "$TMP/sop_25a.txt"
# shellcheck source=../lib/devops_run_guard.sh
source ops/lib/devops_run_guard.sh
awk '/^路徑級受保護名稱：/' "$TMP/sop_25a.txt" >"$TMP/protected_names.txt"
require_grep '路徑級受保護名稱' "$TMP/protected_names.txt"
if grep -q 'docker volumes' "$TMP/protected_names.txt"; then
  echo "backup_restore.md §2.5a lists docker volumes as a path-level protected name; the guard only blocks docker volume commands (#2923)" >&2
  exit 1
fi
for name in kg-data kg-prod /app/data knowledge_graph_api knowledge-graph-api_data; do
  require_grep "\`$name\`" "$TMP/protected_names.txt"
  devops_run_is_blocked run "rm -rf $name" || {
    echo "protected name '$name' is listed in backup_restore.md §2.5a but the run guard does not block it (#2923)" >&2
    exit 1
  }
done
awk -F'|' '/^\|/ && !/^\|---/' "$TMP/sop_25a.txt" >"$TMP/guard_table.txt"
guard_rows=0
guard_mismatch=0
while IFS='|' read -r _ sub cmd want _; do
  sub="$(printf '%s' "$sub" | sed -E 's/^ +| +$//g')"
  cmd="$(printf '%s' "$cmd" | sed -E 's/^ +| +$//g; s/^`//; s/`$//')"
  want="$(printf '%s' "$want" | sed -E 's/^ +| +$//g')"
  case "$want" in
    擋|允許) ;;
    *) continue ;;
  esac
  guard_rows=$((guard_rows + 1))
  if devops_run_is_blocked "$sub" "$cmd"; then got="擋"; else got="允許"; fi
  if [ "$got" != "$want" ]; then
    echo "backup_restore.md §2.5a row disagrees with devops_run_is_blocked: [$sub] $cmd (doc=$want, guard=$got)" >&2
    guard_mismatch=$((guard_mismatch + 1))
  fi
done <"$TMP/guard_table.txt"
if [ "$guard_rows" -lt 8 ]; then
  echo "backup_restore.md §2.5a table has $guard_rows 擋/允許 rows, expected >=8" >&2
  exit 1
fi
if [ "$guard_mismatch" -ne 0 ]; then
  exit 1
fi

# #2923 (owner decision 2026-10-13, option A): direct ssh is the single documented human exception and
# it covers §2.5 only. Every other restore step stays behind devops_run_guard: §2.6 chown is guard-blocked
# and §2.7 docker compose is guard-allowed, both pinned in the §2.5a table above; the §2.5 mv/tar lines
# are pinned as guard-blocked, which is the stated reason for the exception.
awk '/^### 2\.5 /{f=1;next} /^#### 2\.5a /{f=0} f' docs/sop/backup_restore.md >"$TMP/sop_25.txt"
require_grep 'direct ssh' "$TMP/sop_25.txt"
require_grep '唯一' "$TMP/sop_25.txt"
awk '/^### 2\.6 /{f=1} /^## 4\. /{f=0} f' docs/sop/backup_restore.md >"$TMP/sop_post25.txt"
if grep -q 'direct ssh' "$TMP/sop_post25.txt"; then
  echo "backup_restore.md documents direct ssh outside §2.5, the single human exception (#2923)" >&2
  exit 1
fi
require_grep '不屬 §2.5 例外' "$TMP/sop_post25.txt"
require_grep 'chown -R chenliangyu ~/kg-data.*擋' "$TMP/sop_25a.txt"
require_grep 'mv ~/kg-data ~/kg-data.broken.*擋' "$TMP/sop_25a.txt"
require_grep 'tar xzf /tmp/2026-05-31.tar.gz -C ~/.*擋' "$TMP/sop_25a.txt"
require_grep 'docker compose up -d.*允許' "$TMP/sop_25a.txt"

# #3264: tech_index CI row names every merge-group required input; SOP states the PR-side clarification.
ci_row="$(grep -m1 '^| CI |' docs/reference/tech_index.md || true)"
for ctx in short-gate ios-quality ops-suite; do
  grep -q "\`$ctx\`" <<< "$ci_row" || { echo "tech_index.md CI row lacks required input $ctx (#3264)" >&2; exit 1; }
done

# #3300: the CI row's merge-group `required` contexts must equal the required job's `needs` as an exact set.
merge_group_contexts() {
  sed -n 's/.*merge-group 的 `required` 聚合\(.*\)；同名 context.*/\1/p' <<<"$1" | grep -o '`[^`]*`' | tr -d '`' | grep -vx 'required' | sort || true
}
# rc: 0 match, 1 real set mismatch, 2 CI row or workflow not parsed, 3 ruby unavailable (#3310, #3329).
merge_group_contexts_match() {
  local wf="$1" got want
  command -v ruby >/dev/null 2>&1 || { echo "ruby unavailable: cannot read $wf needs (#3310)" >&2; return 3; }
  got="$(merge_group_contexts "$2")"
  [ -n "$got" ] || { echo "merge-group row not parsed from tech_index.md CI row (#3310)" >&2; return 2; }
  want="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["required"]["needs"].sort' "$wf" 2>"$TMP/merge-group-want.err")" \
    || { echo "workflow unparsed: cannot load $wf needs (#3329)" >&2; cat "$TMP/merge-group-want.err" >&2; return 2; }
  [ "$got" = "$want" ] || { echo "tech_index.md CI row merge-group contexts differ from merge-group-required.yml needs (#3300)" >&2; return 1; }
}
merge_group_contexts_match .github/workflows/merge-group-required.yml "$ci_row" || exit 1
# red: a drifted workflow copy (one need dropped, one ghost need added) must be detected.
ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); w["jobs"]["required"]["needs"].delete("ops-suite"); File.write(ARGV[1], w.to_yaml)' \
  .github/workflows/merge-group-required.yml "$TMP/merge-group-drop.yml"
ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); w["jobs"]["required"]["needs"] << "ghost-gate"; File.write(ARGV[1], w.to_yaml)' \
  .github/workflows/merge-group-required.yml "$TMP/merge-group-add.yml"
for drifted in "$TMP/merge-group-drop.yml" "$TMP/merge-group-add.yml"; do
  rc=0; merge_group_contexts_match "$drifted" "$ci_row" 2>/dev/null || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "docs-lint did not detect merge-group need drift in $drifted (rc=$rc, #3300)" >&2
    exit 1
  fi
done
# #3310: a row that sed cannot extract is "not parsed" (rc 2), never a set mismatch (rc 1).
bad_row="${ci_row/；同名 context/; 同名 context}"
rc=0; merge_group_contexts_match .github/workflows/merge-group-required.yml "$bad_row" 2>"$TMP/unparsed.err" || rc=$?
if [ "$rc" -ne 2 ] || ! grep -q 'not parsed' "$TMP/unparsed.err" || grep -q 'differ' "$TMP/unparsed.err"; then
  echo "unparsed CI row not reported as 'not parsed' with rc 2 (rc=$rc, #3310)" >&2
  cat "$TMP/unparsed.err" >&2
  exit 1
fi
# #3329: a malformed merge-group workflow (ruby YAML load fails) is "workflow unparsed" (rc 2), never a set mismatch.
printf 'jobs:\n  required:\n    needs: [short-gate\n' >"$TMP/merge-group-malformed.yml"
rc=0; merge_group_contexts_match "$TMP/merge-group-malformed.yml" "$ci_row" 2>"$TMP/malformed.err" || rc=$?
if [ "$rc" -ne 2 ] || ! grep -q 'workflow unparsed' "$TMP/malformed.err" || grep -q 'differ' "$TMP/malformed.err"; then
  echo "malformed merge-group workflow not reported as 'workflow unparsed' with rc 2 (rc=$rc, #3329)" >&2
  cat "$TMP/malformed.err" >&2
  exit 1
fi
# #3358: the ruby/Psych detail (line/column) must reach stderr, not only the generic "workflow unparsed" message.
grep -Eq 'line [0-9]+' "$TMP/malformed.err" && grep -Eq 'column [0-9]+' "$TMP/malformed.err" \
  || { echo "malformed merge-group workflow dropped the Psych line/column detail (#3358)" >&2; cat "$TMP/malformed.err" >&2; exit 1; }
# #3344: a nonexistent merge-group workflow path is "workflow unparsed" (rc 2), never a set mismatch.
rc=0; merge_group_contexts_match "$TMP/does-not-exist.yml" "$ci_row" 2>"$TMP/missing-wf.err" || rc=$?
if [ "$rc" -ne 2 ] || ! grep -q 'workflow unparsed' "$TMP/missing-wf.err" || grep -q 'differ' "$TMP/missing-wf.err"; then
  echo "missing merge-group workflow not reported as 'workflow unparsed' with rc 2 (rc=$rc, #3344)" >&2
  cat "$TMP/missing-wf.err" >&2
  exit 1
fi
# #3310: no ruby on PATH is reported as "ruby unavailable" (rc 3), never as a set mismatch.
noruby="$TMP/noruby-bin"; mkdir -p "$noruby"
for t in sed grep tr sort; do ln -s "$(command -v "$t")" "$noruby/$t"; done
rc=0; (PATH="$noruby"; hash -r; merge_group_contexts_match .github/workflows/merge-group-required.yml "$ci_row") 2>"$TMP/noruby.err" || rc=$?
if [ "$rc" -ne 3 ] || ! grep -q 'ruby unavailable' "$TMP/noruby.err" || grep -q 'differ' "$TMP/noruby.err"; then
  echo "missing ruby not reported as 'ruby unavailable' with rc 3 (rc=$rc, #3310)" >&2
  cat "$TMP/noruby.err" >&2
  exit 1
fi
grep -q 'PR 側.*`pr-gate.yml`.*只 needs `repo-gate`' docs/sop/delivery_control_dogfood.md || { echo "SOP lacks PR-side required clarification (#3264)" >&2; exit 1; }

echo "docs-lint tests: PASS"
