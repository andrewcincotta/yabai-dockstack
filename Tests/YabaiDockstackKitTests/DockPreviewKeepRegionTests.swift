import XCTest
@testable import YabaiDockstackKit

final class DockPreviewKeepRegionTests: XCTestCase {
    // Cocoa coords: icon at the bottom, 640-wide panel centered 8pt above it.
    private let icon = CGRect(x: 500, y: 0, width: 60, height: 60)
    private let panel = CGRect(x: 210, y: 68, width: 640, height: 160)

    private func inside(_ x: CGFloat, _ y: CGFloat, panel: CGRect? = nil) -> Bool {
        DockPreviewKeepRegion.contains(CGPoint(x: x, y: y), panel: panel ?? self.panel, icon: icon)
    }

    func testIconPanelAndGapAreInside() {
        XCTAssertTrue(inside(530, 30))    // icon
        XCTAssertTrue(inside(300, 150))   // panel
        XCTAssertTrue(inside(530, 64))    // gap between them
    }

    /// Regression: the Dock beside the icon, under the panel's span, used to
    /// count as "inside" (union of panel + icon), keeping the preview stuck.
    func testDockBesideIconIsOutside() {
        XCTAssertFalse(inside(300, 30))
        XCTAssertFalse(inside(800, 10))
    }

    func testFlippedPanelBelowIcon() {
        let below = CGRect(x: 210, y: -180, width: 640, height: 160)
        XCTAssertTrue(inside(530, -10, panel: below))   // gap below icon
        XCTAssertTrue(inside(300, -100, panel: below))  // panel
        XCTAssertFalse(inside(300, 30, panel: below))   // beside icon
    }
}
