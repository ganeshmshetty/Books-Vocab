#!/usr/bin/env bash
# test_tap_a11y_lint.sh — behavioral verification for ops/tap_a11y_lint.sh.
#
# Bug class under test: `.onTapGesture` is invisible to VoiceOver and gives no
# 44pt target. A tappable view built from it (colour swatch, pattern tile,
# row tap) announces as plain content: no button trait, no selected state
# (issue #2053). The lint requires every non-test `.onTapGesture` to be
# followed in its modifier chain by an a11y declaration (isButton trait,
# accessibilityAction, accessibilityHidden(true)) or a `// a11y-allow:` marker.
#
# Includes the POSITIVE CONTROL: a deliberately unannotated tap fixture must be
# reported. Without it a lint that silently matches nothing would pass every
# "clean" assertion below and prove nothing. Runs against an isolated fixture
# tree (KG_TAP_A11Y_SRC override) so it never depends on live src state.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$WORKSPACE/ops/tap_a11y_lint.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

FIX="$(mktemp -d)"
BASE="$(mktemp)"
cleanup() { rm -rf "$FIX" "$BASE"; }
trap cleanup EXIT

mkdir -p "$FIX/Views" "$FIX/Debug"

# True positives: onTapGesture with no a11y declaration in the chain.
cat > "$FIX/Views/Dirty.swift" <<'SWIFT'
import SwiftUI
struct Dirty: View {
    var body: some View {
        VStack {
            // Positive control: bare colour-swatch tap, label only (the #2053 shape).
            Circle()
                .frame(width: 32, height: 32)
                .onTapGesture { pickColor(1) }
                .accessibilityLabel("red")

            // Row tap with contentShape but no trait.
            Row()
                .contentShape(Rectangle())
                .onTapGesture { openRow(2) }

            // Method-reference form, args present.
            Row().onTapGesture(count: 2, perform: doubleTap3)

            // isButton exists only inside a string literal: must NOT exempt.
            Row()
                .onTapGesture { stringTrap4() }
                .accessibilityLabel("isButton accessibilityAddTraits(.isButton)")

            // Trait buried inside ANOTHER modifier's trailing closure
            // does not decorate THIS view.
            Row()
                .onTapGesture { closureTrap5() }
                .overlay { Color.clear.accessibilityAddTraits(.isButton) }

            // Marker text inside a string literal must NOT exempt.
            Row()
                .onTapGesture { markerString6() }
                .help("// a11y-allow: not a comment")

            // isSelected alone is not a button trait.
            Row()
                .onTapGesture { selectedOnly7() }
                .accessibilityAddTraits(.isSelected)
        }
    }
}
SWIFT

# Clean shapes.
cat > "$FIX/Views/Clean.swift" <<'SWIFT'
import SwiftUI
struct Clean: View {
    var body: some View {
        VStack {
            Row()
                .onTapGesture { a() }
                .accessibilityAddTraits(.isButton)

            Row()
                .onTapGesture { b() }
                .accessibilityLabel("x")
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)

            Row()
                .onTapGesture { c() }
                .accessibilityAction(.default) { c() }

            // Trailing-closure action forms (no parenthesis).
            Row()
                .onTapGesture { c2() }
                .accessibilityAction { c2() }

            Row()
                .onTapGesture { c3() }
                .accessibilityActions { Button("x") { c3() } }

            // Decorative dismiss catcher hidden from AT.
            Color.clear
                .onTapGesture { d() }
                .accessibilityHidden(true)

            // Exempted with a marker in the chain.
            Row()
                .onTapGesture { e() } // a11y-allow: background dismiss, AT has Done button
            Row()
                // a11y-allow: marker on the line above
                .onTapGesture { f() }

            // Commented-out and string-embedded taps are invisible.
            // Row().onTapGesture { g() }
            /* Row().onTapGesture { h() } */
            Text("call .onTapGesture { x } on it")

            // Real Button, no gesture at all.
            Button { i() } label: { Row() }
        }
    }
}
SWIFT

for name in Debug/DebugScratch Views/Thing_Preview Views/ThingTests; do
  cat > "$FIX/$name.swift" <<'SWIFT'
