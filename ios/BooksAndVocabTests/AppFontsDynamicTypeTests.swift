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
    func contentSizeChangeClearsTypographyCache() async {
        let tracker = FontAvailabilityTracker()
        // 先建立 cache，確保後續的 nil 是由通知造成，而非初始狀態。
        _ = AppSkin.baseTypography
        #expect(AppSkin.isTypographyCached)
        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        // Observer 以 .main 佇列投遞：先排空該佇列再斷言，不以 sleep 輪詢。
        await drainMainQueue()
        #expect(!AppSkin.isTypographyCached)
        withExtendedLifetime(tracker) {}
    }

    /// 等待在呼叫當下之前已排入 `OperationQueue.main` 的工作全部執行完畢。
    /// `NotificationCenter` 以 `queue: .main` 投遞時會把 observer 排入同一個序列佇列，
    /// 因此 post 之後排入的 marker 必定晚於 observer 執行，無需輪詢。
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            OperationQueue.main.addOperation { continuation.resume() }
        }
    }
}
