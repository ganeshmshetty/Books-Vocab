#!/usr/bin/env bash
# test_infra_health.sh — infra_health.sh 結構與行為驗證（離線，靠 seam 注入）
#
# Seam:
#   KG_BASE                  指向 stub，取代 ./devops.sh，攔截 `run "<bundle>"`，吐 canned 指標
#   KG_HEALTH_CERT_ENDDATE   注入憑證 notAfter（繞過 openssl 網路呼叫）
#   KG_HEALTH_HTTP_CODE      注入 HTTPS 探針 http_code（繞過 curl）
#
# 注意：stub 直接吐 canned tab 指標（忽略 REMOTE_BUNDLE），故 macOS-native 探針
#   （vm_stat/sysctl 記憶體·swap、cloudflared ingress）的真實解析行為無法在此 stub
#   行使，須靠 standby 實機 `health --json` 驗證（見 receipt）。
#   **兩個例外，都繞過 stub 去行使真實的 bundle**：
#   ① 單行 eval：把 REMOTE_BUNDLE 裡某一行原封抽出來直接 eval（見「Uptime：StartedAt
#      是 UTC」段）。適合驗單一行的解析邏輯。
#   ② **真執行整段 bundle**（較強，見「REMOTE_BUNDLE 真執行」段）：`KG_BASE` 換一支
#      `bash -c "$2"` 的 stub，把整段 bundle 真的跑起來打 fixture repo（`KG_PROD_REPO`），
#      端到端驗**值**。要驗「producer 印的東西消費端真的讀得到」就用這條——純掃 bundle
#      文字的 grep 擋不住「註解列出 key 名」與「\t 換成空格」兩種突變（都實測過）。
#   真執行的 fake docker `logs` 吐 $KG_TEST_LOG_FIXTURE 檔內容（未設則空），用來行使 log_errors_1h 的
#   等級匹配（#2317）。
#   要為其餘 bundle 內的邏輯補真實覆蓋，照抄這兩個模式，不必再擴充 canned stub。
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$WORKSPACE/ops/infra_health.sh"

command -v zsh >/dev/null 2>&1 || {
  echo "FATAL: infra_health fixture requires zsh to exercise the macOS remote-shell contract" >&2
  exit 1
}

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section(){ echo ""; echo "── $* ──"; }
py() { python3 -c "$@"; }  # 純測試斷言用（非 backend env）

# stub：吃 `run "<bundle>"`，無視 bundle，吐固定 tab-separated 指標
STUB="$(mktemp)"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${KG_TEST_EMPTY:-}" ] && exit 0   # 模擬 SSH 逾時：完全無輸出
printf 'disk_pct\t%s\n' "${KG_TEST_DISK:-27}"
printf 'disk_used_gb\t16\n'; printf 'disk_total_gb\t58\n'; printf 'inode_pct\t3\n'
printf 'mem_total_mb\t1896\n'; printf 'mem_avail_mb\t%s\n' "${KG_TEST_MEM_AVAIL:-900}"
printf 'swap_total_mb\t%s\n' "${KG_TEST_SWAP_TOTAL:-2048}"
printf 'swap_used_mb\t%s\n' "${KG_TEST_SWAP_USED:-100}"
printf 'container_health\t%s\n' "${KG_TEST_HEALTH:-healthy}"
printf 'container_status\trunning\n'
printf 'container_restarts\t%s\n' "${KG_TEST_RESTARTS:-0}"
if [ -n "${KG_TEST_UPTIME_PARSE_FAIL:-}" ]; then
  printf 'container_uptime_parse\tfailed\n'
else
  printf 'container_uptime_s\t%s\n' "${KG_TEST_UPTIME:-93600}"
fi
printf 'cpu_pct\t4.2\n'; printf 'mem_pct\t38.0\n'
printf 'ingress\t%s\n' "${KG_TEST_INGRESS:-active}"
printf 'log_errors_1h\t%s\n' "${KG_TEST_ERRS:-0}"
printf 'data_dir_mb\t%s\n' "${KG_TEST_DATA_MB-393}"
# 資料目錄守衛（#2921）：預設健康（目錄在、5 個用戶目錄）。無冒號形式，讓空字串能表達「量不到」。
printf 'data_dir_exists\t%s\n' "${KG_TEST_DATA_EXISTS-yes}"
printf 'users_dir_count\t%s\n' "${KG_TEST_USERS-5}"
# 部署漂移組。預設值刻意是**健康**的（兩 sha 相同、心跳 60s 前、無 poison），否則上面
# 那條「全綠 overall=ok」的既有斷言會紅。
# **一律 ${VAR-default}（無冒號）**：冒號形式在變數「已設但為空字串」時也會代入 default，
# 於是下面「心跳缺值」案例會拿到健康的 now-60 而不是空值，那條斷言就永遠不可能紅。
# 實測：KG_TEST_TICK_EPOCH="" 時 ${VAR:-D} 得 D、${VAR-D} 得空字串。
printf 'deployed_sha\t%s\n' "${KG_TEST_DEPLOYED_SHA-abc1234}"
printf 'deployed_head_sha\t%s\n' "${KG_TEST_HEAD_SHA-abc1234}"
printf 'origin_prod_sha\t%s\n' "${KG_TEST_ORIGIN_SHA-abc1234}"
printf 'reconciler_tick_epoch\t%s\n' "${KG_TEST_TICK_EPOCH-$(( $(date +%s) - 60 ))}"
printf 'reconciler_poison_epoch\t%s\n' "${KG_TEST_POISON_EPOCH-}"
printf 'host_now_epoch\t%s\n' "${KG_TEST_NOW_EPOCH-$(date +%s)}"
EOF
chmod +x "$STUB"

# 假 date：**只**攔「取現在時刻」(`date +%s`)，給 uptime 算式一個可注入的時間源，讓
# 期望值是常數而非「執行當下算出來的東西」。解析呼叫（`date -j -f …`）一律 exec 回真
# date——那正是受測邏輯，替身接手就等於把待測的失效模式從模型裡刪掉。
FAKEBIN="$(mktemp -d)"
cat >"$FAKEBIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == "+%s" ]]; then
  printf '%s\n' "${KG_TEST_FAKE_NOW:?fake date 被呼叫但 KG_TEST_FAKE_NOW 未設}"; exit 0
fi
if [[ "${1:-}" == -j && "${2:-}" == -f && "$#" -ge 5 ]]; then
  # The production bundle uses BSD date because the real remote host is macOS.
  # On Linux, translate only this test seam to GNU date; on macOS, execute the
  # real BSD parser so the test still exercises the production syntax.
  if /bin/date "$@" >/dev/null 2>&1; then
    exec /bin/date "$@"
  fi
  exec /bin/date -u -d "$4" "$5"
