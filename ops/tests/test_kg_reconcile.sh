#!/usr/bin/env bash
# test_kg_reconcile.sh — offline TDD tests for ops/kg_reconcile.sh
#
# 覆蓋（對齊 ops/tests/ 既有 bash 測試風格）：
#   - paths_need_deploy 觸發正則（backend/src、pyproject、uv.lock、Dockerfile、static、
#     index.html → need；ios、docs、.env、data/ → NOT need）
#   - lock-only 依賴更新（backend/uv.lock）→ 走 build 路徑並 deployed（#2088）
#   - no-change → noop（git 不 pull、compose 不 build）
#   - non-backend change（docs）→ ff-only（compose 不 build、repo ff 到新 sha）
#   - backend change + smoke 全綠 → deployed（compose up、deploy.log 有新行、VERSION 更新）
#   - backend change + smoke 失敗 → rolled-back（git reset --hard ROLLBACK_SHA、
#     compose 第二次 up、poison 寫入、exit 非 0）
#   - smoke unreachable 但 infra 拿到 HTTP status → rolled-back（服務鏈證據優先）
#   - poison 命中同 sha → poisoned-skip（compose 不 build）
#   - --dry-run + backend change → dry-run（compose/pull 完全不呼叫、VERSION/state/log 未變）
#   - lock 已被別人持有 → locked（exit 0、不 build）
#   - --help → exit 0 且含用法
#
# 策略：git 用「記錄呼叫 + 委派真 git」的 wrapper mock（同時拿到呼叫可見性與真實
# 狀態保真度）；compose/curl/infra_health 用 stub。每個 flow 跑在臨時 scratch repo
# （git init + 假 commit + 假 backend/VERSION），測完清乾淨。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RECON="$ROOT/ops/kg_reconcile.sh"
REALGIT="$(command -v git)"

