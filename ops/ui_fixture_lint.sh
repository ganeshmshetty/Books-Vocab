#!/usr/bin/env bash
# ui_fixture_lint.sh — UI 測試裡的 bookshelf fixture id 必須是 BookshelfFixtureID
# 的 rawValue。純文字檢查，秒級，不編譯、不開模擬器。
#
# ── 為什麼存在（IMP-20260806-3ec803）─────────────────────────────────────────
# `BooksAndVocabUITests.swift` 曾傳 `-seedFixture:bookshelf:withBooksLibrary`
# —— 那是 enum 的 **case 名稱**，而 `BookshelfFixtureID` 的 rawValue 是 snake_case
# 的 `with_books_library`。於是 `UITestFixtureSeed+Bookshelf.swift` 的
# `BookshelfFixtureID(rawValue:)` 回 nil，app 在 init 裡 preconditionFailure，
# 測試以「crashed in <external symbol>」形式紅掉。從 2026-06-09 進 repo 到被發現，
# 沒有任何日常 gate 跑過 UI target，所以沒有人知道。
#
# 這支的主張很窄：**那一類錯誤不該需要跑 UI 測試才會發現**。它把「id 不在清單裡」
# 從一場模擬器 crash 降成一行 file:line。它不取代跑 UI 測試（那是
# ops/launchd/com.kg.uisweep.plist 的工作），也不驗 fixture 的內容。
#
# ── 檢查什麼 ────────────────────────────────────────────────────────────────
# 清單來源：BookshelfFixtures.swift 裡 `enum BookshelfFixtureID: String` 區塊的
#           每個 `case x = "y"` 的 y。
# 掃描對象：ios/BooksAndVocabUITests/**.swift 裡的兩種**字面值**呼叫形狀
#           1. -seedFixture:bookshelf:<id>      （extraArgs 直接拼 launch argument）
#           2. .bookshelf("<id>")               （UITestFixture enum 的 associated value）
#           形狀 2 容許括號內空白，也容許 swift-format 把字面值換到下一行
#           （`.bookshelf(\n    "id"\n)`）—— 回報的是**字面值所在的那一行**。
# 刻意不管（三種都沒有可**驗證**的字面值）：
#           a. `-seedFixture:bookshelf:\(id)`   UITestAppLaunch.swift 的建構點
#           b. `case .bookshelf(let id):`       pattern match
#           c. `-seedFixture:bookshelf:book_\(v)` 半字面半插值 —— 拿前綴去比對清單
#              只會產生假陽性（`book_` 當然不在清單裡），所以整筆跳過。
#           （若 IMP-20260806-3ec803 resolution (1) 落地、呼叫端改吃
#           BookshelfFixtureID 本身，字面值會歸零，這支會印一行 note 說「0 個字面
#           呼叫點」而非假裝有在守。）
# 豁免：    行內 `// ui-fixture-allow: <reason>` 跳過該行（同 i18n-allow /
#           token-allow / deadzone-allow 家族）。存在的理由很具體：本 lint 是
#           fast-tier 的 block gate，而在掃描目錄裡寫一行「這裡以前是
#           -seedFixture:bookshelf:withBooksLibrary」的回歸註解是下一個工程師會做的
#           自然舉動 —— 沒有逃生口的 gate 會被繞過，不會被遵守。
#
# ── 退出碼 ──────────────────────────────────────────────────────────────────
#   0  全部 id 合法（或已無字面值呼叫點，附 note）
#   1  有 id 不在清單裡（逐筆印 file:line）
#   2  結構性失敗：清單抽不出來、掃描目錄不存在或沒有 .swift。
#      這幾種**刻意不回 0** —— 一支掃不到東西的 lint 是最容易永遠沉默的那種。
#
# 測試：ops/tests/test_ui_fixture_lint.sh（含負控：注入 camelCase 假 id 必紅）

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENUM_FILE="${KG_UI_FIXTURE_ENUM_FILE:-$ROOT_DIR/ios/BooksAndVocab/Support/Fixtures/Bookshelf/BookshelfFixtures.swift}"
SCAN_DIR="${KG_UI_FIXTURE_SCAN_DIR:-$ROOT_DIR/ios/BooksAndVocabUITests}"

