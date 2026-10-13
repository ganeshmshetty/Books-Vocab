#!/usr/bin/env bash
# test_userland_portability.sh — BSD(macOS) / GNU(linux) userland 可攜性守衛（IMP-0058）。
#
# 為什麼是一支測試而不是「到 linux 上再說」：兩個病灶都只在 GNU userland 顯形，而開發機
# 是 macOS。靠實機分歧當判準等於永遠沒有判準——所以這裡把「另一種 userland」做成可注入的
# 東西（合成語料 + PATH 前置的 GNU shim），在 macOS 上就能證明修法真的成立。
#
# 三章，每章都先立正控（先證明探針會響，才有資格相信它的沉默）：
#   A. SIGPIPE：`grep -r … | head -N` 在 pipefail 下傳出非零。用合成語料現場證明這件事
#      在本機是真的，並證明 `sed -n '1p'` 不會。
#   B. lint：ops/ 底下不得再出現 `grep -r` 接 head 的管線。
#   C. GNU userland shim：用假的 GNU stat/date 前置 PATH，重跑 ops/tests/test_ios_cache_evict.sh，
#      必須全綠。本機若已是 GNU userland 就明示跳過（原生執行本身即證明）。

set -o pipefail

WORKTREE="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # 供 B 章具名排除自己
TMPROOT="$(mktemp -d -t kg_userland_portability_XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section(){ echo ""; echo "── $* ──"; }

# ── A. SIGPIPE 正控 ──────────────────────────────────────────────────────────
# 語料要夠大：上游一次寫完就退場的話 grep 根本收不到 SIGPIPE，探針會假性沉默。
section "SIGPIPE positive control"
corpus="$TMPROOT/corpus"; mkdir -p "$corpus"
for i in $(seq 1 20); do
  seq 1 10000 | awk '{printf "func testAlpha%06d() {}\n", $1}' > "$corpus/f$i.swift"
done
rc=0; grep -rhoE 'func test[A-Za-z0-9_]+' "$corpus" 2>/dev/null | head -1 >/dev/null || rc=$?
[[ "$rc" -ne 0 ]] && ok "head -1 在 pipefail 下傳出非零 rc=${rc}（語料夠大，探針有效）" \
  || fail_t "head -1 rc=0（期望上游因 early-close 非零）— 探針壞了，B 章守的是空氣"
rc=0; grep -rhoE 'func test[A-Za-z0-9_]+' "$corpus" 2>/dev/null | sed -n '1p' >/dev/null || rc=$?
[[ "$rc" -eq 0 ]] && ok "sed -n 1p rc=0（讀完整個 stream，是正確替代）" \
  || fail_t "sed -n 1p rc=${rc}（期望 0）"

# ── B. lint：全 ops/ 掃描 ────────────────────────────────────────────────────
# 掃全 ops/ 而不是只盯 IMP-0058 點名的那個檔：壞的是形狀不是那一行。實測今天全 repo
# 只有 test_ios_test_discovery.sh:272,312 命中，所以擴大掃描是零成本的。
#
# **本檔具名排除自己**：A 章刻意寫了一條真的 `grep -r … | head -1` 當正控，掃到自己會
# 永遠紅。排除只針對這一個路徑，不是萬用 ignore——而且下面會斷言這條排除真的觸發過，
# 否則「排除失效」就會偽裝成「檔案很乾淨」。
section "no grep -r pipeline ends in head (ops/**/*.sh)"