fi
exec /bin/date "$@"
EOF
chmod +x "$FAKEBIN/date"
trap 'rm -f "$STUB"; rm -rf "$FAKEBIN"' EXIT

# openssl notAfter 一律英文月名（如 "Sep 13 .. 2026 GMT"）；fixture 須 LC_ALL=C
# 才不會被系統 locale 換成本地月名（如 "7月"），否則無法行使真實解析路徑。
FUTURE_CERT="$(LC_ALL=C date -u -v+30d '+%b %e %T %Y GMT' 2>/dev/null || LC_ALL=C date -u -d '+30 days' '+%b %e %T %Y GMT')"

run_health() {  # 預設健康全綠的環境
  KG_BASE="$STUB" KG_HEALTH_CERT_ENDDATE="${KG_HEALTH_CERT_ENDDATE:-$FUTURE_CERT}" \
  KG_HEALTH_HTTP_CODE="${KG_HEALTH_HTTP_CODE:-200}" \
    bash "$SCRIPT" "$@"
}

# typed probe mode 的端到端 fixture：只模擬 transport，讓受測的
# infra_health.sh producer/parser 自己處理 allowlist、數值不變式與狀態。
PROBE_STUB="$(mktemp)"
cat >"$PROBE_STUB" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = run ] || exit 64
bundle="${2:-}"
[ -z "${KG_PROBE_SECRET_STDOUT:-}" ] || printf '%s\n' "$KG_PROBE_SECRET_STDOUT"
[ -z "${KG_PROBE_SECRET_STDERR:-}" ] || printf '%s\n' "$KG_PROBE_SECRET_STDERR" >&2
case "${KG_PROBE_MODE:-}" in
  memory)
    [[ "$bundle" == *vm_stat* ]] || exit 65
    printf 'mem_total_mb\t%s\n' "${KG_PROBE_MEM_TOTAL:-16384}"
    printf 'mem_avail_mb\t%s\n' "${KG_PROBE_MEM_AVAILABLE:-8192}"
    printf 'swap_total_mb\t%s\n' "${KG_PROBE_SWAP_TOTAL:-4096}"
    printf 'swap_used_mb\t%s\n' "${KG_PROBE_SWAP_USED:-512}"
    ;;
  caddy)
    [[ "$bundle" == *launchctl* ]] || exit 66
    case "${KG_PROBE_STATE:-active}" in
      active) printf 'status\tactive\nlabel\tcom.cloudflare.cloudflared\npid_count\t2\n' ;;
      inactive) printf 'status\tinactive\nlabel\tcom.cloudflare.cloudflared\npid_count\t0\n' ;;
      unknown) printf 'status\tunknown\nlabel\tcom.cloudflare.cloudflared\npid_count\t0\n' ;;
      *) exit 67 ;;
    esac
    ;;
  fail) exit 68 ;;
  *) exit 69 ;;
esac
EOF
chmod +x "$PROBE_STUB"
trap 'rm -f "$STUB" "$PROBE_STUB"; rm -rf "$FAKEBIN" "${FIXPROD:-}"' EXIT

section "Typed macOS memory probe JSON"
probe_err="$(mktemp)"
probe_mem="$(KG_BASE="$PROBE_STUB" KG_PROBE_MODE=memory KG_PROBE_SECRET_STDOUT=secret-out KG_PROBE_SECRET_STDERR=secret-err bash "$SCRIPT" --memory-usage --json 2>"$probe_err" || true)"
if [[ ! -s "$probe_err" ]] \
   && ! grep -qE 'secret-out|secret-err' <<<"$probe_mem" \
   && ! grep -qE 'secret-out|secret-err' "$probe_err" \
   && jq -e 'keys == ["available_mb","swap_total_mb","swap_used_mb","total_mb"] and .total_mb == 16384 and .available_mb == 8192 and .swap_total_mb == 4096 and .swap_used_mb == 512' <<<"$probe_mem" >/dev/null; then
  ok "memory probe exact JSON + secret-safe channels"
else
  fail_t "memory probe contract failed (out=$probe_mem err=$(cat "$probe_err"))"
fi
probe_mem_changed="$(KG_BASE="$PROBE_STUB" KG_PROBE_MODE=memory KG_PROBE_MEM_TOTAL=32768 KG_PROBE_MEM_AVAILABLE=12345 KG_PROBE_SWAP_TOTAL=8192 KG_PROBE_SWAP_USED=7 bash "$SCRIPT" --memory-usage --json 2>"$probe_err" || true)"
echo "$probe_mem_changed" | jq -e '.total_mb == 32768 and .available_mb == 12345 and .swap_total_mb == 8192 and .swap_used_mb == 7' >/dev/null \
  && ok "memory fixture changes alter output" \
  || fail_t "memory fixture change did not alter output"
rm -f "$probe_err"

section "Typed caddy-status probe JSON"
for probe_state in active inactive unknown; do
  probe_err="$(mktemp)"
  probe_caddy="$(KG_BASE="$PROBE_STUB" KG_PROBE_MODE=caddy KG_PROBE_STATE="$probe_state" KG_PROBE_SECRET_STDOUT=secret-out KG_PROBE_SECRET_STDERR=secret-err bash "$SCRIPT" --caddy-status --json 2>"$probe_err" || true)"
  if [[ ! -s "$probe_err" ]] \
     && ! grep -qE 'secret-out|secret-err' <<<"$probe_caddy" \
     && ! grep -qE 'secret-out|secret-err' "$probe_err" \
     && jq -e --arg s "$probe_state" 'keys == ["label","pid_count","status"] and .label == "com.cloudflare.cloudflared" and .status == $s and (($s != "active") or .pid_count >= 1)' <<<"$probe_caddy" >/dev/null; then
    ok "caddy-status $probe_state exact JSON + secret-safe channels"
  else
    fail_t "caddy-status $probe_state contract failed (out=$probe_caddy err=$(cat "$probe_err"))"
  fi
  rm -f "$probe_err"
done

