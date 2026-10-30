import AppKit

/// Helper for focusing windows with smart deminimize behavior
enum WindowFocuser {
    /// Which space a minimized window is restored onto.
    enum RestoreTarget {
        /// The space of the active (focused) window — switcher restores.
        case activeWindow
        /// The space visible on the display under the mouse cursor — Dock preview restores.
        case cursor
    }

    /// Focus a window. A minimized window is restored onto `target`'s space and
    /// the user is never switched to the window's origin space. Runs off the
    /// calling thread; the restore target is resolved before anything changes.
    static func focusWindow(_ windowId: Int, using client: YabaiClient,
                            restoreTo target: RestoreTarget) {
        // Sampled now: the cursor may move while we work.
        let cursor = CGEvent(source: nil)?.location
        DispatchQueue.global(qos: .userInitiated).async {
            let allWindows = client.queryWindows()
            guard let targetWindow = allWindows.first(where: { $0.id == windowId }),
                  targetWindow.isMinimized
                    || isWindowMinimized(pid: targetWindow.pid, windowId: windowId, allWindows: allWindows)
            else {
                client.focus(windowId: windowId)
                return
            }
            restore(targetWindow, target: target, cursor: cursor, client: client)
        }
    }

    /// Moves the window to the destination space WHILE STILL MINIMIZED (yabai's
    /// scripting addition can move minimized windows), then deminimizes it
    /// there. Deminimizing first makes macOS jump to the window's origin space;
    /// moving first means there is nothing to jump to. Focus comes last, and
    /// only if everything above succeeded.
    private static func restore(_ window: YabaiWindow, target: RestoreTarget,
                                cursor: CGPoint?, client: YabaiClient) {
        let destination = restoreSpace(for: target, cursor: cursor,
                                       windows: client.queryWindows(), client: client)

        if let destination, window.space != destination {
            guard moveVerified(window.id, toSpace: destination, client: client) else {
                // Not restoring: that would switch to the window's old space.
                NSLog("yabai-dockstack: could not move window %d to space %d", window.id, destination)
                return
            }
        }

        client.deminimize(windowId: window.id)
        guard let restored = waitForWindow(window.id, client: client, until: { !$0.isMinimized }) else {
            NSLog("yabai-dockstack: window %d did not deminimize in time", window.id)
            return
        }

        // yabai keeps a window's float state across minimize, move and
        // deminimize. A floating (unmanaged) window stays floating and is
        // centered on its new display; a tiled one is re-tiled only if it
        // somehow came back floating.
        if window.isFloating {
            center(restored, client: client)
        } else if restored.isFloating {
            client.toggleFloat(windowId: window.id)
        }

        client.focus(windowId: window.id)

        // Last line of defence: if macOS still switched spaces, switch back.
        if let destination, let active = client.queryActiveSpaceIndex(), active != destination {
            client.focusSpace(destination)
        }
    }

    private static func restoreSpace(for target: RestoreTarget, cursor: CGPoint?,
                                     windows: [YabaiWindow], client: YabaiClient) -> Int? {
        switch target {
        case .cursor:
            if let cursor, let space = visibleSpace(at: cursor, client: client) { return space }
            fallthrough
        case .activeWindow:
            if let space = client.queryActiveSpaceIndex() { return space }
            return (windows.first(where: { $0.hasFocus }) ?? windows.first(where: { $0.isVisible }))?.space
        }
    }

    /// Centers a floating window on its display, shrunk to fit if it came from a larger one.
    private static func center(_ window: YabaiWindow, client: YabaiClient) {
        guard let display = client.queryDisplaysInfo().first(where: { $0.index == window.display })?.frame
        else { return }
        let w = min(window.frame.w, display.w), h = min(window.frame.h, display.h)
        if w != window.frame.w || h != window.frame.h {
            client.resizeWindow(id: window.id, w: w, h: h)
        }
        client.moveWindow(id: window.id, absX: display.x + (display.w - w) / 2,
                          absY: display.y + (display.h - h) / 2)
    }

