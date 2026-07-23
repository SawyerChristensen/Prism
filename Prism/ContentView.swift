//
//  ContentView.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI

struct ContentView: View {
    @State private var permissions = PermissionsManager()
    @State private var nowPlaying = NowPlayingManager()

    // --- Audio engine A/B toggle ---
    // Active: Core Audio Process Taps (lighter permission, no Screen Recording prompt, macOS 14.4+).
    @State private var audioEngine = CoreAudioTapEngine()
    // Alternative: ScreenCaptureKit-based capture (needs Screen Recording permission).
    // Swap the line above for this one to compare — nothing else in this file needs to change.
    // @State private var audioEngine = AudioCaptureEngine()

    var body: some View {
        VStack(spacing: 30) {
            WaveformView(levels: audioEngine.levels)
                .frame(height: 150)
                .padding()

            VStack(spacing: 12) {
                if let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
                    if let artwork = nowPlaying.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 200, height: 200)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    VStack(spacing: 4) {
                        Text(track)
                            .font(.headline)
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let album = nowPlaying.albumName {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let source = nowPlaying.sourceApp {
                            Text("via \(source)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Not Playing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 400)
        .onAppear {
            permissions.checkAndRequestPermissions()
            nowPlaying.startPolling()
        }
        .task {
            // Each engine gates on its own TCC permission internally (Screen Recording for
            // ScreenCaptureKit, a lighter audio-recording permission for Core Audio Taps), so
            // capture is simply attempted on appear rather than gated on `permissions.hasAudioPermission`
            // (which specifically tracks the ScreenCaptureKit/Screen Recording permission).
            await audioEngine.start()
        }
    }
}

// Renders live frequency-band levels produced by AudioCaptureEngine's FFT.
struct WaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .bottom,
                        endPoint: .top
                    ))
                    .frame(height: max(4, levels[index] * 150))
                    .animation(.spring(response: 0.15, dampingFraction: 0.7), value: levels[index])
            }
        }
    }
}

#Preview {
    ContentView()
}