section "Typed caddy launchctl PID fallback"
CADDY_LAUNCH_STUB="$(mktemp)"
CADDY_FAKEBIN="$(mktemp -d)"
cat >"$CADDY_LAUNCH_STUB" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == run ]] || exit 64
PATH="${KG_CADDY_FAKEBIN}:$PATH" zsh -c "${2:-}"
EOF
cat >"$CADDY_FAKEBIN/launchctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == print ]] || exit 64
printf 'state = running\npid = 41046\n'
EOF
cat >"$CADDY_FAKEBIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$CADDY_LAUNCH_STUB" "$CADDY_FAKEBIN/launchctl" "$CADDY_FAKEBIN/pgrep"
probe_err="$(mktemp)"
probe_caddy_launch="$(KG_BASE="$CADDY_LAUNCH_STUB" KG_CADDY_FAKEBIN="$CADDY_FAKEBIN" bash "$SCRIPT" --caddy-status --json 2>"$probe_err" || true)"
if [[ ! -s "$probe_err" ]] \
   && jq -e '.status == "active" and .pid_count == 1 and .label == "com.cloudflare.cloudflared"' <<<"$probe_caddy_launch" >/dev/null; then
  ok "caddy-status derives active PID from launchctl without argv scan"
else
  fail_t "caddy-status launchctl PID fallback failed (out=$probe_caddy_launch err=$(cat "$probe_err"))"
fi
rm -f "$probe_err" "$CADDY_LAUNCH_STUB"
rm -rf "$CADDY_FAKEBIN"

probe_err="$(mktemp)"
probe_fail="$(KG_BASE="$PROBE_STUB" KG_PROBE_MODE=fail KG_PROBE_SECRET_STDOUT=secret-out KG_PROBE_SECRET_STDERR=secret-err bash "$SCRIPT" --memory-usage --json 2>"$probe_err" || true)"
if [[ -z "$probe_fail" ]] && ! grep -qE 'secret-out|secret-err' "$probe_err"; then
  ok "probe transport failure stays non-zero and secret-safe"
else
  fail_t "probe transport failure was swallowed or leaked (out=$probe_fail err=$(cat "$probe_err"))"
fi
rm -f "$probe_err"

section "Syntax"
bash -n "$SCRIPT" && ok "infra_health syntax" || fail_t "infra_health syntax"

section "Text mode：健康全綠"
out="$(run_health 2>&1 || true)"
echo "$out" | grep -q "OK" && ok "text 含整體 OK" || fail_t "text 無整體 OK"
echo "$out" | grep -q "27%" && ok "text 顯示磁碟 27%" || fail_t "text 無磁碟值"
echo "$out" | grep -q "HTTPS 端點" && ok "text 含 HTTPS 探針" || fail_t "text 無 HTTPS 探針"

section "JSON mode：結構契約 + overall=ok"
js="$(run_health --json 2>/dev/null || true)"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);assert "overall" in d and isinstance(d["metrics"],list)' \
  && ok "JSON overall + metrics[]" || fail_t "JSON 結構不符"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);assert d["overall"]=="ok",d["overall"]' \
  && ok "全綠 overall=ok" || fail_t "全綠 overall 非 ok"

section "JSON：raw 數值欄（B agent 回饋）"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);m={x["key"]:x for x in d["metrics"]};assert m["disk_pct"]["raw"]==27,m["disk_pct"];assert isinstance(m["disk_pct"]["raw"],(int,float))' \
  && ok "disk_pct.raw 為純數值 27" || fail_t "disk_pct.raw 非數值"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);m={x["key"]:x for x in d["metrics"]};assert m["ingress"]["raw"] is None,m["ingress"]' \
  && ok "非數值 metric raw=null" || fail_t "ingress.raw 非 null"

section "Cloudflare Tunnel ingress：active → ok"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="ingress"][0];assert g["status"]=="ok" and g["value"]=="active",g' \
  && ok "ingress active → ok" || fail_t "ingress active 未 ok"

section "Cloudflare Tunnel ingress：inactive → crit"
echo "$(KG_TEST_INGRESS=inactive run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="ingress"][0];assert g["status"]=="crit",g;assert d["overall"]=="crit",d["overall"]' \
  && ok "ingress inactive → crit" || fail_t "ingress inactive 未 crit"

section "閾值：磁碟 92% → crit"
echo "$(KG_TEST_DISK=92 run_health --json 2>/dev/null)" | py 'import sys,json;assert json.load(sys.stdin)["overall"]=="crit"' \
  && ok "磁碟 92% crit" || fail_t "磁碟 92% 未 crit"

section "閾值：容器 unhealthy → crit"
echo "$(KG_TEST_HEALTH=unhealthy run_health --json 2>/dev/null)" | py 'import sys,json;assert json.load(sys.stdin)["overall"]=="crit"' \
  && ok "容器 unhealthy crit" || fail_t "容器 unhealthy 未 crit"

section "閾值：憑證 2 天 → crit"
SOON="$(LC_ALL=C date -u -v+2d '+%b %e %T %Y GMT' 2>/dev/null || LC_ALL=C date -u -d '+2 days' '+%b %e %T %Y GMT')"
echo "$(KG_HEALTH_CERT_ENDDATE="$SOON" run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);c=[m for m in d["metrics"] if m["key"]=="cert_days_left"][0];assert c["status"]=="crit",c' \
  && ok "憑證 2 天 crit" || fail_t "憑證 2 天 未 crit"

section "HTTPS 探針：503 → crit"
echo "$(KG_HEALTH_HTTP_CODE=503 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="http_probe"][0];assert h["status"]=="crit",h;assert d["overall"]=="crit"' \
  && ok "HTTPS 503 crit" || fail_t "HTTPS 503 未 crit"

section "HTTPS 探針：200 → ok + raw=200"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="http_probe"][0];assert h["status"]=="ok" and h["raw"]==200,h' \
  && ok "HTTPS 200 ok + raw=200" || fail_t "HTTPS 200 未 ok"

section "HTTPS 探針：前導零 raw 仍須是合法 JSON"
echo "$(KG_HEALTH_HTTP_CODE=000 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="http_probe"][0];assert h["value"]=="000",h' \
  && ok "HTTP_CODE=000 → JSON 合法且 value=000" || fail_t "HTTP_CODE=000 → JSON 非法或 value 不符"
echo "$(KG_HEALTH_HTTP_CODE=000000 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="http_probe"][0];assert h["value"]=="000000",h' \
  && ok "HTTP_CODE=000000 → JSON 合法且保留 value" || fail_t "HTTP_CODE=000000 → JSON 非法或 value 不符"

