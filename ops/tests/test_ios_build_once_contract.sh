#!/usr/bin/env bash
# test_ios_build_once_contract.sh — #3331: a merge-group iOS run compiles once.
#
# With tests on, ios-build-for-testing runs build-for-testing a single time and
# uploads only what test-without-building reads (the .xctestrun and Build/Products).
# ios-tests (unit, ui-smoke) and ios-targeted download those products and never
# compile. The PR path (run_tests=false) keeps its compile-only ios-build check.
#
# The workflow checks parse YAML. The ios_test.sh checks stop before any simulator,
# lock or xcodebuild call, so this file is hermetic.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

failures=0
fail() {
  printf '✗ %s\n' "$1" >&2
  failures=$((failures + 1))
}

IOS=".github/workflows/ios-quality.yml"
IOS_TEST="ops/ios_test.sh"
# `uses:` as YAML parses it: the SHA pin without the trailing version comment.
PIN_DOWNLOAD='actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131'
PIN_UPLOAD='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
GUARD_STEP='Require build-once test products'

tmp="$(mktemp -d "$ROOT/.cache/test-ios-build-once-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- 1. Workflow topology (parsed YAML) -------------------------------------
cat >"$tmp/topology.rb" <<'RUBY'
require "yaml"

wf = YAML.load_file(ARGV[0]) || {}
jobs = wf["jobs"] || {}
out = []

def steps(job)
  Array((job || {})["steps"])
end

def needs_of(job)
  Array((job || {})["needs"])
end

def run_text(job)
  steps(job).map { |s| s["run"].to_s }.join("\n")
end

def step_by_uses(job, prefix)
  steps(job).find { |s| s["uses"].to_s.start_with?(prefix) }
end

bft = jobs["ios-build-for-testing"]
if bft.nil?
  out << "ios-build-for-testing job is missing: tests-on runs compile once per test leg"
else
  out << "ios-build-for-testing must need plan only" unless needs_of(bft) == ["plan"]
  out << "ios-build-for-testing must run only with tests on (PR stays compile-only)" unless bft["if"].to_s.include?("inputs.run_tests != 'false'")
  out << "ios-build-for-testing timeout must be 20 minutes" unless bft["timeout-minutes"] == 20
  out << "ios-build-for-testing must prepare products with ios_ops.sh test --prepare-cache" unless run_text(bft).include?("ios_ops.sh test --prepare-cache")
  out << "ios-build-for-testing must not run tests (no test-without-building)" if run_text(bft).include?("test-without-building")
  upload = steps(bft).find { |s| s["name"] == "Upload test products" }
  if upload.nil?
    out << "ios-build-for-testing uploads no test products"
  else
    with = upload["with"] || {}
    out << "ios-build-for-testing upload is not pinned to upload-artifact v7" unless upload["uses"] == ENV["PIN_UPLOAD"]
    # Keyed by run_id only: a "Re-run failed jobs" attempt 2 must find attempt 1's
    # products, because the build job is not re-run (see PRODUCTS_NAME below).
    out << "ios-build-for-testing artifact must be named ios-test-products-${{ github.run_id }} (no run_attempt)" unless with["name"] == "ios-test-products-${{ github.run_id }}"
    out << "ios-build-for-testing upload must set overwrite: true so a full re-run replaces the products" unless with["overwrite"] == true
    out << "ios-build-for-testing artifact retention must be 1 day" unless with["retention-days"] == 1
    out << "ios-build-for-testing must fail when no products were produced" unless with["if-no-files-found"] == "error"
  end
end

bft_upload = steps(jobs["ios-build-for-testing"] || {}).find { |s| s["name"] == "Upload test products" }
upload_name = ((bft_upload || {})["with"] || {})["name"]

%w[ios-tests ios-targeted].each do |name|
  job = jobs[name]
  if job.nil?
    out << "#{name} job is missing"
    next
  end
  out << "#{name} must need ios-build-for-testing (test-without-building from its products)" unless needs_of(job).include?("ios-build-for-testing")
  guard = steps(job).find { |s| s["name"] == ENV["GUARD_STEP"] }
  if guard.nil?
    out << "#{name} has no fail-closed guard (#{ENV["GUARD_STEP"]})"
  else
    out << "#{name} guard does not read the build-for-testing result" unless guard.dig("env", "BUILD_FOR_TESTING_RESULT") == "${{ needs.ios-build-for-testing.result }}"
  end
  download = step_by_uses(job, "actions/download-artifact@")
  if download.nil?
    out << "#{name} does not download the test products"
  else
    out << "#{name} download is not pinned to download-artifact v7" unless download["uses"] == ENV["PIN_DOWNLOAD"]
    out << "#{name} downloads a different artifact than ios-build-for-testing uploads" unless ((download["with"] || {})["name"]) == upload_name
  end
  text = run_text(job)
  out << "#{name} compiles in a test leg (--prepare-cache or xcodebuild build-for-testing)" if text.include?("--prepare-cache") || text.include?("xcodebuild build-for-testing")
  out << "#{name} does not pass the downloaded xctestrun to ios_ops.sh test" unless text.include?('--xctestrun "$IOS_XCTESTRUN"')
