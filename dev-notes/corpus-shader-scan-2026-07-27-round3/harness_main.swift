import Foundation
import Metal

let root = "/Users/sawyerchristensen/Desktop/BestMilkdropPresetsPack/Presets"
let fm = FileManager.default
guard let enumerator = fm.enumerator(atPath: root) else {
    print("Could not enumerate \(root)")
    exit(1)
}
var files: [String] = []
for case let path as String in enumerator {
    if path.lowercased().hasSuffix(".milk") {
        files.append(root + "/" + path)
    }
}
print("Found \(files.count) preset files")

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device")
    exit(1)
}

var parseFailCount = 0
var warpNone = 0, warpTranslateFail = 0, warpCompileFail = 0, warpOK = 0
var compNone = 0, compTranslateFail = 0, compCompileFail = 0, compOK = 0

// First line of each distinct compile error, with one example file, capped in count.
var errorSignatures: [String: (count: Int, example: String)] = [:]

func firstErrorLine(_ message: String) -> String {
    // Take the first "error:" line, stripped of exact line/col numbers so similar errors group.
    guard let range = message.range(of: "error:") else { return String(message.prefix(80)) }
    let rest = message[range.lowerBound...]
    let line = rest.split(separator: "\n").first.map(String.init) ?? String(rest.prefix(120))
    return line
}

var processed = 0
let startTime = Date()

for path in files {
    processed += 1
    if processed % 1000 == 0 {
        let elapsed = Date().timeIntervalSince(startTime)
        print("... \(processed)/\(files.count) (\(Int(elapsed))s elapsed)")
    }

    let url = URL(fileURLWithPath: path)
    guard let file = try? MilkdropPresetFile(contentsOf: url) else {
        parseFailCount += 1
        continue
    }

    // warp_N=
    if file.warpShaderSource.isEmpty {
        warpNone += 1
    } else if let translated = MilkdropShaderTranslator.translate(file.warpShaderSource) {
        let src = MilkdropMetalRenderer.buildWarpShaderSource(translated)
        do {
            _ = try device.makeLibrary(source: src, options: nil)
            warpOK += 1
        } catch {
            warpCompileFail += 1
            let sig = firstErrorLine("\(error)")
            if let existing = errorSignatures[sig] {
                errorSignatures[sig] = (existing.count + 1, existing.example)
            } else {
                errorSignatures[sig] = (1, url.lastPathComponent + " [warp]")
            }
        }
    } else {
        warpTranslateFail += 1
    }

    // comp_N=
    if file.compositeShaderSource.isEmpty {
        compNone += 1
    } else if let translated = MilkdropShaderTranslator.translate(file.compositeShaderSource) {
        let src = MilkdropMetalRenderer.buildCompositeShaderSource(translated)
        do {
            _ = try device.makeLibrary(source: src, options: nil)
            compOK += 1
        } catch {
            compCompileFail += 1
            let sig = firstErrorLine("\(error)")
            if let existing = errorSignatures[sig] {
                errorSignatures[sig] = (existing.count + 1, existing.example)
            } else {
                errorSignatures[sig] = (1, url.lastPathComponent + " [comp]")
            }
        }
    } else {
        compTranslateFail += 1
    }
}

let totalTime = Date().timeIntervalSince(startTime)
print("\n=== SUMMARY (over \(files.count) files, \(Int(totalTime))s) ===")
print("Parse failures: \(parseFailCount)")
print()
let warpTotal = warpNone + warpTranslateFail + warpCompileFail + warpOK
print("warp_N=: none=\(warpNone) translateFail=\(warpTranslateFail) compileFail=\(warpCompileFail) OK=\(warpOK)")
let warpHasCode = warpTranslateFail + warpCompileFail + warpOK
if warpHasCode > 0 {
    print("  compile success rate among files WITH warp_N=: \(Double(warpOK) / Double(warpHasCode) * 100)%")
}
print()
let compTotal = compNone + compTranslateFail + compCompileFail + compOK
print("comp_N=: none=\(compNone) translateFail=\(compTranslateFail) compileFail=\(compCompileFail) OK=\(compOK)")
let compHasCode = compTranslateFail + compCompileFail + compOK
if compHasCode > 0 {
    print("  compile success rate among files WITH comp_N=: \(Double(compOK) / Double(compHasCode) * 100)%")
}

print("\n=== TOP ERROR SIGNATURES ===")
let sorted = errorSignatures.sorted { $0.value.count > $1.value.count }
for (sig, info) in sorted.prefix(30) {
    print("[\(info.count)x] \(sig)  (e.g. \(info.example))")
}
