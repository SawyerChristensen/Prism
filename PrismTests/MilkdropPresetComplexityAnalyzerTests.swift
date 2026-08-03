//
//  MilkdropPresetComplexityAnalyzerTests.swift
//  PrismTests
//
//  Coverage for both cost paths MilkdropPresetComplexityAnalyzer checks: the tex3D/GetPixel/
//  GetBlur1/2/3 per-pixel shader scan, and the shapecode/wavecode instance-count scan. Includes a
//  regression case for the GetBlur1/2/3 substring bug (the old check only matched the literal
//  string "getblur(", which real presets never call — the actual intrinsics are always numbered)
//  and for "amandio c - the climbing ..." (TO DO.md), whose cost is entirely from shapecode
//  num_inst, with no expensive-looking pixel shader at all.
//

import Testing
@testable import Prism

struct MilkdropPresetComplexityAnalyzerTests {
    @Test func emptyPresetIsNotExpensive() {
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: "") == false)
    }

    @Test func plainWarpWithNoShaderCallsIsNotExpensive() {
        let text = """
        warp_1=`shader_body
        warp_2=`{
        warp_3=`ret = tex2D(sampler_main, uv);
        warp_4=`}
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == false)
    }

    @Test func tex3DLookupIsExpensive() {
        let text = """
        warp_1=`shader_body
        warp_2=`{
        warp_3=`ret = tex3D(sampler_noise, float3(uv, 0.0));
        warp_4=`}
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == true)
    }

    @Test func threeOrMoreGetPixelCallsAreExpensive() {
        let text = """
        comp_1=`shader_body
        comp_2=`{
        comp_3=`ret = GetPixel(uv) + GetPixel(uv+float2(.01,0)) + GetPixel(uv-float2(.01,0));
        comp_4=`}
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == true)
    }

    @Test func fewerThanThreeNeighborSamplesAreNotExpensive() {
        let text = """
        comp_1=`shader_body
        comp_2=`{
        comp_3=`ret = GetPixel(uv) + GetBlur1(uv);
        comp_4=`}
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == false)
    }

    /// Regression test: the old check only matched the exact substring "getblur(", which never
    /// appears in real presets (the intrinsics are always GetBlur1/GetBlur2/GetBlur3). This preset
    /// calls all three real forms and must be flagged.
    @Test func numberedGetBlurCallsAreExpensive() {
        let text = """
        comp_1=`shader_body
        comp_2=`{
        comp_3=`ret = GetBlur1(uv).z + GetBlur3(uv).z;
        comp_4=`ret *= GetBlur2(uv+float2(0,.01)).y;
        comp_5=`}
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == true)
    }

    @Test func highNumInstShapecodeIsExpensiveWithNoPixelShaderCost() {
        var lines = [
            "shapecode_0_enabled=1",
            "shapecode_0_num_inst=1024",
        ]
        for i in 1...85 {
            lines.append("shape_0_per_frame\(i)=x=sin(\(i)*sample);")
        }
        let text = lines.joined(separator: "\n")
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == true)
    }

    @Test func lowNumInstShapecodeIsNotExpensive() {
        let text = """
        shapecode_0_enabled=1
        shapecode_0_num_inst=8
        shape_0_per_frame1=x=sin(sample);
        shape_0_per_frame2=y=cos(sample);
        """
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == false)
    }

    @Test func disabledHighNumInstShapecodeIsNotExpensive() {
        var lines = [
            "shapecode_0_enabled=0",
            "shapecode_0_num_inst=1024",
        ]
        for i in 1...85 {
            lines.append("shape_0_per_frame\(i)=x=sin(\(i)*sample);")
        }
        let text = lines.joined(separator: "\n")
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == false)
    }

    @Test func highSampleWavecodeWithPerPointCodeIsExpensive() {
        var lines = [
            "wavecode_0_enabled=1",
            "wavecode_0_samples=512",
        ]
        for i in 1...100 {
            lines.append("wave_0_per_point\(i)=x=sin(\(i)*sample);")
        }
        let text = lines.joined(separator: "\n")
        #expect(MilkdropPresetComplexityAnalyzer.isExpensive(presetText: text) == true)
    }
}
