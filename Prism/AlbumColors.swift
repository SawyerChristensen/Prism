//
//  AlbumColors.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import AppKit

extension NSImage {
    /// Extracts a dominant background color and a contrasting foreground color. Pure pixel
    /// crunching, no UI state — `nonisolated` so callers can run it off the main actor (it's
    /// called from a background task after each artwork fetch).
    nonisolated func extractColors() -> (background: NSColor, foreground: NSColor)? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Verified against real album art (Men At Work's "Business As Usual", which has a fine
        // black-and-yellow diamond-lattice pattern over roughly the bottom half of the cover):
        // at a coarse 40x40 grid, even with high-quality interpolation, downscaling blends those
        // black grid lines into the surrounding yellow — measured 82 RGB-distance units off the
        // image's true dominant color. That blending is inherent to *any* interpolation quality
        // once the sample grid is coarser than the pattern being sampled; the fix isn't a better
        // filter kernel, it's sampling finely enough that each sample point has a real chance of
        // landing on solid, unblended color. Capped at 300 (native size if smaller) measured 2.4
        // units off ground truth on the same image — accurate without scaling cost unboundedly on
        // an unusually large source image. Runs once per track change on a background thread, so
        // the ~50ms cost at 300x300 isn't perf-sensitive.
        let size = min(300, max(cgImage.width, cgImage.height))
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        // Explicit sRGB rather than "device" RGB, which on macOS tracks the main display's
        // calibrated space — album art is authored in sRGB, so decoding through a fixed,
        // image-independent space keeps results deterministic across machines/monitors.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // No interpolation (nearest-neighbor): every sample this returns is a real pixel that
        // existed in the source, never a synthesized blend of two different-colored neighbors.
        // Measured slightly *more* accurate than `.high` at every grid size tested, which makes
        // sense for this specific goal — area-averaging is correct for a visually smooth
        // thumbnail, but for finding "the true dominant color," a blended pixel is exactly the
        // kind of value we don't want feeding the average.
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Sample { var r: UInt8; var g: UInt8; var b: UInt8; var hue: CGFloat; var saturation: CGFloat; var brightness: CGFloat }
        var samples: [Sample] = []
        samples.reserveCapacity(size * size)
        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            guard pixelData[i + 3] > 0 else { continue } // skip transparent pixels
            let r = pixelData[i], g = pixelData[i + 1], b = pixelData[i + 2]
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            samples.append(Sample(r: r, g: g, b: b, hue: h, saturation: s, brightness: v))
        }
        guard !samples.isEmpty else { return nil }

        func averageColor(_ group: [Sample]) -> NSColor {
            let n = Double(group.count)
            let r = group.reduce(0.0) { $0 + Double($1.r) } / n
            let g = group.reduce(0.0) { $0 + Double($1.g) } / n
            let b = group.reduce(0.0) { $0 + Double($1.b) } / n
            return NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }

        // Background: cluster by *hue*, not RGB distance. RGB-distance clustering (the previous
        // version) conflates "different hue" with "different brightness" in one number, so
        // antialiased edge pixels between a yellow field and any darker/black graphic on the
        // cover — which are genuinely partway toward black, not another shade of yellow — end up
        // within the same distance threshold and drag the average toward grey. Hue is stable
        // across exactly that kind of brightness/saturation variation, so two yellows that differ
        // only in how dark JPEG compression or antialiasing made them still land in the same hue
        // bucket. Filtering to `saturation >= 0.20` first excludes grey/black/white outright —
        // they have little to no hue to begin with — so they can never enter the average, rather
        // than relying on a distance threshold to keep them out after the fact.
        let colorful = samples.filter { $0.saturation >= 0.20 && $0.brightness >= 0.15 }
        let pool = colorful.isEmpty ? samples : colorful // falls back to everything for genuinely monochrome art

        var hueBuckets: [Int: [Sample]] = [:]
        for s in pool {
            let bucketIndex = Int(s.hue * 30) % 30 // 30 buckets = 12° of hue each
            hueBuckets[bucketIndex, default: []].append(s)
        }
        guard let dominantHueGroup = hueBuckets.values.max(by: { $0.count < $1.count }) else { return nil }

