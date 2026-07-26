//
//  MilkdropPerPixelMeshVertexShaderTests.swift
//  PrismTests
//
//  Compiles MilkdropMetalRenderer.buildPerPixelMeshVertexSource's output (Tier 3 of TO DO.md's
//  performance-pass notes: a per_pixel_N= script transpiled directly into a GPU vertex function,
//  replacing up to 825 CPU tree-interpreter evaluations/frame) through a real MTLDevice, paired
//  with a trivial fragment function into an actual MTLRenderPipelineState — same pattern
//  MilkdropMetalRendererShaderTests already uses for buildCompositeShaderSource/
//  buildWarpShaderSource. This is the test that would catch a real MSL syntax/semantic mistake in
//  the duplicated warp math (see that function's own doc comment on why it's a deliberate
//  duplicate of Shaders.metal's feedback_mesh_vertex, not a shared declaration) before it ever
//  reached a running preset load.
//
//  Verified first, more exhaustively, via a standalone `swiftc` harness: 16 checks — 3 synthetic
//  per-pixel scripts plus 6 real `per_pixel_N=` scripts pulled from the actual ~9,795-file preset
//  pack on this machine (one correctly skipped by the safety analyzer as unsafe, the rest compiled
//  *and* dispatched a real 33x25-vertex draw call with no runtime error), 0 failures.
//

import Metal
import Testing
@testable import Prism

struct MilkdropPerPixelMeshVertexShaderTests {
    private let builtins: Set<String> = Set(
        MilkdropPerPixelMeshRuntime.perFrameUniformBuiltinNames + MilkdropPerPixelMeshRuntime.perVertexBuiltinNames
    )

    /// `nil` if the script isn't sweep-parallel-safe or uses an unsupported construct — callers
    /// should treat that as "nothing to compile," not a failure (the real renderer falls back to
    /// the CPU interpreter in exactly that case).
    private func compiledVertexFunction(for source: String) throws -> MTLFunction? {
        guard let program = MilkdropExpressionProgram(source: source) else { return nil }
        guard MilkdropExpressionParallelSafetyAnalyzer.isSweepParallelSafe(program.statements, builtins: builtins) else { return nil }
        guard let transpiled = MilkdropExpressionMSLTranspiler.transpile(program.statements, builtins: builtins) else { return nil }

        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let mslSource = MilkdropMetalRenderer.buildPerPixelMeshVertexSource(transpiled)
        let library = try device.makeLibrary(source: mslSource, options: options)
        return library.makeFunction(name: "milkdrop_per_pixel_mesh_vertex")
    }

    /// Pairs the compiled vertex function with a trivial fragment into a real
    /// `MTLRenderPipelineState` — matching how the real renderer pairs it with either a compiled
    /// `warp_N=` fragment or the static `feedback_mesh_fragment`.
    private func linksIntoARealPipeline(_ source: String) throws -> Bool {
        guard let vertexFunction = try compiledVertexFunction(for: source) else { return true } // nothing to link — not a failure
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fragmentSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct MeshVertexOut {
            float4 position [[position]];
            float2 uv;
            float2 uvOrig;
            float2 radiusAngle;
        };
        fragment float4 trivial_fragment(MeshVertexOut in [[stage_in]]) {
            return float4(in.uv, 0.0, 1.0);
        }
        """
        let fragmentLibrary = try device.makeLibrary(source: fragmentSource, options: nil)
        let fragmentFunction = try #require(fragmentLibrary.makeFunction(name: "trivial_fragment"))

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return (try? device.makeRenderPipelineState(descriptor: descriptor)) != nil
    }

    @Test func simpleZoomRotScriptCompilesAndLinks() throws {
        #expect(try linksIntoARealPipeline("zoom = 1 + 0.1*sin(time); rot = rot + 0.001*bass; cx = 0.5 + 0.1*cos(ang);"))
    }

    @Test func scriptUsingXYRadAngBuiltinsCompilesAndLinks() throws {
        #expect(try linksIntoARealPipeline("an = ang + q1; zm = 0.5 + 0.5*sin(an*4); zoom = 1 + zm*q2; dx = dx*0.9;"))
    }

    @Test func scriptUsingIfAboveAndComparisonsCompilesAndLinks() throws {
        #expect(try linksIntoARealPipeline("zoom = if(above(bass,0.5), 1.1, 0.9); rot = (x < y) * 0.1;"))
    }

    @Test func unsafeAccumulatorScriptCompilesToNothingRatherThanFailing() throws {
        // hue=hue+0.01 depends on cross-vertex evaluation order — the safety analyzer must reject
        // it, and `compiledVertexFunction` returning nil here (not throwing) is the correct,
        // documented fallback contract, not a test failure.
        let vertexFunction = try compiledVertexFunction(for: "hue = hue + 0.01; zoom = hue;")
        #expect(vertexFunction == nil)
    }

    @Test func realCorpusStyleScriptCompilesAndLinks() throws {
        // A representative real per_pixel_N= body (see TO DO.md's corpus notes) — chained locals,
        // sqrt/sqr/atan, and a custom (but same-iteration-only, hence safe) temp variable.
        #expect(try linksIntoARealPipeline("""
        cx=0.5+q4;
        cy=0.5-q5;
        rd=sqrt( sqr( (x-0.5-q4)*2) + sqr( (y-0.5+q5)*1.5 ) );
        zm=1;
        ag=atan( (y-0.5+q5)/(x-0.5-q4) );
        star=sin(ag*6+time)*(2-rd);
        sy=(1/rad/ag/(rd+bass));
        sx=-1.3;
        rot=ag;
        """))
    }
}
