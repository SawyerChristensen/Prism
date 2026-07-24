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

struct MilkdropVisualizerView: View {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    /// 0...1 bass energy, used to thicken the line the way MilkDrop's mod-alpha-by-volume does.
    var bassEnergy: CGFloat = 0

    @State private var model = MilkdropVisualizerModel()
    @State private var trail = WaveformTrailBuffer()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let (left, right) = audioEngine.snapshotWaveform()
                let scaledLeft = MilkdropWaveform.smoothed(left, scale: model.params.scale, smoothing: model.params.smoothing)
                let scaledRight = MilkdropWaveform.smoothed(right, scale: model.params.scale, smoothing: model.params.smoothing)

                let time = timeline.date.timeIntervalSinceReferenceDate
                let aspect = size.width > 0 ? Float(size.height / size.width) : 1
                let (rawPoints, rawBreak) = MilkdropWaveform.points(
                    mode: model.mode, left: scaledLeft, right: scaledRight,
                    params: model.params, time: time, aspect: aspect
                )
                let (tessPoints, tessBreak) = MilkdropWaveform.tessellated(rawPoints, segmentBreak: rawBreak)

                let nsColor = NSColor(color)
                let lineWidth: CGFloat = 1.6 + bassEnergy * 2.2

                guard let image = trail.render(
                    viewSize: size,
                    displayScale: displayScale,
                    decay: 0.90,
                    zoom: 1.006,
                    rotation: 0.0025,
                    drawStroke: { cgContext, pixelSize in
                        Self.strokeWaveform(
                            into: cgContext, pixelSize: pixelSize,
                            points: tessPoints, segmentBreak: tessBreak,
                            color: nsColor, lineWidth: lineWidth * displayScale
                        )
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
}
