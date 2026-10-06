/// Keeps only windows that live on a *currently visible* space.
///
/// A yabai stack shows only its active member on top, so the occluded members
/// report `is-visible == false`. We therefore can't filter windows by their own
/// visibility — instead we find the set of spaces currently shown on each
/// display and keep all windows on those spaces. This drops stacks that live on
/// other spaces (so they don't bleed across spaces) and avoids drawing over
/// native-fullscreen spaces.
public enum VisibleSpaceFilter {
    /// - Parameter visibleSpaces: authoritative visible space indices from
    ///   `yabai -m query --spaces`. When provided (non-empty) it is used as-is,
    ///   so an empty visible space correctly yields no windows. When nil/empty
    ///   (e.g. replay mode or a failed query) the set is inferred from windows
    ///   that report `is-visible`.
    public static func apply(_ windows: [YabaiWindow], visibleSpaces: Set<Int>? = nil) -> [YabaiWindow] {
        if let visibleSpaces, !visibleSpaces.isEmpty {
            return windows.filter { visibleSpaces.contains($0.space) }
        }
        // Inference can't distinguish "every visible space is empty" from "no
        // visibility data", so only here do we fall back to showing everything.
        let inferred = Set(windows.filter { $0.isVisible }.map { $0.space })
        guard !inferred.isEmpty else { return windows }  // safety: don't hide everything
        return windows.filter { inferred.contains($0.space) }
    }
}
