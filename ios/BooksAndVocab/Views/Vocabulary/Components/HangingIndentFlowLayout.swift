import SwiftUI

/// 列首標籤加上可換行的項目流（#3114）。第一個子視圖是標籤；其後的項目接在標籤右側，
/// 超出寬度時換行，且每一行都從「標籤寬 + spacing」的同一欄開始。收合與展開的連結區
/// 共用此佈局，所以展開後的第一顆與換行後的連結 minX 一致。
///
/// 與 `CollocationFlowLayout` 分開：後者仍服務單字詳情，不因連結區改版而改動。
struct HangingIndentFlowLayout: Layout {
    var spacing: CGFloat

    /// 子視圖量測：寬度為 nil 取自然尺寸；否則取該寬度下換行後的尺寸（#3227：超寬項目在值欄內換行）。
    private static func flow(_ subviews: Subviews, spacing: CGFloat, maxWidth: CGFloat?) -> HangingIndentFlow.Result {
        HangingIndentFlow.place(count: subviews.count, spacing: spacing, maxWidth: maxWidth) { index, width in
            subviews[index].sizeThatFits(width.map { ProposedViewSize(width: $0, height: nil) } ?? .unspecified)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = Self.flow(subviews, spacing: spacing, maxWidth: proposal.width)
        return CGSize(width: proposal.width ?? result.contentWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = Self.flow(subviews, spacing: spacing, maxWidth: bounds.width)
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
        place(count: sizes.count, spacing: spacing, maxWidth: maxWidth) { index, _ in sizes[index] }
    }

    /// `measure(index, width)`：width 為 nil 取自然尺寸；否則回傳該寬度下的尺寸（文字換行後的高）。
    static func place(
        count: Int,
        spacing: CGFloat,
        maxWidth: CGFloat?,
        measure: (_ index: Int, _ width: CGFloat?) -> CGSize
    ) -> Result {
        guard count > 0 else {
            return Result(frames: [], contentWidth: 0, height: 0)
        }
        let limit = maxWidth ?? .infinity
        let label = measure(0, nil)
        // 懸掛縮排：第一行與之後每一行的項目都從這個 x 開始。
        let indent = label.width + spacing
        // 值欄可用寬。超過它的項目（#3227）改以值欄寬重新量測，在值欄內換行，不溢出卡片。
        let valueWidth = max(0, limit - indent)
        // 標籤已佔滿（valueWidth <= 0）時沒有值欄：項目改從卡片左緣起排，寬度夾到卡片寬。
        // 夾成 0 會讓項目隱形（#3297）；保留自然寬又會溢出卡片（#3317）。
        let hasValueColumn = valueWidth > 0
        let lineStart: CGFloat = hasValueColumn ? indent : 0
        let itemWidth = hasValueColumn ? valueWidth : limit
        var frames = [CGRect(origin: .zero, size: label)]
        var x = indent
        var y: CGFloat = 0
        var rowHeight = label.height
        var contentWidth = label.width

        for index in 1..<count {
            var size = measure(index, nil)
            if size.width > itemWidth {
                let fitted = measure(index, itemWidth)
                size = CGSize(width: min(fitted.width, itemWidth), height: fitted.height)
            }
            // 行首永遠放得下一顆（已夾到寬度上限），避免超寬項目被丟到下一行造成空行。
            // 無值欄時首顆的 x = indent 已超出卡片，會在此換到 lineStart 的新行。
            if x > lineStart, x + size.width > limit {
                y += rowHeight + spacing
                x = lineStart
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
