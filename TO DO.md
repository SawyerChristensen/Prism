# Prism — To Do
---
## **Update 1.2** *- More/Better Presets*
- [ ] 3rd App Icon: Dynamically changes to the album currently being played
- [ ] Better background removal
  - [ ] Allow for disabling of text detection in a new artwork preferences file. the text should instead be picked up by background detail. (see Once Twice Melody)
  - [ ] If an album art is noisy, expand the breadth of the color bucket that should be taken out. See Beach House's "Depression Cherry" (not all reds removed) and Djo's "Chateau" (blue is not taken out). This requires defining what "noisy" is.
- [ ] Look for presets that make use of inputted album art, see if we can detect if a preset can input a picture and use our album art with these presets
  - [ ] Find image tiling presets if an album tiles (rare) (low priority) (Pool of Swim, Teenage Dirtbag)
- [ ] Sell album-specific presets
  - [ ] All Star Wars albums - a modified "fishbrain radiate supernova 3" with rays color coded for each album
  - [ ] Beach House specific ones
- [ ] Sell Prism+ which includes all album-specific presets now and forever as well as a dynamic app icon that updates the app icon to the currently playing album cover
- [ ] 13 presets fail to parse in Scripts/generate_preset_visual_traits.sh ("couldn't read ... — skipping") and so have no PresetVisualTraits.json entry / never participate in song-preset matching. Pre-existing in the raw NestDrop pack, not caused by the ProductionMilkdropCorpus rename (confirmed absent from the old traits.json too, under their original filenames). All 13 are LuxXx/The NG+Flexi+BDRV/Hexcollie.../A Milk Art Detail/drugsincombat presets — see dev-notes/preset-ratings-backup-2026-08-05 conversation notes for the full old→new filename list. Worth investigating why these specific files don't parse (corrupt/unusual encoding?).
  - [ ] Review corpus for other presets that didnt compile/got skipped in the performance check and correct the .milk files themselves
- [ ] Better App Store Listing
  - [ ] Preview Video
  - [ ] Full carousel of preview images

## **Update 1.3** *- More Platforms*
- [ ] tvOS?
- [ ] iOS?
- [ ] iPadOS?
- [ ] visionOS??

## Misc
---
- [ ] Make presets match to color (requires adding a dominant color(s) field to the preset traits/matching algorithm)
  - [ ] TonyMilkdrop - Vroom!!! [MashUp]   - that takes an input color and changes its colors to that color and nearby colorsSeparate audio tracks into vocals, bass, drums, etc. feed each into different sections of the visualizer. vocals into the waveform, bass/drums into the zoom/scaling
  - [ ] Make album art base reactivity react less to mids and more to bass hits?
- [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Add a thumbnail for the prism screen saver in macOS settings
- [ ] Increase speed of preset matching by combining the rating and visual traits json
- [ ] Add the preset matching algorithm to the apple music plugin (later — real lift, not a quick wire-up)
  - [ ] Add Swift compilation to the PrismVisualizerPlugin target (currently ObjC++ only, zero Swift files) or port SongPresetMatcher's scoring logic to C++/ObjC++
  - [ ] Share PresetVisualTraits.json + PresetRatings.json with the plugin (e.g. App Group container) instead of the plugin having no access to them
  - [ ] Fix the plugin's preset library path (currently its own bundle or hardcoded ~/Documents/PrismCollection fallback) to match the app's actual configured library so filenames line up with the traits JSON
  - [ ] Add async ReccoBeats network lookup in the plugin without blocking Music.app's render callback thread
  - [ ] Add a moving album cover to the apple music plugin? How would layers work?