section "HTTPS 探針：真 curl 失敗不得雙寫 http code"
# 不經 run_health：它以 ${KG_HEALTH_HTTP_CODE:-200} 注入正控，空值會繞過 curl。
echo "$(env -u KG_HEALTH_HTTP_CODE KG_BASE="$STUB" KG_HEALTH_CERT_ENDDATE="$FUTURE_CERT" KG_HEALTH_PROBE_URL=file:///dev/null/kg-health-probe bash "$SCRIPT" --json 2>/dev/null || true)" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="http_probe"][0];assert len(h["value"])==3,h' \
  && ok "真 curl 失敗 → http_probe.value 長度 3" || fail_t "真 curl 失敗 → http_probe.value 非三位"

section "通用 raw 路徑：前導零 metric 不得破壞 JSON"
echo "$(KG_TEST_DISK=007 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);m=[x for x in d["metrics"] if x["key"]=="disk_pct"][0];assert "007" in m["value"],m' \
  && ok "disk_pct=007 → JSON 合法且 metric 保留" || fail_t "disk_pct=007 → JSON 非法或 metric 消失"

section "Swap：使用 63% → ok（macOS 門檻 warn70/crit90；中度 swap 為常態）"
echo "$(KG_TEST_SWAP_USED=1300 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);s=[m for m in d["metrics"] if m["key"]=="swap_used_pct"][0];assert s["status"]=="ok",s' \
  && ok "swap 63% ok" || fail_t "swap 63% 未 ok"
section "Swap：使用 78% → warn（門檻 warn70/crit90）"
echo "$(KG_TEST_SWAP_USED=1600 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);s=[m for m in d["metrics"] if m["key"]=="swap_used_pct"][0];assert s["status"]=="warn",s' \
  && ok "swap 78% warn" || fail_t "swap 78% 未 warn"
section "Swap：使用 93% → crit"
echo "$(KG_TEST_SWAP_USED=1900 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);s=[m for m in d["metrics"] if m["key"]=="swap_used_pct"][0];assert s["status"]=="crit",s' \
  && ok "swap 93% crit" || fail_t "swap 93% 未 crit"

section "Uptime：93600s → 1d 2h + raw 秒數"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);u=[m for m in d["metrics"] if m["key"]=="container_uptime"][0];assert u["raw"]==93600,u;assert "1d" in u["value"] and "2h" in u["value"],u' \
  && ok "uptime 1d 2h + raw=93600" || fail_t "uptime 格式/raw 不符"

section "Uptime：StartedAt 是 UTC，本機時區不得改變秒數"
# 這幾條斷言碰到的字串**由 ops/infra_health.sh 自己產生**：從 REMOTE_BUNDLE 把那一行原封
# 抽出來 eval（與 acceptance 同一個抽法），不是在測試裡另寫一份等價算式（那只會
# 證明測試自己會算術）。抽錯行的話斷言會被一個不相干的字串滿足，故先立 provenance 守衛。
UPLINE_NO="$(grep -n 'container_uptime_s' "$SCRIPT" | head -1 | cut -d: -f1)"
UPSNIP="$(sed -n "${UPLINE_NO}p" "$SCRIPT")"
# 守衛要求同一行**同時**具備「日期解析」與「印出 uptime key」兩個特徵。只認前者的話，
# 一句同時提到這兩個 token 的註解就能通過守衛（實測過），守衛就只是裝飾——真正擋住誘餌的
# 會變成下游那幾條值斷言，而那不是守衛存在的理由。
# 日期解析認 `date -j -f` 與 `date -u -j -f` 兩種寫法：輸入計畫兩種都認可，只綁
# 其中一種會讓「另一個正確實作」變成一條指著錯誤原因的假紅。
if printf '%s' "$UPSNIP" | grep -qE 'date (-u )?-j -f' \
   && printf '%s' "$UPSNIP" | grep -qF 'printf "container_uptime_s'; then
  ok "抽到的是 uptime 計算行（provenance 守衛，行號 ${UPLINE_NO}）"
else
  fail_t "抽到的不是 uptime 計算行（行號 ${UPLINE_NO}）：$UPSNIP"
fi

# StartedAt 與 NOW 都釘死 → 期望值是常數 90，不隨執行時刻漂移，也不靠「兩邊一致」蒙混
# （兩邊同時錯成 0 也會一致；故三條斷言各自釘絕對值）。
# 用**生產形狀**的字串（docker 的 StartedAt 帶奈秒），否則 `${S%.*}` 的剝除是 no-op、
# 那條路徑從未被行使，而尾隨的 Z 只是靠 BSD date 的「忽略多餘字元」容忍度矇混過去。
STARTED_AT="2026-08-06T03:40:51.123456789Z"   # State.StartedAt 語意為 UTC；epoch 1785987651
FAKE_NOW=1785987741                 # = StartedAt + 90s
eval_upsnip() {  # $1 = TZ
  ( export PATH="$FAKEBIN:$PATH" KG_TEST_FAKE_NOW="$FAKE_NOW" TZ="$1" S="$STARTED_AT"
    eval "$UPSNIP" ) 2>/dev/null | cut -f2
}
UP_UTC="$(eval_upsnip UTC || true)"
UP_TPE="$(eval_upsnip Asia/Taipei || true)"
[[ "$UP_UTC" == "90" ]] && ok "TZ=UTC 下 uptime=90s" \
  || fail_t "TZ=UTC 下 uptime=${UP_UTC:-<空>}，期望 90"
[[ "$UP_TPE" == "90" ]] && ok "TZ=Asia/Taipei 下 uptime 同為 90s（時區不污染）" \
  || fail_t "TZ=Asia/Taipei 下 uptime=${UP_TPE:-<空>}，期望 90（差 28800 = 把 UTC 時戳當本地時間讀）"

section "Uptime：StartedAt 解析失敗 → 不得靜默消失"
# 舊 fallback 代入 NOW → uptime 顯示 0，與「容器剛起來」長得一模一樣：一個解析壞掉被
# 偽裝成一個健康讀數。
#
# **兩端各釘一次，producer 端不可省**：stub 是直接偽造 container_uptime_parse 這個 key
# 的，注入的是失效的**結果**而不是失效本身。只釘消費端的話，把 bundle 那行的
# `|| echo ""` 改回 `|| echo "$NOW"`（＝把整個 bug 放回去）測試照樣全綠——實測過。
# 這正是本檔 TZ 段自己寫下的判準（替身接手＝把待測的失效模式從模型裡刪掉），這裡補上。
UP_BAD="$( ( export PATH="$FAKEBIN:$PATH" KG_TEST_FAKE_NOW="$FAKE_NOW" TZ=UTC S="not-a-timestamp"
             eval "$UPSNIP" ) 2>/dev/null || true )"