pass=0; fail=0
ok()      { echo "  ✓ $*"; pass=$((pass+1)); }
bad()     { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

SCRATCHES=()
cleanup() { [[ ${#SCRATCHES[@]} -gt 0 ]] && rm -rf "${SCRATCHES[@]}"; }
trap cleanup EXIT

get_verdict() { printf '%s' "$1" | sed -n 's/.*"verdict":"\([^"]*\)".*/\1/p' | head -1; }

# ── mock curl（fixture 驅動；沿用 test_deploy_smoke.sh 的解析法）─────────────
# fixture 每行：URL_SUBSTRING|HTTP_CODE|BODY_LITERAL
make_mock_curl() {
  local fixture_content="$1"
  local dir="$2"
  local served="${3:-}"          # 選填：容器「實際 serving」版本檔；localhost 動態回此值
  local fixture="$dir/curl_fixture_$RANDOM.txt"
  local script="$dir/mock_curl_$RANDOM.sh"
  printf '%s\n' "$fixture_content" > "$fixture"
  cat >"$script" <<MOCK
#!/usr/bin/env bash
SERVED="$served"
url=""
want_body_plus_http=0
want_http_only=0
next=""
for a in "\$@"; do
  if [[ "\$next" == "w" ]]; then
    if [[ "\$a" == *"%{http_code}" && "\$a" == *\$'\n'* ]]; then
      want_body_plus_http=1
    elif [[ "\$a" == "%{http_code}" ]]; then
      want_http_only=1
    fi
    next=""
  elif [[ "\$a" == "-w" ]]; then
    next="w"
  elif [[ "\$a" == http*://* ]]; then
    url="\$a"
  fi
done
# readiness 探針（/api/system/info/ready）：必須先於 SERVED / system/info 分支攔截，
# 否則 localhost 的 SERVED 分支會對它回一個帶 version 的 200，等於替身比真實依賴仁慈。
# MOCK_READY_LOCAL / MOCK_READY_EXTERNAL = 該端點回的 HTTP code（預設 200；000 = 連不出去）。
if [[ "\$url" == */api/system/info/ready ]]; then
  if [[ "\$url" == *localhost* ]]; then
    rc_="\${MOCK_READY_LOCAL:-200}"
    # MOCK_READY_LOCAL_SEQ="200 503 503 200"：依序消耗，用完重複最後一個（模擬部署前綠、部署後壞、回滾後好/壞）。
    if [[ -n "\${MOCK_READY_LOCAL_SEQ:-}" ]]; then
      read -r -a seq_ <<<"\$MOCK_READY_LOCAL_SEQ"
      n_=\$(cat "$dir/ready_seq_n" 2>/dev/null || echo 0)
      idx_=\$n_; (( idx_ >= \${#seq_[@]} )) && idx_=\$(( \${#seq_[@]} - 1 ))
      rc_="\${seq_[\$idx_]}"; echo \$((n_+1)) > "$dir/ready_seq_n"
    fi
  else rc_="\${MOCK_READY_EXTERNAL:-200}"; fi
  echo "\$url \$rc_" >> "$dir/ready_calls"
  if [[ "\$rc_" == "000" ]]; then
    if [[ "\$want_body_plus_http" == "1" ]]; then printf '\\n000'
    elif [[ "\$want_http_only" == "1" ]]; then printf '000'; fi
    exit 6
  fi
  if [[ "\$want_body_plus_http" == "1" ]]; then printf '{}\\n%s' "\$rc_";
  elif [[ "\$want_http_only" == "1" ]]; then printf '%s' "\$rc_"; fi
  exit 0
fi
# 動態 localhost：容器 serving 版本 = SERVED 檔內容（模擬 rebuild 後版本改變）。
# SERVED 空 → 該檔缺 → 容器視為 down（000/exit 6）。僅套用於 localhost；外部 URL 走 fixture。
if [[ -n "\$SERVED" && "\$url" == *localhost* ]]; then
  if [[ -s "\$SERVED" ]]; then
    sv="\$(head -1 "\$SERVED" | tr -d '[:space:]')"
    code=200; body="{\"version\":\"\$sv\"}"
    if [[ "\$want_body_plus_http" == "1" ]]; then printf '%s\n%s' "\$body" "\$code";
    elif [[ "\$want_http_only" == "1" ]]; then printf '%s' "\$code";
    else printf '%s' "\$body"; fi
    exit 0
  else
    exit 6
  fi
fi
# 外部：MOCK_EXTERNAL_FAIL_FIRST=<n> 讓前 n 次外部 /api/system/info 直接失敗。
# 模擬的是**主機端對外連通性中斷**（2026-08-04 事故是 felix DNS 掛掉，同一秒 docker
# build 也在 auth.docker.io 上吐 no-such-host），不是 tunnel 重連——後者會回帶
# HTTP status 的 CF 錯誤頁，而事故拿到的是 exit 6 / HTTP=000（連回應都沒有）。
# 注意：本段在 **unquoted heredoc** 內，反引號會在寫檔當下被當成命令替換執行。
# 引用含反引號的日誌時一律改寫成純文字——這個坑今天已經咬過兩次（EXCLUDED_GROUPS
# 那次直接讓整支腳本 rc=141 一個字都沒印）。
# 已知**未**建模：時間。這裡計次不計時，且 harness 把 DELAY 釘成 0，所以綠燈只證明
# 「重試了 N 次」，不證明「等得夠久」——而後者才是這條修法真正想買的東西。
# 只挑外部主機名。用 *system/info* 比對的話 localhost 探針（KG_LOCAL_HEALTH_URL 也是
# .../api/system/info）會一起被擋掉並混進計數；現在沒炸只是因為上面 SERVED 分支先 exit。
if [[ -n "\${MOCK_EXTERNAL_FAIL_FIRST:-}" && "\$url" == *wordnexus.lol* && "\$url" == *system/info* ]]; then
  n=\$(cat "$dir/external_calls" 2>/dev/null || echo 0)
  n=\$((n+1)); echo "\$n" > "$dir/external_calls"
  if (( n <= MOCK_EXTERNAL_FAIL_FIRST )); then
    # MOCK_EXTERNAL_FAIL_SHAPE 控制**失敗長什麼樣**，預設 code000 = 忠實模擬真 curl。
    # 實測（2026-08-06，無法解析的主機名）：
    #   curl -sS -o - -w \$'\\n%{http_code}' → stdout=[\\n000]、exit 6
    # 也就是說連不出去時 curl **有印東西**，呼叫端拿到的 code 是字串 "000" 而不是空字串。
    # 舊版這裡靜默 exit 6 → 呼叫端拿到 ""，於是「只檢查空字串」的實作會在測試裡全綠、
    # 在生產照樣誤判。shape=silent 保留舊形狀，專門用來釘住分類器不得只認其中一種。
    if [[ "\${MOCK_EXTERNAL_FAIL_SHAPE:-code000}" != "silent" ]]; then
      if [[ "\$want_body_plus_http" == "1" ]]; then printf '\\n000'
      elif [[ "\$want_http_only" == "1" ]]; then printf '000'; fi
    fi
    exit 6
  fi
fi
match_line=""
while IFS= read -r line; do
  [[ -z "\$line" || "\$line" == \#* ]] && continue
  sub="\${line%%|*}"
  if [[ "\$url" == *"\$sub"* ]]; then match_line="\$line"; break; fi
done < "$fixture"
if [[ -z "\$match_line" ]]; then
  echo "mock_curl: no fixture match for url=\$url" >&2
  exit 7
fi
rest="\${match_line#*|}"
code="\${rest%%|*}"
body="\${rest#*|}"
if [[ "\$code" == "000" ]]; then
  # 同上：fixture 寫 000 代表「連不出去」，真 curl 會先把 000 印出來才以 6 退出。
  if [[ "\$want_body_plus_http" == "1" ]]; then printf '\\n000'
  elif [[ "\$want_http_only" == "1" ]]; then printf '000'; fi
  exit 6
fi
if [[ "\$want_body_plus_http" == "1" ]]; then
  printf '%s\n%s' "\$body" "\$code"
elif [[ "\$want_http_only" == "1" ]]; then
  printf '%s' "\$code"
else
  printf '%s' "\$body"
fi
exit 0
MOCK
  chmod +x "$script"
  echo "$script"
}

# ── scratch repo + mocks ────────────────────────────────────────────────────
# kind ∈ backend | docs | none
new_scratch() {
  local kind="$1"
  SC="$(mktemp -d)"; SCRATCHES+=("$SC")
  ORIGIN="$SC/origin.git"; REPO="$SC/repo"; BIN="$SC/bin"
  GITLOG="$SC/git.log"; COMPOSELOG="$SC/compose.log"
  STATE="$SC/backups/reconciler.state"; DEPLOYLOG="$SC/backups/deploy.log"
  VERSIONFILE="$REPO/backend/VERSION"
  SERVEDFILE="$SC/served.txt"     # 容器「實際 serving」版本（compose recreate 時更新為 VERSION 內容）
  IMAGECHANGED="$SC/image_changed"  # 存在 = 這次改動真的動到 image / 解析後 compose config
  RECREATELOG="$SC/recreate.log"    # 每次真的 recreate 記一行（與「版本變了」分開觀測）
  CONTAINER_DEAD="$SC/container_dead"  # 存在 = recreate 後容器起不來（用來測雙壞告警）
  INFRALOG="$SC/infra.log"          # infra_health 替身每次被呼叫記一行（含它自己探到的 code）
  SENTRYLOG="$SC/sentry.log"        # Sentry release 替身（KG_SENTRY_RELEASE）每次被呼叫記一行 argv
  LOCK="$SC/deploy.lock"
  mkdir -p "$BIN" "$SC/backups"

  "$REALGIT" init -q --bare "$ORIGIN"
  "$REALGIT" init -q "$REPO"
  "$REALGIT" -C "$REPO" config user.email t@t.test
  "$REALGIT" -C "$REPO" config user.name t
  mkdir -p "$REPO/backend/src" "$REPO/docs" "$REPO/ios"
  printf 'backend/VERSION\nbackups/\n' > "$REPO/.gitignore"
  echo "print(1)" > "$REPO/backend/src/app.py"
  # 命中 BACKEND_TRIGGER_RE 但**不進 image** 的檔案，用來造出 backend-noimage 情境
  printf 'services:\n  api:\n    build: .\n' > "$REPO/backend/docker-compose.yml"
  # backend/uv.lock：image 依它安裝（#2088），backend-locked 情境只改這個檔
  printf 'version = 1\n' > "$REPO/backend/uv.lock"
  echo "root" > "$REPO/README.md"
  "$REALGIT" -C "$REPO" add -A
  "$REALGIT" -C "$REPO" commit -qm base
  "$REALGIT" -C "$REPO" branch -M main
  "$REALGIT" -C "$REPO" remote add origin "$ORIGIN"
  "$REALGIT" -C "$REPO" push -qu origin main 2>/dev/null
  SHA_OLD="$("$REALGIT" -C "$REPO" rev-parse --short HEAD)"
  # seed origin/prod = origin/main and check out prod — REPO mimics ~/kg-prod, the
  # dedicated production clone the reconciler tracks (origin/prod, NOT origin/main).
  "$REALGIT" -C "$REPO" branch prod
  "$REALGIT" -C "$REPO" push -qu origin prod 2>/dev/null
  "$REALGIT" -C "$REPO" checkout -q prod

  if [[ "$kind" != "none" ]]; then
    case "$kind" in
      backend) echo "print(2)" >> "$REPO/backend/src/app.py"; : > "$IMAGECHANGED" ;;
      # lock-only 依賴更新（#2088）：Dockerfile 依 uv.lock 安裝，所以這會改 image
      backend-lockonly) printf '[[package]]\nname = "x"\nversion = "2"\n' >> "$REPO/backend/uv.lock"; : > "$IMAGECHANGED" ;;
      # 命中 trigger、但改的是不進 image 的檔案的註解：`docker compose config --hash`
      # 不變、Dockerfile 沒有 COPY 到它 → image digest 不變 → compose 不 recreate。
      # 這是 IMP-0056 實際踩到的形狀，**刻意不設 IMAGECHANGED**。
      backend-noimage) printf '# a comment; nothing here enters the image\n' >> "$REPO/backend/docker-compose.yml" ;;
      docs)    echo "doc" >> "$REPO/docs/x.md" ;;
    esac
    "$REALGIT" -C "$REPO" add -A
    "$REALGIT" -C "$REPO" commit -qm change
    # the change lands on origin/prod (the release-plane ref); reconciler converges to it
    "$REALGIT" -C "$REPO" push -q origin prod 2>/dev/null
    # SHA_NEW is the **full** sha: deploy writes `git rev-parse HEAD` to VERSION so the
    # Sentry release kg-backend@<VERSION> is unambiguous (#2078). SHA_OLD above stays
    # short on purpose — it is the legacy cursor every pre-#2078 deploy left on felix,
    # so each flow also proves the short→full transition converges.
    SHA_NEW="$("$REALGIT" -C "$REPO" rev-parse HEAD)"
    "$REALGIT" -C "$REPO" reset --hard -q "$SHA_OLD"
  else
    SHA_NEW="$SHA_OLD"
  fi
  echo "$SHA_OLD" > "$VERSIONFILE"
  echo "$SHA_OLD" > "$SERVEDFILE"   # 容器起始 serving 舊版（與 VERSION 一致）

  # git wrapper mock: 記錄呼叫 + 委派真 git
  cat >"$BIN/git_mock.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GITLOG"
exec "$REALGIT" "\$@"
EOF
  # compose stub: 記錄呼叫 + 依 **docker 真正的 recreate 語意** 決定容器要不要換版。
  #
  # 舊版無條件 `cp VERSION served`，也就是模型裡的 compose **永遠**會 recreate。那比
  # docker 聽話：`up -d --build` 只在 image digest 或**解析後**的 compose config hash
  # 變了才 recreate，`--force-recreate` 才是無條件。於是「compose 沒 recreate」這條
  # 路徑在測試裡根本不存在，而它正是 IMP-0056 的整個故事：健康 gate 比對容器自報版本
  # 與新 sha，沒 recreate 就永遠不相等 → 假失敗 → 回滾 + poison + 每小時重來。
  # 測試替身比真實依賴聽話，等於把待測的失效模式從世界上刪掉。
  #
  # recreate 另外記一個計數檔，不要只靠「served 版本變了」推斷：**一次不改變版本的
  # recreate 在後者眼裡完全隱形**，而停機成本正好落在那種 recreate 上（build 失敗後的
  # 回滾就是）。把「該不該重啟」與「重啟後是哪一版」拆成兩個可分別斷言的事實。
  # MOCK_COMPOSE_FAIL_NTH=<n> 讓第 n 次呼叫回非零，用來覆蓋 build 失敗分支。
  cat >"$BIN/compose_mock.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$COMPOSELOG"
calls=\$(( \$(wc -l < "$COMPOSELOG") ))
if [[ -n "\${MOCK_COMPOSE_FAIL_NTH:-}" && "\$calls" == "\$MOCK_COMPOSE_FAIL_NTH" ]]; then
  echo "compose: build failed (injected)" >&2
  exit 1
fi
if [[ "\$*" == *--force-recreate* || -f "$IMAGECHANGED" ]]; then
  echo x >> "$RECREATELOG"
  if [[ -f "$CONTAINER_DEAD" ]]; then
    : > "$SERVEDFILE"        # 容器重建後起不來 → 什麼版本都沒 serving
  else
    cp "$VERSIONFILE" "$SERVEDFILE" 2>/dev/null || true
  fi
fi
exit 0
EOF
  # infra_health stub：**忠實度是承重的，不是裝飾**。
  #
  # 舊版只有一行 `exit "${MOCK_INFRA_EXIT:-0}"`，於是「同一場斷網會讓這一關也 crit」
  # 這件事在測試世界裡根本不存在——而真的 ops/infra_health.sh 會用**同一個外部 URL**
  # 再打一次（:40 PROBE_URL 預設 = 公開網域/api/system/info）、非 200 一律 crit（:186）、
  # crit → exit 2（:227）。結果是外部 smoke 這一關放行了 unreachable，下一關照樣把主機端
  # 斷網翻譯成 reason=infra + 回滾 + poison。替身比真實依賴仁慈 = 把待測的失效模式從模型
  # 裡刪掉，這正是 IMP-0056 記過一次、IMP-0061 review D1 又抓到一次的同一課題。
  #
  # 所以這裡照真的做：真的去打那個 URL（走同一支 mock curl）、真的照 200 判 ok/crit、
  # 真的吐同形 JSON（key/label/value/raw/status + overall），exit 0/1/2 同語意。
  # 旋鈕只保留兩個，且都對應真實世界存在的形狀：
  #   MOCK_INFRA_EXTRA_CRIT=<container|ingress>  http_probe **以外**的真 crit（機器真的壞了）
  #   MOCK_INFRA_MALFORMED=1                     crit 但 stdout 不是 JSON（版本不合／被換掉）
  # 呼叫紀錄寫 $INFRALOG，讓「這一關真的跑了、真的 crit 了」可以被正控斷言，而不是靠推測。
  cat >"$BIN/infra_mock.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
json=0; [[ "\${1:-}" == "--json" ]] && json=1
probe_url="\${KG_HEALTH_PROBE_URL:-\${KG_PUBLIC_URL:-https://wordnexus.lol}/api/system/info}"
pinned=no; [[ -n "\${KG_HEALTH_PROBE_URL:-}" ]] && pinned=yes
code="\$("\${CURL_BIN:-curl}" -sS -o /dev/null -w '%{http_code}' --max-time 10 "\$probe_url" 2>/dev/null || true)"
[[ -n "\$code" ]] || code="000"
hst=crit; [[ "\$code" == "200" ]] && hst=ok
extra="\${MOCK_INFRA_EXTRA_CRIT:-}"
overall=ok
[[ "\$hst" == "crit" ]] && overall=crit
[[ -n "\$extra" ]] && overall=crit
printf 'call probe_url=%s pinned=%s http_code=%s http_probe=%s extra_crit=%s overall=%s deploy_drift=%s\n' \\
  "\$probe_url" "\$pinned" "\$code" "\$hst" "\${extra:-none}" "\$overall" \\
  "\${KG_HEALTH_DEPLOY_DRIFT:-unset}" >> "$INFRALOG"
st_of() { if [[ "\$extra" == "\$1" ]]; then printf crit; else printf ok; fi; }
if (( json == 1 )); then
  if [[ "\${MOCK_INFRA_MALFORMED:-0}" == "1" ]]; then
    printf 'infra_health: not json at all\n'
  else
    printf '{"overall":"%s","domain":"test","metrics":[' "\$overall"
    printf '{"key":"host_collect","label":"Host","value":"ok","raw":null,"status":"ok"}'
    printf ',{"key":"container","label":"Container","value":"running","raw":null,"status":"%s"}' "\$(st_of container)"
    printf ',{"key":"ingress","label":"Tunnel","value":"active","raw":null,"status":"%s"}' "\$(st_of ingress)"
    printf ',{"key":"http_probe","label":"HTTPS","value":"%s","raw":%s,"status":"%s"}' "\$code" "\$code" "\$hst"
    printf ']}\n'
  fi
fi
case "\$overall" in ok) exit 0;; warn) exit 1;; crit) exit 2;; esac
EOF
  # Sentry release recorder 替身：記 argv，並**故意往 stdout 吐垃圾**——reconciler 的
  # stdout 只准有那一行 JSON verdict，recorder 的任何輸出都必須被導去 stderr。
  # MOCK_SENTRY_MODE=fail|hang 覆蓋「Sentry 掛了／卡住也不得影響部署」。
  cat >"$BIN/sentry_mock.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SENTRYLOG"
echo "sentry-mock noise on stdout"
case "\${MOCK_SENTRY_MODE:-ok}" in
  fail) exit 1 ;;
  hang) sleep 30 ;;
esac
exit 0
EOF
  chmod +x "$BIN/git_mock.sh" "$BIN/compose_mock.sh" "$BIN/infra_mock.sh" "$BIN/sentry_mock.sh"
}

run_recon() {
  (
    export KG_RECON_REPO="$REPO"
    export KG_GIT="$BIN/git_mock.sh"
    export KG_COMPOSE="$BIN/compose_mock.sh"
    export CURL_BIN="$MOCK_CURL"
    export KG_INFRA_HEALTH="$BIN/infra_mock.sh"
    export KG_STATE_FILE="$STATE"
    export KG_DEPLOY_LOG="$DEPLOYLOG"
    export KG_PUBLIC_URL="https://wordnexus.lol"
    export KG_LOCAL_HEALTH_URL="http://localhost:8000/api/system/info"
    export KG_LOCK_DIR="$LOCK"
    export KG_GH_TOKEN_ENV="$SC/no-such-token.env"
    # 資料目錄守衛（#2921）：永遠指向 scratch 內的 stub，絕不碰真實 ~/kg-data。
    # 預設 stub 有 1 個用戶；案例用 KG_DATA_DIR_OVERRIDE 改指向缺失／空目錄。
    [[ -d "$SC/kg-data/users/u1" ]] || mkdir -p "$SC/kg-data/users/u1"
    export KG_DATA_DIR="${KG_DATA_DIR_OVERRIDE:-$SC/kg-data}"
    export KG_DATA_BASELINE_FILE="$SC/backups/data_dir.baseline"
    export KG_RECON_HEALTH_DELAY=0
    export KG_RECON_HEALTH_ATTEMPTS=2
    # 預設指向 scratch repo 裡不存在的 helper（= 生產 clone 尚未帶到 helper 的情形）；
    # 要觀測 recorder 的 flow 自己覆寫成 $BIN/sentry_mock.sh。
    export KG_SENTRY_RELEASE="${KG_SENTRY_RELEASE_OVERRIDE:-$REPO/ops/sentry_release.sh}"
    "$RECON" "$@"
  )
}

# ── paths_need_deploy 純函式 ────────────────────────────────────────────────
pnd_rc() { ( source "$RECON" >/dev/null 2>&1; set +e; printf '%s\n' "$1" | paths_need_deploy; echo "$?" ); }
need()   { local rc; rc="$(pnd_rc "$1")"; [[ "$rc" == "0" ]] && ok "need: $1" || bad "expected need(0) for $1, got '$rc'"; }
noneed() { local rc; rc="$(pnd_rc "$1")"; [[ "$rc" == "1" ]] && ok "no-need: $1" || bad "expected no-need(1) for $1, got '$rc'"; }

section "Syntax + executable + help"
bash -n "$RECON" && ok "kg_reconcile syntax" || bad "kg_reconcile syntax"
[[ -x "$RECON" ]] && ok "kg_reconcile executable" || bad "kg_reconcile not executable"
help_out="$("$RECON" --help 2>&1)"; help_rc=$?
[[ "$help_rc" -eq 0 ]] && ok "--help exit 0" || bad "--help exit $help_rc"
grep -qi "reconcile" <<< "$help_out" && ok "--help mentions reconcile" || bad "--help missing usage"

section "paths_need_deploy 觸發正則"
need   "backend/src/x.py"
need   "backend/pyproject.toml"
need   "backend/Dockerfile"
need   "backend/static/a.css"
need   "backend/index.html"
need   "backend/uv.lock"
noneed "ios/x.swift"
noneed "docs/x.md"
noneed "backend/.env"
noneed "backend/data/x.db"

section "no-change → noop"
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "noop" ]] && ok "verdict noop" || bad "expected noop, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "noop exit 0" || bad "noop exit $rc"
# smoke 欄位是**發佈出去的機讀契約**（docs/reference/tech_index.md、docs/sop/deploy.md），
# 四個取值就要四條斷言。原本只釘 unverified，於是把 "n/a"/"ok"/"bad" 改成垃圾字串照樣全綠。
grep -q '"smoke":"n/a"' <<<"$out" && ok "noop: smoke=n/a（沒進 gate 的路徑）" || bad "noop: smoke 欄位不是 n/a (out=$out)"
[[ ! -s "$COMPOSELOG" ]] && ok "noop: compose not called" || bad "noop: compose called ($(cat "$COMPOSELOG"))"
grep -q "pull" "$GITLOG" && bad "noop: git pull called" || ok "noop: git pull not called"
# 心跳量的是「reconciler 還活著嗎」不是「有沒有部署」，所以**連 noop 這條路徑都要寫**。
# 在 noop 上斷言正是因為它是最容易被漏掉的那條：只在 deployed 路徑寫心跳的實作，會讓
# 一台「活著但無事可做」的 reconciler 看起來跟停擺一模一樣。
grep -q "^tick " "$STATE" 2>/dev/null && ok "noop: tick 心跳已寫入 state" || bad "noop: tick 心跳未寫入 state"
noop_err="$(run_recon --once 2>&1 >/dev/null)"
grep -q "已同版" <<<"$noop_err" && bad "noop: default 不應寫重複人讀 log" || ok "noop: default 不寫重複人讀 log"

section "non-backend change (docs) → ff-only"
new_scratch docs
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "ff-only" ]] && ok "verdict ff-only" || bad "expected ff-only, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "ff-only exit 0" || bad "ff-only exit $rc"
[[ ! -s "$COMPOSELOG" ]] && ok "ff-only: compose not called" || bad "ff-only: compose called"
grep -q "pull --ff-only" "$GITLOG" && ok "ff-only: git pull --ff-only called" || bad "ff-only: pull not called"
head_now="$("$REALGIT" -C "$REPO" rev-parse HEAD)"
[[ "$head_now" == "$SHA_NEW" ]] && ok "ff-only: repo ff'd to origin sha" || bad "ff-only: HEAD=$head_now != $SHA_NEW"

