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
}
