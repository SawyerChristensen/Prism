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

    func makeCoordinator() -> MilkdropMetalRenderer {
        MilkdropMetalRenderer(audioEngine: audioEngine, model: model)
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
        // `model` is a reference type, so mutations (e.g. loadPreset(from:)) are already visible to
        // the renderer without re-pushing it; `color`/`bassEnergy` are value types and do need
        // pushing through on every SwiftUI update.
        context.coordinator.color = color
        context.coordinator.bassEnergy = bassEnergy
    }
}
