import SwiftData
import Testing
@testable import BooksAndVocab

@Suite("Graph link coordinator", .serialized)
struct AddLinkCoordinatorTests {
    @Test("local candidates stay notebook-scoped and exclude self/already-linked")
    func localCandidates() {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let match = Self.entry("lucid", cardID: "target", notebook: "nb")
        let otherNotebook = Self.entry("lucidity", cardID: "other", notebook: "other")
        let linked = Self.entry("lucidly", cardID: "linked", notebook: "nb")
        source.graphLinksByKind = ["related": [
            KGCardLinkSummary(
                id: "link", cardId: "linked", word: "lucidly", kind: "related",
                label: "related", confidence: 1, reason: ""
            )
        ]]

        let result = AddLinkCoordinator.localCandidates(
            query: "lucid",
            sourceEntry: source,
            allEntries: [source, match, otherNotebook, linked]
        )

        #expect(result.map(\.word) == ["lucid"])
    }

    @Test("local candidates exclude entries with an empty card id")
    func localCandidatesExcludeEmptyCardID() {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let unresolved = Self.entry("lucid", cardID: "", notebook: "nb")

        let result = AddLinkCoordinator.localCandidates(
            query: "lucid",
            sourceEntry: source,
            allEntries: [source, unresolved]
        )

        #expect(result.isEmpty)
    }

    @Test("local candidates exclude archived, deleting, whitespace-card, and other-notebook entries")
    func localCandidatesExcludeIneligibleEntries() {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let match = Self.entry("lucid", cardID: "target", notebook: "nb")
        let archived = Self.entry("lucid archive", cardID: "archived", notebook: "nb")
        archived.isArchived = true
        let deleting = Self.entry("lucid delete", cardID: "deleting", notebook: "nb")
        deleting.syncAction = .delete
        let whitespaceCard = Self.entry("lucid unresolved", cardID: "   ", notebook: "nb")
        let otherNotebook = Self.entry("lucid other", cardID: "other", notebook: "other")
        let linked = Self.entry("lucid linked", cardID: "linked", notebook: "nb")
        source.graphLinksByKind = ["related": [
            KGCardLinkSummary(
                id: "link", cardId: "linked", word: linked.word, kind: "related",
                label: "related", confidence: 1, reason: ""
            )
        ]]

        let result = AddLinkCoordinator.localCandidates(
            query: "lucid",
            sourceEntry: source,
            allEntries: [source, match, archived, deleting, whitespaceCard, otherNotebook, linked]
        )

        #expect(result.map(\.word) == ["lucid"])
    }

    @Test("local candidates keep exact-first then store order on a mixed CJK/Latin fixture, cold or warm")
    func localCandidatesOrderingIsPinned() {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        var all: [VocabularyEntry] = [source]
        // 30 partial matches of "run" in store order: CJK word + English translation,
        // accented Latin word, plain Latin word.
        var partialWords: [String] = []
        for i in 0..<30 {
            let word: String
            let translation: String
            switch i % 3 {
            case 0: (word, translation) = ("跑\(i)", "to RUN \(i)")
            case 1: (word, translation) = ("Rùn\(i)", "x")
            default: (word, translation) = ("running\(i)", "y")
            }
            partialWords.append(word)
            all.append(Self.entry(word, translation: translation, cardID: "p\(i)", notebook: "nb"))
        }
        all.append(Self.entry("walk", cardID: "walk", notebook: "nb"))
        all.append(Self.entry("run", cardID: "exact1", notebook: "nb"))
        all.append(Self.entry("RUN.", cardID: "exact2", notebook: "nb"))

        let expected = ["run", "RUN."] + Array(partialWords.prefix(AddLinkCoordinator.candidateLimit - 2))

        let cold = AddLinkCoordinator.localCandidates(query: "run", sourceEntry: source, allEntries: all)
        #expect(cold.map(\.word) == expected)

        let index = AddLinkSearchIndex()
        for _ in 0..<2 {
            let warm = AddLinkCoordinator.localCandidates(
                query: "run", sourceEntry: source, allEntries: all, index: index
            )
            #expect(warm.map(\.word) == expected)
        }
        #expect(
            Self.referenceCandidates(query: "run", sourceEntry: source, allEntries: all).map(\.word) == expected,
            "the pinned order must equal the pre-#2406 implementation"
        )