    /// The visible space of the display containing `point` (global, top-left origin — yabai's convention).
    private static func visibleSpace(at point: CGPoint, client: YabaiClient) -> Int? {
        guard let display = client.queryDisplaysInfo().first(where: {
            point.x >= $0.frame.x && point.x < $0.frame.x + $0.frame.w
                && point.y >= $0.frame.y && point.y < $0.frame.y + $0.frame.h
        }) else { return nil }
        return client.querySpacesInfo().first(where: { $0.display == display.index && $0.isVisible })?.index
    }

    private static func waitForWindow(_ id: Int, client: YabaiClient, timeout: TimeInterval = 2.0,
                                      until done: (YabaiWindow) -> Bool) -> YabaiWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let w = client.queryWindow(id: id), done(w) { return w }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Moves the window and confirms yabai reports it on `space`, re-issuing the
    /// move if macOS undid it while finishing the restore.
    private static func moveVerified(_ id: Int, toSpace space: Int, client: YabaiClient,
                                     timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if client.queryWindow(id: id)?.space == space { return true }
            if Date() >= deadline { return false }
            client.moveWindow(id: id, toSpace: space)
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private static func isWindowMinimized(pid: Int, windowId: Int, allWindows: [YabaiWindow]) -> Bool {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        var windowListRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef) == .success,
              let windowList = windowListRef as? [AXUIElement],
              let targetWindow = allWindows.first(where: { $0.id == windowId }) else { return false }
        
        for axWindow in windowList {
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let isMinimized = minimizedRef as? Bool, isMinimized else { continue }
            
            // Try CGWindowID match
            var cgWindowIdRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "AXWindowID" as CFString, &cgWindowIdRef) == .success,
               let cgWindowId = cgWindowIdRef as? UInt32, Int(cgWindowId) == windowId {
                return true
            }
            
            // Fallback: title + position match
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String, axTitle == targetWindow.title {
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
}

public enum YabaiDockstack {
    public static func versionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "yabai-dockstack \(v)"
    }

    /// Absolute path to the running binary — used as the yabai signal action target.
    private static func selfBinaryPath() -> String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return (raw as NSString).standardizingPath
    }

