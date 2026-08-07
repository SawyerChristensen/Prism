//
//  AppIconManager.swift
//  Prism
//

import AppKit

/// Runtime-only alternate app icon switching, backing the Settings > App Icon tab.
///
/// Both LGPrismIcon (the default, set via ASSETCATALOG_COMPILER_APPICON_NAME) and
/// LGPrismTieDyeIcon (via ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES) compile into Assets.car
/// as full icon families, loadable by name through `NSImage(named:)` - confirmed via `assetutil
/// --info` on the built app's Assets.car. There's no macOS API to persist a choice into the
/// bundle itself the way iOS's UIApplication.setAlternateIconName does, and Prism ships App
/// Sandboxed, so it can't rewrite its own Info.plist-declared icon (the one Finder shows) the way
/// an unsandboxed installer could. Setting `NSApp.applicationIconImage` instead changes the Dock,
/// Cmd-Tab, and About panel icon for the running process - not Finder - so `apply()` needs
/// re-calling at every launch to restore the saved choice.
///
/// `apply()` must not be called from PrismApp.init() - NSApp (AppKit's NSApplication.shared)
/// isn't set up yet that early in a SwiftUI App's lifecycle, and touching it force-unwraps nil.
/// Call it from the root view's `onAppear` instead, once the app has actually finished launching.
enum AppIconManager {
    static let defaultAssetName = "LGPrismIcon"
    static let tieDyeAssetName = "LGPrismTieDyeIcon"

    private static let selectionDefaultsKey = "selectedAppIconAssetName"

    static var selectedAssetName: String {
        get { UserDefaults.standard.string(forKey: selectionDefaultsKey) ?? defaultAssetName }
        set { UserDefaults.standard.set(newValue, forKey: selectionDefaultsKey) }
    }

    /// Applies `selectedAssetName` (or `assetName` if given) to the running app's icon.
    /// `defaultAssetName` is itself a valid named asset (confirmed via `assetutil --info` on the
    /// built app's Assets.car - see the enum's doc comment), so there's no need to separately
    /// capture NSApp's own built-in icon as a fallback; every choice, including the default,
    /// resolves the same way.
    static func apply(_ assetName: String? = nil) {
        let name = assetName ?? selectedAssetName
        guard let icon = NSImage(named: name) else { return }
        NSApp.applicationIconImage = icon
    }
}
