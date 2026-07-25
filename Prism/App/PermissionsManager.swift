//
//  PermissionManager.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import Foundation
import ApplicationServices
import ScreenCaptureKit

@Observable
class PermissionsManager {
    var hasAudioPermission = false
    var hasAutomationPermission = false

    /// Both underlying calls are synchronous, and either can block for a long time waiting on a
    /// TCC permission dialog (screen recording) or an Apple Events round-trip that may need to
    /// launch the target app first (automation probe). Neither is safe to run on the main thread —
    /// doing so freezes the whole UI, indistinguishable from a real hang, until the dialog is
    /// answered. Run them on a background task instead.
    func checkAndRequestPermissions() {
        PrismDebug.trace("PermissionsManager.checkAndRequestPermissions() dispatched")
        Task.detached(priority: .userInitiated) {
            let hasAudio = Self.requestScreenCapturePermission()
            let hasAutomation = Self.requestAutomationPermission(for: "Spotify")
            // Self.requestAutomationPermission(for: "Music") // Apple Music
            await MainActor.run {
                self.hasAudioPermission = hasAudio
                self.hasAutomationPermission = hasAutomation
            }
        }
    }

    private nonisolated static func requestScreenCapturePermission() -> Bool {
        // CGRequestScreenCaptureAccess triggers the prompt on macOS 10.15+
        // Required to use ScreenCaptureKit for system audio
        PrismDebug.trace("CGPreflightScreenCaptureAccess() start")
        var granted = CGPreflightScreenCaptureAccess()
        PrismDebug.trace("CGPreflightScreenCaptureAccess() -> \(granted)")
        if !granted {
            PrismDebug.trace("CGRequestScreenCaptureAccess() start (may block on system dialog)")
            granted = CGRequestScreenCaptureAccess()
            PrismDebug.trace("CGRequestScreenCaptureAccess() -> \(granted)")
        }
        return granted
    }

    private nonisolated static func requestAutomationPermission(for appName: String) -> Bool {
        // Executing a dummy AppleScript targets the app and triggers the permission prompt.
        // `tell application "X"` will launch X if it isn't running, so this can take a while.
        PrismDebug.trace("automation probe for \(appName) start (may launch the app)")
        let scriptSource = "tell application \"\(appName)\" to return"
        guard let script = NSAppleScript(source: scriptSource) else { return false }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        PrismDebug.trace("automation probe for \(appName) -> \(errorInfo == nil ? "granted" : "denied/error \(errorInfo!)")")
        // Only a clean send (no error at all) means Apple Events access is actually granted.
        // Any error — -1743 (not yet authorized), -600 (send blocked, e.g. by App Sandbox),
        // or anything else — means it did NOT succeed, so treat all of them as not granted.
        return errorInfo == nil
    }
}

