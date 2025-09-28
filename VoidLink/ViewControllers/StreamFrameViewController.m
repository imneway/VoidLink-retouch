//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.1
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import <AVKit/AVKit.h>
#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "SceneDelegate.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "PaddedLabel.h"
#import "ImGuiRenderer.h"
#import "RelativeTouchHandler.h"
#import "MetalVideoRenderer.h"
#import "CustomEdgeSlideGestureRecognizer.h"
#import "CustomTapGestureRecognizer.h"
#import "LocalizationHelper.h"
#import "VoidLink-Swift.h"
#import "OSCProfilesManager.h"
#import "ThemeManager.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#include <errno.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end



@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    NSTimer *_timeBatteryUpdateTimer;
    PaddedLabel *_overlayView;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    uint16_t overlayLevel;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    UILabel *_timeLabel;
    UILabel *_batteryLabel;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    bool viewJustLoaded;
    bool viewIsBeingResized;
    CGSize _keyboardSize;
    PlotMetrics _decodeMetrics;
    PlotMetrics _frameDropMetrics;
    PlotMetrics _frameQueueMetrics;
    UIWindow *_extWindow;
    UIView *_streamVideoRenderView;
    // Main-like toast UI (reuse from Main page style)
    UIView *_autoEnterToast;
    UILabel *_autoEnterLabel;
    UIButton *_autoEnterCancelButton;
    // Self-heal reconnect guard
    NSTimer *_reconnectTimer;
    double _reconnectElapsedSeconds;
    NSInteger _reconnectProbeTick;
    BOOL _hasConnectionStarted;
    /*
     * View architecture of this viewController:
     * self.view (named `streamFrameTopLayerView` in StreamView.m, where slide & tap gestures, and onScreenControls & OnScreenWidgetView buttons are registered)
     *   - streamView (where touchHandlers are registered)
     *     - streamVideoRenderView (where stream view is rendered)
     */
    UIWindow *_deviceWindow;
    dispatch_block_t _delayedRemoveExtScreen;
    VideoDecoderRenderer *_videoRenderer;
    BOOL _isRestoringFromPiP;
#if !TARGET_OS_TV
    CustomEdgeSlideGestureRecognizer *_slideToSettingsRecognizer;
    CustomEdgeSlideGestureRecognizer *_slideToCmdToolRecognizer;
    CustomEdgeSlideGestureRecognizer *_rightEdgeToggleOscRecognizer;
    CustomTapGestureRecognizer *_oscLayoutTapRecoginizer;
    LayoutOnScreenControlsViewController *_layoutOnScreenControlsVC;
    ToolboxViewController* toolBoxViewController;
    UIControl *_toolboxOverlay;
#pragma mark Snap ratio button
    UIButton *_snapRatioButton;
    UIButton *_oscToggleButton;
#else
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
#endif

}

// MARK: - 方向锁定 持久化Key（与其它页面一致）
static NSString * const kOSCLockedPortraitProfileName = @"OSCLockedPortraitProfileName";
static NSString * const kOSCLockedLandscapeProfileName = @"OSCLockedLandscapeProfileName";

// 根据当前视图 bounds 判断是否横屏
- (BOOL)osc_isCurrentLandscapeInViewBounds {
    return self.view.bounds.size.width > self.view.bounds.size.height;
}

// 读取锁定的布局名
- (NSString *)osc_lockedProfileNameForLandscape:(BOOL)isLandscape {
    NSString *key = isLandscape ? kOSCLockedLandscapeProfileName : kOSCLockedPortraitProfileName;
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

// 在串流界面应用锁定：切换选中布局并刷新OSC与Widget
- (void)osc_applyLockForCurrentOrientationInStreamingIfNeeded {
    BOOL isLandscape = [self osc_isCurrentLandscapeInViewBounds];
    NSString *lockedName = [self osc_lockedProfileNameForLandscape:isLandscape];
    if (lockedName.length == 0) {
        return;
    }
    OSCProfilesManager *pm = [OSCProfilesManager sharedManager:self.view.bounds];
    NSMutableArray *all = [pm getAllProfiles];
    OSCProfile *found = nil;
    for (OSCProfile *p in all) {
        if ([p.name isEqualToString:lockedName]) { found = p; break; }
    }
    if (!found) {
        return;
    }
    if ([pm isTemplateProfile:found.name]) {
        return;
    }
    if (![[[pm getSelectedProfile] name] isEqualToString:found.name]) {
        [pm setProfileToSelected:found.name];
        // 刷新串流界面上的 OSC 与键盘控件
        if (self->_controllerSupport && self->_streamConfig) {
            [self->_streamView reloadOnScreenControlsRealtimeWith:(ControllerSupport*)self->_controllerSupport
                                                         andConfig:(StreamConfiguration*)self->_streamConfig];
        }
        [self->_streamView reloadOnScreenWidgetViews];
    }
}

// 应用当前屏幕方向的方向锁定
- (void)osc_applyLockForCurrentOrientation {
    [self osc_applyLockForCurrentOrientationInStreamingIfNeeded];
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    _streamView.hidden = YES;
    if (self.imguiView) {
        self.imguiView.mtkView.hidden = YES;
        Log(LOG_I, @"Hiding ImGui view for PiP start.");
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    Log(LOG_E, @"PiP Failed to Start: %@", error);
    _streamView.hidden = NO;
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    _streamView.hidden = NO;
    if (self.imguiView) {
        self.imguiView.mtkView.hidden = NO;
        Log(LOG_I, @"Showing ImGui view after PiP stop.");
    }

    if (!_isRestoringFromPiP) {
        [self returnToMainFrame];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL restored))completionHandler {
    _isRestoringFromPiP = YES;
    _streamView.hidden = NO;
    if (self.imguiView) {
        self.imguiView.mtkView.hidden = NO;
        Log(LOG_I, @"Showing ImGui view for PiP restore.");
    }
    completionHandler(YES);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
           didTransitionToRenderSize:(CMVideoDimensions)newRenderSize API_AVAILABLE(ios(15.0)){
    Log(LOG_I, @"PiP transitioned to size: %d x %d", newRenderSize.width, newRenderSize.height);
 }

// Indicate that playback is never paused for a live stream
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(14.0)) {
    return NO;
}

// Return an indefinite time range for a live stream
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController API_AVAILABLE(ios(14.0)) {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController setPlaying:(BOOL)playing API_AVAILABLE(ios(14.0)) {
}

// Live streams typically can't skip, so just call the completion handler.
- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(14.0)) {
    if (completionHandler) {
        completionHandler();
    }
}

- (BOOL)isFirstStreaming {
    NSString *key = @"hasStreamedBefore";
    BOOL streamedBefore = [[NSUserDefaults standardUserDefaults] boolForKey:key];

    if (!streamedBefore) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize]; // iOS 12+ 可省略
        return YES;
    }
    return NO;
}


- (bool)isOscLayoutToolEnabled{
    return (_settings.touchMode.intValue == RelativeTouch || _settings.touchMode.intValue == NativeTouch || _settings.touchMode.intValue == AbsoluteTouch) && _settings.onscreenControls.intValue == OnScreenControlsLevelCustom;
}

- (void)setupPiPControllerWithRenderer:(VideoDecoderRenderer *)videoRenderer {    // Ensure we have the renderer and its layer
    if (self.pipController) {
        return;
    }
    Log(LOG_I, @"Setting up PiP controller...");

    if (!videoRenderer || !videoRenderer.displayLayer) {
        Log(LOG_E, @"PiP setup failed: Video renderer or display layer not ready.");
        return;
    }

    AVSampleBufferDisplayLayer *streamLayer = videoRenderer.displayLayer;

    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        if (@available(iOS 15.0, *)) {
            self.pipContentSource = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:streamLayer playbackDelegate:(id<AVPictureInPictureSampleBufferPlaybackDelegate>)self];
            self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:self.pipContentSource];
            self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        } else {
            Log(LOG_E, @"PiP not fully supported on this device.");
            return;
        }

        if (self.pipController) {
            self.pipController.delegate = self;
            Log(LOG_I, @"PiP controller created successfully.");
        } else {
            Log(LOG_E, @"Failed to create PiP controller.");
        }
    } else {
        Log(LOG_E, @"PiP not supported on this device.");
    }
}

