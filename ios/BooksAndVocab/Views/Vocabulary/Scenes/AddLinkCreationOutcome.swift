import Foundation

/// Why a missing-target Add Link creation failed, classified from the backend
/// operation `error_code` (or from the client-side failure that ended polling).
///
/// `reason` is the raw code: the backend's own code for server failures, a
/// client code (`timed_out`, `operation_not_found`, `offline`,
/// `not_authenticated`) otherwise. It is what the durable record stores and what
/// `addLink.error.reason` exposes, so a restored failure classifies the same way.
struct AddLinkCreationFailure: Equatable {
    enum Kind: Equatable {
        case quotaExhausted
        case sourceUnavailable
        case targetArchived
        case targetIsSource
        case translationFailed
        case serviceUnavailable
        /// The server stopped before the operation ended (restart or shutdown).
        case interrupted
        /// The client gave up polling after `pollTimeoutNanoseconds`.
        case timedOut
        /// The server no longer knows the polled operation (HTTP 404).
        case operationNotFound
        case offline
        case notAuthenticated
        case generic
    }

    static let timedOutReason = "timed_out"
    static let operationNotFoundReason = "operation_not_found"
    static let sourceUnavailableReason = "source_unavailable"
    static let offlineReason = "offline"
    static let notAuthenticatedReason = "not_authenticated"
    static let unknownReason = "unknown"

    let reason: String

    init(reason: String?) {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reason = trimmed.isEmpty ? Self.unknownReason : trimmed
    }

    /// Failure that ended polling on the client side.
    init(error: Error) {
        guard let kgError = error as? KGError else {
            self.init(reason: Self.unknownReason)
            return
        }
        switch kgError {
        case .notAuthenticated, .unauthorized:
            self.init(reason: Self.notAuthenticatedReason)
        case .offline, .networkError:
            self.init(reason: Self.offlineReason)
        case .httpError(let statusCode, _) where statusCode == 404:
            self.init(reason: Self.operationNotFoundReason)
        default:
            self.init(reason: Self.unknownReason)
        }
    }

    var kind: Kind {
        switch reason {
        case "quota_exhausted": return .quotaExhausted
        case Self.sourceUnavailableReason: return .sourceUnavailable
        case "target_archived": return .targetArchived
        case "target_is_source": return .targetIsSource
        case "translation_failed": return .translationFailed
        // `cancelled` is the legacy code of interrupted operations.
        case "interrupted", "cancelled": return .interrupted
        case Self.timedOutReason: return .timedOut
        case Self.operationNotFoundReason: return .operationNotFound
        case Self.offlineReason: return .offline
        case Self.notAuthenticatedReason: return .notAuthenticated
        // `{step}_unavailable` (translate/create_card/enrich/create_link): a
        // dependency of that step was not found. `target_unavailable` is the
        // resolve step's catch-all and stays generic.
        case "target_unavailable": return .generic
        default:
            return reason.hasSuffix("_unavailable") ? .serviceUnavailable : .generic
        }
    }

    /// False when retrying cannot change the outcome: the user must act first
    /// (unarchive, pick another word, sign in) or the quota must reset.
    var isRetryable: Bool {
        switch kind {
        case .quotaExhausted, .sourceUnavailable, .targetArchived, .targetIsSource, .notAuthenticated:
            return false
        case .translationFailed, .serviceUnavailable, .interrupted, .timedOut,
             .operationNotFound, .offline, .generic:
            return true
        }
    }

    var message: String {
        switch kind {
        case .quotaExhausted: return L10n.string("addLink.error.quotaExhausted")
        case .sourceUnavailable: return L10n.string("addLink.error.sourceUnavailable")
        case .targetArchived: return L10n.string("addLink.error.targetArchived")
        case .targetIsSource: return L10n.string("addLink.error.targetIsSource")
        case .translationFailed: return L10n.string("翻譯暫時失敗")
        case .serviceUnavailable: return L10n.string("addLink.error.serviceUnavailable")
        case .interrupted: return L10n.string("addLink.error.interrupted")
        case .timedOut: return L10n.string("addLink.error.timedOut")
        case .operationNotFound: return L10n.string("addLink.error.operationNotFound")
        case .offline: return L10n.string("請確認網路連線後重試")
        case .notAuthenticated: return L10n.string("您的登入已過期，請重新登入")
        case .generic: return L10n.string("addLink.error.linkFailed")
        }
    }
}

/// A part of a succeeded creation that did not complete. The link exists on the
/// server; each warning names what is still missing so the user can retry it.
enum AddLinkCreationWarning: String, Equatable, CaseIterable {
    /// Server `enrichment_failed`: the new card has no generated explanation yet.
    case enrichmentIncomplete = "enrichment_failed"
    /// Server `link_projection_pending`: the link committed but its projection lagged.
    case linkProjectionPending = "link_projection_pending"
    /// Client: pulling the canonical card/graph into the local store failed.
    case localSyncIncomplete = "local_projection_failed"

    /// Known warnings in a stable order; unknown server codes are ignored.
    static func parse(_ rawValues: [String]) -> [AddLinkCreationWarning] {
        let known = Set(rawValues.compactMap(AddLinkCreationWarning.init(rawValue:)))
        return allCases.filter(known.contains)
    }

    var message: String {
        switch self {
        case .enrichmentIncomplete: return L10n.string("addLink.creation.warning.enrichment")
        case .linkProjectionPending: return L10n.string("addLink.creation.warning.linkProjection")
        case .localSyncIncomplete: return L10n.string("addLink.creation.warning.localSync")
        }
    }
}
