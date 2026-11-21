import XCTest
@testable import YabaiDockstackKit

final class StackBuilderTests: XCTestCase {
    private func win(_ id: Int, _ app: String, _ idx: Int, _ frame: YRect, focus: Bool = false,
                     space: Int = 1) -> YabaiWindow {
        YabaiWindow(id: id, pid: id, app: app, title: app, frame: frame, display: 1, space: space, stackIndex: idx, hasFocus: focus)
    }

    func testGroupsStackedWindowsAndIgnoresUnstacked() {
        let f = YRect(x: 0, y: 25, w: 800, h: 900)
        let other = YRect(x: 800, y: 25, w: 800, h: 900)
        let wins = [
            win(2, "Code", 2, f),
            win(1, "Code", 1, f, focus: true),
            win(3, "Safari", 0, other),   // unstacked -> ignored
        ]
        let stacks = StackBuilder.build(wins)
        XCTAssertEqual(stacks.count, 1)
        let s = stacks[0]
        XCTAssertEqual(s.windows.map { $0.id }, [1, 2])  // sorted by stackIndex
        XCTAssertTrue(s.isFocused)
        XCTAssertEqual(s.frame, f)
    }

    func testSameFrameButStackIndexZeroIsNotAStack() {
        let f = YRect(x: 0, y: 25, w: 800, h: 900)
        let wins = [win(1, "A", 0, f), win(2, "B", 0, f)]
        XCTAssertEqual(StackBuilder.build(wins).count, 0)
    }

    /// Same-frame stacks on different spaces must get distinct keys, or the
    /// renderer reuses a panel pinned to the other space.
    func testSameFrameOnDifferentSpacesAreSeparateStacks() {
        let f = YRect(x: 0, y: 25, w: 800, h: 900)
        let wins = [
            win(1, "A", 1, f, space: 1), win(2, "B", 2, f, space: 1),
            win(3, "C", 1, f, space: 2), win(4, "D", 2, f, space: 2),
        ]
        let stacks = StackBuilder.build(wins)
        XCTAssertEqual(stacks.count, 2)
        XCTAssertNotEqual(stacks[0].key, stacks[1].key)
        XCTAssertEqual(Set(stacks.map { $0.space }), [1, 2])
    }
}