- (void)cleanupPiPController {
    if (self.pipController) {
        self.pipController.delegate = nil;
        self.pipController = nil;
        if (@available(iOS 15.0, *)) {
            self.pipContentSource = nil;
        }

        Log(LOG_I, @"PiP controller cleaned up.");
    }
}

- (void)updateToolboxSpecialEntries{
    if([self isOscLayoutToolEnabled]){
        if(![toolBoxViewController.specialEntries containsObject:@"widgetLayoutTool"]) [toolBoxViewController.specialEntries insertObject:@"widgetLayoutTool" atIndex:0];
        if(![toolBoxViewController.specialEntries containsObject:@"widgetSwitchTool"]) [toolBoxViewController.specialEntries insertObject:@"widgetSwitchTool" atIndex:1];
    }
    else{
        [toolBoxViewController.specialEntries removeObject:@"widgetLayoutTool"];
        [toolBoxViewController.specialEntries removeObject:@"widgetSwitchTool"];
    }
    if(_settings.enablePIP){
        if(![toolBoxViewController.specialEntries containsObject:@"enterPip"]) [toolBoxViewController.specialEntries addObject:@"enterPip"];
    }
    else [toolBoxViewController.specialEntries removeObject:@"enterPip"];
    
    NSLog(@"toolBoxViewController.specialEntries %@", toolBoxViewController.specialEntries);
}

- (void)configOscLayoutTool{

    if([self isOscLayoutToolEnabled]){
        /* sets a reference to the correct 'LayoutOnScreenControlsViewController' depending on whether the user is on an iPhone or iPad */
        // _layoutOnScreenControlsVC = [[LayoutOnScreenControlsViewController alloc] init];
        BOOL isIPhone = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
        if (isIPhone) {
            UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPhone" bundle:nil];
            _layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
        }
        else {
            UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
            _layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
            _layoutOnScreenControlsVC.modalPresentationStyle = UIModalPresentationFullScreen;
        }
        _layoutOnScreenControlsVC.view.backgroundColor = UIColor.clearColor;
        _layoutOnScreenControlsVC.modalPresentationStyle = UIModalPresentationOverCurrentContext;
    }
    //NSLog(@"in osc frameview gestures: %d", (uint32_t)[self.view.gestureRecognizers count]);
    //NSLog(@"in osc streamview gestures: %d", (uint32_t)[_streamView.gestureRecognizers count]);
}

- (void)presentToolboxViewController{
    [self configOscLayoutTool];
    ToolboxViewController* oldToolboxVC = toolBoxViewController;
    toolBoxViewController = [[ToolboxViewController alloc] init];
    toolBoxViewController.specialEntryDelegate = self;
    toolBoxViewController.specialEntries = oldToolboxVC.specialEntries;
    toolBoxViewController.modalPresentationStyle = UIModalPresentationOverCurrentContext;
    toolBoxViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    // delegate will be set again in completion when presentationController is ready

    [self presentViewController:toolBoxViewController animated:YES completion:^{
        // Ensure delegate is set after presentation
        self->toolBoxViewController.presentationController.delegate = self;
        //[self->toolBoxViewController setupConstraints];
    }];

    id<UIViewControllerTransitionCoordinator> presentationCoordinator = self.transitionCoordinator ?: toolBoxViewController.transitionCoordinator;
    if (presentationCoordinator) {
        [presentationCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
            UIView *container = self->toolBoxViewController.view.superview ?: self.view;
            if (self->_toolboxOverlay == nil) {
                CGRect frame = container.bounds;
                self->_toolboxOverlay = [[UIControl alloc] initWithFrame:frame];
                self->_toolboxOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
                self->_toolboxOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self->_toolboxOverlay addTarget:self action:@selector(_toolboxOverlayTapped) forControlEvents:UIControlEventTouchDown];
                self->_toolboxOverlay.alpha = 0.0;
            }
            if (self->_toolboxOverlay.superview != container) {
                [self->_toolboxOverlay removeFromSuperview];
                [container insertSubview:self->_toolboxOverlay belowSubview:self->toolBoxViewController.view];
            }
            self->_toolboxOverlay.alpha = 1.0; // will animate alongside transition
        } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
            if ([context isCancelled]) {
                // Rollback overlay if presentation cancelled
                [self _removeToolboxOverlayIfNeeded];
            }
        }];
    } else {
        // Fallback: insert on next runloop to minimize latency
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *container = self->toolBoxViewController.view.superview ?: self.view;
            if (self->_toolboxOverlay == nil) {
                CGRect frame = container.bounds;
                self->_toolboxOverlay = [[UIControl alloc] initWithFrame:frame];
                self->_toolboxOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
                self->_toolboxOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self->_toolboxOverlay addTarget:self action:@selector(_toolboxOverlayTapped) forControlEvents:UIControlEventTouchDown];
                self->_toolboxOverlay.alpha = 0.0;
            }
            if (self->_toolboxOverlay.superview != container) {
                [self->_toolboxOverlay removeFromSuperview];
                [container insertSubview:self->_toolboxOverlay belowSubview:self->toolBoxViewController.view];
            }
            [UIView animateWithDuration:0.2 animations:^{ self->_toolboxOverlay.alpha = 1.0; }];
        });
    }
}

- (void)_toolboxOverlayTapped {
    if (toolBoxViewController && [toolBoxViewController isPinned]) {
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{ self->_toolboxOverlay.alpha = 0.0; }];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)presentationControllerWillDismiss:(UIPresentationController *)presentationController {
    // Fade out overlay alongside dismissal
    [UIView animateWithDuration:0.2 animations:^{ self->_toolboxOverlay.alpha = 0.0; }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self _removeToolboxOverlayIfNeeded];
}

- (void)_removeToolboxOverlayIfNeeded {
    if (_toolboxOverlay && _toolboxOverlay.superview) {
        [_toolboxOverlay removeFromSuperview];
    }
}

- (void)configGestures{
    _slideToSettingsRecognizer = [[CustomEdgeSlideGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _slideToSettingsRecognizer.edges = _settings.slideToSettingsScreenEdge.intValue;
    _slideToSettingsRecognizer.normalizedThresholdDistance = _settings.slideToSettingsDistance.floatValue;
    _slideToSettingsRecognizer.delaysTouchesBegan = NO;
    _slideToSettingsRecognizer.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:_slideToSettingsRecognizer];
    // Right-side edge is freed; Command Manager is opened by on-screen widget "CMD"

    // Add a small-threshold right-edge gesture to toggle OSC visibility
    _rightEdgeToggleOscRecognizer = [[CustomEdgeSlideGestureRecognizer alloc] initWithTarget:self action:@selector(handleRightEdgeToggle:)];
    _rightEdgeToggleOscRecognizer.edges = UIRectEdgeRight;
    CGFloat smallThreshold = 15.0f / self.view.frame.size.width; // ~15pt swipe distance
    _rightEdgeToggleOscRecognizer.normalizedThresholdDistance = smallThreshold;
    _rightEdgeToggleOscRecognizer.delaysTouchesBegan = NO;
    _rightEdgeToggleOscRecognizer.delaysTouchesEnded = NO;
    _rightEdgeToggleOscRecognizer.cancelsTouchesInView = NO;
    _rightEdgeToggleOscRecognizer.delegate = self;
    _rightEdgeToggleOscRecognizer.edgeDelegate = self;
    // Right edge small gesture is standalone now; no dependency on Command Manager gesture
    [self.view addGestureRecognizer:_rightEdgeToggleOscRecognizer];
    
    if([self isOscLayoutToolEnabled]){
        _oscLayoutTapRecoginizer = [[CustomTapGestureRecognizer alloc] initWithTarget:self action:@selector(handleWidgetLayoutGesture)];
        _oscLayoutTapRecoginizer.numberOfTouchesRequired = _settings.oscLayoutToolFingers.intValue; //tap a predefined number of fingers to open osc layout tool
        _oscLayoutTapRecoginizer.tapDownTimeThreshold = 0.2;
        _oscLayoutTapRecoginizer.delaysTouchesBegan = NO;
        _oscLayoutTapRecoginizer.delaysTouchesEnded = NO;
        if(_settings.touchMode.intValue == AbsoluteTouch) _oscLayoutTapRecoginizer.immediateTriggering = true; // make immediate triggering on for absolute touch mode
        [self.view addGestureRecognizer:_oscLayoutTapRecoginizer]; //
    }
    
}

- (void)configZoomGestureAndAddStreamView{
    if (_settings.touchMode.intValue == AbsoluteTouch) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
        [_scrollView.panGestureRecognizer setMaximumNumberOfTouches:2]; // reduce competing with keyboardToggleRecognizer in StreamView.
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        // Insert at index 0 to ensure it doesn't cover OSC controls (CALayers)
        [self.view insertSubview:_scrollView atIndex:0];
    }
    else{
        // Add streamView directly to self.view in other touch modes
        // Insert at index 0 to ensure it doesn't cover OSC controls (CALayers)
        [self.view insertSubview:_streamView atIndex:0];
    }
}

