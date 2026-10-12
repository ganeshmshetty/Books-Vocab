//
//  ReaderProgressFormatterTests.swift
//  BooksAndVocab Tests
//

import Foundation
import Testing
@testable import BooksAndVocab

// #2864：閱讀器與書架必須共用同一個 locale-aware 整數百分比格式，
// 否則同一本書在兩個畫面會顯示不同數字（56.7% vs 56%）。
struct ReaderProgressFormatterTests {
    private let english = Locale(identifier: "en_US_POSIX")

    @Test
    func percentIsIntegerAndRoundedToNearest() {
        #expect(ReadingProgressFormatter.percentText(0, locale: english) == "0%")
        #expect(ReadingProgressFormatter.percentText(0.567, locale: english) == "57%")
        #expect(ReadingProgressFormatter.percentText(0.564, locale: english) == "56%")
        #expect(ReadingProgressFormatter.percentText(1, locale: english) == "100%")
    }

    @Test
    func outOfRangeProgressIsClamped() {
        #expect(ReadingProgressFormatter.percentText(-0.2, locale: english) == "0%")
        #expect(ReadingProgressFormatter.percentText(1.4, locale: english) == "100%")
    }

    @Test
    func localeVariantKeepsIntegerDigitsWithoutDecimalSeparator() {
        let text = ReadingProgressFormatter.percentText(0.567, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("57"))
        #expect(text.contains("%"))
        #expect(!text.contains(","))
        #expect(!text.contains("."))
    }
}
