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

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            links = try await kgService.pullGraphLinks(notebookIDs: notebookIDs)
        } catch {
            errorMessage = SyncFailurePresentation.reason(for: error)
        }
    }
}