- (void)reConfigStreamViewRealtime {
    [self reConfigStreamViewRealtimeAndReloadSettings:YES];
}

// key implementation of reconfiguring streamview after realtime setting menu is closed.
- (void)reConfigStreamViewRealtimeAndReloadSettings:(BOOL)reloadSettings{
    //[self.view removeGestureRecognizer:]
    //first, remove all gesture recognizers:
    if (self->_streamView) {
        [self->_streamView endRightEdgeGestureSuppression];
    }
    for (UIGestureRecognizer *recognizer in _streamView.gestureRecognizers) {
        [_streamView removeGestureRecognizer:recognizer];
    }
    for (UIGestureRecognizer *recognizer in self.view.gestureRecognizers) {
        [self.view removeGestureRecognizer:recognizer];
    }
    
    if (reloadSettings) {
        _settings = [[[DataManager alloc] init] getSettings];  //StreamFrameViewController retrieve the settings here.
    }
    overlayLevel = _settings.statsOverlayLevel.intValue;
    if(viewIsBeingResized) viewIsBeingResized = false;
    else [self configOscLayoutTool];
    [self updateToolboxSpecialEntries];
    [self configGestures];
    [self configZoomGestureAndAddStreamView];
    [self->_streamView disableOnScreenControls]; //don't know why but this must be called outside the streamview class, just put it here. execute in streamview class cause hang
    [self.mainFrameViewcontroller reloadStreamConfig]; // reload streamconfig
    
    NSLog(@"viewJustloaded: %d", viewJustLoaded);
    if(!viewJustLoaded) [_controllerSupport updateControllerSupport:self.streamConfig delegate:self];
    else viewJustLoaded = false;
    // reload controllerSupport obj, this is mandatory for OSC reload,especially when the stream view is launched without OSC
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig streamFrameTopLayerView:self.view]; //reinitiate setupStreamView process.
        // we got self.view passed to streamView class as the topLayerView, will be useful in many cases
    [self->_streamView reloadOnScreenControlsRealtimeWith:(ControllerSupport*)_controllerSupport
                                        andConfig:(StreamConfiguration*)_streamConfig]; //reload OSC here.
    [self->_streamView reloadOnScreenWidgetViews]; //reload keyboard buttons here. the keyboard widget view will be added to the streamframe view instead streamview, the highest layer, which saves a lot of reengineering
    [self reloadAirPlayConfig];
    [self mousePresenceChanged];
    [self applySnapToTopIfNeeded];
    
    // Invalidate the old timer to prevent duplicates
    if (self->_statsUpdateTimer) {
        [self->_statsUpdateTimer invalidate];
        self->_statsUpdateTimer = nil;
    }
    // Re-schedule the timer only if the overlay is enabled
    if (_settings.statsOverlayEnabled) {
        self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                 target:self
                                                               selector:@selector(updateStatsOverlay)
                                                               userInfo:nil
                                                                repeats:YES];
    } else {
        // Ensure the overlay is removed when disabled
        [_overlayView removeFromSuperview];
    }
    
    // Restart time and battery update timer
    if (self->_timeBatteryUpdateTimer) {
        [self->_timeBatteryUpdateTimer invalidate];
        self->_timeBatteryUpdateTimer = nil;
    }
    self->_timeBatteryUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:60.0f
                                                                   target:self
                                                                 selector:@selector(updateTimeBatteryDisplay)
                                                                 userInfo:nil
                                                                  repeats:YES];
    
    // Re-create the ImGui view to properly apply the 'enableGraphs' setting
    if (self.imguiView && self.imguiView.mtkView) {
        [self.imguiView stop];
        [self.imguiView.mtkView removeFromSuperview];
        self.imguiView = nil;
    }
    self.imguiView = [[ImGuiRenderer alloc] initWithFrame:self.view.bounds
                                                streamFps:[_settings.framerate intValue]
                                             enableGraphs:_settings.enableGraphs
                                             graphOpacity:[_settings.graphOpacity intValue]];
    self.imguiView.mtkView.userInteractionEnabled = NO;
    [self.view addSubview:self.imguiView.mtkView];

    // Ensure views are layered correctly
    // Metal view should be at the bottom for video rendering
    if (self.metalViewController && self.metalViewController.view.superview) {
        [self.view sendSubviewToBack:self.metalViewController.view];
    }
    // StreamView should also be at the back so OSC CALayers on self.view show
    if (self->_streamView && self->_streamView.superview) {
        [self.view sendSubviewToBack:self->_streamView];
    }
    // ImGui view should be on top for debug graphs
    if (self.imguiView && self.imguiView.mtkView.superview) {
        [self.view bringSubviewToFront:self.imguiView.mtkView];
    }

    NSLog(@"frameview gestures: %d", (uint32_t)[self.view.gestureRecognizers count]);
    NSLog(@"streamview gestures: %d", (uint32_t)[_streamView.gestureRecognizers count]);
    // Ensure ratio button is created/updated after reconfig
    [self updateSnapRatioButton];
}

- (void)applySnapToTopIfNeeded {
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (!isPad || !_settings.snapScreenToTop) {
        // Restore to original position
        CGRect f = _streamView.frame;
        f.origin.y = 0;
        _streamView.frame = f;
        _streamView.originalFrame = f;
        // Restore Metal view
        [_streamView liftMetalVideoViewIfNeeded:0];
        // Hide button if not enabled
        if (_snapRatioButton) _snapRatioButton.hidden = YES;
        return;
    }

    CGFloat viewWidth = self.view.bounds.size.width;
    CGFloat viewHeight = self.view.bounds.size.height;
    // target aspect: 0 -> 16:9, 1 -> Full Screen (use actual stream aspect)
    CGFloat targetAspect = (_settings.snapScreenRatioMode.integerValue == 0) ? (16.0f/9.0f) : ((CGFloat)_streamConfig.width / (CGFloat)_streamConfig.height);
    if (targetAspect <= 0.0f) targetAspect = 16.0f/9.0f;
    CGFloat videoHeight = viewWidth / targetAspect; // iPad: 按宽等比
    CGFloat topBlackBar = (viewHeight - videoHeight) / 2.0f;
    if (topBlackBar < 0) topBlackBar = 0;
    // Portrait: use half of the offset (not full top-align)
    if (viewHeight > viewWidth) {
        topBlackBar = topBlackBar * 0.5f;
    }

    // Move the entire StreamView up
    CGRect f = self.view.bounds;
    f.origin.y = -topBlackBar;
    _streamView.frame = f;
    _streamView.originalFrame = f; // so keyboard lift restores correctly

    // Move Metal video view by the same amount (if applicable)
    [_streamView liftMetalVideoViewIfNeeded:topBlackBar];

    // Show/update ratio button
    [self updateSnapRatioButton];
}

