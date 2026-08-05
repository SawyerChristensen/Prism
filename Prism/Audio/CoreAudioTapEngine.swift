//
//  CoreAudioTapEngine.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import AppKit
import Foundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.prism.app", category: "CoreAudioTapEngine")

/// os_unfair_lock wrapper — needed (over NSLock) so the real-time audio thread can use
/// `tryLock()` and skip rather than block. Requires a stable address, hence the class box.
private final class UnfairLock {
    private var primitive = os_unfair_lock_s()
    func lock() { os_unfair_lock_lock(&primitive) }
    func unlock() { os_unfair_lock_unlock(&primitive) }
    func tryLock() -> Bool { os_unfair_lock_trylock(&primitive) }
}

@Observable
final class CoreAudioTapEngine: NSObject {
    private(set) var levels: [CGFloat] = Array(repeating: 0.02, count: 40)
    private(set) var isCapturing = false

    private let analyzer = SpectrumAnalyzer()

    // Raw PCM scope buffer (mirrors MilkDrop's 576-sample mysound.fWaveform[0/1]).
    // Written from Core Audio's real-time IO thread in handleAudio, read from the render loop.
    // Real-time audio threads must never block on a lock held by a non-real-time thread — doing
    // so risks a missed IO deadline, which can destabilize coreaudiod for the whole system, not
    // just this app. So the writer only ever *tries* the lock and drops this buffer's samples if
    // it's contended; the reader (main thread) can block freely since it's never the one holding
    // up real-time audio.
    static let waveformSampleCount = 576
    private let waveformLock = UnfairLock()
    // These never drive UI directly (only `levels`/`isCapturing` do), so they shouldn't be part of
    // @Observable's tracking machinery in the first place — @ObservationIgnored opts them out,
    // which is also what makes plain `nonisolated(unsafe)` valid here (the ObservationTracked
    // accessors @Observable generates for *tracked* mutable properties reject `nonisolated`
    // annotations outright).
    @ObservationIgnored private nonisolated(unsafe) var ringL = [Float](repeating: 0, count: CoreAudioTapEngine.waveformSampleCount)
    @ObservationIgnored private nonisolated(unsafe) var ringR = [Float](repeating: 0, count: CoreAudioTapEngine.waveformSampleCount)

    /// Snapshot of the most recent raw samples, oldest first — for oscilloscope-style rendering.
    func snapshotWaveform() -> (left: [Float], right: [Float]) {
        waveformLock.lock()
        defer { waveformLock.unlock() }
        return (ringL, ringR)
    }

    private func pushWaveformSamples(left: [Float], right: [Float]) {
        guard waveformLock.tryLock() else { return }
        defer { waveformLock.unlock() }

        let n = left.count
        let capacity = Self.waveformSampleCount
        if n >= capacity {
            ringL = Array(left.suffix(capacity))
            ringR = Array(right.suffix(capacity))
        } else {
            ringL.removeFirst(n)
            ringL.append(contentsOf: left)
            ringR.removeFirst(n)
            ringR.append(contentsOf: right)
        }
    }