    public static func main() {
        let args = CommandLine.arguments
        let configPath = "~/.config/yabai-dockstack/config.json"
        var config = AppConfig.loadFromFile(configPath)
        L10n.current = L10n.resolve(AppLanguage(rawValue: config.language) ?? .auto,
                                    preferred: Locale.preferredLanguages)

        if args.contains("--refresh") {
            RefreshClient.sendPoke(socketPath: config.socketPath, force: args.contains("--force"))
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // LSUIElement-equivalent at runtime

        // Auto-detect yabai: a valid configured path wins, otherwise search.
        let resolvedYabai = YabaiLocator.resolve(configuredPath: config.yabaiPath) ?? config.yabaiPath
        config.yabaiPath = resolvedYabai
        let client = YabaiClient(yabaiPath: resolvedYabai)

        let renderer = OverlayRenderer(config: config)
        renderer.onClickWindow = { id in
            // Smart focus: deminimize onto the cursor's space if needed
            WindowFocuser.focusWindow(id, using: client, restoreTo: .cursor)
        }

        // replay mode: render once from a JSON file, no live yabai
        if let idx = args.firstIndex(of: "--replay"), idx + 1 < args.count {
            let path = (args[idx + 1] as NSString).expandingTildeInPath
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            let stacks = StackBuilder.build(VisibleSpaceFilter.apply(YabaiWindow.decodeList(data)))
            renderer.update(stacks)
            app.run()
            return
        }

        // Single-instance guard: duplicate login-item registrations (e.g. a dev
        // copy and the installed copy) or session restore can launch a second
        // copy at boot — the newcomer bows out, since the menu bar item, unix
        // socket, and event tap all assume exactly one instance. (--refresh and
        // --replay above are exempt: they don't start the full app.)
        let myPid = ProcessInfo.processInfo.processIdentifier
        let exeName = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])).lastPathComponent
        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != myPid && $0.executableURL?.lastPathComponent == exeName
        }) {
            NSLog("yabai-dockstack: another instance is already running (pid %d) — exiting",
                  other.processIdentifier)
            return
        }

        // Write a default config file on first run so it's discoverable/editable.
        let expandedConfig = (configPath as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expandedConfig) {
            config.save(to: configPath)
        }

        // Install/refresh bundled helper scripts (only writes to the scripts dir,
        // never touches the user's rc files). Overwrites when an update ships
        // new script contents.
        if ScriptInstaller.needsUpdate(dir: ConfigPaths.scriptsDir) {
            do { try ScriptInstaller.install(to: ConfigPaths.scriptsDir) }
            catch { NSLog("yabai-dockstack: helper script install failed: \(error)") }
        }

        // Dock window previews (gated; needs Accessibility + Screen Recording).
        let thumbCache = ThumbnailCache()
        var dockController: DockPreviewController?

        // AltTab-style window switcher: hold-to-cycle via a global event tap,
        // plus a sticky mode reachable through the show-switcher socket command.
        // The tap is gated on yabai being present so a captured ⌘⇥ can never
        // black-hole the system switcher while yabai is down (5s heal re-checks).
        let switcher = SwitcherController(client: client, cache: thumbCache, config: config)
        let switcherTap = SwitcherKeyTap()
        switcher.onDismiss = { switcherTap.resetMachine() }
        func ensureSwitcherTap() {
            let wanted = config.switcherEnabled && config.switcherHoldToCycle
                && PermissionsHelper.hasAccessibility() && client.isAvailable()
            if wanted {
                switcherTap.updateTriggers(SwitcherTriggers.build(from: config))
                _ = switcherTap.start()
            } else {
                switcherTap.stop()
            }
        }

        let coordinator = RefreshCoordinator(config: config, client: client) { stacks in
            renderer.update(stacks)
            dockController?.warmCache()
        }
        coordinator.onWindows = { switcher.noteWindows($0) }
        switcherTap.onOutput = { output in
            switch output {
            case let .activate(idx, backward):
                let scope = switcherTap.triggers.indices.contains(idx)
                    ? switcherTap.triggers[idx].scope : .allWindows
                if !switcher.open(scope: scope, sticky: false, backward: backward) {
                    // Nothing to show (e.g. window list not warmed yet): stop
                    // swallowing keys and warm the cache for the next attempt.
                    switcherTap.resetMachine()
                    coordinator.requestRefresh()
                }
            case let .cycle(forward): switcher.cycle(forward: forward)
            case let .move(dx, dy): switcher.move(dx: dx, dy: dy)
            case .commit: switcher.commit()
            case .cancel: switcher.cancel()
            case .closeSelected: switcher.closeSelected()
            case .quitSelected: switcher.quitSelected()
            case .pass, .swallow: break
            }
        }
        let spaceMover = SpaceMover(client: client)
        let menu = MenuBarController()
        let listener = SignalListener(
            socketPath: config.socketPath,
            onPoke: { force in coordinator.requestRefresh(force: force) },
            onCommand: { cmd in
                if cmd == "show-menu" {
                    DispatchQueue.main.async { menu.openMenu() }
                } else if cmd == "show-switcher" {
                    DispatchQueue.main.async {
                        switcher.open(scope: .allWindows, sticky: true)
                    }
                } else {
                    spaceMover.handle(command: cmd)
                }
            })

        let binaryPath = selfBinaryPath()
        menu.statusProvider = { client.isAvailable() ? L10n.t("ui.menu.yabaiConnected") : L10n.t("ui.menu.yabaiNotFound") }
        menu.windowListProvider = {
            WindowMenuModel.build(client.queryWindows(), spaceLabels: client.querySpaceLabels())
        }
        menu.onSelectWindow = { id in WindowFocuser.focusWindow(id, using: client, restoreTo: .cursor) }
        menu.permissionWarning = {
            (config.dockPreview && !PermissionsHelper.allGranted)
                ? L10n.t("ui.menu.grantPerms") : nil
        }
        menu.yabaiMissing = { !client.isAvailable() }

        let yabaiGuide = YabaiSetupGuide()

        // Auto-register yabai signals (idempotent) so the user never edits yabairc.
        func installSignals() {
            guard client.isAvailable() else { return }
            SignalInstaller.install(client: client, appBinaryPath: binaryPath)
        }

        // Start/stop the Dock-preview controller to match config + permission state.
        // The watcher needs Accessibility; Screen Recording only affects thumbnails.
        func ensureDockController() {
            if config.dockPreview, PermissionsHelper.hasAccessibility(), dockController == nil {
                let dc = DockPreviewController(client: client, cache: thumbCache)
                dc.start()
                dockController = dc
            } else if !config.dockPreview, let dc = dockController {
                dc.stop(); dockController = nil
            }
        }

        let settings = SettingsWindowController(
            config: config,
            onChange: { newConfig in
                config = newConfig
                // Re-resolve the yabai path (blank field → auto-detect) and apply
                // it live to the shared client, then re-register signals.
                let resolved = YabaiLocator.resolve(configuredPath: config.yabaiPath) ?? config.yabaiPath
                client.path = resolved
                config.save(to: configPath)
                renderer.updateConfig(config)
                coordinator.updateConfig(config)
                installSignals()
                coordinator.requestRefresh()
                ensureDockController()
                switcher.updateConfig(config)
                ensureSwitcherTap()
            },
            onLoginToggle: { enabled in _ = LoginItem.setEnabled(enabled) },
            loginIsEnabled: { LoginItem.isEnabled })

        // Permissions section: request the permission AND open the right pane, one
        // at a time (avoids the two prompts colliding at launch).
        settings.permissionStatus = {
            (PermissionsHelper.hasAccessibility(), PermissionsHelper.hasScreenRecording())
        }
        settings.onGrantAccessibility = {
            PermissionsHelper.requestAccessibility()
            PermissionsHelper.openAccessibilitySettings()
        }
        settings.onGrantScreenRecording = {
            PermissionsHelper.requestScreenRecording()
            PermissionsHelper.openScreenRecordingSettings()
        }

        yabaiGuide.onSetPath = { settings.show() }
        menu.onQuit = { listener.stop(); coordinator.stop(); app.terminate(nil) }
        menu.onOpenSettings = { settings.show() }
        menu.onOpenYabaiSetup = { yabaiGuide.show() }
        menu.onReregisterSignals = {
            installSignals()
            coordinator.requestRefresh()
        }

        // observe display changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                coordinator.requestRefresh(force: true)
                // yabai can take a moment to re-tile after a display/resolution
                // change, so re-place again once its window frames settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    coordinator.requestRefresh(force: true)
                }
            }

        ensureDockController()
        ensureSwitcherTap()
        // First-run guidance (deferred so the run loop is active for the modal).
        // yabai missing is the priority — nothing works without it. Otherwise, if
        // previews are on but permissions are missing, open Settings to grant them.
        DispatchQueue.main.async {
            if args.contains("--open-settings") {
                settings.show()   // open Settings on launch (handy for support/testing)
                // Optional "--tab <n>" picks the tab (default: Appearance).
                var tab = 0
                if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let n = Int(args[i + 1]) {
                    tab = n
                }
                settings.selectTab(at: tab)

            } else if !client.isAvailable() {
                yabaiGuide.show()
            } else if config.dockPreview && !PermissionsHelper.allGranted {
                settings.show()
            }
        }

        installSignals()
        listener.start()
        coordinator.start()

        // Self-heal: yabai's CLI-registered signals are wiped whenever yabai
        // restarts. Periodically re-add ours if they've gone missing, so the
        // instant event path keeps working without a relaunch.
        // A yabai restart recreates its socket, so only a changed socket identity
        // (checked with a local stat) triggers the `signal --list` query.
        var lastSocketIdentity: SignalInstaller.SocketIdentity?
        let signalHealth = Timer(timeInterval: 5, repeats: true) { _ in
            // Activate Dock previews once Accessibility is granted (no relaunch).
            ensureDockController()
            ensureSwitcherTap()
            guard client.isAvailable() else { return }
            let identity = SignalInstaller.yabaiSocketIdentity()
            guard let identity else { lastSocketIdentity = nil; return }  // yabai down
            guard identity != lastSocketIdentity else { return }
            lastSocketIdentity = identity
            if !SignalInstaller.isInstalled(client: client) {
                installSignals()
                coordinator.requestRefresh()
            }
        }
        RunLoop.main.add(signalHealth, forMode: .common)

        _ = menu  // retain
        app.run()
    }
}
