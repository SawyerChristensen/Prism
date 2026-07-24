//
//  ContentView.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI

struct ContentView: View {
    @State private var audioEngine = CoreAudioTapEngine()
    @State private var nowPlaying = NowPlayingManager()
    @State private var permissions = PermissionsManager()

    var body: some View {
        let bgColor = nowPlaying.albumBackgroundColor.map { Color(nsColor: $0) } ?? Color(NSColor.windowBackgroundColor)
        let fgColor = nowPlaying.albumForegroundColor.map { Color(nsColor: $0) } ?? .accentColor
        
        VStack(spacing: 30) {
            WaveformView(levels: audioEngine.levels, color: fgColor)
                .frame(height: 150)
            
            Spacer()
            Spacer()

            VStack {
                if let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
                    if let artwork = nowPlaying.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            //.shadow(color: fgColor, radius: 6)
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
                    
                    Spacer()

                    HStack() {
                        Text(track)
                            .font(.headline)
                            .foregroundStyle(fgColor)
                        
                        Spacer()
                        
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(fgColor.opacity(0.8))
                    }
                } else {
                    Text("") //do we need this?
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(bgColor)
        .animation(.easeInOut(duration: 0.5), value: bgColor)
        .onAppear {
            permissions.checkAndRequestPermissions()
            nowPlaying.startPolling()
        }
        .task {
            await audioEngine.start()
        }
    }
}

// Renders live frequency-band levels produced by AudioCaptureEngine's FFT.
struct WaveformView: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(height: max(4, levels[index] * 150))
                    .animation(.spring(response: 0.15, dampingFraction: 0.7), value: levels[index])
            }
        }
    }
}

#Preview {
    ContentView()
}
