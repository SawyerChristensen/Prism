//
//  MilkdropVisualizerView.swift
//  Prism
//
//  Renders the MilkdropWaveform math to screen. The line itself is a direct port of DrawWave();
//  the persistent, fading, slowly-zooming/rotating trail buffer underneath it is a lightweight
//  stand-in for MilkDrop's warp/feedback pass — the "don't clear the frame, re-project it" trick
//  that gives MilkDrop its signature drifting, breathing look, without pulling in the full
//  NS-EEL per-pixel warp-mesh engine.
//
//  The trail's zoom/rotation gets a momentary kick from MilkdropBeatState below, driven by
//  MilkdropAudioSignals.swift's port of MilkDrop's real bass/mid/treb signal — the same "hard
//  cut" pulse presets get from a `bass_att`-driven zoom, without needing the preset engine itself.
//

import SwiftUI
import AppKit

@Observable
final class MilkdropVisualizerModel {
    var mode: MilkdropWaveMode = .line
    var params = MilkdropWaveformParams()

    func cycleMode() {
        let all = MilkdropWaveMode.allCases
        let idx = all.firstIndex(of: mode) ?? 0
        mode = all[(idx + 1) % all.count]
    }
}

/// Feedback buffer: each frame, fades + zooms/rotates whatever was drawn last time instead of
/// clearing it, then strokes the new waveform on top. Kept as a plain (non-Observable) class held
/// in `@State` — its mutations drive pixels, not SwiftUI diffing.
private final class WaveformTrailBuffer {
    private var ctx: CGContext?
    private var pixelSize: CGSize = .zero

    func render(
        viewSize: CGSize,
        displayScale: CGFloat,
        decay: CGFloat,
        zoom: CGFloat,
        rotation: CGFloat,
        drawStroke: (CGContext, CGSize) -> Void
    ) -> CGImage? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let targetSize = CGSize(width: viewSize.width * displayScale, height: viewSize.height * displayScale)

        if ctx == nil || pixelSize != targetSize {
            ctx = CGContext(
                data: nil,
                width: max(1, Int(targetSize.width)),
                height: max(1, Int(targetSize.height)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            pixelSize = targetSize
        }
        guard let ctx else { return nil }

        if let previous = ctx.makeImage() {
            ctx.clear(CGRect(origin: .zero, size: pixelSize))
            ctx.saveGState()
            ctx.translateBy(x: pixelSize.width / 2, y: pixelSize.height / 2)
            ctx.rotate(by: rotation)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -pixelSize.width / 2, y: -pixelSize.height / 2)
            ctx.setAlpha(decay)
            ctx.draw(previous, in: CGRect(origin: .zero, size: pixelSize))
            ctx.restoreGState()
        }

        ctx.saveGState()
        drawStroke(ctx, pixelSize)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

/// Drives MilkdropSignalAnalyzer frame-to-frame and turns its `bass` (imm_rel) signal into a
/// decaying "punch" value: a bass onset well above the long-term baseline snaps punch to 1, then
/// it decays exponentially until the next onset can retrigger it. Plain class in `@State`, mutated
/// in place — same pattern as WaveformTrailBuffer above, and for the same reason (Canvas's content
/// closure runs during rendering, where reassigning @State outright is unsafe).
private final class MilkdropBeatState {
    private let analyzer = MilkdropSignalAnalyzer()
    private var lastFrameDate: Date?
    private(set) var punch: CGFloat = 0

    func update(left: [Float], right: [Float], sampleRate: Float, now: Date) -> Float {
        let dt = lastFrameDate.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastFrameDate = now
        let fps = dt > 0 ? min(240.0, max(1.0, 1.0 / dt)) : 60.0

        let energy = analyzer.process(left: left, right: right, sampleRate: sampleRate, fps: fps)

        // MilkDrop's `bass` (imm_rel) sits near 1.0 on average by construction (it's normalized
        // against its own long-term average) and spikes well above it on a hit. 0.15 as the
        // re-arm floor keeps a sustained loud passage from retriggering every single frame.
        if energy.bass > 1.6 && punch < 0.15 {
            punch = 1.0
        } else {
            punch *= 0.85
        }
        return energy.bass
    }
}

struct MilkdropVisualizerView: View {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    /// 0...1 bass energy, used to thicken the line the way MilkDrop's mod-alpha-by-volume does.
    var bassEnergy: CGFloat = 0
    /// Owned by the caller (ContentView) so a keyboard shortcut can drive mode-cycling too, not
    /// just the tap gesture below.
    var model: MilkdropVisualizerModel

    @State private var trail = WaveformTrailBuffer()
    @State private var beat = MilkdropBeatState()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let (left, right) = audioEngine.snapshotWaveform()
                let scaledLeft = MilkdropWaveform.smoothed(left, scale: model.params.scale, smoothing: model.params.smoothing)
                let scaledRight = MilkdropWaveform.smoothed(right, scale: model.params.scale, smoothing: model.params.smoothing)

                // CoreAudioTapEngine taps the system default output device, so 44.1kHz is the
                // common case; SpectrumAnalyzer makes the same assumption.
                _ = beat.update(left: left, right: right, sampleRate: 44100, now: timeline.date)
                let punch = beat.punch

                let time = timeline.date.timeIntervalSinceReferenceDate
                let aspect = size.width > 0 ? Float(size.height / size.width) : 1
                let (rawPoints, rawBreak) = MilkdropWaveform.points(
                    mode: model.mode, left: scaledLeft, right: scaledRight,
                    params: model.params, time: time, aspect: aspect
                )
                let (tessPoints, tessBreak) = MilkdropWaveform.tessellated(rawPoints, segmentBreak: rawBreak)

                let nsColor = NSColor(color)
                let lineWidth: CGFloat = 1.6 + bassEnergy * 2.2 + punch * 1.4
                let bands = audioEngine.levels

                guard let image = trail.render(
                    viewSize: size,
                    displayScale: displayScale,
                    decay: 0.90,
                    zoom: 1.006 + punch * 0.035,
                    rotation: 0.0025 + punch * 0.01,
                    drawStroke: { cgContext, pixelSize in
                        if model.mode == .spectrumBars {
                            Self.strokeSpectrumBars(into: cgContext, pixelSize: pixelSize, bands: bands, color: nsColor)
                        } else {
                            Self.strokeWaveform(
                                into: cgContext, pixelSize: pixelSize,
                                points: tessPoints, segmentBreak: tessBreak,
                                color: nsColor, lineWidth: lineWidth * displayScale
                            )
                        }
                    }
                ) else { return }

                context.draw(Image(decorative: image, scale: displayScale), in: CGRect(origin: .zero, size: size))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.cycleMode() }
    }

