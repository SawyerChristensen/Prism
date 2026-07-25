//
//  MilkdropNoiseTexturesTests.swift
//  PrismTests
//
//  MilkdropNoiseTextures' generation math is a direct port of MilkdropNoise.cpp's random-fill +
//  cubic-smoothing loops (see that file's header) — the actual noise content is intentionally
//  non-deterministic (real Milkdrop reseeds every run too), so these tests exercise the thing that
//  actually can go wrong in a port like this: index math in the smoothing passes (zoomFactor > 1)
//  not crashing/going out of bounds, and every catalog entry actually being reachable, rather than
//  asserting anything about pixel content.
//

import Metal
import Testing
@testable import Prism

struct MilkdropNoiseTexturesTests {

    private func makeCatalog() throws -> MilkdropNoiseTextures {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        return try #require(MilkdropNoiseTextures(device: device))
    }

    @Test func allFiveCatalogTexturesAreCreatedWithExpectedDimensions() throws {
        let catalog = try makeCatalog()
        #expect(catalog.noiseLq.width == 256 && catalog.noiseLq.height == 256)
        #expect(catalog.noiseMq.width == 256 && catalog.noiseMq.height == 256)
        #expect(catalog.noiseHq.width == 256 && catalog.noiseHq.height == 256)
        #expect(catalog.noiseVolLq.width == 32 && catalog.noiseVolLq.depth == 32)
        #expect(catalog.noiseVolHq.width == 32 && catalog.noiseVolHq.depth == 32)
        for texture in [catalog.noiseLq, catalog.noiseMq, catalog.noiseHq, catalog.noiseVolLq, catalog.noiseVolHq] {
            #expect(texture.pixelFormat == .rgba8Unorm)
        }
    }

    @Test func textureNamedResolvesEveryCatalogKeyAndRejectsUnknownNames() throws {
        let catalog = try makeCatalog()
        #expect(catalog.texture(named: "noise_lq") === catalog.noiseLq)
        #expect(catalog.texture(named: "noise_mq") === catalog.noiseMq)
        #expect(catalog.texture(named: "noise_hq") === catalog.noiseHq)
        #expect(catalog.texture(named: "noisevol_lq") === catalog.noiseVolLq)
        #expect(catalog.texture(named: "noisevol_hq") === catalog.noiseVolHq)
        #expect(catalog.texture(named: "clouds") == nil)
        #expect(catalog.texture(named: "") == nil)
    }
}