- (void)updateSnapRatioButton {
    if (!_snapRatioButton) {
        _snapRatioButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _snapRatioButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_snapRatioButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.64] forState:UIControlStateNormal];
        _snapRatioButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [_snapRatioButton addTarget:self action:@selector(toggleSnapRatio) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_snapRatioButton];
    }
    
    // Create OSC toggle button if not exists
    if (!_oscToggleButton) {
        _oscToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _oscToggleButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_oscToggleButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.64] forState:UIControlStateNormal];
        _oscToggleButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [_oscToggleButton addTarget:self action:@selector(toggleOscOnOff) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_oscToggleButton];
    }
    
    // Update titles
    NSString *snapTitle = _settings.snapScreenRatioMode.integerValue == 0 ? @"16:9" : @"Full Screen";
    [_snapRatioButton setTitle:snapTitle forState:UIControlStateNormal];
    
    // Update OSC button title based ONLY on ON/OFF state, not transparency state
    OnScreenControlsLevel currentLevel = [_streamView getCurrentOscState];
    NSString *oscTitle = (currentLevel == OnScreenControlsLevelOff) ? @"OSC OFF" : @"OSC ON";
    [_oscToggleButton setTitle:oscTitle forState:UIControlStateNormal];
    
    // Hide both buttons if snap screen is not enabled
    _snapRatioButton.hidden = !_settings.snapScreenToTop;
    _oscToggleButton.hidden = !_settings.snapScreenToTop;
    
    if (_snapRatioButton.hidden) return;
    
    // Layout both buttons at bottom-right
    // First calculate sizes
    CGSize snapSize = [_snapRatioButton sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGSize oscSize = [_oscToggleButton sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    
    // Position snap ratio button (rightmost)
    CGFloat snapX = self.view.bounds.size.width - 24 - snapSize.width;
    CGFloat snapY = self.view.bounds.size.height - 12 - snapSize.height;
    _snapRatioButton.frame = CGRectMake(snapX, snapY, snapSize.width, snapSize.height);
    
    // Position OSC button (left of snap ratio button with 8pt spacing)
    CGFloat oscX = snapX - 8 - oscSize.width;
    CGFloat oscY = self.view.bounds.size.height - 12 - oscSize.height;
    _oscToggleButton.frame = CGRectMake(oscX, oscY, oscSize.width, oscSize.height);
}

- (void)createTimeBatteryDisplay {
    // Create time label
    if (!_timeLabel) {
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _timeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.64];
        _timeLabel.userInteractionEnabled = NO;
        [self.view addSubview:_timeLabel];
    }
    
    // Create battery label
    if (!_batteryLabel) {
        _batteryLabel = [[UILabel alloc] init];
        _batteryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _batteryLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.64];
        _batteryLabel.userInteractionEnabled = NO;
        [self.view addSubview:_batteryLabel];
    }
    
    [self updateTimeBatteryDisplay];
}

- (void)updateTimeBatteryDisplay {
    // Update time
    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.dateFormat = @"HH:mm";
    _timeLabel.text = [timeFormatter stringFromDate:[NSDate date]];
    [_timeLabel sizeToFit];
    
    // Update battery
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    float batteryLevel = device.batteryLevel;
    int batteryPercent = (int)(batteryLevel * 100);
    _batteryLabel.text = [NSString stringWithFormat:@"%d%%", batteryPercent];
    [_batteryLabel sizeToFit];
    
    // Layout labels at bottom-left
    CGFloat leftMargin = 24.0f;
    CGFloat bottomMargin = 12.0f;
    CGFloat spacing = 12.0f;
    
    CGFloat timeX = leftMargin;
    CGFloat batteryX = timeX + _timeLabel.frame.size.width + spacing;
    CGFloat y = self.view.bounds.size.height - bottomMargin - _timeLabel.frame.size.height;
    
    _timeLabel.frame = CGRectMake(timeX, y, _timeLabel.frame.size.width, _timeLabel.frame.size.height);
    _batteryLabel.frame = CGRectMake(batteryX, y, _batteryLabel.frame.size.width, _batteryLabel.frame.size.height);
}

- (void)toggleSnapRatio {
    // Toggle 0<->1
    NSInteger mode = _settings.snapScreenRatioMode.integerValue == 0 ? 1 : 0;
    // Persist to NSUserDefaults so侧栏也能读到
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"snapScreenRatioMode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // 立即更新内存 settings
    _settings.snapScreenRatioMode = [NSNumber numberWithInteger:mode];
    // 重新应用布局
    [self applySnapToTopIfNeeded];
}

- (void)toggleOscOnOff {
    // Avoid interference when widget layout tool is open
    if (self->_streamView.widgetToolOpened) {
        return;
    }

    OnScreenControlsLevel currentLevel = [self->_streamView getCurrentOscState];
    BOOL isOscObscured = [self->_streamView isOscObscuredByAlpha];

    if (currentLevel == OnScreenControlsLevelOff || isOscObscured) {
        // If OSC is off or obscured, turn it on
        [self->_streamView reloadOnScreenControlsRealtimeWith:(ControllerSupport*)self->_controllerSupport
                                                    andConfig:(StreamConfiguration*)self->_streamConfig];
        [self->_streamView reloadOnScreenWidgetViews]; // Reload widgets to ensure they are recreated
        [self->_streamView setOscObscuredByAlpha:NO]; // Restore OSC layers to normal opacity
        [self setWidgetsHidden:NO]; // Restore widgets to normal opacity
    } else {
        // If OSC is on, turn it off completely
        [self->_streamView disableOnScreenControls]; // Disable OSC completely
        [self->_streamView clearOnScreenWidgets]; // Remove all onscreen widgets completely
    }
    
    // Update button title
    [self updateSnapRatioButton];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    _deviceWindow = self.view.window;
    if (@available(iOS 13.0, *)) {
        UIScreen *currentScreen = self.view.window.windowScene.screen;
        if (UIScreen.screens.count > 1 && [self isAirPlayEnabled] && currentScreen == UIScreen.mainScreen) {
            [SceneDelegate setExternalDisplayRenderView:self->_streamVideoRenderView];
        }
        else {
            /*
             _settings.externalDisplayMode.intValue:
             0 - stage manager
             1 - airplay
             2 - disabled
             */
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_streamView insertSubview:self->_streamVideoRenderView atIndex:0];
            });
        }
    } else {
        [self->_streamView insertSubview:self->_streamVideoRenderView atIndex:0];
        // Fallback on earlier versions
    }

    self->_streamView.originalFrame = self->_streamView.frame;
    [self updateSnapRatioButton];

    // check to see if external screen is connected/disconnected

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(extScreenDidConnect:)
                                                 name: UIScreenDidConnectNotification
                                               object: nil];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(extScreenDidDisconnect:)
                                                 name: UIScreenDidDisconnectNotification
                                               object: nil];
   
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reConfigStreamViewRealtime) // reconfig streamview when settings view is closed in stream view
                                                 name:@"SettingsViewClosedNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(disconnectRemoteSession) //quit session when exit button is press in setting view during streaming
                                                 name:@"SessionDisconnectedBySettingsMenuNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(expandSettingsView) // //force expand settings view to update resolution table, and all setting includes current fullscreen resolution will be updated.
                                                 name:@"SettingsOverlayButtonPressedNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(presentToolboxViewController) // open command manager via on-screen widget
                                                 name:@"CommandManagerOverlayButtonPressedNotification"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    #endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif

- (void)popFirstStreamingTip {
    // 初始化倒计时秒数
    __block NSInteger remainingSeconds = 16;

    NSString* settingsEdgeSide = _settings.slideToSettingsScreenEdge.intValue == UIRectEdgeLeft ? [LocalizationHelper localizedStringForKey:@"left"] : [LocalizationHelper localizedStringForKey:@"right"];
    NSString* cmdToolEdgeSide = _settings.slideToSettingsScreenEdge.intValue == UIRectEdgeLeft ? [LocalizationHelper localizedStringForKey:@"right"] : [LocalizationHelper localizedStringForKey:@"left"];
    uint8_t slideDist = (uint8_t)(_settings.slideToSettingsDistance.floatValue * 100);
    // 创建弹窗
    
    NSString* tipText = [LocalizationHelper localizedStringForKey:@"firstLaunchTip", settingsEdgeSide, slideDist, cmdToolEdgeSide, slideDist];
    
    UIAlertController *tipsAlertController = [UIAlertController alertControllerWithTitle: [LocalizationHelper localizedStringForKey:@"First Launch Tips"] message: [LocalizationHelper localizedStringForKey:@"%@", tipText] preferredStyle:UIAlertControllerStyleAlert];

    
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentLeft;

    NSDictionary *attributes = @{
        NSParagraphStyleAttributeName: paragraphStyle,
        NSFontAttributeName: [UIFont systemFontOfSize:14]
    };

    NSAttributedString *attributedMessage = [[NSAttributedString alloc] initWithString:tipText
                                                                             attributes:attributes];

    // 使用 KVC 设置 attributedMessage（注意审核风险）
    [tipsAlertController setValue:attributedMessage forKey:@"attributedMessage"];

    // 添加确认按钮（初始禁用）
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Got it! (15)"]
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction * _Nonnull action) {
    }];
    confirmAction.enabled = NO;
    [tipsAlertController addAction:confirmAction];

    // 显示弹窗
    [self presentViewController:tipsAlertController animated:YES completion:nil];

    // 使用dispatch_source_t实现精确倒计时
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);

    dispatch_source_set_event_handler(timer, ^{
        remainingSeconds--;

        if (remainingSeconds <= 0) {
            // 倒计时结束
            dispatch_source_cancel(timer);
            // 启用确认按钮
            confirmAction.enabled = YES;
            [confirmAction setValue:[LocalizationHelper localizedStringForKey:@"Got it!"] forKey:@"title"];
        } else {
            // 更新按钮标题和消息
            [confirmAction setValue:[NSString stringWithFormat:[LocalizationHelper localizedStringForKey:@"Got it! (%ld)", remainingSeconds], (long)remainingSeconds] forKey:@"title"];
        }
    });

    dispatch_resume(timer);

}


- (void)viewDidLoad
{
    viewJustLoaded = true;
    viewIsBeingResized = false;
    [super viewDidLoad];

    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];  //StreamFrameViewController retrieve the settings here.
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    // [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel setText: [LocalizationHelper localizedStringForKey:@"Connecting..."]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    _hasConnectionStarted = NO;
    _reconnectTimer = nil;
    _reconnectElapsedSeconds = 0;
    _reconnectProbeTick = 0;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    
    toolBoxViewController = [[ToolboxViewController alloc] init];
    toolBoxViewController.specialEntryDelegate = self;

    _isRestoringFromPiP = NO;

    /*
     _settings.externalDisplayMode.intValue:
     0 - stage manager
     1 - airplay
     */
    // A separate render view is always created to support external displays.
    _streamVideoRenderView = (StreamView*)[[UIView alloc] initWithFrame:self.view.frame];
    _streamVideoRenderView.bounds = _streamView.bounds;
    _streamVideoRenderView.userInteractionEnabled = false;
    
    //[_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
    // 在初始化OSC之前先应用方向锁定，避免显示旧布局
    [self osc_applyLockForCurrentOrientation];
    
    [self reConfigStreamViewRealtime]; // call this method again to make sure all gestures are configured & added to the superview(self.view), including the gestures added from inside the streamview.
    
    if([self isFirstStreaming]) [self popFirstStreamingTip];

#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    //[self configSwipeGestures]; // swipe & exit gesture configured here
    //[self configOscLayoutTool]; //_oscLayoutTapRecoginizer will be added or removed to the view here
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    // [_tipLabel setText:[LocalizationHelper localizedStringForKey:@"Tip: Swipe from screen edge to a certiain distance (configured by Swipe & Exit settings) to disconnect from your PC"]];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    [self startStreamOrEnterSelfHealIfOffline];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(oscLayoutClosed)
                                                 name:@"OscLayoutCloseNotification"
                                               object:nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    // TrueZhuanJia: Already fixed by my refactored keyboard toggle gesture recognizer, and the keyboardWillShow/Hide method in StreamView.m
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // for compatibility of iOS14 & lower
    self.view.backgroundColor = [UIColor systemGrayColor];
    _stageLabel.textColor = [UIColor systemGrayColor];
    _spinner.color = [UIColor systemGrayColor];
    
    self.view.backgroundColor = [ThemeManager appBackgroundColor];
    _stageLabel.textColor = [[ThemeManager textColor] colorWithAlphaComponent:0.9];
    _spinner.color = [ThemeManager textColor];
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
    [self applySnapToTopIfNeeded];
    
    // Create time and battery display
    [self createTimeBatteryDisplay];

    if ([_settings.renderingBackend intValue] == RENDER_METAL) {
        // Metal view for video
        Log(LOG_I, @"StreamFrameViewController creating MetalViewController");
        self.metalViewController = [[MetalViewController alloc] initWithFrame:self.view.bounds
                                                                    framerate:[self->_settings.framerate floatValue]
                                                                    settings:self->_settings
                                                               metricsHandler:self.imguiView.metricsHandler];
        self.metalViewController.view.userInteractionEnabled = NO;
        [self addChildViewController:self.metalViewController];
        // Insert Metal view at the bottom of the view hierarchy
        [self.view insertSubview:self.metalViewController.view atIndex:0];
        [self.metalViewController didMoveToParentViewController:self];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self->_streamView) {
        [self->_streamView endRightEdgeGestureSuppression];
    }
}

#pragma mark - Self-Heal Reconnect Guard

- (void)startStreamOrEnterSelfHealIfOffline {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithAddress:weakSelf.streamConfig.host httpsPort:weakSelf.streamConfig.httpsPort serverCert:weakSelf.streamConfig.serverCert];
        ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        BOOL online = [serverInfoResp isStatusOk];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!online) {
                [self beginSelfHealReconnectLoopWithOverlay:YES];
            } else {
                [self startStreamManager];
            }
        });
    });
}

- (void)startStreamManager {
    if (_streamMan != nil) return;
    _hasConnectionStarted = NO;
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamVideoRenderView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
}

- (void)beginSelfHealReconnectLoopWithOverlay:(BOOL)showOverlay {
    if (_reconnectTimer != nil) return;
    if (showOverlay) {
        [self showAutoEnterToastLikeMainWithText:[LocalizationHelper localizedStringForKey:@"Host offline. Retrying..."]];
    }
    _reconnectElapsedSeconds = 0;
    _reconnectProbeTick = 0;
    __weak typeof(self) weakSelf2 = self;
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        typeof(self) selfRef = weakSelf2;
        if (!selfRef) { [timer invalidate]; return; }
        selfRef->_reconnectElapsedSeconds += 1.0;
        selfRef->_reconnectProbeTick++;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HttpManager* hMan = [[HttpManager alloc] initWithAddress:selfRef.streamConfig.host httpsPort:selfRef.streamConfig.httpsPort serverCert:selfRef.streamConfig.serverCert];
            ServerInfoResponse* resp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resp withUrlRequest:[hMan newServerInfoRequest:false]
                                                                fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            BOOL online = [resp isStatusOk];
            if (online) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [selfRef stopSelfHealReconnectLoop];
                    [selfRef updateAutoEnterToastLabel:[LocalizationHelper localizedStringForKey:@"Connecting..."]];
                    [selfRef startStreamManager];
                });
            }
        });
    }];
}

