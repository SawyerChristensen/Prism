//
//  TextExtraction.swift
//  Prism
//
//  OCR for album art via Vision's VNRecognizeTextRequest — same on-device text recognition behind
//  Live Text. Two uses: (1) NowPlayingManager stores the recognized lines as a property so a
//  future feature can animate text pulled from the cover; (2) `maskingOutText` protects any
//  detected text from NowPlayingManager's background color-key the same way
//  SubjectMasking.swift's subject mask does — text sharing the background's color (white text on
//  a white cover, say) would otherwise get keyed away along with the real background.
//

import AppKit
import Vision

struct RecognizedTextLine {
    var string: String
    /// Normalized (0...1), origin bottom-left / y-up — Vision's own convention, confirmed
    /// empirically. Matches CGContext.fill/draw's coordinate convention directly (no flip needed
    /// for draw-time clip/fill rects built from this), but *not* a raw pixel buffer's row order
    /// (CGContext.draw flips into top-down storage — also confirmed empirically, see
    /// maskingOutBackgroundByText below, which needs both conventions and converts explicitly).
    var boundingBox: CGRect
    var confidence: Float
}

extension Array where Element == RecognizedTextLine {
    /// True if every detected line is just the RIAA Parental Advisory sticker, word for word —
    /// OCR sometimes splits it across lines ("PARENTAL ADVISORY" / "EXPLICIT CONTENT"), sometimes
    /// reads it as one. That sticker is compliance boilerplate stamped onto the cover, not part
    /// of its actual design, so an album whose *only* detected text is this label shouldn't need
    /// it drawn back into the visualizer by default (see NowPlayingManager.loadSpotifyArtwork/
    /// loadArtworkFromiTunes, which use this to default `includesTextOverlay` off for exactly
    /// that case, unless the album already has an explicit saved preference).
    var isOnlyParentalAdvisoryLabel: Bool {
        guard !isEmpty else { return false }
        let advisoryWords: Set<String> = ["PARENTAL", "ADVISORY", "EXPLICIT", "CONTENT", "LYRICS"]
        return allSatisfy { line in
            let words = line.string.uppercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            guard !words.isEmpty else { return false }
            return words.allSatisfy { advisoryWords.contains($0) }
        }
    }
}

