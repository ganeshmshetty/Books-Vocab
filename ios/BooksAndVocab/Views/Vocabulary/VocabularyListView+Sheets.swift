//
//  VocabularyListView+Sheets.swift
//  Books & Vocab
//

import SwiftUI

struct VocabularyListSheets: ViewModifier {
    @Bindable var coordinator: VocabularyListCoordinator
    let allEntries: [VocabularyEntry]

    func body(content: Content) -> some View {
        content
            .toastSheet(isPresented: $coordinator.showSyncView) {
                SyncView()
            }
            .settingsSheet(isPresented: $coordinator.showSettings)
            .toastSheet(item: $coordinator.exportURL) { url in
                PlatformShareView(url: url)
                    .onDisappear { VocabularyExporter.cleanup(url) }
            }
    }
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