[[ "$UP_BAD" == "container_uptime_parse"$'\t'"failed" ]] \
  && ok "producer：StartedAt 真解析不了時，bundle 印出 container_uptime_parse" \
  || fail_t "producer：解析失敗未留痕跡（實得：${UP_BAD:-<空>}）"
# consumer：key 送達後不得被判讀段吞掉
echo "$(KG_TEST_UPTIME_PARSE_FAIL=1 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);u=[m for m in d["metrics"] if m["key"]=="container_uptime"];assert u,"container_uptime metric 整個不見了（靜默降級）";assert u[0]["status"]!="ok",u[0];assert d["overall"]!="ok",d["overall"]' \
  && ok "uptime 解析失敗 → metric 仍在且非 ok" || fail_t "uptime 解析失敗被靜默吞掉"

section "閾值 env 覆寫：磁碟 70% + DISK_WARN=65 → warn"
echo "$(KG_TEST_DISK=70 KG_HEALTH_DISK_WARN=65 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);assert d["overall"]=="warn",d["overall"]' \
  && ok "env 覆寫 DISK_WARN 生效" || fail_t "env 覆寫 DISK_WARN 無效"

section "閾值：容器重啟 3 次 → warn"
echo "$(KG_TEST_RESTARTS=3 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);r=[m for m in d["metrics"] if m["key"]=="container_restarts"][0];assert r["status"]=="warn" and d["overall"]=="warn",r' \
  && ok "重啟 3 次 warn" || fail_t "重啟 3 次 未 warn"

section "降級：SSH 收集失敗（空 RAW）→ host_collect crit + overall crit"
js="$(KG_TEST_EMPTY=1 run_health --json 2>/dev/null || true)"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);h=[m for m in d["metrics"] if m["key"]=="host_collect"][0];assert h["status"]=="crit",h;assert d["overall"]=="crit",d["overall"]' \
  && ok "空 RAW → crit（不假綠）" || fail_t "空 RAW 未判 crit"

section "降級：憑證量不到（openssl 失敗）→ unknown → overall warn"
js="$(KG_HEALTH_CERT_ENDDATE="garbage-not-a-date" run_health --json 2>/dev/null || true)"
echo "$js" | py 'import sys,json;d=json.load(sys.stdin);c=[m for m in d["metrics"] if m["key"]=="cert_days_left"][0];assert c["status"]=="unknown",c;assert d["overall"]=="warn",d["overall"]' \
  && ok "cert 量不到 → unknown→warn" || fail_t "cert 量不到 未 warn"

section "REMOTE_BUNDLE 結構：五個部署漂移 key 真的在遠端 bundle 內"
# 這五個 key 的**產生端**在 REMOTE_BUNDLE 裡，而 stub 完全忽略 bundle、直接偽造 key。
# 少了這條，把 bundle 那五行整個刪掉、只留 stub 的偽造值，下面六段照樣全綠——與 uptime
# 那張票被 review 抓到的存活突變是同一個形狀，故在這裡先堵。
# 掃的是 ops/infra_health.sh，不是測試檔自己，故不會自我滿足。
bundle_src="$(sed -n "/^REMOTE_BUNDLE='/,/^'$/p" "$SCRIPT")"
miss=""
for k in deployed_sha origin_prod_sha reconciler_tick_epoch reconciler_poison_epoch host_now_epoch; do
  printf '%s' "$bundle_src" | grep -qF "$k" || miss="$miss $k"
done
[[ -z "$miss" ]] && ok "REMOTE_BUNDLE 含五個漂移 key" || fail_t "REMOTE_BUNDLE 缺:$miss"

section "REMOTE_BUNDLE 真執行：五個 key 的值端到端到得了 getm"
# **上面那條 grep 不夠,它擋不住它宣稱要擋的東西**（實測兩個突變體都能全綠通過）：
#   ① 五行 producer 全刪、補一句 `# TODO: re-add deployed_sha origin_prod_sha …` 的註解
#   ② 只把某行的 \t 換成空格 —— key 名還在,但消費端 getm 用 -F'\t' 永遠比不中
# 所以這裡改用真執行：KG_BASE 這個 seam 吃的就是 `run "<bundle>"`,換一支真的把 bundle
# 跑起來的 base stub,對 fixture 生產 repo 端到端驗**值**而不是驗字串出現過。
EXECBASE="$(mktemp)"
EXECBIN="$(mktemp -d)"
cat >"$EXECBASE" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
PATH="${KG_EXEC_FAKEBIN}:$PATH" zsh -c "$2"
EOF
chmod +x "$EXECBASE"

# The real remote bundle is intentionally macOS-native.  Its true-execution
# test must still run on the Linux Actions runner, so stub only the host
# primitives that do not exist there; the bundle's own shell, awk, git, path
# handling, allowlist keys, and consumer parsing remain real.
cat >"$EXECBIN/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"hw.memsize"*) printf '17179869184\n' ;;
  *"vm.swapusage"*) printf 'total = 4096.00M  used = 512.00M  free = 3584.00M\n' ;;
  *) exit 1 ;;
esac
EOF
cat >"$EXECBIN/vm_stat" <<'EOF'
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
printf 'Pages free:                             100.\n'
printf 'Pages inactive:                         200.\n'
printf 'Pages speculative:                       50.\n'
EOF
cat >"$EXECBIN/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  inspect)
    template="${3:-}"
    if [[ "$template" == *StartedAt* ]]; then
      printf '2026-08-06T03:40:51.123456789Z\n'
    else
      printf 'container_health\thealthy\ncontainer_status\trunning\ncontainer_restarts\t0\n'
    fi
    ;;
  stats) printf 'cpu_pct\t4.2\nmem_pct\t38.0\n' ;;
  logs) [ -n "${KG_TEST_LOG_FIXTURE:-}" ] && cat "$KG_TEST_LOG_FIXTURE" || : ;;
  *) exit 1 ;;
esac
EOF
cat >"$EXECBIN/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -j && "${2:-}" == -f && "$#" -ge 5 ]]; then
  exec /bin/date -u -d "$4" "$5"
fi
exec /bin/date "$@"
EOF
chmod +x "$EXECBIN/sysctl" "$EXECBIN/vm_stat" "$EXECBIN/docker" "$EXECBIN/date"

