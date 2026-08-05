//
//  ProjectMMetalView.swift
//  Prism
//
//  Bridges MTKView into SwiftUI for the projectM-backed path. Reuses PresetDroppableMTKView
//  as-is for drag-and-drop rather than a second implementation - see that class's own header for
//  why it's a raw AppKit NSDraggingDestination rather than SwiftUI's .onDrop. Only the render
//  delegate differs between the two paths.
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
    // The "only the subject" (no text) layer of ContentView's four-style cycle - see
    // NowPlayingManager.subjectOnlyArtwork/ProjectMCoordinator.AlbumArtLayerCount.
    var albumArtSubjectOnlyImage: NSImage?
    // OCR text alone, no subject - see NowPlayingManager.textOnlyArtwork. Kept separate from
    // albumArtSubjectImage so the coordinator can hold it static while the subject layer
    // beat-zooms independently on top of it.
    var albumArtTextOnlyImage: NSImage?
    // The four-layer stack's own two "background" layers - genuinely non-overlapping with
    // albumArtSubjectOnlyImage/albumArtTextOnlyImage above, unlike albumArtRawImage/
    // albumArtColorKeyedImage (which still carry the whole photo) - see
    // NowPlayingManager.backgroundDetailArtwork/backgroundColorArtwork.
    var albumArtBackgroundDetailImage: NSImage?
    var albumArtBackgroundColorImage: NSImage?
    // How many of the four stacked layers are currently visible, 0...4 - ContentView's "M" hotkey.
    // See ProjectMCoordinator.AlbumArtLayerCount.
    var albumArtVisibleLayerCount: Int
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
        // Real value gets set in updateNSView once the view has a window (and thus a real
        // screen) - view.window is always nil this early, so this is just a same-tick-safe
        // placeholder that updateNSView immediately corrects.
        view.preferredFramesPerSecond = Self.refreshMatchedFramesPerSecond(for: view)
        view.onDropPreset = onDropPreset
        view.onDropTargetChanged = onDropTargetChanged
        return view
    }

    func updateNSView(_ nsView: PresetDroppableMTKView, context: Context) {
        context.coordinator.updateModelIfNeeded(model)
        context.coordinator.updateAlbumArt(
            rawImage: albumArtRawImage, colorKeyedImage: albumArtColorKeyedImage,
            subjectImage: albumArtSubjectImage, subjectOnlyImage: albumArtSubjectOnlyImage,
            textOnlyImage: albumArtTextOnlyImage, backgroundDetailImage: albumArtBackgroundDetailImage,
            backgroundColorImage: albumArtBackgroundColorImage,
            visibleLayerCount: albumArtVisibleLayerCount, hidden: isAlbumArtHidden
        )
        nsView.onDropPreset = onDropPreset
        nsView.onDropTargetChanged = onDropTargetChanged
        // Re-read every update tick (cheap - just an Int) rather than only on window/screen
        // notifications, so dragging the window to a monitor with a different refresh rate picks
        // up the new rate without needing a dedicated NSWindow.didChangeScreenNotification
        // listener. MTKView clamps preferredFramesPerSecond to the display's real vsync rate
        // anyway, so this can never draw faster than the screen actually supports - it just stops
        // us from leaving a higher-refresh screen's extra smoothness on the table (see
        // ProjectMCoordinator.updateDisplayFPS/setTargetFPS for why raising the real draw rate
        // doesn't also speed up presets that correctly normalize against the `fps` builtin).
        nsView.preferredFramesPerSecond = Self.refreshMatchedFramesPerSecond(for: nsView)
    }

    /// The real screen's max refresh rate, so ProMotion/high-refresh displays get fully smooth
    /// output instead of being capped at some arbitrary constant. Falls back to
    /// NSScreen.main (view has no window yet, e.g. during makeNSView) or 60 (no screens at all,
    /// e.g. an early SwiftUI preview render) since MTKView requires a positive value.
    private static func refreshMatchedFramesPerSecond(for view: NSView) -> Int {
        (view.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
    }
}