end

unit = steps(jobs["ios-tests"] || {}).select { |s| s["run"].to_s.include?("ios_ops.sh test") }
out << "ios-tests must have exactly one test invocation step" unless unit.size == 1
out << "ios-tests unit and ui legs must both run test-without-building from the products" unless unit.all? { |s| s["run"].to_s.include?('--xctestrun "$IOS_XCTESTRUN"') }

ib = jobs["ios-build"] || {}
out << "PR compile job must keep ios_ops.sh build" unless run_text(ib).include?("ios_ops.sh build")
out << "PR compile job must not prepare test products" if run_text(ib).include?("--prepare-cache")

# Build-once downloads (#3591): a hung download must not hold a leg until the
# 25-minute job timeout. Every download is step-bounded, followed by one retry
# that runs only when the first attempt did not succeed, and the unpack after
# them stays fail-closed (no rebuild, no always()).
DOWNLOAD_NAME = "Download build-once test products"
UNPACK_NAME = "Unpack build-once test products"
MAX_STEP_MINUTES = 5
dl_jobs = jobs.select { |_, job| steps(job).any? { |s| s["name"] == DOWNLOAD_NAME } }
%w[ios-tests ios-targeted].each do |name|
  out << "#{name} has no '#{DOWNLOAD_NAME}' step" unless dl_jobs.key?(name)
end
dl_jobs.each do |name, job|
  list = steps(job)
  list.each_with_index do |first, i|
    next unless first["name"] == DOWNLOAD_NAME
    id = first["id"].to_s
    out << "#{name}: download step has no id for the retry guard" if id.empty?
    t = first["timeout-minutes"]
    out << "#{name}: download step must have timeout-minutes <= #{MAX_STEP_MINUTES}" unless t.is_a?(Integer) && t.between?(1, MAX_STEP_MINUTES)
    out << "#{name}: download step must be continue-on-error: true so the retry can run" unless first["continue-on-error"] == true
    retry_step = list[i + 1]
    if retry_step.nil? || retry_step["uses"].to_s != ENV["PIN_DOWNLOAD"]
      out << "#{name}: no retry download step directly after the download"
      next
    end
    out << "#{name}: retry downloads a different artifact or path" unless (retry_step["with"] || {}).slice("name", "path") == (first["with"] || {}).slice("name", "path")
    out << "#{name}: retry must run only when the first download is not success" unless retry_step["if"].to_s.include?("steps.#{id}.outcome != 'success'")
    rt = retry_step["timeout-minutes"]
    out << "#{name}: retry download must have timeout-minutes <= #{MAX_STEP_MINUTES}" unless rt.is_a?(Integer) && rt.between?(1, MAX_STEP_MINUTES)
    out << "#{name}: retry download must not be continue-on-error (a second failure must go red)" if retry_step["continue-on-error"] == true
    unpack = list[i + 2]
    if unpack.nil? || unpack["name"] != UNPACK_NAME
      out << "#{name}: no '#{UNPACK_NAME}' step directly after the retry"
      next
    end
    out << "#{name}: unpack must not rebuild (xcodebuild, build-for-testing or --prepare-cache)" if unpack["run"].to_s.match?(/xcodebuild|build-for-testing|--prepare-cache/)
    out << "#{name}: unpack must run under set -euo pipefail" unless unpack["run"].to_s.include?("set -euo pipefail")
    out << "#{name}: unpack must not be always() or continue-on-error" if unpack["continue-on-error"] || unpack["if"].to_s.include?("always()")
  end
end

# Products artifact name (#3591): every upload and download of the build-once
# products uses the run_id-only name, so no attempt-scoped artifact can be looked up.
PRODUCTS_NAME = "ios-test-products-${{ github.run_id }}"
jobs.each do |jname, job|
  steps(job).each do |s|
    next unless s["uses"].to_s.start_with?("actions/download-artifact@", "actions/upload-artifact@")
    artifact = (s["with"] || {})["name"].to_s
    next unless artifact.start_with?("ios-test-products")
    out << "#{jname}: '#{s["name"]}' must use the artifact name #{PRODUCTS_NAME} (no run_attempt)" unless artifact == PRODUCTS_NAME
  end