- (void)stopSelfHealReconnectLoop {
    [_reconnectTimer invalidate];
    _reconnectTimer = nil;
    _reconnectElapsedSeconds = 0;
    _reconnectProbeTick = 0;
    [self hideAutoEnterToastLikeMain];
}

- (void)cancelSelfHealAndReturnToMain {
    [self stopSelfHealReconnectLoop];
    [self returnToMainFrame];
}

#pragma mark - Main-like AutoEnter Toast in Stream VC

- (void)showAutoEnterToastLikeMainWithText:(NSString *)text {
    if (_autoEnterToast != nil) return;
    _autoEnterToast = [[UIView alloc] init];
    _autoEnterToast.translatesAutoresizingMaskIntoConstraints = NO;
    _autoEnterToast.backgroundColor = [UIColor whiteColor];
    _autoEnterToast.layer.cornerRadius = 12.0;
    _autoEnterToast.layer.shadowColor = [UIColor blackColor].CGColor;
    _autoEnterToast.layer.shadowOpacity = 0.15;
    _autoEnterToast.layer.shadowRadius = 8.0;
    _autoEnterToast.layer.shadowOffset = CGSizeMake(0, 2);

    _autoEnterLabel = [[UILabel alloc] init];
    _autoEnterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _autoEnterLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    _autoEnterLabel.textColor = [UIColor blackColor];
    _autoEnterLabel.text = text ?: @"";

    _autoEnterCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _autoEnterCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_autoEnterCancelButton setTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] forState:UIControlStateNormal];
    _autoEnterCancelButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_autoEnterCancelButton addTarget:self action:@selector(cancelSelfHealAndReturnToMain) forControlEvents:UIControlEventTouchUpInside];

    [_autoEnterToast addSubview:_autoEnterLabel];
    [_autoEnterToast addSubview:_autoEnterCancelButton];
    [self.view addSubview:_autoEnterToast];

    UILayoutGuide *guide;
    if (@available(iOS 11.0, *)) { guide = self.view.safeAreaLayoutGuide; }

    [NSLayoutConstraint activateConstraints:@[
        [_autoEnterToast.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [_autoEnterToast.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],
        [_autoEnterToast.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-20],

        [_autoEnterLabel.topAnchor constraintEqualToAnchor:_autoEnterToast.topAnchor constant:12],
        [_autoEnterLabel.leadingAnchor constraintEqualToAnchor:_autoEnterToast.leadingAnchor constant:16],
        [_autoEnterLabel.bottomAnchor constraintEqualToAnchor:_autoEnterToast.bottomAnchor constant:-12],

        [_autoEnterCancelButton.centerYAnchor constraintEqualToAnchor:_autoEnterLabel.centerYAnchor],
        [_autoEnterCancelButton.trailingAnchor constraintEqualToAnchor:_autoEnterToast.trailingAnchor constant:-16]
    ]];
}

- (void)hideAutoEnterToastLikeMain {
    [_autoEnterToast removeFromSuperview];
    _autoEnterToast = nil;
    _autoEnterLabel = nil;
    _autoEnterCancelButton = nil;
}

- (void)updateAutoEnterToastLabel:(NSString *)text {
    if (_autoEnterLabel) {
        _autoEnterLabel.text = text ?: @"";
    }
}

- (void)keyboardWillShow:(NSNotification *)notification{
    [_streamView keyboardWillShow:notification];
}

- (void)keyboardWillHide{
    [_streamView keyboardWillHide];
}

- (void)handleWidgetLayoutGesture{
    [self configOscLayoutTool];
    [self openWidgetLayoutTool];
}

- (void)openWidgetLayoutTool{
    _streamView.widgetToolOpened = true;
    [self->_streamView disableOnScreenControls];
    [self->_streamView clearOnScreenWidgets]; // clear all onScreenKeyboardButtons before entering edit mode
    _layoutOnScreenControlsVC.toolbarStackView.hidden = false;
    _layoutOnScreenControlsVC.toolbarRootView.hidden = false;
    [self presentViewController:_layoutOnScreenControlsVC animated:YES completion:nil];
}


- (void)bringUpSoftKeyboard{
    [self->_streamView readyToBringUpSoftKeyboardByToolbox];
}

- (void)enterPip{
    [self.pipController startPictureInPicture];
}

- (void)oscLayoutClosed{
    // Handle the callback
    _streamView.widgetToolOpened = false;
    [self->_streamView disableOnScreenControls]; // add this to get realtime back menu working.
    [self->_streamView reloadOnScreenControlsWith:(ControllerSupport*)_controllerSupport
                                        andConfig:(StreamConfiguration*)_streamConfig];
    [self->_streamView showOnScreenControls];
    [self->_streamView reloadOnScreenWidgetViews]; //update keyboard buttons here
}

- (void)setUserInteractionEnabledForStreamView:(bool)enabled{
    _streamView.userInteractionEnabled = enabled;
    for(UIView* view in self.view.subviews){
        if([view isKindOfClass:[OnScreenWidgetView class]]) view.userInteractionEnabled = enabled;
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        //NSLog(@"gyro cleanup, count: %ld", _controller.count);
        [_controllerSupport cleanup];

        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        if (_timeBatteryUpdateTimer != nil) {
            [_timeBatteryUpdateTimer invalidate];
            _timeBatteryUpdateTimer = nil;
        }
        if (self.metalViewController) {
            [self.metalViewController.view removeFromSuperview];
            [self.metalViewController removeFromParentViewController];
            self.metalViewController = nil;
            NSLog(@"Metal renderer stopped and cleaned up.");
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    if(!_settings.statsOverlayEnabled){
        [_overlayView removeFromSuperview];
        // Invalidate the timer when stats overlay is disabled
        if (_statsUpdateTimer) {
            [_statsUpdateTimer invalidate];
            _statsUpdateTimer = nil;
        }
        return; // add this for realtime streamview reconfig
    }
    
    // Only add the overlay if it's not already in the view hierarchy
    if (_overlayView.superview == nil) {
        [self.view addSubview:_overlayView];
    }

    NSString* overlayText = [self->_streamMan getStatsOverlayText:overlayLevel];
                             
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[PaddedLabel alloc] initWithFrame:CGRectZero];
        [_overlayView setTextInsets:UIEdgeInsetsMake(10, 15, 10, 15)];
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setNumberOfLines:100];
        [_overlayView.layer setCornerRadius:12];
        [_overlayView.layer setMasksToBounds:YES];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24 weight:UIFontWeightMedium]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium]];

#endif
        [_overlayView setAlpha:(float)[_settings.graphOpacity intValue]/ 100.0];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, (12 + (_overlayView.frame.size.height / 2)))];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    if (@available(iOS 13.0, *)) {
        [SceneDelegate clearExternalDisplayRenderView];
    }

    if (_settings.enablePIP) {
        [self cleanupPiPController];
    }

    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    [_timeBatteryUpdateTimer invalidate];
    _timeBatteryUpdateTimer = nil;
    
    // Mark one-shot suppression to avoid immediate auto-enter after manual exit
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AutoEnterSuppressOnce"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.navigationController popToRootViewControllerAnimated:NO];
    
    _extWindow = nil;
    
    self.mainFrameViewcontroller.settingsExpandedInStreamView = false; // reset this flag to false
}

// External Screen connected
- (void)extScreenDidConnect:(NSNotification *)notification {
    Log(LOG_I, @"External Screen Connected");
    if ([self isAirPlayEnabled] && [notification.object isKindOfClass:[UIScreen class]]) {
        // UIScreen *extScreen = (UIScreen *)notification.object;
        if (_streamVideoRenderView) {
             // Remove from current superview before passing it
             [_streamVideoRenderView removeFromSuperview];
             if (@available(iOS 13.0, *)) {
                 [SceneDelegate setExternalDisplayRenderView:_streamVideoRenderView];
             }
             NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
             [nc postNotificationName:@"ScreenChanged" object:self];
             // 外接屏切换后，按方向应用锁定
             [self osc_applyLockForCurrentOrientationInStreamingIfNeeded];
        } else {
             Log(LOG_W, @"_streamVideoRenderView is nil when external screen connected.");
        }
    }
}