# 逐行判定抽成一個述詞，好讓下面的負控能**雙向**驗它：規則恆真與規則恆假都會讓這章的
# 沉默失去意義，而兩者長得一樣綠。
#
# **註解行不算數**：bash 不執行 `#` 開頭的行，所以註解裡寫出壞形狀不可能造成 SIGPIPE。
# 這不是放寬而是精確化——不這樣做的話，本檔與 test_ops_ci_coverage.sh 裡任何一句「不要
# 寫 grep -r … | head -1」的散文都會讓守衛轉紅，於是壓力會落到「別把 bug 講清楚」而不是
# 「別把 bug 寫進去」。（實測：第一版沒有這條，被自己的 IMP-0058 註解抓成假陽性。）
# **形狀字彙必須比「我當初打的那一行」寬**。第一版寫死 `*'grep -r'*` 與 `*'| head -'*`，
# 漏掉 `-R`（follow-symlink 拼法，實測同樣 141）、`| head`（不帶 -N）、`|head -1`、
# `|  head -1`。那批漏網之所以撐過 15 個突變，是因為負控只餵述詞已經會抓的形狀——
# 自我確認：證明了規則不恆真也不恆假，卻從沒問過「該抓而沒抓的是什麼」。
#
# **刻意不涵蓋非遞迴 grep 接 head**：`cat f | grep x | head -1` 同樣可能 141，但那是
# 大小/時序問題（IMP-0058 自己記載 :272 只有 1852 bytes 所以一直沒炸），而本 repo 有數處
# 非遞迴 `grep | head -1` 是以 `|| true` 收尾的合法寫法。把它們一起抓等於製造假陽性，
# 而假陽性會讓人關掉這條測試。遞迴 grep 要走完目錄樹，是可靠會炸的那一種。
GREP_RECURSIVE_RE='(^|[^A-Za-z0-9_])grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-[A-Za-z]*[rR]|--recursive)'
PIPE_HEAD_RE='\|[[:space:]]*head([[:space:]]|$|[^A-Za-z0-9_])'
is_bad_line() {  # $1=整條邏輯行；壞形狀 → rc 0
  local body="$1"
  while [[ "$body" == [[:space:]]* ]]; do body="${body#?}"; done
  [[ "$body" == '#'* ]] && return 1
  [[ "$body" =~ $GREP_RECURSIVE_RE ]] || return 1
  [[ "$body" =~ $PIPE_HEAD_RE ]]
}

# 判定的單位必須是**邏輯行**不是物理行。壞形狀是「同一條管線裡同時有 grep -r 與 | head -」，
# 而續行寫法在本 repo 很常見（ops/lib/ios_cache_evict.sh:52-55 那條 find|stat|sort 就是）：
#     grep -rhoE 'x' dir \
#       | head -1
# 只看物理行的話兩邊各缺一半，整條漏掉——而它跟單行版是同一個 bug。
# 註解行不接續：bash 的註解到行尾為止，行尾的 `\` 不構成續行。
#
# 相依（載重且不明顯）：awk 的 `[[:space:]]` 字元類。若某個 awk 不支援它，縮排過的註解
# 就剝不掉前導空白、`iscomment` 判成 0，於是「行尾有反斜線的縮排註解」會往下接一行——
# 而接出來的邏輯行以 `#` 開頭又會被 is_bad_line 跳過，等於無聲漏掉。macOS awk
# (20200816) / gawk / mawk 三者實測皆支援。
logical_lines() {  # $1=檔案；印 "<起始物理行號>:<邏輯行>"
  awk '
    function flush() { if (buf != "") { print start ":" buf; buf = "" } }
    {
      stripped = $0; sub(/^[[:space:]]+/, "", stripped)
      if (buf == "") { start = NR; iscomment = (substr(stripped, 1, 1) == "#") }
      buf = (buf == "") ? $0 : buf " " $0
      if (!iscomment && $0 ~ /\\$/) { sub(/\\$/, "", buf); next }
      flush()
    }
    END { flush() }
  ' "$1"
}

# 負控：**must-catch 那半要列出述詞「該抓」的形狀變體，不能只列它已經會抓的**，否則
# 負控就是自我確認（第一版正是如此，於是 -R / 無 -N / 無空白三種漏網撐過了 15 個突變）。
# must-not-catch 那半守另一個方向：規則恆真一樣安靜。joiner 另驗接續行、不吃註解。
probe_ok=1
for shape in \
  "PAT=\"\$(grep -rhoE 'x' \"\$D\" | head -1)\"" \
  "PAT=\"\$(grep -Rn 'x' dir | head -1)\"" \
  "PAT=\"\$(grep -rn 'x' dir | head)\"" \
  "PAT=\"\$(grep -rn 'x' dir |head -1)\"" \
  "PAT=\"\$(grep -rn 'x' dir |  head -1)\"" \
  "PAT=\"\$(grep --recursive 'x' dir | head -1)\"" \
  "PAT=\"\$(grep -n -r 'x' dir | head -1)\"" \
; do
  is_bad_line "$shape" || { probe_ok=0; echo "    負控 must-catch 漏掉: $shape" >&2; }
done
for shape in \
  "  # 註解裡寫 grep -r … | head -1 只是敘述" \
  "PAT=\"\$(grep -rhoE 'x' \"\$D\" | sed -n '1p')\"" \
  "cat f | head -1" \
  "PAT=\"\$(grep -oE 'x' f | head -1)\"" \
  "rg --files dir | head -1" \
  "grep -rn 'x' dir | header_fn" \
; do
  is_bad_line "$shape" && { probe_ok=0; echo "    負控 must-not-catch 誤抓: $shape" >&2; }
done
[[ "$probe_ok" -eq 1 ]] && ok "偵測述詞雙向有效（7 種遞迴變體全抓、6 種非壞形狀全放）" \
  || fail_t "偵測述詞負控失敗 — 這章不管是紅是綠都不算數"

