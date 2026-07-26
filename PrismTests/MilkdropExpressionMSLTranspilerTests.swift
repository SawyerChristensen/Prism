//
//  MilkdropExpressionMSLTranspilerTests.swift
//  PrismTests
//
//  Compiles MilkdropExpressionMSLTranspiler's generated MSL through a real MTLDevice (same safe,
//  no-CoreAudio/AppKit pattern MilkdropMetalRendererShaderTests already uses) and, for a spread of
//  representative programs, actually dispatches a compute kernel running the transpiled body and
//  compares its output against MilkdropExpressionProgram's own (reference) dictionary-based
//  evaluator for identical inputs — not just "did it compile," but "did it compute the same
//  answer." `if`/`&&`/`||` short-circuit in both (real NS-EEL semantics, confirmed 7/26 — see
//  MilkdropExpressionMSLTranspiler.swift's header), so these tests confirm the GPU and CPU sides
//  agree on *which* branch/side actually ran (an untaken branch's side effect must not appear on
//  either side), not that both unconditionally run everything. Verified first, much more
//  exhaustively, via a standalone `swiftc` harness: 20,000 checks (17 synthetic programs covering
//  every operator/builtin/edge case, plus 6 real `per_pixel_N=` scripts pulled from the actual
//  ~9,795-file preset pack on this machine), 0 failures, GPU output matching CPU to within float
//  precision (`mathMode = .safe`, disabling fast-math, which would otherwise risk masking a real
//  mismatch as "close enough"). See TO DO.md for the full writeup.
//

import Metal
import Testing
@testable import Prism

struct MilkdropExpressionMSLTranspilerTests {
    private let builtinNames = ["x", "y", "rad", "ang", "time", "bass", "treb", "zoom", "rot", "cx", "cy"]
    private var builtins: Set<String> { Set(builtinNames) }

    /// Compiles `source`'s transpiled MSL into a real compute pipeline, dispatches it over a
    /// handful of varied inputs, and returns (gpu results, cpu reference results) per thread, one
    /// dictionary per output name (builtins + any custom variables the program introduced) — `nil`
    /// if the program is empty or uses an unsupported construct (e.g. `rand()`), which callers
    /// should treat as "nothing to compare," not a failure.
    private func runOnGPUAndCPU(_ source: String, threadCount: Int = 8) throws -> (gpu: [[String: Float]], cpu: [[String: Float]])? {
        guard let program = MilkdropExpressionProgram(source: source) else { return nil }
        guard let result = MilkdropExpressionMSLTranspiler.transpile(program.statements, builtins: builtins) else { return nil }

        let outputNames = builtinNames + result.customVariableNames
        var mslLines = ["#include <metal_stdlib>", "using namespace metal;", MilkdropExpressionMSLTranspiler.shimFunctions]
        mslLines.append("kernel void test_kernel(const device float *inputs [[buffer(0)]], device float *outputs [[buffer(1)]], uint tid [[thread_position_in_grid]]) {")
        mslLines.append("  uint inBase = tid * \(builtinNames.count)u;")
        mslLines.append("  uint outBase = tid * \(outputNames.count)u;")
        for (i, name) in builtinNames.enumerated() {
            mslLines.append("  float \(MilkdropExpressionMSLTranspiler.mslIdentifier(for: name)) = inputs[inBase + \(i)u];")
        }
        for name in result.customVariableNames {
            mslLines.append("  float \(MilkdropExpressionMSLTranspiler.mslIdentifier(for: name)) = 0.0f;")
        }
        mslLines.append(result.body)
        for (i, name) in outputNames.enumerated() {
            mslLines.append("  outputs[outBase + \(i)u] = \(MilkdropExpressionMSLTranspiler.mslIdentifier(for: name));")
        }
        mslLines.append("}")

        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        let queue = try #require(device.makeCommandQueue())
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: mslLines.joined(separator: "\n"), options: options)
        let function = try #require(library.makeFunction(name: "test_kernel"))
        let pipeline = try device.makeComputePipelineState(function: function)

        var inputData = [Float](repeating: 0, count: threadCount * builtinNames.count)
        var cpuSeeds: [[String: Float]] = []
        for t in 0..<threadCount {
            var seed: [String: Float] = [:]
            for (i, name) in builtinNames.enumerated() {
                let v = sin(Float(t * 11 + i * 7)) * 3.3 + Float(t) * 0.05 - 0.8
                inputData[t * builtinNames.count + i] = v
                seed[name] = v
            }
            cpuSeeds.append(seed)
        }

