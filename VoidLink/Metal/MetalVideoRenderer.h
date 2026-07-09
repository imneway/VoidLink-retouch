//
//  MetalVideoRenderer.h
//
//  Created by Andy Grundman.
//  Ported to VoidLink by Acaki.
//  Copyright (c) 2025 Moonlight Stream. All rights reserved.
//

#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import "ConnectionCallbacks.h"
#import "Frame.h"
#import "Plot.h"
#import "TemporarySettings.h"

@interface MetalVideoRenderer : NSObject

@property (atomic) CFTimeInterval averageGPUTime;
@property (nonatomic) NSUInteger sampleCount;
@property (nonatomic) MTLPixelFormat colorPixelFormat;
@property (nonatomic) CFTimeInterval lastPresented;
@property (nonatomic) id<CAMetalDrawable> _Nullable nextDrawable;
@property (atomic) BOOL isStopping;
@property (nonatomic) BOOL hdrEnabled;

- (instancetype _Nonnull )initWithMetalDevice:(id<MTLDevice>_Nonnull)device drawablePixelFormat:(MTLPixelFormat)drawablePixelFormat settings:(TemporarySettings* _Nonnull )currentSettings;


- (void)renderFrame:(nonnull Frame *)frame toLayer:(nonnull CAMetalLayer *)layer;
// Returns NO when no in-flight frame slot was acquired (stopping, or the
// semaphore wait timed out — e.g. GPU stalled in background). Callers must
// skip renderFrame: for this pass, otherwise the completion handler's
// signal permanently inflates the semaphore and breaks pacing.
- (BOOL)waitToRenderTo:(nonnull CAMetalLayer *)layer API_AVAILABLE(ios(13.0));
- (void)drawableResize:(CGSize)drawableSize;
// Makes the render loop bail out; safe from any thread, any time.
- (void)requestStop;
// Full teardown including GPU resources the render loop touches — only call
// after the render thread has been joined.
- (void)shutdown;

+ (NSString *_Nullable)currentColorSpace;

@end
