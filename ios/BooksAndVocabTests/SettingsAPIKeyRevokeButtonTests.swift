#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import BooksAndVocab

/// #3426：撤銷鈕的可點範圍（frame + contentShape）不得低於 HIG 44pt 下限。
/// 舊實作把 label 固定成 32×32，命中區只有 32pt。這裡量的是production 元件渲染後的實際尺寸。
@MainActor
struct SettingsAPIKeyRevokeButtonTests {
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 320, height: 320))
    }

    @Test func revoke_control_hit_area_meets_the_44pt_floor() {
        let size = fittingSize(
            SettingsAPIKeyRevokeButton(isDisabled: false, accessibilityIdentifier: "test.revoke", action: {})
        )

        #expect(size.width >= 44, "revoke hit area width \(size.width) is below the 44pt floor")
        #expect(size.height >= 44, "revoke hit area height \(size.height) is below the 44pt floor")
    }

    @Test func revoke_control_glyph_is_smaller_than_the_floor() {
        // Positive control: the bare glyph is below 44pt, so the floor assertion above
        // is only satisfied by the hit-target frame, not by the glyph itself.
        let glyph = Image(systemName: "xmark.circle").font(.system(size: 17))
        #expect(fittingSize(glyph).height < 44)
    }
}
#endif
