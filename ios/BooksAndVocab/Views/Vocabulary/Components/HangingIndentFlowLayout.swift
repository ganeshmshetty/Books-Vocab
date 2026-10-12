import SwiftUI

/// 列首標籤加上可換行的項目流（#3114）。第一個子視圖是標籤；其後的項目接在標籤右側，
/// 超出寬度時換行，且每一行都從「標籤寬 + spacing」的同一欄開始。收合與展開的連結區
/// 共用此佈局，所以展開後的第一顆與換行後的連結 minX 一致。
///
/// 與 `CollocationFlowLayout` 分開：後者仍服務單字詳情，不因連結區改版而改動。
struct HangingIndentFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = HangingIndentFlow.place(sizes: sizes, spacing: spacing, maxWidth: proposal.width)
        return CGSize(width: proposal.width ?? result.contentWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = HangingIndentFlow.place(sizes: sizes, spacing: spacing, maxWidth: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// 純幾何版本的 `HangingIndentFlowLayout`：只吃子視圖尺寸、回傳位置，可單元測試。
enum HangingIndentFlow {
    struct Result: Equatable {
        /// 與輸入 `sizes` 同序；第 0 個是標籤。
        let frames: [CGRect]
        let contentWidth: CGFloat
        let height: CGFloat
    }

    static func place(sizes: [CGSize], spacing: CGFloat, maxWidth: CGFloat?) -> Result {
        guard let label = sizes.first else {
            return Result(frames: [], contentWidth: 0, height: 0)
        }
        let limit = maxWidth ?? .infinity
        // 懸掛縮排：第一行與之後每一行的項目都從這個 x 開始。
        let indent = label.width + spacing
        var frames = [CGRect(origin: .zero, size: label)]
        var x = indent
        var y: CGFloat = 0
        var rowHeight = label.height
        var contentWidth = label.width

        for size in sizes.dropFirst() {
            // 行首永遠放得下一顆，避免超寬的單一連結被丟到下一行造成空行。
            if x > indent, x + size.width > limit {
                y += rowHeight + spacing
                x = indent
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, x - spacing)
        }
        return Result(frames: frames, contentWidth: contentWidth, height: y + rowHeight)
    }
}