end

puts out.join("\n")
RUBY
ruby_rc=0
ruby_out="$(PIN_UPLOAD="$PIN_UPLOAD" PIN_DOWNLOAD="$PIN_DOWNLOAD" GUARD_STEP="$GUARD_STEP" ruby "$tmp/topology.rb" "$IOS")" || ruby_rc=$?
# A crashed checker prints nothing; it must not read as a clean topology.
[[ "$ruby_rc" -eq 0 ]] || fail "topology checker crashed (exit $ruby_rc)"
if [[ -n "$ruby_out" ]]; then
  while IFS= read -r line; do fail "$line"; done <<<"$ruby_out"
fi

# --- 2. Fail-closed guard, executed (not just grepped) ----------------------
for job in ios-tests ios-targeted; do
  guard_script="$tmp/guard-$job.sh"
  if ! ruby -ryaml -e 'job = YAML.load_file(ARGV[0])["jobs"][ARGV[1]] || {}; step = Array(job["steps"]).find { |s| s["name"] == ARGV[2] }; abort("no guard step") unless step; print step["run"].to_s' "$IOS" "$job" "$GUARD_STEP" >"$guard_script" 2>/dev/null; then
    fail "$job: cannot extract the guard step '$GUARD_STEP'"
    continue
  fi
  for result in success failure cancelled skipped; do
    set +e
    BUILD_FOR_TESTING_RESULT="$result" bash "$guard_script" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$result" == success ]]; then
      [[ "$rc" -eq 0 ]] || fail "$job: guard rejects a successful build-for-testing (exit $rc)"
    else
      [[ "$rc" -ne 0 ]] || fail "$job: guard passes build-for-testing=$result (must fail closed)"
    fi
  done
done

# --- 2b. Guard comment matches the topology (#3478) -------------------------
# `needs` skips ios-targeted when the build fails or is skipped, so the guard step
# never runs on a red build. Its comment must not claim it fails the run there;
# the fail-closed verdict is ios-verdict, which reads the targeted result.
awk '/^  ios-targeted:/{on=1} /^  ios-verdict:/{on=0} on' "$IOS" >"$tmp/targeted-job.yml"
grep -q 'so the run fails here' "$tmp/targeted-job.yml" \
  && fail "ios-targeted guard comment claims a skipped build fails here; needs skips the job so the guard never runs"
grep -q 'ios-verdict' "$tmp/targeted-job.yml" \
  || fail "ios-targeted guard comment does not name ios-verdict as the fail-closed path"

# --- 2c. Unpack stays red when no download attempt produced the tar (#3591) --
# Executed, not grepped: with the downloads having left no tarball, the unpack step
# must exit non-zero, so a failed download can never reach the test run.
for job in ios-tests ios-targeted; do
  unpack_script="$tmp/unpack-$job.sh"
  if ! ruby -ryaml -e 'job = YAML.load_file(ARGV[0])["jobs"][ARGV[1]] || {}; step = Array(job["steps"]).find { |s| s["name"] == ARGV[2] }; abort("no unpack step") unless step; print step["run"].to_s' "$IOS" "$job" 'Unpack build-once test products' >"$unpack_script" 2>/dev/null; then
    fail "$job: cannot extract the unpack step"
    continue
  fi
  runner_temp="$tmp/runner-$job"
  mkdir -p "$runner_temp/ios-test-products/Build/Products"
  set +e
  RUNNER_TEMP="$runner_temp" GITHUB_ENV="$runner_temp/github-env" bash "$unpack_script" >/dev/null 2>&1
  unpack_rc=$?
  set -e
  [[ "$unpack_rc" -ne 0 ]] || fail "$job: unpack exits 0 with no test products tar (a failed download would reach the tests)"
done

# --- 3. ios_test.sh --xctestrun: validation refuses before any build or lock --
products="$tmp/products"
mkdir -p "$products/Build/Products"
: >"$products/Build/Products/BooksAndVocab_incomplete.xctestrun"