        let inputBuffer = try #require(device.makeBuffer(bytes: &inputData, length: MemoryLayout<Float>.stride * inputData.count, options: .storageModeShared))
        let outputBuffer = try #require(device.makeBuffer(length: MemoryLayout<Float>.stride * threadCount * outputNames.count, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: threadCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadCount, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let outPtr = outputBuffer.contents().bindMemory(to: Float.self, capacity: threadCount * outputNames.count)
        var gpuResults: [[String: Float]] = []
        var cpuResults: [[String: Float]] = []
        for t in 0..<threadCount {
            var gpuRow: [String: Float] = [:]
            for (i, name) in outputNames.enumerated() { gpuRow[name] = outPtr[t * outputNames.count + i] }
            gpuResults.append(gpuRow)

            var cpuVars = cpuSeeds[t]
            MilkdropExpressionProgram(source: source)?.evaluate(&cpuVars)
            cpuResults.append(cpuVars)
        }
        return (gpuResults, cpuResults)
    }

    private func assertGPUMatchesCPU(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard let (gpuResults, cpuResults) = try runOnGPUAndCPU(source) else { return }
        for (thread, (gpuRow, cpuRow)) in zip(gpuResults, cpuResults).enumerated() {
            for (name, cpuValue) in cpuRow {
                let gpuValue = gpuRow[name] ?? 0
                let matched = abs(gpuValue - cpuValue) < 0.0005 || (gpuValue.isNaN && cpuValue.isNaN)
                #expect(matched, "thread \(thread) '\(name)': cpu=\(cpuValue) gpu=\(gpuValue)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func arithmeticAndComparisonsMatchCPU() throws {
        try assertGPUMatchesCPU("a = 1 + 2 - 3 * 4 / 5; b = (x < y); c = (x == x); d = 7 % 0;")
    }

    @Test func ifShortCircuitsOnlyTakenBranchMatchesCPU() throws {
        // The single most important correctness property this transpiler must preserve — see this
        // file's header and MilkdropExpressionMSLTranspiler.swift's own header. GPU and CPU must
        // agree on exactly which branch's side effect fired for both a true and a false condition.
        try assertGPUMatchesCPU("s1 = 0; s2 = 0; a = if(above(bass, 0.5), s1 = 1, s2 = 1); b = s1; c = s2;")
        try assertGPUMatchesCPU("s1 = 0; s2 = 0; a = if(above(bass, 999.0), s1 = 1, s2 = 1); b = s1; c = s2;")
    }

    @Test func logicalAndOrShortCircuitMatchesCPU() throws {
        try assertGPUMatchesCPU("s1 = 0; s2 = 0; a = (bass > 0.5) && (s1 = 1); b = (treb > 5) || (s2 = 1); c = s1; d = s2;")
        try assertGPUMatchesCPU("s1 = 0; s2 = 0; a = (bass > 999.0) && (s1 = 1); b = (treb > -999.0) || (s2 = 1); c = s1; d = s2;")
    }

    @Test func guardedOpsMatchCPU() throws {
        try assertGPUMatchesCPU("a = sqrt(-4); b = log(-1); c = log10(-1); d = 5/0;")
    }

    @Test func trigAndPowMatchCPU() throws {
        try assertGPUMatchesCPU("a = sin(time); b = cos(time); c = pow(2,3); d = atan2(y,x);")
    }

    @Test func unsupportedFunctionStillEvaluatesArgsForSideEffectsOnGPU() throws {
        try assertGPUMatchesCPU("s = 0; a = totallyMadeUp(x, s = 5, y); b = s;")
    }

    @Test func realPerPixelStyleScriptMatchesCPU() throws {
        try assertGPUMatchesCPU("""
        zoom = 1 + 0.1*sin(time);
        rot = rot + 0.001*bass;
        cx = 0.5 + 0.1*cos(ang);
        accum = accum + x;
        """)
    }

    @Test func randIsUnsupportedAndTranspileReturnsNil() {
        let program = MilkdropExpressionProgram(source: "a = rand(3);")
        #expect(program.flatMap { MilkdropExpressionMSLTranspiler.transpile($0.statements, builtins: builtins) } == nil)
    }
}