usage() {
  cat <<'EOF'
ui_fixture_lint.sh — assert every bookshelf fixture id used by the UI tests is a
real BookshelfFixtureID rawValue.

Usage:
  ./ops/ui_fixture_lint.sh            # lint; exit 1 on unknown ids, 2 on structural failure
  ./ops/ui_fixture_lint.sh --list     # print the allowlist (BookshelfFixtureID rawValues)
  ./ops/ui_fixture_lint.sh --help

Scanned shapes (literals only):
  -seedFixture:bookshelf:<id>       raw launch argument
  .bookshelf("<id>")                UITestFixture case, incl. wrapped/spaced forms

Not findings (nothing verifiable to check): `\(id)` interpolation, a half-literal
`book_\(variant)`, and `case .bookshelf(let id):`.

Escape hatch: `// ui-fixture-allow: <reason>` on the same line.

Overrides (used by ops/tests/test_ui_fixture_lint.sh to inject fixtures):
  KG_UI_FIXTURE_ENUM_FILE   path to BookshelfFixtures.swift
  KG_UI_FIXTURE_SCAN_DIR    directory scanned recursively for *.swift

Exit codes: 0 clean · 1 unknown id(s) · 2 structural failure (allowlist empty,
scan dir missing/empty) — never a silent green.
EOF
}

err() { echo "[ui-fixture-lint] $*" >&2; }

# rawValues of `enum BookshelfFixtureID: String`. The enum body contains a nested
# `var key: FixtureKey { … }`, so the block ends at a column-0 `}` — not the first
# one seen.
extract_ids() {
  awk '
    /^enum[[:space:]]+BookshelfFixtureID[[:space:]]*:[[:space:]]*String/ { inblock = 1; next }
    inblock && /^}/ { inblock = 0 }
    inblock && match($0, /case[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"[^"]*"/) {
      seg = substr($0, RSTART, RLENGTH)
      raw = substr(seg, index(seg, "\"") + 1)
      sub(/".*/, "", raw)
      if (raw != "") print raw
    }
  ' "$1"
}

# camelCase -> snake_case, for the did-you-mean on the exact regression this exists for.
camel_to_snake() {
  printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list) LIST_ONLY=1 ;;
  "") LIST_ONLY=0 ;;
  *) err "unknown argument: $1"; echo "" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -f "$ENUM_FILE" ]]; then
  err "error: fixture enum file not found: $ENUM_FILE"
  exit 2
fi

KNOWN_IDS="$(extract_ids "$ENUM_FILE")"
if [[ -z "$KNOWN_IDS" ]]; then
  err "error: extracted zero rawValues from $ENUM_FILE"
  err "hint: 'enum BookshelfFixtureID: String' 不見了、被改名或換了形狀。空清單會讓每個呼叫點都變成 unknown，"
  err "      而『放棄檢查、回 0』會讓這支 lint 在 enum 被搬走的那天起永遠沉默 —— 所以這是硬錯誤，不是警告。"
  exit 2
fi

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf '%s\n' "$KNOWN_IDS"
  exit 0
fi

if [[ ! -d "$SCAN_DIR" ]]; then
  err "error: scan directory not found: $SCAN_DIR"
  exit 2
fi

files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && files+=("$f")
done < <(find "$SCAN_DIR" -type f -name '*.swift' | LC_ALL=C sort)

if [[ "${#files[@]}" -eq 0 ]]; then
  err "error: no .swift files under $SCAN_DIR"
  err "hint: 掃不到檔案的 lint 永遠是綠的。UITest 目錄搬家了就改這裡（或 KG_UI_FIXTURE_SCAN_DIR）。"
  exit 2
fi

