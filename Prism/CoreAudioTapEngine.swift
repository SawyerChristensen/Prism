//
//  CoreAudioTapEngine.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import Foundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.prism.app", category: "CoreAudioTapEngine")

@Observable
final class CoreAudioTapEngine: NSObject {
    private(set) var levels: [CGFloat] = Array(repeating: 0.02, count: 40)
    private(set) var isCapturing = false

    private let analyzer = SpectrumAnalyzer()

    // CoreAudio's HAL setup calls (AudioHardwareCreateProcessTap, AudioHardwareCreateAggregateDevice,
    // AudioDeviceCreateIOProcIDWithBlock) block on internal synchronization that doesn't play well
    // with Swift Concurrency's cooperative thread pool — calling them from a MainActor-isolated
    // async function deadlocks. Running them on a dedicated plain thread avoids that. All the
    // bookkeeping below is only ever touched from `controlQueue`, so it's safe despite not being
    // actor-isolated; the compiler just can't see that confinement.
    private let controlQueue = DispatchQueue(label: "com.prism.coreAudioTap.control")
    private nonisolated(unsafe) var processTapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var deviceProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) let tapUUID = UUID()
    private nonisolated(unsafe) var debugFrameCounter = 0

    func start() async {
        guard !isCapturing else {
            logger.debug("start() called but already capturing")
            return
        }

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            controlQueue.async { [weak self] in
                continuation.resume(returning: self?.setupAndStartTapSync() ?? false)
            }
        }
        isCapturing = success
        if success {
            logger.debug("Core Audio tap capture started successfully")
        }
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
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            logger.error("could not resolve default output device UID")
            return false
        }
        logger.debug("default output device UID: \(outputUID, privacy: .public)")

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
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

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            logger.error("AudioHardwareCreateAggregateDevice failed, status=\(status, privacy: .public)")
            AudioHardwareDestroyProcessTap(tapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        aggregateDeviceID = aggregateID
        logger.debug("aggregate device created, id=\(aggregateID, privacy: .public)")

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            self?.handleAudio(inputData)
        }
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

        status = AudioDeviceStart(aggregateID, ioProcID)
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