section "backend change + smoke 全綠 → deployed"
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "deployed" ]] && ok "verdict deployed" || bad "expected deployed, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "deployed exit 0" || bad "deployed exit $rc"
compose_ups="$(grep -c 'up -d --build' "$COMPOSELOG" 2>/dev/null || echo 0)"
[[ "$compose_ups" -eq 1 ]] && ok "deployed: compose up --build once" || bad "deployed: compose up x$compose_ups"
grep -q "sha=$SHA_NEW user=reconciler" "$DEPLOYLOG" && ok "deployed: deploy.log line" || bad "deployed: deploy.log missing"
grep -q '"smoke":"ok"' <<<"$out" && ok "deployed: smoke=ok（外部真的驗過了）" || bad "deployed: smoke 欄位不是 ok (out=$out)"
ver_now="$(cat "$VERSIONFILE")"
[[ "$ver_now" == "$SHA_NEW" ]] && ok "deployed: VERSION == new sha" || bad "deployed: VERSION=$ver_now != $SHA_NEW"
# 正控：這一關真的跑過，且它探的是**與外部 smoke 同一個 URL**（歸因規則的整個支點）。
grep -q "overall=ok" "$INFRALOG" && ok "deployed: infra_health 真的跑了且判 ok（正控）" || bad "deployed: infra_health 沒被呼叫或沒判 ok（$(cat "$INFRALOG" 2>/dev/null)）"
# 自噬迴圈守衛：部署收斂是 reconciler **自己的職責**，把自己的收斂狀態納入自我健康
# 條件會構成迴圈——release 後到收斂完成之間必然 drift，於是它會回滾一次本來健康的部署。
# 故這一關必須以 KG_HEALTH_DEPLOY_DRIFT=0 呼叫。
grep -q "deploy_drift=0" "$INFRALOG" && ok "deployed: infra_health 以 KG_HEALTH_DEPLOY_DRIFT=0 呼叫" || bad "deployed: infra_health 未關掉 deploy_drift，有自噬迴圈風險（$(cat "$INFRALOG" 2>/dev/null)）"
[[ ${#SHA_NEW} -eq 40 && "$ver_now" == "$SHA_NEW" ]] && ok "deployed: VERSION 是完整 40 字元 sha（Sentry release 名的唯一來源）" || bad "deployed: VERSION=$ver_now 不是完整 sha"

section "deployed → Sentry release 紀錄（best-effort，永不影響 verdict）"
sentry_fixture() {
  MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
}
sentry_flow() {  # $1=mode → 設 out/rc/err/elapsed
  new_scratch backend
  sentry_fixture
  local t0; t0=$(date +%s)
  out="$(KG_SENTRY_RELEASE_OVERRIDE="$BIN/sentry_mock.sh" MOCK_SENTRY_MODE="$1" KG_RECON_SENTRY_TIMEOUT=2 \
    run_recon --once 2>"$SC/sentry.err")"; rc=$?
  elapsed=$(( $(date +%s) - t0 )); err="$(cat "$SC/sentry.err")"
}
sentry_flow ok
[[ "$(get_verdict "$out")" == "deployed" && "$rc" -eq 0 ]] && ok "sentry ok: verdict deployed exit 0" || bad "sentry ok: verdict=$(get_verdict "$out") rc=$rc"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 1 && "$out" == '{"schema":"kg.deploy.reconcile.v1"'* ]] \
  && ok "sentry ok: stdout 仍只有一行 JSON（recorder 輸出被導去 stderr）" || bad "sentry ok: stdout 被污染: $out"
[[ "$(cat "$SENTRYLOG" 2>/dev/null)" == "record-backend --sha $SHA_NEW --environment production --name reconciler" ]] \
  && ok "sentry ok: recorder 收到完整 sha + production + reconciler" || bad "sentry ok: recorder argv=$(cat "$SENTRYLOG" 2>/dev/null)"
sentry_flow fail
[[ "$(get_verdict "$out")" == "deployed" && "$rc" -eq 0 ]] && ok "sentry fail: 部署照樣 deployed exit 0" || bad "sentry fail: verdict=$(get_verdict "$out") rc=$rc"
grep -q "Sentry" <<<"$err" && ok "sentry fail: stderr 告知 Sentry 紀錄失敗" || bad "sentry fail: stderr 沒提 Sentry ($err)"
sentry_flow hang
[[ "$(get_verdict "$out")" == "deployed" && "$rc" -eq 0 && "$elapsed" -lt 10 ]] \
  && ok "sentry hang: time bound 內放手，部署照樣 deployed（${elapsed}s）" || bad "sentry hang: verdict=$(get_verdict "$out") rc=$rc elapsed=${elapsed}s"
new_scratch backend
sentry_fixture
out="$(run_recon --once 2>"$SC/sentry.err")"; rc=$?
[[ "$(get_verdict "$out")" == "deployed" && "$rc" -eq 0 ]] && grep -q "SKIP" "$SC/sentry.err" \
  && ok "sentry helper 不存在：deployed + 大聲 SKIP" || bad "sentry missing: verdict=$(get_verdict "$out") rc=$rc err=$(grep -i sentry "$SC/sentry.err")"

section "外部 smoke 前兩次連不上 → 重試後仍 deployed（不得假回滾）"
# IMP-0060，這是**生產實際發生過的事故**（2026-08-04 12:40Z）：容器 recreate 後
# localhost 探針重試 5 次撐過了啟動，但 external_smoke_ok 只打**一次**，那一次落在
# Cloudflare tunnel 還沒接回新 origin 的窗口內 → HTTP=000 → reason=smoke → 回滾。
# 兩個探針對同一件事（服務剛起來需要幾秒）有不同的耐心，而只有其中一個有重試。
# force-recreate 讓每次部署都會 recreate，於是這個原本偶發的失敗變成每次必中。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
# harness 把 KG_RECON_HEALTH_ATTEMPTS 釘在 2（跑得快），所以注入 1 次失敗＝落在預算內。
out="$(MOCK_EXTERNAL_FAIL_FIRST=1 run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "deployed" ]] && ok "external flap: verdict deployed" || bad "external flap: expected deployed, got '$v' — 單次探針把 tunnel 重連當成部署失敗"
[[ "$rc" -eq 0 ]] && ok "external flap: exit 0" || bad "external flap: exit $rc"
grep -q "ROLLED_BACK" "$DEPLOYLOG" 2>/dev/null && bad "external flap: 假回滾了" || ok "external flap: 未回滾"
ext_calls="$(cat "$SC/external_calls" 2>/dev/null || echo 0)"
[[ "$ext_calls" -ge 2 ]] && ok "external flap: 真的重試了（$ext_calls 次）" || bad "external flap: 只打了 $ext_calls 次 — 沒有重試，上面的綠是別的原因"

section "外部全程拿不到任何 HTTP 回應（主機端斷網）→ 落地 + 告警，不得回滾"
# IMP-0061。健康 gate 把**我這台量不到**判成**這次部署壞了**，而兩者不是同一件事。
# 2026-08-04 事故：felix 的 DNS 掛了，容器與 tunnel 都好端端的、使用者也拿得到服務，
# gate 卻從 felix 內部量外部可達性、量不到就回滾——而回滾的 `--build` 又因為同一個
# 網路問題失敗（IMP-0060 C2）。兩個失效相關而非獨立：gate 最容易假失敗的時候，正是
# 回滾最不可能成功的時候。
#
# 判準：回滾只有在**證據指控被部署的那份 code** 時才正當。localhost 探針此刻已經證明
# 新 sha 起來了；「拿到 HTTP 回應但內容不對」是關於服務鏈的證據，「一個 HTTP 回應都
# 拿不到」則什麼都沒證明——除了這台機器連不出去。
#
# 兩種 shape 都跑，逼分類器不准挑替身的形狀來認：
#   code000 = 真 curl 的形狀（stdout 印 000、exit 6 → 呼叫端 code="000"）
#   silent  = 舊替身的形狀（什麼都不印 → 呼叫端 code=""）
# 只認其中一種的實作會在這裡紅一半（見 test 檔 make_mock_curl 內的實測註解）。
for shape in code000 silent; do
  new_scratch backend
  MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
  ERRLOG="$SC/recon.err"
  out="$(MOCK_EXTERNAL_FAIL_FIRST=99 MOCK_EXTERNAL_FAIL_SHAPE=$shape run_recon --once 2>"$ERRLOG")"; rc=$?
  v="$(get_verdict "$out")"
  [[ "$v" == "deployed" ]] && ok "host-outage[$shape]: verdict deployed（沒把斷網判成部署壞了）" || bad "host-outage[$shape]: expected deployed, got '$v' — 主機端連不出去被判成這次部署壞了 (out=$out)"
  [[ "$rc" -eq 0 ]] && ok "host-outage[$shape]: exit 0" || bad "host-outage[$shape]: exit $rc"
  # 落地了不代表可以假裝一切正常：verdict 與 deploy.log 都要留下「這次外部沒驗過」的痕跡。
  # 這兩條是持久、可 grep 的證據；stderr 告警是次要的（沒人保證有人在讀 launchd err log）。
  grep -q '"smoke":"unverified"' <<<"$out" && ok "host-outage[$shape]: verdict 標記 smoke=unverified" || bad "host-outage[$shape]: verdict 沒標 smoke 未驗證，落地被當成完全成功 (out=$out)"
  grep -q "sha=$SHA_NEW user=reconciler smoke=unverified" "$DEPLOYLOG" && ok "host-outage[$shape]: deploy.log 記下 smoke=unverified" || bad "host-outage[$shape]: deploy.log 沒記 smoke=unverified（$(cat "$DEPLOYLOG" 2>/dev/null)）"
  grep -q "ROLLED_BACK" "$DEPLOYLOG" 2>/dev/null && bad "host-outage[$shape]: 回滾了一個其實健康的部署" || ok "host-outage[$shape]: 未回滾"
  grep -q "^poison " "$STATE" 2>/dev/null && bad "host-outage[$shape]: 寫了 poison — 自己把自己凍結 1 小時" || ok "host-outage[$shape]: 未寫 poison"
  [[ "$(cat "$VERSIONFILE")" == "$SHA_NEW" ]] && ok "host-outage[$shape]: VERSION == 新 sha" || bad "host-outage[$shape]: VERSION=$(cat "$VERSIONFILE") != $SHA_NEW"
  [[ "$(cat "$SERVEDFILE")" == "$SHA_NEW" ]] && ok "host-outage[$shape]: 容器實際 serving 新 sha" || bad "host-outage[$shape]: serving=$(cat "$SERVEDFILE") != $SHA_NEW"
  # 正控：先證明這個探針**讀得到** stderr，否則下面「沒有回滾告警」跟「根本沒接到 stderr」
  # 長得一模一樣（這個檔已經被這種空斷言咬過一次，見下方 no-image rollback 段的註解）。
  grep -q "external attempt" "$ERRLOG" && ok "host-outage[$shape]: 探針讀得到 stderr（正控）" || bad "host-outage[$shape]: 連重試日誌都沒讀到 — 探針壞了，不是行為對了"
  grep -q "ALERT: 部署健康 gate 失敗" "$ERRLOG" && bad "host-outage[$shape]: 仍發回滾告警" || ok "host-outage[$shape]: 未發回滾告警"
  # 只認 `ALERT: ` 前綴（alert() 是唯一產生者），不要只 grep「外部 smoke」——那個詞在
  # dry-run 預覽字串裡也有，會被別的用途的同形 token 滿足。
  grep -q "ALERT: 外部 smoke" "$ERRLOG" && ok "host-outage[$shape]: 發了「量不到」告警要人看" || bad "host-outage[$shape]: 靜靜落地，沒有任何告警"
  # ── review D1：放行 unreachable 之後，**下一關會用同一個 URL 再問一次同一個問題** ──
  # 正控先行：證明 infra_health 這一關真的跑了、且真的因為那支對外探針而 crit。
  # 少了這兩條，下面「沒有 reason=infra」與「這一關根本沒被呼叫」長得一模一樣。
  grep -q "http_probe=crit" "$INFRALOG" && ok "host-outage[$shape]: infra_health 的對外探針真的 crit 了（正控）" || bad "host-outage[$shape]: infra 替身沒 crit — 替身比真實依賴仁慈，D1 的失效模式又被刪掉了（$(cat "$INFRALOG" 2>/dev/null)）"
  grep -q "overall=crit" "$INFRALOG" && ok "host-outage[$shape]: infra_health 整體 CRIT（exit 2）仍照樣落地（正控）" || bad "host-outage[$shape]: infra_health 沒判 CRIT，這條綠是別的原因"
  # 「同一個 URL」不能是註解裡的假設：reconciler 必須把 KG_HEALTH_PROBE_URL 釘成
  # 自己剛剛探過的那個，歸因才是結構上為真而非碰巧預設值相同。
  grep -q "pinned=yes" "$INFRALOG" && ok "host-outage[$shape]: reconciler 有把 infra 探針 URL 釘成同一個" || bad "host-outage[$shape]: infra 探針 URL 沒被釘（歸因只是碰巧靠預設值相同）"
  grep -q "probe_url=https://wordnexus.lol/api/system/info" "$INFRALOG" && ok "host-outage[$shape]: 釘的正是外部 smoke 那個 URL" || bad "host-outage[$shape]: infra 探針打的是別的 URL（$(cat "$INFRALOG" 2>/dev/null)）"
  grep -q "reason=infra" "$DEPLOYLOG" 2>/dev/null && bad "host-outage[$shape]: 回滾理由只是從 smoke 換成 infra — 同一個主機端問題，同一個回滾" || ok "host-outage[$shape]: 沒有把主機端問題翻譯成 reason=infra"
  # 預算真的被吃完才宣告 unverified；否則「有人把探針整個刪掉」也會產生一樣的綠。
  ext_calls="$(cat "$SC/external_calls" 2>/dev/null || echo 0)"
  [[ "$ext_calls" -ge 2 ]] && ok "host-outage[$shape]: 探針真的重試到預算用盡（$ext_calls 次）" || bad "host-outage[$shape]: 只打了 $ext_calls 次 — 沒重試就宣告量不到"
done

section "外部 smoke 斷線但 infra 回真實 HTTP 502 → 回滾（不是同一場斷網）"
# 兩關量測不同時刻：smoke 燒完預算後，infra 可能已拿到真實 HTTP 回應。
# 這代表服務鏈有證據，不得因 smoke unreachable 而放行。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|502|boom
wordnexus.lol/api/health|401|{\"detail\":\"x\"}
EOF
)" "$SC" "$SERVEDFILE")"
ERRLOG="$SC/recon.err"
out="$(MOCK_EXTERNAL_FAIL_FIRST=2 run_recon --once 2>"$ERRLOG")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "outage-then-status:rolled-back: verdict rolled-back" || bad "outage-then-status:rolled-back: expected rolled-back, got '$v' (out=$out)"
[[ "$rc" -ne 0 ]] && ok "outage-then-status: exit non-zero" || bad "outage-then-status: expected non-zero exit"
grep -q "reason=infra" "$DEPLOYLOG" && ok "outage-then-status: reason=infra" || bad "outage-then-status: missing reason=infra"
grep -q "^poison $SHA_NEW " "$STATE" && ok "outage-then-status: poison written" || bad "outage-then-status: missing poison"
grep -q "http_code=502" "$INFRALOG" && ok "outage-then-status: infra really got HTTP 502" || bad "outage-then-status: infra did not get HTTP 502"
grep -q "external attempt" "$ERRLOG" && ok "outage-then-status: smoke exhausted its budget" || bad "outage-then-status: smoke retry evidence missing"
ext_calls="$(cat "$SC/external_calls" 2>/dev/null || echo 0)"
[[ "$ext_calls" -ge 3 ]] && ok "outage-then-status: external calls >= 3 ($ext_calls)" || bad "outage-then-status: expected >= 3 external calls, got $ext_calls"

section "斷網當下 infra_health 另有 http_probe 以外的 crit → 仍必須回滾（不得把整關關掉）"
# 上一段放行的**只能是**「同一場斷網的第二個症狀」。如果 infra_health 還告訴你容器不見了
# ／磁碟爆了／tunnel 掛了，那是關於這台機器與這個服務的真證據，與能不能連出去無關——
# 放行它等於把 infra 這一關整個關掉，那不是修 D1，是用更大的洞蓋掉小洞。
# 這一段與上一段合起來才有判別力：同一場斷網、兩個相反的結論。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
ERRLOG="$SC/recon.err"
out="$(MOCK_EXTERNAL_FAIL_FIRST=99 MOCK_INFRA_EXTRA_CRIT=container run_recon --once 2>"$ERRLOG")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "infra-real-crit: 仍回滾" || bad "infra-real-crit: expected rolled-back, got '$v' — 斷網變成 infra 這關的免死金牌 (out=$out)"
grep -q "reason=infra" "$DEPLOYLOG" && ok "infra-real-crit: 理由記成 infra" || bad "infra-real-crit: deploy.log 沒記 reason=infra（$(cat "$DEPLOYLOG" 2>/dev/null)）"
grep -q "^poison $SHA_NEW " "$STATE" && ok "infra-real-crit: poison 寫入" || bad "infra-real-crit: poison missing"
grep -q "extra_crit=container" "$INFRALOG" && ok "infra-real-crit: 替身真的多吐了一個 crit（正控）" || bad "infra-real-crit: 替身沒注入 extra crit，這條紅/綠都不算數"

section "外部 smoke 綠但 infra_health CRIT → 回滾 reason=infra（既有行為不得被放寬）"
# infra 這條分支原本**零覆蓋**（舊替身恆 exit 0），所以「修 D1 時不小心把 infra 全放行」
# 不會有任何測試反對。先把既有正確行為釘住，再談例外。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_INFRA_EXTRA_CRIT=ingress run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "infra-crit-smoke-ok: 回滾" || bad "infra-crit-smoke-ok: expected rolled-back, got '$v' (out=$out)"
[[ "$rc" -ne 0 ]] && ok "infra-crit-smoke-ok: exit 非 0" || bad "infra-crit-smoke-ok: exit 0"
grep -q "reason=infra" "$DEPLOYLOG" && ok "infra-crit-smoke-ok: 理由記成 infra" || bad "infra-crit-smoke-ok: 沒記 reason=infra"
grep -q '"smoke":"ok"' <<<"$out" && ok "infra-crit-smoke-ok: smoke 仍記 ok（外部確實驗過，壞的是別的）" || bad "infra-crit-smoke-ok: smoke 欄位失真 (out=$out)"

section "infra_health CRIT 但 JSON 讀不懂 → 無法歸因 → 照舊回滾（fail-closed）"
# 歸因規則的前提是「讀得懂它為什麼 crit」。讀不懂就不准放行——否則 infra_health 換版、
# 被替換、或吐了非預期輸出，就會靜悄悄地變成「什麼都不擋」。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_EXTERNAL_FAIL_FIRST=99 MOCK_INFRA_MALFORMED=1 run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "infra-unparseable: 讀不懂就不放行" || bad "infra-unparseable: expected rolled-back, got '$v' — 看不懂被當成沒問題 (out=$out)"
grep -q "reason=infra" "$DEPLOYLOG" && ok "infra-unparseable: 理由記成 infra" || bad "infra-unparseable: 沒記 reason=infra"

section "外部回得了 HTTP 但 /api/health 5xx → 仍必須回滾（重試不得變成無條件放行）"
# 這一段原本注入 MOCK_EXTERNAL_FAIL_FIRST=99（＝完全連不上）來釘「重試不得變成無條件
# 放行」。IMP-0061 之後那個情境的正確答案改成「落地」，所以斷言被搬到上一段；但**意圖
# 必須保留**，只是重新瞄準真正該擋的那條分支：拿得到 HTTP 回應、內容卻是壞的。
# 這條與上一段合起來才是真正的判別力——同一個 gate 兩個相反的結論，而不是「兩邊都非零」。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|503|boom
EOF
)" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "external 5xx: 仍回滾" || bad "external 5xx: expected rolled-back, got '$v' — 重試把真失敗吃掉了"
grep -q "reason=smoke" "$DEPLOYLOG" && ok "external 5xx: 理由記成 smoke" || bad "external 5xx: deploy.log 沒記 reason=smoke"

