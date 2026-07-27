//
//  ProjectMMetalView.swift
//  Prism
//
//  Bridges MTKView into SwiftUI for the new projectM-backed path. Reuses PresetDroppableMTKView
//  (MilkdropMetalView.swift) as-is for drag-and-drop rather than a second implementation - see
//  that class's own header for why it's a raw AppKit NSDraggingDestination rather than SwiftUI's
//  .onDrop. Only the render delegate differs between the two paths.
//

import MetalKit
import SwiftUI

struct ProjectMMetalView: NSViewRepresentable {
    let audioEngine: CoreAudioTapEngine
    var model: ProjectMVisualizerModel
    var onDropPreset: (URL) -> Void
    var onDropTargetChanged: (Bool) -> Void

    func makeCoordinator() -> ProjectMCoordinator {
        ProjectMCoordinator(audioEngine: audioEngine)
    }

    func makeNSView(context: Context) -> PresetDroppableMTKView {
        let view = PresetDroppableMTKView()
        view.registerForDraggedTypes([.fileURL])
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        view.onDropPreset = onDropPreset
        view.onDropTargetChanged = onDropTargetChanged
        return view
    }

    func updateNSView(_ nsView: PresetDroppableMTKView, context: Context) {
        context.coordinator.updateModelIfNeeded(model)
        nsView.onDropPreset = onDropPreset
        nsView.onDropTargetChanged = onDropTargetChanged
    }
}
