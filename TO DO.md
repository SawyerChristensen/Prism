# Prism — To Do
---
- [x] Album art transitions
  - [x] When a new song is chosen, lets transition into the album art, display it for a couple seconds and then let it blend with the preset once we decide how ^
  - [x] Scale up transition
  - [x] Scale down transition
  - [x] Slide in from the right, pushing the other art to the left while it dissolves
  - [x] Slide in from the top, pushing the other art out to the buttom while it dissolves
- [x] Transition in the text on the bottom right and left. the text should settle at the same moment the subject becomes settled and the background start fading out. only transition both texts if the song and artist are changing. if just the song is changing but the artist stays the same, only transition the song text away
- [x] Make the text the inverse of what is behind it. maybe a text-sized mask/inverse filter on the content? if the preset is black, the text should be white. if the preset is white, it should be black, if the preset is red, it should be the opposite of red etc. 
- [x] Speed up all transitions once fully implemented
- [x] The bar at the top of the window is set to white. is there a way we can extend what the gpu displays into that bar or get rid of the bar altogether? the red yellow and green buttons should still be there but the white bar is just a little annoying
- [x] Deprecate the m, t and p keys for changing the art. comment them out for now! maybe revist later. right now they should do nothing. text still shows up on the screen for a deprecated function
- [x] Add options in the view settings for hiding the album art and hiding the text
- [x] Allow importing of milk files in the file menu. when a milk file is imported, it should display that milk file until the user starts cycling through again or until the application closes. Next time its opened, it should start cycling through again as default behavior
- [x] Space should pause whatever music is playing
- [x] Change the projectM starting logo when the app first starts up
- [ ] Add a "History" Menu bar tab where past presets in this session show up, above a "Last Session >" tab that shows the presets used last session
- [ ] Slow down all animations. keep the framerate high, and the app just as responsive to audio as it was before, but right now its just way too fast and spazzy. mellow everything out. is there an intensity/reactivity slider? if a bass hits there graphic should still change, the change just shouldnt be as crazy wild as it is now. things should gradually change but still sync to the music.
  - [ ] Add an increase/decrease intensity toggle in the "View" menu bar settings?
- [ ] Bundle the external preset back with the xcode project so the entire app can actually be exported and work
- [ ] Expensive presets (flagged by MilkdropPresetComplexityAnalyzer — heavy tex3D/GetPixel-neighbor-sample warp/comp shaders, the kind that render at ~3fps) are currently just skipped outright during sequential stepping/auto-cycle. Instead, render them at a reduced internal resolution and upscale to the display size, so they're still shown (just cheaper) rather than never appearing at all.
  - [ ] Set them to render, just at a lower resolution so that they still render at a higher frame rate. Requries fine tuning
- [ ] Find a good collection of presets to ship, and make sure they are all sufficiently "chilled out"


## Post Launch
---
- [ ] Add mutliple album art transition outs when the song ends
- [ ] Figure out a solution to centering the subject of the album
