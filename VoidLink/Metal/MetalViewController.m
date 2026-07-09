//
//  MetalViewController.m
//
//  Created by Andy Grundman.
//  Ported to VoidLink by Acaki.
//  Copyright (c) 2025 Moonlight Stream. All rights reserved.
//

#import "MetalViewController.h"
#import "FrameQueue.h"
#import "ImGuiRenderer.h"
#import "MetalVideoRenderer.h"

@implementation MetalViewController {
    FrameQueue *_frameQueue;
    float _framerate;
    TemporarySettings* _currentSettings;
    MetalView *_metalView;
    MetalVideoRenderer *_renderer;
    MetricsHandler _metricsHandler;
    CADisplayLink *_displayLink;
    BOOL _frameSlotAcquired;
}

- (nonnull instancetype)initWithFrame:(CGRect)bounds framerate:(float)framerate settings:(TemporarySettings* )settings metricsHandler:(MetricsHandler)metricsHandler {
    self = [super init];
    if (self) {
        _bounds = bounds;
        _frameQueue = [FrameQueue sharedInstance];
        _framerate = framerate;
        _currentSettings = settings;
        _metricsHandler = metricsHandler;
    }
    return self;
}

- (void)loadView {
    self.view = [[MetalView alloc] initWithFrame:_bounds];
    Log(LOG_I, @"[MetalViewController] created MetalView %@", (MetalView *)self.view);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    __block MetalView *view = (MetalView *)self.view;
    if (!view) {
        Log(LOG_E, @"The view attached to MetalViewController isn't a MetalView.");
        return;
    }
    _metalView = view;
    _metalView.delegate = self;
    _metalView.framerate = _framerate;

    // Select the device to render with.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        Log(LOG_E, @"Metal isn't supported on this device.");
        self.view = [[UIView alloc] initWithFrame:self.view.frame];
        return;
    }
    view.metalLayer.device = device;

    // Determine supported pixel format before initializing renderer
    // Use TARGET_OS_SIMULATOR to detect simulator environment
    MTLPixelFormat pixelFormat;
#if TARGET_OS_SIMULATOR
    // iOS Simulator doesn't support BGRA10_XR
    pixelFormat = MTLPixelFormatBGRA8Unorm;
    Log(LOG_W, @"Running on iOS Simulator, using BGRA8Unorm pixel format");
#else
    // On real devices, check if we should enable HDR
    if (_currentSettings.enableHdr) {
        pixelFormat = MTLPixelFormatBGRA10_XR;
        Log(LOG_I, @"HDR enabled, using BGRA10_XR pixel format");
    } else {
        pixelFormat = MTLPixelFormatBGRA8Unorm;
        Log(LOG_I, @"HDR disabled, using BGRA8Unorm pixel format");
    }
#endif

    // Initialize the renderer.
    MetalVideoRenderer *renderer = [[MetalVideoRenderer alloc] initWithMetalDevice:device
                                                               drawablePixelFormat:pixelFormat
                                                                         settings:_currentSettings];
    if (!renderer) {
        Log(LOG_E, @"The renderer couldn't be initialized.");
        return;
    }
    self->_renderer = renderer;
    Log(LOG_I, @"[MetalViewController] viewDidLoad, created renderer: %@", renderer);

    // Initialize the renderer-dependent view properties.
    view.metalLayer.pixelFormat = renderer.colorPixelFormat;
    view.metalLayer.maximumDrawableCount = 3;

    // We need a no-op displaylink timer or iOS can decide to run at 60fps
    // The overhead from this should be minimal.
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkHandler:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(_framerate, _framerate, _framerate);
    } else {
        _displayLink.preferredFramesPerSecond = _framerate;
    }
    [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)displayLinkHandler:(CADisplayLink *)link {
    // Rendering does not use DisplayLink, this exists to fool iOS into keeping us running at the desired framerate
}

- (void)waitToRenderTo:(nonnull CAMetalLayer *)layer {
    // Skip waiting when renderer is paused. Leave the slot flag set so
    // renderTo: still reaches its isStopping branch and drains the queue.
    if (_renderer.isStopping) {
        _frameSlotAcquired = YES;
        return;
    }

    // Renderer obtains an in-flight frame slot, waiting if necessary.
    // Defaults to YES so pre-iOS 13 keeps the old always-render behavior.
    _frameSlotAcquired = YES;
    if (@available(iOS 13.0, *)) {
        _frameSlotAcquired = [_renderer waitToRenderTo:layer];
    }

    if (_frameSlotAcquired) {
        // If we don't have a frame yet, wait on that too
        [_frameQueue waitForEnqueue];
    }
}

/// Draw frame (used by manual loop)
- (void)renderTo:(nonnull CAMetalLayer *)layer {
    if (!_frameSlotAcquired) {
        // No in-flight slot this pass (semaphore wait timed out, e.g. GPU
        // stalled in background). Rendering anyway would over-signal the
        // semaphore in the completion handler and break frame pacing.
        return;
    }
    CFTimeInterval timeout = (1.0f / _framerate) - _renderer.averageGPUTime;
    Frame *frame = [_frameQueue dequeueWithTimeout:timeout];

    if (!_renderer.isStopping) {
        // Only render if not paused
        if (frame) {
            //if (@available(iOS 13.0, *)) {
                [_renderer renderFrame:frame toLayer:layer];
            //}
        }
    } else {
        // When paused, we still dequeue frames to prevent accumulation
        // but don't render them. Also sleep a bit to reduce CPU usage
        usleep(100000);
    }
}

- (void)drawableResize:(CGSize)size {
    [_renderer drawableResize:size];
}

- (void)pauseRendering {
    if (_displayLink) {
        _displayLink.paused = YES;
    }
    if (_renderer) {
        _renderer.isStopping = YES;
    }
    Log(LOG_I, @"[MetalViewController] Rendering paused");
}

- (void)resumeRendering {
    if (_renderer) {
        _renderer.isStopping = NO;
    }
    if (_displayLink) {
        _displayLink.paused = NO;
    }
    Log(LOG_I, @"[MetalViewController] Rendering resumed");
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    Log(LOG_I, @"[MetalViewController] viewDidDisappear");

    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }

    // Only request the stop before the join — full renderer teardown clears
    // pipeline state the render loop may still be reading.
    if (_renderer) {
        [_renderer requestStop];
    }

    BOOL threadExited = YES;
    if (_metalView) {
        threadExited = [_metalView shutdownWithTimeout:3.0];
    }

    if (threadExited) {
        [_renderer shutdown];
        _metalView.delegate = nil;
        _renderer = nil;
        _metalView = nil;
    } else {
        // The render thread is still blocked (typically in a dispatch_sync
        // onto the main queue). Releasing the renderer or unhooking the
        // delegate now would let it resume into deallocated objects — hand
        // ownership to a background block that joins the thread first.
        // (view.delegate is strong and keeps this controller alive too.)
        MetalVideoRenderer *renderer = _renderer;
        MetalView *view = _metalView;
        _renderer = nil;
        _metalView = nil;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [view joinRenderThread];
            [renderer shutdown];
            dispatch_async(dispatch_get_main_queue(), ^{
                view.delegate = nil;
            });
        });
    }
}

#if TARGET_OS_IOS
// Hides the Home indicator button automatically.
- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}
#endif

@end
