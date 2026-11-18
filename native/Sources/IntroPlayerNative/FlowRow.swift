import SwiftUI

/// Lays items out left to right and wraps to a new line when they no longer fit.
///
/// An HStack would rather shrink a button than let it overflow, and a squeezed button renders its
/// label one character per line. The transport row must never do that mid-taping, so it wraps.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW {
                widest = max(widest, x - spacing)
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW {
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                    proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