section "backend change 但不動 image → 仍 deployed（不得假回滾）"
# IMP-0056：`backend/docker-compose.yml` 的純註解改動命中 BACKEND_TRIGGER_RE，但不進
# image、也不改變解析後的 config hash，所以 compose 不 recreate。健康 gate 比對容器
# 自報版本與新 sha，於是永遠不相等 → 回滾 + poison + 告警；poison 只冷卻 3600 秒，
# 冷卻完下一 tick 又看到 origin/prod 領先 → 再部署再失敗，**每小時自我重複**，
# 直到有人推一個真的會動 image 的 commit 為止。
new_scratch backend-noimage
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "deployed" ]] && ok "no-image change: verdict deployed" || bad "no-image change: expected deployed, got '$v' — 這就是每小時重複的假回滾 (out=$out)"
[[ "$rc" -eq 0 ]] && ok "no-image change: exit 0" || bad "no-image change: exit $rc"
[[ -s "$DEPLOYLOG" ]] && ok "no-image change: 探針讀得到 deploy.log（正控）" || bad "no-image change: deploy.log 是空的 — 反向斷言無從區分「沒回滾」與「路徑打錯」"
grep -q "^poison " "$STATE" 2>/dev/null && bad "no-image change: poison 寫入了 — 冷卻後會再炸一次，這正是迴圈" || ok "no-image change: 未寫 poison"
grep -q "ROLLED_BACK" "$DEPLOYLOG" 2>/dev/null && bad "no-image change: deploy.log 記了 ROLLED_BACK" || ok "no-image change: 未回滾"
ver_now="$(cat "$VERSIONFILE")"
[[ "$ver_now" == "$SHA_NEW" ]] && ok "no-image change: VERSION == new sha" || bad "no-image change: VERSION=$ver_now != $SHA_NEW"
served_now="$(cat "$SERVEDFILE")"
[[ "$served_now" == "$SHA_NEW" ]] && ok "no-image change: 容器實際 serving 新 sha" || bad "no-image change: serving=$served_now != ${SHA_NEW}（容器沒被 recreate）"

