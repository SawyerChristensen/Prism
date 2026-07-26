//
//  MilkdropMetalView.swift
//  Prism
//
//  Bridges MTKView (AppKit) into SwiftUI. MTKView drives its own continuous redraw off the
//  display's actual refresh rate — including ProMotion's 120Hz — independent of SwiftUI's own
//  update cycle, so there's no TimelineView here; MilkdropMetalRenderer.draw(in:) is called
//  directly by MetalKit.
//

import MetalKit
import SwiftUI

struct MilkdropMetalView: NSViewRepresentable {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    var bassEnergy: CGFloat
    var model: MilkdropVisualizerModel

    func makeCoordinator() -> MilkdropMetalCoordinator {
        MilkdropMetalCoordinator(audioEngine: audioEngine, model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        // The wave sits behind the album art in ContentView's ZStack, over a SwiftUI-drawn
        // background color — the Metal layer needs to stay transparent wherever nothing is
        // drawn so that background shows through, rather than painting opaque black over it.
        view.layer?.isOpaque = false
        // Redraw continuously at the display's max rate rather than only `setNeedsDisplay`-driven
        // — this is a live audio visualizer, every frame has new content.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // `color`/`bassEnergy` are value types and need pushing through on every SwiftUI update.
        context.coordinator.color = color
        context.coordinator.bassEnergy = bassEnergy
        // `model` is a reference type, but ContentView.loadPresetAndTrack now hands down a *new*
        // MilkdropVisualizerModel instance per preset load (see its own doc comment on why) rather
        // than mutating the existing one in place — so unlike color/bassEnergy, this one does need
        // an identity check: a different instance than last time means a new preset just loaded,
        // which starts a crossfade rather than just updating a property in place.
        context.coordinator.updateModelIfNeeded(model)
    }
}