    // CoreAudio's HAL setup calls (AudioHardwareCreateProcessTap, AudioHardwareCreateAggregateDevice,
    // AudioDeviceCreateIOProcIDWithBlock) block on internal synchronization that doesn't play well
    // with Swift Concurrency's cooperative thread pool — calling them from a MainActor-isolated
    // async function deadlocks. Running them on a dedicated plain thread avoids that. All the
    // bookkeeping below is only ever touched from `controlQueue`, so it's safe despite not being
    // actor-isolated; the compiler just can't see that confinement.
    private let controlQueue = DispatchQueue(label: "com.prism.coreAudioTap.control")
    @ObservationIgnored private nonisolated(unsafe) var processTapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private nonisolated(unsafe) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private nonisolated(unsafe) var deviceProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()
    @ObservationIgnored private nonisolated(unsafe) var debugFrameCounter = 0
    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Nothing else reliably calls stop() before the process exits (there's no view-lifecycle
        // event that fires on quit). A killed/crashed process is handled by the HAL itself — a
        // process tap and its aggregate device are scoped to the owning process's Mach port, so
        // coreaudiod reclaims them once that port dies — but a clean Cmd+Q quit still deserves a
        // clean, synchronous teardown rather than relying on that.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.controlQueue.sync { self?.teardownSync() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func start() async {
        PrismDebug.trace("CoreAudioTapEngine.start() called")
        guard !isCapturing else {
            logger.debug("start() called but already capturing")
            return
        }

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            controlQueue.async { [weak self] in
                PrismDebug.trace("setupAndStartTapSync() begin (controlQueue)")
                let result = self?.setupAndStartTapSync() ?? false
                PrismDebug.trace("setupAndStartTapSync() end -> \(result)")
                continuation.resume(returning: result)
            }
        }
        isCapturing = success
        PrismDebug.trace("CoreAudioTapEngine.start() returned -> \(success)")
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async { [weak self] in
                self?.teardownSync()
                continuation.resume()
            }
        }
        isCapturing = false
    }

    // MARK: - Runs only on controlQueue

    private func setupAndStartTapSync() -> Bool {
        PrismDebug.trace("defaultOutputDeviceUID() start")
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            logger.error("could not resolve default output device UID")
            return false
        }
        PrismDebug.trace("defaultOutputDeviceUID() -> \(outputUID)")

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .unmuted

        PrismDebug.trace("AudioHardwareCreateProcessTap() start")
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        PrismDebug.trace("AudioHardwareCreateProcessTap() -> status \(status)")
        guard status == noErr else {
            logger.error("AudioHardwareCreateProcessTap failed, status=\(status, privacy: .public)")
            return false
        }
        processTapID = tapID
        logger.debug("process tap created, id=\(tapID, privacy: .public)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prism Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        PrismDebug.trace("AudioHardwareCreateAggregateDevice() start")
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        PrismDebug.trace("AudioHardwareCreateAggregateDevice() -> status \(status)")
        guard status == noErr else {
            logger.error("AudioHardwareCreateAggregateDevice failed, status=\(status, privacy: .public)")
            AudioHardwareDestroyProcessTap(tapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        aggregateDeviceID = aggregateID
        logger.debug("aggregate device created, id=\(aggregateID, privacy: .public)")

        PrismDebug.trace("AudioDeviceCreateIOProcIDWithBlock() start")
        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            self?.handleAudio(inputData)
        }
        PrismDebug.trace("AudioDeviceCreateIOProcIDWithBlock() -> status \(status)")
        guard status == noErr, let ioProcID else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed, status=\(status, privacy: .public)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            processTapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        deviceProcID = ioProcID
        logger.debug("IOProc created")

        PrismDebug.trace("AudioDeviceStart() start")
        status = AudioDeviceStart(aggregateID, ioProcID)
        PrismDebug.trace("AudioDeviceStart() -> status \(status)")
        guard status == noErr else {
            logger.error("AudioDeviceStart failed, status=\(status, privacy: .public)")
            return false
        }

        return true
    }

    private func teardownSync() {
        if let deviceProcID {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            self.deviceProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if processTapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Runs on CoreAudio's real-time IO thread

    private func handleAudio(_ bufferListPointer: UnsafePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferListPointer))
        guard let buffer = bufferList.first, let mData = buffer.mData else { return }

        let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: mData.bindMemory(to: Float.self, capacity: frameCount), count: frameCount))

        let channelCount = Int(buffer.mNumberChannels)
        if channelCount >= 2 {
            let frames = frameCount / channelCount
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                left[i] = samples[i * channelCount]
                right[i] = samples[i * channelCount + 1]
            }
            pushWaveformSamples(left: left, right: right)
        } else {
            pushWaveformSamples(left: samples, right: samples)
        }

        debugFrameCounter += 1
        let shouldLog = PrismDebug.verboseLogging && debugFrameCounter % 50 == 0
        if shouldLog {
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            logger.debug("buffer #\(self.debugFrameCounter, privacy: .public) — \(samples.count, privacy: .public) samples, rms=\(rms, privacy: .public)")
        }

        let bands = analyzer.process(samples, shouldLog: shouldLog)
        Task { @MainActor in
            self.levels = bands
        }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        guard status == noErr else {
            logger.error("failed to get default output device, status=\(status, privacy: .public)")
            return nil
        }

        var uidRef: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else {
            logger.error("failed to get output device UID, status=\(status, privacy: .public)")
            return nil
        }
        return uidRef as String
    }
}
