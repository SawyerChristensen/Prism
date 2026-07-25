//
//  PixelExactImage.swift
//  Prism
//
//  NSImage(cgImage:size:) doesn't keep the CGImage as-is — it wraps it in a lazy
//  NSCGImageSnapshotRep whose *reported* pixel dimensions are `size (points) *
//  NSScreen.main.backingScaleFactor`, not the source CGImage's actual pixel dimensions.
//  Confirmed empirically: a 1200x1200 CGImage wrapped this way on a 2x Retina display reports as
//  an NSCGImageSnapshotRep at 2400x2400, and every subsequent draw/re-extraction has to resample
//  through that phantom upscale. AlbumColors/SubjectMasking/TextExtraction each produce a new
//  image via CGContext and then feed it into the next processing step (color-key -> subject
//  overlay -> text overlay) — every intermediate NSImage(cgImage:size:) in that chain adds another
//  lossy resample generation, which is why more processing steps visibly compounded into a
//  blurrier result even though the underlying pixel data barely changed.
//
//  NSBitmapImageRep(cgImage:) instead copies the CGImage's real pixel data directly into a
//  representation sized to match — same kind of representation `NSImage(contentsOfFile:)`
//  produces for a freshly loaded image, with no scale-dependent resampling on access.
//

import AppKit

extension CGImage {
    /// Wraps this CGImage in an NSImage backed by a pixel-exact NSBitmapImageRep, avoiding the
    /// lazy NSCGImageSnapshotRep resampling that NSImage(cgImage:size:) introduces.
    nonisolated func asPixelExactNSImage() -> NSImage {
        let rep = NSBitmapImageRep(cgImage: self)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
