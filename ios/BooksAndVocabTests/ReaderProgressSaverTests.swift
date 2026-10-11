//
//  ReaderProgressSaverTests.swift
//  Books & Vocab Tests
//
//  Spec for Track 20: EPUB reader last-read locator persistence fix.
//
//  Root cause: ReaderView.handleLocationChange mutated Book.lastReadLocatorJSON
//  every page-turn but never called modelContext.save() (unlike PDFReaderView's
//  explicit safeSave()), so the last position could be lost on crash/OOM before
//  SwiftData's non-deterministic autosave flushed.
//
//  The debounce contract is exercised through an injected deterministic
//  scheduler; no wall-clock wait is needed to verify flush/coalescing.
//

import Foundation
import Testing
import ReadiumShared
@testable import BooksAndVocab

@MainActor
struct ReaderProgressSaverTests {

    @Test func defaultProgressSaverCanBeConstructedFromMainActor() {
        _ = ReaderProgressSaver()
    }

    @Test func readerLocationHandlerUsesInjectedRuntimeClock() throws {
        let expectedDate = Date(timeIntervalSince1970: 123)
        let book = Book(title: "Clocked Reader", author: "Test", fileName: "clocked.epub")
        var sut = ReaderView(
            book: book,
            readerRuntimeClock: ReaderRuntimeClock(now: { expectedDate })
        )
        let locator = try #require(try? Locator(jsonString: """
        {"href":"chapter1.html","type":"text/html","locations":{"totalProgression":0.42}}
        """))

        sut.handleLocationChange(locator)

        #expect(book.dateLastRead == expectedDate)
        #expect(book.progression == 0.42)
    }

    /// Consecutive page-turns inside the debounce window collapse to a single
    /// save — no per-page synchronous I/O.
    @Test func consecutivePageTurnsCoalesceToSingleSave() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let sut = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)

        var applied = 0
        for _ in 0..<10 {
            sut.recordChange(apply: { applied += 1 }, save: { saves.increment() })
        }

        // apply runs synchronously every page (in-memory model stays fresh)...
        #expect(applied == 10)
        // ...but no save has flushed yet within the window.
        #expect(saves.value == 0)

        debouncer.fire()
        // Exactly one coalesced save fires at the window tail.
        #expect(saves.value == 1)
    }

    /// flush() persists immediately and cancels the pending debounced save,
    /// so it never double-fires — covers onDisappear / scenePhase .background.
    @Test func flushSavesImmediatelyAndCancelsPending() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let sut = ReaderProgressSaver(flushDelay: 0.5, debouncer: debouncer)

        sut.recordChange(apply: {}, save: { saves.increment() })
        #expect(saves.value == 0)   // still pending

        sut.flush()
        #expect(saves.value == 1)   // immediate

        // The previously-scheduled debounced save must have been cancelled.
        debouncer.fire()
        #expect(saves.value == 1)
    }

    /// flush() with nothing pending is a no-op (no spurious save).
    @Test func flushWithoutPendingIsNoOp() {
        let saves = Counter()
        let sut = ReaderProgressSaver(flushDelay: 0.5, debouncer: TestReaderProgressDebouncer())
        sut.flush()
        #expect(saves.value == 0)
    }

    /// A record() arriving after a flush() schedules a fresh debounce window.
    @Test func recordAfterFlushSchedulesNewWindow() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let sut = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)

        sut.recordChange(apply: {}, save: { saves.increment() })
        sut.flush()                 // save #1
        #expect(saves.value == 1)

        sut.recordChange(apply: {}, save: { saves.increment() })
        debouncer.fire()
        #expect(saves.value == 2)   // debounced save #2
    }

    /// A valid locator round-trips to a non-nil JSON the restore path can decode
    /// (no "{}" pollution on the happy path). Built via the same `jsonString`
    /// decode seam the restore path uses (ReaderView+Panels.initialLocator).
    @Test func encodedLocatorJSONReturnsJSONForValidLocator() throws {
        let sourceJSON = """
        {"href":"chapter1.html","type":"text/html","locations":{"totalProgression":0.42}}
        """
        let locator = try #require(try? Locator(jsonString: sourceJSON))

        let json = try #require(ReaderProgressSaver.encodedLocatorJSON(locator))
        // Must round-trip back into a Locator carrying the same progression.
        let restored = try #require(try? Locator(jsonString: json))
        #expect(restored.locations.totalProgression == 0.42)
    }

    // MARK: - Edge cases

    /// Calling flush() twice without an intervening recordChange is a no-op.
    @Test func doubleFlushWithoutRecordIsNoOp() {
        let saves = Counter()
        let sut = ReaderProgressSaver(flushDelay: 0.5, debouncer: TestReaderProgressDebouncer())

        sut.recordChange(apply: {}, save: { saves.increment() })
        sut.flush()   // save #1
        sut.flush()   // latestSave already nil → no-op
        #expect(saves.value == 1)
    }

    /// flush() cancels the pending debounce task; even if the original window
    /// expires later, no late save fires because the task was cancelled.
    @Test func flushCancelsPendingTaskSoNoLateSave() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let sut = ReaderProgressSaver(flushDelay: 0.5, debouncer: debouncer)

        sut.recordChange(apply: {}, save: { saves.increment() })
        sut.flush()   // immediate save + cancel pending task

        // Wait well past the original debounce window.
        debouncer.fire()
        #expect(saves.value == 1)   // still only the flush save
    }

    /// The save closure from the most recent recordChange wins — intermediate
    /// closures are never executed.
    @Test func intermediateSaveClosuresAreNeverExecuted() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let sut = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)

        sut.recordChange(apply: {}, save: { saves.increment() })          // closure A
        sut.recordChange(apply: {}, save: { saves.increment() })          // closure B
        sut.recordChange(apply: {}, save: { saves.increment() })          // closure C

        debouncer.fire()
        // Only the latest closure (C) executes once; A and B are dropped.
        #expect(saves.value == 1)
    }

    // MARK: - PDF progress recorder (#2471)

    /// 10 page changes coalesce to 0 persists until the debouncer fires, then 1;
    /// in-memory fields stay fresh immediately.
    @Test func pdfPageChangesCoalesceAndKeepMemoryFresh() throws {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let saver = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)
        let book = Book(title: "PDF", author: "Test", fileName: "a.pdf")
        let sut = PDFProgressRecorder(book: book, saver: saver, persist: { saves.increment() })

        for page in 0..<10 { sut.pageChanged(pageIndex: page, pageCount: 100) }

        #expect(saves.value == 0)
        #expect(book.progression == 9.0 / 99.0)
        let json = try #require(book.lastReadLocatorJSON)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int])
        #expect(obj == ["pageIndex": 9])

        debouncer.fire()
        #expect(saves.value == 1)
    }

    @Test func pdfFlushPersistsOnceAndLateFireDoesNotRepeat() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let saver = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)
        let book = Book(title: "PDF", author: "Test", fileName: "a.pdf")
        let sut = PDFProgressRecorder(book: book, saver: saver, persist: { saves.increment() })

        sut.pageChanged(pageIndex: 3, pageCount: 10)
        saver.flush()
        #expect(saves.value == 1)
        debouncer.fire()
        #expect(saves.value == 1)
    }

    /// An empty PDF (pageCount == 0) has no position to record: the model is
    /// untouched and no save is scheduled.
    @Test func pdfZeroPageCountIsIgnored() {
        let saves = Counter()
        let debouncer = TestReaderProgressDebouncer()
        let saver = ReaderProgressSaver(flushDelay: 0.05, debouncer: debouncer)
        let book = Book(title: "PDF", author: "Test", fileName: "a.pdf")
        let locatorBefore = book.lastReadLocatorJSON
        let dateBefore = book.dateLastRead
        let sut = PDFProgressRecorder(book: book, saver: saver, persist: { saves.increment() })

        sut.pageChanged(pageIndex: 0, pageCount: 0)
        debouncer.fire()

        #expect(saves.value == 0)
        #expect(book.lastReadLocatorJSON == locatorBefore)
        #expect(book.dateLastRead == dateBefore)
    }

    @Test func pdfSinglePageHasFullProgression() {
        let saver = ReaderProgressSaver(flushDelay: 0.05, debouncer: TestReaderProgressDebouncer())
        let book = Book(title: "PDF", author: "Test", fileName: "a.pdf")
        let date = Date(timeIntervalSince1970: 42)
        let sut = PDFProgressRecorder(book: book, saver: saver, persist: {}, now: { date })

        sut.pageChanged(pageIndex: 0, pageCount: 1)
        #expect(book.progression == 1.0)
        #expect(book.dateLastRead == date)
    }
}

/// Minimal thread-safe counter for observing save invocations.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

@MainActor
private final class TestReaderProgressDebouncer: ReaderProgressDebouncing {
    private var pendingAction: (@MainActor () -> Void)?

    func schedule(after _: TimeInterval, action: @escaping @MainActor () -> Void) {
        pendingAction = action
    }

    /// Deliberately keeps `pendingAction`: a real debouncer can lose the race
    /// with an in-flight fire, so a late fire after cancel must be harmless on
    /// its own (the saver must not rely on cancel() to suppress it).
    func cancel() {}

    func fire() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}
