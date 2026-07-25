//
//  MilkdropNoiseTextures.swift
//  Prism
//
//  Milkdrop's built-in 2D/3D value-noise textures, generated once at renderer startup — the
//  standard `sampler_noise_lq`/`sampler_noisevol_hq`/etc. textures real preset warp/comp shaders
//  reference (see MilkdropShaderTranslator.swift's header for why these specifically: a 9,795-preset
//  corpus survey found them referenced by 63% of presets with any shader code at all, the single
//  biggest real-world compatibility unlock available for bounded scope).
//
//  Port of projectM's Renderer/MilkdropNoise.cpp — confirmed to be plain per-run random noise, not
//  a fixed/shipped asset (it reseeds from the current time on every run, same as this port does),
//  so there's no "reference image" to match byte-for-byte, only the generation algorithm: per-pixel
//  random RGBA, a same-row pixel shuffle pass "to improve randomness", and — for the "medium"/"high
//  quality" variants only — a two-pass (three-pass in 3D) cubic interpolation smoothing that blurs
//  the noise across blocks of `zoomFactor` texels, which is what actually distinguishes lq (sharp
//  static) from mq/hq (soft blobby noise) visually.
//

import Metal

final class MilkdropNoiseTextures {
    let noiseLq: MTLTexture
    let noiseMq: MTLTexture
    let noiseHq: MTLTexture
    let noiseVolLq: MTLTexture
    let noiseVolHq: MTLTexture

    /// `nil` only if Metal texture allocation itself fails (out of memory) — the noise generation
    /// math below never fails.
    init?(device: MTLDevice) {
        guard let noiseLq = Self.makeTexture2D(device: device, size: 256, zoomFactor: 1),
              let noiseMq = Self.makeTexture2D(device: device, size: 256, zoomFactor: 4),
              let noiseHq = Self.makeTexture2D(device: device, size: 256, zoomFactor: 8),
              let noiseVolLq = Self.makeTexture3D(device: device, size: 32, zoomFactor: 1),
              let noiseVolHq = Self.makeTexture3D(device: device, size: 32, zoomFactor: 4)
        else { return nil }
        self.noiseLq = noiseLq
        self.noiseMq = noiseMq
        self.noiseHq = noiseHq
        self.noiseVolLq = noiseVolLq
        self.noiseVolHq = noiseVolHq
    }

    /// Looks up a generated texture by MilkdropShaderTranslator's base-name catalog key (`noise_lq`,
    /// `noisevol_hq`, etc — see `MilkdropShaderTranslator.supportedNoiseTextures`).
    func texture(named baseName: String) -> MTLTexture? {
        switch baseName {
        case "noise_lq": return noiseLq
        case "noise_mq": return noiseMq
        case "noise_hq": return noiseHq
        case "noisevol_lq": return noiseVolLq
        case "noisevol_hq": return noiseVolHq
        default: return nil
        }
    }

    // MARK: - Texture creation

    private static func makeTexture2D(device: MTLDevice, size: Int, zoomFactor: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let pixels = generateNoise2D(size: size, zoomFactor: zoomFactor)
        let region = MTLRegionMake2D(0, 0, size, size)
        pixels.withUnsafeBytes { raw in
            texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        return texture
    }

    private static func makeTexture3D(device: MTLDevice, size: Int, zoomFactor: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let voxels = generateNoise3D(size: size, zoomFactor: zoomFactor)
        let region = MTLRegionMake3D(0, 0, 0, size, size, size)
        let bytesPerRow = size * 4
        voxels.withUnsafeBytes { raw in
            texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * size)
        }
        return texture
    }

    // MARK: - Noise generation (port of MilkdropNoise.cpp's generate2D/generate3D)

    /// A packed RGBA8 pixel, matching MilkdropNoise.cpp's single-`uint32_t`-per-texel approach —
    /// kept as one value per pixel (not 4 separate channel arrays) so the pixel-shuffle pass moves
    /// all four channels of a texel together, same as upstream.
    private static func randomRGBA(range: Int) -> UInt32 {
        func channel() -> UInt32 {
            UInt32(Int.random(in: 0...Int(Int32.max)) % range + range / 2)
        }
        return (channel() << 24) | (channel() << 16) | (channel() << 8) | channel()
    }

    private static func generateNoise2D(size: Int, zoomFactor: Int) -> [UInt32] {
        let range = zoomFactor > 1 ? 216 : 256
        var pixels = [UInt32](repeating: 0, count: size * size)

        for y in 0..<size {
            let rowStart = y * size
            for x in 0..<size {
                pixels[rowStart + x] = randomRGBA(range: range)
            }
            // Swap random pixel pairs within the row "to improve randomness" — matches upstream
            // exactly, including that it only shuffles within a row, not the whole image.
            for _ in 0..<size {
                let x1 = Int.random(in: 0..<size)
                let x2 = Int.random(in: 0..<size)
                pixels.swapAt(rowStart + x1, rowStart + x2)
            }
        }

        guard zoomFactor > 1 else { return pixels }

        // First pass: cubic-interpolate across X, only on rows that are multiples of zoomFactor.
        for y in stride(from: 0, to: size, by: zoomFactor) {
            for x in 0..<size where x % zoomFactor != 0 {
                let baseX = (x / zoomFactor) * zoomFactor + size
                let rowBase = y * size
                let y0 = pixels[rowBase + (baseX - zoomFactor) % size]
                let y1 = pixels[rowBase + baseX % size]
                let y2 = pixels[rowBase + (baseX + zoomFactor) % size]
                let y3 = pixels[rowBase + (baseX + zoomFactor * 2) % size]
                let t = Float(x % zoomFactor) / Float(zoomFactor)
                pixels[y * size + x] = dwCubicInterpolate(y0, y1, y2, y3, t)
            }
        }
        // Second pass: cubic-interpolate down Y, on every column now.
        for x in 0..<size {
            for y in 0..<size where y % zoomFactor != 0 {
                let baseY = (y / zoomFactor) * zoomFactor + size
                let y0 = pixels[(baseY - zoomFactor) % size * size + x]
                let y1 = pixels[baseY % size * size + x]
                let y2 = pixels[(baseY + zoomFactor) % size * size + x]
                let y3 = pixels[(baseY + zoomFactor * 2) % size * size + x]
                let t = Float(y % zoomFactor) / Float(zoomFactor)
                pixels[y * size + x] = dwCubicInterpolate(y0, y1, y2, y3, t)
            }
        }
        return pixels
    }

