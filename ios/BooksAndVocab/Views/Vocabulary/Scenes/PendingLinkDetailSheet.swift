import SwiftUI

/// Detail for a link whose target card is still being created in the
/// background. It shows whatever the job knows so far (the word, the current
/// pipeline step) and fills in as the operation progresses; it dismisses itself
/// when the job completes and the item becomes a normal link. A failed job
/// keeps its retry (when retryable) and remove actions here; a partial
/// (warning) result lists what did not complete, with retry and done.
struct PendingLinkDetailSheet: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dismiss) private var dismiss

    let link: KGCardLinkSummary
    var hub: AddLinkCreationHub = .shared

    private var jobKey: String? { link.pendingCreationJobKey }
    private var job: AddLinkCreationHub.Job? { jobKey.flatMap { hub.job(forJobKey: $0) } }
    private var isFailed: Bool { job?.record.state == .failed }
    private var isWarning: Bool { job?.record.state == .warning }
    private var isGone: Bool { job == nil }
    private var isRetryingWarnings: Bool { job?.coordinator?.isRetryingWarnings == true }
    /// A failure the user must fix first (archived target, quota…) offers no retry.
    private var canRetry: Bool {
        if isWarning { return !isRetryingWarnings }
        return isFailed && job?.record.failure?.isRetryable != false
    }
    private var warnings: [AddLinkCreationWarning] {
        AddLinkCreationWarning.parse(job?.record.warnings ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.sectionGap) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s2) {
                Image(systemName: "paperclip")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                Text(L10n.string(link.label))
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }

            Text(link.word)
                .font(appSkin.typography.detailWord)
                .foregroundStyle(appSkin.palette.primaryText)

            CardSectionDivider(horizontalPadding: 0)

            statusBlock

            if let coordinator = job?.coordinator, !isFailed, !isWarning || isRetryingWarnings {
                SettingsSyncProgressPanel(steps: coordinator.steps, fraction: coordinator.fraction)
            }

            Spacer()

            if isFailed || isWarning, let jobKey {
                VStack(spacing: appSkin.spacing.inlineGap) {
                    if canRetry || isRetryingWarnings {
                        Button {
                            hub.retry(jobKey: jobKey)
                        } label: {
                            Text(L10n.string("重試")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.ghost(appSkin.palette.primaryText))
                        .disabled(!canRetry)
                        .accessibilityIdentifier("todayReview.card.link.pending.retry")
                    }

                    Button {
                        hub.dismiss(jobKey: jobKey)
                        dismiss()
                    } label: {
                        Text(isWarning ? L10n.string("完成") : L10n.string("移除")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ghost(isWarning ? appSkin.palette.primaryText : appSkin.palette.destructive))
                    .accessibilityIdentifier("todayReview.card.link.pending.dismiss")
                }
            }
        }
        .padding(appSkin.metrics.cardBlockPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todayReview.card.link.pending.detail")
        .vocabCanvasBackground()
        .onChange(of: isGone) { _, gone in
            // Completed: the pending item has become a real link behind this sheet.
            if gone { dismiss() }
        }
        .enableInjection()
    }

    @ViewBuilder
    private var statusBlock: some View {
        if isWarning {
            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                Text(L10n.string("addLink.creation.warning.summary"))
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(warnings, id: \.self) { warning in
                    Text(warning.message)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(PendingLinkStatusKind.warning.accessibilityIdentifier)
        } else if isFailed {
            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                Text(L10n.string("todayReview.link.pending.failed"))
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = job?.record.message, !message.isEmpty {
                    Text(message)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(PendingLinkStatusKind.failed.accessibilityIdentifier)
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                Text(L10n.string("todayReview.link.pending.creating"))
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.primaryText)
                Text(L10n.string("todayReview.link.pending.hint"))
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(PendingLinkStatusKind.creating.accessibilityIdentifier)
        }
    }
}

/// Creation state shown by `PendingLinkDetailSheet`'s status block. The state
/// is carried by the accessibility identifier, not by an accessibility value,
/// so no raw English token reaches VoiceOver or UI tests (#3425).
enum PendingLinkStatusKind: String, CaseIterable {
    case warning
    case failed
    case creating

    var accessibilityIdentifier: String {
        "todayReview.card.link.pending.status.\(rawValue)"
    }
}
