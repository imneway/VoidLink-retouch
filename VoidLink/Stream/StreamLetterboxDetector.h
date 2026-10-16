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
// Delivered on the main queue, only when the debounced verdict changes.
- (void)letterboxDetector:(StreamLetterboxDetector *)detector didChangeContentClass:(StreamContentClass)contentClass;
@end

@interface StreamLetterboxDetector : NSObject

@property (weak, nonatomic) id<StreamLetterboxDetectorDelegate> delegate;
// Off by default. While disabled analyzePixelBuffer: is a no-op and the
// current class stays Unknown.
@property (atomic, assign) BOOL enabled;
@property (atomic, readonly) StreamContentClass currentContentClass;

// Call from the decoder's output path with every decoded frame; it samples at
// most every 0.5 s and returns immediately otherwise. Safe on any thread.
- (void)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer;

// Forget the current verdict and debounce history (new stream / resize).
- (void)reset;

@end
