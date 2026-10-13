#!/usr/bin/env bash
# test_pipefail_echo_grep_guard.sh — 守 #3395：`echo|printf … | grep -q` 在 pipefail 腳本內是 EPIPE 競態。
#
# 為什麼：grep -q 首次命中即退出；若 producer 尚未寫完，echo 收到 EPIPE（141），pipefail 把
# 整條管線判失敗，即使 pattern 其實命中。時序與輸入大小相依，表現為隨機紅（#3381 把 main 弄紅）。
# 修法：here-string `grep -q P <<<"$x"`，沒有 producer 行程，也就沒有競態。
#
# 本測試：
#   1. seeded fixture 證明 guard 會抓到 pipefail 腳本內的違規（正控）；非 pipefail 與註解行不抓。
#   2. 真實 ops/ 樹必須 0 站點。目前沒有合法例外，因此不設 allowlist；將來若要加，須逐條附理由。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SELF="ops/tests/test_pipefail_echo_grep_guard.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kg_pipefail_guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# grep 的旗標區（緊接 grep 之後）必須含 q；不可跨到 `[ -eq 1 ]` 之類的非 grep 旗標。
PATTERN='(^|[^[:alnum:]_.-])(echo|printf)[^|&;]*[|][[:space:]]*grep([[:space:]]+-[[:alpha:]]+)*[[:space:]]+-[[:alpha:]]*q'

# scan <root>：印出 <root>/ops 下、含 pipefail 的 *.sh 中、非註解行的違規站點（file:line: text）。
scan() {
  local root="$1" f
  while IFS= read -r f; do
    if [[ "$f" == "$root/$SELF" ]]; then
      continue
    fi
    if ! grep -q 'pipefail' "$f"; then
      continue
    fi
    awk -v re="$PATTERN" '$0 ~ re && $0 !~ /^[ \t]*#/ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }' "$f"
  done < <(find "$root/ops" -type f -name '*.sh' | LC_ALL=C sort)
}

fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fail=1; }

mkdir -p "$TMP/seeded/ops" "$TMP/clean/ops" "$TMP/nopipefail/ops"

cat >"$TMP/seeded/ops/bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
x="hello"
echo "$x" | grep -q P && echo matched
FIXTURE

cat >"$TMP/clean/ops/good.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
x="hello"
grep -q P <<<"$x" && echo matched
# 註解裡提到 echo "$x" | grep -q P 不算違規
n="$(echo "$x" | grep -c .)"
FIXTURE

cat >"$TMP/nopipefail/ops/loose.sh" <<'FIXTURE'
#!/usr/bin/env bash
x="hello"
echo "$x" | grep -q P && echo matched
FIXTURE

seeded_hits="$(scan "$TMP/seeded")"
if [[ "$seeded_hits" == *"bad.sh:4:"* ]]; then
  ok "seeded pipefail violation is caught"
else
  bad "seeded pipefail violation not caught: [$seeded_hits]"
fi

if [[ -z "$(scan "$TMP/clean")" ]]; then
  ok "here-string form and comment lines are not flagged"
else
  bad "clean fixture wrongly flagged"
fi

if [[ -z "$(scan "$TMP/nopipefail")" ]]; then
  ok "files without pipefail are out of scope"
else
  bad "non-pipefail fixture wrongly flagged"
fi

real_hits="$(scan "$ROOT")"
real_count="$(awk 'END { print NR }' <<<"$real_hits")"
if [[ -z "$real_hits" ]]; then
  ok "real ops tree has 0 echo|printf ... | grep -q sites under pipefail"
else
  bad "real ops tree has $real_count echo|printf ... | grep -q sites under pipefail (first 40):"
  sed -n '1,40p' <<<"$real_hits" >&2
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "pipefail echo|grep guard: all checks passed"
