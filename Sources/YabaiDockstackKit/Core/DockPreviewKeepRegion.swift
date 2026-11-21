import CoreGraphics

/// Where the cursor may be while a Dock preview stays open: the panel, the
/// hovered icon, and the corridor between them (the icon's width), each padded
/// by `tolerance`. Deliberately NOT the union of panel + icon: the panel is much
/// wider than the icon, so the union would cover neighbouring Dock items
/// (folders, Trash, gaps) and keep the preview stuck open over them.
public enum DockPreviewKeepRegion {
    public static func contains(_ p: CGPoint, panel: CGRect, icon: CGRect,
                                tolerance: CGFloat = 8) -> Bool {
        if panel.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
        if icon.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
        // Vertical gap between icon and panel (panel above, or flipped below).
        let gapMinY = min(icon.maxY, panel.maxY)
        let gapMaxY = max(icon.minY, panel.minY)
        guard gapMaxY > gapMinY else { return false }
        let bridge = CGRect(x: icon.minX - tolerance, y: gapMinY,
                            width: icon.width + tolerance * 2, height: gapMaxY - gapMinY)
        return bridge.contains(p)
    }
}