// External Screen disconnected
- (void)extScreenDidDisconnect:(NSNotification *)notification {
    Log(LOG_I, @"External Screen Disconnected");
    if(UIScreen.screens.count < 2) {
        if (@available(iOS 13.0, *)) {
            [SceneDelegate clearExternalDisplayRenderView];
        }
        // Add the render view back to the local StreamView if AirPlay was active
        if ([self isAirPlayEnabled]) {
            if (_streamVideoRenderView && _streamView) {
                [_streamView insertSubview:_streamVideoRenderView atIndex:0];
                [self handleViewResize]; // Adjust frames as needed
            }
        }
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc postNotificationName:@"ScreenChanged" object:self]; // Your existing notification
        // 外接屏断开后，按方向应用锁定
        [self osc_applyLockForCurrentOrientationInStreamingIfNeeded];
    }
}

- (bool)shallDisableGyroHotSwitch{
    return _controllerSupport.shallDisableGyroHotSwitch;
}

- (BOOL) isAirPlaying{
    if (_settings.externalDisplayMode.intValue == 1 && _streamVideoRenderView) {
        return _streamVideoRenderView.hidden;
    }
    return NO;
}

- (BOOL) isAirPlayEnabled{
    return _settings.externalDisplayMode.intValue == 1;
}

- (void) reloadAirPlayConfig{
    if (UIScreen.screens.count == 1){return;}
    if (![self isAirPlaying] && [self isAirPlayEnabled]){
        if (@available(iOS 13.0, *)) {
            [SceneDelegate setExternalDisplayRenderView:_streamVideoRenderView];
        }
    }else if ([self isAirPlaying] && ![self isAirPlayEnabled]){
        if (@available(iOS 13.0, *)) {
            [SceneDelegate clearExternalDisplayRenderView];
        }
    }
}

- (void) handleViewResize{
    viewIsBeingResized = true;
    _streamView.bounds = _deviceWindow.bounds;
    _streamView.frame = _deviceWindow.frame;
    if(![self isAirPlaying]){
        _streamVideoRenderView.bounds = _deviceWindow.bounds;
        _streamVideoRenderView.frame = _deviceWindow.frame;

        // Handle resize for meetal renderer
        if ([_settings.renderingBackend intValue] == RENDER_METAL && self.metalViewController) {
            self.metalViewController.view.frame = _deviceWindow.bounds;
            [self.metalViewController.view setNeedsLayout];
            [self.metalViewController.view layoutIfNeeded];
            Log(LOG_I, @"Updated Metal view bounds after resize");
        }
        
        // Handle resize for AVSB renderer
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc postNotificationName:@"ScreenChanged" object:self];
        // 尺寸改变时应用锁定
        [self osc_applyLockForCurrentOrientationInStreamingIfNeeded];
    }
    [self reConfigStreamViewRealtime];
    
    // Update time and battery display layout after resize
    [self updateTimeBatteryDisplay];
    
    // Update button layout after resize
    [self updateSnapRatioButton];
}


// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    //[self.pipController startPictureInPicture];
    //sleep(1);

#if !TARGET_OS_TV
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

    // Check if we were in PiP
    if (self.pipController && self.pipController.isPictureInPictureActive) {
        [self.pipController stopPictureInPicture];
    }
    
    if ([_settings.renderingBackend intValue] == RENDER_METAL && self.metalViewController) {
        Log(LOG_I, @"Resuming Metal renderer on foreground");
        [self.metalViewController resumeRendering];
    }
    
    if (self.imguiView && self.imguiView.mtkView && _settings.enableGraphs) {
        self.imguiView.mtkView.enableSetNeedsDisplay = YES;
        self.imguiView.mtkView.paused = NO;
        Log(LOG_I, @"Resuming ImGui renderer on foreground");
    }
    
    [self->_streamMan.videoRenderer resetFramePacing];
    _isRestoringFromPiP = NO;
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {

    NSLog(@"did enter background, %d, %@, %d", _settings.enablePIP, self.pipController, self.pipController.isPictureInPictureActive);
    if (_settings.enablePIP && self.pipController && self.pipController.isPictureInPictureActive) {
        //Log(LOG_I, @"PIP is active, not terminating stream");
    } else {
        if ([_settings.renderingBackend intValue] == RENDER_METAL && self.metalViewController) {
            Log(LOG_I, @"Pausing Metal renderer on background");
            [self.metalViewController pauseRendering];
        }
        
        if (self.imguiView && self.imguiView.mtkView) {
            self.imguiView.mtkView.paused = YES;
            self.imguiView.mtkView.enableSetNeedsDisplay = NO;
            Log(LOG_I, @"Pausing ImGui renderer on background");
        }
    }

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

    // Terminate the stream if the app is inactive for ...
    Log(LOG_I, @"Starting inactivity termination timer with %d min", _settings.backgroundSessionTimer.intValue);
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60*(double)_settings.backgroundSessionTimer.intValue
                                  target:self
                                selector:@selector(inactiveTimerExpired:)
                                userInfo:nil
                                 repeats:NO];

#if !TARGET_OS_TV

#endif
}

- (void)expandSettingsView{
    self.mainFrameViewcontroller.settingsExpandedInStreamView = true; //notify mainFrameViewContorller that this is a setting expansion in stream view, some settings shall be disabled.
    [self.mainFrameViewcontroller expandSettingsView];
}

- (void)edgeSwiped{
    /*
    if([self->_mainFrameViewcontroller isIPhonePortrait]){ // disable backmenu for iphone portrait mode;
        [self returnToMainFrame]; //directly quit the session
        return;
    } */
    [self expandSettingsView];  // expand settings view in other cases;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _rightEdgeToggleOscRecognizer) {
        CustomEdgeSlideGestureRecognizer *edgeRecognizer = (CustomEdgeSlideGestureRecognizer *)gestureRecognizer;
        CGPoint location = [touch locationInView:gestureRecognizer.view];
        CGRect bounds = gestureRecognizer.view.bounds;
        CGFloat tolerance = MAX(edgeRecognizer.EDGE_TOLERANCE, 24.0f);
        BOOL withinEdge = NO;

        if (edgeRecognizer.edges & UIRectEdgeRight) {
            withinEdge = location.x >= (CGRectGetMaxX(bounds) - tolerance);
        } else if (edgeRecognizer.edges & UIRectEdgeLeft) {
            withinEdge = location.x <= tolerance;
        } else if (edgeRecognizer.edges & UIRectEdgeTop) {
            withinEdge = location.y <= tolerance;
        } else if (edgeRecognizer.edges & UIRectEdgeBottom) {
            withinEdge = location.y >= (CGRectGetMaxY(bounds) - tolerance);
        }

        if (!withinEdge) {
            return NO;
        }

        [self->_streamView beginRightEdgeGestureSuppressionForTouch:touch];
    }
    return YES;
}

- (void)edgeSlideGesture:(CustomEdgeSlideGestureRecognizer *)recognizer didFinishWithSuccess:(BOOL)success {
    [self->_streamView endRightEdgeGestureSuppression];
}

- (void)handleRightEdgeToggle:(CustomEdgeSlideGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self toggleOscVisibility];
    }
}

