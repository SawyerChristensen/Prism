//
//  AudioCaptureEngine.swift
//  Prism
//
//  Audio capture via ScreenCaptureKit (audio-only, minimal video surface). Requires the
//  Screen Recording TCC permission. See CoreAudioTapEngine.swift for the alternative
//  Core Audio Process Tap-based capture path (macOS 14.4+), which avoids that permission.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import os

private let logger = Logger(subsystem: "com.prism.app", category: "AudioCaptureEngine")

@Observable
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var levels: [CGFloat] = Array(repeating: 0.02, count: 40)
    private(set) var isCapturing = false

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.prism.audioCaptureQueue.sck")
    private let analyzer = SpectrumAnalyzer()
    private var debugFrameCounter = 0

    func start() async {
        guard !isCapturing else {
            logger.debug("start() called but already capturing")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            logger.debug("found \(content.displays.count, privacy: .public) display(s)")
            guard let display = content.displays.first else {
                logger.debug("no displays available, aborting capture start")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()

            self.stream = newStream
            self.isCapturing = true
            logger.debug("capture started successfully on display \(display.displayID, privacy: .public)")
        } catch {
            logger.error("failed to start audio capture — \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        self.isCapturing = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        debugFrameCounter += 1
        let shouldLog = PrismDebug.verboseLogging && debugFrameCounter % 50 == 0

        guard sampleBuffer.isValid else {
            if shouldLog { logger.debug("received invalid sample buffer") }
            return
        }
        guard let samples = Self.extractFloatSamples(from: sampleBuffer) else {
            if shouldLog { logger.debug("sample extraction returned nil (buffer #\(self.debugFrameCounter, privacy: .public))") }
            return
        }

        if shouldLog {
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            logger.debug("buffer #\(self.debugFrameCounter, privacy: .public) — \(samples.count, privacy: .public) samples, rms=\(rms, privacy: .public)")
        }

        let bands = analyzer.process(samples, shouldLog: shouldLog)
        Task { @MainActor in
            self.levels = bands
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("stream stopped with error — \(String(describing: error), privacy: .public)")
        Task { @MainActor in
            self.isCapturing = false
        }
    }

    private static func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = sampleBuffer.formatDescription else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        // Non-interleaved stereo needs an AudioBufferList with 2 AudioBuffer entries, which is
        // larger than MemoryLayout<AudioBufferList>.size (that only accounts for 1). Ask CoreMedia
        // how many bytes it actually needs first, then allocate exactly that.
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else {
            logger.debug("size query failed, status=\(status, privacy: .public)")
            return nil
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let audioBufferListPointer = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            logger.debug("buffer fetch failed, status=\(status, privacy: .public)")
            return nil
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: audioBufferListPointer, deallocator: nil) else {
            logger.debug("AVAudioPCMBuffer init failed")
            return nil
        }
        guard let channelData = pcmBuffer.floatChannelData else {
            logger.debug("floatChannelData was nil (format: \(audioFormat.description, privacy: .public))")
            return nil
        }

        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
