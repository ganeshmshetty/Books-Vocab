//
//  AppFontsDynamicTypeTests.swift
//  Books & Vocab Tests
//

import Foundation
import Testing
import UIKit
@testable import BooksAndVocab

@Suite
@MainActor
struct AppFontsDynamicTypeTests {

    @Test("body token keeps its base point size at the default category")
    func bodyTokenKeepsBaseSizeAtDefaultCategory() {
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let resolved = AppFonts.scaledPointSize(AppFonts.TypeScale.body, compatibleWith: defaultTraits)
        #expect(resolved == AppFonts.TypeScale.body)
    }

    @Test("body token grows at accessibilityExtraExtraExtraLarge")
    func bodyTokenGrowsAtAccessibilitySize() {
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let axTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let atDefault = AppFonts.scaledPointSize(AppFonts.TypeScale.body, compatibleWith: defaultTraits)
        let atAccessibility = AppFonts.scaledPointSize(AppFonts.TypeScale.body, compatibleWith: axTraits)
        #expect(atAccessibility > atDefault)
    }

    @Test("live Dynamic Type change invalidates typography and bumps the render version")
    func contentSizeChangeInvalidatesTypography() async throws {
        let tracker = FontAvailabilityTracker()
        let before = tracker.serifCJKVersion
        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        // Observer 以 .main 佇列投遞；輪詢至多 2 秒等待版本號變動。
        var waited = 0
        while tracker.serifCJKVersion == before && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(tracker.serifCJKVersion == before + 1)
    }

    @Test("typography invalidation seam clears the cache and bumps the render version")
    func typographyInputsDidChangeClearsCache() {
        let tracker = FontAvailabilityTracker()
        // 先建立 cache，確保後續的 nil 是由 seam 造成，而非初始狀態。
        _ = AppSkin.baseTypography
        #expect(AppSkin.isTypographyCached)
        let before = tracker.serifCJKVersion
        // 直接呼叫 internal seam，不經 NotificationCenter，因此不依賴 observer 的投遞時序。
        // 同步斷言即可：沒有任何 await，SwiftUI 不會在此之間重建 typography 把 cache 填回去。
        tracker.typographyInputsDidChange()
        #expect(tracker.serifCJKVersion == before + 1)
        #expect(!AppSkin.isTypographyCached)
    }
}