    private static func strokeWaveform(
        into ctx: CGContext, pixelSize: CGSize,
        points: [WavePoint], segmentBreak: Int?,
        color: NSColor, lineWidth: CGFloat
    ) {
        guard points.count > 1 else { return }

        func toPixel(_ p: WavePoint) -> CGPoint {
            CGPoint(
                x: CGFloat(p.x) * 0.5 * pixelSize.width + pixelSize.width / 2,
                y: CGFloat(p.y) * 0.5 * pixelSize.height + pixelSize.height / 2
            )
        }

        let path = CGMutablePath()
        let end = segmentBreak ?? points.count
        path.move(to: toPixel(points[0]))
        for p in points[1..<end] { path.addLine(to: toPixel(p)) }
        if let segmentBreak, segmentBreak < points.count {
            path.move(to: toPixel(points[segmentBreak]))
            for p in points[(segmentBreak + 1)...] { path.addLine(to: toPixel(p)) }
        }

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(lineWidth)
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor((color.usingColorSpace(.deviceRGB) ?? color).cgColor)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// Classic mirrored bar-spectrum EQ display, built from SpectrumAnalyzer's log-spaced bands
    /// (already computed every audio callback for `bassEnergy`, just never drawn until now).
    private static func strokeSpectrumBars(into ctx: CGContext, pixelSize: CGSize, bands: [CGFloat], color: NSColor) {
        guard !bands.isEmpty else { return }
        let barCount = bands.count
        let spacing = pixelSize.width * 0.10 / CGFloat(barCount)
        let barWidth = max(1, (pixelSize.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        let baseline = pixelSize.height / 2

        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? color).cgColor)

        for i in 0..<barCount {
            let magnitude = max(2, bands[i] * pixelSize.height * 0.45)
            let x = CGFloat(i) * (barWidth + spacing)
            let rect = CGRect(x: x, y: baseline - magnitude, width: barWidth, height: magnitude * 2)
            ctx.fill(rect)
        }
    }
}
