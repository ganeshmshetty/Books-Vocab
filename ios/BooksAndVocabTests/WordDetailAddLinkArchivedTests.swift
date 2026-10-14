//
//  WordDetailAddLinkArchivedTests.swift
//  Books & Vocab Tests
//
//  Issue #3671: 封存卡的知識連結「+」必須不可見。後端對封存來源一律回 404（ensure-target 與既有詞手動連結皆然），
//  前端若仍提供入口，使用者只會看到無法重試的一般錯誤。
//

import Foundation
import Testing
@testable import BooksAndVocab

@Suite("WordDetail Add Link availability")
struct WordDetailAddLinkArchivedTests {
    @Test("archived card offers no Add Link handler")
    func archivedCardHidesAddLink() {
        var opened = false
        let handler = WordDetailSheet.addLinkAction(isArchived: true) { opened = true }
        #expect(handler == nil)
        #expect(opened == false)
    }

    @Test("active card offers Add Link handler that opens the flow")
    func activeCardShowsAddLink() {
        var opened = false
        let handler = WordDetailSheet.addLinkAction(isArchived: false) { opened = true }
        #expect(handler != nil)
        handler?()
        #expect(opened == true)
    }
}
