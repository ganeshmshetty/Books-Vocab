import SwiftUI

struct LinkReasonSheet: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dismiss) private var dismiss

    let link: KGCardLinkSummary
    let onNavigate: () -> Void
    var onHide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.sectionGap) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s2) {
                Image(systemName: "paperclip")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.tertiaryText)

                Text(link.label.localized)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }

            Text(link.word)
                .font(appSkin.typography.detailWord)
                .foregroundStyle(appSkin.palette.primaryText)

            CardSectionDivider(horizontalPadding: 0)

            Text(link.reason)
                .font(appSkin.typography.body)
                .foregroundStyle(appSkin.palette.secondaryText)
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: appSkin.spacing.inlineGap) {
                Button {
                    dismiss()
                    onNavigate()
                } label: {
                    HStack(spacing: 6) {
                        Text("查看詳情".localized)
                        Image(systemName: "arrow.up.right")
                            .font(appSkin.typography.iconTiny)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ghost(appSkin.palette.primaryText))

                if let onHide {
                    Button {
                        dismiss()
                        onHide()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(appSkin.typography.iconTiny)
                            Text("隱藏連結".localized)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ghost(appSkin.palette.destructive))
                }
            }
        }
        .padding(appSkin.metrics.cardBlockPadding)
        .vocabCanvasBackground()
        .enableInjection()
    }
}
