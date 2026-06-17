import CmuxTerminalCore

/// App-target alias for ``CmuxTerminalCore/GhosttyConfig``, lifted into
/// CmuxTerminalCore in stack D tranche A. Keeps every `GhosttyConfig` call site
/// (and `GhosttyConfig.ColorSchemePreference` / `GhosttyConfig.UserAppearanceConfigSummary`
/// member lookups) byte-identical across the app target.
typealias GhosttyConfig = CmuxTerminalCore.GhosttyConfig

extension GhosttyConfig {
    /// The Quick Terminal global toggle shortcut, parsed from the raw
    /// `keybind = global:…=toggle_quick_terminal` directive retained by the
    /// config. Lives here (not in CmuxTerminalCore) because `StoredShortcut`
    /// and `parseGhosttyGlobalKeybind` are owned by the app target.
    var quickTerminalShortcut: StoredShortcut? {
        quickTerminalKeybindRaw.flatMap {
            StoredShortcut.parseGhosttyGlobalKeybind($0, action: "toggle_quick_terminal")
        }
    }
}
