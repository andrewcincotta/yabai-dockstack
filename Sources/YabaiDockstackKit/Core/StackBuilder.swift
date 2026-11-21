public enum StackBuilder {
    public static func build(_ windows: [YabaiWindow]) -> [Stack] {
        // group by display + space + frame. The space keeps same-frame stacks on
        // different spaces apart, so each gets its own (space-pinned) panel.
        func key(_ w: YabaiWindow) -> String {
            "\(w.display)|\(w.space)|\(Int(w.frame.x))|\(Int(w.frame.y))|\(Int(w.frame.w))|\(Int(w.frame.h))"
        }
        var groups: [String: [YabaiWindow]] = [:]
        for w in windows { groups[key(w), default: []].append(w) }

        var stacks: [Stack] = []
        for (k, group) in groups {
            // a real stack has >1 window AND every member has stackIndex > 0
            let stacked = group.filter { $0.stackIndex > 0 }
            guard stacked.count > 1 else { continue }
            let sorted = stacked.sorted { $0.stackIndex < $1.stackIndex }
            let first = sorted[0]
            stacks.append(Stack(
                frame: first.frame, display: first.display, space: first.space,
                windows: sorted, isFocused: sorted.contains { $0.hasFocus }, key: k))
        }
        return stacks.sorted { $0.key < $1.key }  // stable order
    }
}