FIXPROD="$(mktemp -d)"
mkdir -p "$FIXPROD/backend" "$FIXPROD/backups"
echo "81f564d" > "$FIXPROD/backend/VERSION"     # 刻意與 HEAD 不同 = ff-only 穩態
# tick 取末筆；poison 取**最大** epoch（2000）而非最後一行（1000）——兩條都靠這份 fixture
# 行使，下面的斷言用 2000 vs 1000 的差距把「取錯那個」釘出來。
printf 'poison deadbee 2000\npoison cafe123 1000\ntick 3000\n' > "$FIXPROD/backups/reconciler.state"
( cd "$FIXPROD" && git init -q && git config user.email t@t.test && git config user.name t \
  && echo x > f && git add -A && git commit -qm base \
  && git update-ref refs/remotes/origin/prod HEAD ) >/dev/null 2>&1
FIXSHA="$(git -C "$FIXPROD" rev-parse --short HEAD)"
trap 'rm -f "$STUB" "$EXECBASE"; rm -rf "$FAKEBIN" "$FIXPROD" "$EXECBIN"' EXIT

exec_health() {  # 真跑 bundle（本機探針失敗無妨，漂移組只吃 fixture repo）
  # KG_DATA_DIR / KG_CONTAINER 也要釘：真執行會跑 `du -sm $KG_DATA_DIR` 與
  # `docker logs $KG_CONTAINER`，不釘的話在 **felix 上兩者都是生產**，測試耗時會變成
  # 生產資料量的函數（唯讀，無安全問題，但成本不該綁在生產上）。
  KG_BASE="$EXECBASE" KG_EXEC_FAKEBIN="$EXECBIN" KG_PROD_REPO="$FIXPROD" \
  KG_DATA_DIR="${EXEC_DATA_DIR:-$FIXPROD/backups}" KG_CONTAINER="kg-test-no-such-container" \
  KG_HEALTH_CERT_ENDDATE="$FUTURE_CERT" KG_HEALTH_HTTP_CODE=200 \
    bash "$SCRIPT" --json 2>/dev/null
}
ej="$(exec_health || true)"
echo "$ej" | py "import sys,json;d=json.load(sys.stdin);g=[m for m in d['metrics'] if m['key']=='deploy_drift'][0];assert g['status']=='ok',g;assert '$FIXSHA' in g['value'],g;assert '81f564d' in g['value'],g" \
  && ok "真執行：HEAD==origin/prod 但 VERSION 落後（ff-only 穩態）→ deploy_drift=ok，VERSION 只當資訊欄" \
  || fail_t "真執行：ff-only 穩態未判 ok（用 VERSION 當收斂判準會在此永久 warn）"
echo "$ej" | py 'import sys,json,time;d=json.load(sys.stdin);now=int(time.time());g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"][0];assert g["raw"] is not None,g;assert abs((now-g["raw"])-3000)<300,(g,now)' \
  && ok "真執行：tick epoch 經 bundle→getm 正確到位" || fail_t "真執行：tick 值沒到 getm"
echo "$ej" | py 'import sys,json,time;d=json.load(sys.stdin);now=int(time.time());g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"][0];assert g["raw"] is not None,g;e=now-g["raw"];assert abs(e-2000)<300,("取到的不是最大 epoch",g,e)' \
  && ok "真執行：poison 取最大 epoch（非最後一行）" || fail_t "真執行：poison 取值錯誤"

# 資料目錄守衛（#2921）真執行：bundle 的 find/[ -d ] 產出必須被 getm 讀到（stub 測試行使不到）。
mkdir -p "$FIXPROD/dd/users/a" "$FIXPROD/dd/users/b"
dj="$(EXEC_DATA_DIR="$FIXPROD/dd" exec_health || true)"
echo "$dj" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="users_dir_count"][0];assert g["raw"]==2 and g["status"]=="ok",g' \
  && ok "真執行：users_dir_count 經 bundle 到位（2 個目錄）" || fail_t "真執行：users_dir_count 值沒到 getm"
dj="$(EXEC_DATA_DIR="$FIXPROD/no-such-dd" exec_health || true)"
echo "$dj" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="data_dir_mb"][0];assert g["status"]=="crit",g' \
  && ok "真執行：資料目錄不存在 → data_dir_mb crit" || fail_t "真執行：資料目錄缺失未 crit"