import SwiftUI
struct Scratch: View {
    var body: some View { Row().onTapGesture { x() } }
}
SWIFT
done

run() { KG_TAP_A11Y_SRC="$FIX" KG_TAP_A11Y_BASELINE="$BASE" bash "$LINT" "$@"; }

section "Syntax"
bash -n "$LINT" && ok "tap_a11y_lint.sh syntax" || fail_t "tap_a11y_lint.sh syntax"

section "--report exit 0"
if run --report >/dev/null 2>&1; then ok "--report exits 0 with findings present"
else fail_t "--report exited non-zero"; fi

section "--strict detection + positive control"
out="$(run --strict 2>&1 || true)"
if run --strict >/dev/null 2>&1; then fail_t "--strict exited 0 despite findings (lint is blind)"
else ok "--strict exits non-zero with findings"; fi

dirty_count="$(echo "$out" | grep -c 'Dirty.swift:' || true)"
if [[ "$dirty_count" -eq 7 ]]; then ok "all 7 dirty taps flagged"
else fail_t "expected 7 Dirty.swift findings, got $dirty_count"; echo "$out" | sed 's/^/    /'; fi

grep -q 'pickColor(1)' <<< "$out"     && ok "POSITIVE CONTROL: bare swatch tap caught"        || fail_t "positive control missed: bare swatch tap"
grep -q 'openRow(2)' <<< "$out"       && ok "contentShape alone does not exempt"              || fail_t "missed contentShape-only row tap"
grep -q 'doubleTap3' <<< "$out"       && ok "onTapGesture(count:perform:) form caught"        || fail_t "missed onTapGesture(count:perform:)"
grep -q 'stringTrap4' <<< "$out"      && ok "isButton inside string does not exempt"          || fail_t "string-literal trait falsely exempted"
grep -q 'closureTrap5' <<< "$out"     && ok "trait inside other modifier's closure does not exempt" || fail_t "closure-buried trait falsely exempted"
grep -q 'markerString6' <<< "$out"    && ok "marker inside string does not exempt"            || fail_t "string-literal marker falsely exempted"
grep -q 'selectedOnly7' <<< "$out"    && ok "isSelected without isButton does not exempt"     || fail_t "isSelected falsely exempted"

section "Clean / exemption / exclusions"
grep -q 'Clean.swift' <<< "$out"         && { fail_t "Clean.swift wrongly flagged"; echo "$out" | grep 'Clean.swift' | sed 's/^/    /'; } || ok "Clean.swift not flagged"
grep -q 'DebugScratch.swift' <<< "$out"  && fail_t "Debug/ wrongly flagged"    || ok "Debug/ excluded"
grep -q 'Thing_Preview.swift' <<< "$out" && fail_t "*Preview* wrongly flagged" || ok "*Preview* excluded"
grep -q 'ThingTests.swift' <<< "$out"    && fail_t "*Tests* wrongly flagged"   || ok "*Tests* excluded"

section "Baseline set-difference"
run --baseline >/dev/null 2>&1 && ok "--baseline writes file" || fail_t "--baseline failed"
[[ -s "$BASE" ]] && ok "baseline file non-empty" || fail_t "baseline file empty"
if run --baseline-check >/dev/null 2>&1; then ok "--baseline-check exits 0 on unchanged src"
else fail_t "--baseline-check regressed on unchanged src"; fi

section "Baseline resists pure line drift"
{ printf '//\n//\n//\n'; cat "$FIX/Views/Dirty.swift"; } > "$FIX/Views/Dirty.swift.tmp"
mv "$FIX/Views/Dirty.swift.tmp" "$FIX/Views/Dirty.swift"
if run --baseline-check >/dev/null 2>&1; then ok "line drift does not regress baseline"
else fail_t "line drift falsely regressed baseline"; fi

section "New violation regresses"
cat > "$FIX/Views/Newbad.swift" <<'SWIFT'
import SwiftUI
struct Newbad: View {
    var body: some View { Row().onTapGesture { fresh() } }
}
SWIFT
if run --baseline-check >/dev/null 2>&1; then fail_t "new violation not detected by baseline-check"
else ok "new file violation regresses baseline-check"; fi

echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
