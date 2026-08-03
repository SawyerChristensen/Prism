//
//  MilkdropPresetVisualTraitsStore.swift
//  Prism
//
//  Loads Resources/PresetVisualTraits.json (see Scripts/generate_preset_visual_traits.sh) once at
//  launch and answers every later lookup out of memory — the whole point of precomputing the
//  corpus ahead of time instead of having ContentView re-run
//  MilkdropPresetVisualTraitsAnalyzer/re-read thousands of .milk files on every track change. Keyed
//  by filename (matching MilkdropNestDropFavoritesList.presetFilenames' existing "filenames are
//  unique across the whole corpus" assumption — reverified when generating the JSON: zero
//  collisions across all 9,795 shipped presets), so lookups work the same whether `presetLibrary`
//  is pointed at the app's bundled Presets folder or a user-picked external one, as long as it's
//  (a copy of) the same underlying pack. A preset the index has no entry for (a completely
//  different personal library, or one added after the index was last generated) just can't
//  contribute a scored candidate — SongPresetMatcher.rank only ever sees pairs this store actually
//  resolved, never a fabricated placeholder.
//

import Foundation

@Observable
final class MilkdropPresetVisualTraitsStore {
    private var traitsByFilename: [String: MilkdropPresetVisualTraits] = [:]

    init() {
        guard let url = Bundle.main.url(forResource: "PresetVisualTraits", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MilkdropPresetVisualTraits].self, from: data) else {
            return
        }
        traitsByFilename = decoded
    }

    func traits(for url: URL) -> MilkdropPresetVisualTraits? {
        traitsByFilename[url.lastPathComponent]
    }

    /// Pairs every preset in `urls` with its precomputed traits, silently dropping any this store
    /// has no entry for (see this file's own doc comment on why that's the right degradation
    /// rather than an error).
    func pairs(for urls: [URL]) -> [(url: URL, traits: MilkdropPresetVisualTraits)] {
        urls.compactMap { url in traits(for: url).map { (url, $0) } }
    }
}
