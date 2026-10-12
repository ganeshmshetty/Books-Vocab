import Foundation

/// Expansion state of the Add Link candidate list (#3111).
///
/// A tap on the row body only expands or collapses that row, and at most one row is open.
/// Linking and opening the card are explicit buttons on the row; they emit an effect for the
/// sheet to perform and never change which row is expanded (except that a query change resets it).
struct AddLinkRowDisclosure: Equatable {
    enum Action: Equatable {
        case toggleRow(UUID)
        case link(UUID)
        case openCard(UUID)
        case queryChanged
    }

    enum Effect: Equatable {
        case nothing
        case link(UUID)
        case openCard(UUID)
    }

    private(set) var expandedID: UUID?

    func isExpanded(_ id: UUID) -> Bool {
        expandedID == id
    }

    @discardableResult
    mutating func send(_ action: Action) -> Effect {
        switch action {
        case .toggleRow(let id):
            expandedID = expandedID == id ? nil : id
            return .nothing
        case .link(let id):
            return .link(id)
        case .openCard(let id):
            return .openCard(id)
        case .queryChanged:
            expandedID = nil
            return .nothing
        }
    }
}