    private static func generateNoise3D(size: Int, zoomFactor: Int) -> [UInt32] {
        let range = zoomFactor > 1 ? 216 : 256
        var voxels = [UInt32](repeating: 0, count: size * size * size)

        for z in 0..<size {
            let sliceBase = z * size * size
            for y in 0..<size {
                let rowStart = sliceBase + y * size
                for x in 0..<size {
                    voxels[rowStart + x] = randomRGBA(range: range)
                }
                for _ in 0..<size {
                    let x1 = Int.random(in: 0..<size)
                    let x2 = Int.random(in: 0..<size)
                    voxels.swapAt(rowStart + x1, rowStart + x2)
                }
            }
        }

        guard zoomFactor > 1 else { return voxels }

        // Three smoothing passes (X, then Y, then Z) — same structure as generateNoise2D's two
        // passes, extended with a third axis; see MilkdropNoise.cpp:178-259.
        for z in stride(from: 0, to: size, by: zoomFactor) {
            for y in stride(from: 0, to: size, by: zoomFactor) {
                for x in 0..<size where x % zoomFactor != 0 {
                    let baseX = (x / zoomFactor) * zoomFactor + size
                    let base = z * size + y * size
                    let y0 = voxels[base + (baseX - zoomFactor) % size]
                    let y1 = voxels[base + baseX % size]
                    let y2 = voxels[base + (baseX + zoomFactor) % size]
                    let y3 = voxels[base + (baseX + zoomFactor * 2) % size]
                    let t = Float(x % zoomFactor) / Float(zoomFactor)
                    voxels[z * size + y * size + x] = dwCubicInterpolate(y0, y1, y2, y3, t)
                }
            }
        }
        for z in stride(from: 0, to: size, by: zoomFactor) {
            for x in 0..<size {
                for y in 0..<size where y % zoomFactor != 0 {
                    let baseY = (y / zoomFactor) * zoomFactor + size
                    let baseZ = z * size
                    let y0 = voxels[(baseY - zoomFactor) % size * size + baseZ + x]
                    let y1 = voxels[baseY % size * size + baseZ + x]
                    let y2 = voxels[(baseY + zoomFactor) % size * size + baseZ + x]
                    let y3 = voxels[(baseY + zoomFactor * 2) % size * size + baseZ + x]
                    let t = Float(y % zoomFactor) / Float(zoomFactor)
                    voxels[y * size + baseZ + x] = dwCubicInterpolate(y0, y1, y2, y3, t)
                }
            }
        }
        for x in 0..<size {
            for y in 0..<size {
                for z in 0..<size where z % zoomFactor != 0 {
                    let baseY = y * size
                    let baseZ = (z / zoomFactor) * zoomFactor + size
                    let y0 = voxels[(baseZ - zoomFactor) % size * size + baseY + x]
                    let y1 = voxels[baseZ % size * size + baseY + x]
                    let y2 = voxels[(baseZ + zoomFactor) % size * size + baseY + x]
                    let y3 = voxels[(baseZ + zoomFactor * 2) % size * size + baseY + x]
                    let t = Float(z % zoomFactor) / Float(zoomFactor)
                    voxels[z * size + baseY + x] = dwCubicInterpolate(y0, y1, y2, y3, t)
                }
            }
        }
        return voxels
    }

    // MARK: - Interpolation (port of MilkdropNoise.cpp's fCubicInterpolate/dwCubicInterpolate)

    private static func cubicInterpolate(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let a0 = y3 - y2 - y0 + y1
        let a1 = y0 - y1 - a0
        let a2 = y2 - y0
        let a3 = y1
        return a0 * t * t2 + a1 * t2 + a2 * t + a3
    }

    /// Interpolates each of the four packed 8-bit channels independently, same as upstream.
    private static func dwCubicInterpolate(_ y0: UInt32, _ y1: UInt32, _ y2: UInt32, _ y3: UInt32, _ t: Float) -> UInt32 {
        var result: UInt32 = 0
        for shift: UInt32 in [0, 8, 16, 24] {
            let channel = { (v: UInt32) in Float((v >> shift) & 0xFF) / 255.0 }
            var f = cubicInterpolate(channel(y0), channel(y1), channel(y2), channel(y3), t)
            f = min(1, max(0, f))
            result |= UInt32(f * 255) << shift
        }
        return result
    }
}
