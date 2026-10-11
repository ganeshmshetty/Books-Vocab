//
//  NotebookPaletteTests.swift
//  Books & Vocab Tests
//
//  鎖 NotebookPalette.darken HSB 計算正確性。
//

import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

#if canImport(UIKit)
import UIKit
private func hsb(_ color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return (h, s, b, a)
}
#else
import AppKit
private func hsb(_ color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    NSColor(color).usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return (h, s, b, a)
}
#endif

struct NotebookPaletteTests {
    @Test func darkenReducesBrightnessBy30Percent() async throws {
        let original = Color(hex: "#AFC2D3")!  // 海洋 Dusty Blue
        let darkened = NotebookPalette.darken(original, by: 0.3)
        let o = hsb(original)
        let d = hsb(darkened)
        #expect(abs(d.b - o.b * 0.7) < 0.01, "brightness should be ×0.7")
        #expect(abs(d.h - o.h) < 0.01, "hue should be preserved")
        #expect(abs(d.s - o.s) < 0.01, "saturation should be preserved")
    }

    @Test func darkenZeroIsIdentity() async throws {
        let original = Color(hex: "#DEC69C")!  // 琥珀
        let identity = NotebookPalette.darken(original, by: 0)
        let o = hsb(original)
        let i = hsb(identity)
        #expect(abs(i.b - o.b) < 0.001)
    }

    @Test func darkenAcrossAllMorandiColors() async throws {
        for (name, hex) in NotebookPalette.colors {
            guard let original = Color(hex: hex) else {
                Issue.record("\(name) (\(hex)) failed to parse")
                continue
            }
            let darkened = NotebookPalette.darken(original, by: 0.4)
            let o = hsb(original)
            let d = hsb(darkened)
            #expect(d.b < o.b, "\(name) brightness should decrease")
            #expect(abs(d.h - o.h) < 0.02, "\(name) hue should be near-preserved")
        }
    }

    /// 色票 VoiceOver 名稱的嚴格契約：每個 shipped locale 的 bundle 必須自己持有該鍵，
    /// 故用 `fallback: nil`。若走 `L10n.string` 的英文回落，en-only 的鍵會讓 ja/ko 假綠，
    /// VoiceOver 仍念出中文 key。zh-Hant 以原文為鍵（identity），只要求 en/ja/ko 不等於原文。
    @Test func swatchNames_resolveInEveryShippedLocaleWithoutEnglishFallback() {
        let translatedLanguages: Set<AppLanguage> = [.english, .japanese, .korean]
        for language in AppLanguage.allCases where language != .system {
            let bundle = AppLanguageStore.shared.stringBundle(for: language)
            for swatch in NotebookPalette.colors {
                let resolved = L10n.lookup(swatch.name, in: bundle, fallback: nil)
                #expect(!resolved.isEmpty, "\(language) resolved \(swatch.name) to empty")
                if translatedLanguages.contains(language) {
                    #expect(resolved != swatch.name, "\(language) has no translation for \(swatch.name)")
                }
            }
        }
    }
}