joiner_fix="$TMPROOT/joiner.sh"
{
  printf 'BAD="$(grep -rhoE %s x%s dir \\\n' "'" "'"
  printf '  | head -1)"\n'
  printf 'GOOD="$(grep -rhoE %s x%s dir \\\n' "'" "'"
  printf "  | sed -n '1p')\"\n"
  printf '# 註解結尾有反斜線 \\\n'
  printf 'INNOCENT="$(grep -r x dir)"\n'
} > "$joiner_fix"
joined="$(logical_lines "$joiner_fix")"
joiner_ok=1
grep -q "^1:.*grep -r.*| head -" <<< "$joined"     || joiner_ok=0   # 續行接起來了
grep -q "^3:.*grep -r.*sed -n '1p'" <<< "$joined"  || joiner_ok=0   # 安全版也接起來
grep -q "^6:INNOCENT" <<< "$joined"                || joiner_ok=0   # 註解沒吃掉下一行
[[ "$joiner_ok" -eq 1 ]] && ok "續行 joiner 有效（接續行、不吃註解後的下一行）" \
  || { fail_t "續行 joiner 負控失敗 — 多行管線會整條漏掉"; printf '%s\n' "$joined" | sed 's/^/      /' >&2; }

ANCHOR="$WORKTREE/ops/test_ios_test_discovery.sh"   # 本票原始病灶，兼掃描範圍的正控
scanned=0; anchor_lines=0; self_excluded=0; bad=0
while IFS= read -r f; do
  if [[ "$f" == "$SELF" ]]; then self_excluded=$((self_excluded+1)); continue; fi
  scanned=$((scanned+1))
  while IFS= read -r srcline; do
    [[ -n "$srcline" ]] || continue
    lineno="${srcline%%:*}"; body="${srcline#*:}"
    [[ "$f" == "$ANCHOR" ]] && anchor_lines=$((anchor_lines+1))
    if is_bad_line "$body"; then
      fail_t "${f#"$WORKTREE"/}:$lineno: grep -r 管線接 head — 上游可能因 early-close 非零、破壞 pipefail"
      bad=1
    fi
    # 預篩只認裸字 `grep`，判定一律交給 is_bad_line。預篩若也寫成 'grep -r'，就會把
    # 述詞剛擴出去的 -R / --recursive 再收回來——兩處各有一份形狀知識是必然會不一致的。
  done < <(logical_lines "$f" 2>/dev/null | grep -- 'grep' || true)
done < <(find "$WORKTREE/ops" -type f -name '*.sh' | sort)

if (( self_excluded != 1 )); then
  fail_t "自我排除觸發 $self_excluded 次（期望 1）— SELF 解析壞了，這章的綠燈不算數"
elif (( anchor_lines == 0 )); then
  fail_t "錨點檔 $ANCHOR 裡找不到任何 grep 行 — 掃描範圍壞了，不是檔案乾淨"
elif (( bad == 0 )); then
  ok "掃過 $scanned 支 ops shell 腳本（錨點檔 $anchor_lines 條候選 grep 行），無遞迴 grep→head 管線"
fi

