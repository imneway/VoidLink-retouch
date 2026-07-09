//
//  MetalView.h
//
//  Created by Andy Grundman.
//  Ported to VoidLink by Acaki.
//  Copyright (c) 2025 Moonlight Stream. All rights reserved.
//

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import "MetalConfig.h"

// The protocol to provide resize and redraw callbacks to a delegate.
@protocol MetalViewDelegate <NSObject>

- (void)drawableResize:(CGSize)size;
- (void)renderTo:(nonnull CAMetalLayer *)layer;
- (void)waitToRenderTo:(nonnull CAMetalLayer *)layer;

@end

// The Metal game view base class.
@interface MetalView : UIView <CALayerDelegate>

@property (nonatomic, nonnull, readonly) CAMetalLayer *metalLayer;
@property (nonatomic, nullable) id<MetalViewDelegate> delegate;
@property (nonatomic) float framerate;

- (void)initCommon;
- (void)shutdown;
// Bounded join of the render thread; returns YES if it exited. On NO the
// thread reference is kept so joinRenderThread can finish the job later.
- (BOOL)shutdownWithTimeout:(CFTimeInterval)timeout;
// Blocks until the render thread exits. Call off the main thread only.
- (void)joinRenderThread;
#if AUTOMATICALLY_RESIZE
- (void)resizeDrawable:(CGFloat)scaleFactor;
#endif

@end