section "lock-only 依賴更新（backend/uv.lock）→ 走 build 路徑並 deployed"
# #2088：image 依 backend/uv.lock 安裝。若 trigger 漏掉它，lock-only commit 讓 origin/prod
# 前進卻走 no-build 路徑，生產永遠跑舊依賴版本。
new_scratch backend-lockonly
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "deployed" ]] && ok "lock-only: verdict deployed" || bad "lock-only: expected deployed, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "lock-only: exit 0" || bad "lock-only: exit $rc"
grep -q 'up -d --build' "$COMPOSELOG" 2>/dev/null && ok "lock-only: compose build 路徑被執行" || bad "lock-only: 沒有 compose up --build（走了 no-build 路徑，生產仍跑舊依賴）"
served_now="$(cat "$SERVEDFILE")"
[[ "$served_now" == "$SHA_NEW" ]] && ok "lock-only: 容器實際 serving 新 sha" || bad "lock-only: serving=$served_now != $SHA_NEW"

section "backend change + smoke 失敗 → rolled-back"
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|500|internal error
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(KG_SENTRY_RELEASE_OVERRIDE="$BIN/sentry_mock.sh" run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "verdict rolled-back" || bad "expected rolled-back, got '$v' (out=$out)"
[[ ! -s "$SENTRYLOG" ]] && ok "rolled-back: 不記 Sentry release（只有健康部署才記）" || bad "rolled-back: recorder 被呼叫 ($(cat "$SENTRYLOG"))"
[[ "$rc" -ne 0 ]] && ok "rolled-back exit non-zero ($rc)" || bad "rolled-back expected non-zero exit"
grep -q "reset --hard $SHA_OLD" "$GITLOG" && ok "rolled-back: git reset --hard ROLLBACK_SHA" || bad "rolled-back: reset missing"
compose_ups="$(grep -c 'up -d --build' "$COMPOSELOG" 2>/dev/null || echo 0)"
[[ "$compose_ups" -eq 2 ]] && ok "rolled-back: compose up twice (deploy+rollback)" || bad "rolled-back: compose up x$compose_ups"
grep -q "^poison $SHA_NEW " "$STATE" && ok "rolled-back: poison written for new sha" || bad "rolled-back: poison missing"
grep -q "ROLLED_BACK from=$SHA_NEW to=$SHA_OLD reason=smoke" "$DEPLOYLOG" && ok "rolled-back: deploy.log ROLLED_BACK" || bad "rolled-back: deploy.log ROLLED_BACK missing"
grep -q '"smoke":"bad"' <<<"$out" && ok "rolled-back: smoke=bad（拿得到回應但不合格）" || bad "rolled-back: smoke 欄位不是 bad (out=$out)"
ver_now="$(cat "$VERSIONFILE")"
[[ "$ver_now" == "$SHA_OLD" ]] && ok "rolled-back: VERSION back to old sha" || bad "rolled-back: VERSION=$ver_now != $SHA_OLD"

section "不動 image 的改動 + smoke 失敗 → 回滾後容器要真的回到舊版"
# 部署路徑加了 --force-recreate 之後產生的**二階效應**：容器已經被動過，所以回滾若不也
# force，image 沒變 → 不 recreate → 容器仍自報 new_sha → 回滾後健康確認失敗 → 誤發
# 「生產可能雙壞，需立即人工檢查」這種最高級告警。IMP-0056 原本判定回滾路徑不該加旗標，
# 那個判斷在部署路徑加了之後就過期了。
new_scratch backend-noimage
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|500|internal error
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
# 告警走 stderr（kg_reconcile.sh:70），所以要接住 stderr 才看得到——原本這裡寫成
# `grep -q ... "$out"`，把一個**字串**當檔名餵給 grep，於是它永遠找不到檔案、永遠回
# 非零、`||` 那側永遠印 ✓。空斷言，而且就出現在專門在抓空斷言的這一輪裡。
ERRLOG="$SC/recon.err"
out="$(run_recon --once 2>"$ERRLOG")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "no-image rollback: verdict rolled-back" || bad "no-image rollback: expected rolled-back, got '$v'"
[[ "$rc" -ne 0 ]] && ok "no-image rollback: exit non-zero ($rc)" || bad "no-image rollback: 回滾卻 exit 0"
served_now="$(cat "$SERVEDFILE")"
[[ "$served_now" == "$SHA_OLD" ]] && ok "no-image rollback: 容器實際回到舊版" || bad "no-image rollback: serving=$served_now != ${SHA_OLD}（回滾沒 recreate，會誤發雙壞告警）"
# 正控：先證明這個探針**看得到**告警，否則下面那條「沒有雙壞告警」跟「根本沒接到 stderr」
# 長得一模一樣。
grep -q "ALERT: 部署健康 gate 失敗" "$ERRLOG" && ok "no-image rollback: 探針讀得到告警（正控）" || bad "no-image rollback: 連預期中的 gate 失敗告警都沒讀到 — 探針壞了，不是行為對了"
grep -q "回滾後舊版" "$ERRLOG" && bad "no-image rollback: 誤發雙壞告警" || ok "no-image rollback: 未誤發雙壞告警"

section "每一個 compose 呼叫都必須 force-recreate（字面防護）"
# 行為斷言更強，但 IMP-0052 當年是靠**字面**斷言抓到的：`devops.sh` 掉了同一個旗標，
# 紅了 6.5 週。兩條部署路徑既然同語意，就配同形的防護。
# 用「所有呼叫點」而非「第 N 行」，新增第三個呼叫點會自動被涵蓋；dry-run 的預覽字串
# 也含 ${KG_COMPOSE}，所以這條同時釘住「預覽不得少報那個會造成停機的旗標」。
naked="$(grep -n '\$KG_COMPOSE up -d --build' "$RECON" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v -- '--force-recreate' || true)"
[[ -z "$naked" ]] && ok "所有 compose 呼叫與 dry-run 預覽都帶 --force-recreate" || bad "有 compose 呼叫沒帶 --force-recreate: $naked"
# 自測：探針要真的找得到呼叫點，否則上面是空迴圈式的全綠。
call_sites="$(grep -c '\$KG_COMPOSE up -d --build' "$RECON" || echo 0)"
[[ "$call_sites" -ge 3 ]] && ok "字面探針找到 $call_sites 處 compose 呼叫（deploy/rollback/dry-run）" || bad "字面探針只找到 $call_sites 處 — 探針壞了，不是程式對了"

section "build 失敗 → rolled-back，且回滾確實重建容器"
# 這條分支原本零覆蓋（compose stub 恆 exit 0），而它正是 rollback 旗標新成本的落點：
# build 失敗時部署路徑根本沒 recreate 過，回滾仍無條件重建一顆本來好好的容器。
# 這裡把那次重建**斷言出來**，成本就不是隱形的了。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_OLD"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_COMPOSE_FAIL_NTH=1 run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "build-fail: verdict rolled-back" || bad "build-fail: expected rolled-back, got '$v'"
grep -q "ROLLED_BACK from=$SHA_NEW to=$SHA_OLD reason=build" "$DEPLOYLOG" && ok "build-fail: 成功回滾並記錄 ROLLED_BACK" || bad "build-fail: deploy.log 沒記成功 ROLLED_BACK reason=build"
recreates="$(wc -l < "$RECREATELOG" 2>/dev/null | tr -d ' ' || echo 0)"
[[ "$recreates" == "1" ]] && ok "build-fail: 僅回滾那次 recreate（部署那次 build 就死了）" || bad "build-fail: recreate x${recreates}（預期 1）"
served_now="$(cat "$SERVEDFILE")"
[[ "$served_now" == "$SHA_OLD" ]] && ok "build-fail: 容器停在舊版" || bad "build-fail: serving=$served_now != $SHA_OLD"

section "回滾自己的 compose 失敗 → rollback-failed，必須說「回滾未生效」，不得說「雙壞」"
# IMP-0060 的 C2，**生產實際發生過**：健康 gate 因主機 DNS 掛掉而假失敗 → 進回滾 →
# 回滾的 `--build` 也因為同一個 DNS 取不到 registry metadata 而失敗 → 退出碼被整個丟棄
# → git tree 與 VERSION 退回舊 sha，容器卻仍跑新版。接著舊版健康檢查當然不符，於是發出
# 「生產可能雙壞」——語意相反的誤導告警。真相是回滾根本沒發生。
#
# 兩個失效**相關而非獨立**：gate 最容易假失敗的時候，正是回滾最不可能成功的時候。
# 注意這個 seam（MOCK_COMPOSE_FAIL_NTH）**早就存在**，`=1` 測了部署 build 失敗，
# 只是從來沒有人寫 `=2`。不是替身不夠忠實，是買好的儀器沒去讀。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|500|internal error
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
ERRLOG="$SC/recon.err"
out="$(MOCK_COMPOSE_FAIL_NTH=2 run_recon --once 2>"$ERRLOG")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rollback-failed" ]] && ok "rollback-build-fail: verdict rollback-failed" || bad "rollback-build-fail: expected rollback-failed, got '$v'"
[[ "$rc" -ne 0 ]] && ok "rollback-build-fail: exit non-zero ($rc)" || bad "rollback-build-fail: 回滾未生效卻 exit 0"
grep -q "ROLLBACK_FAILED from=$SHA_NEW to=$SHA_OLD reason=smoke compose_rc=1" "$DEPLOYLOG" \
  && ok "rollback-build-fail: deploy.log 記錄完整 ROLLBACK_FAILED 證據" \
  || bad "rollback-build-fail: deploy.log 缺少完整 ROLLBACK_FAILED 證據"
