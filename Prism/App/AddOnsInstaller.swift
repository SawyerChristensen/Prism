//
//  AddOnsInstaller.swift
//  Prism
//

import AppKit

/// Installs the bundled Music.app visualizer plug-in and screen saver (both embedded in
/// Prism.app/Contents/Resources - see the "Embed Visualizer Plugin & Screen Saver" build phase).
/// Neither is loaded in-process by Prism.app itself, so embedding alone does nothing - Music.app
/// and legacyScreenSaver only find them at fixed system locations outside Prism's own sandbox
/// container (~/Library/iTunes/iTunes Plug-ins, ~/Library/Screen Savers).
///
/// Prism ships App Sandboxed (Mac App Store distribution), which rules out writing either
/// straight to those paths the way an unsandboxed installer would:
/// - The screen saver still has a real path: opening a `.saver` bundle via `NSWorkspace` invokes
///   macOS's own built-in installer sheet ("Install this screen saver for you / all users?"),
///   which does the actual file placement itself, outside the sandbox. No entitlement needed, but
///   it's a real (one-click) system prompt, not silent - so this is meant to be triggered from an
///   explicit user action (the settings toggle - see TO DO.md), not fired automatically at launch.
/// - The legacy iTunes/Music visual-plugin protocol has no OS-level installer at all, but the
///   `com.apple.security.files.user-selected.read-write` entitlement lets a sandboxed app write
///   to any folder the user picks via an NSOpenPanel - so an open panel defaulted to
///   ~/Library/iTunes/iTunes Plug-ins stands in for a real installer: one click to grant access,
///   then the copy itself happens here instead of leaving it to a manual Finder drag.
enum AddOnsInstaller {
    private static func resourceURL(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Triggers macOS's built-in screen saver installer sheet. Call this from the settings toggle
    /// once it exists, not automatically - it puts up a system prompt.
    static func installScreenSaver() {
        guard let url = resourceURL("PrismScreenSaver.saver") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copies the bundled visualizer plug-in into ~/Library/iTunes/iTunes Plug-ins so Music.app
    /// picks it up, after the user grants access to that folder via the open panel (App Sandbox
    /// has no other write path there - see the enum's doc comment).
    static func installVisualizerPlugin() {
        guard let pluginURL = resourceURL("PrismVisualizerPlugin.bundle") else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose the iTunes Plug-ins Folder"
        panel.message = "Select \"iTunes Plug-ins\" to install the Prism visualizer plug-in there."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/iTunes/iTunes Plug-ins")

        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        let destinationURL = destinationFolder.appendingPathComponent(pluginURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destinationURL)
        try? FileManager.default.copyItem(at: pluginURL, to: destinationURL)
    }
}
