import AppKit
import CoreGraphics

/// Orchestrates the Dock-hover preview: watch the Dock, group the hovered app's
/// windows, show thumbnails (live → cached → icon), and focus on click.
public final class DockPreviewController {
    private let client: YabaiClient
    private let cache: ThumbnailCache
    private let capturer = ThumbnailCapturer()
    private let panel = DockPreviewPanel()
    private var watcher: DockWatcher?
    private var keepTimer: Timer?
    private var iconFrame: CGRect?
    /// The hover that produced the current panel — lets the ✕ button rebuild
    /// the preview after a window is closed.
    private var lastHover: DockHover?
    /// Windows we've asked to close but yabai still lists — hidden from the
    /// popover immediately (optimistic) until the queries catch up.
    private var pendingCloseIDs: Set<Int> = []

    public init(client: YabaiClient, cache: ThumbnailCache) {
        self.client = client
        self.cache = cache
    }

    public func start() {
        guard PermissionsHelper.hasAccessibility() else { return }
        let w = DockWatcher { [weak self] hover in self?.handle(hover) }
        w.start()
        watcher = w
    }

    public func stop() {
        watcher?.stop(); watcher = nil
        hidePanel()
    }

    private func hidePanel() {
        keepTimer?.invalidate(); keepTimer = nil
        iconFrame = nil
        lastHover = nil
        panel.hide()
    }

    /// ✕ on a preview cell. The cell disappears immediately (optimistic — some
    /// apps close slowly and yabai keeps listing the window for a moment).
    /// Closing the app's LAST window quits the app instead: a plain window
    /// close leaves agenty apps (Music, …) running with no window, which is
    /// never what a ✕ in a Dock popover means.
    private func closeWindow(_ id: Int) {
        guard let hover = lastHover else { return }
        let current = windows(for: hover)
        let isLastWindow = !current.contains { $0.id != id }
        let pid = current.first { $0.id == id }?.pid
        pendingCloseIDs.insert(id)
        handle(hover)   // rebuild without the closed cell; hides when empty

        if isLastWindow, let pid {
            NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.client.close(windowId: id)
            Thread.sleep(forTimeInterval: 0.4)
            DispatchQueue.main.async {
                guard self.panel.isVisible, let hover = self.lastHover else { return }
                self.handle(hover)   // reconcile (e.g. the close was refused)
            }
        }
    }

