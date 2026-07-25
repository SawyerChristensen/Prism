//
//  AlbumColors.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import AppKit

/// A point in whatever feature space a particular k-means clustering call is using — chromaticity
/// + weighted brightness for the background clustering below, plain RGB for the foreground one.
/// Kept generic so both share one clustering implementation rather than two near-duplicates.
private struct KMeansPoint {
    var x: Double
    var y: Double
    var z: Double
}

private func distanceSquared(_ a: KMeansPoint, _ b: KMeansPoint) -> Double {
    let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
}

/// Empirical prior for album art layout: covers frequently center the actual subject and let a
/// plain or gradient background carry through to the edges, so the four corners are
/// disproportionately likely to show that background rather than incidental subject detail.
///
/// An earlier version applied this as a graded per-pixel *weight* (boosting corner-adjacent
/// pixels up to 4x in the whole-image vote below) rather than a hard region — but that failed on
/// Kanye West's "Jesus Is King" (a vinyl scan: a blue disc covering ~78% of the frame, on a white
/// canvas visible only at the corners). Even a 4x boost on every corner pixel couldn't outweigh
/// blue's sheer four-to-one area advantage, so blue still won the whole-image vote. A hard region
/// membership test — "is this pixel actually in a corner, yes or no" — sidesteps that: it lets the
/// corners be judged on their own, undiluted by how much area the centered subject takes up
/// elsewhere in the frame. See `pickBackgroundColor` for how that verdict is used.
private func isCornerPixel(row: Int, col: Int, size: Int, cornerFraction: Double = 0.18) -> Bool {
    let cornerSize = Int(Double(size) * cornerFraction)
    guard cornerSize > 0 else { return false }
    let nearLeftOrRight = col < cornerSize || col >= size - cornerSize
    let nearTopOrBottom = row < cornerSize || row >= size - cornerSize
    return nearLeftOrRight && nearTopOrBottom
}

/// Standard k-means with k-means++ initialization (weights the next centroid pick toward points
/// far from existing centroids, which avoids the classic bad-luck failure mode of plain random
/// init — two initial centroids landing close together and permanently splitting one real cluster
/// while starving another). Returns a cluster index per input point, same order as `points`.
///
/// Converges on centroid *movement* falling under `moveThreshold`, not on zero assignment changes
/// — measured on real album art, a handful of points sitting right on a cluster boundary keep
/// flip-flopping assignment indefinitely even after the centroids themselves have visibly settled,
/// which blocked a zero-changes check from ever firing and forced every call through the full
/// iteration cap (1.2s combined, unoptimized). Movement-based convergence exits as soon as the
/// centroids stop moving in any *meaningful* way, regardless of a few boundary points still
/// flickering — measured 342ms combined on the same image and same accuracy. `moveThreshold` is in
/// the same units as the points, so callers in different feature spaces (e.g. chromaticity's ~0-1
/// range vs raw RGB's 0-255) need different values.
private func kmeans(_ points: [KMeansPoint], k: Int, moveThreshold: Double, iterations: Int = 15) -> [Int] {
    guard points.count > k else { return Array(points.indices) }

    var rng = SystemRandomNumberGenerator()
    var centroids: [KMeansPoint] = [points[Int.random(in: 0..<points.count, using: &rng)]]
    while centroids.count < k {
        let distances = points.map { p in centroids.map { distanceSquared(p, $0) }.min()! }
        let total = distances.reduce(0, +)
        guard total > 0 else {
            centroids.append(points[Int.random(in: 0..<points.count, using: &rng)])
            continue
        }
        var remaining = Double.random(in: 0..<total, using: &rng)
        var chosen = points.count - 1
        for (i, d) in distances.enumerated() {
            remaining -= d
            if remaining <= 0 { chosen = i; break }
        }
        centroids.append(points[chosen])
    }

    var assignments = [Int](repeating: 0, count: points.count)
    let thresholdSquared = moveThreshold * moveThreshold
    for _ in 0..<iterations {
        for (i, p) in points.enumerated() {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (c, centroid) in centroids.enumerated() {
                let d = distanceSquared(p, centroid)
                if d < bestDistance { bestDistance = d; best = c }
            }
            assignments[i] = best
        }

        var sums = [KMeansPoint](repeating: KMeansPoint(x: 0, y: 0, z: 0), count: k)
        var counts = [Int](repeating: 0, count: k)
        for (i, p) in points.enumerated() {
            sums[assignments[i]].x += p.x
            sums[assignments[i]].y += p.y
            sums[assignments[i]].z += p.z
            counts[assignments[i]] += 1
        }
        var maxMoveSquared = 0.0
        for c in 0..<k where counts[c] > 0 {
            let newCentroid = KMeansPoint(x: sums[c].x / Double(counts[c]), y: sums[c].y / Double(counts[c]), z: sums[c].z / Double(counts[c]))
            maxMoveSquared = max(maxMoveSquared, distanceSquared(centroids[c], newCentroid))
            centroids[c] = newCentroid
        }
        if maxMoveSquared < thresholdSquared { break } // converged
    }
    return assignments
}

