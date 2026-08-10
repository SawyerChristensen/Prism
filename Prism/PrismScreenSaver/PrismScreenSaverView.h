//
//  PrismScreenSaverView.h
//  PrismScreenSaver
//
//  The macOS Screen Saver-facing half of the visualizer: a ScreenSaverView subclass that hosts
//  a ProjectMEngine + PrismItunesVisualizer (both reused as-is from PrismVisualizerPlugin - see
//  those files' own doc comments) showing only Prism's built-in idle animation ("Geiss & Sperl -
//  Feedback (projectM idle HDR mix).milk"), with the idle preset's shapecode_0 glyph swapped for
//  an Apple logo instead of Prism's own headphones logo - same -setTextureOverrideImage:forName:
//  technique PrismVisualizerPlugin.mm uses for its Apple Music glyph, see
//  PrismScreenSaverView.mm's kPrismScreenSaverIdlePresetText. No audio capture of any kind (the
//  idle preset is designed to look complete without it, and a screen saver process has no
//  business requesting Screen Recording/audio permissions of its own).
//

#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

@interface PrismScreenSaverView : ScreenSaverView

@end

NS_ASSUME_NONNULL_END