# ── C. GNU userland shim ─────────────────────────────────────────────────────
# 三種模式，**強度不同，所以會明講自己跑的是哪一種**：
#   ① 本機原生就是 GNU（linux）→ 跳過本章，group 的原生執行就是直接證明。
#   ② 本機有真的 GNU coreutils（macOS + brew，`gnubin` 目錄提供不帶 g 前綴的名字）
#      → **前置真 GNU 到 PATH**，這是真量測：真的 GNU stat/date/touch/du/sort 在跑。
#      並且當場把 `%Y≡%m`、`%n≡%N`、`-d '-N hours'≡-v -NH` 三條等價**量出來**。
#      仍然假設的部分要講明：`xargs`/`find`/`grep`/`sed` 來自 findutils/BSD，**不是 GNU**。
#      已知的語意差是 GNU xargs 對空輸入仍執行一次而 BSD 不會——真 linux 上空 cache root
#      會讓 `stat -c '%Y %n'` 收到零個 operand 而 exit 1；無害（stderr 已吞、entries 空），
#      且 case 9 原生覆蓋該形狀，但它確實不在模式②的量測範圍內。
#   ③ 都沒有 → 退回翻譯 shim（把 GNU 形狀轉回 BSD 再交給真 binary）。它證明被測碼
#      **選對分支、用 GNU 形狀的參數呼叫**，但**不**證明 GNU 的實際輸出位元組——
#      那三條等價在這個模式下是假設。假設錯了這裡照樣綠，所以它是最弱的一檔。
# 模式不是散文:下面用「本章實際貢獻幾條斷言」把它釘成數字,②降級成③會讓數字對不上而轉紅,
# 不是只在 stderr 留一行字。
# 任何模式都不取代 CI：`ios-cache-evict` / `ios-test-discovery` 已由本批進
# test_ops_ci_coverage.sh 的 LINUX_GROUPS，linux runner 會原生跑。
section "ios_cache_evict passes under a GNU userland"
gnu_mode=""; pass_before_c="$pass"; fail_before_c="$fail"
# 自動搜尋兩個 Homebrew prefix：Apple Silicon 是 /opt/homebrew，Intel 是 /usr/local。
# 只寫死前者的話，Intel mac 會無聲掉到模式③——正是這段要防的降級。
#
# `KG_GNU_COREUTILS_BIN` 三分岔，**具名了就不准無聲改道**（同 ui_quality_plane 的
# injection-baseline 契約）：
#   未設        → 自動搜尋；都沒有就模式③。
#   設成 `none` → 明示要求模式③（測 fallback 用的接縫，也是刻意選弱模式的說法）。
#   設成路徑    → 必須可用；不可用就**硬失敗**，不 fallback。具名一條錯路徑卻默默跑了
#                 別的東西，正是本批在 userland_compat.sh 抬頭指控的那種安靜改道。
GNU_COREUTILS_BIN=""
if [[ "${KG_GNU_COREUTILS_BIN:-}" == "none" ]]; then
  :
elif [[ -n "${KG_GNU_COREUTILS_BIN:-}" ]]; then
  if [[ -x "$KG_GNU_COREUTILS_BIN/stat" && -x "$KG_GNU_COREUTILS_BIN/date" ]]; then
    GNU_COREUTILS_BIN="$KG_GNU_COREUTILS_BIN"
  else
    fail_t "KG_GNU_COREUTILS_BIN=$KG_GNU_COREUTILS_BIN 沒有可執行的 stat/date — 具名的路徑不可用時不會 fallback（要模式③請明示 none）"
    echo ""
    echo "passed=$pass failed=$fail"
    exit 1
  fi
else
  for cand in /opt/homebrew/opt/coreutils/libexec/gnubin \
              /usr/local/opt/coreutils/libexec/gnubin; do
    if [[ -x "$cand/stat" && -x "$cand/date" ]]; then GNU_COREUTILS_BIN="$cand"; break; fi
  done
fi
if stat --version >/dev/null 2>&1; then
  gnu_mode=native
  echo "  · 模式①跳過：本機已是 GNU userland，group ios-cache-evict 的原生執行就是直接證明" >&2
  ok "GNU 章明示跳過（declared，不是靜默放行）"
elif [[ -n "$GNU_COREUTILS_BIN" ]]; then
  gnu_mode=real
  bin="$GNU_COREUTILS_BIN"
  echo "  · 模式②真 GNU coreutils：$bin" >&2
  # 把翻譯 shim 賴以成立的三條等價**量出來**。這兩條斷言碰到的字串分別由真 BSD
  # /usr/bin/stat 與真 GNU stat 產生，不是由本檔的任何假設產生。
  probe_file="$WORKTREE/ops/lib/userland_compat.sh"
  bsd_out="$(stat -f '%m %N' "$probe_file")"
  gnu_out="$("$bin/stat" -c '%Y %n' "$probe_file")"
  [[ "$bsd_out" == "$gnu_out" ]] \
    && ok "量測：GNU \`stat -c '%Y %n'\` 與 BSD \`stat -f '%m %N'\` 輸出逐字相同" \
    || fail_t "量測：stat 兩版輸出不同 — BSD[$bsd_out] GNU[$gnu_out]（相容層的格式對應是錯的）"
  # 兩次 fork 跨過分鐘邊界就會假紅（實測兩次量測相隔 0.02s，約每 3000 次跑會中一次）。
  # 不一致時重量一次，兩次都不一致才算數——真的格式對應錯誤不會只錯一次。
  bsd_d="$(date -v -3H '+%Y%m%d%H%M')"
  gnu_d="$("$bin/date" -d '-3 hours' '+%Y%m%d%H%M')"
  if [[ "$bsd_d" != "$gnu_d" ]]; then
    bsd_d="$(date -v -3H '+%Y%m%d%H%M')"
    gnu_d="$("$bin/date" -d '-3 hours' '+%Y%m%d%H%M')"
  fi
  [[ "$bsd_d" == "$gnu_d" ]] \
    && ok "量測：GNU \`date -d '-3 hours'\` 與 BSD \`date -v -3H\` 輸出相同" \
    || fail_t "量測：date 兩版輸出不同（連驗兩次）— BSD[$bsd_d] GNU[$gnu_d]"
