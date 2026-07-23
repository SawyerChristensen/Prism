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
    private(set) var albumName: String?
    private(set) var sourceApp: String?
    private(set) var artwork: NSImage?

    private var timer: Timer?

    // Identifies the currently loaded track so artwork is only re-fetched when the track
    // actually changes, rather than on every 2-second poll.
    private var currentTrackKey: String?

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
                albumName = info.album.isEmpty ? nil : info.album
                sourceApp = app.name

                let key = "\(app.bundleID)|\(info.track)|\(info.artist)|\(info.album)"
                if key != currentTrackKey {
                    currentTrackKey = key
                    loadArtwork(app: app, artist: info.artist, album: info.album)
                }
                return
            }
        }
        trackName = nil
        artistName = nil
        albumName = nil
        sourceApp = nil
        artwork = nil
        currentTrackKey = nil
    }

    private static func queryNowPlaying(app: (name: String, bundleID: String)) -> (track: String, artist: String, album: String)? {
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
                return (name of current track) & "\u{241F}" & (artist of current track) & "\u{241F}" & (album of current track)
            end if
        end tell
        return ""
        """
        guard let result = runScript(script, appName: app.name) else { return nil }

        let value = result.stringValue ?? ""
        logger.debug("raw result for \(app.name, privacy: .public): \"\(value, privacy: .public)\"")
        let parts = value.components(separatedBy: "\u{241F}")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        logger.debug("now playing via \(app.name, privacy: .public): \(parts[0], privacy: .public) — \(parts[1], privacy: .public) — \(parts[2], privacy: .public)")
        return (track: parts[0], artist: parts[1], album: parts[2])
    }

    // MARK: - Artwork

    private func loadArtwork(app: (name: String, bundleID: String), artist: String, album: String) {
        artwork = nil
        switch app.bundleID {
        case "com.spotify.client":
            loadSpotifyArtwork()
        case "com.apple.Music":
            // App Sandbox blocks reading Music's embedded artwork via Apple Events (every
            // artwork property raises a -10004 privilege violation), so look the album art up
            // by artist + album through the public iTunes Search API instead.
            loadArtworkFromiTunes(artist: artist, album: album)
        default:
            break
        }
    }

    // Spotify exposes the artwork as a remote URL, so fetch the image over the network.
    private func loadSpotifyArtwork() {
        let script = """
        tell application id "com.spotify.client"
            if player state is playing then
                return artwork url of current track
            end if
        end tell
        return ""
        """
        guard let result = Self.runScript(script, appName: "Spotify"),
              let urlString = result.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else {
                return
            }
            await MainActor.run { self?.artwork = image }
        }
    }

    // Response shape for the iTunes Search API album lookup.
    private struct iTunesSearchResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    // Looks album art up by artist + album through the iTunes Search API. Used for sources
    // (like Music) whose artwork can't be read directly.
    private func loadArtworkFromiTunes(artist: String, album: String) {
        guard !album.isEmpty || !artist.isEmpty else { return }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return }

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(iTunesSearchResponse.self, from: data),
                  let thumbURL = response.results.first?.artworkUrl100 else {
                return
            }

            // The API returns a 100×100 thumbnail URL; request a larger rendition instead.
            let highResURL = thumbURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: highResURL),
                  let (imageData, _) = try? await URLSession.shared.data(from: artURL),
                  let image = NSImage(data: imageData) else {
                return
            }
            await MainActor.run { self?.artwork = image }
        }
    }

    // MARK: - Helpers

    private static func runScript(_ source: String, appName: String) -> NSAppleEventDescriptor? {
        guard let appleScript = NSAppleScript(source: source) else {
            logger.error("NSAppleScript(source:) init failed for \(appName, privacy: .public)")
            return nil
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            logger.error("AppleScript error for \(appName, privacy: .public): \(error, privacy: .public)")
            return nil
        }
        return result
    }
}
