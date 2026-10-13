/// Replaces yabai's reported window frames with the window server's actual bounds.
///
/// yabai can keep stale frames for windows on spaces it hasn't re-laid-out — e.g.
/// after switching from an external display, a hidden space may still report the
/// old monitor's split geometry. Indicators placed from those frames land in the
/// wrong spot, and members of one stack can stop sharing a frame (so StackBuilder
/// splits them). The window server's bounds (same top-left global coordinates as
/// yabai) reflect where the window really is.
public enum WindowFrameCorrector {
    /// - Parameter bounds: window id → actual bounds. Windows missing from the map
    ///   keep yabai's frame.
    public static func apply(_ windows: [YabaiWindow], bounds: [Int: YRect]) -> [YabaiWindow] {
        guard !bounds.isEmpty else { return windows }
        return windows.map { w in
            guard let real = bounds[w.id], real.w > 0, real.h > 0, real != w.frame else { return w }
            return YabaiWindow(id: w.id, pid: w.pid, app: w.app, title: w.title, frame: real,
                               display: w.display, space: w.space, stackIndex: w.stackIndex,
                               hasFocus: w.hasFocus, isVisible: w.isVisible, isFloating: w.isFloating)
        }
    }
}