grep -q "回滾的 compose 失敗" "$ERRLOG" && ok "rollback-build-fail: 明確告知回滾未生效" || bad "rollback-build-fail: 回滾 compose 的退出碼被吞掉了 — 這正是生產當天發生的事"
grep -q "生產可能雙壞" "$ERRLOG" && bad "rollback-build-fail: 仍發語意相反的『雙壞』告警" || ok "rollback-build-fail: 未發誤導的雙壞告警"
grep -q "^poison $SHA_NEW " "$STATE" && ok "rollback-build-fail: poison 保留以避免立即重試" || bad "rollback-build-fail: 未保留 poison"
grep -q "ROLLED_BACK" "$DEPLOYLOG" && bad "rollback-build-fail: 回滾未生效卻寫入 ROLLED_BACK" || ok "rollback-build-fail: 未誤寫成功回滾"
served_now="$(cat "$SERVEDFILE")"
[[ "$served_now" == "$SHA_NEW" ]] && ok "rollback-build-fail: 容器確實仍跑新版（與告警一致）" || bad "rollback-build-fail: serving=${served_now}，告警與事實不符"

section "回滾後容器起不來 → 必須發雙壞告警"
# 這是上一條反向斷言的**正控**：先前只斷言「沒有雙壞告警」，把那個告警字串改名一樣全綠
# （reviewer 實測），因為 ✓ 與「這字串根本永遠找不到」長得一樣。這裡讓它真的發生一次。
# 順帶關掉「force-recreate 新引入的風險完全沒測」這個洞。
new_scratch backend
: > "$CONTAINER_DEAD"        # recreate 後容器起不來
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|500|internal error
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
ERRLOG="$SC/recon.err"
out="$(run_recon --once 2>"$ERRLOG")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "rolled-back" ]] && ok "double-fail: verdict rolled-back" || bad "double-fail: expected rolled-back, got '$v'"
grep -q "回滾後舊版" "$ERRLOG" && ok "double-fail: 雙壞告警確實發得出來（正控）" || bad "double-fail: 連舊版都不健康卻沒發最高級告警 — 那條反向斷言是空的"

section "poison 命中同 sha → poisoned-skip"
new_scratch backend
printf 'poison %s %s\n' "$SHA_NEW" "$(date +%s)" > "$STATE"
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "poisoned-skip" ]] && ok "verdict poisoned-skip" || bad "expected poisoned-skip, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "poisoned-skip exit 0" || bad "poisoned-skip exit $rc"
[[ ! -s "$COMPOSELOG" ]] && ok "poisoned-skip: compose not called" || bad "poisoned-skip: compose called"

section "--dry-run + backend change → dry-run（無 mutation）"
new_scratch backend
pre_ver="$(cat "$VERSIONFILE")"
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once --dry-run 2>"$SC/dryerr.txt")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "dry-run" ]] && ok "verdict dry-run" || bad "expected dry-run, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "dry-run exit 0" || bad "dry-run exit $rc"
[[ ! -s "$COMPOSELOG" ]] && ok "dry-run: compose not called" || bad "dry-run: compose called"
grep -q "pull" "$GITLOG" && bad "dry-run: git pull called" || ok "dry-run: git pull not called"
[[ "$(cat "$VERSIONFILE")" == "$pre_ver" ]] && ok "dry-run: VERSION unchanged" || bad "dry-run: VERSION mutated"
[[ ! -f "$STATE" ]] && ok "dry-run: state not written" || bad "dry-run: state written"
[[ ! -f "$DEPLOYLOG" ]] && ok "dry-run: deploy.log not written" || bad "dry-run: deploy.log written"
grep -qi "would" "$SC/dryerr.txt" && ok "dry-run: prints would-actions to stderr" || bad "dry-run: no would-actions"

section "lock 已被別人持有 → locked"
new_scratch backend
mkdir -p "$LOCK"
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "locked" ]] && ok "verdict locked" || bad "expected locked, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "locked exit 0" || bad "locked exit $rc"
[[ ! -s "$COMPOSELOG" ]] && ok "locked: compose not called" || bad "locked: compose called"
[[ -d "$LOCK" ]] && ok "locked: 未刪別人的鎖" || bad "locked: 誤刪他人鎖"

section "lock 被持有 + live != VERSION → 2b 讓路（VERSION 不被改寫）（#2266）"
new_scratch backend
echo "$SHA_NEW" > "$VERSIONFILE"       # 與 live（SHA_OLD）不一致；無鎖時 2b 會改寫它
mkdir -p "$LOCK"
pre_ver="$(cat "$VERSIONFILE")"; pre_sum="$(cksum < "$VERSIONFILE")"
MOCK_CURL="$(make_mock_curl "" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "locked" ]] && ok "locked-2b: verdict locked" || bad "locked-2b: expected locked, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "locked-2b: exit 0" || bad "locked-2b: exit $rc"
[[ "$(cat "$VERSIONFILE")" == "$pre_ver" && "$(cksum < "$VERSIONFILE")" == "$pre_sum" ]] \
  && ok "locked-2b: VERSION byte-identical" || bad "locked-2b: VERSION 被改寫為 $(cat "$VERSIONFILE")"
[[ ! -s "$COMPOSELOG" ]] && ok "locked-2b: compose not called" || bad "locked-2b: compose called"
[[ -d "$LOCK" ]] && ok "locked-2b: 未刪別人的鎖" || bad "locked-2b: 誤刪他人鎖"

section "鎖空閒時 2b 仍修正 stale VERSION，且 noop 不留鎖（#2266）"
new_scratch none
echo "$SHA_NEW" > "$VERSIONFILE"       # 宣稱 new，live=old；origin==old 時修正後同版 noop
MOCK_CURL="$(make_mock_curl "" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "noop" ]] && ok "unlocked-2b: verdict noop" || bad "unlocked-2b: expected noop, got '$v' (out=$out)"
[[ "$(cat "$VERSIONFILE")" == "$SHA_OLD" ]] && ok "unlocked-2b: VERSION 修正為 live==$SHA_OLD" || bad "unlocked-2b: VERSION=$(cat "$VERSIONFILE")"
[[ ! -e "$LOCK" ]] && ok "unlocked-2b: noop 後鎖不殘留" || bad "unlocked-2b: 鎖殘留"

section "VERSION 缺失 + 容器 down → graceful noop（block 修復，不崩）"
new_scratch none
rm -f "$VERSIONFILE"
MOCK_CURL="$(make_mock_curl "" "$SC")"           # 無 served、無 fixture → localhost 視為 down
out="$(run_recon --once 2>"$SC/seed.err")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "noop" ]] && ok "missing-VERSION: verdict noop（非崩潰）" || bad "missing-VERSION: expected noop, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "missing-VERSION: exit 0" || bad "missing-VERSION: exit $rc"
[[ -n "$out" ]] && ok "missing-VERSION: stdout 有 verdict（輸出契約守住）" || bad "missing-VERSION: stdout 空（block 未修）"
grep -qi "seed VERSION" "$SC/seed.err" && ok "missing-VERSION: alert 指引 seed VERSION" || bad "missing-VERSION: 無 seed 指引"
[[ ! -s "$COMPOSELOG" ]] && ok "missing-VERSION: compose not called" || bad "missing-VERSION: compose called"

section "VERSION 缺失但容器健在 → 以 live 版重建游標（crash-consistency）"
new_scratch none
rm -f "$VERSIONFILE"
MOCK_CURL="$(make_mock_curl "" "$SC" "$SERVEDFILE")"   # served=SHA_OLD（容器健在自報舊版）
out="$(run_recon --once 2>"$SC/live.err")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "noop" ]] && ok "live-recover: verdict noop（recovered==origin）" || bad "live-recover: expected noop, got '$v' (out=$out)"
[[ "$rc" -eq 0 ]] && ok "live-recover: exit 0" || bad "live-recover: exit $rc"
[[ -f "$VERSIONFILE" && "$(cat "$VERSIONFILE")" == "$SHA_OLD" ]] && ok "live-recover: VERSION 游標由 live 重建==$SHA_OLD" || bad "live-recover: VERSION 未重建（=$(cat "$VERSIONFILE" 2>/dev/null))"
grep -qi "serving" "$SC/live.err" && ok "live-recover: alert 標明以實際版為準" || bad "live-recover: 無 live-mismatch alert"
[[ ! -s "$COMPOSELOG" ]] && ok "live-recover: compose not called（已同版）" || bad "live-recover: compose called"