# 漂移：讓 origin/prod 前進一個 commit，HEAD 留在原地
( cd "$FIXPROD" && echo y > f2 && git add -A && git commit -qm next \
  && git update-ref refs/remotes/origin/prod HEAD && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
# 這一段**只**對漂移組的 metric 斷言，不碰 overall：真執行會跑到本機真實的 df / docker /
# pgrep 探針，開發機沒有 docker 與 cloudflared 時 overall 本來就會是 crit——那是環境事實，
# 不是受測邏輯。deploy_drift 永不 crit 的契約由上面 stub 那段釘住（環境無關）。
echo "$(exec_health || true)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="deploy_drift"][0];assert g["status"]=="warn",g' \
  && ok "真執行：HEAD 落後 origin/prod → deploy_drift=warn" || fail_t "真執行：HEAD 落後未判 warn"

# log_errors_1h 只數 ERROR/CRITICAL **等級**記錄（#2317）：舊規則 grep 訊息文字
# （error|exception|traceback|critical），把 WARNING 的 NotFoundError→404、
# QuotaExceededError→429、/error 路徑與多行 traceback 都灌進去，穩態就噴假警報。
# fake docker 的 `logs` 吐 KG_TEST_LOG_FIXTURE 的內容；bundle 與 grep 皆真跑。
log_errs() {  # $1=fixture 檔 → log_errors_1h 的 raw
  KG_TEST_LOG_FIXTURE="$1" exec_health | py 'import sys,json;d=json.load(sys.stdin);print([m for m in d["metrics"] if m["key"]=="log_errors_1h"][0]["raw"])'
}
LOGMIX="$(mktemp)"; LOGWARN="$(mktemp)"; LOGCRIT="$(mktemp)"; LOGBARE="$(mktemp)"
printf '%s\n' \
  '{"ts":1,"level":"WARNING","msg":"NotFoundError [x] GET /api/x -> 404"}' \
  '{"ts":2,"level":"WARNING","msg":"NotFoundError [y] GET /api/x -> 404"}' \
  '{"ts":3,"level":"WARNING","msg":"NotFoundError [z] GET /api/x -> 404"}' \
  '{"level":"WARNING","msg":"QuotaExceededError: daily quota -> 429"}' \
  '{"level":"WARNING","msg":"QuotaExceededError: daily quota -> 429"}' \
  '{"level":"WARNING","msg":"Validation error on body"}' \
  'INFO:     127.0.0.1:1 - "GET /api/error?error=1 HTTP/1.1" 404' \
  '{"ts":9,"level": "ERROR","msg":"unhandled"}' \
  'Traceback (most recent call last):' \
  '  File "app.py", line 1, in handler' \
  'ValueError: boom Exception tail' >"$LOGMIX"
printf '%s\n' \
  '{"level":"WARNING","msg":"error while parsing; exception ignored"}' \
  '{"level":"INFO","msg":"recovered from Error, no traceback"}' >"$LOGWARN"
printf '%s\n' '{"level":"CRITICAL","msg":"db down"}' >"$LOGCRIT"
printf '%s\n' 'ERROR: bare line' 'CRITICAL bare line' 'WARNING: error word only' >"$LOGBARE"
trap 'rm -f "$STUB" "$EXECBASE" "$LOGMIX" "$LOGWARN" "$LOGCRIT" "$LOGBARE"; rm -rf "$FAKEBIN" "$FIXPROD" "$EXECBIN"' EXIT
[ "$(log_errs "$LOGMIX")" = 1 ] && ok "log_errors_1h：WARNING 404/429/Validation/路徑/traceback 不計，單一 ERROR 記錄=1" \
  || fail_t "log_errors_1h 混合 log 不等於 1（仍在 grep 訊息文字？）"
[ "$(log_errs "$LOGWARN")" = 0 ] && ok "log_errors_1h：僅 WARNING/INFO（訊息含 error/exception 字樣）=0" \
  || fail_t "log_errors_1h WARNING/INFO-only 不為 0"
[ "$(log_errs "$LOGCRIT")" = 1 ] && ok "log_errors_1h：CRITICAL 記錄=1" || fail_t "log_errors_1h CRITICAL 未計"
[ "$(log_errs "$LOGBARE")" = 2 ] && ok "log_errors_1h：bare 格式 'ERROR:' / 'CRITICAL ' 開頭各計 1" \
  || fail_t "log_errors_1h bare 格式計數錯誤"

NOWE="$(date +%s)"

section "deploy_drift：兩 sha 不同 → warn 且 overall 不得 crit"
# **永不 crit** 是契約不是巧合：release 推進 origin/prod 到 reconciler 收斂完成之間，
# drift 是設計上的正常瞬態。判 crit 會讓 reconciler 的自我健康 gate 把一次剛部署成功
# 的健康版本回滾掉（自噬迴圈）。
echo "$(KG_TEST_ORIGIN_SHA=deadbee run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="deploy_drift"][0];assert g["status"]=="warn",g;assert d["overall"]!="crit",d["overall"]' \
  && ok "deploy_drift 兩 sha 不同 → warn 且 overall 非 crit" || fail_t "deploy_drift 未 warn 或誤判 crit"

section "deploy_drift：origin/prod 未 seed（unknown）→ warn"
# felix 首次切換、或 fetch 失敗時**必然**走到的第三個分支，原本零覆蓋。
echo "$(KG_TEST_ORIGIN_SHA=unknown run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="deploy_drift"][0];assert g["status"]=="warn",g;assert d["overall"]!="crit",d["overall"]' \
  && ok "deploy_drift origin unknown → warn" || fail_t "deploy_drift unknown 分支未 warn"

section "reconciler_poison_active：有紀錄但算不出年齡 → 不得回報「無」"
# 「量不到」絕不等於「沒有 poison」——與本檔 host_collect / cert 兩處同一原則。
echo "$(KG_TEST_POISON_EPOCH=not-a-number run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"][0];assert g["status"]!="ok",g;assert g["value"]!="無",g' \
  && ok "poison 值非數值 → 非 ok 且不宣稱「無」" || fail_t "poison 非數值時 fail-open"

section "reconciler_tick_age_s：非數值 tick 不得讓整支腳本猝死"
# state 檔是磁碟上的檔（可能被截斷/手改/殘留舊格式）。非數字 token 進 $(( )) 會被當變數名，
# set -u 下整支腳本當場死掉、stdout 一個字都沒有卻回 rc=1——而 rc=1 會被 reconciler 讀成
# 「WARN 仍 pass」，一支死掉的工具被當成通過的工具。
tick_junk="$(KG_TEST_TICK_EPOCH=not-a-number run_health --json 2>/dev/null || true)"
printf '%s' "$tick_junk" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"][0];assert g["status"]!="ok",g' \
  && ok "tick 非數值 → JSON 仍完整且該格非 ok" || fail_t "tick 非數值：JSON 壞掉或假綠（實得 ${#tick_junk} bytes）"

section "前導零：通過 ^[0-9]+$ 卻過不了 bash 算術的值，不得讓 metric 靜靜消失"
# `09` 通過正則但 bash 當它是八進位 → `value too great for base` 中止整個 if 複合命令，
# 三個 metric 從 metrics[] 消失，而 overall / exit code 完全乾淨。消費端找不到 key，
# 得到的結論是「健康」。這比「腳本猝死」更難發現，故各自釘一條。
echo "$(KG_TEST_TICK_EPOCH=09 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"];assert g,"reconciler_tick_age_s 從 metrics[] 消失了（八進位中止 if 複合命令）";assert g[0]["status"]!="ok",g[0]' \
  && ok "tick=09 → metric 仍在且非 ok（十進位強制生效）" || fail_t "tick=09 讓 metric 消失或假綠"

section "前導零：POISON_COOLDOWN=0900 不得把冷卻中的 poison 判成 ok"
# 這個旋鈕正是本批文檔剛對 operator 宣傳的那個；比較失敗會落進 else＝健康那一支。
echo "$(KG_TEST_NOW_EPOCH=$(date +%s) KG_TEST_POISON_EPOCH=$(( $(date +%s) - 100 )) KG_RECON_POISON_COOLDOWN=0900 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"][0];assert g["status"]=="warn",g' \
  && ok "COOLDOWN=0900 + 100s 前 poison → 仍判 warn" || fail_t "前導零冷卻窗 fail-open 成 ok"

section "前導零：poison epoch 與閾值 env 也不得 fail-open"
echo "$(KG_TEST_POISON_EPOCH=09 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"];assert g,"reconciler_poison_active 從 metrics[] 消失了"' \
  && ok "poison epoch=09 → metric 仍在" || fail_t "poison epoch=09 讓 metric 消失"
# 閾值 env 的前導零最陰險：比較式是 && 左側，錯誤只回 false → warn/crit 永久不可達，
# 指標永遠綠、rc 永遠 0。本 commit 新增的 KG_HEALTH_TICK_WARN/CRIT 正是新的消費者。
echo "$(KG_TEST_NOW_EPOCH=$(date +%s) KG_TEST_TICK_EPOCH=$(( $(date +%s) - 1000 )) KG_HEALTH_TICK_WARN=0900 KG_HEALTH_TICK_CRIT=01800 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"][0];assert g["status"]!="ok",g' \
  && ok "TICK_WARN=0900 + 心跳 1000s → 不得判 ok" || fail_t "閾值 env 前導零 → warn/crit 分支不可達"

