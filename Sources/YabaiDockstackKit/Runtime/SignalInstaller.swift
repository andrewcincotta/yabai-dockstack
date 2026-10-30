import Foundation

/// Registers/unregisters the yabai signals that poke the app, so the user never
/// has to edit ~/.yabairc. Idempotent: install removes our labels first, then adds.
public enum SignalInstaller {
    /// yabai events that should trigger a redraw.
    public static let events = [
        "window_focused",
        "window_moved",
        "window_resized",
        "window_created",
        "window_destroyed",
        "space_changed",
        "display_changed",
        "application_front_switched",
        "window_minimized",
        "window_deminimized",
        "application_hidden",
        "application_visible",
        "application_terminated",
    ]

    /// Events whose pokes bypass the redraw diff: screen geometry changed, which
    /// the stack data doesn't capture.
    public static let forceEvents: Set<String> = ["display_changed"]

    public static func label(for event: String) -> String { "yabai-dockstack-\(event)" }

    public struct Spec: Equatable {
        public let event: String
        public let label: String
        public let action: String
    }

    /// Pure, testable: the signal specs for a given app binary path.
    public static func specs(appBinaryPath: String) -> [Spec] {
        events.map { event in
            Spec(event: event,
                 label: label(for: event),
                 action: "\"\(appBinaryPath)\" --refresh"
                    + (forceEvents.contains(event) ? " --force" : ""))
        }
    }

    public static func install(client: YabaiClient, appBinaryPath: String) {
        for spec in specs(appBinaryPath: appBinaryPath) {
            client.removeSignal(label: spec.label)   // idempotent
            client.addSignal(event: spec.event, label: spec.label, action: spec.action)
        }
    }

    public static func uninstall(client: YabaiClient) {
        for event in events { client.removeSignal(label: label(for: event)) }
    }

    /// Identity of yabai's control socket. yabai recreates it on every start, and
    /// CLI-registered signals vanish with it, so a change means "re-check signals".
    public struct SocketIdentity: Equatable {
        public let inode: UInt64
        public let mtimeSec: Int
        public let mtimeNsec: Int
    }

    /// Local `stat` of `/tmp/yabai_$USER.socket` — no yabai query. nil when absent.
    public static func yabaiSocketIdentity(
        path: String = "/tmp/yabai_\(NSUserName()).socket") -> SocketIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return SocketIdentity(inode: UInt64(st.st_ino),
                              mtimeSec: Int(st.st_mtimespec.tv_sec),
                              mtimeNsec: Int(st.st_mtimespec.tv_nsec))
    }

    public static func isInstalled(client: YabaiClient) -> Bool {
        let installed = Set(client.listSignalLabels())
        return events.allSatisfy { installed.contains(label(for: $0)) }
    }
}
