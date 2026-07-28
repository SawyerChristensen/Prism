# Prism — To Do
---
- [ ] Change the projectM starting logo when the app first starts up
- [ ] Is there a way we can combine the album subject with the preset? right now just floats above the preset. we isolate the subject in the album, but other than that we dont blend it with the visualizer at all. what are the options for blending it in?
  - [ ] When a new song is chosen, lets transition into the album art, display it for a couple seconds and then let it blend with the preset once we decide how ^
  - [ ] transition in the text on the bottom right and left, maybe make it the inverse of whatever is behind it? so that it is always visible? if the preset is black, the text should be white. if the preset is white, it should be black, if the preset is red, it should be the opposite of red etc.
- [ ] The bar at the top of the window is set to white. is there a way we can extend what the gpu displays into that bar or get rid of the bar altogether? the red yellow and green buttons should still be there but the white bar is just a little annoying
- [ ] Bundle the external preset back with the xcode project so the entire app can actually be exported and work
- [ ] Expensive presets (flagged by MilkdropPresetComplexityAnalyzer — heavy tex3D/GetPixel-neighbor-sample warp/comp shaders, the kind that render at ~3fps) are currently just skipped outright during sequential stepping/auto-cycle. Instead, render them at a reduced internal resolution and upscale to the display size, so they're still shown (just cheaper) rather than never appearing at all.
  - [ ] Set them to render, just at a lower resolution so that they still render at a higher frame rate. Requries fine tuning
