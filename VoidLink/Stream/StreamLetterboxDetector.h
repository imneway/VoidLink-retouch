//
//  StreamLetterboxDetector.h
//  VoidLink
//
//  Classifies the decoded video as "game", "desktop" or "ambiguous" by looking
//  for letterbox bars baked into the host's frames, and for the Windows
//  taskbar along the bottom edge. On a host display that matches the iPad's
//  aspect ratio, a borderless-fullscreen 16:9 game gets padded with black bars
//  by Windows, while the desktop fills the whole display with the taskbar
//  showing. Content with neither (a game that fills the display, a fullscreen
//  window) is ambiguous. The host VC uses the verdict to decide what "hide the
//  OSC" means (translucent but tappable for games, fully off so touch becomes
//  the mouse otherwise) and treats only a taskbar-confirmed desktop as a real
//  change of scene that may override the user's manual OSC choices.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

typedef NS_ENUM(NSInteger, StreamContentClass) {
    StreamContentClassUnknown = 0,
    StreamContentClassDesktop,      // no bars, Windows taskbar seen at the bottom
    StreamContentClassGame,         // letterbox bars
    StreamContentClassAmbiguous,    // no bars, no taskbar
};

@class StreamLetterboxDetector;

@protocol StreamLetterboxDetectorDelegate <NSObject>
// Delivered on the main queue whenever the debounced (contentClass, fits16x9)
// pair changes. fitsSixteenNine is YES when the content sits inside the
// centred 16:9 region of the frame (its top/bottom bars are at least as tall
// as a 16:9 letterbox would be, within a small slack), so the view can snap
// that region to the top edge without clipping anything. Always NO when the
// class is not Game.
- (void)letterboxDetector:(StreamLetterboxDetector *)detector
    didChangeContentClass:(StreamContentClass)contentClass
          fitsSixteenNine:(BOOL)fitsSixteenNine;
@optional
// Main queue. The area a 16:9 letterbox would leave black (top and bottom)
// has carried substantial content for a sustained stretch that began at
// `since` (CACurrentMediaTime). Fired once per uninterrupted stretch: proof
// that whatever is on screen draws over the whole display, which a 16:9 game
// never does. The caller decides whether the content was a game.
- (void)letterboxDetector:(StreamLetterboxDetector *)detector didSeeContentInBarsSince:(CFTimeInterval)since;
@end

@interface StreamLetterboxDetector : NSObject

@property (weak, nonatomic) id<StreamLetterboxDetectorDelegate> delegate;
// Off by default. While disabled analyzePixelBuffer: is a no-op and the
// current class stays Unknown.
@property (atomic, assign) BOOL enabled;
@property (atomic, readonly) StreamContentClass currentContentClass;
@property (atomic, readonly) BOOL currentFitsSixteenNine;

// Call from the decoder's output path with every decoded frame. At most one
// frame per 0.2 s is retained and analysed on a background queue; every other
// call returns after a cheap throttle check. Safe on any thread.
- (void)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer;

// Forget the current verdict and debounce history (new stream / resize).
- (void)reset;

// Measure the current bar-content stretch (if any) from now on and report it
// again once it has lasted long enough. For a delegate that had to reject a
// report (the game had just changed) and wants fresh evidence.
- (void)restartBarContentStretch;

@end
