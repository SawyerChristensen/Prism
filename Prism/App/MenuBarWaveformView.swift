//
//  MenuBarWaveformView.swift
//  Prism
//
//  Menu bar companion: the same raw PCM ring buffer CoreAudioTapEngine feeds ProjectM's
//  oscilloscope preset rendering (see ProjectMAudioBridge), reused here instead of through the
//  Milkdrop shader pipeline.
//

import SwiftUI

/// The menu bar status item's own icon — always visible in the strip itself, no click required.
///
/// A block-character sparkline rather than a graphical line: reading `audioEngine.levels` below
/// (its value is unused) piggybacks on `@Observable`'s ordinary SwiftUI change-tracking as the
/// redraw trigger, firing once per real audio buffer rather than on a synthetic timer — no
/// `TimelineView` needed. The bigger popover view further down draws a real Canvas line instead,
/// which a plain window (unlike a status-item label) has no trouble with.
struct MenuBarWaveformIcon: View {
    let audioEngine: CoreAudioTapEngine

    private static let segmentCount = 12
    private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    var body: some View {
        _ = audioEngine.levels
        return Text(sparkline())
            .font(.system(size: 12, weight: .medium, design: .monospaced))
    }

    private func sparkline() -> String {
        let (left, right) = audioEngine.snapshotWaveform()
        guard left.count > 1, left.count == right.count else {
            return String(repeating: Self.blocks[0], count: Self.segmentCount)
        }

        let chunkSize = max(1, left.count / Self.segmentCount)
        var result = String()
        result.reserveCapacity(Self.segmentCount)

        for segment in 0..<Self.segmentCount {
            let start = segment * chunkSize
            let end = min(left.count, start + chunkSize)
            guard start < end else { result.append(Self.blocks[0]); continue }

            var peak: Float = 0
            for i in start..<end {
                peak = max(peak, abs(left[i]), abs(right[i]))
            }
            let level = min(Self.blocks.count - 1, Int(peak * Float(Self.blocks.count)))
            result.append(Self.blocks[level])
        }

        return result
    }
}

/// Larger trace shown in the popover when the status item is clicked — a plain window, so
/// (unlike MenuBarWaveformIcon above) Canvas renders normally here.
struct MenuBarWaveformView: View {
    let audioEngine: CoreAudioTapEngine

    private static let size = CGSize(width: 280, height: 100)

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let (left, right) = audioEngine.snapshotWaveform()
                guard left.count > 1, left.count == right.count else { return }

                var path = Path()
                let midY = size.height / 2
                let stepX = size.width / CGFloat(left.count - 1)

                for i in 0..<left.count {
                    let sample = CGFloat(left[i] + right[i]) / 2
                    let point = CGPoint(x: CGFloat(i) * stepX, y: midY - sample * midY)
                    if i == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }

                context.stroke(path, with: .color(.primary), lineWidth: 1.5)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .padding(12)
    }
}
