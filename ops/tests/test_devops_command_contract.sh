#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/devops.sh"
SAFE="$ROOT/ops/devops_kg_safe.sh"
REGISTRY="$ROOT/ops/lib/devops_command_registry.sh"
COMMANDS="$ROOT/ops/lib/devops_commands.sh"
ENV_DRIFT="$ROOT/ops/env_drift.py"
# P0 2026-10-09: self-hermetic — safe to run standalone, not only via ops/test_ops.sh.
# shellcheck source=../lib/hermetic_ops_test.sh
source "$ROOT/ops/lib/hermetic_ops_test.sh"; hermetic_ops_test_init "$ROOT"

pass() { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

[[ -x "$BASE" ]] || fail "base entrypoint is not executable"
[[ -x "$SAFE" ]] || fail "safe entrypoint is not executable"
[[ -x "$ENV_DRIFT" ]] || fail "env_drift.py is not executable"
[[ -x "$ROOT/ops/tests/test_devops_command_contract.sh" ]] || fail "contract test is not executable"

# Both entrypoints must consume the same side-effect-free registry.
grep -Fq 'ops/lib/devops_command_registry.sh' "$BASE" \
  || fail "base entrypoint does not source the command registry"
grep -Fq 'ops/lib/devops_command_registry.sh' "$SAFE" \
  || fail "safe entrypoint does not source the command registry"
grep -Fq 'ops/lib/devops_commands.sh' "$BASE" \
  || fail "base entrypoint does not source dispatch helpers"
grep -Fq 'devops_command_registry_validate' "$BASE" \
  || fail "base entrypoint does not validate the registry"
grep -Fq 'devops_command_registry_validate' "$SAFE" \
  || fail "safe entrypoint does not validate the registry"
grep -Fq 'devops_command_blocked "$sub"' "$SAFE" \
  || fail "safe entrypoint does not consume registry blocked policy"
pass "base and safe entrypoints share a validated command registry"

# Source-only loading is the supported test seam: it defines handlers without
# dispatching a remote command or running the default help path.
source_probe="$(ROOT="$ROOT" DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true \
  bash -c 'source "$ROOT/devops.sh"; declare -F cmd_env_drift; declare -F cmd_help; declare -F devops_dispatch_command; declare -f cmd_env_drift' \
  2>/dev/null)" || fail "base source-only load failed"
grep -Fq 'cmd_env_drift' <<<"$source_probe" \
  || fail "source-only load did not define cmd_env_drift"
grep -Fq 'cmd_help' <<<"$source_probe" \
  || fail "source-only load did not define cmd_help"
grep -Fq 'devops_dispatch_command' <<<"$source_probe" \
  || fail "source-only load did not define dispatch helper"
grep -Fq 'ops/env_drift.py' <<<"$source_probe" \
  || fail "cmd_env_drift does not delegate to env_drift.py"
if grep -Eq '^cmd_env_drift\(\)|^cmd_.*\(\)' <<<"$source_probe" \
   && awk '/^cmd_env_drift\(\)/,/^}/' "$BASE" | grep -Eq 'python3|<<'; then
  fail "cmd_env_drift still embeds python3/heredoc implementation"
fi
grep -Fq 'devops_dispatch_command "${1:-help}"' "$BASE" \
  || fail "base entrypoint does not dispatch through shared helper"
grep -Fq 'DEVOPS_SOURCE_ONLY' "$BASE" \
  || fail "base entrypoint lacks source-only guard"
pass "source-only loading exposes handlers without dispatch side effects"

help_output="$(KG_SSH_CMD=/usr/bin/true "$BASE" --help 2>/dev/null)" \
  || fail "base help command failed"
grep -Fq 'env-drift' <<<"$help_output" \
  || fail "base help is not generated from registry"
grep -Fq 'ops-edit-batch' <<<"$help_output" \
  || fail "base help omitted a registered command"
pass "base help renders the registry without transport"

# Registry API must expose the commands that are actually supported by the two
# surfaces.  This is intentionally offline and does not require SSH or Docker.
registry_probe="$(ROOT="$ROOT" bash -c 'source "$ROOT/ops/lib/devops_command_registry.sh"; devops_command_registry_validate; for c in env-drift ops-cli container-script; do devops_command_registered "$c"; done; for c in preflight env-drift docker-logs; do devops_safe_command_registered "$c"; done; devops_command_blocked setup; devops_command_help_lines' 2>/dev/null)" \
  || fail "registry API validation failed"
grep -Fq 'env-drift' <<<"$registry_probe" || fail "registry help omits env-drift"
pass "registry validates base/safe/blocked command membership"

safe_usage_output="$(KG_DEVOPS_BASE=/usr/bin/true "$SAFE" __unknown__ 2>&1 || true)"
safe_rows="$(ROOT="$ROOT" bash -c 'source "$ROOT/ops/lib/devops_command_registry.sh"; for c in "${DEVOPS_SAFE_COMMANDS[@]}"; do devops_command_help_row "$c"; done')"
while IFS='|' read -r display _description; do
  [[ -z "$display" ]] && continue
  grep -Fq "$display" <<<"$safe_usage_output" \
    || fail "safe usage omitted registry command: $display"
done <<<"$safe_rows"
pass "safe usage renders every registry command"

# Exercise the extracted env checker entirely offline.  The SSH seam returns a
# fixture; no network-capable command is allowed in this test.
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/certs" "$tmp/bin"
tmp_real="$(cd "$tmp" && pwd -P)"
cat > "$tmp/local.env" <<EOF
TOKEN=stable
APP_STORE_ROOT_CA_PATH=$tmp_real/certs/root.pem
EOF
cat > "$tmp/remote.env" <<'EOF'
TOKEN=stable
APP_STORE_ROOT_CA_PATH=/app/certs/root.pem
EOF
cat > "$tmp/bin/ssh-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${ENV_DRIFT_REMOTE_FIXTURE:?}"
EOF
chmod +x "$tmp/bin/ssh-stub"

ENV_DRIFT_REMOTE_FIXTURE="$tmp/remote.env" KG_SSH_BIN="$tmp/bin/ssh-stub" \
  uv run --no-project --python 3.13 "$ENV_DRIFT" \
    "$tmp/local.env" "$tmp/remote.env" "$tmp" "/app" test-server \
    >"$tmp/match.out" 2>"$tmp/match.err" \
  || fail "env_drift.py rejected matching offline fixtures"
grep -Fq '已一致' "$tmp/match.out" || fail "matching env fixture did not report green"
pass "env_drift.py compares matching local/remote fixtures offline"

sed 's/TOKEN=stable/TOKEN=drift/' "$tmp/remote.env" > "$tmp/remote-mismatch.env"
set +e
ENV_DRIFT_REMOTE_FIXTURE="$tmp/remote-mismatch.env" KG_SSH_BIN="$tmp/bin/ssh-stub" \
  uv run --no-project --python 3.13 "$ENV_DRIFT" \
    "$tmp/local.env" "$tmp/remote-mismatch.env" "$tmp" "/app" test-server \
    >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"
rc=$?
set -e
(( rc == 1 )) || fail "env_drift.py mismatch exit=$rc (expected 1)"
grep -Fq '值不同' "$tmp/mismatch.out" || fail "mismatch fixture omitted named difference"
pass "env_drift.py returns typed non-zero on mismatch"

grep -Fq 'uv run' <(head -1 "$ENV_DRIFT") || fail "env_drift.py lacks uv-managed shebang"
if grep -Eq 'python3|python -c|<<' <(awk 'NR > 1' "$ENV_DRIFT"); then
  fail "env_drift.py contains an embedded interpreter/heredoc"
fi
pass "env_drift.py keeps interpreter ownership explicit"

printf 'contract: all checks passed\n'
