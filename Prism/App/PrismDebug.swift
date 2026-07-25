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

import Foundation

enum PrismDebug {
    /// When `false`, the recurring diagnostic logs stay silent. Errors are logged regardless.
    /// `nonisolated` since callers include background tasks doing the actual capture/AppleScript work.
    nonisolated static let verboseLogging = false

    /// Separate from `verboseLogging`: traces one-time startup steps (permission checks, Apple
    /// Events probes, Core Audio tap setup) with elapsed time, so a hang at launch shows exactly
    /// which call didn't return. Cheap and rare enough to leave on by default.
    nonisolated static let startupTracing = true

    // ProcessInfo.systemUptime is a monotonic Double (seconds since boot), so there's no risk of
    // the unsigned-integer underflow that DispatchTime.uptimeNanoseconds subtraction has: a lazily
    // initialized `static let` resolves the moment it's first read, so a `now - bootTime` built
    // from two independently-lazy UInt64 clocks can see `bootTime` initialize a few nanoseconds
    // *after* an already-captured `now`, and unsigned subtraction traps on that. Doubles just don't
    // have that trap.
    private nonisolated static let bootTime = ProcessInfo.processInfo.systemUptime

    private nonisolated static func secondsSinceBoot() -> Double {
        max(0, ProcessInfo.processInfo.systemUptime - bootTime)
    }

    /// Prints `"[+0.123s] <thread> <label>"` when startup tracing is on. Call once before and
    /// once after a suspect blocking call to see how long it actually took (or that it never
    /// returned at all). `nonisolated` so it's callable from the background tasks it's mainly
    /// there to diagnose, not just from the main actor.
    nonisolated static func trace(_ label: String) {
        guard startupTracing else { return }
        let thread = Thread.isMainThread ? "main" : "bg"
        print(String(format: "[+%.3fs] (%@) %@", secondsSinceBoot(), thread, label))
    }
}
