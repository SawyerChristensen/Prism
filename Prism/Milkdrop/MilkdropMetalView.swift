//
//  MilkdropMetalView.swift
//  Prism
//
//  Bridges MTKView (AppKit) into SwiftUI. MTKView drives its own continuous redraw off the
//  display's actual refresh rate — including ProMotion's 120Hz — independent of SwiftUI's own
//  update cycle, so there's no TimelineView here; MilkdropMetalRenderer.draw(in:) is called
//  directly by MetalKit.
//

import AppKit
import MetalKit
import SwiftUI

/// A plain `MTKView` that also accepts a dropped `.milk` file, via AppKit's own
/// `NSDraggingDestination` — SwiftUI's `.onDrop` modifier, layered on top of this same view via
/// `MilkdropVisualizerView`, showed *zero* drag recognition at all (no cursor/highlight feedback,
/// meaning nothing in the hierarchy was actually registering as a drop target — not just a failed
/// read afterward). Registering directly on the view that already correctly receives every other
/// event (mouse taps, via `MilkdropVisualizerView`'s `.onTapGesture`) sidesteps that unreliability
/// entirely, using the same mechanism a plain AppKit app would. This doesn't conflict with the
/// existing tap gesture: `draggingEntered`/`performDragOperation` only ever fire during a genuine
/// incoming drag session from another process (Finder), a completely separate AppKit dispatch path
/// from `mouseDown`/`mouseUp` click handling.
final class PresetDroppableMTKView: MTKView {
    var onDropPreset: ((URL) -> Void)?
    var onDropTargetChanged: ((Bool) -> Void)?

    /// Reads a dropped `.milk` file's URL directly off the dragging pasteboard — the traditional,
    /// sandbox-blessed way for an App Sandbox app to get read access to an externally-dropped file
    /// (same trust model as an Open panel), rather than going through `NSItemProvider`, which is
    /// primarily an iOS/Share-extension mechanism and has had more friction under App Sandbox on
    /// macOS specifically. Returns `nil` for a drag that isn't (or doesn't contain) a `.milk` file,
    /// so non-preset drags correctly show a reject cursor instead of being silently accepted.
    private func milkURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { $0.pathExtension.lowercased() == "milk" }
    }

    // Temporary diagnostic logging (unconditional `NSLog`, not `PrismDebug.trace`) while tracking
    // down a "drag-and-drop still doesn't work, cursor never changes" report — `NSLog` shows up in
    // Console.app regardless of how the app was launched (Xcode's console, a directly-executed
    // binary in Terminal, or a plain Finder double-click, unlike a raw `print()`, which only reaches
    // *somewhere visible* for the first two of those). If `draggingEntered` never logs at all, this
    // view isn't being asked about drags in the first place — a different problem than the URL/
    // extension check being wrong. Remove once drag-and-drop is confirmed working live.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types?.map(\.rawValue) ?? []
        NSLog("Prism[drop]: draggingEntered, pasteboard types = %@", types)
        let accepts = milkURL(from: sender) != nil
        NSLog("Prism[drop]: draggingEntered accepts=%@", accepts ? "true" : "false")
        onDropTargetChanged?(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        milkURL(from: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        NSLog("Prism[drop]: draggingExited")
        onDropTargetChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NSLog("Prism[drop]: performDragOperation")
        onDropTargetChanged?(false)
        guard let url = milkURL(from: sender) else {
            NSLog("Prism[drop]: performDragOperation found no .milk URL")
            return false
        }
        onDropPreset?(url)
        return true
    }
}

struct MilkdropMetalView: NSViewRepresentable {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    var bassEnergy: CGFloat
    var model: MilkdropVisualizerModel
    var onDropPreset: (URL) -> Void
    var onDropTargetChanged: (Bool) -> Void

    func makeCoordinator() -> MilkdropMetalCoordinator {
        MilkdropMetalCoordinator(audioEngine: audioEngine, model: model)
    }

    func makeNSView(context: Context) -> PresetDroppableMTKView {
        let view = PresetDroppableMTKView()
        view.registerForDraggedTypes([.fileURL])
        NSLog("Prism[drop]: makeNSView registered draggedTypes = %@", view.registeredDraggedTypes.map(\.rawValue))
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
        view.onDropPreset = onDropPreset
        view.onDropTargetChanged = onDropTargetChanged
        return view
    }

    func updateNSView(_ nsView: PresetDroppableMTKView, context: Context) {
        // `color`/`bassEnergy` are value types and need pushing through on every SwiftUI update.
        context.coordinator.color = color
        context.coordinator.bassEnergy = bassEnergy
        // `model` is a reference type, but ContentView.loadPresetAndTrack now hands down a *new*
        // MilkdropVisualizerModel instance per preset load (see its own doc comment on why) rather
        // than mutating the existing one in place — so unlike color/bassEnergy, this one does need
        // an identity check: a different instance than last time means a new preset just loaded,
        // which starts a crossfade rather than just updating a property in place.
        context.coordinator.updateModelIfNeeded(model)
        // Reassigned every update rather than only in makeNSView: a closure has no identity to
        // compare, so this is the only way to keep it pointing at ContentView's current methods
        // (capturing current @State, not whatever was live the first time this view was created).
        nsView.onDropPreset = onDropPreset
        nsView.onDropTargetChanged = onDropTargetChanged
    }
}