extension NSImage {
    /// Extracts a dominant background color and a contrasting foreground color via k-means
    /// clustering. Pure pixel crunching, no UI state — `nonisolated` so callers can run it off the
    /// main actor (it's called from a background task after each artwork fetch).
    ///
    /// Earlier versions tried fixed-grid histogram bucketing (by RGB, then by hue, then hue with a
    /// brightness sub-bucket) — all of them work by picking hard bin boundaries up front and hoping
    /// real clusters don't straddle one. K-means instead finds the boundaries from the data itself
    /// via iterative centroid refinement, which is both more accurate (measured closer to ground
    /// truth on real album art than any of the bucketing attempts) and avoids the whole class of
    /// "two visually-identical samples land in different buckets" bugs those had.
    nonisolated func extractColors() -> (background: NSColor, foreground: NSColor)? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // K-means clusters on centroids, not on dense per-pixel coverage, so it doesn't need the
        // 300x300 the earlier histogram approach needed to avoid aliasing against fine detail
        // (e.g. this file's original test case, Men At Work's "Business As Usual," has a fine
        // black-and-yellow diamond lattice over half the cover). Measured 150x150 vs 300x300 on
        // that image: same result within a couple RGB units either way. The reason to keep the cap
        // low rather than "may as well use 300": Xcode Debug builds compile Swift with -Onone, and
        // k-means' O(points × k × iterations) cost is steep unoptimized — 300x300 measured over a
        // second combined (background + foreground calls) in an -Onone build (fine in a Release
        // build's optimized code, bad in Debug), vs ~400-750ms combined at 150x150 with the
        // movement-based convergence check below (see `kmeans`'s doc comment). Nearest-neighbor
        // sampling (`.none` interpolation, right below) is what makes shrinking this safe: every
        // sample point is still a real, unblended source pixel, so fewer of them costs statistical
        // density, not correctness.
        let size = min(150, max(cgImage.width, cgImage.height))
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
        // existed in the source, never a synthesized blend of two different-colored neighbors —
        // area-averaging is correct for a visually smooth thumbnail, but for finding "the true
        // dominant color," a blended pixel is exactly the kind of value that shouldn't be there.
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Sample { var r: UInt8; var g: UInt8; var b: UInt8; var hue: CGFloat; var saturation: CGFloat; var brightness: CGFloat; var isCorner: Bool }
        var samples: [Sample] = []
        samples.reserveCapacity(size * size)
        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            guard pixelData[i + 3] > 0 else { continue } // skip transparent pixels
            let r = pixelData[i], g = pixelData[i + 1], b = pixelData[i + 2]
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            let pixelIndex = i / bytesPerPixel
            let isCorner = isCornerPixel(row: pixelIndex / size, col: pixelIndex % size, size: size)
            samples.append(Sample(r: r, g: g, b: b, hue: h, saturation: s, brightness: v, isCorner: isCorner))
        }
        guard !samples.isEmpty else { return nil }

        func averageColor(_ group: [Sample]) -> NSColor {
            let n = Double(group.count)
            let r = group.reduce(0.0) { $0 + Double($1.r) } / n
            let g = group.reduce(0.0) { $0 + Double($1.g) } / n
            let b = group.reduce(0.0) { $0 + Double($1.b) } / n
            return NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }

        // Ranks a group by size, nudged up for how saturated it is on average. This is a
        // tie-breaker, not a color transform: unlike the old `vibrancyBoosted` post-process
        // (removed — it multiplied the *output* color's saturation, which on an off-white or
        // washed-out cover meant a barely-there yellow tint got amplified into a visibly yellow
        // background, drifting away from what the artwork actually looks like), this never
        // touches the color itself. It only changes which candidate group wins when two are
        // close in size, so a small vivid patch can edge out a slightly larger but near-identical
        // dull one, while a genuinely dominant color (e.g. an 80% white cover) still wins
        // regardless of how much more saturated a smaller competing patch is.
        func saturationScore(_ group: [Sample]) -> Double {
            guard !group.isEmpty else { return 0 }
            let avgSaturation = group.reduce(0.0) { $0 + Double($1.saturation) } / Double(group.count)
            return Double(group.count) * (1 + 0.5 * avgSaturation)
        }

        // Background should be whichever color is genuinely most common within `group` — not
        // whichever is most colorful. Splitting into three pools up front (rather than one
        // saturation-filtered pool like earlier versions had) is what makes that possible: white
        // and black are deliberate, common design choices (a stark white or black cover background
        // is completely normal), so they need to be eligible to win outright, same as any hue —
        // verified against Tyler, The Creator's "Don't Tap The Glass" (a white cover with a small
        // red figure): filtering white/black out before comparing sizes, like an earlier version
        // did, picked the red as background because it was the only *chromatic* candidate, even
        // though white covers ~80% of the image.
        //
        // `nearBlack` deliberately does *not* also require low saturation the way `nearWhite`
        // does. HSV saturation is (max−min)/max, which is numerically unstable as max approaches
        // zero: a JPEG-compressed "black" pixel like (5, 7, 7) computes ~30% saturation from pure
        // compression noise, not from any actual color. Requiring `saturation < 0.20` here (as an
        // earlier version did) let that noise exclude the true black background from its own pool
        // — measured on Daft Punk's "TRON: Legacy" cover (a black sleeve with bright cyan neon
        // text), 99.6% of the near-black pixels failed that saturation check and fell into no pool
        // at all, leaving the neon glow as the only non-empty candidate and handing it the
        // background pick by default. At `brightness <= 0.10`, hue and saturation aren't
        // perceptible anyway, so brightness alone is sufficient here.
        //
        // True mid-range grey (moderate brightness, low saturation) is still excluded from all
        // three pools — it's far more often an incidental shadow/blend artifact than an
        // intentional background color (confirmed on "Lover"'s pastel-gradient cover, where a pale
        // pinkish-grey band was, before this exclusion, narrowly outsizing the actual pink and
        // winning by a hair).
        //
        // The chromatic pool clusters in hue-weighted chromaticity space — x = S·cos(2πH),
        // y = S·sin(2πH) (a flattened color wheel, handling hue's 0°/360° wraparound for free,
        // unlike a fixed hue bucket that hard-cuts at arbitrary degree boundaries) — plus z = V·0.3,
        // a *deliberately small* weight on brightness. Clustering in plain RGB would repeat the
        // original bug this file had (RGB distance conflates "different hue" with "different
        // brightness" in one number, so antialiased/blended edge pixels between yellow and any
        // darker graphic get pulled into the yellow cluster and drag its centroid down); clustering
        // on hue alone can't tell "solid yellow" apart from "yellow blended toward black" at all,
        // since blending toward black scales brightness down without shifting hue. A *small*
        // brightness weight is the resolution: enough that k-means can still split those apart when
        // the data supports it, not enough to let brightness dominate the distance metric.
        func pickBackgroundColor(from group: [Sample]) -> (color: NSColor, dominantFraction: Double)? {
            guard !group.isEmpty else { return nil }
            let chromatic = group.filter { $0.saturation >= 0.20 && $0.brightness >= 0.15 }
            let nearWhite = group.filter { $0.saturation < 0.20 && $0.brightness >= 0.90 }
            let nearBlack = group.filter { $0.brightness <= 0.10 }

            var chromaticDominant: [Sample] = []
            if !chromatic.isEmpty {
                let chromaticityPoints = chromatic.map { s -> KMeansPoint in
                    let angle = 2 * Double.pi * Double(s.hue)
                    return KMeansPoint(x: Double(s.saturation) * cos(angle), y: Double(s.saturation) * sin(angle), z: Double(s.brightness) * 0.3)
                }
                let assignments = kmeans(chromaticityPoints, k: 4, moveThreshold: 0.001)
                var clusters: [Int: [Sample]] = [:]
                for (i, cluster) in assignments.enumerated() {
                    clusters[cluster, default: []].append(chromatic[i])
                }
                chromaticDominant = clusters.values.max(by: { saturationScore($0) < saturationScore($1) }) ?? []
            }

            guard let dominant = [chromaticDominant, nearWhite, nearBlack].max(by: { saturationScore($0) < saturationScore($1) }), !dominant.isEmpty else {
                return nil
            }
            return (averageColor(dominant), Double(dominant.count) / Double(group.count))
        }

        // Corners first: on covers that center a subject on a plain canvas (vinyl scans, logo-on-
        // solid-field art, etc.) the corner pixels are unambiguous background, and a decisive
        // consensus among just those pixels should win outright regardless of how much more area
        // a centered subject occupies elsewhere (see `isCornerPixel`'s doc comment for why a
        // whole-image weighted vote wasn't enough). Only when the corners *don't* agree — a busy,
        // edge-to-edge cover with no clean canvas — does this fall through to the whole-image vote.
        let cornerSamples = samples.filter { $0.isCorner }
        let background: NSColor
        if let cornerResult = pickBackgroundColor(from: cornerSamples), cornerResult.dominantFraction >= 0.6 {
            background = cornerResult.color
        } else if let wholeImageResult = pickBackgroundColor(from: samples) {
            background = wholeImageResult.color
        } else {
            // Only possible if the entire sampled image is mid-range grey (excluded from all three
            // pools by design above). Still need *a* background/foreground pair.
            return (averageColor(samples), samples.first.map { $0.brightness < 0.5 ? .white : .black } ?? .black)
        }

        // Foreground: unlike the background, black/white/grey are legitimate choices here — a dark
        // logo or white text is a perfectly good foreground color — so this clusters in plain RGB
        // across *all* samples (no saturation filter, no hue weighting) and walks clusters from
        // largest to smallest, taking the first that contrasts with the background.
        let rgbPoints = samples.map { KMeansPoint(x: Double($0.r), y: Double($0.g), z: Double($0.b)) }
        let foregroundAssignments = kmeans(rgbPoints, k: 5, moveThreshold: 0.5)
        var foregroundClusters: [Int: [Sample]] = [:]
        for (i, cluster) in foregroundAssignments.enumerated() {
            foregroundClusters[cluster, default: []].append(samples[i])
        }

        var foreground: NSColor?
        for cluster in foregroundClusters.values.sorted(by: { $0.count > $1.count }) {
            let candidate = averageColor(cluster)
            if background.hasSufficientContrast(with: candidate) {
                foreground = candidate
                break
            }
        }

        return (background, foreground ?? (background.isDark ? .white : .black))
    }

    /// Returns a copy of this image with pixels close to `keyColor` faded to transparent, and
    /// everything else left untouched — a chroma-key cutout, not a blend mode. A blend mode
    /// (.lighten/.darken) compares *every* pixel's brightness against whatever's behind the whole
    /// image, so it also fades out any dark/light pixel that's part of the actual subject (a
    /// shadow, dark hair, a dark logo), not just the background field — which reads as the layer
    /// behind the artwork "poking through" the art itself. Keying only touches pixels that
    /// actually match the measured background color, so the rest of the artwork stays fully
    /// opaque and renders normally, in front of whatever's behind it.
    ///
    /// `tolerance` is a Euclidean distance in 0...255-per-channel RGB space; pixels within it are
    /// faded, with a feathered (not hard-edged) falloff over the inner 40% of that radius to avoid
    /// a jagged cutout edge where the background meets the subject.
    nonisolated func keyingOutBackground(_ keyColor: NSColor, tolerance: CGFloat = 40) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let keyRGB = keyColor.usingColorSpace(.sRGB) else { return nil }
        let kr = keyRGB.redComponent * 255, kg = keyRGB.greenComponent * 255, kb = keyRGB.blueComponent * 255
        let featherWidth = tolerance * 0.4

        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let a = pixelData[i + 3]
            guard a > 0 else { continue }
            // Buffer is premultiplied — un-premultiply so the distance check compares true pixel
            // color, not color already attenuated by (usually irrelevant, near-1) alpha.
            let alphaFrac = CGFloat(a) / 255
            let r = CGFloat(pixelData[i]) / alphaFrac
            let g = CGFloat(pixelData[i + 1]) / alphaFrac
            let b = CGFloat(pixelData[i + 2]) / alphaFrac
            let dr = r - kr, dg = g - kg, db = b - kb
            let distance = (dr * dr + dg * dg + db * db).squareRoot()

            guard distance < tolerance else { continue }
            // 0 at the key color itself, ramping to 1 (fully opaque, untouched) over the outer
            // feather band — scaling all four premultiplied channels by the same factor keeps
            // premultiplication consistent without needing to re-premultiply by hand.
            let alphaScale = distance < tolerance - featherWidth ? 0 : (distance - (tolerance - featherWidth)) / featherWidth
            pixelData[i] = UInt8(CGFloat(pixelData[i]) * alphaScale)
            pixelData[i + 1] = UInt8(CGFloat(pixelData[i + 1]) * alphaScale)
            pixelData[i + 2] = UInt8(CGFloat(pixelData[i + 2]) * alphaScale)
            pixelData[i + 3] = UInt8(CGFloat(pixelData[i + 3]) * alphaScale)
        }

        guard let outCGImage = context.makeImage() else { return nil }
        return NSImage(cgImage: outCGImage, size: self.size)
    }
}

/// Which of the two "special" background tones (if either) a color counts as — used to decide
/// whether an album-art image is worth keying out (see NSImage.keyingOutBackground below).
/// Thresholds deliberately match `pickBackgroundColor`'s own nearBlack/nearWhite pool definitions
/// above, so "detected as black/white" means the same thing here as it does during background
/// extraction.
enum BackgroundTone {
    case black, white, other
}

extension NSColor {
    nonisolated var backgroundTone: BackgroundTone {
        guard let rgb = usingColorSpace(.deviceRGB) else { return .other }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        if brightness <= 0.10 { return .black }
        if saturation < 0.20 && brightness >= 0.90 { return .white }
        return .other
    }

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
