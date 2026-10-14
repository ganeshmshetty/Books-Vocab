import Foundation
import SwiftUI

@MainActor protocol KnowledgeGraphCoordinating: AnyObject, Observable {
    var isLoading: Bool { get }
    var errorMessage: String? { get }
    var isShowingSettings: Bool { get set }
    var links: [KGGraphLink] { get }
    var selectedEntry: VocabularyEntry? { get set }
    var centerForce: Double { get set }
    var repelForce: Double { get set }
    var linkForce: Double { get set }
    var linkDistance: Double { get set }
    var nodeSize: Double { get set }
    var linkThickness: Double { get set }
    var showsIsolatedNodes: Bool { get set }
    func toggleSettings()
    func resetForces()
    func handleNodeTap(_ nodeID: String, allEntries: [VocabularyEntry])
    func loadGraphData(authManager: any AuthManaging, kgService: any GraphServing, notebookIDs: [String]) async
}

@Observable @MainActor
final class KnowledgeGraphCoordinator: KnowledgeGraphCoordinating {
    var isLoading = false
    var errorMessage: String?
    var isShowingSettings = false
    var links: [KGGraphLink] = []
    var selectedEntry: VocabularyEntry?

    var centerForce: Double = 0.05
    var repelForce: Double = 0.20
    var linkForce: Double = 0.50
    var linkDistance: Double = 50
    var nodeSize: Double = 5.0
    var linkThickness: Double = 1.0
    var showsIsolatedNodes: Bool = false

    @ObservationIgnored private var loadGeneration = 0

    init(links: [KGGraphLink] = []) {
        self.links = links
    }

    func toggleSettings() {
        withAnimation(AppMotion.panelState) {
            isShowingSettings.toggle()
        }
    }

    func resetForces() {
        centerForce = 0.05
        repelForce = 0.20
        linkForce = 0.50
        linkDistance = 50
        nodeSize = 5.0
        linkThickness = 1.0
    }

    func handleNodeTap(_ nodeID: String, allEntries: [VocabularyEntry]) {
        selectedEntry = allEntries.first { $0.kgCardId == nodeID }
    }

    func loadGraphData(
        authManager: any AuthManaging,
        kgService: any GraphServing,
        notebookIDs: [String]
    ) async {
        guard authManager.isLoggedIn else { return }

        // Demo mode uses bundled graph links — no API call
        if authManager.isDemoMode {
            links = DemoDataProvider.demoGraphLinks
            return
        }

        // `.task(id:)` 會取消並取代前一個 run；只有最新一次 run 可以寫入 links／errorMessage／isLoading，
        // 被取代 run 的 CancellationError 不得蓋過最新 run 的狀態（#3818）。
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let fetched = try await kgService.pullGraphLinks(notebookIDs: notebookIDs)
            guard generation == loadGeneration else { return }
            links = fetched
            errorMessage = nil
        } catch is CancellationError {
            // 被取代或被取消：狀態由最新 run 決定，這裡不呈現錯誤。
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = SyncFailurePresentation.reason(for: error)
        }
    }
}
