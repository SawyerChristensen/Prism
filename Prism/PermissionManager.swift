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
    
    func checkAndRequestPermissions() {
        requestScreenCapturePermission()
        requestAutomationPermission(for: "Spotify")
        // requestAutomationPermission(for: "Music") // Apple Music
    }
    
    private func requestScreenCapturePermission() {
        // CGRequestScreenCaptureAccess triggers the prompt on macOS 10.15+
        // Required to use ScreenCaptureKit for system audio
        self.hasAudioPermission = CGPreflightScreenCaptureAccess()
        if !self.hasAudioPermission {
            let granted = CGRequestScreenCaptureAccess()
            self.hasAudioPermission = granted
        }
    }
    
    private func requestAutomationPermission(for appName: String) {
        // Executing a dummy AppleScript targets the app and triggers the permission prompt
        let scriptSource = "tell application \"\(appName)\" to return"
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            // Only a clean send (no error at all) means Apple Events access is actually granted.
            // Any error — -1743 (not yet authorized), -600 (send blocked, e.g. by App Sandbox),
            // or anything else — means it did NOT succeed, so treat all of them as not granted.
            self.hasAutomationPermission = errorInfo == nil
        }
    }
}

