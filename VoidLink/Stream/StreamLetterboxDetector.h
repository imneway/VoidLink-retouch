//
//  StreamLetterboxDetector.h
//  VoidLink
//
//  Classifies the decoded video as "game" or "desktop" by looking for
//  letterbox bars baked into the host's frames. On a host display that matches
//  the iPad's aspect ratio, a borderless-fullscreen 16:9 game gets padded with
//  black bars by Windows, while the desktop fills the whole display. The host
//  VC uses the verdict to decide what "hide the OSC" means (translucent but
//  tappable for games, fully off so touch becomes the mouse on the desktop).
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

typedef NS_ENUM(NSInteger, StreamContentClass) {
    StreamContentClassUnknown = 0,
    StreamContentClassDesktop,
    StreamContentClassGame,
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
@end

@interface StreamLetterboxDetector : NSObject

@property (weak, nonatomic) id<StreamLetterboxDetectorDelegate> delegate;
// Off by default. While disabled analyzePixelBuffer: is a no-op and the
// current class stays Unknown.
@property (atomic, assign) BOOL enabled;
@property (atomic, readonly) StreamContentClass currentContentClass;
@property (atomic, readonly) BOOL currentFitsSixteenNine;

// Call from the decoder's output path with every decoded frame; it samples at
// most every 0.5 s and returns immediately otherwise. Safe on any thread.
- (void)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer;

// Forget the current verdict and debounce history (new stream / resize).
- (void)reset;

@end
