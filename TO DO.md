# Prism — To Do
---
### Album overlays
  - [x] Different layers of the album should be on different layers of the visualizer
  - [x] Improve chromatic aberation
  - [x] Improve the test mask! Sometimes theres artifcats around the edges not connected to the text (see Once Twice Melody)
  - [ ] Make album art base reactivity react less to mids and more to bass?
  - [x] Default background color to nil, 
    - [ ] ^ Allow for certain albums defined in a new v2 "Artwork Preferences"
      - [ ] Allow for disabling of text detection in this new artwork preferences. the text should just be picked up by background detail. (see Once Twice Melody)
  - [ ] If an album art is noisy, expand the breadth of the color bucket that should be taken out. See Beach House's "Depression Cherry" (not all reds removed) and Djo's "Chateau" (blue is not taken out). This requires defining what "noisy" is...
### Transitions
  - [x] Album art frames limits how much they can warp. There is a frame around every album that clips the edges. They should have no frame
    - [ ] Fixed for wave & circle. Review if other transitions should exceed their bounds (havent seen any)
  - [ ] The intro preset does not transition well into the first song once it is played. the first song simply flashes in. we should always wait until we have the next album art retrieved to initiate a transition into the next preset. this goes for the intro preset on application start transitioning into the first preset and for every other transition in between songs.
  - [ ] Some transitions seem to have no effect and instantly despawn/spawn to the next one
    - [ ] The expanding circle transition seem to do this sometimes^
  - [x] Remove dead AlbumArtIntroStyle code (ProjectMCoordinator.swift) — the forward/reverseScale/slideRight/slideDown intro system is fully disabled ("Album transition code temporarily disabled" blocks) and no longer wired into the shader at all.

### Song-Preset Matching
- [ ] Test what audio brainz actually returns. Set up API retrieval and print values for now so we can move on to the preset grading/matching mechanism
- [ ] Add a grading mechanism for matching presets with songs
  - [ ] Overall quality (1-5)
  - [ ] Basic color registering (default to nil) (only entered if theres a prominent color "red" "brown" in the preset)
  - [ ] Song Valence -> Preset color amount
  - [ ] Song Energy -> Preset screen presence: "amount on screen"
  - [ ] Song Danceability -> Preset responsiveness
  - [ ] Acousticness -> Vibe?
- [ ] Build a search function that looks at each of those traits ^ with different levels of importance acousticness might not be as important as song energy to preset selection

### Apple Music Plugin
- [x] Tell Apple Music this app is a visualizer extension under Window > Visualizer Settings
- [x] Ship/point at real `.milk` presets — falls back to scanning `~/Documents/PrismCollection/BestMilkdropPresetsPack/Presets` (same source Prism.app's own bundling script uses) when the plugin's own bundled `Presets/` folder is empty
  - [ ] Make sure this works with whatever the actual app ships with. (it wont be some external folder)
- [x] Change a preset every song — wired `kVisualPluginChangeTrackMessage` to pick a new random preset (smooth crossfade)
  - [ ] Reevaluate with the new album art transitioning framework above 

### Screen Saver Plugin
- [ ] Add a screen saver target in settings
- [ ] Have the starting screen be the only option (for now)
  - [ ] Remove the headphones and glyph from the animation and replace with an apple logo (set this as the default glyph (without headphones) in the apple music plugin too?)

### Misc
- [ ] Fix ProjectMCoordinator's "10 diganostic issues"?
- [ ] The starting screen should only display if there is nothing playing already. if a song is playing and the app opens, the starting screen should be skipped entirely and never display. while the app is opening (bobbing in dock), it should get the song thats playing, do the album photo ops, match it to a preset, and then start displaying everything immediately when the first window appears. This should also work for the Apple Music plugin. If there is nothing playing in apple music, display the starting screen. if there is something playing, immediately move to display the album art and a matching preset.


## Post Launch
---
- [ ] Look for presets that make use of inputted album art, see if we can detect if a preset can input a picture and use our album art with these presets
  - [ ] Find image tiling presets if an album tiles (rare) (low priority)
- [ ] Separate audio tracks into vocals, bass, drums, etc. feed each into different sections of the visualizer. vocals into the waveform, bass/drums into the zoom/scaling
- [ ] Make own presets?
  - [ ] TonyMilkdrop - Vroom!!! [MashUp]   - that takes an input color and changes its colors to that color and nearby colors
- [ ] Expensive presets (flagged by MilkdropPresetComplexityAnalyzer — heavy tex3D/GetPixel-neighbor-sample warp/comp shaders, the kind that render at ~3fps) are currently just skipped outright during sequential stepping/auto-cycle. Instead, render them at a reduced internal resolution and upscale to the display size, so they're still shown (just cheaper) rather than never appearing at all.
  - [ ] ...or optimize the engine so that there are no presets expensive enough that we cannot run them
- [ ] Verify the apple music plugin works in production
- [ ] Slow down all visuals
  - [ ] Most presets take the previous frame and do some math to it so a higher frame rate (such as 120) actually speeds up all animations buy 2x. Going to 60fps does not reduce the reactivity of the audio, but it DOES decrease the speed at which the preset animates.
  - [ ] Set preferred fps to whatever the device's max refresh rate is
  - [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Some small issues with the wave transition, but they are small
