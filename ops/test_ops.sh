#!/usr/bin/env bash
# test_ops.sh — aggregate ops regression tests.
#
# Usage:
#   ./ops/test_ops.sh          # run the full ops suite (incl. ASC offline tests)
#   ./ops/test_ops.sh --list   # list available test groups
#   ./ops/test_ops.sh release backup-verify
#   ./ops/test_ops.sh asc      # run App Store Connect offline surface tests

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# P0 2026-10-09 (docs/runbook/incidents/2026-10-09-kg-data-deleted-by-test.md):
# every ops test runs hermetic.  KG_OPS_TEST=1, a PATH shim whose
# ssh/scp/sftp/rsync/aws exit 97, and deny-stub transport seams are set here, before
# any group starts, so a test that forgets its own stub fails loudly instead of
# reaching production.  A test that needs a fake installs its own stub earlier in PATH.
# shellcheck source=lib/hermetic_ops_test.sh
source "$ROOT/ops/lib/hermetic_ops_test.sh"
hermetic_ops_test_init "$ROOT"
: > "$KG_OPS_TEST_TRIPWIRE_LOG"

UV_BIN="${UV_BIN:-}"
if [[ -z "$UV_BIN" ]]; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    UV_BIN="$HOME/.local/bin/uv"
  else
    UV_BIN="uv"
  fi
fi

DEFAULT_TESTS=(
  release
  ios-release
  backup-verify
  devops
  deploy-smoke
  infra-health
  disk-guard
  reconcile
  sentry-release
  branch-audit
  exit-code-contract
  worktree
  delivery-control
  capability-matrix
  context-routing
  doctor
  ui-deadcode
  ui-graph
  log-assert
  python-entrypoints
  ui-token
  plain-deadzone
  tap-a11y
  lint-baselines
  injection-lint
  ui-fixture-lint
  ops-ci-coverage
  github-workflows
  ui-quality-plane
  ui-quality-gate
  review-card-golden
  docs-lint
  gen-ios-baseline
  ios-signal-traps
  sim-pool-disposable
  ios-install-provenance
  sentry-tool
  ios-ops
  ios-sentry-wiring
  ios-run-verdict
  ios-device-lock
  ios-cache-evict
  review-probe
  review-flip-probe
  lldb-forensics
  ios-device-files
  ios-device-logs
  ios-test-discovery
  userland-portability
  script-help
  install-hooks
  lib-sourcing
  heavy-slots
  podcast-ops
  # ── IMP-20260805-947062：以下 4 個 group 收編原本對每個 group 都不可達的 19 支
  #    測試檔。反向覆蓋由 ops/tests/test_ops_ci_coverage.sh 的
  #    「every tracked test file is reachable from some group」把關——新增測試檔
  #    卻忘了註冊，那段會指名它並回非零。
  streaming-command
  app-review
  demo-data
  catalog-agent
  uitest-contact-sheet
  # Issue #2065：以下 group 收編 full reachability scan 找到的未路由測試檔。
  worktree-extended
  ios-ui-review
  review-preflight
  # Issue #2064：lab/podcast 單元測試（pipeline／publish／synthesize／saga／monitor）。
  lab-podcast
  # Issue #2764: asc 離線測試原僅在 OPTIONAL，無 workflow 跑它；納入預設與 CI。
  asc
)

# Host-wide slot limiter (ops/lib/heavy_slots.sh): only these groups claim a slot
# (KG_HEAVY_SLOTS, default 3). Everything else runs unthrottled.
HEAVY_TESTS=(
  worktree
  delivery-control
  docs-lint
  disk-guard
  doctor
)
# shellcheck source=lib/heavy_slots.sh
source "$ROOT/ops/lib/heavy_slots.sh"

OPTIONAL_TESTS=(
  release-surfaces
)

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

list_tests() {
  printf '%s\n' "${DEFAULT_TESTS[@]}"
  printf '%s (optional)\n' "${OPTIONAL_TESTS[@]}"
}

