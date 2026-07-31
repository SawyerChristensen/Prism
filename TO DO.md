# Prism — To Do
---
- [x] Tell the system that this application can open milk files if milk files are double clicked on
- [x] Milk file icons
- [ ] Tell Apple Music this app is a visualizer extension under Window > Visualizer/Visualizer Settings
- [ ] Wait for the user to press enter/return to go past the starting screen
- [ ] Better album overlays
  - [ ] Different layers of the album should be on different layers of the visualizer
  - [ ] Look for presets that make use of inputted album art, see if we can detect if a preset can input a picture and use our album art with these presets
- [ ] Make own presets?
- [ ] Slow down all visuals
  - [ ] Most presets take the previous frame and do some math to it so a higher frame rate (such as 120) actually speeds up all animations buy 2x. Going to 60fps does not reduce the reactivity of the audio, but it DOES decrease the speed at which the preset animates.
  - [ ] Set preferred fps to whatever the device's max refresh rate is
  - [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Find a good collection of presets to ship, and make sure they are all sufficiently "chilled out"

## Post Launch
---
- [ ] Expensive presets (flagged by MilkdropPresetComplexityAnalyzer — heavy tex3D/GetPixel-neighbor-sample warp/comp shaders, the kind that render at ~3fps) are currently just skipped outright during sequential stepping/auto-cycle. Instead, render them at a reduced internal resolution and upscale to the display size, so they're still shown (just cheaper) rather than never appearing at all.
  - [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Add mutliple album art transition outs when the song ends
- [ ] Figure out a solution to centering the subject of the album
