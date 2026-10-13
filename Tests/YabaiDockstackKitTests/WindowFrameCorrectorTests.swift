import XCTest
@testable import YabaiDockstackKit

final class WindowFrameCorrectorTests: XCTestCase {
    private func win(_ id: Int, _ frame: YRect) -> YabaiWindow {
        YabaiWindow(id: id, pid: id, app: "A", title: "t", frame: frame,
                    display: 1, space: 1, stackIndex: id, hasFocus: false)
    }

    func testStaleFramesReplacedSoStackRegroups() {
        // Stale yabai frames from an ultrawide split; real bounds are one shared stack frame.
        let real = YRect(x: 10, y: 46, w: 1780, h: 1113)
        let wins = [
            win(1, YRect(x: 1154, y: 46, w: 2276, h: 1384)),
            win(2, YRect(x: 1154, y: 46, w: 2276, h: 1384)),
            win(3, YRect(x: 10, y: 46, w: 1137, h: 1384)),
        ]
        let fixed = WindowFrameCorrector.apply(wins, bounds: [1: real, 2: real, 3: real])
        XCTAssertTrue(fixed.allSatisfy { $0.frame == real })
        let stacks = StackBuilder.build(fixed)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks.first?.windows.count, 3)
        XCTAssertEqual(stacks.first?.frame, real)
    }

    func testMissingOrEmptyBoundsKeepYabaiFrame() {
        let f = YRect(x: 0, y: 0, w: 100, h: 100)
        let wins = [win(1, f), win(2, f)]
        let fixed = WindowFrameCorrector.apply(wins, bounds: [2: YRect(x: 5, y: 5, w: 0, h: 0)])
        XCTAssertEqual(fixed.map { $0.frame }, [f, f])
    }
}