        // The dominant hue bucket alone still isn't enough: measured on the same album art, it
        // holds 48,594 samples with brightness spread from 0.15 all the way to 1.0 (median 1.0) —
        // solid, unblended yellow sits right at the bright end, while the lattice-blended pixels
        // (same hue, since blending toward black scales brightness down without shifting hue —
        // see the note above) spread out below it. Averaging the *whole* bucket lets that whole
        // spread dilute the result even though it's a small minority of it. Sub-bucketing by
        // brightness within the hue cluster and keeping only the largest sub-bucket isolates the
        // solid color from that dilution: on the same image, the top 10% of the brightness range
        // holds 43,358 of those 48,594 samples (89%) — an overwhelming, unambiguous majority —
        // while the blended pixels scatter thinly across the remaining lower bins and lose by
        // count. Measured result: #FDEB0B, essentially exact against the image's true dominant
        // color (#FFEC00), vs. #F2E10F from a flat average of the same bucket.
        var brightnessBuckets: [Int: [Sample]] = [:]
        for s in dominantHueGroup {
            let bucketIndex = min(9, Int(s.brightness * 10)) // 10 bins = 0.1 brightness each
            brightnessBuckets[bucketIndex, default: []].append(s)
        }
        let dominantGroup = brightnessBuckets.values.max(by: { $0.count < $1.count }) ?? dominantHueGroup
        let background = averageColor(dominantGroup)

        // Foreground: unlike the background, black/white/grey are legitimate choices here — a
        // dark logo or white text is a perfectly good foreground color — so this bucket by RGB
        // (not hue) across *all* samples and take the most common bucket that contrasts with the
        // background, same averaging-not-first-pixel fix as the background gets.
        //
        // Key is a real Hashable struct, not a hand bit-packed Int — a previous version of this
        // packed r/g/b into one Int via `(r/16 << 16) | (g/16 << 8) | (b/16)`, which is a bug in
        // Swift specifically: `<<` binds *tighter* than `/`, so `r/16 << 16` actually parses as
        // `r / (16 << 16)`, i.e. `r / 1048576` — 0 for every possible byte value. Red and green
        // silently never contributed to the hash; every "bucket" was really just "every pixel
        // sharing a blue value," regardless of red/green. A struct key sidesteps the whole
        // precedence trap rather than requiring everyone reading this to get shift/divide
        // grouping right by eye.
        struct RGBBucketKey: Hashable { var r: Int; var g: Int; var b: Int }
        struct RGBBucket { var rSum = 0, gSum = 0, bSum = 0, count = 0 }
        var rgbBuckets: [RGBBucketKey: RGBBucket] = [:]
        for s in samples {
            let key = RGBBucketKey(r: Int(s.r) / 16, g: Int(s.g) / 16, b: Int(s.b) / 16)
            var bucket = rgbBuckets[key] ?? RGBBucket()
            bucket.rSum += Int(s.r); bucket.gSum += Int(s.g); bucket.bSum += Int(s.b); bucket.count += 1
            rgbBuckets[key] = bucket
        }

        var foreground: NSColor?
        for bucket in rgbBuckets.values.sorted(by: { $0.count > $1.count }) {
            let candidate = NSColor(
                red: CGFloat(bucket.rSum) / CGFloat(bucket.count) / 255,
                green: CGFloat(bucket.gSum) / CGFloat(bucket.count) / 255,
                blue: CGFloat(bucket.bSum) / CGFloat(bucket.count) / 255,
                alpha: 1
            )
            if background.hasSufficientContrast(with: candidate) {
                foreground = candidate
                break
            }
        }

        return (background, foreground ?? (background.isDark ? .white : .black))
    }
}

extension NSColor {
    nonisolated var luminance: CGFloat {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 0.5 }
        let r = rgb.redComponent <= 0.03928 ? rgb.redComponent / 12.92 : pow((rgb.redComponent + 0.055) / 1.055, 2.4)
        let g = rgb.greenComponent <= 0.03928 ? rgb.greenComponent / 12.92 : pow((rgb.greenComponent + 0.055) / 1.055, 2.4)
        let b = rgb.blueComponent <= 0.03928 ? rgb.blueComponent / 12.92 : pow((rgb.blueComponent + 0.055) / 1.055, 2.4)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    nonisolated var isDark: Bool {
        return luminance < 0.5
    }

    nonisolated func hasSufficientContrast(with color: NSColor) -> Bool {
        let l1 = max(self.luminance, color.luminance)
        let l2 = min(self.luminance, color.luminance)
        let ratio = (l1 + 0.05) / (l2 + 0.05)
        return ratio > 2.0
    }
}
