#!/usr/bin/env bash
# test_ui_token_lint.sh — behavioral verification for ops/ui_token_lint.sh.
#
# Asserts the four-mode contract (--report / --baseline / --baseline-check /
# --strict), the inline `// token-allow:` exemption, file-level exclusions, and
# the line-drift-resistant set-difference baseline. Runs against an isolated
# fixture tree (KG_UI_TOKEN_SRC override) so it never depends on live src state.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$WORKSPACE/ops/ui_token_lint.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

# ── fixture tree ─────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
BASE="$(mktemp)"
cleanup() { rm -rf "$FIX" "$BASE"; }
trap cleanup EXIT

mkdir -p "$FIX/Views" "$FIX/Debug" "$FIX/Models"

# A genuinely dirty view file: raw padding number, directional raw padding,
# raw shadow, raw cornerRadius, raw hex color, raw system font size.
cat > "$FIX/Views/Dirty.swift" <<'SWIFT'
import SwiftUI
struct Dirty: View {
    var body: some View {
        Text("x")
            .padding(7)
            .padding(.vertical, 13)
            .padding(.horizontal, 6)
            .padding(.top, 9)
            .padding(.leading, -4)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .background(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(Color(hex: "#FF0000"))
            .font(.system(size: 17))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(Capsule(style: .continuous))
            .overlay(AppRoundedRect(roundness: 0.15))
            .mask(AppUnevenRoundedRect(topRoundness: 8, bottomRoundness: 0))
    }
}
SWIFT

# A clean view file: everything tokenized, plus one exempted raw value.
# The directional .padding(.edge, AppSpacing.*) form is the SANCTIONED token
# usage and must NOT be flagged.
cat > "$FIX/Views/Clean.swift" <<'SWIFT'
import SwiftUI
struct Clean: View {
    var body: some View {
        Text("x")
            .padding(AppSpacing.s2)
            .padding(.vertical, AppSpacing.s3)
            .padding(.horizontal, skin.spacing.microGap)
            .appElevation(.z1)
            .background(AppRoundedRect(roundness: AppRoundness.card))
            .clipShape(AppUnevenRoundedRect(topRoundness: skin.roundness.card, bottomRoundness: 0))
            .foregroundColor(AppColors.accent)
            .padding(3) // token-allow: intentional one-off hairline
            .padding(.bottom, 8) // token-allow: exempted directional one-off
    }
}
SWIFT

# Excluded paths must NOT contribute findings even when dirty.
cat > "$FIX/Debug/DebugScratch.swift" <<'SWIFT'
import SwiftUI
struct DebugScratch: View { var body: some View { Text("x").padding(9) } }
SWIFT
cat > "$FIX/Views/Thing_Preview.swift" <<'SWIFT'
import SwiftUI
struct ThingPreview: View { var body: some View { Text("x").padding(9) } }
SWIFT
cat > "$FIX/Views/ThingTests.swift" <<'SWIFT'
import SwiftUI
struct ThingTests: View { var body: some View { Text("x").padding(9) } }
SWIFT
cat > "$FIX/Models/AppColors.swift" <<'SWIFT'
import SwiftUI
enum AppColors { static let accent = Color(hex: "#00FF00") }
SWIFT

run() { KG_UI_TOKEN_SRC="$FIX" KG_UI_TOKEN_BASELINE="$BASE" bash "$LINT" "$@"; }

# ── 1. Syntax ─────────────────────────────────────────────────────────────────
section "Syntax"
bash -n "$LINT" && ok "ui_token_lint.sh syntax" || fail_t "ui_token_lint.sh syntax"

# ── 2. --report never fails ───────────────────────────────────────────────────
section "--report exit 0"
if run --report >/dev/null 2>&1; then ok "--report exits 0 with findings present"
else fail_t "--report exited non-zero"; fi

# ── 3. --strict fails on raw findings + names the file ────────────────────────
section "--strict fails on raw findings"
out="$(run --strict 2>&1 || true)"
if grep -q 'Dirty.swift' <<< "$out"; then ok "--strict reports Dirty.swift"
else fail_t "--strict did not name Dirty.swift"; fi
if run --strict >/dev/null 2>&1; then fail_t "--strict exited 0 despite findings"
else ok "--strict exits non-zero with findings"; fi

# Each pattern category fires.
for pat in 'padding' 'shadow' 'cornerRadius|RoundedRectangle' 'hex|Color' 'system'; do
  grep -qiE "$pat" <<< "$out" && ok "strict detects category /$pat/" || fail_t "missing category /$pat/"
done

# Directional raw padding must be caught (each edge variant + negative).
grep -q '.padding(.vertical, 13)' <<< "$out"   && ok "padding caught .vertical raw"   || fail_t "missed directional .vertical raw padding"
grep -q '.padding(.horizontal, 6)' <<< "$out"  && ok "padding caught .horizontal raw" || fail_t "missed directional .horizontal raw padding"
grep -q '.padding(.top, 9)' <<< "$out"         && ok "padding caught .top raw"        || fail_t "missed directional .top raw padding"
grep -q '.padding(.leading, -4)' <<< "$out"    && ok "padding caught negative raw"    || fail_t "missed directional negative raw padding"

# ── 4. Exclusions & exemptions produce no Clean/excluded findings ─────────────
grep -q 'raw-rounded-shape' <<< "$out" && ok "raw RoundedRectangle/Capsule flagged" || fail_t "raw-rounded-shape rule never fired"
grep -q 'Capsule(style: .continuous)' <<< "$out" && ok "Capsule(style:) caught (not just bare Capsule())" || fail_t "Capsule(style:) slipped through"
grep -q 'roundness: 0.15' <<< "$out" && ok "bare t literal flagged" || fail_t "bare roundness literal missed"
grep -q 'topRoundness: 8' <<< "$out" && ok "pt smuggled into topRoundness flagged" || fail_t "per-corner roundness label not covered"

section "Exclusions & inline exemption"
grep -q 'Clean.swift' <<< "$out"        && fail_t "Clean.swift wrongly flagged (token-form directional padding false-positive?)" || ok "Clean.swift not flagged"
grep -q 'DebugScratch.swift' <<< "$out" && fail_t "Debug/ wrongly flagged"      || ok "Debug/ excluded"
grep -q 'Thing_Preview.swift' <<< "$out" && fail_t "*Preview* wrongly flagged"  || ok "*Preview* excluded"
grep -q 'ThingTests.swift' <<< "$out"   && fail_t "*Tests* wrongly flagged"     || ok "*Tests* excluded"
grep -q 'AppColors.swift' <<< "$out"    && fail_t "AppColors.swift wrongly flagged" || ok "AppColors.swift excluded"

# ── 5. baseline write + baseline-check on unchanged src exits 0 ───────────────
section "Baseline set-difference"
run --baseline >/dev/null 2>&1 && ok "--baseline writes file" || fail_t "--baseline failed"
[[ -s "$BASE" ]] && ok "baseline file non-empty" || fail_t "baseline file empty"
if run --baseline-check >/dev/null 2>&1; then ok "--baseline-check exits 0 on unchanged src"
else fail_t "--baseline-check regressed on unchanged src"; fi

# ── 6. baseline is line-drift resistant ───────────────────────────────────────
section "Baseline resists pure line drift"
# Prepend blank lines to Dirty.swift → every finding's line number shifts, but
# the normalized finding set is unchanged. baseline-check must still pass.
{ printf '\n\n\n'; cat "$FIX/Views/Dirty.swift"; } > "$FIX/Views/Dirty.swift.tmp"
mv "$FIX/Views/Dirty.swift.tmp" "$FIX/Views/Dirty.swift"
if run --baseline-check >/dev/null 2>&1; then ok "line drift does not regress baseline"
else fail_t "line drift falsely regressed baseline"; fi

# ── 7. genuinely new violation regresses ──────────────────────────────────────
section "New violation regresses"
cat > "$FIX/Views/Newbad.swift" <<'SWIFT'
import SwiftUI
struct Newbad: View { var body: some View { Text("x").cornerRadius(4) } }
SWIFT
if run --baseline-check >/dev/null 2>&1; then fail_t "new violation not detected by baseline-check"
else ok "new file violation regresses baseline-check"; fi

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
