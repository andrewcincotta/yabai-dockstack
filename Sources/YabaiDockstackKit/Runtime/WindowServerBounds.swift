import CoreGraphics
import Foundation

/// Actual window bounds from the window server, keyed by window id. Includes
/// windows on other spaces. Bounds don't require Screen Recording permission.
public enum WindowServerBounds {
    public static func query() -> [Int: YRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var out: [Int: YRect] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            out[id] = YRect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                            w: Double(rect.width), h: Double(rect.height))
        }
        return out
    }
}
