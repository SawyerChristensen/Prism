# Prism — To Do
---
### Screen Saver Plugin
- [ ] Add a screen saver target in settings
- [ ] Have the starting screen be the only option (for now)
  - [ ] Remove the headphones and glyph from the animation and replace with an apple logo (set this as the default glyph (without headphones) in the apple music plugin too?)

### Misc
- [ ] Clean up file headers and documentation that refers to dead features or outdated informaiton. Comment out log statements
- [ ] The transition "presets" should never be viewed just by themselves. This results in a black screen. This should only be used as transitions. Make sure they are out of consideratino of the search function
- [ ] remove the transition names in the upper left and strip all profanity from being displayed in the titles
  - [ ] review questionable names

## Post Launch
---
- [x] Make the Apple Music plugin default to the built in starting animation "Geiss & Sperl - Feedback (projectM idle HDR mix).milk" if nothing is playing. Else, if something is playing, match a preset to it and display it
  - [ ] Add the preset matching algorithm to the apple music plugin
  - [ ] Add a moving album cover to the apple music plugin?
- [ ] Spotify plugin similar to Apple Music plugin? Research is it is possible to add an option under Spotify's View Menu
- [ ] Better background removal
  - [ ] Allow for background color to be shown for certain albums defined in a new v2 "Artwork Preferences"
      - [ ] Allow for disabling of text detection in this new artwork preferences. the text should just be picked up by background detail. (see Once Twice Melody)
  - [ ] If an album art is noisy, expand the breadth of the color bucket that should be taken out. See Beach House's "Depression Cherry" (not all reds removed) and Djo's "Chateau" (blue is not taken out). This requires defining what "noisy" is...
- [ ] Look for presets that make use of inputted album art, see if we can detect if a preset can input a picture and use our album art with these presets
  - [ ] Find image tiling presets if an album tiles (rare) (low priority)
- [ ] Make album art base reactivity react less to mids and more to bass hits?
- [ ] Separate audio tracks into vocals, bass, drums, etc. feed each into different sections of the visualizer. vocals into the waveform, bass/drums into the zoom/scaling
- [ ] Make own presets?
  - [ ] TonyMilkdrop - Vroom!!! [MashUp]   - that takes an input color and changes its colors to that color and nearby colors
- [ ] Expensive presets (flagged by MilkdropPresetComplexityAnalyzer — heavy tex3D/GetPixel/GetBlur1-2-3 warp/comp shaders, or high shapecode num_inst/wavecode samples × per-frame line count) are currently just skipped outright during sequential stepping/auto-cycle. Instead, render them at a reduced internal resolution and upscale to the display size, so they're still shown (just cheaper) rather than never appearing at all.
- [ ] Verify the apple music plugin works in production
- [ ] Slow down all visuals
  - [ ] Most presets take the previous frame and do some math to it so a higher frame rate (such as 120) actually speeds up all animations buy 2x. Going to 60fps does not reduce the reactivity of the audio, but it DOES decrease the speed at which the preset animates.
  - [ ] Set preferred fps to whatever the device's max refresh rate is
  - [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Some small issues with the wave transition, but they are small