section "deploy_drift：兩 sha 相同 → ok"
echo "$(run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="deploy_drift"][0];assert g["status"]=="ok",g' \
  && ok "deploy_drift 已收斂 → ok" || fail_t "deploy_drift 收斂時未 ok"

section "reconciler_tick_age_s：2000s → crit"
echo "$(KG_TEST_NOW_EPOCH=$NOWE KG_TEST_TICK_EPOCH=$(( NOWE - 2000 )) run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"][0];assert g["status"]=="crit",g' \
  && ok "reconciler_tick_age_s 2000s → crit" || fail_t "tick 2000s 未 crit"

section "reconciler_tick_age_s：缺值 → 不得假綠"
# 年齡一律用**遠端**時鐘（host_now_epoch）相減，免本機時鐘偏移污染；量不到時 th_high
# 回 unknown → bump 升成 warn，不會靜默變綠。
echo "$(KG_TEST_TICK_EPOCH= run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_tick_age_s"][0];assert g["status"]!="ok",g' \
  && ok "reconciler_tick_age_s 缺值 → 非 ok" || fail_t "tick 缺值 假綠"

section "reconciler_poison_active：距今 100s → warn；99999s → ok"
echo "$(KG_TEST_NOW_EPOCH=$NOWE KG_TEST_POISON_EPOCH=$(( NOWE - 100 )) run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"][0];assert g["status"]=="warn",g' \
  && ok "reconciler_poison_active 100s → warn" || fail_t "poison 100s 未 warn"
echo "$(KG_TEST_NOW_EPOCH=$NOWE KG_TEST_POISON_EPOCH=$(( NOWE - 99999 )) run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);g=[m for m in d["metrics"] if m["key"]=="reconciler_poison_active"][0];assert g["status"]=="ok",g' \
  && ok "poison 冷卻已過 → ok" || fail_t "poison 冷卻已過 未 ok"

section "開關：預設三個 metric 都在；KG_HEALTH_DEPLOY_DRIFT=0 → 完全不出現"
# **正控不可省**：只斷言「=0 時不出現」的話，這條在三個 metric 根本還沒實作時就會通過
# （空集合與空集合的交集是空的）——一條在實作前後都綠的斷言，對開關零保護。故先釘住
# 「預設時三個都在」，再釘「關掉後都不在」，兩個方向合起來才等於「開關真的在控制它們」。
echo "$(run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);ks={m["key"] for m in d["metrics"]};want={"deploy_drift","reconciler_tick_age_s","reconciler_poison_active"};assert want <= ks, "預設缺少: %s" % (want - ks)' \
  && ok "預設（開關未設）三個 metric 都在（正控）" || fail_t "預設三個 metric 未全部出現"
echo "$(KG_HEALTH_DEPLOY_DRIFT=0 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);ks={m["key"] for m in d["metrics"]};assert not (ks & {"deploy_drift","reconciler_tick_age_s","reconciler_poison_active"}),ks' \
  && ok "KG_HEALTH_DEPLOY_DRIFT=0 → 三個 metric 不出現" || fail_t "開關無效"

section "資料目錄守衛（#2921）：缺失／無用戶／驟降 → crit，可關閉"
dm() { py 'import sys,json;d=json.load(sys.stdin);k=sys.argv[1];g=[m for m in d["metrics"] if m["key"]==k];assert g,("missing",k);assert g[0]["status"]==sys.argv[2],g' "$1" "$2"; }
echo "$(run_health --json 2>/dev/null)" | dm users_dir_count ok && ok "正控：5 個用戶目錄 → users_dir_count ok" || fail_t "正控 users_dir_count 非 ok"
echo "$(run_health --json 2>/dev/null)" | dm data_dir_mb ok && ok "正控：data_dir_mb ok" || fail_t "正控 data_dir_mb 非 ok"
echo "$(KG_TEST_USERS=0 run_health --json 2>/dev/null)" | dm users_dir_count crit && ok "users=0 → crit" || fail_t "users=0 未 crit"
echo "$(KG_TEST_DATA_EXISTS=no KG_TEST_DATA_MB= KG_TEST_USERS= run_health --json 2>/dev/null)" | dm data_dir_mb crit && ok "資料目錄不存在 → data_dir_mb crit" || fail_t "資料目錄缺失 data_dir_mb 未 crit"
echo "$(KG_TEST_DATA_EXISTS=no KG_TEST_DATA_MB= KG_TEST_USERS= run_health --json 2>/dev/null)" | dm users_dir_count crit && ok "資料目錄不存在 → users_dir_count crit" || fail_t "資料目錄缺失 users_dir_count 未 crit"
set +e; KG_TEST_USERS=0 run_health --json >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 2 ]] && ok "users=0 → exit 2（cron alert 路徑）" || fail_t "users=0 exit=${rc}（預期 2）"
echo "$(KG_HEALTH_DATA_MB_BASELINE=1000 KG_TEST_DATA_MB=100 run_health --json 2>/dev/null)" | dm data_dir_mb crit && ok "容量跌破基線 50% → crit" || fail_t "容量驟降未 crit"
echo "$(KG_HEALTH_DATA_MB_BASELINE=1000 KG_TEST_DATA_MB=600 run_health --json 2>/dev/null)" | dm data_dir_mb ok && ok "容量僅降 40% → ok" || fail_t "容量小降誤報"
echo "$(KG_HEALTH_USERS_BASELINE=100 KG_TEST_USERS=10 run_health --json 2>/dev/null)" | dm users_dir_count crit && ok "用戶數跌破基線 50% → crit" || fail_t "用戶數驟降未 crit"
echo "$(KG_HEALTH_DATA_GUARD=0 KG_TEST_USERS=0 run_health --json 2>/dev/null)" | py 'import sys,json;d=json.load(sys.stdin);ks={m["key"] for m in d["metrics"]};assert "users_dir_count" not in ks,ks;g=[m for m in d["metrics"] if m["key"]=="data_dir_mb"][0];assert g["status"]=="ok",g' \
  && ok "KG_HEALTH_DATA_GUARD=0 → 無 users_dir_count、data_dir_mb 回到資訊性" || fail_t "守衛開關無效"

echo ""
echo "═══ infra_health v2: $pass passed, $fail failed ═══"
[[ $fail -eq 0 ]]
