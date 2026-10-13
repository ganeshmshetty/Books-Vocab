#!/bin/bash
# 離線測試 ios_device_files.sh 的命令組裝（--dry-run，不碰真機）。
# 釘住 devicectl 的旗標不一致事實：info files 用 --username、copy from 用 --user。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/ops/ios_device_files.sh"
FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }

[ -x "$TOOL" ] || { echo "FAIL: tool 不存在或不可執行"; exit 1; }

# list → info files + --username
OUT=$("$TOOL" list --device FAKE-1111 --dry-run --sub Documents)
grep -q "device info files" <<< "$OUT" || fail "list 未走 info files"
grep -q -- "--username mobile" <<< "$OUT" || fail "list 未用 --username（devicectl info files 的旗標）"
grep -q -- "--subdirectory Documents" <<< "$OUT" || fail "list 未帶 --subdirectory"
grep -q -- "--device FAKE-1111" <<< "$OUT" || fail "list 未帶指定裝置"

# pull → copy from + --user
OUT=$("$TOOL" pull "Documents/x.bin" /tmp/x.bin --device FAKE-1111 --dry-run)
grep -q "device copy from" <<< "$OUT" || fail "pull 未走 copy from"
grep -q -- "--user mobile" <<< "$OUT" || fail "pull 未用 --user（devicectl copy from 的旗標）"
grep -q -- "--source Documents/x.bin" <<< "$OUT" || fail "pull 未帶 source"

# pull-store → 兩 store × 三件套 = 6 條 copy 命令
OUT=$("$TOOL" pull-store --device FAKE-1111 --dry-run --out /tmp/kg_dft_test)
CNT=$(echo "$OUT" | grep -c "device copy from")
[ "$CNT" -eq 6 ] || fail "pull-store 應發 6 條 copy（CloudStore+LocalStore 三件套），實際 $CNT"
grep -q "CloudStore.store-wal" <<< "$OUT" || fail "pull-store 缺 wal"

# 自訂 bundle id 透傳
OUT=$("$TOOL" list --device FAKE-1111 --app com.example.other --dry-run)
grep -q -- "--domain-identifier com.example.other" <<< "$OUT" || fail "--app 未透傳"

# --simulator：list → simctl get_app_container 解析容器 + ls
OUT=$("$TOOL" list --simulator --device FAKE-SIM --dry-run --sub Documents)
grep -q "simctl get_app_container FAKE-SIM com.Max0228.BooksBrowser data" <<< "$OUT" || fail "sim list 未走 get_app_container"
grep -q "ls .*<container>/Documents" <<< "$OUT" || fail "sim list 未列容器子目錄"
grep -q "devicectl" <<< "$OUT" && fail "sim 模式不應碰 devicectl"

# --simulator 預設 device = booted
OUT=$("$TOOL" list --simulator --dry-run)
grep -q "get_app_container booted" <<< "$OUT" || fail "sim 模式未預設 booted"

# --simulator pull → cp 容器內檔案
OUT=$("$TOOL" pull "Documents/x.bin" /tmp/x.bin --simulator --device FAKE-SIM --dry-run)
grep -q "cp .*<container>/Documents/x.bin /tmp/x.bin" <<< "$OUT" || fail "sim pull 未走 cp"

# --simulator pull-store → 兩 store × 三件套 = 6 條 cp
OUT=$("$TOOL" pull-store --simulator --device FAKE-SIM --dry-run --out /tmp/kg_dft_sim_test)
CNT=$(echo "$OUT" | grep -c "DRY-RUN: cp ")
[ "$CNT" -eq 6 ] || fail "sim pull-store 應發 6 條 cp，實際 $CNT"
grep -q "CloudStore.store-wal" <<< "$OUT" || fail "sim pull-store 缺 wal"

# 未知子命令 → usage + 非零
if "$TOOL" frobnicate >/dev/null 2>&1; then fail "未知子命令應非零退出"; fi

if [ "$FAIL" -eq 0 ]; then echo "PASS: ios_device_files 全部斷言通過"; else exit 1; fi