set +e
missing_out="$(bash "$IOS_TEST" --unit --device 'iPhone 17 Pro Max' --xctestrun "$tmp/none.xctestrun" 2>&1)"
missing_rc=$?
incomplete_out="$(bash "$IOS_TEST" --unit --device 'iPhone 17 Pro Max' --xctestrun "$products/Build/Products/BooksAndVocab_incomplete.xctestrun" 2>&1)"
incomplete_rc=$?
prepare_out="$(bash "$IOS_TEST" --unit --device 'iPhone 17 Pro Max' --xctestrun "$products/Build/Products/BooksAndVocab_incomplete.xctestrun" --prepare-cache 2>&1)"
prepare_rc=$?
list_out="$(bash "$IOS_TEST" --unit --device 'iPhone 17 Pro Max' --xctestrun "$products/Build/Products/BooksAndVocab_incomplete.xctestrun" --list 2>&1)"
list_rc=$?
set -e

[[ "$missing_rc" -ne 0 ]] || fail "--xctestrun with a missing file exits 0"
grep -q -- '--xctestrun file not found' <<<"$missing_out" || fail "--xctestrun missing file does not name the cause: $missing_out"
[[ "$incomplete_rc" -ne 0 ]] || fail "--xctestrun with incomplete products exits 0 (would test a half-built cache)"
grep -q -- '--xctestrun products are incomplete' <<<"$incomplete_out" || fail "--xctestrun incomplete products do not name the cause: $incomplete_out"
[[ "$prepare_rc" -ne 0 ]] || fail "--xctestrun combined with --prepare-cache exits 0"
grep -q -- '--xctestrun cannot be combined' <<<"$prepare_out" || fail "--xctestrun with --prepare-cache does not name the conflict: $prepare_out"
[[ "$list_rc" -ne 0 ]] || fail "--xctestrun combined with --list exits 0"
grep -q -- '--xctestrun cannot be combined' <<<"$list_out" || fail "--xctestrun with --list does not name the conflict: $list_out"

# The run path must test the prebuilt products and never fall back to a rebuild.
awk '/if \[\[ -n "\$XCTESTRUN_OVERRIDE" \]\]; then/{f=1} f&&/elif ios_test_cache_is_complete/{exit} f{print}' "$IOS_TEST" >"$tmp/override-branch.txt"
grep -q 'run_xcodebuild_test_without_building_once "\$XCTESTRUN_PATH"' "$tmp/override-branch.txt" \
  || fail "--xctestrun branch does not run test-without-building on the given products"
grep -q 'rebuild_test_cache' "$tmp/override-branch.txt" \
  && fail "--xctestrun branch can rebuild; a CI test leg must fail instead of compiling"
grep -q -- '--xctestrun' "$IOS_TEST" || fail "ios_test.sh has no --xctestrun flag"

# --- 3b. --json stdout is one payload document (#3331 merge-group failure) --
# The prepare path's progress lines (build-for-testing, disk budget, locks) used to
# reach stdout, so the redirected JSON file began with "[ios_test]" and the artifact
# step's jq failed. Under --json the dispatcher must fence fd 1 to stderr and write the
# payload only to fd 9. ios_ops.sh must pass --prepare-cache through natively.
grep -Fq 'exec 9>&1 1>&2' "$IOS_TEST" || fail "ios_test.sh does not fence stdout to stderr under --json for cache actions"
grep -Fq '"$payload" >&9' "$IOS_TEST" || fail "ios_test.sh cache payload is not written to the reserved fd 9"
if grep -F "printf '%s\\n' \"\$payload\"" "$IOS_TEST" | grep -qvF '>&9'; then
  fail "ios_test.sh writes a cache payload to plain stdout (would corrupt --json)"
fi
grep -Fq -- '--cache-status|--prepare-cache|--clean-cache)' ops/ios_ops.sh \
  || fail "ios_ops.sh does not pass --prepare-cache --json through natively"
cache_status_json="$tmp/cache-status.json"
set +e
bash "$IOS_TEST" --cache-status --unit --json --device 'iPhone 17 Pro Max' >"$cache_status_json" 2>/dev/null
cache_status_rc=$?
set -e
[[ "$cache_status_rc" -eq 0 ]] || fail "--cache-status --json exits $cache_status_rc"
jq -e '.schema == "kg.ios.test-cache.v1"' "$cache_status_json" >/dev/null 2>&1 \
  || fail "--cache-status --json stdout is not one JSON payload"

# --- 4. Docs describe the build-once topology -------------------------------
grep -q 'ios-build-for-testing' docs/sop/ios.md || fail "docs/sop/ios.md does not describe ios-build-for-testing"
grep -q 'ios-build-for-testing' docs/reference/delivery_model.md || fail "docs/reference/delivery_model.md does not describe ios-build-for-testing"

if [[ "$failures" -gt 0 ]]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "ios build-once contract: ok"
