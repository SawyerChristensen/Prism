//
//  SubjectMasking.swift
//  Prism
//
//  Prototype: isolates album art's main subject via Vision's on-device subject-lifting
//  segmentation (VNGenerateForegroundInstanceMaskRequest) — the same technology behind Photos/
//  Preview's "Copy Subject". Unlike AlbumColors.swift's keyingOutBackground (a color-distance
//  cutout, only correct when the background is a genuinely solid color), this segments the actual
//  subject regardless of what the background looks like — gradient, texture, busy edge-to-edge
//  art, anything.
//
//  NowPlayingManager.keyedArtwork combines both: color-key the background broadly (catches
//  background-colored pixels wherever they appear, including any stray ones the Vision mask's
//  edge missed), then draw the Vision-detected subject back on top at full fidelity via
//  `overlaying(_:)` below — so if the subject happens to share a color with the background (dark
//  clothing on a black cover, say), the color key can't accidentally punch a hole through it,
//  since the subject overlay always wins there.
//

import AppKit
import CoreImage
import Vision

extension NSImage {
    /// Returns a copy of this image with everything but the detected subject(s) made transparent,
    /// or nil if Vision couldn't find a subject (abstract art with no discrete foreground object,
    /// a request failure, etc.) — callers should treat nil as "fall back to another approach,"
    /// not as an error.
    nonisolated func maskingOutBackgroundBySubject() -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }

            let maskedBuffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )

            let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
            let ciContext = CIContext()
            guard let outCGImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return outCGImage.asPixelExactNSImage()
        } catch {
            return nil
        }
    }

    /// Draws `subject` on top of this image with ordinary alpha compositing — wherever `subject`
    /// is transparent, this image shows through; wherever it's opaque, it wins outright. The two
    /// images don't need matching pixel dimensions (Vision's output buffer isn't guaranteed to be
    /// the same resolution as whatever this image's own pixel buffer is); CGContext.draw scales
    /// each to fill the destination canvas regardless of its source size.
    nonisolated func overlaying(_ subject: NSImage) -> NSImage? {
        guard let baseCGImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let subjectCGImage = subject.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = baseCGImage.width, height = baseCGImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(baseCGImage, in: rect)
        context.draw(subjectCGImage, in: rect)

        guard let outCGImage = context.makeImage() else { return nil }
        return outCGImage.asPixelExactNSImage()
    }
}