    // While a preview is visible, keep it open as long as the cursor stays within
    // the panel + the Dock icon + the gap between them. This is robust against the
    // panel rebuilding its content (live-thumbnail refresh) and the bare gap,
    // which event-based tracking handled unreliably.
    private func startKeepTimer() {
        keepTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.checkKeep() }
        RunLoop.main.add(t, forMode: .common)
        keepTimer = t
    }

    private func checkKeep() {
        guard panel.isVisible, let icon = iconFrame, let pf = panel.currentFrame else {
            hidePanel(); return
        }
        let region = pf.union(icon).insetBy(dx: -12, dy: -12)
        if !region.contains(NSEvent.mouseLocation) { hidePanel() }
    }

    private func icon(for win: YabaiWindow) -> NSImage {
        NSRunningApplication(processIdentifier: pid_t(win.pid))?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private func items(for wins: [YabaiWindow]) -> [PreviewItem] {
        wins.map { win in
            let minimized = isWindowMinimized(pid: win.pid, windowId: win.id)
            // Don't show thumbnails for minimized windows
            let thumbnail = minimized ? nil : cache.get(win.id)
            
            return PreviewItem(windowID: win.id, 
                             title: win.title, 
                             space: win.space,
                             thumbnail: thumbnail, 
                             icon: icon(for: win),
                             isMinimized: minimized)
        }
    }

    private var bundleIDCache: [Int: String] = [:]
    private func bundleID(pid: Int) -> String? {
        if let c = bundleIDCache[pid] { return c }
        let b = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
        if let b { bundleIDCache[pid] = b }
        return b
    }

    /// Windows belonging to the hovered Dock app. Prefer bundle-id matching (robust
    /// across display-name vs yabai-app-name mismatches like "Visual Studio Code"
    /// vs "Code"); fall back to app-name matching. Windows with a close in
    /// flight are excluded (and forgotten once yabai drops them).
    private func windows(for hover: DockHover) -> [YabaiWindow] {
        let all = client.queryWindows()
        pendingCloseIDs.formIntersection(Set(all.map { $0.id }))
        let live = all.filter { !pendingCloseIDs.contains($0.id) }
        if let bid = hover.bundleID {
            let matched = live.filter { bundleID(pid: $0.pid) == bid }
                .sorted { ($0.space, $0.stackIndex, $0.id) < ($1.space, $1.stackIndex, $1.id) }
            if !matched.isEmpty { return matched }
        }
        return AppWindowGrouper.windows(of: hover.appTitle, in: live)
    }

    private func handle(_ hover: DockHover?) {
        // hover == nil (cursor left Dock items) is ignored here; the keep-timer
        // decides when to hide based on the cursor's position.
        guard let hover else { return }

        let wins = windows(for: hover)
        guard !wins.isEmpty else { hidePanel(); return }

        iconFrame = hover.iconFrame
        lastHover = hover
        // Show immediately with cached/icon, then refresh live thumbnails async.
        panel.show(items: items(for: wins), aboveIcon: hover.iconFrame,
                   onClick: { [weak self] id in
                       self?.focusWindow(id, from: wins); self?.hidePanel()
                   },
                   onClose: { [weak self] id in self?.closeWindow(id) })
        startKeepTimer()

        Task { [weak self] in
            guard let self else { return }
            let fresh = await self.capturer.captureOnScreen(windowIDs: Set(wins.map { $0.id }))
            guard !fresh.isEmpty else { return }
            for (id, img) in fresh { self.cache.put(id, img) }
            await MainActor.run {
                guard self.panel.isVisible, self.iconFrame == hover.iconFrame else { return }
                self.panel.show(items: self.items(for: wins), aboveIcon: hover.iconFrame,
                                onClick: { [weak self] id in
                                    guard let self else { return }
                                    let currentWins = self.windows(for: hover)
                                    self.focusWindow(id, from: currentWins)
                                    self.hidePanel()
                                },
                                onClose: { [weak self] id in self?.closeWindow(id) })
            }
        }
    }
    
    /// Focus a window, handling minimized windows by deminimizing them to the
    /// current active space/display instead of their original space.
    private func focusWindow(_ windowId: Int, from windows: [YabaiWindow]) {
        guard let targetWindow = windows.first(where: { $0.id == windowId }) else {
            client.focus(windowId: windowId)
            return
        }
        
        // Check if the window is minimized using Accessibility API
        if isWindowMinimized(pid: targetWindow.pid, windowId: windowId) {
            // Get the current active space and display
            guard let (currentDisplay, currentSpace) = getCurrentActiveLocation() else {
                // Fallback: just deminimize to original location
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    _ = self.runYabaiCommand("-m window \(windowId) --deminimize")
                    Thread.sleep(forTimeInterval: 0.15)
                    DispatchQueue.main.async { self.client.focus(windowId: windowId) }
                }
                return
            }
            
            // Deminimize and move to current space
            deminimizeToCurrentSpace(windowId: windowId,
                                    targetDisplay: currentDisplay,
                                    targetSpace: currentSpace,
                                    originalSpace: targetWindow.space,
                                    originalDisplay: targetWindow.display)
        } else {
            // Window is not minimized, use normal focus
            client.focus(windowId: windowId)
        }
    }
    
    /// Run a yabai command directly using the client's yabai path
    @discardableResult
    private func runYabaiCommand(_ args: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: client.path)
        process.arguments = args.split(separator: " ").map(String.init)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
    
    /// Check if a window is minimized using Accessibility API
    private func isWindowMinimized(pid: Int, windowId: Int) -> Bool {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowListRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef) == .success,
              let windowList = windowListRef as? [AXUIElement] else { return false }
        
        // Check each window for minimized state
        // Note: We iterate through windows since matching by ID is not reliable
        for axWindow in windowList {
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let isMinimized = minimizedRef as? Bool, isMinimized {
                // Found a minimized window - assume it's the one we're looking for
                // This works well in practice since we're called with a specific window ID
                // from the dock preview which already filtered to this app
                return true
            }
        }
        
        return false
    }
    
    /// Get the current active display and space based on focused window or mouse position
    private func getCurrentActiveLocation() -> (display: Int, space: Int)? {
        // Try to get the focused window's location first (most reliable)
        let allWindows = client.queryWindows()
        if let focusedWindow = allWindows.first(where: { $0.hasFocus }) {
            return (focusedWindow.display, focusedWindow.space)
        }
        
        // Fallback: Find the most recently used visible window on any display
        // This is a heuristic since we don't have direct access to querySpaces
        if let recentWindow = allWindows.first(where: { $0.isVisible }) {
            return (recentWindow.display, recentWindow.space)
        }
        
        // Last resort: use first window we can find
        if let firstWindow = allWindows.first {
            return (firstWindow.display, firstWindow.space)
        }
        
        return nil
    }
    
    /// Deminimize a window and move it to the current space
    private func deminimizeToCurrentSpace(windowId: Int,
                                         targetDisplay: Int,
                                         targetSpace: Int,
                                         originalSpace: Int,
                                         originalDisplay: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            // Step 1: Deminimize the window (it will appear on its original space)
            _ = self.runYabaiCommand("-m window \(windowId) --deminimize")
            
            // Small delay to let deminimize complete
            Thread.sleep(forTimeInterval: 0.15)
            
            // Step 2: Move to target space if different from original
            if targetSpace != originalSpace || targetDisplay != originalDisplay {
                _ = self.runYabaiCommand("-m window \(windowId) --space \(targetSpace)")
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            // Step 3: Focus the window
            DispatchQueue.main.async {
                self.client.focus(windowId: windowId)
            }
        }
    }

    /// Warm the cache with currently on-screen windows (call on yabai signals).
    public func warmCache() {
        let ids = Set(client.queryWindows().map { $0.id })
        Task { [weak self] in
            guard let self else { return }
            let fresh = await self.capturer.captureOnScreen(windowIDs: ids)
            for (id, img) in fresh { self.cache.put(id, img) }
        }
    }
}