section "crash-window：VERSION 宣稱 new 但容器 serving old → 自癒重部署"
new_scratch backend
echo "$SHA_NEW" > "$VERSIONFILE"       # 謊稱已部署 new（VERSION 於 health 確認前寫入後斷電）
# SERVED 仍 = SHA_OLD（容器實際 serving 舊，compose 未成功跑完）
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(run_recon --once 2>"$SC/crash.err")"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "deployed" ]] && ok "crash-window: 自癒→verdict deployed" || bad "crash-window: expected deployed, got '$v' (out=$out)"
grep -qi "serving" "$SC/crash.err" && ok "crash-window: 偵測 VERSION 與 live 不一致" || bad "crash-window: 未偵測不一致"
[[ "$(cat "$VERSIONFILE")" == "$SHA_NEW" ]] && ok "crash-window: 重部署後 VERSION==$SHA_NEW" || bad "crash-window: VERSION=$(cat "$VERSIONFILE") != $SHA_NEW"
grep -q 'up -d --build' "$COMPOSELOG" && ok "crash-window: compose up 重建" || bad "crash-window: compose 未跑"

# ── 三平面解耦迴歸鎖：main 前進不觸發部署，reconciler 只看 origin/prod ──────────
section "prod 落後 main（main 有 backend 前進）→ noop 且從不看 main（解耦迴歸鎖）"
new_scratch none
# 讓 origin/main 超前 origin/prod 一個 backend commit；origin/prod 仍 == deployed。
# 舊模型（追 main）會在此部署；新模型（追 prod）必須 noop。
"$REALGIT" -C "$REPO" checkout -q main
echo "print(9)" >> "$REPO/backend/src/app.py"
"$REALGIT" -C "$REPO" add -A
"$REALGIT" -C "$REPO" commit -qm "main-only backend（不進 prod）"
"$REALGIT" -C "$REPO" push -q origin main 2>/dev/null
"$REALGIT" -C "$REPO" checkout -q prod
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "noop" ]] && ok "prod-behind-main: verdict noop（main 的 backend 不觸發部署）" || bad "prod-behind-main: expected noop, got '$v' (out=$out)"
[[ ! -s "$COMPOSELOG" ]] && ok "prod-behind-main: compose 未跑" || bad "prod-behind-main: compose 被觸發（$(cat "$COMPOSELOG")）"
if grep -qE "origin/main|origin main" "$GITLOG"; then
  bad "prod-behind-main: reconciler 竟碰 main（$(grep -E 'origin/main|origin main' "$GITLOG" | head -1)）"
else
  ok "prod-behind-main: git.log 從不出現 main（reconciler 只 fetch/diff prod）"
fi

section "prod 前進純非 backend → ff-only 但 VERSION 游標未變（釘不寫游標決策）"
new_scratch docs
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$v" == "ff-only" ]] && ok "ff-only-no-write: verdict ff-only" || bad "ff-only-no-write: expected ff-only, got '$v' (out=$out)"
[[ "$(cat "$VERSIONFILE")" == "$SHA_OLD" ]] && ok "ff-only-no-write: VERSION 游標未變（仍 ${SHA_OLD}）" || bad "ff-only-no-write: VERSION=$(cat "$VERSIONFILE") 被寫（§2.4 要求非 backend ff-only 不動游標）"

section "origin/prod 未 seed（首次啟用前）→ 非 dry-run 優雅 noop 不崩（守輸出契約）"
new_scratch none
# 模擬 origin/prod 尚未 seed：刪 origin 的 prod + 本地 tracking ref。fetch origin prod 會 fatal，
# 但容錯後應落到 rev-parse origin/prod→unknown→noop，而非 set -e 中止（回歸 IMPORTANT #1）。
"$REALGIT" -C "$ORIGIN" update-ref -d refs/heads/prod 2>/dev/null || true
"$REALGIT" -C "$REPO" update-ref -d refs/remotes/origin/prod 2>/dev/null || true
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>/dev/null)"; rc=$?
v="$(get_verdict "$out")"
[[ "$rc" -eq 0 ]] && ok "unseeded-prod: exit 0（fetch fatal 已容錯，不崩）" || bad "unseeded-prod: exit ${rc}（fetch 未容錯 → set -e 中止）"
[[ "$v" == "noop" ]] && ok "unseeded-prod: verdict noop（優雅落 unknown handler）" || bad "unseeded-prod: expected noop, got '$v' (out=$out)"
[[ -n "$out" ]] && ok "unseeded-prod: 有 JSON verdict（輸出契約守住）" || bad "unseeded-prod: stdout 空（契約破）"
[[ ! -s "$COMPOSELOG" ]] && ok "unseeded-prod: compose 未跑" || bad "unseeded-prod: compose 被觸發"

section "poison cooldown 前導零與非法值 → fail-closed"

poison_cooldown_case() {
  local cooldown="$1" label="$2"
  new_scratch backend
  printf 'poison %s %s\n' "$SHA_NEW" "$(date +%s)" > "$STATE"
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  set +e
  out="$(KG_RECON_POISON_COOLDOWN="$cooldown" run_recon --once 2>"$SC/cooldown.err")"
  rc=$?
  set -e
  v="$(get_verdict "$out")"
  if [[ "$v" == "poisoned-skip" && "$rc" -eq 0 && ! -s "$COMPOSELOG" ]]; then
    ok "poison cooldown[$label]: value stays poisoned"
  else
    bad "poison cooldown[$label]: expected poisoned-skip without compose, got verdict=$v rc=$rc"
  fi
}

poison_cooldown_case "09" "09"
poison_cooldown_case "08" "08"
poison_cooldown_case "" "empty"
poison_cooldown_case "not-a-number" "non-numeric"
poison_cooldown_case "90" "90 control"

new_scratch backend
printf 'poison %s not-a-timestamp\n' "$SHA_NEW" > "$STATE"
MOCK_CURL="$(make_mock_curl "" "$SC")"
set +e
out="$(run_recon --once 2>"$SC/timestamp.err")"
rc=$?
set -e
v="$(get_verdict "$out")"
if [[ "$v" == "poisoned-skip" && "$rc" -eq 0 && ! -s "$COMPOSELOG" ]]; then
  ok "poison cooldown[invalid timestamp]: value stays poisoned"
else
  bad "poison cooldown[invalid timestamp]: expected poisoned-skip without compose, got verdict=$v rc=$rc"
fi

section "poison 鍵 short/full SHA 前綴比對（升級前寫入的 short poison 仍擋對應 full sha）"

# poison_key_case <label> <key: prefix length of the new sha, or a literal> <expect: skip|run>
# (SHA_NEW is per-scratch, so a numeric key is cut after new_scratch.)
poison_key_case() {
  local label="$1" key="$2" expect="$3"
  new_scratch backend
  [[ "$key" =~ ^[0-9]+$ ]] && key="${SHA_NEW:0:$key}"
  printf 'poison %s %s\n' "$key" "$(date +%s)" > "$STATE"
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  set +e
  out="$(run_recon --once 2>"$SC/prefix.err")"
  rc=$?
  set -e
  v="$(get_verdict "$out")"
  if [[ "$expect" == skip ]]; then
    if [[ "$v" == "poisoned-skip" && "$rc" -eq 0 && ! -s "$COMPOSELOG" ]]; then
      ok "poison prefix[$label]: blocks the matching full sha"
    else
      bad "poison prefix[$label]: expected poisoned-skip without compose, got verdict=$v rc=$rc"
    fi
  else
    if [[ "$v" != "poisoned-skip" ]]; then
      ok "poison prefix[$label]: does not block (verdict=$v)"
    else
      bad "poison prefix[$label]: wrongly blocked the sha"
    fi
  fi
}

poison_key_case "7-char short sha" 7 skip
poison_key_case "12-char short sha" 12 skip
poison_key_case "other 7-char sha (control)" "deadbee" run
poison_key_case "6-char prefix is too short" 6 run

section "readiness（fail-closed）：info 200 但 /app/data 壞掉 → 不得判健康（2026-10-09 事故）"
# 事故：/app/data 被刪後 /api/system/info 仍 200、/api/health 對 reconcile 是 429，
# 三小時沒人發現。每個斷言都以正控（readiness 200 時綠）為前提，見 noop 與 deployed 段。
# 前一段留下 set -e；本段刻意讓被測腳本非 0 退出，所以先關掉。
set +e
# 1) noop tick 也要探 readiness
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
rm -f "$SC/ready_calls"
out="$(run_recon --once 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "noop" && "$rc" -eq 0 ]] && ok "ready noop 正控: readiness 200 → noop exit 0" || bad "ready noop 正控: verdict=$(get_verdict "$out") rc=$rc"
grep -q "localhost:8000/api/system/info/ready 200" "$SC/ready_calls" 2>/dev/null && ok "ready noop 正控: noop tick 真的探了 readiness" || bad "ready noop 正控: noop tick 沒探 readiness"

for rcode in 503 000 404; do
  new_scratch none
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  out="$(MOCK_READY_LOCAL=$rcode run_recon --once 2>"$SC/ready.err")"; rc=$?
  [[ "$(get_verdict "$out")" == "unhealthy" ]] && ok "ready noop[$rcode]: verdict unhealthy" || bad "ready noop[$rcode]: expected unhealthy, got '$(get_verdict "$out")' (out=$out)"
  [[ "$rc" -ne 0 ]] && ok "ready noop[$rcode]: exit 非 0" || bad "ready noop[$rcode]: exit 0 — 壞掉的儲存層被當成健康"
  grep -q "ALERT: readiness" "$SC/ready.err" && ok "ready noop[$rcode]: ALERT 已寫 stderr" || bad "ready noop[$rcode]: 無 ALERT"
  [[ ! -s "$COMPOSELOG" ]] && ok "ready noop[$rcode]: 不 rebuild" || bad "ready noop[$rcode]: compose 被呼叫"
done

# dry-run 不探（不產生任何對外呼叫）
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
rm -f "$SC/ready_calls"
out="$(MOCK_READY_LOCAL=503 run_recon --once --dry-run 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "noop" && "$rc" -eq 0 && ! -e "$SC/ready_calls" ]] && ok "ready dry-run: 不探 readiness" || bad "ready dry-run: verdict=$(get_verdict "$out") rc=$rc calls=$(cat "$SC/ready_calls" 2>/dev/null)"

