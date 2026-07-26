//
//  MilkdropCustomTextureManagerTests.swift
//  PrismTests
//
//  Coverage for MilkdropCustomTextureManager against a synthetic temp-directory fixture (not the
//  real preset pack on this Mac's Desktop, which is a machine-specific path — see this file's
//  presetFile()-style helper) laid out the same way a real pack is: `Pack/Presets/.../foo.milk`
//  with `Pack/Textures/` as a sibling of `Presets/`, several levels up from the .milk file itself.
//  This behavior was also verified directly against a real ~10k-preset pack during development
//  (see the session notes in TO DO.md) — this file exists for portable, repeatable regression
//  coverage of the same logic, not as the first verification of it.
//

import Foundation
import Metal
import Testing
@testable import Prism

struct MilkdropCustomTextureManagerTests {
    /// A minimal valid 1x1 RGBA PNG, decodable by MTKTextureLoader — real image bytes, not a
    /// hand-rolled fake format, so a lookup that succeeds here would also succeed against a real
    /// preset pack's actual texture files.
    private static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// Builds `root/Presets/Category/Sub/preset.milk` alongside `root/Textures/<name>.png` for
    /// each name in `textureNames` — the same nesting depth (2 levels under Presets/) confirmed
    /// against a real preset pack, with Textures/ as a sibling of Presets/ rather than nested
    /// inside it.
    private func makePack(textureNames: [String]) throws -> (presetURL: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let presetDir = root.appendingPathComponent("Presets/Category/Sub", isDirectory: true)
        let texturesDir = root.appendingPathComponent("Textures", isDirectory: true)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: texturesDir, withIntermediateDirectories: true)

        let presetURL = presetDir.appendingPathComponent("preset.milk")
        try "[preset00]\nnWaveMode=0\n".write(to: presetURL, atomically: true, encoding: .utf8)

        for name in textureNames {
            try Self.onePixelPNG.write(to: texturesDir.appendingPathComponent("\(name).png"))
        }
        return (presetURL, root)
    }

    private func makeManager() throws -> MilkdropCustomTextureManager {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        return MilkdropCustomTextureManager(device: device)
    }

    @Test func resolvesARealFileByLowercasedBaseName() throws {
        let (presetURL, _) = try makePack(textureNames: ["clouds"])
        let manager = try makeManager()
        manager.prepareForPreset(at: presetURL)
        let texture = try #require(manager.texture(named: "clouds"))
        #expect(texture.width == 1 && texture.height == 1)
    }

    @Test func missingNameFallsBackToAOnePixelPlaceholderRatherThanNil() throws {
        let (presetURL, _) = try makePack(textureNames: ["clouds"])
        let manager = try makeManager()
        manager.prepareForPreset(at: presetURL)
        let texture = try #require(manager.texture(named: "worms"))
        #expect(texture.width == 1 && texture.height == 1)
    }

    @Test func noTexturesFolderAtAllStillFallsBackToPlaceholderInsteadOfCrashing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let presetDir = root.appendingPathComponent("Presets", isDirectory: true)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        let presetURL = presetDir.appendingPathComponent("preset.milk")
        try "[preset00]\n".write(to: presetURL, atomically: true, encoding: .utf8)

        let manager = try makeManager()
        manager.prepareForPreset(at: presetURL)
        #expect(manager.texture(named: "anything") != nil)
    }

    @Test func randomSlotPicksAreStableWithinOnePresetLoad() throws {
        // rand00 (a real slot 0-15 per MilkdropShader.cpp) should return the SAME texture on every
        // call for as long as the same preset stays loaded — matching real Milkdrop's own
        // per-preset randomTextureDescriptors cache, not a fresh roll every call.
        let (presetURL, _) = try makePack(textureNames: ["a", "b", "c"])
        let manager = try makeManager()
        manager.prepareForPreset(at: presetURL)
        let first = try #require(manager.texture(named: "rand00"))
        for _ in 0..<5 {
            #expect(manager.texture(named: "rand00") === first)
        }
    }

    @Test func outOfRangeRandomSlotIsTreatedAsALiteralMissingName() throws {
        // Only slots 0-15 are real random slots (MilkdropShader.cpp's own range check) — "rand16"
        // isn't a valid slot, so it should resolve like any other not-found literal name: the
        // placeholder, not a random pick.
        let (presetURL, _) = try makePack(textureNames: ["a", "b", "c"])
        let manager = try makeManager()
        manager.prepareForPreset(at: presetURL)
        let texture = try #require(manager.texture(named: "rand16"))
        #expect(texture.width == 1 && texture.height == 1)
    }

    @Test func loadingADifferentPackClearsTheStaleCache() throws {
        let (firstPreset, _) = try makePack(textureNames: ["onlyinfirst"])
        let (secondPreset, _) = try makePack(textureNames: ["onlyinsecond"])
        let manager = try makeManager()

        manager.prepareForPreset(at: firstPreset)
        let first = try #require(manager.texture(named: "onlyinfirst"))
        #expect(first.width == 1)

        manager.prepareForPreset(at: secondPreset)
        let second = try #require(manager.texture(named: "onlyinsecond"))
        #expect(second.width == 1)
        // "onlyinfirst" doesn't exist in the second pack's Textures/ folder — must fall back to
        // the placeholder, not a stale reference to the first pack's file.
        let staleName = try #require(manager.texture(named: "onlyinfirst"))
        #expect(staleName === manager.texture(named: "onlyinfirst"))
    }
}
