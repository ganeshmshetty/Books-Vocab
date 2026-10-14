#!/usr/bin/env bash
# test_plain_deadzone_lint.sh — behavioral verification for ops/plain_deadzone_lint.sh.
#
# Bug class under test: `.buttonStyle(.plain)` hit-testing falls through
# transparent pixels, so a Button whose label has a transparent gap (Spacer /
# maxWidth-infinity frame) and no `.contentShape` has a dead middle — taps land
# on nothing (production bug caught in the Settings flow, fixed in PR #904).
#
# Asserts the four-mode contract (--report / --baseline / --baseline-check /
# --strict), label-form coverage (trailing closure, `label:` closure, titled
# action closure), the inline `// deadzone-allow:` exemption, file-level
# exclusions, and the line-drift-resistant set-difference baseline. Runs against
# an isolated fixture tree (KG_DEADZONE_SRC override) so it never depends on
# live src state.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$WORKSPACE/ops/plain_deadzone_lint.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

# ── fixture tree ─────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
BASE="$(mktemp)"
cleanup() { rm -rf "$FIX" "$BASE"; }
trap cleanup EXIT

mkdir -p "$FIX/Views" "$FIX/Debug"

# True positives: transparent-gap labels on .plain buttons, no contentShape.
cat > "$FIX/Views/Dirty.swift" <<'SWIFT'
import SwiftUI
struct Dirty: View {
    var body: some View {
        VStack {
            // Trailing-closure label with a Spacer gap.
            Button(action: { tap() }) {
                HStack {
                    Text("title")
                    Spacer()
                    Text("value")
                }
            }
            .buttonStyle(.plain)

            // `label:` closure form with a Spacer gap.
            Button {
                tap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            // maxWidth-infinity label stretches past its visible content.
            Button(action: { tap() }) {
                Text("wide")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Spelled-out style must count as plain too.
            Button(action: { tap() }) {
                HStack { Text("a"); Spacer(); Text("b") }
            }
            .buttonStyle(PlainButtonStyle())

            // Multi-trailing-closure modifier between the label and the style:
            // the chain walk must not stop at `message:`.
            Button(action: { confirmTap() }) {
                HStack { Text("a"); Spacer(); Text("b") }
            }
            .alert("sure?", isPresented: $confirming) {
                Button("ok") { tap() }
            } message: {
                Text("details")
            }
            .buttonStyle(.plain)

            // A string literal containing the marker text must NOT exempt.
            Button(action: { tap() }) {
                HStack { Text("deadzone-allow: not a real marker"); Spacer(minLength: 2) }
            }
            .buttonStyle(.plain)

            // Not even when the string spells out the full comment form.
            Button(action: { tap() }) {
                HStack { Text("see // deadzone-allow: docs"); Spacer(minLength: 3) }
            }
            .buttonStyle(.plain)

            // contentShape buried inside another modifier's trailing closure
            // does not guard THIS button — must still be flagged.
            Button(action: { tap() }) {
                HStack { Text("x"); Spacer(minLength: 4) }
            }
            .alert("sure?", isPresented: $confirming) {
                Button("ok") { tap() }
            } message: {
                Text("details").contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
SWIFT

# Clean: same shapes but guarded, non-plain, or solid labels.
cat > "$FIX/Views/Clean.swift" <<'SWIFT'
import SwiftUI
struct Clean: View {
    var body: some View {
        VStack {
            // contentShape inside the label closure.
            Button(action: { tap() }) {
                HStack {
                    Text("title")
                    Spacer()
                    Text("value")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // contentShape on the modifier chain after the label.
            Button(action: { tap() }) {
                HStack { Text("a"); Spacer() }
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            // Gap but NOT plain-styled: default styles hit-test the full bounds.
            Button(action: { tap() }) {
                HStack { Text("a"); Spacer() }
            }
            .buttonStyle(.borderedProminent)

            // Solid single-view label: no transparent gap to fall through.
            Button(action: { tap() }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)

            // Titled init: the trailing closure is the ACTION, label is solid text.
            Button("ok") {
                tap()
            }
            .buttonStyle(.plain)

            // Exempted finding.
            Button(action: { tap() }) { // deadzone-allow: custom overlay handles hits
                HStack { Text("a"); Spacer() }
            }
            .buttonStyle(.plain)

            // A gap that only exists inside string copy is not a gap.
            Button(action: { tap() }) {
                Text("call Spacer( with maxWidth: .infinity, says the docs")
            }
            .buttonStyle(.plain)

            // Commented-out dirty buttons must be invisible to the scanner.
            // Button(action: { tap() }) { HStack { Spacer() } }.buttonStyle(.plain)
            /*
            Button(action: { tap() }) {
                HStack { Text("a"); Spacer(); Text("b") }
            }
            .buttonStyle(.plain)
            */
        }
    }
}
SWIFT

# Excluded paths must NOT contribute findings even when dirty.
cat > "$FIX/Debug/DebugScratch.swift" <<'SWIFT'
import SwiftUI
struct DebugScratch: View {
    var body: some View {
        Button(action: {}) { HStack { Spacer() } }.buttonStyle(.plain)
    }
}
SWIFT
cat > "$FIX/Views/Thing_Preview.swift" <<'SWIFT'
import SwiftUI
struct ThingPreview: View {
    var body: some View {
        Button(action: {}) { HStack { Spacer() } }.buttonStyle(.plain)
    }
}
SWIFT
cat > "$FIX/Views/ThingTests.swift" <<'SWIFT'
import SwiftUI
struct ThingTests: View {
    var body: some View {
        Button(action: {}) { HStack { Spacer() } }.buttonStyle(.plain)
    }
}
SWIFT

run() { KG_DEADZONE_SRC="$FIX" KG_DEADZONE_BASELINE="$BASE" bash "$LINT" "$@"; }

# ── 1. Syntax ─────────────────────────────────────────────────────────────────
section "Syntax"
bash -n "$LINT" && ok "plain_deadzone_lint.sh syntax" || fail_t "plain_deadzone_lint.sh syntax"

# ── 2. --report never fails ───────────────────────────────────────────────────
section "--report exit 0"
if run --report >/dev/null 2>&1; then ok "--report exits 0 with findings present"
else fail_t "--report exited non-zero"; fi

# ── 3. --strict fails and flags every dirty button (count pinned below) ───────
section "--strict detection"
out="$(run --strict 2>&1 || true)"
if run --strict >/dev/null 2>&1; then fail_t "--strict exited 0 despite findings"
else ok "--strict exits non-zero with findings"; fi

dirty_count="$(echo "$out" | grep -c 'Dirty.swift' || true)"
if [[ "$dirty_count" -eq 8 ]]; then ok "all 8 dirty buttons flagged"
else fail_t "expected 8 Dirty.swift findings, got $dirty_count"; echo "$out" | sed 's/^/    /'; fi

grep -q 'Spacer()' <<< "$out"                 && ok "trailing-closure Spacer gap caught"  || fail_t "missed trailing-closure Spacer gap"
grep -q 'Spacer(minLength: 0' <<< "$out"      && ok "label:-closure Spacer gap caught"    || fail_t "missed label:-closure Spacer gap"
grep -q 'maxWidth: .infinity' <<< "$out"      && ok "maxWidth-infinity gap caught"        || fail_t "missed maxWidth-infinity gap"
grep -q 'PlainButtonStyle()' <<< "$out"       && ok "PlainButtonStyle() spelling caught"  || fail_t "missed PlainButtonStyle() spelling"
grep -q 'confirmTap' <<< "$out"               && ok "chain survives multi-trailing-closure modifier" || fail_t "chain walk stopped at message: closure"
grep -q 'Spacer(minLength: 2' <<< "$out"      && ok "marker inside string literal does not exempt"   || fail_t "string-literal marker falsely exempted"
grep -q 'Spacer(minLength: 3' <<< "$out"      && ok "full comment-form marker in string does not exempt" || fail_t "string spelling // deadzone-allow: falsely exempted"
grep -q 'Spacer(minLength: 4' <<< "$out"      && ok "contentShape inside alert message does not exempt"  || fail_t "closure-buried contentShape falsely exempted"

# ── 4. Clean shapes, exemption, exclusions produce no findings ────────────────
section "Clean / exemption / exclusions"
grep -q 'Clean.swift' <<< "$out"         && { fail_t "Clean.swift wrongly flagged"; echo "$out" | grep 'Clean.swift' | sed 's/^/    /'; } || ok "Clean.swift not flagged"
grep -q 'DebugScratch.swift' <<< "$out"  && fail_t "Debug/ wrongly flagged"     || ok "Debug/ excluded"
grep -q 'Thing_Preview.swift' <<< "$out" && fail_t "*Preview* wrongly flagged"  || ok "*Preview* excluded"
grep -q 'ThingTests.swift' <<< "$out"    && fail_t "*Tests* wrongly flagged"    || ok "*Tests* excluded"

# ── 5. baseline write + baseline-check on unchanged src exits 0 ───────────────
section "Baseline set-difference"
run --baseline >/dev/null 2>&1 && ok "--baseline writes file" || fail_t "--baseline failed"
[[ -s "$BASE" ]] && ok "baseline file non-empty" || fail_t "baseline file empty"
if run --baseline-check >/dev/null 2>&1; then ok "--baseline-check exits 0 on unchanged src"
else fail_t "--baseline-check regressed on unchanged src"; fi

# ── 6. baseline is line-drift resistant ───────────────────────────────────────
section "Baseline resists pure line drift"
{ printf '//\n//\n//\n'; cat "$FIX/Views/Dirty.swift"; } > "$FIX/Views/Dirty.swift.tmp"
mv "$FIX/Views/Dirty.swift.tmp" "$FIX/Views/Dirty.swift"
if run --baseline-check >/dev/null 2>&1; then ok "line drift does not regress baseline"
else fail_t "line drift falsely regressed baseline"; fi

# ── 7. genuinely new violation regresses ──────────────────────────────────────
section "New violation regresses"
cat > "$FIX/Views/Newbad.swift" <<'SWIFT'
import SwiftUI
struct Newbad: View {
    var body: some View {
        Button(action: {}) { HStack { Text("x"); Spacer() } }.buttonStyle(.plain)
    }
}
SWIFT
if run --baseline-check >/dev/null 2>&1; then fail_t "new violation not detected by baseline-check"
else ok "new file violation regresses baseline-check"; fi

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
