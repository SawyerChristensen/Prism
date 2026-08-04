//
//  ProjectMVisualizerModel.swift
//  Prism
//
//  Deliberately minimal, unlike the old MilkdropVisualizerModel: real projectM owns all per-frame
//  preset state internally (expression variables, warp/border/shape/waveform params, shader
//  compilation) inside the vendored C++ engine (see ProjectMEngine.mm), so Swift only needs to
//  track which preset URL is currently requested and surface load failures — everything else
//  this class's predecessor had to hand-roll (warpParams, presetVariables, per-frame evaluation,
//  ...) simply doesn't exist on this side of the bridge anymore.
//

import Foundation

@Observable
final class ProjectMVisualizerModel {
    private(set) var presetURL: URL?
    /// Not private(set): the view clears this once the user dismisses the load-failure alert.
    var presetLoadError: String?
    /// Smoothed (exponential moving average, not instantaneous) frames-per-second, written by
    /// ProjectMCoordinator once per frame — read by ContentView's on-screen performance counter.
    var displayFPS: Double = 60

    /// Set once by ProjectMCoordinator's runtime watchdog (see updateSlowPresetWatchdog) when
    /// displayFPS has stayed unwatchably low for several seconds straight — a live safety net in
    /// case a preset renders slower in practice than its offline benchmark measured (different
    /// hardware, a resolution change, a specific song's audio triggering an unusually expensive
    /// code path). ContentView reacts by stepping to the next preset and clearing this back to nil,
    /// same as presetLoadError.
    var slowPresetDetected: URL?

    /// Multiplier on top of each preset's own `fWarpAnimSpeed`, adjusted via ContentView's
    /// up/down arrow handling and applied every frame by ProjectMCoordinator
    /// (engine.setWarpAnimSpeedMultiplier) — see PRISM_LOCAL_PATCH in
    /// Vendor/projectm-local-patches/0004-warp-anim-speed-multiplier.patch. 1.0 = unmodified.
    var warpAnimSpeedMultiplier: Double = 1.0

    func requestPreset(at url: URL) {
        presetURL = url
        presetLoadError = nil
    }
}
