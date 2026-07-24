//
//  PrismDebug.swift
//  Prism
//
//  Master switch for verbose diagnostic logging. The audio capture engines, the FFT
//  analyzer, and the now-playing poller emit per-frame/per-poll `logger.debug` output
//  (buffer stats, FFT peaks, raw AppleScript results) that floods the console while the
//  app runs. Keep this `false` for a quiet console; flip it to `true` to re-enable the
//  full debug stream when investigating audio/analysis issues.
//

enum PrismDebug {
    /// When `false`, the recurring diagnostic logs stay silent. Errors are logged regardless.
    static let verboseLogging = false
}