run_one() {
  case "$1" in
    release)            ./ops/test_release.sh ;;
    ios-release)
      ./ops/test_ios_release.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_asc_shipped.py
      ;;
    backup-verify)
      ./ops/tests/test_backup_verify.sh &&
      ./ops/tests/test_kg_backup.sh
      ;;
    devops)
      ./ops/test_devops.sh &&
      ./ops/tests/test_devops_command_contract.sh &&
      # P0 2026-10-09：ops 測試不得觸及 production（transport tripwire + hermetic lint）。
      ./ops/tests/test_devops_transport_tripwire.sh &&
      ./ops/tests/test_ops_hermetic_lint.sh &&
      ./ops/tests/test_devops_backup_cleanup.sh &&
      ./ops/tests/test_backup_status.sh &&
      # IMP-20260805-947062：devops_kg_safe.sh 的 transport retarget 契約測試，
      # 主體與 test_devops.sh 同源（都測 wrapper），先前不屬於任何 group。
      ./ops/tests/test_devops_safe_lightsail_guard.sh &&
      # Issue #2327：成本文件引用的 ops-cli 子命令／旗標必須真實存在，
      # 與 devops command contract 同屬「文件宣稱的命令 vs 實作」守衛。
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_env_drift.py \
        ops/tests/test_env_check.py \
        ops/tests/test_env_check_backend_rules.py \
        ops/tests/test_cost_docs_commands.py &&
      "$UV_BIN" run --project backend python -m pytest -q ops/tests/test_ops_edit_batch.py
      ;;
    deploy-smoke)       ./ops/tests/test_deploy_smoke.sh ;;
    infra-health)       ./ops/test_infra_health.sh ;;
    disk-guard)
      ./ops/tests/test_kg_disk_guard.sh &&
      ./ops/tests/test_ios_disk_budget.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_disk_usage.py
      ;;
    reconcile)          ./ops/tests/test_kg_reconcile.sh ;;
    sentry-release)     ./ops/tests/test_sentry_release.sh ;;
    branch-audit)       ./ops/tests/test_branch_audit.sh ;;
    exit-code-contract)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_exit_code_contract.py
      ;;
    worktree)
      "$UV_BIN" run --no-project --python 3.13 \
        "$ROOT/ops/run_serial_test_group.py" \
        --repo-root "$ROOT" --lock-name worktree -- \
        "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_worktree_registry.py \
        ops/tests/test_worktree_registry_admission.py \
        ops/tests/test_worktree_registry_handback.py \
        ops/tests/test_worktree_registry_lifecycle.py \
        ops/tests/test_worktree_registry_maintenance.py \
        ops/tests/test_worktree_orchestrate.py \
        ops/tests/test_worktree_closed_pr_disposition.py \
        ops/tests/test_worktree_recovery_lifecycle.py \
        ops/tests/test_worktree_scope.py \
        ops/tests/test_worktree_shared_scope.py \
        ops/tests/test_task_registry.py \
        ops/tests/test_lock_wait.py \
        ops/tests/test_test_execution_lock.py
      ;;
    delivery-control)
      delivery_tests=(ops/tests/test_delivery_*.py)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_canonical_json.py \
        "${delivery_tests[@]}" &&
      ./ops/tests/test_pr_readiness_workflow.sh
      ;;
    capability-matrix)
      "$UV_BIN" run --python 3.13 --with pytest --with 'cryptography>=48,<49' pytest -q \
        ops/tests/test_capability_matrix.py \
        ops/tests/test_compute_cli.py \
        ops/tests/test_compute_contract.py \
        ops/tests/test_compute_executor.py \
        ops/tests/test_compute_gate_adapter.py \
        ops/tests/test_compute_history.py \
        ops/tests/test_compute_hosts.py \
        ops/tests/test_compute_receipt.py \
        ops/tests/test_compute_router.py \
        ops/tests/test_felix_compute_launcher.py \
        ops/tests/test_xmachine_transport.py
      ;;
    doctor)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_doctor.py \
        ops/tests/test_pr_timeline.py \
        ops/tests/test_release_report.py \
        ops/tests/test_release_train.py \
        ops/tests/test_complexity.py \
        ops/tests/test_doctor_issue.py \
        ops/tests/test_main_watch.py \
        ops/tests/test_delivery_metrics.py \
        ops/tests/test_launchd_manifests.py
      ;;
    context-routing)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_context_route.py \
        ops/tests/test_skill_route.py \
        ops/tests/test_agent_onboard.py &&
      ./ops/context_route.py validate --json >/dev/null &&
      ./ops/skill_route.py validate --json >/dev/null &&
      ./ops/agent_onboard.py \
        --identity Worker --intent delivery --entry direct-assignment \
        --evidence '{"User/IM assignment":"context-routing","acceptance":"green","structured Scope":"ops/ tests","dispatch_channel":"im","dispatch_owner":"IM-1"}' \
        --json >/dev/null
      ;;
    ui-deadcode)
      "$UV_BIN" run --python 3.13 --with pytest pytest -q ops/tests/test_ui_deadcode.py &&
      ./ops/tests/test_ui_deadcode.sh
      ;;
    ui-graph)
      "$UV_BIN" run --python 3.13 --with pytest pytest -q \
        ops/tests/test_ui_graph.py ops/tests/test_ui_graph_contract.py &&
      ./ops/tests/test_ui_graph.sh
      ;;
    log-assert)
      "$UV_BIN" run --python 3.13 --with pytest pytest -q ops/tests/test_ios_log_assert.py
      ;;
    python-entrypoints)
      ./ops/tests/test_python_entrypoints.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_venv_health.py
      ;;
    ui-token)           ./ops/test_ui_token_lint.sh ;;
    plain-deadzone)     ./ops/test_plain_deadzone_lint.sh ;;
    tap-a11y)           ./ops/test_tap_a11y_lint.sh ;;
    lint-baselines)     ./ops/tests/test_lint_baselines.sh && ./ops/tests/test_i18n_lint.sh ;;
    injection-lint)     ./ops/tests/test_injection_lint.sh ;;
    ui-fixture-lint)    ./ops/tests/test_ui_fixture_lint.sh ;;
    ops-ci-coverage)
      ./ops/tests/test_ops_ci_coverage.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_ci_expected_fail_exclusions.py \
        ops/tests/test_ops_group_chain.py
      ;;
    github-workflows)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_agent_review_contract.py &&
      ./ops/tests/test_github_workflows.sh &&
      ./ops/tests/test_ops_suite_bootstrap.sh &&
      ./ops/tests/test_ci_scope_router.sh &&
      ./ops/tests/test_ci_macos_queue_probe.sh &&
      ./ops/tests/test_ci_confidence_verdict.sh &&
      ./ops/tests/test_ci_apt_install.sh
      ;;
    ui-quality-plane)   ./ops/tests/test_ui_quality_plane.sh ;;
    ui-quality-gate)    ./ops/tests/test_ui_quality_gate.sh ;;
    review-card-golden) ./ops/tests/test_review_card_layout_golden.sh ;;
    docs-lint)
      ./ops/tests/test_docs_impact.sh &&
      ./ops/tests/test_docs_registry_coverage.sh &&
      ./ops/tests/test_docs_lint.sh &&
      ./ops/tests/test_docs_lint_generated_check.sh &&
      ./ops/tests/test_docs_lint_generated_diff.sh &&
      ./ops/tests/test_docs_lint_source_existence.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_context_route.py
      ;;
    gen-ios-baseline)
      ./ops/tests/test_gen_ios_baseline.sh &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_swift_decl_count.py
      ;;
    ios-signal-traps)
      ./ops/tests/test_ios_signal_traps.sh
      ;;
    sim-pool-disposable)
      ./ops/tests/test_ios_ops_sim_pool_disposable.sh
      ;;
    ios-install-provenance)
      ./ops/tests/test_ios_install_provenance.sh
      ;;
    sentry-tool)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_sentry_contract.py \
        ops/tests/test_sentry_tool.py
      ;;
    ios-ops)
      ./ops/test_ios_ops.sh &&
      ./ops/tests/test_ios_ops_release_heartbeat.sh &&
      ./ops/tests/test_ios_xctestrun_cache.sh &&
      ./ops/tests/test_ios_ui_test_package_dependencies.sh &&
      "$UV_BIN" run --project backend python -m pytest -q \
        ops/tests/test_ios_diagnostics.py \
        ops/tests/test_ios_coverage.py &&
      ./ops/tests/test_ios_build_covers_test_targets.sh
      ;;
    ios-sentry-wiring)
      ./ops/tests/test_sentry_wiring.sh &&
      KG_IOS_SENTRY_BUILD_LOCK_TIMEOUT=0 ./ops/test_ios_ops.sh --section 'Sentry wiring surface'
      ;;
    ios-run-verdict)    ./ops/tests/test_ios_run_verdict.sh ;;
    ios-device-lock)    ./ops/tests/test_ios_device_lock_verdict.sh ;;
    ios-cache-evict)
      ./ops/tests/test_ios_cache_evict.sh &&
      ./ops/tests/test_ios_test_cache_root.sh &&
      ./ops/tests/test_ios_build_cache_lifecycle.sh &&
      ./ops/tests/test_ios_disk_budget.sh
      ;;
    review-probe)       ./ops/tests/test_review_probe.sh ;;
    review-flip-probe)
      "$UV_BIN" run --python 3.13 --with pytest pytest -q ops/tests/test_review_flip_probe_report.py
      ;;
    # 真 lldb 那支必須排第一：ops-ci-coverage 的證偽器靠「遮蔽 xcrun → 這個 group 必死」
    # 認定它的 bin-xcode 相依，而 timeout 守衛用假 lldb、遮蔽 xcrun 也照樣綠。
    lldb-forensics)
      ./ops/tests/test_lldb_crash_forensics.sh &&
      ./ops/tests/test_lldb_forensics_timeout.sh
      ;;
    ios-device-files)   ./ops/tests/test_ios_device_files.sh ;;
    ios-device-logs)    ./ops/tests/test_ios_device_logs.sh ;;
    ios-test-discovery) ./ops/test_ios_test_discovery.sh ;;
    userland-portability) ./ops/tests/test_userland_portability.sh ;;
    script-help)        ./ops/tests/test_script_help.sh ;;
    install-hooks)      ./ops/tests/test_install_hooks.sh ;;
    lib-sourcing)       ./ops/tests/test_lib_sourcing.sh ;;
    heavy-slots)        ./ops/tests/test_heavy_slots.sh ;;
    podcast-ops)
      "$UV_BIN" run --python 3.13 --with pytest pytest -q \
        ops/test_podcast_ops.py \
        ops/tests/test_podcast_backfill_disk.py \
        ops/tests/test_podcast_cover_publish.py \
        ops/tests/test_podcast_preview_backfill.py \
        ops/tests/test_podcast_publish_skill.py \
        ops/tests/test_podcast_upload.py
      ;;
    # ── shared offline ops groups ───────────────────────────────────────────
    streaming-command)
      # 鐵律 5 heartbeat 契約唯一的 [machine] 守衛，先前從不執行。
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_streaming_command.py
      ;;
    app-review)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_app_review_evidence.py \
        ops/tests/test_app_review_gate.py \
        ops/tests/test_app_review_evaluators.py \
        ops/tests/test_asc_reviewer_mirror.py \
        ops/tests/test_provenance.py \
        ops/tests/test_reviewer_evidence.py \
        ops/tests/test_app_review_test_topology.py
      ;;
    demo-data)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_demo_backend_emitter.py \
        ops/tests/test_demo_ios_emitter.py \
        ops/tests/test_shape_history.py \
        ops/tests/test_apply_curation.py \
        ops/tests/test_ui_world_manifest.py \
        ops/tests/test_ui_world_test_topology.py \
        ops/tests/test_settings_sync_fixture_contract.py \
        ops/tests/test_p9_review_calendar_contract.py \
        ops/tests/test_p9_review_calendar_evidence.py \
        ops/tests/test_uitest_flow_matrix.py \
        ops/tests/test_uitest_review_page.py \
        ops/tests/test_uitest_evidence_contract.py \
        ops/tests/test_uitest_manifest_normalize.py \
        ops/tests/test_png_integrity.py \
        ops/tests/test_uitest_review_attest.py \
        && KG_REQUIRE_BACKEND_E2E=1 "$UV_BIN" run --project backend python -m pytest -q \
          ops/tests/test_demo_ios_spec_emitter.py
      ;;
    catalog-agent)
      ./ops/tests/test_catalog_agent_boundary.sh \
        ops/tests/test_catalog_agent_boundary.py
      ;;
    uitest-contact-sheet)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_uitest_contact_sheet.py
      ;;
    # Coordinator recovery/reanchor contracts.  Kept out of `worktree` because
    # that group runs inside the 3-minute required repo gate (pr-gate.yml) and
    # these add over a minute; same serial lock, so the two never interleave.
    worktree-extended)
      "$UV_BIN" run --no-project --python 3.13 \
        "$ROOT/ops/run_serial_test_group.py" \
        --repo-root "$ROOT" --lock-name worktree -- \
        "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_worktree_abandoned_recovery.py \
        ops/tests/test_worktree_published_remote_recovery.py \
        ops/tests/test_worktree_reanchor_same_path.py \
        ops/tests/test_worktree_registry_operation_lock.py \
        ops/tests/test_worktree_registry_published_base.py \
        ops/tests/test_worktree_resume_cleanup_pending.py \
        ops/tests/test_worktree_resume_maintenance.py \
        ops/tests/test_task_registry_process_identity.py
      ;;
    ios-ui-review)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_ios_ui_review_clusters.py \
        ops/tests/test_ios_ui_review_matrix.py \
        ops/tests/test_ios_ui_review_matrix_batch.py \
        ops/tests/test_ios_ui_run_many.py &&
      ./.claude/skills/ios-simulator-verification/scripts/test_run_ui_evidence.sh
      ;;
    review-preflight)
      "$UV_BIN" run --no-project --python 3.13 --with pytest pytest -q \
        ops/tests/test_review_preflight.py
      ;;
    # lab/podcast has no venv or conftest (PEP 723 per-file deps), so the union of
    # those deps is pinned here.  Two pytest runs: monitor/ and the top level both
    # put their own directory on sys.path and share module names.  The live
    # smoke scripts (smoke_tts.py, voices_ab.py, ab_perf_frame.py) are not
    # test_-prefixed, hence never collected; nothing here needs an API key,
    # network or ffmpeg (all 37 files green on first run, none excluded).
    lab-podcast)
      "$UV_BIN" run --no-project --python 3.13 --with pytest \
        --with google-genai --with python-dotenv --with pydub --with audioop-lts \
        --with pillow --with ebooklib --with beautifulsoup4 --with lxml --with boto3 \
        pytest -q -p no:cacheprovider lab/podcast/test_*.py &&
      "$UV_BIN" run --no-project --python 3.13 --with pytest \
        --with fastapi --with 'uvicorn[standard]' --with python-multipart --with httpx \
        pytest -q -p no:cacheprovider lab/podcast/monitor/test_*.py
      ;;
    asc)
      ./ops/test_asc.sh &&
      "$UV_BIN" run --python 3.13 --with pytest --with pyjwt --with cryptography pytest -q \
        ops/tests/test_asc_text_bundle.py \
        ops/tests/test_asc_build.py
      ;;
    release-surfaces)
      run_one release &&
      run_one ios-release &&
      run_one asc
      ;;
    *) return 64 ;;
  esac
}

selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      list_tests
      exit 0
      ;;
    -*)
      echo "✗ unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      selected+=("$1")
      shift
      ;;
  esac
done

if [[ "${#selected[@]}" -eq 0 ]]; then
  selected=("${DEFAULT_TESTS[@]}")
fi

passed=0
failed=0
failed_names=()
inconclusive=0
inconclusive_names=()
start_all=$SECONDS

for name in "${selected[@]}"; do
  echo ""
  echo "════════ $name ════════"
  start=$SECONDS
  set +e
  heavy_slots_run "$name" run_one "$name"
  rc=$?
  set -e
  elapsed=$((SECONDS - start))
  if [[ "$rc" -eq 0 ]]; then
    echo "✓ $name passed (${elapsed}s)"
    passed=$((passed + 1))
  elif [[ "$rc" -eq 75 ]]; then
    echo "? $name inconclusive rc=75 (${elapsed}s)" >&2
    inconclusive=$((inconclusive + 1))
    inconclusive_names+=("$name")
  elif [[ "$rc" -eq 64 ]]; then
    echo "✗ unknown test group: $name" >&2
    failed=$((failed + 1))
    failed_names+=("$name")
  else
    echo "✗ $name failed rc=$rc (${elapsed}s)" >&2
    failed=$((failed + 1))
    failed_names+=("$name")
  fi
done

# A shim denial or a devops.sh tripwire anywhere in the run is a failure even if the test
# that triggered it swallowed the exit status (`|| true`, `$(...)`, `2>/dev/null`): it means
# some test tried to reach the network / production.  Never PASS over that.
if [[ -s "$KG_OPS_TEST_TRIPWIRE_LOG" ]]; then
  echo "" >&2
  echo "✗ hermetic harness: a test attempted real network/production access:" >&2
  sed 's/^/    /' "$KG_OPS_TEST_TRIPWIRE_LOG" >&2
  failed=$((failed + 1))
  failed_names+=("hermetic-tripwire")
fi

echo ""
echo "════════ summary ════════"
echo "passed groups: $passed"
echo "failed groups: $failed"
echo "inconclusive groups: $inconclusive"
echo "elapsed: $((SECONDS - start_all))s"
if [[ "$failed" -gt 0 ]]; then
  printf 'failed: %s\n' "${failed_names[*]}" >&2
  exit 1
fi
if [[ "$inconclusive" -gt 0 ]]; then
  printf 'inconclusive: %s\n' "${inconclusive_names[*]}" >&2
  exit 75
fi
