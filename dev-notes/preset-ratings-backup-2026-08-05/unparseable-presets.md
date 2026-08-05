# 13 presets that fail to parse in generate_preset_visual_traits.sh

Confirmed pre-existing: none of these were present in the old (pre-rename) PresetVisualTraits.json
under their original filenames either, so this isn't a rename regression.

| Old (raw) filename | New (ProductionMilkdropCorpus) filename |
|---|---|
| `LuxXx - the first beat-tube.milk` | `LuxXx - Liquid Blobby Reaction 2.milk` |
| `LuxXx - gaseous disconuggets.milk` | `LuxXx - Liquid Simmering Reaction 9.milk` |
| `LuxXx - ColourSturm I.milk` | `LuxXx - Liquid Simmering Reaction 2.milk` |
| `The NG + Flexi + BDRV - Ultramix, Aderrasi + Flexi - Predator Prey Spirals, Flexi - Jellyfish Jam.milk` | `The NG + flexi + bdrv - Liquid Ripples Reaction.milk` |
| `Hexcollie, Aderassi, BDRV, AdamFX n Flexi - It's a start.milk` | `Hexcollie, Aderassi, BDRV, AdamFX n Flexi - Polar Rolling Hypnotic.milk` |
| `LuxXx - chillin wid my homiez i.milk` | `LuxXx - Nested Spiral Multiple Fractal.milk` |
| `A Milk Art Detail 2 flexi - moebius transformation ft Martin With AdamFX A.milk` | `A Milk Art Detail 2 flexi - Loops Fractal.milk` |
| `drugsincombat - keepthesignal (cranked).milk` | `drugsincombat - Wire Flat Waveform.milk` |
| `LuxXx - Daily Data Commute (aut lane).milk` | `LuxXx - Infect Dancer 6.milk` |
| `LuxXx - Daily Data Commute to Werk I.milk` | `LuxXx - Infect Dancer 7.milk` |
| `LuxXx - Daily Data Commute to Werk II b.milk` | `LuxXx - Infect Dancer 8.milk` |
| `LuxXx - Daily Data Commute to Werk II.milk` | `LuxXx - Infect Dancer 9.milk` |
| `LuxXx - Play v2.milk` | `LuxXx - Glimmer Sparkle 3.milk` |

These presets load and render fine in the app — the failure is specific to the traits analyzer
(`MilkdropPresetVisualTraitsAnalyzer`/`generate_preset_visual_traits.swift.txt`), so they just never
get precomputed traits and are silently excluded from song-preset matching candidates.