extension NSImage {
    /// Runs Vision's OCR over the whole image and returns every recognized line with its text,
    /// position, and confidence. Empty (not nil) if Vision found no text or the request failed —
    /// most album art has no text at all, which is a normal outcome, not an error.
    nonisolated func recognizedTextLines() -> [RecognizedTextLine] {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedTextLine(string: candidate.string, boundingBox: observation.boundingBox, confidence: candidate.confidence)
            }
        } catch {
            return []
        }
    }

    /// Returns a copy of this image with only the actual glyph pixels within `lines`' bounding
    /// boxes kept opaque — everything else, including the *background fill inside each padded
    /// box* (not just outside it), goes transparent. This is a real ink/background separation
    /// (Otsu's method — a standard automatic-thresholding technique — run independently per line
    /// on that line's own local luminance histogram), not a rectangular cutout: an earlier version
    /// of this function just pasted back the whole padded box, background fill and all, which
    /// looked like a solid block sitting on the art rather than clean text.
    ///
    /// Per-line (not one global threshold) because different lines can sit on different local
    /// backgrounds within the same cover (e.g. one line over a dark patch, another over a lighter
    /// one) — a single whole-image threshold couldn't adapt to both.
    ///
    /// Takes precomputed lines rather than running OCR itself so callers that also want the
    /// recognized strings (see NowPlayingManager) don't pay for Vision's text request twice. Nil
    /// if `lines` is empty or this image has no usable CGImage representation.
    nonisolated func maskingOutBackgroundByText(_ lines: [RecognizedTextLine], padding: CGFloat = 0.15) -> NSImage? {
        guard !lines.isEmpty, let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Render the source once into a raw RGBA buffer — manual pixel indexing below needs it,
        // vs. the draw-time clip/draw the previous block-based version used. CGContext.draw flips
        // into top-down buffer storage (row 0 = visual top) regardless of Core Graphics' own
        // bottom-up fill/draw coordinate convention — confirmed empirically earlier, see
        // MilkdropWaveform-adjacent notes from this session on the same gotcha — so this buffer
        // and `boundingBox` (bottom-left origin, Vision's own convention) need an explicit flip to
        // line up, unlike the old clip-based version which stayed in draw-time coordinates and
        // needed none.
        var srcPixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let srcContext = CGContext(
            data: &srcPixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        srcContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var outPixels = [UInt8](repeating: 0, count: height * bytesPerRow) // starts fully transparent
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        for line in lines {
            let box = line.boundingBox // normalized, origin bottom-left / y-up
            var rect = CGRect(
                x: box.minX * CGFloat(width),
                y: (1 - box.maxY) * CGFloat(height), // bottom-left/y-up -> top-down
                width: box.width * CGFloat(width),
                height: box.height * CGFloat(height)
            )
            rect = rect.insetBy(dx: -rect.width * padding, dy: -rect.height * padding).intersection(bounds)
            guard rect.width > 1, rect.height > 1 else { continue }

            let minX = max(0, Int(rect.minX)), maxX = min(width - 1, Int(rect.maxX))
            let minY = max(0, Int(rect.minY)), maxY = min(height - 1, Int(rect.maxY))
            guard maxX > minX, maxY > minY else { continue }

            // Pass 1: luminance histogram over just this box.
            var histogram = [Int](repeating: 0, count: 256)
            var sampleCount = 0
            for y in minY...maxY {
                let rowStart = y * bytesPerRow
                for x in minX...maxX {
                    let i = rowStart + x * bytesPerPixel
                    guard srcPixels[i + 3] > 0 else { continue }
                    histogram[Self.unpremultipliedLuminanceBin(srcPixels, at: i)] += 1
                    sampleCount += 1
                }
            }
            guard sampleCount > 0 else { continue }

            let threshold = Self.otsuThreshold(histogram: histogram, totalCount: sampleCount)
            // Text ink is assumed to be the minority population — thin glyph strokes cover less
            // area than the box's own background fill, even after padding trims some of the
            // surrounding margin.
            let belowCount = histogram[0...threshold].reduce(0, +)
            let textIsAtOrBelowThreshold = belowCount <= sampleCount - belowCount

            // Pass 2: copy through only the pixels classified as ink.
            for y in minY...maxY {
                let rowStart = y * bytesPerRow
                for x in minX...maxX {
                    let i = rowStart + x * bytesPerPixel
                    guard srcPixels[i + 3] > 0 else { continue }
                    let bin = Self.unpremultipliedLuminanceBin(srcPixels, at: i)
                    let isText = textIsAtOrBelowThreshold ? bin <= threshold : bin >= threshold
                    guard isText else { continue }
                    outPixels[i] = srcPixels[i]
                    outPixels[i + 1] = srcPixels[i + 1]
                    outPixels[i + 2] = srcPixels[i + 2]
                    outPixels[i + 3] = srcPixels[i + 3]
                }
            }
        }

        guard let outContext = CGContext(
            data: &outPixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outCGImage = outContext.makeImage() else { return nil }
        return outCGImage.asPixelExactNSImage()
    }

    /// Un-premultiplies the pixel at byte offset `i` in a premultipliedLast RGBA buffer and
    /// returns its perceptual luminance (Rec. 709 weights, same as AlbumColors.swift's
    /// NSColor.luminance) as a 0...255 histogram bin.
    private nonisolated static func unpremultipliedLuminanceBin(_ pixels: [UInt8], at i: Int) -> Int {
        let alphaFrac = Float(pixels[i + 3]) / 255
        let r = Float(pixels[i]) / alphaFrac
        let g = Float(pixels[i + 1]) / alphaFrac
        let b = Float(pixels[i + 2]) / alphaFrac
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return min(255, max(0, Int(luminance)))
    }

    /// Otsu's method: finds the luminance threshold that maximizes between-class variance across
    /// a histogram, i.e. the split that best separates two populations — here, text ink from its
    /// local background. Standard automatic-thresholding technique, not something bespoke to
    /// Prism.
    private nonisolated static func otsuThreshold(histogram: [Int], totalCount: Int) -> Int {
        let total = Float(totalCount)
        var sum: Float = 0
        for bin in 0..<256 { sum += Float(bin) * Float(histogram[bin]) }

        var sumBelow: Float = 0
        var weightBelow: Float = 0
        var bestVariance: Float = 0
        var bestThreshold = 0

        for bin in 0..<256 {
            weightBelow += Float(histogram[bin])
            guard weightBelow > 0 else { continue }
            let weightAbove = total - weightBelow
            guard weightAbove > 0 else { break }

            sumBelow += Float(bin) * Float(histogram[bin])
            let meanBelow = sumBelow / weightBelow
            let meanAbove = (sum - sumBelow) / weightAbove
            let meanDiff = meanBelow - meanAbove
            let betweenClassVariance = weightBelow * weightAbove * meanDiff * meanDiff

            if betweenClassVariance > bestVariance {
                bestVariance = betweenClassVariance
                bestThreshold = bin
            }
        }
        return bestThreshold
    }
}
