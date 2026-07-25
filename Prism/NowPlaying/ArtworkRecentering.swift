//
//  ArtworkRecentering.swift
//  Prism
//
//  Final compositing step: once background-removal/masking has left large transparent margins
//  around the subject (a photo that composed the subject off-center, or a Vision-detected subject
//  sitting toward one edge), tightly crop to the actual remaining content and recenter it —
//  otherwise a subject in, say, the bottom-right corner stays pinned there even after everything
//  around it goes transparent, wasting most of the fixed display frame on empty space.
//
//  Deliberately the *last* step in NowPlayingManager.compositeArtwork, after text overlay too —
//  cropping any earlier (before the subject/color-key masking settles, or before text gets drawn
//  back in) would crop against an incomplete opaque region and risk cutting off content that
//  hadn't been composited back in yet.
//

import AppKit

extension NSImage {
    /// Crops exactly to the tight bounding box of this image's non-transparent content — no
    /// padding added back in, so content that has transparency all the way to some edge of that
    /// box ends up touching the new frame's edge there. Returns self unchanged if there's nothing
    /// meaningful to remove (content already fills virtually the whole frame — e.g. an
    /// unprocessed opaque original) or if this image has no CGImage representation.
    nonisolated func recenteredOnOpaqueContent(threshold: UInt8 = 8) -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return self }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Top-down buffer (CGContext.draw always flips into top-down storage regardless of Core
        // Graphics' own bottom-up draw coordinate convention — confirmed empirically elsewhere in
        // this file's neighbors, e.g. TextExtraction.swift) — matches CGImage.cropping(to:)'s own
        // convention directly, so the bounding box found below needs no flip before cropping.
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                guard pixels[rowStart + x * bytesPerPixel + 3] > threshold else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return self } // fully transparent — nothing to crop to

        let contentWidth = maxX - minX + 1
        let contentHeight = maxY - minY + 1
        // Content already fills virtually the whole frame (nothing was actually "disposed of" by
        // masking, e.g. an unprocessed opaque original) — skip rather than force a needless
        // resample generation.
        guard contentWidth < Int(Double(width) * 0.98) || contentHeight < Int(Double(height) * 0.98) else { return self }

        let rect = CGRect(x: minX, y: minY, width: contentWidth, height: contentHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return self }
        return cropped.asPixelExactNSImage()
    }
}
