//
//  PresetDroppableMTKView.swift
//  Prism
//
//  An `MTKView` that also accepts a dropped `.milk` file, via AppKit's own
//  `NSDraggingDestination` — SwiftUI's `.onDrop` modifier, layered on top of this same view via
//  the old MilkdropVisualizerView, showed *zero* drag recognition at all (no cursor/highlight
//  feedback, meaning nothing in the hierarchy was actually registering as a drop target — not
//  just a failed read afterward). Registering directly on the view that already correctly
//  receives every other event (mouse taps) sidesteps that unreliability entirely, using the same
//  mechanism a plain AppKit app would. This doesn't conflict with tap gestures added by whatever
//  SwiftUI view wraps this: `draggingEntered`/`performDragOperation` only ever fire during a
//  genuine incoming drag session from another process (Finder), a completely separate AppKit
//  dispatch path from `mouseDown`/`mouseUp` click handling.
//

import AppKit
import MetalKit

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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = milkURL(from: sender) != nil
        onDropTargetChanged?(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        milkURL(from: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargetChanged?(false)
        guard let url = milkURL(from: sender) else { return false }
        onDropPreset?(url)
        return true
    }
}
