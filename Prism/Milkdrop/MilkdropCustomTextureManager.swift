//
//  MilkdropCustomTextureManager.swift
//  Prism
//
//  Resolves a preset shader's custom (non-main, non-noise) texture references — `sampler_worms`,
//  `sampler_rand00`, etc. (see MilkdropShaderTranslator.TextureBinding.Resource.custom) — against
//  the real preset pack's own `Textures/` folder. Port of projectM's Renderer/TextureManager.cpp,
//  scoped to just the filesystem-lookup/random-slot pieces that matter here (no OpenGL, no
//  age-based eviction — Prism's whole texture set for one preset is tiny compared to the corpus's
//  259MB, so there's no memory-pressure case worth the extra complexity of porting that part).
//
//  Per the "Preset library decision" in TO DO.md, Prism doesn't bundle or vendor any of the preset
//  pack's own textures — the pack is an aggregated community collection with unclear redistribution
//  rights, same reasoning that kept the .milk files themselves external. Concretely, this means:
//  every real preset pack sampled so far is also missing at least some of the textures its own
//  presets reference (confirmed directly: this Mac's copy of a real ~10k-preset pack has no
//  `worms.jpg` at all, despite `sampler_worms` being the single most-referenced custom name in the
//  corpus) — so "can't find the file" has to be a normal, silent case, not an error. Falls back to
//  a 1x1 black placeholder texture in that case, exactly matching TextureManager.cpp's own
//  `m_placeholderTexture` — never rejects the shader over it (see MilkdropShaderTranslator.swift).
//

import Foundation
import Metal
import MetalKit

final class MilkdropCustomTextureManager {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private let placeholder: MTLTexture?

    /// Base file name (lowercased, extension stripped) -> loaded texture. Cleared whenever the
    /// scanned root folder changes (a new preset from a different pack/location loads) — see
    /// `prepareForPreset(at:)`.
    private var cache: [String: MTLTexture] = [:]
    /// Every image file found under the current root, lowercased base name alongside its full URL —
    /// scanned once per distinct root, not per frame or even per preset (most presets in one pack
    /// share the same root, so re-scanning on every `loadPreset` would be pure waste).
    private var scannedFiles: [(baseName: String, url: URL)] = []
    private var scannedRoot: URL?
    /// `rand00`-`rand15` slot picks, cached per scanned root so every shader in the *same* loaded
    /// preset that references e.g. `sampler_rand00` gets the same file — matching real Milkdrop's
    /// own per-preset `randomTextureDescriptors` cache (MilkdropShader.cpp) rather than rolling a
    /// fresh random pick per shader or per frame.
    private var randomSlotChoices: [Int: String] = [:]

    /// Real image formats found in a sampled preset pack's `Textures/` folder; matches
    /// TextureManager.cpp's own `m_extensions` list minus `.dds` (a DirectX-compressed format
    /// `MTKTextureLoader` doesn't decode, and one that hasn't turned up in any sampled pack so far).
    private static let recognizedExtensions: Set<String> = ["jpg", "jpeg", "png", "tga", "bmp", "dib"]

