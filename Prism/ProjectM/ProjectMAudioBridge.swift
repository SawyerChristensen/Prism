//
//  ProjectMAudioBridge.swift
//  Prism
//
//  Pulls the latest raw waveform snapshot from CoreAudioTapEngine (preserved as-is — see
//  CoreAudioTapEngine.swift's own header) and feeds it into a ProjectMEngine as interleaved
//  stereo PCM, once per rendered frame. Kept separate from ProjectMCoordinator so render-loop
//  orchestration doesn't get tangled up with audio-format/interleaving concerns.
//

import Foundation

enum ProjectMAudioBridge {
    static func feed(_ engine: ProjectMEngine, from audioEngine: CoreAudioTapEngine) {
        let (left, right) = audioEngine.snapshotWaveform()
        let frameCount = min(left.count, right.count)
        guard frameCount > 0 else { return }

        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }
        interleaved.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            engine.addInterleavedStereoPCM(baseAddress, frameCount: UInt(frameCount))
        }
    }
}
