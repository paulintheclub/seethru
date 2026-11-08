import AppKit

/// Cuts rectangles out of a layer. The overlay panels float above every normal window, so the parts of the
/// transparent window that another window currently covers are cut out and that window shows through unchanged.
@MainActor
enum HoleMask {
    /// `rect` is the CG-coordinate rectangle the layer's window occupies; `holes` are CG-coordinate rectangles.
    static func apply(to layer: CALayer?, rect: CGRect, holes: [CGRect]) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let local: [CGRect] = holes.compactMap { h in
            let i = h.intersection(rect)
            guard !i.isNull, i.width > 0, i.height > 0 else { return nil }
            // Layer coordinates have a bottom-left origin.
            return CGRect(x: i.minX - rect.minX, y: rect.maxY - i.maxY, width: i.width, height: i.height)
        }
        guard !local.isEmpty else { layer.mask = nil; return }
        let bounds = CGRect(origin: .zero, size: rect.size)
        let cut = CGMutablePath()
        for r in local {
            // Windows have rounded corners; a square hole would expose the original's square corner there.
            let radius = min(r.width, r.height) >= 200 ? 26.0 : min(10.0, min(r.width, r.height) / 2)
            cut.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.path = CGPath(rect: bounds, transform: nil).subtracting(cut, using: .winding)
        layer.mask = shape
    }
}
