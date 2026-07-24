//
//  AlbumColors.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import AppKit

extension NSImage {
    /// Extracts a dominant background color and a contrasting foreground color. Pure pixel
    /// crunching, no UI state — `nonisolated` so callers can run it off the main actor (it's
    /// called from a background task after each artwork fetch).
    nonisolated func extractColors() -> (background: NSColor, foreground: NSColor)? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let size = 20
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(data: &pixelData, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        
        var colorCounts: [Int: Int] = [:]
        var colorsByHash: [Int: NSColor] = [:]
        
        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = pixelData[i]
            let g = pixelData[i+1]
            let b = pixelData[i+2]
            let a = pixelData[i+3]
            
            guard a > 0 else { continue } // Ignore transparent pixels
            
            // Group similar colors together
            let hash = (Int(r) / 16 << 16) | (Int(g) / 16 << 8) | (Int(b) / 16)
            
            colorCounts[hash, default: 0] += 1
            if colorsByHash[hash] == nil {
                colorsByHash[hash] = NSColor(red: CGFloat(r)/255.0, green: CGFloat(g)/255.0, blue: CGFloat(b)/255.0, alpha: 1.0)
            }
        }
        
        let sortedHashes = colorCounts.sorted { $0.value > $1.value }.map { $0.key }
        guard !sortedHashes.isEmpty, let dominantHash = sortedHashes.first, let background = colorsByHash[dominantHash] else { return nil }
        
        var foreground: NSColor? = nil
        for hash in sortedHashes.dropFirst() {
            guard let candidate = colorsByHash[hash] else { continue }
            if background.hasSufficientContrast(with: candidate) {
                foreground = candidate
                break
            }
        }
        
        if foreground == nil {
            foreground = background.isDark ? .white : .black
        }
        
        return (background, foreground!)
    }
}

extension NSColor {
    nonisolated var luminance: CGFloat {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 0.5 }
        let r = rgb.redComponent <= 0.03928 ? rgb.redComponent / 12.92 : pow((rgb.redComponent + 0.055) / 1.055, 2.4)
        let g = rgb.greenComponent <= 0.03928 ? rgb.greenComponent / 12.92 : pow((rgb.greenComponent + 0.055) / 1.055, 2.4)
        let b = rgb.blueComponent <= 0.03928 ? rgb.blueComponent / 12.92 : pow((rgb.blueComponent + 0.055) / 1.055, 2.4)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    nonisolated var isDark: Bool {
        return luminance < 0.5
    }

    nonisolated func hasSufficientContrast(with color: NSColor) -> Bool {
        let l1 = max(self.luminance, color.luminance)
        let l2 = min(self.luminance, color.luminance)
        let ratio = (l1 + 0.05) / (l2 + 0.05)
        return ratio > 2.0
    }
}
