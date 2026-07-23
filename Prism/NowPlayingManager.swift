//
//  NowPlayingManager.swift
//  Prism
//
//  Polls Spotify and Music via Apple Events for the current track/artist. Exercises the
//  com.apple.security.automation.apple-events entitlement end-to-end, rather than just
//  the dummy permission-probe AppleScript in PermissionManager.
//

import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.prism.app", category: "NowPlayingManager")

@Observable
final class NowPlayingManager {
    private(set) var trackName: String?
    private(set) var artistName: String?
    private(set) var sourceApp: String?

    private var timer: Timer?

    func startPolling() {
        logger.debug("startPolling() called")
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private static let supportedApps: [(name: String, bundleID: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
    ]

    private func refresh() {
        for app in Self.supportedApps {
            if let info = Self.queryNowPlaying(app: app) {
                trackName = info.track
                artistName = info.artist
                sourceApp = app.name
                return
            }
        }
        trackName = nil
        artistName = nil
        sourceApp = nil
    }

    private static func queryNowPlaying(app: (name: String, bundleID: String)) -> (track: String, artist: String)? {
        // `application "X" is running` is unreliable from inside App Sandbox (returns false
        // even when the app is genuinely running), so check via NSWorkspace instead — that's a
        // plain Cocoa API and doesn't need Apple Events at all.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app.bundleID }) else {
            return nil
        }

        // Addressing by bundle id (rather than by name, e.g. `tell application "Spotify"`) avoids
        // an App Sandbox quirk where by-name Apple Event addressing fails to resolve the target
        // process and surfaces as a generic "Application isn't running" (-600) error.
        let script = """
        tell application id "\(app.bundleID)"
            if player state is playing then
                return (name of current track) & "\u{241F}" & (artist of current track)
            end if
        end tell
        return ""
        """
        guard let appleScript = NSAppleScript(source: script) else {
            logger.error("NSAppleScript(source:) init failed for \(app.name, privacy: .public)")
            return nil
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            logger.error("AppleScript error for \(app.name, privacy: .public): \(error, privacy: .public)")
            return nil
        }

        let value = result.stringValue ?? ""
        logger.debug("raw result for \(app.name, privacy: .public): \"\(value, privacy: .public)\"")
        let parts = value.components(separatedBy: "\u{241F}")
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        logger.debug("now playing via \(app.name, privacy: .public): \(parts[0], privacy: .public) — \(parts[1], privacy: .public)")
        return (track: parts[0], artist: parts[1])
    }
}
