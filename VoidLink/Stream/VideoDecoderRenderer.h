//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"
#import "FrameQueue.h"
#import "Plot.h"
#import "StreamLetterboxDetector.h"
#import "StreamBackdropBlur.h"

#include "Limelight.h"

@interface VideoDecoderRenderer : NSObject

@property (atomic, readonly) PlotMetrics decodeMetrics;
@property (atomic, readonly) PlotMetrics frameQueueMetrics;

@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *displayLayer;
// Game / desktop classifier fed with every decoded frame (both backends). The
// host VC enables it and listens as its delegate; disabled it costs nothing.
@property (nonatomic, strong, readonly) StreamLetterboxDetector *letterboxDetector;
// ~1 Hz blurred samples of the frame behind the bottom chrome capsules. Same
// feed as the detector; disabled it costs nothing.
@property (nonatomic, strong, readonly) StreamBackdropBlur *backdropBlur;
// NO when frames go straight to the display layer undecoded (AVSB backend with
// Legacy / Off frame pacing): the detector never sees a pixel buffer then.
@property (nonatomic, readonly) BOOL providesDecodedFrames;
// Aspect ratio of the frames actually being decoded; follows host resolution
// changes (StreamAspectRatioChanged), unlike the configured stream size.
@property (nonatomic, readonly) float streamAspectRatio;

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)renderFrame:(Frame *)frame atTime:(CMTime)targetTime;
- (void)cleanup;
- (void)setHdrMode:(BOOL)enabled;
- (void)safeCopyMetricsTo:(PlotMetrics *)dst from:(PlotMetrics *)src;
- (void)getAllStats:(video_stats_t *)stats;
- (void)optimizeRefreshRate;
- (void)resetFramePacing;

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
               decodeUnit:(PDECODE_UNIT)du
          decodeStartTime:(CFTimeInterval)decodeStartTime;

- (OSStatus)decodeFrameWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            frameNumber:(int)frameNumber
                              frameType:(int)frameType
                        decodeStartTime:(CFTimeInterval)decodeStartTime;

// Removed from implementation; keep header clean

@end
