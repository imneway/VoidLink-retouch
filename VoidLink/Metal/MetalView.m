//
//  MetalView.m
//
//  Created by Andy Grundman.
//  Ported to VoidLink by Acaki.
//  Copyright (c) 2025 Moonlight Stream. All rights reserved.
//
// This is based on the following Apple example
// https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link?language=objc
// https://developer.apple.com/wwdc23/10123/

#import "MetalView.h"
#import "MetalConfig.h"

@implementation MetalView {
    // The secondary thread containing the render loop.
    NSThread *_renderThread;
}

#pragma mark - Initialization and Setup.

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self initCommon];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self initCommon];
    }
    return self;
}

- (void)initCommon {
    _metalLayer = (CAMetalLayer *)self.layer;
    self.layer.delegate = self;
}

- (void)shutdown {
    [self shutdownWithTimeout:3.0];
}

- (BOOL)shutdownWithTimeout:(CFTimeInterval)timeout {
    // _renderThread is touched from the main thread (shutdown, window
    // reattach) and from a background join after a timed-out shutdown —
    // mutate it only under @synchronized, and compare before clearing so a
    // stale join can't drop a newly attached thread.
    NSThread *thread;
    @synchronized (self) {
        thread = _renderThread;
    }
    if (!thread) {
        return YES;
    }
    Log(LOG_I, @"[MetalView] sending renderThread a cancel message");
    [thread cancel];
    Log(LOG_I, @"[MetalView] waiting on renderThread to finish");
    // Bounded wait: this runs on the main thread while the render thread may
    // be blocked in a dispatch_sync onto the main queue (colorspace/EDR layer
    // updates) — spinning forever here is a mutual deadlock. Give up after
    // the deadline; once the main run loop resumes, the render thread's
    // dispatch_sync completes and the thread exits.
    CFTimeInterval deadline = CACurrentMediaTime() + timeout;
    while (!thread.isFinished && CACurrentMediaTime() < deadline) {
        usleep(1000);
    }
    if (thread.isFinished) {
        Log(LOG_I, @"[MetalView] renderThread has finished");
        @synchronized (self) {
            if (_renderThread == thread) {
                _renderThread = nil;
            }
        }
        return YES;
    }
    Log(LOG_W, @"[MetalView] renderThread still running after timeout; join it via joinRenderThread");
    return NO;
}

- (void)joinRenderThread {
    NSThread *thread;
    @synchronized (self) {
        thread = _renderThread;
    }
    while (thread && !thread.isFinished) {
        usleep(10000);
    }
    @synchronized (self) {
        if (_renderThread == thread) {
            _renderThread = nil;
        }
    }
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (void)didMoveToWindow {
    [self movedToWindow];
}

- (void)movedToWindow {
    if (!self.window) {
        Log(LOG_I, @"[MetalView] movedToWindow(nil): shutting down...");
        [self shutdown];
        return;
    }

    // Render on a new thread
    NSThread *renderThread = [[NSThread alloc] initWithBlock:^{
        while (![NSThread currentThread].isCancelled) {
            @autoreleasepool {
                [self.delegate waitToRenderTo:self.metalLayer];
                [self.delegate renderTo:self.metalLayer];
            }
        }
        Log(LOG_I, @"[MetalView] renderThread is exiting");
    }];
    renderThread.name = @"MetalVideoRenderer";
    renderThread.qualityOfService = NSQualityOfServiceUserInteractive;
    @synchronized (self) {
        _renderThread = renderThread;
    }
    [renderThread start];
    Log(LOG_I, @"[MetalView] started renderThread %@", renderThread);

    // Perform any actions that need to know the size and scale of the drawable. When UIKit calls
    // didMoveToWindow after the view initialization, this is the first opportunity to notify
    // components of the drawable's size.
#if AUTOMATICALLY_RESIZE
    [self resizeDrawable:self.window.screen.nativeScale];
#else
    // Notify the delegate of the default drawable size when the system can calculate it.
    CGSize defaultDrawableSize = self.bounds.size;
    defaultDrawableSize.width *= self.layer.contentsScale;
    defaultDrawableSize.height *= self.layer.contentsScale;
    [self.delegate drawableResize:defaultDrawableSize];
#endif
}

#pragma mark - Resizing

#if AUTOMATICALLY_RESIZE

// Override all methods that indicate the view's size has changed.

- (void)setContentScaleFactor:(CGFloat)contentScaleFactor {
    [super setContentScaleFactor:contentScaleFactor];
    [self resizeDrawable:self.window.screen.nativeScale];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self resizeDrawable:self.window.screen.nativeScale];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self resizeDrawable:self.window.screen.nativeScale];
}

- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    [self resizeDrawable:self.window.screen.nativeScale];
}

- (void)resizeDrawable:(CGFloat)scaleFactor {
    CGSize newSize = self.bounds.size;
    newSize.width *= scaleFactor;
    newSize.height *= scaleFactor;

    if (newSize.width <= 0 || newSize.height <= 0) {
        return;
    }

    // The system calls all AppKit and UIKit calls that notify of a resize on the main thread. Use
    // a synchronized block to ensure that resize notifications on the delegate are atomic.
    @synchronized(_metalLayer) {
        if (newSize.width == _metalLayer.drawableSize.width && newSize.height == _metalLayer.drawableSize.height) {
            return;
        }

        Log(LOG_I, @"[MetalView] resizeDrawable: %.2f x %.2f", newSize.width, newSize.height);

        _metalLayer.drawableSize = newSize;

        [_delegate drawableResize:newSize];
    }
}
#endif  // END AUTOMATICALLY_RESIZE

@end
