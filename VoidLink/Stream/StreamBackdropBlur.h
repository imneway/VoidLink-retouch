//
//  StreamBackdropBlur.h
//  VoidLink
//
//  Low-rate stand-in for UIVisualEffectView behind the bottom chrome capsules.
//  A system blur sits over a video layer that changes every frame, so the
//  render server re-blurs at the display refresh rate. What sits behind the
//  capsules is nearly static (the host taskbar, or black letterbox bars), so
//  this samples the decoded frame about once a second instead: it box-averages
//  the region behind each capsule down to a handful of pixels, blurs that tiny
//  image on a background queue and hands back a CGImage the capsule layer
//  stretches with linear filtering. Unchanged output is not re-delivered.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

enum { StreamBackdropBlurMaxSlots = 4 };

@interface StreamBackdropBlur : NSObject

// Off by default; while off, offerPixelBuffer: is a cheap no-op.
@property (atomic, assign) BOOL enabled;

// Main queue. image is NULL when the slot produced nothing usable. The image
// covers exactly the slot's capsule rect (the blur margin is cropped off).
@property (nonatomic, copy, nullable) void (^imageHandler)(NSUInteger slot, CGImageRef _Nullable image);

// Main queue. normalizedRect is the capsule rect in frame coordinates
// (0...1, origin top-left), CGRectNull to stop sampling the slot.
// pointSize is the capsule's size on screen; the output has one pixel per
// kStreamBackdropPointsPerPixel points, plus a blur margin that is sampled
// from around the capsule and cropped away again.
- (void)setSlot:(NSUInteger)slot normalizedRect:(CGRect)normalizedRect pointSize:(CGSize)pointSize;

// Any thread, typically the decoder output. Throttled to about 1 Hz (sooner
// right after a region change); the analysis runs on a utility queue.
- (void)offerPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