        let cjk = AddLinkCoordinator.localCandidates(
            query: "跑", sourceEntry: source, allEntries: all, index: index
        )
        #expect(cjk.map(\.word) == partialWords.enumerated().filter { $0.offset % 3 == 0 }.map(\.element))
    }

    @Test("a shared search index never serves a stale key after word or translation edits")
    func searchIndexInvalidatesOnEdit() {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("alpha", translation: "first", cardID: "t", notebook: "nb")
        let index = AddLinkSearchIndex()
        func words(_ query: String) -> [String] {
            AddLinkCoordinator.localCandidates(
                query: query, sourceEntry: source, allEntries: [source, target], index: index
            ).map(\.word)
        }

        #expect(words("alpha") == ["alpha"])
        target.word = "beta"
        #expect(words("alpha").isEmpty)
        #expect(words("beta") == ["beta"])
        target.translation = "Café"
        #expect(words("cafe") == ["beta"])
        target.translation = "other"
        #expect(words("cafe").isEmpty)
    }

    @Test("local candidates baseline: worst-case search p95 per store size", arguments: [500, 2000, 5000])
    func localCandidatesPerformanceBaseline(count: Int) {
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        var all: [VocabularyEntry] = [source]
        for i in 0..<count {
            all.append(Self.entry(
                i % 7 == 0 ? "Café\(i)" : "word\(i)",
                translation: i % 3 == 0 ? "翻譯項目\(i)" : "tr\(i) Ünï",
                cardID: "c\(i)",
                notebook: "nb"
            ))
        }
        // Worst case: nothing matches, so every entry has to be examined.
        let query = "zzq"
        let runs = 50
        let index = AddLinkSearchIndex()
        let cold = AddLinkCoordinator.localCandidates(query: query, sourceEntry: source, allEntries: all, index: index)
        #expect(cold.isEmpty)

        func legacyCount() -> Int {
            Self.referenceCandidates(query: query, sourceEntry: source, allEntries: all).count
        }
        func warmCount() -> Int {
            AddLinkCoordinator.localCandidates(
                query: query, sourceEntry: source, allEntries: all, index: index
            ).count
        }
        func milliseconds(_ elapsed: Duration) -> Double {
            Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        func percentile(_ samples: [Double], _ fraction: Double) -> Double {
            samples.sorted()[Int((Double(samples.count) * fraction).rounded(.up)) - 1]
        }

        // Legacy and warm are timed back to back inside every iteration (alternating which goes
        // first), so a load spike from the suites running in parallel on a shared runner lands on
        // both sides of the same pair. Comparing two independently measured p95 tails flipped on
        // CI (warm 54 ms vs legacy 47 ms at N=2000) although the cache is faster in the typical
        // case: the per-entry SwiftData property reads that the cache cannot remove dominate a
        // Debug build, so the real advantage is only ~20-35% (macOS Debug micro-benchmark with a
        // model stand-in, idle and CPU-contended), well inside tail noise.
        let clock = ContinuousClock()
        var legacySamples: [Double] = []
        var warmSamples: [Double] = []
        var ratios: [Double] = []
        var sink = 0
        for run in 0..<runs {
            let legacyElapsed: Duration
            let warmElapsed: Duration
            if run.isMultiple(of: 2) {
                legacyElapsed = clock.measure { sink &+= legacyCount() }
                warmElapsed = clock.measure { sink &+= warmCount() }
            } else {
                warmElapsed = clock.measure { sink &+= warmCount() }
                legacyElapsed = clock.measure { sink &+= legacyCount() }
            }
            legacySamples.append(milliseconds(legacyElapsed))
            warmSamples.append(milliseconds(warmElapsed))
            ratios.append(milliseconds(warmElapsed) / milliseconds(legacyElapsed))
        }
        #expect(sink == 0, "the worst-case query must match nothing")

        let legacy = percentile(legacySamples, 0.95)
        let warm = percentile(warmSamples, 0.95)
        let warmMedian = percentile(warmSamples, 0.5)
        let medianRatio = percentile(ratios, 0.5)
        print("PERF addLink.localCandidates N=\(count) p95 legacy=\(String(format: "%.2f", legacy))ms warm=\(String(format: "%.2f", warm))ms warm/legacy median=\(String(format: "%.2f", medianRatio))")

        // The absolute budget is generous (CI simulators are slow and noisy); it only catches a regression
        // back to per-keystroke folding of the whole store, which measured ~70 ms at N=5000. It applies to
        // the median: a 50-run p95 is the third-worst sample, so a few preempted runs fail it by themselves.
        #expect(warmMedian < 100, "warm median \(warmMedian)ms (p95 \(warm)ms) at N=\(count)")
        // The relative claim is about the typical query, so it uses the median of the paired ratios.
        #expect(
            medianRatio < 1,
            "the cached search must beat the uncached scan (median warm/legacy \(medianRatio); p95 warm \(warm)ms, legacy \(legacy)ms)"
        )
    }

    @Test("AddLink lookup exposes deterministic idle, result, empty, loading, error, and retry states")
    func lookupStateMatrix() {
        #expect(
            AddLinkCoordinator.lookupState(
                query: "   ", candidateCount: 0, creationPhase: .idle, creationAttempt: 0
            ) == .idle
        )
        #expect(
            AddLinkCoordinator.lookupState(
                query: "fort", candidateCount: 2, creationPhase: .idle, creationAttempt: 0
            ) == .results(count: 2)
        )
        #expect(
            AddLinkCoordinator.lookupState(
                query: "zzqxv", candidateCount: 0, creationPhase: .idle, creationAttempt: 0
            ) == .empty
        )
        #expect(
            AddLinkCoordinator.lookupState(
                query: "zzqxv", candidateCount: 0, creationPhase: .running, creationAttempt: 1
            ) == .loading(attempt: 1)
        )
        #expect(
            AddLinkCoordinator.lookupState(
                query: "zzqxv", candidateCount: 0, creationPhase: .failed, creationAttempt: 1
            ) == .error(attempt: 1)
        )
        #expect(
            AddLinkCoordinator.lookupState(
                query: "zzqxv", candidateCount: 0, creationPhase: .running, creationAttempt: 2
            ) == .retry(attempt: 2)
        )
    }

    @Test("collapsed row value names only the visible first sense and verdict, never hidden examples or provenance")
    func collapsedRowValueOmitsHiddenDetail() {
        let entry = Self.entry("fortuitous", cardID: "target", notebook: "nb")
        entry.translation = "偶然發生而幸運的"
        entry.explanation = #"kg.dictionary.detail.v1:{"provider":"free_dictionary","senses":[{"definition":"Happening by chance, usually with a favorable result.","partOfSpeech":"adj.","translation":"偶然發生而幸運的","examples":["The fortuitous meeting changed the project’s direction."]},{"definition":"Occurring unexpectedly.","partOfSpeech":"adj.","translation":"意外的","examples":["A fortuitous delay gave time to think."]}]}"#
        entry.rootForm = "fortuitous"
        entry.inflections = ["fortuitously", "fortuitousness"]
        entry.bookTitle = "The Weight of Words"
        entry.chapterTitle = "Linked Cards"
        entry.context = "A fortuitous delay gave time to think."

        let collapsed = AddLinkCoordinator.candidateProjection(for: entry, isExpanded: false)
        let value = AddLinkCoordinator.rowAccessibilityValue(for: entry, detail: collapsed)

        #expect(value.contains("word=fortuitous"))
        #expect(value.contains("translation=偶然發生而幸運的"))
        #expect(value.contains("sense=Happening by chance, usually with a favorable result."))
        #expect(value.contains("detail.state=ready-senses-2"))
        #expect(!value.contains("example="))
        #expect(!value.contains("The fortuitous meeting"))
        #expect(!value.contains("Occurring unexpectedly"))
        #expect(!value.contains("fortuitousness"))
        #expect(!value.contains("The Weight of Words"))
        #expect(!value.contains("Linked Cards"))
        #expect(!value.contains("A fortuitous delay gave time to think."))
    }

    @Test("dictionary detail projection keeps every sense, example, form, and provenance level")
    func dictionaryDetailProjectionPreservesHierarchy() throws {
        let entry = Self.entry("fortuitous", cardID: "target", notebook: "nb")
        entry.translation = "偶然發生而幸運的"
        entry.explanation = #"kg.dictionary.detail.v1:{"provider":"free_dictionary","senses":[{"definition":"Happening by chance, usually with a favorable result.","partOfSpeech":"adj.","translation":"偶然發生而幸運的","examples":["The fortuitous meeting changed the project's direction, preserving the complete first example."]},{"definition":"Occurring unexpectedly in a way that brings an advantage, with the long second sense still intact.","partOfSpeech":"adj.","translation":"意外而有利的","examples":["A fortuitous delay gave the researcher enough time to notice the pattern."]}]}"#
        entry.rootForm = "fortuitous"
        entry.inflections = ["fortuitously", "fortuitousness"]
        entry.bookTitle = "The Weight of Words"
        entry.chapterTitle = "Linked Cards"
        entry.context = "A fortuitous delay gave the researcher time to notice the pattern."

        let projection = AddLinkCoordinator.dictionaryDetailProjection(for: entry)

        #expect(projection.state == .ready(senseCount: 2))
        #expect(projection.senses.count == 2)
        #expect(projection.senses[0].definition.contains("Happening by chance"))
        #expect(projection.senses[1].definition.contains("long second sense still intact"))
        #expect(projection.senses[0].examples == ["The fortuitous meeting changed the project's direction, preserving the complete first example."])
        #expect(projection.forms == ["fortuitous", "fortuitously", "fortuitousness"])
        #expect(projection.provenance.source == "The Weight of Words")
        #expect(projection.provenance.chapter == "Linked Cards")
        #expect(projection.provenance.context == entry.context)

        #expect(projection.senses[1].examples == ["A fortuitous delay gave the researcher enough time to notice the pattern."])
    }

    @Test("compact candidate projection keeps only the first sense while the state still counts every sense")
    func compactDetailProjectionKeepsFirstSenseOnly() {
        let entry = Self.entry("fortuitous", cardID: "target", notebook: "nb")
        entry.translation = "偶然發生而幸運的"
        entry.explanation = #"kg.dictionary.detail.v1:{"provider":"free_dictionary","senses":[{"definition":"Happening by chance.","partOfSpeech":"adj.","examples":["First example."]},{"definition":"Second sense.","partOfSpeech":"adj.","examples":["Second example."]}]}"#
        entry.bookTitle = "The Weight of Words"

        let compact = AddLinkCoordinator.compactDetailProjection(for: entry)
        let full = AddLinkCoordinator.dictionaryDetailProjection(for: entry)

        #expect(compact.senses.map(\.definition) == ["Happening by chance."])
        #expect(compact.senses[0].examples == ["First example."])
        #expect(compact.state == .ready(senseCount: 2))
        #expect(full.senses.count == 2)
        #expect(full.state == compact.state)
        let value = AddLinkCoordinator.rowAccessibilityValue(for: entry, detail: compact)
        #expect(value.contains("sense=Happening by chance."))
        #expect(!value.contains("First example."))
        #expect(!value.contains("Second sense."))
        #expect(!value.contains("Second example."))
    }

    @Test("compact evidence reports a missing example that sits beyond the first sense")
    func compactEvidenceMissingExampleBeyondFirstSense() {
        let entry = Self.entry("fortuitous", cardID: "target", notebook: "nb")
        entry.translation = "偶然發生而幸運的"
        entry.explanation = #"kg.dictionary.detail.v1:{"provider":"free_dictionary","senses":[{"definition":"Happening by chance.","partOfSpeech":"adj.","examples":["First example."]},{"definition":"Second sense.","partOfSpeech":"adj.","examples":[]}]}"#

        let compact = AddLinkCoordinator.compactDetailProjection(for: entry)
        let value = AddLinkCoordinator.rowAccessibilityValue(for: entry, detail: compact)

        #expect(compact.state == .missingExample(senseCount: 2))
        #expect(value.contains("detail.state=missing-example-senses-2"))
        #expect(!value.contains("First example."))
    }

    @Test("collapsed candidate row projects only the compact first sense, expanded row the full projection")
    func candidateProjectionSelectsCompactUntilExpanded() {
        let entry = Self.entry("fortuitous", cardID: "target", notebook: "nb")
        entry.translation = "偶然發生而幸運的"
        entry.explanation = #"kg.dictionary.detail.v1:{"provider":"free_dictionary","senses":[{"definition":"Happening by chance.","partOfSpeech":"adj.","examples":["First example."]},{"definition":"Second sense.","partOfSpeech":"adj.","examples":["Second example."]}]}"#

        let collapsed = AddLinkCoordinator.candidateProjection(for: entry, isExpanded: false)
        let expanded = AddLinkCoordinator.candidateProjection(for: entry, isExpanded: true)

        #expect(collapsed == AddLinkCoordinator.compactDetailProjection(for: entry))
        #expect(collapsed.senses.count == 1)
        #expect(expanded == AddLinkCoordinator.dictionaryDetailProjection(for: entry))
        #expect(expanded.senses.count == 2)
    }

    @Test("dictionary detail projection makes an absent explicit example observable")
    func dictionaryDetailProjectionMissingExample() {
        let entry = Self.entry("fortunate", cardID: "target", notebook: "nb")
        entry.translation = "幸運的；有利的"
        entry.explanation = "Favored by luck or resulting in a good outcome."
        entry.context = "It was fortunate that the note survived in the old copy."
        entry.reviewExamples = []

        let projection = AddLinkCoordinator.dictionaryDetailProjection(for: entry)

        #expect(projection.state == .missingExample(senseCount: 1))
        #expect(projection.senses.count == 1)
        #expect(projection.senses[0].examples.isEmpty)
        let value = AddLinkCoordinator.rowAccessibilityValue(
            for: entry,
            detail: AddLinkCoordinator.candidateProjection(for: entry, isExpanded: false)
        )
        #expect(value.contains("detail.state=missing-example-senses-1"))
        #expect(!value.contains("It was fortunate"))
    }

    @Test("provider decode error is retryable through a deterministic local recovery")
    func dictionaryDetailProjectionProviderDecodeErrorRecovers() {
        let entry = Self.entry("revelation", cardID: "target", notebook: "nb")
        entry.translation = "揭示；驚人的新發現"
        entry.explanation = "kg.dictionary.detail.v1:{malformed"
        entry.reviewExamples = ["The archive produced one quiet revelation after another."]
        entry.rootForm = "revelation"
        entry.inflections = ["reveal", "revealed"]

        let failed = AddLinkCoordinator.dictionaryDetailProjection(for: entry)
        #expect(failed.state == .providerDecodeError)
        #expect(failed.senses.isEmpty)

        let recovered = AddLinkCoordinator.dictionaryDetailProjection(
            for: entry,
            recoveringProviderError: true
        )
        #expect(recovered.state == .recovered(senseCount: 1))
        #expect(recovered.senses.first?.definition == entry.translation)
        #expect(recovered.senses.first?.examples == entry.reviewExamples)
        #expect(recovered.forms == ["revelation", "reveal", "revealed"])
        #expect(AddLinkCoordinator.detailStateIdentifier(for: entry) == "addLink.local.result.target.state")
        #expect(AddLinkCoordinator.detailRetryIdentifier(for: entry) == "addLink.local.result.target.provider.retry")
    }

    @Test("manual link rejects an out-of-scope target before creating a link")
    @MainActor
    func manualLinkRejectsOutOfScopeTarget() async throws {
        let container = try Self.container()
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("target", cardID: "target", notebook: "other")
        let context = ModelContext(container)
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = RecordingGraphService()
        let coordinator = AddLinkCoordinator()
        await coordinator.linkExisting(target: target, sourceEntry: source, using: service)

        #expect(coordinator.actionPhase == .failed)
        #expect(service.createCallCount == 0)
        #expect(source.graphLinksByKind.isEmpty)
    }

    @Test("manual link validation surfaces missing source and treats duplicate as already linked")
    @MainActor
    func manualLinkValidation() async throws {
        let container = try Self.container()
        let target = Self.entry("target", cardID: "target", notebook: "nb")
        let missingSource = Self.entry("source", cardID: "source", notebook: "nb")
        missingSource.kgCardId = nil
        let duplicateSource = Self.entry("source", cardID: "source", notebook: "nb")
        let context = ModelContext(container)
        context.insert(target)
        context.insert(missingSource)
        context.insert(duplicateSource)
        try context.save()

        let missingSourceCoordinator = AddLinkCoordinator()
        await missingSourceCoordinator.linkExisting(
            target: target,
            sourceEntry: missingSource,
            using: StaleProjectionGraphService()
        )
        #expect(missingSourceCoordinator.actionPhase == .failed)
        #expect(missingSourceCoordinator.actionError == .missingSourceCard)

        duplicateSource.insertLink(
            KGCardLinkSummary(
                id: "existing-link", cardId: "target", word: target.word,
                kind: "related", label: "related", confidence: 1, reason: "existing"
            ),
            kind: "related"
        )
        let duplicateCoordinator = AddLinkCoordinator()
        await duplicateCoordinator.linkExisting(
            target: target,
            sourceEntry: duplicateSource,
            using: StaleProjectionGraphService()
        )
        #expect(duplicateCoordinator.actionPhase == .succeeded)
        #expect(duplicateCoordinator.actionError == nil)
        #expect(duplicateSource.graphLinksByKind.values.flatMap { $0 }.count == 1)
    }

    @Test("manual link 409 refreshes graph projection and converges to success")
    @MainActor
    func manualLinkConflictRefreshesProjection() async throws {
        let container = try Self.container()
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("target", cardID: "target", notebook: "nb")
        let context = ModelContext(container)
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = StaleProjectionGraphService()
        let coordinator = AddLinkCoordinator()
        await coordinator.linkExisting(
            target: target,
            sourceEntry: source,
            using: service
        )

        #expect(coordinator.actionPhase == .succeeded)
        #expect(coordinator.actionError == nil)
        let link = try #require(source.graphLinksByKind["shares_usage"]?.first)
        #expect(link.id == "server-link")
        #expect(link.cardId == "target")
        #expect(await service.pullNotebookIDs == ["nb"])
    }

    @Test("manual link 409 without matching projection stays failed and rolls back")
    @MainActor
    func manualLinkConflictWithoutProjectionFailsClosed() async throws {
        let container = try Self.container()
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("target", cardID: "target", notebook: "nb")
        let context = ModelContext(container)
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = StaleProjectionGraphService(links: [])
        let coordinator = AddLinkCoordinator()
        await coordinator.linkExisting(
            target: target,
            sourceEntry: source,
            using: service
        )

        #expect(coordinator.actionPhase == .failed)
        #expect(coordinator.actionError == .existingLinkRefreshFailed)
        #expect(source.graphLinksByKind.isEmpty)
        #expect(await service.pullNotebookIDs == ["nb"])
    }

    @Test("failed manual link rolls back and supports a retry")
    @MainActor
    func manualLinkFailureCanRetry() async throws {
        let container = try Self.container()
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("target", cardID: "target", notebook: "nb")
        let context = ModelContext(container)
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = RetryableGraphService()
        let coordinator = AddLinkCoordinator()
        await coordinator.linkExisting(target: target, sourceEntry: source, using: service)

        #expect(coordinator.actionPhase == .failed)
        #expect(coordinator.actionError == .existingLinkFailed)
        #expect(source.graphLinksByKind.isEmpty)

        await coordinator.linkExisting(target: target, sourceEntry: source, using: service)

        #expect(coordinator.actionPhase == .succeeded)
        #expect(coordinator.actionError == nil)
        #expect(service.createCallCount == 2)
        #expect(source.graphLinksByKind.values.flatMap { $0 }.count == 1)
    }

    @Test("manual link exposes linking and cancelled outcomes without committing")
    @MainActor
    func manualLinkCanBeCancelled() async throws {
        let container = try Self.container()
        let source = Self.entry("source", cardID: "source", notebook: "nb")
        let target = Self.entry("target", cardID: "target", notebook: "nb")
        let context = ModelContext(container)
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = BlockingGraphService()
        let coordinator = AddLinkCoordinator()
        #expect(coordinator.actionPhase == .idle)

        let task = coordinator.startLinkExisting(target: target, sourceEntry: source, using: service)
        #expect(coordinator.actionPhase == .linking)
        while !service.hasStarted {
            await Task.yield()
        }

        // Precondition (#2196): the optimistic placeholder IS projected while linking, so the
        // post-cancel emptiness assertions below cannot pass vacuously.
        let pendingLinks = source.graphLinksByKind.values.flatMap { $0 }
        #expect(pendingLinks.map(\.cardId) == ["target"])
        #expect(pendingLinks.allSatisfy { $0.id.hasPrefix("pending-") })

        coordinator.cancel()
        #expect(coordinator.actionPhase == .cancelled)
        // The projection must be clean the moment `.cancelled` is observable: cancel() must not
        // leave the placeholder to a cancelled task that may wake up arbitrarily late (#2196).
        #expect(source.graphLinksByKind.isEmpty)

        service.resume()
        // Await the cancelled task's teardown instead of guessing a number of Task.yield() hops.
        await task.value

        #expect(coordinator.actionPhase == .cancelled)
        #expect(source.graphLinksByKind.isEmpty)
    }

    /// The pre-#2406 implementation, kept verbatim as the ordering/semantics oracle.
    private static func referenceCandidates(
        query: String,
        sourceEntry: VocabularyEntry,
        allEntries: [VocabularyEntry]
    ) -> [VocabularyEntry] {
        let trimmed = AddLinkCreationCoordinator.cleanedQuery(query)
        guard !trimmed.isEmpty else { return [] }
        let linkedIDs = Set(sourceEntry.graphLinksByKind.values.flatMap { $0 }.map(\.cardId))
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let folded = trimmed.folding(options: options, locale: .current)
        let typed = AddLinkCreationCoordinator.normalizeWord(trimmed)
        var exact: [VocabularyEntry] = []
        var partial: [VocabularyEntry] = []
        for entry in allEntries {
            guard entry.id != sourceEntry.id,
                  entry.notebookId == sourceEntry.notebookId,
                  entry.kgCardId != sourceEntry.kgCardId,
                  !entry.isArchived,
                  entry.syncAction != .delete,
                  !(entry.kgCardId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                  !(entry.kgCardId.map(linkedIDs.contains) ?? false),
                  entry.word.folding(options: options, locale: .current).contains(folded)
                      || entry.translation.folding(options: options, locale: .current).contains(folded)
            else { continue }
            if AddLinkCreationCoordinator.normalizeWord(entry.word) == typed {
                exact.append(entry)
            } else if partial.count < AddLinkCoordinator.candidateLimit {
                partial.append(entry)
            }
        }
        return Array((exact + partial).prefix(AddLinkCoordinator.candidateLimit))
    }

    private static func entry(
        _ word: String,
        translation: String? = nil,
        cardID: String,
        notebook: String
    ) -> VocabularyEntry {
        let value = VocabularyEntry(
            word: word,
            translation: translation ?? word,
            context: "",
            bookTitle: "Book"
        )
        value.kgCardId = cardID
        value.notebookId = notebook
        return value
    }

    private static func container() throws -> ModelContainer {
        let schema = Schema([VocabularyEntry.self, ReviewRecord.self])
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

@MainActor
private final class StaleProjectionGraphService: GraphServing {
    private let links: [KGGraphLink]
    private(set) var pullNotebookIDs: [String] = []

    init(links: [KGGraphLink]? = nil) {
        self.links = links ?? [
            KGGraphLink(
                id: "server-link",
                fromId: "source",
                toId: "target",
                kind: "shares_usage",
                confidence: 1,
                reason: "existing"
            )
        ]
    }

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] {
        pullNotebookIDs.append(notebookId)
        return links
    }

    func createManualLink(
        fromId: String,
        toId: String,
        notebookId: String
    ) async throws -> KGGraphLink {
        throw KGError.httpError(
            statusCode: 409,
            detail: "Link already exists between these cards"
        )
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}

@MainActor
private final class RecordingGraphService: GraphServing {
    private(set) var createCallCount = 0

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] { [] }

    func createManualLink(
        fromId: String,
        toId: String,
        notebookId: String
    ) async throws -> KGGraphLink {
        createCallCount += 1
        return KGGraphLink(
            id: "created-link",
            fromId: fromId,
            toId: toId,
            kind: "related",
            confidence: 1,
            reason: "created"
        )
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}

@MainActor
private final class RetryableGraphService: GraphServing {
    private(set) var createCallCount = 0

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] { [] }

    func createManualLink(
        fromId: String,
        toId: String,
        notebookId: String
    ) async throws -> KGGraphLink {
        createCallCount += 1
        if createCallCount == 1 {
            throw KGError.serverError("temporary link failure")
        }
        return KGGraphLink(
            id: "retry-link",
            fromId: fromId,
            toId: toId,
            kind: "related",
            confidence: 1,
            reason: "retry succeeded"
        )
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}

@MainActor
private final class BlockingGraphService: GraphServing {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<KGGraphLink, Never>?

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] { [] }

    func createManualLink(
        fromId: String,
        toId: String,
        notebookId: String
    ) async throws -> KGGraphLink {
        hasStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume(returning: KGGraphLink(
            id: "cancelled-link",
            fromId: "source",
            toId: "target",
            kind: "related",
            confidence: 1,
            reason: "should not commit"
        ))
        continuation = nil
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}
