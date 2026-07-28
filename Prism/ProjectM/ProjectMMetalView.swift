//
//  ProjectMMetalView.swift
//  Prism
//
//  Bridges MTKView into SwiftUI for the new projectM-backed path. Reuses PresetDroppableMTKView
//  (MilkdropMetalView.swift) as-is for drag-and-drop rather than a second implementation - see
//  that class's own header for why it's a raw AppKit NSDraggingDestination rather than SwiftUI's
//  .onDrop. Only the render delegate differs between the two paths.
//

import AppKit
import MetalKit
import SwiftUI

struct ProjectMMetalView: NSViewRepresentable {
    let audioEngine: CoreAudioTapEngine
    var model: ProjectMVisualizerModel
    // Album art now composites (fade in, background/subject erosion, distortion against the wave)
    // inside the Metal render pass itself - see ProjectMCoordinator.updateAlbumArt/draw(in:) -
    // rather than as a separate SwiftUI layer stacked on top. The unmodified cover, the color-keyed
    // variant, and the subject-plus-text "end graphic" are all needed so the coordinator can
    // reinstate .combined's "color-key the background out, keep the subject (and any OCR'd text)
    // at full fidelity" default (rather than the bare Vision mask alone) before choreographing the
    // background eroding away ahead of that end graphic - see
    // NowPlayingManager.rawArtwork/colorKeyedArtwork/subjectArtwork.
    var albumArtRawImage: NSImage?
    var albumArtColorKeyedImage: NSImage?
    var albumArtSubjectImage: NSImage?
    var isAlbumArtHidden: Bool
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
        context.coordinator.updateAlbumArt(
            rawImage: albumArtRawImage, colorKeyedImage: albumArtColorKeyedImage,
            subjectImage: albumArtSubjectImage, hidden: isAlbumArtHidden
        )
        nsView.onDropPreset = onDropPreset
        nsView.onDropTargetChanged = onDropTargetChanged
    }
}
