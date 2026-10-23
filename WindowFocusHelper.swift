import AppKit
import Foundation

/// Shared helper for focusing windows with smart deminimize behavior.
/// Handles minimized windows by deminimizing them to the current active space
/// instead of switching to their original space.
public final class WindowFocusHelper {
    private let client: YabaiClient
    
    public init(client: YabaiClient) {
        self.client = client
    }
    
    /// Focus a window, handling minimized windows intelligently
    public func focusWindow(_ windowId: Int) {
        let allWindows = client.queryWindows()
        guard let targetWindow = allWindows.first(where: { $0.id == windowId }) else {
            client.focus(windowId: windowId)
            return
        }
        
        // Check if window is minimized
        if isWindowMinimized(pid: targetWindow.pid, windowId: windowId) {
            deminimizeAndFocus(windowId: windowId,
                             targetWindow: targetWindow,
                             allWindows: allWindows)
        } else {
            client.focus(windowId: windowId)
        }
    }
    
    /// Check if a specific window is minimized using Accessibility API
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
    
    /// Deminimize a window to the current active space and focus it
    private func deminimizeAndFocus(windowId: Int, targetWindow: YabaiWindow, allWindows: [YabaiWindow]) {
        // Get current active location
        guard let (currentDisplay, currentSpace) = getCurrentActiveLocation(allWindows: allWindows) else {
            // Fallback: just deminimize to original location
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                _ = self.runYabaiCommand("-m window \(windowId) --deminimize")
                Thread.sleep(forTimeInterval: 0.15)
                DispatchQueue.main.async { self.client.focus(windowId: windowId) }
            }
            return
        }
        
        // Deminimize and move to current space if different
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            _ = self.runYabaiCommand("-m window \(windowId) --deminimize")
            Thread.sleep(forTimeInterval: 0.15)
            
            if targetWindow.space != currentSpace || targetWindow.display != currentDisplay {
                _ = self.runYabaiCommand("-m window \(windowId) --space \(currentSpace)")
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            DispatchQueue.main.async {
                self.client.focus(windowId: windowId)
            }
        }
    }
    
    /// Get the current active display and space
    private func getCurrentActiveLocation(allWindows: [YabaiWindow]) -> (display: Int, space: Int)? {
        // Prefer focused window location
        if let focusedWindow = allWindows.first(where: { $0.hasFocus }) {
            return (focusedWindow.display, focusedWindow.space)
        }
        
        // Fallback to first visible window
        if let visibleWindow = allWindows.first(where: { $0.isVisible }) {
            return (visibleWindow.display, visibleWindow.space)
        }
        
        // Last resort: first window
        if let firstWindow = allWindows.first {
            return (firstWindow.display, firstWindow.space)
        }
        
        return nil
    }
    
    /// Run a yabai command
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
}
