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
    /// Deduplicates windows with identical frames (handles apps like Autodesk Fusion
    /// that create multiple layers for one visual window).
    private func windows(for hover: DockHover) -> [YabaiWindow] {
        let all = client.queryWindows()
        pendingCloseIDs.formIntersection(Set(all.map { $0.id }))
        let live = all.filter { !pendingCloseIDs.contains($0.id) }
        
        var matched: [YabaiWindow]
        if let bid = hover.bundleID {
            matched = live.filter { bundleID(pid: $0.pid) == bid }
                .sorted { ($0.space, $0.stackIndex, $0.id) < ($1.space, $1.stackIndex, $1.id) }
            if matched.isEmpty {
                matched = AppWindowGrouper.windows(of: hover.appTitle, in: live)
            }
        } else {
            matched = AppWindowGrouper.windows(of: hover.appTitle, in: live)
        }
        
        // Special handling for Autodesk Fusion: filter out helper app windows
        // The main app is com.autodesk.fusion360, but helper processes like
        // com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion should be excluded
        if let bid = hover.bundleID, bid.contains("autodesk") && bid.contains("fusion") {
            matched = matched.filter { win in
                guard let winBundleID = bundleID(pid: win.pid) else { return true }
                // Keep only the main Fusion app, exclude streamer/helper apps
                return !winBundleID.contains("streamer") && !winBundleID.contains("scriptapp")
            }
        }
        
        // Deduplicate windows with identical frames (layers/overlays)
        return deduplicateOverlayWindows(matched)
    }
    
    /// Remove duplicate windows that share the same frame, keeping only one per location.
    /// This handles apps like Autodesk Fusion that create multiple layer windows at the
    /// same position, which should appear as a single window in the dock preview.
    private func deduplicateOverlayWindows(_ windows: [YabaiWindow]) -> [YabaiWindow] {
        var seen: Set<String> = []
        var unique: [YabaiWindow] = []
        
        for window in windows {
            // Create a unique key based on space, display, and frame coordinates
            // Use rounded coordinates to handle minor floating-point differences
            let frameKey = "\(window.space)_\(window.display)_\(Int(window.frame.x))_\(Int(window.frame.y))_\(Int(window.frame.w))_\(Int(window.frame.h))"
            
            if !seen.contains(frameKey) {
                seen.insert(frameKey)
                unique.append(window)
            }
        }
        
        return unique
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
    
    /// Focus a window using the shared WindowFocuser (handles deminimize smartly)
    private func focusWindow(_ windowId: Int, from windows: [YabaiWindow]) {
        WindowFocuser.focusWindow(windowId, using: client, restoreTo: .cursor)
    }
    
    /// Check if a specific window is minimized using Accessibility API
    /// (used for visual indicator in preview)
    private func isWindowMinimized(pid: Int, windowId: Int) -> Bool {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowListRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef) == .success,
              let windowList = windowListRef as? [AXUIElement] else { return false }
        
        // Get the target window details for matching
        let allWindows = client.queryWindows()
        guard let targetWindow = allWindows.first(where: { $0.id == windowId }) else { return false }
        
        for axWindow in windowList {
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let isMinimized = minimizedRef as? Bool else { continue }
            
            if !isMinimized { continue }
            
            // Try to match by CGWindowID
            var cgWindowIdRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "AXWindowID" as CFString, &cgWindowIdRef) == .success,
               let cgWindowId = cgWindowIdRef as? UInt32,
               Int(cgWindowId) == windowId {
                return true
            }
            
            // Fallback: match by title and position
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String,
               axTitle == targetWindow.title {
                
                var posRef: CFTypeRef?
                var pos = CGPoint.zero
                if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                   let p = posRef {
                    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                    if abs(targetWindow.frame.x - pos.x) < 5 {
                        return true
                    }
                }
            }
        }
        
        return false
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