# Emit one TAB-separated finding per literal call site: file, line, id, snippet.
# Both patterns require at least one id character, which is exactly what excludes
# `\(id)` interpolation and `case .bookshelf(let id):` — neither has a literal to check.
findings="$(awk '
  # A line-local escape hatch, same shape as i18n-allow / token-allow / deadzone-allow.
  /\/\/[[:space:]]*ui-fixture-allow:/ { pending = 0; next }

  {
    rest = $0
    while (match(rest, /-seedFixture:bookshelf:[A-Za-z0-9_]+/)) {
      tok = substr(rest, RSTART, RLENGTH)
      tail = substr(rest, RSTART + RLENGTH, 1)
      # `-seedFixture:bookshelf:book_\(variant)` is half literal, half interpolation.
      # The literal prefix is not an id, so checking it would only ever be a false
      # positive. Skip the whole occurrence rather than accuse `book_`.
      if (tail != "\\") {
        printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, substr(tok, 24), tok
      }
      rest = substr(rest, RSTART + RLENGTH)
    }

    # `.bookshelf(` and its literal may sit on separate lines once swift-format has
    # wrapped the call. `pending` carries the open paren to the next non-blank line;
    # the finding is reported at the literal, which is where an operator must edit.
    if (pending) {
      if (match($0, /^[[:space:]]*"[^"]*"/)) {
        tok = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*"/, "", tok)
        sub(/"$/, "", tok)
        printf "%s\t%d\t%s\t.bookshelf(\"%s\")\n", FILENAME, FNR, tok, tok
      }
      pending = 0
    }

    rest = $0
    while (match(rest, /\.bookshelf\([[:space:]]*"[^"]*"/)) {
      tok = substr(rest, RSTART, RLENGTH)
      sub(/^\.bookshelf\([[:space:]]*"/, "", tok)
      sub(/"$/, "", tok)
      printf "%s\t%d\t%s\t.bookshelf(\"%s\")\n", FILENAME, FNR, tok, tok
      rest = substr(rest, RSTART + RLENGTH)
    }

    # Trailing `.bookshelf(` with nothing after it on this line — arm the wrap check.
    # `.bookshelf(let id)` and `.bookshelf(id)` never reach here (they have a token
    # after the paren), so this cannot resurrect the non-literal exemptions.
    if (match($0, /\.bookshelf\([[:space:]]*$/)) pending = 1
  }
' "${files[@]}")"
# awk exits non-zero on the first unreadable input and emits nothing for later files,
# so a bare capture would scan a partial set and can go green (#2817).
awk_rc=$?
if [[ "$awk_rc" -ne 0 ]]; then
  err "error: awk failed (exit $awk_rc) while scanning $SCAN_DIR — an unreadable .swift file?"
  err "hint: 只掃到一部分檔案的 lint 不能算綠；修好檔案權限後重跑。"
  exit 2
fi

known() { grep -Fxq -- "$1" <<< "$KNOWN_IDS"; }

sites=0
bad=0
while IFS=$'\t' read -r file line id snippet; do
  [[ -z "$file" ]] && continue
  sites=$((sites + 1))
  known "$id" && continue
  bad=$((bad + 1))
  echo "${file#"$ROOT_DIR"/}:$line: unknown bookshelf fixture id \"$id\"  in  $snippet"
  guess="$(camel_to_snake "$id")"
  if [[ "$guess" != "$id" ]] && known "$guess"; then
    echo "    hint: BookshelfFixtureID 的 rawValue 是 snake_case，\"$id\" 看起來是 case 名稱 — did you mean \"$guess\"?"
  fi
done <<< "$findings"

if [[ "$bad" -gt 0 ]]; then
  echo ""
  echo "[ui-fixture-lint] FAIL: $bad unknown id(s) out of $sites literal call site(s) in ${#files[@]} file(s)."
  echo "[ui-fixture-lint] allowlist comes from ${ENUM_FILE#"$ROOT_DIR"/} — run --list to see it."
  exit 1
fi

if [[ "$sites" -eq 0 ]]; then
  echo "[ui-fixture-lint] note: 0 literal call sites across ${#files[@]} file(s)."
  echo "[ui-fixture-lint] 這可能表示呼叫端都已改成型別安全的形式（好事），也可能表示掃描形狀漂了（壞事）。"
  echo "[ui-fixture-lint] 這個綠沒有斷言任何東西 —— 別把它當覆蓋。"
  exit 0
fi

echo "[ui-fixture-lint] ok: $sites literal call site(s) in ${#files[@]} file(s), all ids valid."
