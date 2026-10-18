import Foundation

enum LocalAICompanionLayout {
    static func center(in size: CGSize, right: Bool, fraction: Double, drag: CGSize) -> CGPoint {
        let w = max(0, size.width), h = max(0, size.height)
        let dragging = drag.width != 0 || drag.height != 0
        let inset = min(24, w / 2)
        let restingX = right ? w : 0
        let dragX = (right ? w - inset : inset) + drag.width
        let margin = min(32, h / 2)
        let y = margin + max(0, h - margin * 2) * (fraction.isFinite ? min(1, max(0, fraction)) : 0.5) + drag.height
        return CGPoint(x: dragging ? min(w - inset, max(inset, dragX)) : restingX,
                       y: min(h - margin, max(margin, y)))
    }

    static func hitCenter(_ visual: CGPoint, in size: CGSize) -> CGPoint {
        let inset = min(22, max(0, size.width) / 2)
        return CGPoint(x: min(max(inset, visual.x), max(inset, size.width - inset)), y: visual.y)
    }
}
