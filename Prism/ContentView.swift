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
        
        let bassEnergy = audioEngine.levels.prefix(4).reduce(0, +) / 4

        ZStack {
            // The wave
            MilkdropVisualizerView(audioEngine: audioEngine, color: fgColor, bassEnergy: bassEnergy)
                .frame(height: 150)
            
            // The album art
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
                
                // Text pinned to the bottom
                VStack {
                    Spacer()
                    
                    HStack {
                        Text(track)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(fgColor)
                        
                        Spacer()
                        
                        Text(artist)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(fgColor.opacity(0.8))
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(bgColor)
        .animation(.easeInOut(duration: 0.5), value: bgColor)
        .onAppear {
            PrismDebug.trace("ContentView.onAppear")
            permissions.checkAndRequestPermissions()
            nowPlaying.startPolling()
            PrismDebug.trace("ContentView.onAppear returned (both calls are async/backgrounded)")
        }
        .task {
            PrismDebug.trace("ContentView.task -> audioEngine.start() awaiting")
            await audioEngine.start()
            PrismDebug.trace("ContentView.task -> audioEngine.start() returned")
        }
    }
}
