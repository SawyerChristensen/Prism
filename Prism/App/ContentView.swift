//
//  ContentView.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var audioEngine = CoreAudioTapEngine()
    @State private var nowPlaying = NowPlayingManager()
    @State private var permissions = PermissionsManager()
    @State private var visualizerModel = MilkdropVisualizerModel()
    @State private var isPresetImporterPresented = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let bgColor = nowPlaying.albumBackgroundColor.map { Color(nsColor: $0) } ?? Color(NSColor.windowBackgroundColor)
        let fgColor = nowPlaying.albumForegroundColor.map { Color(nsColor: $0) } ?? .accentColor

        let bassEnergy = audioEngine.levels.prefix(4).reduce(0, +) / 4

        ZStack {
            // The wave
            MilkdropVisualizerView(audioEngine: audioEngine, color: fgColor, bassEnergy: bassEnergy, model: visualizerModel)
            
            // The album art/text
            if let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
                // Text pinned to the bottom
                VStack {
                    Spacer()
                    
                    /*if let artwork = nowPlaying.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 250, height: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            //.shadow(color: fgColor, radius: 6)
                    } /*else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 250, height: 250)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }*/*/
                    
                    Spacer()
                    
                    HStack {
                        Text(track)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(fgColor)
                            .padding()
                        
                        Spacer()
                        
                        Text(artist)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(fgColor.opacity(0.8))
                            .padding()
                    }
                }
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(bgColor)
        .animation(.easeInOut(duration: 0.5), value: bgColor)
        // Wave-only .milk preset loading (see MilkdropPresetFile.swift/MilkdropVisualizerModel):
        // "O" opens a file picker, and the preset's name shows briefly so there's some feedback
        // that a load actually happened, since nothing else in the UI names the active preset.
        .overlay(alignment: .topLeading) {
            if let presetName = visualizerModel.presetName {
                Text(presetName)
                    .font(.caption)
                    .foregroundStyle(fgColor.opacity(0.6))
                    .padding(8)
            }
        }
        .fileImporter(
            isPresented: $isPresetImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "milk") ?? .plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            visualizerModel.loadPreset(from: url)
        }
        .alert(
            "Couldn't Load Preset",
            isPresented: Binding(
                get: { visualizerModel.presetLoadError != nil },
                set: { if !$0 { visualizerModel.presetLoadError = nil } }
            )
        ) {
            Button("OK") { visualizerModel.presetLoadError = nil }
        } message: {
            Text(visualizerModel.presetLoadError ?? "")
        }
        // Keyboard control surface, mirroring the spirit of MilkDrop pluginshell's hotkeys
        // (arrow keys / F / Esc) even though there's no preset deck to navigate here: Space
        // cycles the visual mode (same action as tapping the visualizer), F toggles fullscreen.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [" ", "f", "F", "o", "O"]) { press in
            switch press.characters {
            case " ":
                visualizerModel.cycleMode()
                return .handled
            case "f", "F":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            case "o", "O":
                isPresetImporterPresented = true
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear {
            PrismDebug.trace("ContentView.onAppear")
            permissions.checkAndRequestPermissions()
            nowPlaying.startPolling()
            isFocused = true
            PrismDebug.trace("ContentView.onAppear returned (both calls are async/backgrounded)")
        }
        .task {
            PrismDebug.trace("ContentView.task -> audioEngine.start() awaiting")
            await audioEngine.start()
            PrismDebug.trace("ContentView.task -> audioEngine.start() returned")
        }
    }
}
