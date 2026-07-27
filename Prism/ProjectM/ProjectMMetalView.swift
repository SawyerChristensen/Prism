//
//  ProjectMMetalView.swift
//  Prism
//
//  Bridges MTKView into SwiftUI for the new projectM-backed path — deliberately minimal for this
//  first-pixels-on-screen milestone: no drag-and-drop yet (that's PresetDroppableMTKView's job,
//  still used by the old MilkdropMetalView; repointing it at this path is Phase 5, not this one).
//

import MetalKit
import SwiftUI

struct ProjectMMetalView: NSViewRepresentable {
    let audioEngine: CoreAudioTapEngine
    var model: ProjectMVisualizerModel

    func makeCoordinator() -> ProjectMCoordinator {
        ProjectMCoordinator(audioEngine: audioEngine)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.updateModelIfNeeded(model)
    }
}