# 1b) ff-only 與 poisoned-skip 的 tick 也要探（P1：原本只有 noop 探，其餘路徑對儲存層全盲）
for rcode in 200 503; do
  new_scratch docs
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  rm -f "$SC/ready_calls"
  out="$(MOCK_READY_LOCAL=$rcode run_recon --once 2>"$SC/ready.err")"; rc=$?
  if [[ "$rcode" == "200" ]]; then
    [[ "$(get_verdict "$out")" == "ff-only" && "$rc" -eq 0 && -s "$SC/ready_calls" ]] && ok "ready ff-only 正控: 探了 readiness 且仍 ff-only" || bad "ready ff-only 正控: verdict=$(get_verdict "$out") rc=$rc"
  else
    [[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && grep -q "ALERT: readiness 失敗" "$SC/ready.err" && ok "ready ff-only[503]: unhealthy/ALERT/exit!=0" || bad "ready ff-only[503]: verdict=$(get_verdict "$out") rc=$rc"
    grep -q "pull" "$GITLOG" && bad "ready ff-only[503]: 仍 pull 了" || ok "ready ff-only[503]: 未 pull"
  fi
done
for rcode in 200 503; do
  new_scratch backend
  printf 'poison %s %s\n' "$SHA_NEW" "$(date +%s)" > "$STATE"
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  rm -f "$SC/ready_calls"
  out="$(MOCK_READY_LOCAL=$rcode run_recon --once 2>"$SC/ready.err")"; rc=$?
  if [[ "$rcode" == "200" ]]; then
    [[ "$(get_verdict "$out")" == "poisoned-skip" && "$rc" -eq 0 && -s "$SC/ready_calls" ]] && ok "ready poisoned-skip 正控: 探了 readiness 且仍 poisoned-skip" || bad "ready poisoned-skip 正控: verdict=$(get_verdict "$out") rc=$rc"
  else
    [[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && grep -q "ALERT: readiness 失敗" "$SC/ready.err" && ok "ready poisoned-skip[503]: unhealthy/ALERT/exit!=0" || bad "ready poisoned-skip[503]: verdict=$(get_verdict "$out") rc=$rc"
  fi
done

# 2) deploy：部署前 readiness 壞 → 不部署（host state 壞，先修它）
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_LOCAL=503 run_recon --once 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 && ! -s "$COMPOSELOG" ]] && ok "ready pre-deploy: 儲存層壞 → 不 rebuild" || bad "ready pre-deploy: verdict=$(get_verdict "$out") rc=$rc compose=$(cat "$COMPOSELOG" 2>/dev/null)"

# 2b) deploy：部署前綠、部署後壞、回滾後轉綠 → 新 sha 有罪：rolled-back + poison reason=ready
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_LOCAL_SEQ="200 503 503 200" run_recon --once 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "rolled-back" && "$rc" -ne 0 ]] && ok "ready deploy-local(rollback fixes): rolled-back 非 0" || bad "ready deploy-local(rollback fixes): verdict=$(get_verdict "$out") rc=$rc"
grep -q "ROLLED_BACK .*reason=ready" "$DEPLOYLOG" && ok "ready deploy-local(rollback fixes): reason=ready" || bad "ready deploy-local: deploy.log=$(cat "$DEPLOYLOG" 2>/dev/null)"
grep -q "^poison " "$STATE" && ok "ready deploy-local(rollback fixes): sha 已 poison" || bad "ready deploy-local(rollback fixes): 未 poison"

# 2c) 回滾後仍不 ready → host state：不 poison、verdict=unhealthy、ALERT
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_LOCAL_SEQ="200 503" run_recon --once 2>"$SC/ready.err")"; rc=$?
[[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && ok "ready host-state: unhealthy 非 0" || bad "ready host-state: verdict=$(get_verdict "$out") rc=$rc"
grep -q "^poison " "$STATE" 2>/dev/null && bad "ready host-state: 不該 poison 無辜的 sha" || ok "ready host-state: 未 poison"
grep -q "host state" "$SC/ready.err" && ok "ready host-state: ALERT 指出 host state" || bad "ready host-state: 無 host state ALERT"
grep -q "host_unready=1" "$DEPLOYLOG" && ok "ready host-state: deploy.log 記錄 host_unready" || bad "ready host-state: deploy.log=$(cat "$DEPLOYLOG" 2>/dev/null)"

# 2d) 容器掛了（readiness 000）不得封死自動修復：有待部署 commit 就照部署；
#     部署前 000 → PRE_READY=0，部署後 ready 失敗不做 host-state 歸因，照常 rollback + poison。
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_LOCAL_SEQ="000 000 200" run_recon --once 2>"$SC/ready.err")"; rc=$?
[[ "$(get_verdict "$out")" == "deployed" && "$rc" -eq 0 ]] && ok "ready 000 + 待部署修復: 照常 deployed" || bad "ready 000 + 待部署修復: verdict=$(get_verdict "$out") rc=$rc"
grep -q "HTTP 000" "$SC/ready.err" && ok "ready 000: 仍發 ALERT" || bad "ready 000: 無 ALERT"
[[ -s "$COMPOSELOG" ]] && ok "ready 000: compose 有跑" || bad "ready 000: compose 沒跑 — 自動修復被封死"

new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_LOCAL_SEQ="000 000 503" run_recon --once 2>"$SC/ready.err")"; rc=$?
[[ "$(get_verdict "$out")" == "rolled-back" && "$rc" -ne 0 ]] && ok "ready 000→503: PRE_READY=0 照舊 rolled-back" || bad "ready 000→503: verdict=$(get_verdict "$out") rc=$rc"
grep -q "^poison " "$STATE" && ok "ready 000→503: 照舊 poison（不做 host-state 歸因）" || bad "ready 000→503: 未 poison"
grep -q "host_unready" "$DEPLOYLOG" 2>/dev/null && bad "ready 000→503: 不該有 host_unready" || ok "ready 000→503: 無 host_unready"

# 2e) 000 且沒有東西可部署 → 不能報健康
for kind in none docs; do
  new_scratch "$kind"
  MOCK_CURL="$(make_mock_curl "" "$SC")"
  out="$(MOCK_READY_LOCAL=000 run_recon --once 2>/dev/null)"; rc=$?
  [[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && ok "ready 000 無可部署[$kind]: unhealthy 非 0" || bad "ready 000 無可部署[$kind]: verdict=$(get_verdict "$out") rc=$rc"
done

# 3) deploy gate：外部 readiness 壞（info 200 + health 401 都綠）→ 回滾 reason=smoke
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_READY_EXTERNAL=503 run_recon --once 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "rolled-back" && "$rc" -ne 0 ]] && ok "ready deploy-external: rolled-back 非 0（info/health 都綠仍不放行）" || bad "ready deploy-external: verdict=$(get_verdict "$out") rc=$rc"
grep -q "ROLLED_BACK .*reason=smoke" "$DEPLOYLOG" && ok "ready deploy-external: reason=smoke" || bad "ready deploy-external: deploy.log=$(cat "$DEPLOYLOG" 2>/dev/null)"

# 外部 readiness 連不出去（000）而 info 也拿不到任何回應 = 主機斷網，仍走 unverified 不回滾
new_scratch backend
MOCK_CURL="$(make_mock_curl "$(cat <<EOF
wordnexus.lol/api/system/info|200|{"version":"$SHA_NEW"}
wordnexus.lol/api/health|401|{"detail":"x"}
EOF
)" "$SC" "$SERVEDFILE")"
out="$(MOCK_EXTERNAL_FAIL_FIRST=99 MOCK_READY_EXTERNAL=000 run_recon --once 2>/dev/null)"; rc=$?
[[ "$(get_verdict "$out")" == "deployed" ]] && grep -q '"smoke":"unverified"' <<<"$out" && ok "ready outage: 斷網維持 unverified 落地（不因 readiness 假回滾）" || bad "ready outage: verdict=$(get_verdict "$out") out=$out"

section "資料目錄守衛（#2921）：缺失／清空／驟降必須告警"
# 正控：健康 stub → noop 且寫基線。
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(run_recon --once 2>"$SC/dd.err")"; rc=$?
[[ "$(get_verdict "$out")" == "noop" && "$rc" -eq 0 ]] && ok "data guard 正控：健康 stub → noop" || bad "data guard 正控: verdict=$(get_verdict "$out") rc=$rc"
grep -q "ALERT" "$SC/dd.err" && bad "data guard 正控：不該有 ALERT" || ok "data guard 正控：無 ALERT"
[[ -s "$SC/backups/data_dir.baseline" ]] && ok "data guard：基線已寫入" || bad "data guard：基線未寫入"

# 1) 資料目錄不存在
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(KG_DATA_DIR_OVERRIDE="$SC/gone" run_recon --once 2>"$SC/dd.err")"; rc=$?
[[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && ok "data dir 缺失 → unhealthy 非 0" || bad "data dir 缺失: verdict=$(get_verdict "$out") rc=$rc"
grep -q "ALERT: 資料目錄不存在" "$SC/dd.err" && ok "data dir 缺失 → ALERT" || bad "data dir 缺失: 無 ALERT ($(cat "$SC/dd.err"))"

# 2) users/ 子目錄數 0
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
mkdir -p "$SC/empty/users"
out="$(KG_DATA_DIR_OVERRIDE="$SC/empty" run_recon --once 2>"$SC/dd.err")"; rc=$?
[[ "$(get_verdict "$out")" == "unhealthy" && "$rc" -ne 0 ]] && ok "users/ 為空 → unhealthy 非 0" || bad "users/ 為空: verdict=$(get_verdict "$out") rc=$rc"
grep -q "ALERT: .*沒有任何用戶子目錄" "$SC/dd.err" && ok "users/ 為空 → ALERT" || bad "users/ 為空: 無 ALERT"

# 3) 用戶數驟降（基線 10 → 現 1）：只告警，不 gate
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
mkdir -p "$SC/backups"; printf '1 10\n' > "$SC/backups/data_dir.baseline"
out="$(run_recon --once 2>"$SC/dd.err")"; rc=$?
grep -q "ALERT: 用戶目錄數驟降" "$SC/dd.err" && ok "用戶數驟降 → ALERT" || bad "用戶數驟降: 無 ALERT ($(cat "$SC/dd.err"))"
[[ "$(get_verdict "$out")" == "noop" && "$rc" -eq 0 ]] && ok "用戶數驟降：不 gate（noop）" || bad "用戶數驟降: verdict=$(get_verdict "$out") rc=$rc"
[[ "$(cat "$SC/backups/data_dir.baseline")" == "1 10" ]] && ok "驟降時基線不被覆寫" || bad "驟降時基線被覆寫"

# 4) 容量驟降（基線 5000MB → 現 <1MB）
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
mkdir -p "$SC/backups"; printf '5000 1\n' > "$SC/backups/data_dir.baseline"
run_recon --once >/dev/null 2>"$SC/dd.err"
grep -q "ALERT: 資料目錄容量驟降" "$SC/dd.err" && ok "容量驟降 → ALERT" || bad "容量驟降: 無 ALERT ($(cat "$SC/dd.err"))"

# 5) 關閉開關
new_scratch none
MOCK_CURL="$(make_mock_curl "" "$SC")"
out="$(KG_RECON_DATA_GUARD=0 KG_DATA_DIR_OVERRIDE="$SC/gone" run_recon --once 2>/dev/null)"
[[ "$(get_verdict "$out")" == "noop" ]] && ok "KG_RECON_DATA_GUARD=0 → 不檢查" || bad "guard=0: verdict=$(get_verdict "$out")"

echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ "$fail" -eq 0 ]]
