//
//  MilkdropVisualizerView.swift
//  Prism
//
//  Public-facing wrapper: owns the mode/params model, forwards a tap gesture to cycle modes, and
//  hosts the actual GPU renderer (MilkdropMetalView / MilkdropMetalRenderer). The old CPU
//  CGContext-based Canvas renderer lived here — see MilkdropMetalRenderer.swift's header for why
//  it moved to Metal (fullscreen on a large/high-refresh display was CPU-bound and couldn't hold
//  120fps; a GPU-based feedback buffer also gives real headroom for future 3D/warp effects, which
//  a CPU bitmap never would have).
//

import SwiftUI

@Observable
final class MilkdropVisualizerModel {
    var mode: MilkdropWaveMode = .line
    var params = MilkdropWaveformParams()

    func cycleMode() {
        let all = MilkdropWaveMode.allCases
        let idx = all.firstIndex(of: mode) ?? 0
        mode = all[(idx + 1) % all.count]
    }
}

struct MilkdropVisualizerView: View {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    /// 0...1 bass energy, used to thicken the line the way MilkDrop's mod-alpha-by-volume does.
    var bassEnergy: CGFloat = 0
    /// Owned by the caller (ContentView) so a keyboard shortcut can drive mode-cycling too, not
    /// just the tap gesture below.
    var model: MilkdropVisualizerModel

    var body: some View {
        MilkdropMetalView(audioEngine: audioEngine, color: color, bassEnergy: bassEnergy, model: model)
            .contentShape(Rectangle())
            .onTapGesture { model.cycleMode() }
    }
}
