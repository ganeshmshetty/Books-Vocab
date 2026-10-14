//
//  WordDetailAddLinkArchivedTests.swift
//  Books & Vocab Tests
//
//  Issue #3671: 封存卡的知識連結「+」必須不可見。後端對封存來源一律回 404（ensure-target 與既有詞手動連結皆然），
//  前端若仍提供入口，使用者只會看到無法重試的一般錯誤。
//  `WordDetailPresenter` 是唯一渲染「+」的地方；它解析出的 handler 即決定按鈕是否存在。
//

import Foundation
import Testing
@testable import BooksAndVocab

@Suite("WordDetail Add Link availability")
@MainActor
struct WordDetailAddLinkArchivedTests {
    @Test("archived card resolves no Add Link handler, so the affordance is absent")
    func archivedCardHidesAddLink() {
        var opened = false
        let handler = WordDetailPresenter.addLinkHandler(isArchived: true) { opened = true }
        #expect(handler == nil)
        #expect(opened == false)
    }

    @Test("active card resolves an Add Link handler that opens the flow")
    func activeCardShowsAddLink() {
        var opened = false
        let handler = WordDetailPresenter.addLinkHandler(isArchived: false) { opened = true }
        #expect(handler != nil)
        handler?()
        #expect(opened == true)
    }

    @Test("no caller handler stays nil for both states")
    func missingHandlerStaysNil() {
        #expect(WordDetailPresenter.addLinkHandler(isArchived: true, handler: nil) == nil)
        #expect(WordDetailPresenter.addLinkHandler(isArchived: false, handler: nil) == nil)
    }
}
