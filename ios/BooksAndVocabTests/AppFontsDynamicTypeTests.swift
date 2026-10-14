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

    @Test("live Dynamic Type change clears the typography cache")
    func contentSizeChangeClearsTypographyCache() {
        let tracker = FontAvailabilityTracker()
        // 先建立 cache，確保後續的 nil 是由通知造成，而非初始狀態。
        _ = AppSkin.baseTypography
        #expect(AppSkin.isTypographyCached)
        let before = tracker.serifCJKVersion
        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        // 在 MainActor 上 post 時，`.main` observer 同步執行：版本號先遞增，代表 observer 已跑完、cache 已清除。
        // 斷言必須留在同一個 MainActor turn。任何 await（含排空佇列）都會讓 live AppThemeContainer 的
        // SwiftUI 更新重建 typography 並把 cache 填回去，這正是 #3650 CI 紅燈的成因。
        #expect(tracker.serifCJKVersion == before + 1)
        #expect(!AppSkin.isTypographyCached)
    }
}
