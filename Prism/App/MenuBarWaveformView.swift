//
//  MenuBarWaveformView.swift
//  Prism
//
//  Menu bar companion: the same raw PCM ring buffer CoreAudioTapEngine feeds ProjectM's
//  oscilloscope preset rendering (see ProjectMAudioBridge), reused here instead of through the
//  Milkdrop shader pipeline.
//
//  Purely decorative — the status item has no click behavior at all (see
//  MenuBarWaveformController below), so this is only ever seen in the menu bar strip itself.
//

import SwiftUI
import AppKit

/// The menu bar status item's own icon — always visible in the strip itself, no click required.
///
/// A block-character sparkline rather than a graphical line: reading `audioEngine.levels` below
/// (its value is unused) piggybacks on `@Observable`'s ordinary SwiftUI change-tracking as the
/// redraw trigger, firing once per real audio buffer rather than on a synthetic timer — no
/// `TimelineView` needed.
struct MenuBarWaveformView: View {
    let audioEngine: CoreAudioTapEngine

    private static let segmentCount = 12
    private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    // Same character count as a real sparkline, so a monospaced font keeps the status item from
    // resizing when the waveform goes silent (or comes back). Only used when EVERY segment is at
    // the lowest level — an individual quiet segment in an otherwise-live waveform still renders
    // as "▁", not a gap, so a moving waveform never shows blanks mid-signal.
    private static let silentSparkline = String(repeating: " ", count: segmentCount)

    var body: some View {
        _ = audioEngine.levels
        return Text(sparkline())
            .font(.system(size: 12, weight: .medium, design: .monospaced))
    }

    private func sparkline() -> String {
        let (left, right) = audioEngine.snapshotWaveform()
        guard left.count > 1, left.count == right.count else {
            return Self.silentSparkline
        }

        let chunkSize = max(1, left.count / Self.segmentCount)
        var levels = [Int](repeating: 0, count: Self.segmentCount)

        for segment in 0..<Self.segmentCount {
            let start = segment * chunkSize
            let end = min(left.count, start + chunkSize)
            guard start < end else { continue }

            var peak: Float = 0
            for i in start..<end {
                peak = max(peak, abs(left[i]), abs(right[i]))
            }
            levels[segment] = min(Self.blocks.count - 1, Int(peak * Float(Self.blocks.count)))
        }

        guard levels.contains(where: { $0 > 0 }) else { return Self.silentSparkline }
        return String(levels.map { Self.blocks[$0] })
    }
}

/// Owns the menu bar status item directly via AppKit rather than SwiftUI's `MenuBarExtra`.
///
/// `MenuBarExtra` always treats a click as "open the content view" — there's no supported way to
/// make one purely inert. Hosting `MenuBarWaveformView` as a plain `NSHostingView` inside a status
/// item button, with no action/target ever wired up, is what makes clicking it a genuine no-op:
/// no popover, no menu, nothing.
@MainActor
final class MenuBarWaveformController {
    // Created once and kept for the app's lifetime — toggling visibility means flipping
    // `isVisible` on this same instance rather than adding/removing it. No `.behavior` is set, so
    // (unlike a plain status item, which is still user-draggable by default) it can't be dragged
    // out of the bar at all — View > Show/Hide Menu Bar Waveform (see PrismApp) is the only control.
    private var statusItem: NSStatusItem?

    /// Shows or hides the status item — backs View > Show/Hide Menu Bar Waveform. Safe to call
    /// repeatedly with the same value.
    func setVisible(_ visible: Bool, audioEngine: CoreAudioTapEngine) {
        let item = statusItem ?? makeStatusItem(audioEngine: audioEngine)
        item.isVisible = visible
    }

    private func makeStatusItem(audioEngine: CoreAudioTapEngine) -> NSStatusItem {
        let hostingView = NSHostingView(rootView: MenuBarWaveformView(audioEngine: audioEngine))
        let fittingSize = hostingView.fittingSize

        let item = NSStatusBar.system.statusItem(withLength: fittingSize.width)
        let barHeight = NSStatusBar.system.thickness
        hostingView.frame = NSRect(
            x: 0, y: (barHeight - fittingSize.height) / 2,
            width: fittingSize.width, height: fittingSize.height
        )
        item.button?.addSubview(hostingView)

        statusItem = item
        return item
    }
}