- (void)toggleOscVisibility{
    // Avoid interference when widget layout tool is open
    if (self->_streamView.widgetToolOpened) {
        return;
    }
    OnScreenControlsLevel current = [self->_streamView getCurrentOscState];
    BOOL obscured = [self->_streamView isOscObscuredByAlpha];
    
    // If OSC is completely off, right swipe should do nothing
    // Only ON/OFF button can turn it back on
    if (current == OnScreenControlsLevelOff) {
        return;
    }
    
    // Only handle transparency changes when OSC is actually enabled
    if (obscured) {
        // Currently hidden by alpha -> show
        [self->_streamView setOscObscuredByAlpha:NO];
        [self setWidgetsHidden:NO];
    } else {
        // Currently shown -> hide by alpha
        [self->_streamView setOscObscuredByAlpha:YES];
        [self setWidgetsHidden:YES];
    }
    // Do NOT update button title - right swipe should not affect ON/OFF button state
}

// Make on-screen widgets visually transparent but still interactive
- (void)setWidgetsHidden:(BOOL)hidden {
    // Use a near-zero alpha to keep hit-testing enabled (UIKit ignores alpha < 0.01)
    CGFloat targetAlpha = hidden ? 0.02f : 1.0f;
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        for (UIView *widgetView in self.view.subviews) {
            if ([widgetView isKindOfClass:[OnScreenWidgetView class]]) {
                widgetView.alpha = targetAlpha;
                widgetView.userInteractionEnabled = YES;
            }
        }
    } completion:nil];
    // Inform Swift side (OnScreenWidgetView) to enable per-button highlight when obscured
    [OnScreenWidgetView setObscuredByAlpha:hidden];
}

- (void)disconnectRemoteSession {
    Log(LOG_I, @"Settings view disconnect the session in stream view");
    [self returnToMainFrame];
    
}

- (void)disconnectAndQuitApp{
    [self returnToMainFrame];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        sleep(1.5);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.mainFrameViewcontroller quitRunningApp];
        });
    });
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_hasConnectionStarted = YES;
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        self->_spinner.hidden = YES;
        
        // Ensure correct view hierarchy before showing OSC
        if ([self->_settings.renderingBackend intValue] == RENDER_METAL && self.metalViewController) {
            [self.view sendSubviewToBack:self.metalViewController.view];
        }
        // For AVSB renderer, ensure streamView is at the back so OSC layers show
        if (self->_streamView && self->_streamView.superview) {
            [self.view sendSubviewToBack:self->_streamView];
        }
        
        [self->_streamView showOnScreenControls];
        
        // 串流连接建立后，应用当前屏幕方向的方向锁定
        [self osc_applyLockForCurrentOrientation];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlayEnabled) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
        
        // Start time and battery update timer (update every minute)
        self->_timeBatteryUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:60.0f
                                                                         target:self
                                                                       selector:@selector(updateTimeBatteryDisplay)
                                                                       userInfo:nil
                                                                        repeats:YES];
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = [LocalizationHelper localizedStringForKey:@"Connection Error"];
            message = @"Your device's session connection is being blocked. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = [LocalizationHelper localizedStringForKey:@"Connection Error"];
                    message = [LocalizationHelper localizedStringForKey:@"No video received from host."];
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[LocalizationHelper localizedStringForKey:@"ConnectionFailedFirewall", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = [LocalizationHelper localizedStringForKey:@"Connection Error"];
                    message = [LocalizationHelper localizedStringForKey: @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection."];
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = [LocalizationHelper localizedStringForKey:@"Connection Error"];
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = [LocalizationHelper localizedStringForKey:@"Connection Error"];
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = [LocalizationHelper localizedStringForKey: @"Connection Terminated"];
                    message = [LocalizationHelper localizedStringForKey: @"The connection was terminated, Error code: %@", errorString];
                    break;
                }
            }
        }
        
        // For offline/network class errors, self-heal instead of blocking
        if (portFlags != 0 || errorCode == ETIMEDOUT || errorCode == ECONNREFUSED) {
            [self updateOverlayText:[LocalizationHelper localizedStringForKey:@"Host offline. Retrying..."]];
            [self beginSelfHealReconnectLoopWithOverlay:NO];
        } else {
            UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                                  message:message
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [Utils addHelpOptionToDialog:conTermAlert];
            [conTermAlert addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                [self returnToMainFrame];
            }]];
            [self presentViewController:conTermAlert animated:YES completion:nil];
        }
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s ...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[LocalizationHelper localizedStringForKey:@"ConnectionFailedFirewall", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:[LocalizationHelper localizedStringForKey:@"!ML_TEST_RESULT_INCONCLUSIVE"]];
        }
        
        // For offline/network/timeout-like failures, enter self-heal instead of blocking with alert
        if (portTestFlags != 0 || errorCode == ETIMEDOUT || errorCode == ECONNREFUSED) {
            [self updateOverlayText:[LocalizationHelper localizedStringForKey:@"Host offline. Retrying..."]];
            [self beginSelfHealReconnectLoopWithOverlay:NO];
        } else {
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Connection Failed"]
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [Utils addHelpOptionToDialog:alert];
            [alert addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                [self returnToMainFrame];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Connection Error"]
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:[LocalizationHelper localizedStringForKey:@"Slow connection to PC, Reduce your bitrate"]];
                }
                else {
                    [self updateOverlayText:[LocalizationHelper localizedStringForKey:@"Poor connection to PC"]];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_spinner stopAnimating];
        [self.view setBackgroundColor:[UIColor blackColor]];

        if (@available(iOS 15.0, *)) {
            if (self->_settings.enablePIP) {
                if (self->_streamMan && self->_streamMan.videoRenderer) {
                    Log(LOG_I, @"Setting up PiP with renderer: %p", self->_streamMan.videoRenderer);
                    [self setupPiPControllerWithRenderer:self->_streamMan.videoRenderer];
                } else {
                    Log(LOG_I, @"No renderer available for PiP setup");
                }
            }
        }
    });
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)toggleStatsOverlay{
    // Toggle the values on the current in-memory settings object for a temporary effect
    _settings.statsOverlayEnabled = !_settings.statsOverlayEnabled;
    _settings.enableGraphs = _settings.statsOverlayEnabled;
    
    // Reconfigure the UI using the current in-memory settings, without reloading from disk
    [self reConfigStreamViewRealtimeAndReloadSettings:NO];
}

- (void)toggleMouseCapture{
    DataManager* dataMan = [[DataManager alloc] init];
    Settings *currentSettings = [dataMan retrieveSettings];
    
    if(currentSettings.localMousePointerMode.intValue == 0){
        currentSettings.localMousePointerMode = @1;
    }else{
        currentSettings.localMousePointerMode = @0;
    }
    
    
    [dataMan saveData];
    [self reConfigStreamViewRealtime];
}

- (void)toggleMouseVisible{
    DataManager* dataMan = [[DataManager alloc] init];
    Settings *currentSettings = [dataMan retrieveSettings];
    
    if(currentSettings.localMousePointerMode.intValue == 2){
        currentSettings.localMousePointerMode = @1;
    }else{
        currentSettings.localMousePointerMode = @2;
    }
    
    [dataMan saveData];
    [self reConfigStreamViewRealtime];
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
        /* Turnoff the fullscreen mode
    if ( [_controllerSupport getConnectedGamepadCount] > 0 && [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;*/
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return ([GCMouse mice].count > 0) && [_settings localMousePointerMode].intValue == 0;
}
#endif

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    if (_isRestoringFromPiP) {
        Log(LOG_I, @"View size changed during PiP restore, skipping redundant reconfiguration.");
        return;
    }

    Log(LOG_I, @"View size changed, terminating stream");
    
    double delayInSeconds = 0.2;
    if (_delayedRemoveExtScreen) {
        dispatch_block_cancel(_delayedRemoveExtScreen);
    }
    dispatch_block_t block = dispatch_block_create(0, ^{
        [self handleViewResize];
        [self applySnapToTopIfNeeded];
        // Update time and battery display layout after rotation
        [self updateTimeBatteryDisplay];
        // 通知编辑界面优先应用方向锁定（其内部会重载UI）
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc postNotificationName:@"ScreenChanged" object:self];
    });
    _delayedRemoveExtScreen = block;
    dispatch_time_t delayTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(delayTime, dispatch_get_main_queue(), block);
}

@end