else
  gnu_mode=shim
  echo "  · 模式③翻譯 shim（本機無 GNU coreutils；此模式不證明 GNU 輸出位元組）" >&2
  bin="$TMPROOT/gnubin"; mkdir -p "$bin"
  # shim 只實作被測碼真的會用到的形狀，其餘一律大聲失敗——沉默的 shim 會把
  # 「呼叫形狀不對」偽裝成「GNU 上沒問題」。
  cat > "$bin/stat" <<'SHIM'
#!/bin/bash
case "${1:-}" in
  --version) echo "stat (GNU coreutils) 9.4"; exit 0 ;;
  -c|--format)
    fmt="$2"; shift 2
    bfmt="${fmt//%Y/%m}"; bfmt="${bfmt//%n/%N}"
    exec /usr/bin/stat -f "$bfmt" "$@" ;;
  -f|--file-system) echo "stat: cannot read file system information" >&2; exit 1 ;;
  *) echo "stat: unsupported in shim: $*" >&2; exit 1 ;;
esac
SHIM
  cat > "$bin/date" <<'SHIM'
#!/bin/bash
case "${1:-}" in
  --version) echo "date (GNU coreutils) 9.4"; exit 0 ;;
  -d|--date)
    spec="$2"; shift 2
    n="$(printf '%s' "$spec" | sed -E 's/^-([0-9]+) hours?$/\1/')"
    case "$n" in ''|*[!0-9]*) echo "date: invalid date '$spec'" >&2; exit 1 ;; esac
    exec /bin/date -v "-${n}H" "$@" ;;
  -v*) echo "date: invalid option -- 'v'" >&2; exit 1 ;;
  *) exec /bin/date "$@" ;;
esac
SHIM
  chmod +x "$bin/stat" "$bin/date"
fi

# 模式 ② 與 ③ 共用同一組正控與同一次執行——差別只在 $bin 是真 GNU 還是翻譯 shim。
if [[ -n "${bin:-}" ]]; then
  # 正控 ①：這個 PATH 真的擋掉了 BSD 旗標。不驗這條的話，PATH 沒生效也會全綠。
  if PATH="$bin:$PATH" date -v -1H '+%Y' >/dev/null 2>&1; then
    fail_t "GNU userland 沒生效（date -v 竟然成功）— 下面那條綠燈沒有意義"
  else
    ok "GNU userland 生效：date -v 被拒"
  fi
  # 正控 ②：GNU 形狀真的能用（否則環境自己壞掉會被誤讀成被測碼壞掉）。
  if PATH="$bin:$PATH" stat --version >/dev/null 2>&1; then
    ok "GNU userland 生效：stat --version rc=0（被測碼會判定成 GNU）"
  else
    fail_t "stat --version 失敗 — 探針自己壞了"
  fi

  if PATH="$bin:$PATH" "$WORKTREE/ops/tests/test_ios_cache_evict.sh" >"$TMPROOT/cev.log" 2>&1; then
    ok "test_ios_cache_evict.sh 在 GNU userland 下全綠"
  else
    fail_t "test_ios_cache_evict.sh 在 GNU userland 下失敗："
    tail -20 "$TMPROOT/cev.log" >&2
  fi
fi

# 模式釘成數字。①=1（跳過）②=5（2 量測 + 2 正控 + 1 執行）③=3（2 正控 + 1 執行）。
# 沒有這條的話，②靜默降級成③只會少兩條 ok、總數仍然「全綠」,而 test_ops.sh 讀的是
# exit code 不是 pass 數——降級就會變成看不見的事。
case "$gnu_mode" in
  native) expect_c=1 ;;
  real)   expect_c=5 ;;
  shim)   expect_c=3 ;;
  *)      expect_c=-1 ;;
esac
# 數的是「跑了幾條斷言」不是「過了幾條」——否則本章真的失敗時會再串一條假的計數失敗。
got_c=$(( (pass - pass_before_c) + (fail - fail_before_c) ))
if (( expect_c < 0 )); then
  fail_t "GNU 章沒有宣告模式 — 無法判斷這章到底驗了什麼"
elif (( got_c == expect_c )); then
  ok "GNU 章模式=${gnu_mode}，貢獻 ${got_c} 條斷言（與該模式的預期相符）"
else
  fail_t "GNU 章模式=${gnu_mode} 應貢獻 ${expect_c} 條斷言，實得 ${got_c} — 模式與實際執行對不上"
fi

echo ""
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
