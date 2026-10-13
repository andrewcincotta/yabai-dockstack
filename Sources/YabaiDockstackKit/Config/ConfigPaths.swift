import Foundation

/// yabai-dockstack never reads or writes the user's yabairc/skhdrc; its only
/// on-disk paths are its own (config.json and the helper scripts dir).
public enum ConfigPaths {
    public static var scriptsDir: String { ("~/.config/yabai-dockstack/scripts" as NSString).expandingTildeInPath }
}