    init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
        self.placeholder = Self.makePlaceholder(device: device)
    }

    /// Re-scans the `Textures/` folder near `presetURL` if it's different from whichever root is
    /// currently cached — a no-op on every frame of the common case (the same preset, or another
    /// preset from the same pack, keeps drawing). Call once per preset load generation (see
    /// MilkdropMetalRenderer's `loadGeneration`-gated recompilation for the same pattern).
    func prepareForPreset(at presetURL: URL?) {
        let root = presetURL.flatMap { Self.findTexturesFolder(near: $0) }
        guard root != scannedRoot else { return }
        scannedRoot = root
        cache.removeAll()
        randomSlotChoices.removeAll()
        scannedFiles = root.map(Self.scan(_:)) ?? []
    }

    /// Resolves an already qualifier-stripped, lowercased base name (see
    /// MilkdropShaderTranslator.classify) to a texture. `randNN` (`rand00`-`rand99`, optionally
    /// followed by `_prefix` to filter candidates by their own filename prefix) picks a random file
    /// instead of matching a literal name — see TextureManager::GetRandomTexture. Never returns
    /// `nil` outright: a name this manager can't resolve to a real file falls back to a 1x1 black
    /// placeholder, same as real Milkdrop's own texture manager.
    func texture(named baseName: String) -> MTLTexture? {
        if let cached = cache[baseName] { return cached }

        let resolvedFileName: String?
        if let randomName = Self.randomFileName(for: baseName, choices: &randomSlotChoices, files: scannedFiles) {
            resolvedFileName = randomName
        } else {
            resolvedFileName = scannedFiles.first { $0.baseName == baseName }?.baseName
        }

        guard let resolvedFileName, let fileURL = scannedFiles.first(where: { $0.baseName == resolvedFileName })?.url,
              let texture = try? loader.newTexture(URL: fileURL, options: [.SRGB: false])
        else {
            // Cache the placeholder too — a name that fails to resolve once will fail every time
            // for the same scanned root, so there's no reason to retry the disk lookup every frame.
            if let placeholder { cache[baseName] = placeholder }
            return placeholder
        }
        cache[baseName] = texture
        return texture
    }

    /// If `baseName` matches Milkdrop's `randNN`(`_prefix`)? convention (`rand` + exactly 2 digits,
    /// slot 0-15 — MilkdropShader.cpp's own range check), returns a real scanned file's base name:
    /// the same one already chosen for that slot this preset load, or a fresh random pick (optionally
    /// filtered to files whose name starts with `_prefix`) if this is the slot's first request.
    private static func randomFileName(for baseName: String, choices: inout [Int: String], files: [(baseName: String, url: URL)]) -> String? {
        guard baseName.count >= 6, baseName.hasPrefix("rand") else { return nil }
        let digitsStart = baseName.index(baseName.startIndex, offsetBy: 4)
        let digitsEnd = baseName.index(digitsStart, offsetBy: 2)
        let digits = baseName[digitsStart..<digitsEnd]
        guard digits.allSatisfy(\.isNumber), let slot = Int(digits), (0...15).contains(slot) else { return nil }

        if let existing = choices[slot] { return existing }

        var candidates = files
        let afterDigits = baseName[digitsEnd...]
        if afterDigits.hasPrefix("_") {
            let prefix = afterDigits.dropFirst()
            if !prefix.isEmpty {
                candidates = files.filter { $0.baseName.hasPrefix(prefix) }
            }
        }
        guard let picked = candidates.randomElement()?.baseName else { return nil }
        choices[slot] = picked
        return picked
    }

    // MARK: - Textures/ folder discovery

    /// Walks upward from `presetURL`'s own containing folder looking for a `Textures` subdirectory
    /// at each ancestor level — real preset packs keep `Textures/` as a sibling of `Presets/` (i.e.
    /// several levels above wherever an individual `.milk` file actually sits, e.g.
    /// `ThePack/Presets/Reaction/Cloudy/foo.milk` needs `ThePack/Textures/`, 3 levels up from
    /// `foo.milk`'s own folder), confirmed directly against a real ~10k-file pack on this machine.
    /// `maxLevels` bounds the walk well past any real pack's nesting depth without risking a slow
    /// crawl toward the filesystem root on an unusual layout.
    private static func findTexturesFolder(near presetURL: URL, maxLevels: Int = 8) -> URL? {
        let fm = FileManager.default
        var dir = presetURL.deletingLastPathComponent()
        for _ in 0..<maxLevels {
            let candidate = dir.appendingPathComponent("Textures", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        return nil
    }

    /// Recursively lists every recognized image file directly under `root` (Milkdrop texture packs
    /// occasionally nest subfolders too — projectM's own FileScanner recurses, so this does too),
    /// paired with its lowercased, extension-stripped base name for case-insensitive lookup.
    private static func scan(_ root: URL) -> [(baseName: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var results: [(baseName: String, url: URL)] = []
        for case let url as URL in enumerator {
            guard recognizedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            results.append((baseName: url.deletingPathExtension().lastPathComponent.lowercased(), url: url))
        }
        return results
    }

    // MARK: - Placeholder

    private static func makePlaceholder(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var black: UInt32 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
        return texture
    }
}
