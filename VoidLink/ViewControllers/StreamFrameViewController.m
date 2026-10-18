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
#import "StreamLetterboxDetector.h"
#import "FrameQueue.h"
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

#if !TARGET_OS_TV
@interface StreamFrameViewController () <UIPickerViewDataSource, UIPickerViewDelegate>
@end
#endif


@interface StreamFrameViewController () <StreamLetterboxDetectorDelegate>
@end

// What "hide the OSC" means. Auto follows the letterbox detector (game ->
// translucent but tappable, desktop -> fully off so touch drives the mouse);
// Game / Desk are per-session manual overrides from the bottom-right button.
typedef NS_ENUM(NSInteger, OscHideMode) {
    OscHideModeAuto = 0,
    OscHideModeGame,
    OscHideModeDesk,
};

typedef NS_ENUM(NSInteger, StreamCountdownState) {
    StreamCountdownStateIdle = 0,
    StreamCountdownStateRunning,
    StreamCountdownStatePaused,
    StreamCountdownStateFinished,
};

static NSString* VLTerminationHintForErrorCode(int errorCode) {
    switch (errorCode) {
        case ML_ERROR_CONTROL_DISCONNECT_TIMEOUT:
            return @"Timeout type: control disconnect timeout.\nThe control stream started disconnecting, but the final disconnect event never arrived before the timeout expired.";
        case ML_ERROR_CONTROL_UNEXPECTED_DISCONNECT:
            return @"Timeout type: enet peer timeout disconnect / unexpected control stream disconnect.\nThe established control stream was dropped by ENet or the host/network unexpectedly.";
        case -1:
            return @"Possible causes:\n- control disconnect timeout\n- enet peer timeout disconnect\n- unexpected control stream disconnect\n- video receive socket failure\n- audio receive socket failure\n- input send socket failure\n- control message send/ack failure\n- loss stats/control buffer malloc failure\n- video buffer malloc failure\n- audio packet malloc failure\n- unknown socket failure";
        case ETIMEDOUT:
            return @"Timeout type: socket or control channel timeout.";
        case ECONNRESET:
            return @"Possible cause: the host or network reset the connection.";
        case EPIPE:
            return @"Possible cause: write failed because the peer closed the connection.";
        case ECONNABORTED:
            return @"Possible cause: the local network stack aborted the connection.";
        case ENETDOWN:
            return @"Possible cause: the local network interface went down.";
        case ENETUNREACH:
            return @"Possible cause: the network became unreachable.";
        case EHOSTUNREACH:
            return @"Possible cause: the host became unreachable.";
        case ENOBUFS:
            return @"Possible cause: the network stack ran out of buffer space.";
        case ENOMEM:
            return @"Possible cause: memory allocation failed.";
        default:
            return nil;
    }
}


// Bottom chrome capsule: an optional low-rate blurred backdrop image (from
// StreamBackdropBlur) under a fixed black tint. Without an image it is just
// the tint, which is also what it looks like over black letterbox bars.
@interface VoidBackdropCapsuleView : UIView
- (void)setBackdropImage:(nullable CGImageRef)image;
@end

@implementation VoidBackdropCapsuleView {
    CALayer *_imageLayer;
    CALayer *_tintLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        _imageLayer = [CALayer layer];
        // The image is a few pixels per capsule; linear magnification is the
        // last smoothing step of the blur.
        _imageLayer.contentsGravity = kCAGravityResize;
        _imageLayer.magnificationFilter = kCAFilterLinear;
        _imageLayer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
        [self.layer addSublayer:_imageLayer];
        _tintLayer = [CALayer layer];
        _tintLayer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4].CGColor;
        _tintLayer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};
        [self.layer addSublayer:_tintLayer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2.0f;
    _imageLayer.frame = self.bounds;
    _tintLayer.frame = self.bounds;
}

// contents keeps its implicit animation: about once a second the new sample
// cross-fades in instead of popping.
- (void)setBackdropImage:(CGImageRef)image {
    _imageLayer.contents = (__bridge id)image;
}
@end

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    CADisplayLink *_dummyEventLink;
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
    UIView *_countdownHitAreaView;
    PaddedLabel *_countdownLabel;
    NSTimer *_streamCountdownUpdateTimer;
    StreamCountdownState _streamCountdownState;
    NSTimeInterval _streamCountdownDurationSeconds;
    NSTimeInterval _streamCountdownRemainingSeconds;
    NSDate *_streamCountdownEndDate;
    BOOL _streamCountdownFinishFeedbackShown;
    UIView *_streamCountdownEdgeGlowView;
#if !TARGET_OS_TV
    UIPickerView *_streamCountdownDurationPicker;
#endif
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
    // Set once the user leaves the stream page (returnToMainFrame / teardown).
    // Async probe completions check this so they never start a StreamManager or
    // a self-heal loop on a popped view controller (zombie session).
    BOOL _hasLeftStreamPage;
    BOOL _hasConnectionStarted;
    // Set when connectionTerminated/stageFailed reported an abnormal end. Blocks
    // clearing the dirty-session flag at teardown: after an abnormal end the host
    // may hold a zombie gamepad slot, so the next session must still reattach.
    BOOL _connectionEndedAbnormally;
    // Background graceful-stop machinery. Once iOS suspends the app, the ENet
    // disconnect can never be delivered: the host keeps a zombie session (and
    // its gamepad slot) alive for the full ping timeout, and a quick resume
    // then streams into the wrong pad slot. So after entering background we
    // keep the stream alive briefly (seamless quick switch-back), then tear it
    // down gracefully while the background task still grants us CPU.
    UIBackgroundTaskIdentifier _bgGracefulStopTask;
    NSUInteger _bgStopEpoch;
    // Writes VoidStreamLastAliveAt every 2s while the connection is healthy.
    // The next session reads it to compute when the host's zombie-session
    // window (ping timeout) ends, so gamepad reattach can fire at the
    // earliest moment slot 0 is winnable instead of on a blind schedule.
    NSTimer *_sessionHeartbeatTimer;
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
    CustomEdgeSlideGestureRecognizer *_rightEdgeOverControlRecognizer;
    CustomTapGestureRecognizer *_oscLayoutTapRecoginizer;
    LayoutOnScreenControlsViewController *_layoutOnScreenControlsVC;
    ToolboxViewController* toolBoxViewController;
    UIControl *_toolboxOverlay;
#pragma mark Snap ratio button
    UIButton *_snapRatioButton;
    UIButton *_oscModeButton;
    UIButton *_rotationLockToggleButton;
    UIButton *_gyroToggleButton;
    // Bottom-right quick menu: a blank capsule in the corner that pops a
    // horizontal panel of host shortcuts above itself.
    UIButton *_quickMenuButton;
    VoidBackdropCapsuleView *_toggleRowBackground; // one capsule behind OSC/snap/gyro/rot
    VoidBackdropCapsuleView *_quickMenuBackdrop;   // behind the quick menu button
    UIView *_quickMenuPanel;
    UIControl *_quickMenuDismissCatcher;
    // Logical open state (the panel may still be attached while fading out);
    // the token invalidates a stale close-animation completion on reopen.
    BOOL _quickMenuOpen;
    NSUInteger _quickMenuToken;
    // OSC mode button hold: while the finger is down (and the OSC is on) the
    // OSC is suspended so the other hand can drive the PC. A quick release with
    // no stream touch in between is still the plain mode-cycling tap.
    BOOL _oscHoldActive;
    CFTimeInterval _oscHoldStartTime;
    // OSC visibility model — see "OSC visibility & hide mode".
    BOOL _oscHidden;                         // right-edge swipe / detector
    OscHideMode _oscModeOverride;            // Auto unless the mode button was tapped this session
    StreamContentClass _oscDetectedContent;  // last debounced detector verdict
    BOOL _oscAutoDetectApplicable;           // stream aspect matches the screen (iPad-size host display)
    // Auto snap ratio — see "Snap ratio (16:9 / FULL)". Shares the detector
    // and its applicability with the OSC hide mode.
    BOOL _snapDetectedFits;                  // detector: content sits inside the centred 16:9 region
    SnapRatioOverride _snapRatioOverride;    // None unless the ratio button was tapped this session
    // Opaque black sheet behind the Metal video view. The Metal view is
    // shifted (snap-to-top / keyboard lift), and whatever it uncovers is
    // self.view's theme background — this keeps those regions letterbox-black
    // like the AVSampleBuffer path, where a full-screen video surface always
    // covered the back. Hidden until streaming is configured so the themed
    // loading screen keeps its look.
    UIView *_metalBackdropView;
#else
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
#endif

}

// MARK: - 方向锁定 持久化Key（与其它页面一致）
static NSString * const kOSCLockedPortraitProfileName = @"OSCLockedPortraitProfileName";
static NSString * const kOSCLockedLandscapeProfileName = @"OSCLockedLandscapeProfileName";
static NSString * const kStreamOrientationLockEnabledKey = @"streamOrientationLockEnabled";

BOOL gStreamOrientationLocked = NO;
UIInterfaceOrientationMask gStreamOrientationLockedMask = UIInterfaceOrientationMaskLandscape;

static NSString * const kStreamCountdownDurationSecondsKey = @"StreamCountdownDurationSeconds";
static NSString * const kStreamCountdownStateKey = @"StreamCountdownState";
static NSString * const kStreamCountdownEndDateKey = @"StreamCountdownEndDate";
static NSString * const kStreamCountdownRemainingSecondsKey = @"StreamCountdownRemainingSeconds";
static const NSTimeInterval kStreamCountdownDefaultDurationSeconds = 5 * 60;
static const NSTimeInterval kStreamCountdownMinimumDurationSeconds = 10;
static const NSTimeInterval kStreamCountdownMaximumDurationSeconds = (23 * 60 * 60) + (59 * 60);
static const NSInteger kStreamCountdownMaximumPickerMinutes = (23 * 60) + 59;
static const NSInteger kStreamCountdownPickerSecondStep = 10;
static const NSInteger kStreamCountdownPickerSecondRows = 6;

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
    // PiP is only functional on the AVSB backend (see videoContentShown)
    if(_settings.enablePIP && [_settings.renderingBackend intValue] == RENDER_AVSB){
        if(![toolBoxViewController.specialEntries containsObject:@"enterPip"]) [toolBoxViewController.specialEntries addObject:@"enterPip"];
    }
    else [toolBoxViewController.specialEntries removeObject:@"enterPip"];
    
    NSLog(@"toolBoxViewController.specialEntries %@", toolBoxViewController.specialEntries);
}

- (void)configOscLayoutTool{

    if([self isOscLayoutToolEnabled]){
        // Never rebuild the editor VC while it is being shown: replacing the ivar
        // mid-edit orphans the presented editor, and (worse) loading the new
        // instance's view would run its viewDidLoad, which repoints the
        // process-wide OSCProfilesManager widget set to the new instance's EMPTY
        // set — every subsequent save (including the auto-save on app resign)
        // would then silently drop all widgets from the profile.
        if (_layoutOnScreenControlsVC != nil && _layoutOnScreenControlsVC.presentingViewController != nil) {
            return;
        }
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
        // NOTE: do NOT touch _layoutOnScreenControlsVC.view here. Accessing .view
        // force-loads the view and runs viewDidLoad immediately (repointing the
        // static widget set, see above). The clear background this line used to set
        // now lives in the editor's own viewDidLoad.
        _layoutOnScreenControlsVC.modalPresentationStyle = UIModalPresentationOverCurrentContext;
    }
    //NSLog(@"in osc frameview gestures: %d", (uint32_t)[self.view.gestureRecognizers count]);
    //NSLog(@"in osc streamview gestures: %d", (uint32_t)[_streamView.gestureRecognizers count]);
}

- (void)presentToolboxViewController{
    [self quickMenu_dismissAnimated:NO];
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
    // Finger-only: Apple Pencil must stay fully interactive across the whole
    // screen, including the edge zones — it never opens the settings sidebar.
    _slideToSettingsRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
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
    // Finger-only: pencil never toggles the OSC, and — since shouldReceiveTouch is
    // what arms the right-edge gesture suppression — pencil touches near the right
    // edge can no longer freeze OSC/stream input either.
    _rightEdgeToggleOscRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _rightEdgeToggleOscRecognizer.delegate = self;
    _rightEdgeToggleOscRecognizer.edgeDelegate = self;
    // Right edge small gesture is standalone now; no dependency on Command Manager gesture
    [self.view addGestureRecognizer:_rightEdgeToggleOscRecognizer];

    // Second right-edge recognizer for touches that land ON a tap-style OSC control
    // (button widgets, legacy A/B/X/Y/L*/R*/start/select layers) inside the edge
    // strip. The passive recognizer above can't take those: it never cancels the
    // view's touches, so a swipe starting on R2 would both press R2 and toggle the
    // OSC. This one uses UIKit's delaysTouchesBegan — the control's touchesBegan is
    // withheld until the recognizer decides — and decides fast (see
    // CustomEdgeSlideGestureRecognizer.earlyDecision): a finger that starts sliding
    // inward at once is the edge gesture and the control never sees it; a finger
    // that rests, taps, or moves vertically hands the control its normal touch
    // sequence ~70ms late at most. Tap → control, drag → gesture, never both.
    _rightEdgeOverControlRecognizer = [[CustomEdgeSlideGestureRecognizer alloc] initWithTarget:self action:@selector(handleRightEdgeToggle:)];
    _rightEdgeOverControlRecognizer.edges = UIRectEdgeRight;
    _rightEdgeOverControlRecognizer.normalizedThresholdDistance = smallThreshold;
    _rightEdgeOverControlRecognizer.earlyDecision = YES;
    _rightEdgeOverControlRecognizer.delaysTouchesBegan = YES;
    _rightEdgeOverControlRecognizer.delaysTouchesEnded = NO;
    _rightEdgeOverControlRecognizer.cancelsTouchesInView = YES;
    _rightEdgeOverControlRecognizer.allowedTouchTypes = @[@(UITouchTypeDirect)];
    _rightEdgeOverControlRecognizer.delegate = self;
    _rightEdgeOverControlRecognizer.edgeDelegate = self;
    [self.view addGestureRecognizer:_rightEdgeOverControlRecognizer];
    
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
        if(!_scrollView) _scrollView = [[UIScrollView alloc] initWithFrame:self.view.frame];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
        [_scrollView.panGestureRecognizer setMaximumNumberOfTouches:2]; // reduce competing with keyboardToggleRecognizer in StreamView.
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        if(!_mainFrameViewcontroller.settingsExpandedInStreamView){
            // Add StreamView inside a UIScrollView for absolute mode
            [_scrollView addSubview:_streamView];
            // Insert at index 0 to ensure it doesn't cover OSC controls (CALayers)
            [self.view insertSubview:_scrollView atIndex:0];
        }
    }
    else{
        // Add streamView directly to self.view in other touch modes
        // Insert at index 0 to ensure it doesn't cover OSC controls (CALayers)
        if([_streamView.superview isKindOfClass:[UIScrollView class]]){
            [_streamView removeFromSuperview];
        }
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

    // The reloads above re-apply the OSC presentation inside StreamView; bring
    // the bottom chrome and the mode button back in sync with it.
    [self osc_applyPresentation];
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
    [self restartTimeBatteryUpdateTimer];
    
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
    // Black backdrop goes bottom-most; streaming is configured now, so it can
    // take over from the themed loading background.
    if (_metalBackdropView && _metalBackdropView.superview) {
        [self.view sendSubviewToBack:_metalBackdropView];
        _metalBackdropView.hidden = NO;
    }
    // ImGui view should be on top for debug graphs
    if (self.imguiView && self.imguiView.mtkView.superview) {
        [self.view bringSubviewToFront:self.imguiView.mtkView];
    }

    [self startDummyEventLinkIfEnabled];

    NSLog(@"frameview gestures: %d", (uint32_t)[self.view.gestureRecognizers count]);
    NSLog(@"streamview gestures: %d", (uint32_t)[_streamView.gestureRecognizers count]);
    // Ensure ratio button is created/updated after reconfig
    [self updateSnapRatioButton];
    if (_timeLabel && _batteryLabel) {
        [self updateTimeBatteryDisplay];
    }
}

- (void)applySnapToTopIfNeeded {
    [self snap_syncOverrideToStreamView];
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    // An open keyboard's lift rides on top of whatever base is applied here;
    // originalFrame stays the unlifted frame so keyboardWillHide restores it.
    CGFloat keyboardLift = [_streamView activeKeyboardLift];
    if (!isPad || !_settings.snapScreenToTop) {
        // Restore to original position
        CGRect f = _streamView.frame;
        f.origin.y = -keyboardLift;
        _streamView.frame = f;
        f.origin.y = 0;
        _streamView.originalFrame = f;
        // Restore Metal view (currentSnapOffset is 0 when snap is off)
        [_streamView liftMetalVideoViewIfNeeded:keyboardLift];
        // Re-evaluate button visibility/layout (ratio button hides, the
        // OSC/ROT/GYRO toggles stay — they are not snap-specific)
        [self updateSnapRatioButton];
        return;
    }

    // Single source of truth for the offset — the same formula
    // liftMetalVideoViewIfNeeded uses as its base, so StreamView and the
    // Metal video view always shift by the exact same amount. (Passing the
    // offset into liftMetalVideoViewIfNeeded would double-apply it: its
    // parameter is the EXTRA lift on top of the snap base, e.g. keyboard.)
    CGFloat topBlackBar = [_streamView currentSnapOffset];

    // Move the entire StreamView up
    CGRect f = self.view.bounds;
    f.origin.y = -topBlackBar;
    _streamView.originalFrame = f; // so keyboard lift restores correctly
    f.origin.y = -topBlackBar - keyboardLift;
    _streamView.frame = f;

    // Metal view picks up the snap base internally; only the keyboard lift is extra
    [_streamView liftMetalVideoViewIfNeeded:keyboardLift];

    // Show/update ratio button
    [self updateSnapRatioButton];
}

// Fixed button width = widest candidate title + horizontal content insets.
// Keeps the bottom-right toggles from shifting when their title text changes
// (e.g. "OSC ON" <-> "OSC OFF"), while staying snug — no extra padding.
static CGFloat VoidFixedToggleWidth(UIButton *button, NSArray<NSString *> *titles) {
    CGFloat maxTextW = 0;
    NSDictionary *attrs = @{NSFontAttributeName: button.titleLabel.font};
    for (NSString *t in titles) {
        CGFloat w = [t sizeWithAttributes:attrs].width;
        if (w > maxTextW) maxTextW = w;
    }
    return ceil(maxTextW) + button.contentEdgeInsets.left + button.contentEdgeInsets.right;
}

static BOOL VoidGyroToggleEnabled(void) {
    id storedValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"forceGyroEnabled"];
    return storedValue == nil ? YES : [storedValue boolValue];
}

static BOOL VoidStreamOrientationLockEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kStreamOrientationLockEnabledKey];
}

- (BOOL)stream_orientationLockActive {
    return VoidStreamOrientationLockEnabled() && !self->_streamView.widgetToolOpened;
}

- (UIViewController *)stream_orientationRootViewController {
    UIViewController *root = self.view.window.rootViewController;
    if (!root) {
        root = self.navigationController.view.window.rootViewController;
    }
    if (!root) {
        root = self.presentingViewController;
    }
    return root ?: self;
}

- (void)stream_requestOrientationRefresh {
    UIViewController *root = [self stream_orientationRootViewController];
    if (@available(iOS 16.0, *)) {
        [root setNeedsUpdateOfSupportedInterfaceOrientations];
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

- (void)stream_publishOrientationLockAndRefresh {
    gStreamOrientationLocked = [self stream_orientationLockActive];
    if (gStreamOrientationLocked) {
        gStreamOrientationLockedMask = [self osc_lockedOrientationMask];
    }
    [self stream_requestOrientationRefresh];
}

- (void)stream_suspendOrientationLockAndRefresh {
    gStreamOrientationLocked = NO;
    [self stream_requestOrientationRefresh];
}

- (void)stream_updateOrientationLockButton {
    BOOL locked = VoidStreamOrientationLockEnabled();
    [_rotationLockToggleButton setTitle:(locked ? @"ROT LOCK" : @"ROT FREE") forState:UIControlStateNormal];
    _rotationLockToggleButton.accessibilityLabel = locked ? @"屏幕方向已锁定" : @"屏幕方向已解锁";
}

- (void)updateSnapRatioButton {
    if (!_snapRatioButton) {
        // Custom (not System) buttons: System buttons cross-fade their title
        // on setTitle:, which looks sluggish for these instant on/off toggles.
        _snapRatioButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _snapRatioButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_snapRatioButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.33] forState:UIControlStateNormal];
        [_snapRatioButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15] forState:UIControlStateHighlighted];
        _snapRatioButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [_snapRatioButton addTarget:self action:@selector(toggleSnapRatio) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_snapRatioButton];
    }
    
    // OSC hide-mode button (AUTO / GAME / DESK). Visibility itself is driven by
    // the right-edge swipe and the letterbox detector; this only picks what
    // "hidden" means.
    if (!_oscModeButton) {
        _oscModeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _oscModeButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_oscModeButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.33] forState:UIControlStateNormal];
        [_oscModeButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15] forState:UIControlStateHighlighted];
        _oscModeButton.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
        // Press-and-hold semantics (see oscModeTouchDown:) instead of a plain
        // TouchUpInside -> cycle.
        [_oscModeButton addTarget:self action:@selector(oscModeTouchDown:) forControlEvents:UIControlEventTouchDown];
        [_oscModeButton addTarget:self action:@selector(oscModeTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];
        [_oscModeButton addTarget:self action:@selector(oscModeTouchEnded:) forControlEvents:(UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
        // The holding finger must not count toward the stream's multi-finger
        // detection (2-finger right click / scroll, 3-finger keyboard, ...).
        [StreamView setMultiTouchExemptView:_oscModeButton];
        [self.view addSubview:_oscModeButton];
    }

    if (!_quickMenuButton) {
        _quickMenuButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _quickMenuButton.accessibilityLabel = @"快捷菜单";
        [_quickMenuButton addTarget:self action:@selector(quickMenu_toggle) forControlEvents:UIControlEventTouchUpInside];
        _quickMenuBackdrop = [[VoidBackdropCapsuleView alloc] initWithFrame:CGRectZero];
        [self.view addSubview:_quickMenuBackdrop];
        [self.view addSubview:_quickMenuButton];
    }

    if (!_rotationLockToggleButton) {
        _rotationLockToggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _rotationLockToggleButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_rotationLockToggleButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.33] forState:UIControlStateNormal];
        [_rotationLockToggleButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15] forState:UIControlStateHighlighted];
        _rotationLockToggleButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [_rotationLockToggleButton addTarget:self action:@selector(toggleStreamOrientationLock) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_rotationLockToggleButton];
    }

    // Persistent gyro on/off toggle — independent of any GYRO widget hold
    // gate. Stored in NSUserDefaults so the choice survives app restart.
    if (!_gyroToggleButton) {
        _gyroToggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _gyroToggleButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [_gyroToggleButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.33] forState:UIControlStateNormal];
        [_gyroToggleButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15] forState:UIControlStateHighlighted];
        _gyroToggleButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [_gyroToggleButton addTarget:self action:@selector(toggleGyroOnOff) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_gyroToggleButton];
    }

    if (!_toggleRowBackground) {
        _toggleRowBackground = [[VoidBackdropCapsuleView alloc] initWithFrame:CGRectZero];
        [self.view insertSubview:_toggleRowBackground belowSubview:_snapRatioButton];
    }

    // Update titles
    NSString *snapTitle = [self snap_effectiveRatioMode] == 0 ? @"16:9" : @"FULL";
    [_snapRatioButton setTitle:snapTitle forState:UIControlStateNormal];

    [_oscModeButton setTitle:[self osc_modeButtonTitle] forState:UIControlStateNormal];

    [self stream_updateOrientationLockButton];

    BOOL gyroForceOn = VoidGyroToggleEnabled();
    [_gyroToggleButton setTitle:(gyroForceOn ? @"GYRO ON" : @"GYRO OFF") forState:UIControlStateNormal];

    // The ratio button is snap-specific (it picks the snap target aspect),
    // so it hides when snap is off. The whole cluster is iPad-only, matching
    // the snap feature, and the toggles follow the OSC: when the OSC is hidden
    // (so the video can own the whole iPad-size screen) they go too.
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    BOOL chromeHidden = !isPad || _oscHidden;
    _snapRatioButton.hidden = chromeHidden || !_settings.snapScreenToTop;
    _oscModeButton.hidden = chromeHidden;
    _rotationLockToggleButton.hidden = chromeHidden;
    _gyroToggleButton.hidden = chromeHidden;
    _toggleRowBackground.hidden = chromeHidden;
    // The quick menu is the one control that stays put whatever the OSC does.
    _quickMenuButton.hidden = !isPad;
    _quickMenuBackdrop.hidden = !isPad;
    if (!isPad) [self quickMenu_dismissAnimated:NO];

    if (!isPad) {
        [self backdrop_updateRegions];
        return;
    }

    // Layout all buttons at bottom-right. Each gets a fixed width sized
    // to its widest possible title so toggling text never shifts neighbours.
    // Order, right -> left: quick menu (corner), osc mode, snap ratio (when
    // visible), gyro, rotation lock.
    CGFloat snapW = VoidFixedToggleWidth(_snapRatioButton, @[@"16:9", @"FULL"]);
    CGFloat oscW  = VoidFixedToggleWidth(_oscModeButton,  @[@"AUTO·GAME", @"AUTO·DESK", @"GAME", @"DESK"]);
    CGFloat rotationW = VoidFixedToggleWidth(_rotationLockToggleButton, @[@"ROT LOCK", @"ROT FREE"]);
    CGFloat gyroW = VoidFixedToggleWidth(_gyroToggleButton, @[@"GYRO ON", @"GYRO OFF"]);
    CGFloat btnH  = [self stream_bottomRowHeight];

    CGFloat baseY = [self stream_bottomRowCenterY] + btnH / 2.0f;
    CGFloat gap = 8;
    CGFloat rowPad = 4; // capsule overhang past the outermost toggles

    CGFloat menuW = round(btnH * 1.5) - 2;
    CGFloat menuX = self.view.bounds.size.width - 13 - menuW;
    _quickMenuButton.frame = CGRectMake(menuX, baseY - btnH, menuW, btnH);
    _quickMenuBackdrop.frame = _quickMenuButton.frame;
    [self quickMenu_layoutPanel];

    // The toggle row keeps its own anchor (where the menu's left edge used to
    // be) so menu size/inset tweaks don't drag it around.
    CGFloat rowRight = self.view.bounds.size.width - 15 - round(btnH * 1.5) - gap;
    CGFloat rightEdge = rowRight - rowPad;

    CGFloat oscX = rightEdge - oscW;
    _oscModeButton.frame = CGRectMake(oscX, baseY - btnH, oscW, btnH);
    _oscModeButton.layer.cornerRadius = btnH / 2.0f;
    rightEdge = oscX - gap;

    if (!_snapRatioButton.hidden) {
        CGFloat snapX = rightEdge - snapW;
        _snapRatioButton.frame = CGRectMake(snapX, baseY - btnH, snapW, btnH);
        rightEdge = snapX - gap;
    }

    CGFloat gyroX = rightEdge - gyroW;
    _gyroToggleButton.frame = CGRectMake(gyroX, baseY - btnH, gyroW, btnH);

    CGFloat rotationX = gyroX - gap - rotationW;
    _rotationLockToggleButton.frame = CGRectMake(rotationX, baseY - btnH, rotationW, btnH);

    CGFloat rowLeft = rotationX - rowPad;
    _toggleRowBackground.frame = CGRectMake(rowLeft, baseY - btnH, rowRight - rowLeft, btnH);
    [self backdrop_updateRegions];
}

// Shared geometry of the bottom chrome row: the right-hand toggles and the
// left-hand time/battery/countdown labels are centred on the same line.
- (CGFloat)stream_bottomRowHeight {
    UIFont *font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    return ceil(font.lineHeight) + 8; // toggle content insets: 4 top + 4 bottom
}

- (CGFloat)stream_bottomRowCenterY {
    return self.view.bounds.size.height - 12 - [self stream_bottomRowHeight] / 2.0f;
}

#pragma mark - Capsule backdrop blur

enum { kBackdropSlotToggleRow = 0, kBackdropSlotQuickMenu = 1 };

// Where the decoded picture is drawn, in self.view coordinates. AVSB: the
// display layer itself. Metal: the Metal view (shifted by snap / keyboard
// lift) with the picture aspect-fitted inside it.
- (CGRect)backdrop_videoRectInView {
    VideoDecoderRenderer *renderer = self->_streamMan.videoRenderer;
    if (!renderer) return CGRectNull;
    if ([_settings.renderingBackend intValue] == RENDER_METAL) {
        UIView *metalView = self.metalViewController.view;
        if (!metalView.superview) return CGRectNull;
        CGRect base = [self.view convertRect:metalView.bounds fromView:metalView];
        CGFloat aspect = renderer.streamAspectRatio;
        if (aspect <= 0 || base.size.width <= 0 || base.size.height <= 0) return CGRectNull;
        CGSize fit = (base.size.width / base.size.height > aspect)
            ? CGSizeMake(base.size.height * aspect, base.size.height)
            : CGSizeMake(base.size.width, base.size.width / aspect);
        return CGRectMake(CGRectGetMidX(base) - fit.width / 2.0f, CGRectGetMidY(base) - fit.height / 2.0f,
                          fit.width, fit.height);
    }
    CALayer *layer = renderer.displayLayer;
    if (!layer.superlayer) return CGRectNull;
    return [self.view.layer convertRect:layer.bounds fromLayer:layer];
}

// Recomputed on every bottom-chrome layout and detector verdict. A slot is
// sampled only while its capsule is on screen over the picture; over black
// letterbox bars (a game) the blurred result would be black anyway, so
// sampling pauses and the capsule falls back to the plain tint.
- (void)backdrop_updateRegions {
    VideoDecoderRenderer *renderer = self->_streamMan.videoRenderer;
    StreamBackdropBlur *blur = renderer.backdropBlur;
    if (!blur) return;
    if (!blur.imageHandler) {
        __weak typeof(self) weakSelf = self;
        __weak StreamBackdropBlur *weakBlur = blur;
        blur.imageHandler = ^(NSUInteger slot, CGImageRef image) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || weakBlur != self->_streamMan.videoRenderer.backdropBlur) return;
            [[self backdrop_viewForSlot:slot] setBackdropImage:image];
        };
    }

    BOOL letterboxed = (_oscDetectedContent == StreamContentClassGame);
    BOOL onScreen = [UIApplication sharedApplication].applicationState != UIApplicationStateBackground;
    CGRect video = [self backdrop_videoRectInView];
    BOOL anyActive = NO;
    for (NSUInteger slot = kBackdropSlotToggleRow; slot <= kBackdropSlotQuickMenu; slot++) {
        VoidBackdropCapsuleView *view = [self backdrop_viewForSlot:slot];
        CGRect r = view.frame;
        BOOL active = onScreen && renderer.providesDecodedFrames && view && !view.hidden && !letterboxed
            && !CGRectIsNull(video) && !CGRectIsEmpty(r) && CGRectContainsRect(CGRectInset(video, -1, -1), r);
        if (active) {
            CGRect norm = CGRectMake((r.origin.x - video.origin.x) / video.size.width,
                                     (r.origin.y - video.origin.y) / video.size.height,
                                     r.size.width / video.size.width,
                                     r.size.height / video.size.height);
            [blur setSlot:slot normalizedRect:norm pointSize:r.size];
            anyActive = YES;
        } else {
            [blur setSlot:slot normalizedRect:CGRectNull pointSize:CGSizeZero];
            [view setBackdropImage:NULL];
        }
    }
    blur.enabled = anyActive;
}

- (VoidBackdropCapsuleView *)backdrop_viewForSlot:(NSUInteger)slot {
    switch (slot) {
        case kBackdropSlotToggleRow: return _toggleRowBackground;
        case kBackdropSlotQuickMenu: return _quickMenuBackdrop;
        default: return nil;
    }
}

#pragma mark - Quick menu (bottom-right corner)

static const CGFloat kQuickMenuItemDiameter = 52;
static const CGFloat kQuickMenuPadding = 8;
static const CGFloat kQuickMenuSpacing = 12;

- (UIButton *)quickMenu_itemWithSymbol:(NSString *)symbol
                              fallback:(NSString *)fallback
                                 label:(NSString *)label
                                action:(SEL)action {
    UIButton *item = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:kQuickMenuItemDiameter weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:config];
    if (!image && fallback) image = [UIImage systemImageNamed:fallback withConfiguration:config];
    [item setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    // The *.circle.fill glyph is the button itself: stretch it to the
    // circular frame so all four read as same-size discs.
    item.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    item.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    item.imageView.contentMode = UIViewContentModeScaleAspectFit;
    item.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    item.layer.cornerRadius = kQuickMenuItemDiameter / 2.0f;
    item.accessibilityLabel = label;
    [item addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return item;
}

- (void)quickMenu_buildPanelIfNeeded {
    if (_quickMenuPanel) return;

    // Full-screen catcher under the panel: a touch anywhere else just closes
    // the menu instead of leaking into the stream as a click.
    _quickMenuDismissCatcher = [[UIControl alloc] initWithFrame:CGRectZero];
    _quickMenuDismissCatcher.backgroundColor = [UIColor clearColor];
    [_quickMenuDismissCatcher addTarget:self action:@selector(quickMenu_catcherTouched) forControlEvents:UIControlEventTouchDown];

    _quickMenuPanel = [[UIView alloc] initWithFrame:CGRectZero];
    _quickMenuPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    _quickMenuPanel.layer.cornerRadius = 16;
    _quickMenuPanel.clipsToBounds = YES;
    // Anchored at its bottom-right corner: layout pins that corner above the
    // menu button, and the open/close scale grows out of it.
    _quickMenuPanel.layer.anchorPoint = CGPointMake(1, 1);

    // Left -> right; "1" ends up nearest the corner button.
    NSArray<UIButton *> *items = @[
        [self quickMenu_itemWithSymbol:@"ellipsis.circle.fill" fallback:nil label:@"命令管理器" action:@selector(quickMenu_openCommandManager)],
        [self quickMenu_itemWithSymbol:@"rectangle.on.rectangle.circle.fill" fallback:@"arrow.left.arrow.right.circle.fill" label:@"切换屏幕" action:@selector(quickMenu_sendDisplaySwitch)],
        [self quickMenu_itemWithSymbol:@"2.circle.fill" fallback:nil label:@"模拟器 2" action:@selector(quickMenu_sendEmulatorTwo)],
        [self quickMenu_itemWithSymbol:@"1.circle.fill" fallback:nil label:@"模拟器 1" action:@selector(quickMenu_sendEmulatorOne)],
    ];
    CGFloat x = kQuickMenuPadding;
    for (UIButton *item in items) {
        item.frame = CGRectMake(x, kQuickMenuPadding, kQuickMenuItemDiameter, kQuickMenuItemDiameter);
        [_quickMenuPanel addSubview:item];
        x += kQuickMenuItemDiameter + kQuickMenuSpacing;
    }
    CGFloat w = x - kQuickMenuSpacing + kQuickMenuPadding;
    _quickMenuPanel.bounds = CGRectMake(0, 0, w, kQuickMenuItemDiameter + 2 * kQuickMenuPadding);
}

- (BOOL)quickMenu_isOpen {
    return _quickMenuOpen;
}

// Other chrome (countdown hit area, re-added widgets, ...) gets raised on its
// own refreshes; while the menu is attached it must stay above all of it so
// an outside touch lands on the catcher. Order: catcher, capsule, panel.
// (The capsule is the backdrop view plus the blank button on top of it.)
- (void)quickMenu_raiseToFront {
    if (!_quickMenuPanel.superview) return;
    [self.view bringSubviewToFront:_quickMenuDismissCatcher];
    [self.view bringSubviewToFront:_quickMenuBackdrop];
    [self.view bringSubviewToFront:_quickMenuButton];
    [self.view bringSubviewToFront:_quickMenuPanel];
}

// Panel sits 15pt above the menu button, 8pt from the screen's right edge. With
// the layer anchored at (1, 1), center is the panel's bottom-right corner.
- (void)quickMenu_layoutPanel {
    if (!_quickMenuPanel.superview) return;
    _quickMenuDismissCatcher.frame = self.view.bounds;
    CGRect anchor = _quickMenuButton.frame;
    _quickMenuPanel.center = CGPointMake(self.view.bounds.size.width - 8, CGRectGetMinY(anchor) - 15);
    [self quickMenu_raiseToFront];
}

- (void)quickMenu_toggle {
    if ([self quickMenu_isOpen]) {
        [self quickMenu_dismissAnimated:YES];
        return;
    }
    if (self->_streamView.widgetToolOpened) return;
    [self quickMenu_buildPanelIfNeeded];
    _quickMenuOpen = YES;
    _quickMenuToken++; // a close fade still running must not detach us
    BOOL wasAttached = (_quickMenuPanel.superview != nil);
    [self.view addSubview:_quickMenuDismissCatcher];
    [self.view addSubview:_quickMenuPanel];
    [self quickMenu_layoutPanel]; // also orders catcher < capsule < panel

    if (!wasAttached) {
        _quickMenuPanel.alpha = 0;
        _quickMenuPanel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    }
    // Reopening mid-fade continues from where the fade is.
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_quickMenuPanel.alpha = 1;
        self->_quickMenuPanel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)quickMenu_detach {
    [_quickMenuDismissCatcher removeFromSuperview];
    [_quickMenuPanel removeFromSuperview];
    _quickMenuPanel.alpha = 1;
    _quickMenuPanel.transform = CGAffineTransformIdentity;
}

- (void)quickMenu_dismissAnimated:(BOOL)animated {
    if (!_quickMenuPanel.superview) return;
    BOOL wasOpen = _quickMenuOpen;
    _quickMenuOpen = NO;
    NSUInteger token = ++_quickMenuToken;
    if (!animated) {
        [_quickMenuPanel.layer removeAllAnimations];
        [self quickMenu_detach];
        return;
    }
    if (!wasOpen) return; // already fading out
    // The catcher stays attached for the whole fade so touches meanwhile
    // still don't leak into the stream; the capsule above it can reopen.
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_quickMenuPanel.alpha = 0;
        self->_quickMenuPanel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        if (token != self->_quickMenuToken) return; // reopened or force-closed since
        [self quickMenu_detach];
    }];
}

- (void)quickMenu_catcherTouched {
    [self quickMenu_dismissAnimated:YES];
}

// Host-side AutoHotkey bindings (mac-keyboard-ahk-v2):
//   Win+Ctrl+Alt+Shift+1 / +2  toggle the two emulators
//   F13 (short press)          extended <-> second-screen-only display mode
- (void)quickMenu_sendEmulatorOne {
    [self quickMenu_dismissAnimated:YES];
    [CommandManager.shared sendKeyComboCommandWithKeyboardCmdStrings:@[@"WIN", @"CTRL", @"ALT", @"SHIFT", @"1"]];
}

- (void)quickMenu_sendEmulatorTwo {
    [self quickMenu_dismissAnimated:YES];
    [CommandManager.shared sendKeyComboCommandWithKeyboardCmdStrings:@[@"WIN", @"CTRL", @"ALT", @"SHIFT", @"2"]];
}

- (void)quickMenu_sendDisplaySwitch {
    [self quickMenu_dismissAnimated:YES];
    [CommandManager.shared sendKeyComboCommandWithKeyboardCmdStrings:@[@"F13"]];
}

- (void)quickMenu_openCommandManager {
    [self quickMenu_dismissAnimated:NO];
    [self presentToolboxViewController];
}

#pragma mark - OSC mode button: tap cycles the hide mode, hold suspends

// Release faster than this, with no stream touch in between, counts as a tap.
static const CFTimeInterval kOscHoldTapMaxDuration = 0.35;

- (void)oscModeTouchDown:(UIButton *)sender {
    _oscHoldActive = NO;
    if (self->_streamView.widgetToolOpened) return;
    // Nothing on screen: nothing to suspend, the release is a plain tap.
    if (![self->_streamView hasAnyOnScreenControls]) return;
    _oscHoldActive = YES;
    _oscHoldStartTime = CACurrentMediaTime();
    // Suspend right at touch-down (no long-press delay) so a hold feels instant;
    // a tap resumes within a few hundred ms, which is invisible.
    [self->_streamView setOscTemporarilySuspended:YES];
}

- (void)oscModeTouchUpInside:(UIButton *)sender {
    if (!_oscHoldActive) {
        [self cycleOscHideMode];
        return;
    }
    BOOL usedAsHold = [self->_streamView oscSuspensionSawStreamTouch]
                   || (CACurrentMediaTime() - _oscHoldStartTime) >= kOscHoldTapMaxDuration;
    [self endOscHold];
    if (!usedAsHold) [self cycleOscHideMode];
}

- (void)oscModeTouchEnded:(UIButton *)sender {
    [self endOscHold];
}

- (void)endOscHold {
    if (!_oscHoldActive) return;
    _oscHoldActive = NO;
    [self->_streamView setOscTemporarilySuspended:NO];
}

// Toggles the persistent forceGyroEnabled flag. An unset value behaves like
// legacy ON; once the user taps, OFF suppresses passive gyro while still
// allowing explicit GYRO / OSCR2-GYRO widgets to enable it.
// ControllerSupport observes VoidGyroSettingsDidChangeNotification so the
// live stream picks up the change without reconnect.
- (void)toggleGyroOnOff {
    BOOL current = VoidGyroToggleEnabled();
    BOOL newValue = !current;
    [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:@"forceGyroEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [_gyroToggleButton setTitle:(newValue ? @"GYRO ON" : @"GYRO OFF") forState:UIControlStateNormal];
    [[NSNotificationCenter defaultCenter] postNotificationName:VoidGyroSettingsDidChangeNotification object:nil];
}

- (void)toggleStreamOrientationLock {
    BOOL newValue = !VoidStreamOrientationLockEnabled();
    [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:kStreamOrientationLockEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self stream_updateOrientationLockButton];
    [self stream_publishOrientationLockAndRefresh];
}

- (void)createTimeBatteryDisplay {
    // Create time label
    if (!_timeLabel) {
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _timeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.33];
        _timeLabel.userInteractionEnabled = NO;
        [self.view addSubview:_timeLabel];
    }
    
    // Create battery label
    if (!_batteryLabel) {
        _batteryLabel = [[UILabel alloc] init];
        _batteryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _batteryLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.33];
        _batteryLabel.userInteractionEnabled = NO;
        [self.view addSubview:_batteryLabel];
    }

    [self createStreamCountdownDisplayIfNeeded];
    
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
    
    [self layoutTimeBatteryCountdownDisplay];
}

- (void)restartTimeBatteryUpdateTimer {
    [_timeBatteryUpdateTimer invalidate];
    _timeBatteryUpdateTimer = nil;

    _timeBatteryUpdateTimer = [NSTimer timerWithTimeInterval:60.0f
                                                      target:self
                                                    selector:@selector(updateTimeBatteryDisplay)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timeBatteryUpdateTimer forMode:NSRunLoopCommonModes];
}

- (NSTimeInterval)normalizedStreamCountdownDuration:(NSTimeInterval)duration {
    if (!isfinite(duration) || duration <= 0) {
        duration = kStreamCountdownDefaultDurationSeconds;
    }
    return MIN(MAX(duration, kStreamCountdownMinimumDurationSeconds), kStreamCountdownMaximumDurationSeconds);
}

- (NSTimeInterval)storedStreamCountdownDuration {
    id storedDuration = [[NSUserDefaults standardUserDefaults] objectForKey:kStreamCountdownDurationSecondsKey];
    if (![storedDuration respondsToSelector:@selector(doubleValue)]) {
        return kStreamCountdownDefaultDurationSeconds;
    }
    return [self normalizedStreamCountdownDuration:[storedDuration doubleValue]];
}

- (NSString *)formattedStreamCountdownSeconds:(NSTimeInterval)seconds {
    NSInteger totalSeconds = (NSInteger)ceil(MAX(0, seconds));
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger remainingSeconds = totalSeconds % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)remainingSeconds];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)remainingSeconds];
}

#if !TARGET_OS_TV
- (NSInteger)streamCountdownPickerMinutesForDuration:(NSTimeInterval)duration {
    NSInteger totalSeconds = (NSInteger)llround([self normalizedStreamCountdownDuration:duration]);
    return MIN(totalSeconds / 60, kStreamCountdownMaximumPickerMinutes);
}

- (NSInteger)streamCountdownPickerSecondRowForDuration:(NSTimeInterval)duration {
    NSInteger totalSeconds = (NSInteger)llround([self normalizedStreamCountdownDuration:duration]);
    NSInteger seconds = totalSeconds % 60;
    NSInteger row = (NSInteger)llround((double)seconds / (double)kStreamCountdownPickerSecondStep);
    return MIN(MAX(row, 0), kStreamCountdownPickerSecondRows - 1);
}

- (NSTimeInterval)selectedStreamCountdownPickerDuration {
    if (!_streamCountdownDurationPicker) {
        return _streamCountdownDurationSeconds;
    }

    NSInteger minutes = [_streamCountdownDurationPicker selectedRowInComponent:0];
    NSInteger seconds = [_streamCountdownDurationPicker selectedRowInComponent:1] * kStreamCountdownPickerSecondStep;
    return [self normalizedStreamCountdownDuration:(minutes * 60) + seconds];
}
#endif

- (UIColor *)streamCountdownBaseTintColor {
    return [[UIColor whiteColor] colorWithAlphaComponent:0.33];
}

- (CGSize)streamCountdownLabelSizeForText:(NSString *)text insets:(UIEdgeInsets)insets {
    UIFont *font = _countdownLabel.font ?: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    CGSize textSize = [text sizeWithAttributes:@{NSFontAttributeName: font}];
    return CGSizeMake(ceil(textSize.width) + insets.left + insets.right,
                      ceil(textSize.height) + insets.top + insets.bottom);
}

- (void)createStreamCountdownDisplayIfNeeded {
    if (!_countdownHitAreaView) {
        _countdownHitAreaView = [[UIView alloc] initWithFrame:CGRectZero];
        _countdownHitAreaView.backgroundColor = [UIColor clearColor];
        _countdownHitAreaView.userInteractionEnabled = YES;
        _countdownHitAreaView.accessibilityTraits = UIAccessibilityTraitButton;
        _countdownHitAreaView.accessibilityLabel = @"Timer";

        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(streamCountdownTapped:)];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(streamCountdownDoubleTapped:)];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(streamCountdownLongPressed:)];
        doubleTap.numberOfTapsRequired = 2;
        longPress.minimumPressDuration = 0.55;
        [singleTap requireGestureRecognizerToFail:doubleTap];

        [_countdownHitAreaView addGestureRecognizer:singleTap];
        [_countdownHitAreaView addGestureRecognizer:doubleTap];
        [_countdownHitAreaView addGestureRecognizer:longPress];
        [self.view addSubview:_countdownHitAreaView];
    }

    if (!_countdownLabel) {
        _countdownLabel = [[PaddedLabel alloc] initWithFrame:CGRectZero];
        _countdownLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _countdownLabel.textAlignment = NSTextAlignmentCenter;
        _countdownLabel.userInteractionEnabled = NO;
        _countdownLabel.clipsToBounds = YES;
        [_countdownHitAreaView addSubview:_countdownLabel];
    }

    if (_streamCountdownDurationSeconds <= 0) {
        [self restoreStreamCountdownStateFromDefaults];
    } else {
        [self updateStreamCountdownDisplay];
    }
}

- (void)restoreStreamCountdownStateFromDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _streamCountdownDurationSeconds = [self storedStreamCountdownDuration];
    _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
    _streamCountdownEndDate = nil;
    _streamCountdownFinishFeedbackShown = NO;

    StreamCountdownState savedState = (StreamCountdownState)[defaults integerForKey:kStreamCountdownStateKey];
    if (savedState == StreamCountdownStateRunning) {
        NSDate *savedEndDate = [defaults objectForKey:kStreamCountdownEndDateKey];
        if ([savedEndDate isKindOfClass:[NSDate class]]) {
            NSTimeInterval remaining = [savedEndDate timeIntervalSinceNow];
            if (remaining > 0) {
                _streamCountdownState = StreamCountdownStateRunning;
                _streamCountdownEndDate = savedEndDate;
                _streamCountdownRemainingSeconds = remaining;
            } else {
                _streamCountdownState = StreamCountdownStateIdle;
                _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
            }
        } else {
            _streamCountdownState = StreamCountdownStateIdle;
        }
    } else if (savedState == StreamCountdownStatePaused) {
        NSTimeInterval remaining = [defaults doubleForKey:kStreamCountdownRemainingSecondsKey];
        if (remaining > 0) {
            _streamCountdownState = StreamCountdownStatePaused;
            _streamCountdownRemainingSeconds = MIN(remaining, _streamCountdownDurationSeconds);
        } else {
            _streamCountdownState = StreamCountdownStateIdle;
            _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
        }
    } else if (savedState == StreamCountdownStateFinished) {
        _streamCountdownState = StreamCountdownStateIdle;
        _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
    } else {
        _streamCountdownState = StreamCountdownStateIdle;
        _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
    }

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];
}

- (void)persistStreamCountdownState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:_streamCountdownDurationSeconds forKey:kStreamCountdownDurationSecondsKey];
    [defaults setInteger:_streamCountdownState forKey:kStreamCountdownStateKey];

    if (_streamCountdownState == StreamCountdownStateRunning && _streamCountdownEndDate) {
        [defaults setObject:_streamCountdownEndDate forKey:kStreamCountdownEndDateKey];
    } else {
        [defaults removeObjectForKey:kStreamCountdownEndDateKey];
    }

    if (_streamCountdownState == StreamCountdownStatePaused) {
        [defaults setDouble:_streamCountdownRemainingSeconds forKey:kStreamCountdownRemainingSecondsKey];
    } else {
        [defaults removeObjectForKey:kStreamCountdownRemainingSecondsKey];
    }
    [defaults synchronize];
}

- (void)updateStreamCountdownTimer {
    [_streamCountdownUpdateTimer invalidate];
    _streamCountdownUpdateTimer = nil;

    if (_streamCountdownState != StreamCountdownStateRunning) {
        return;
    }

    _streamCountdownUpdateTimer = [NSTimer timerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(streamCountdownUpdateTimerFired:)
                                                        userInfo:nil
                                                         repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_streamCountdownUpdateTimer forMode:NSRunLoopCommonModes];
}

- (void)streamCountdownUpdateTimerFired:(NSTimer *)timer {
    [self refreshStreamCountdownFromClockWithFeedback:YES];
}

- (void)refreshStreamCountdownFromClockWithFeedback:(BOOL)feedback {
    if (_streamCountdownState != StreamCountdownStateRunning) {
        return;
    }

    NSTimeInterval remaining = [_streamCountdownEndDate timeIntervalSinceNow];
    if (remaining <= 0) {
        [self finishStreamCountdownWithFeedback:feedback];
        return;
    }

    _streamCountdownRemainingSeconds = remaining;
    [self updateStreamCountdownDisplay];
}

- (void)startStreamCountdownWithDuration:(NSTimeInterval)duration {
    [self removeStreamCountdownEdgeGlowFeedback];
    _streamCountdownDurationSeconds = [self normalizedStreamCountdownDuration:duration];
    _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
    _streamCountdownEndDate = [NSDate dateWithTimeIntervalSinceNow:_streamCountdownDurationSeconds];
    _streamCountdownState = StreamCountdownStateRunning;
    _streamCountdownFinishFeedbackShown = NO;

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];
}

- (void)pauseStreamCountdown {
    if (_streamCountdownState != StreamCountdownStateRunning) {
        return;
    }

    _streamCountdownRemainingSeconds = MAX(0, [_streamCountdownEndDate timeIntervalSinceNow]);
    if (_streamCountdownRemainingSeconds <= 0) {
        [self finishStreamCountdownWithFeedback:YES];
        return;
    }

    _streamCountdownState = StreamCountdownStatePaused;
    _streamCountdownEndDate = nil;

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];
}

- (void)resumeStreamCountdown {
    if (_streamCountdownState != StreamCountdownStatePaused) {
        return;
    }

    if (_streamCountdownRemainingSeconds <= 0) {
        [self finishStreamCountdownWithFeedback:YES];
        return;
    }

    _streamCountdownEndDate = [NSDate dateWithTimeIntervalSinceNow:_streamCountdownRemainingSeconds];
    _streamCountdownState = StreamCountdownStateRunning;

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];
}

- (void)resetStreamCountdownToIdle {
    _streamCountdownState = StreamCountdownStateIdle;
    _streamCountdownRemainingSeconds = _streamCountdownDurationSeconds;
    _streamCountdownEndDate = nil;
    _streamCountdownFinishFeedbackShown = NO;
    [self removeStreamCountdownEdgeGlowFeedback];

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];
}

- (void)resetFinishedStreamCountdownToIdleIfNeeded {
    if (_streamCountdownState == StreamCountdownStateFinished) {
        [self resetStreamCountdownToIdle];
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ((StreamCountdownState)[defaults integerForKey:kStreamCountdownStateKey] == StreamCountdownStateFinished) {
        [defaults setInteger:StreamCountdownStateIdle forKey:kStreamCountdownStateKey];
        [defaults removeObjectForKey:kStreamCountdownEndDateKey];
        [defaults removeObjectForKey:kStreamCountdownRemainingSecondsKey];
        [defaults synchronize];
    }
}

- (void)finishStreamCountdownWithFeedback:(BOOL)feedback {
    _streamCountdownState = StreamCountdownStateFinished;
    _streamCountdownRemainingSeconds = 0;
    _streamCountdownEndDate = nil;

    [self persistStreamCountdownState];
    [self updateStreamCountdownTimer];
    [self updateStreamCountdownDisplay];

    if (feedback) {
        [self playStreamCountdownFinishedFeedback];
    }
}

- (void)applyStreamCountdownDuration:(NSTimeInterval)duration {
    _streamCountdownDurationSeconds = [self normalizedStreamCountdownDuration:duration];
    [self startStreamCountdownWithDuration:_streamCountdownDurationSeconds];
}

- (void)updateStreamCountdownDisplay {
    if (!_countdownLabel) {
        return;
    }

    UIColor *baseTint = [self streamCountdownBaseTintColor];
    UIColor *foregroundColor = baseTint;
    UIColor *backgroundColor = [UIColor clearColor];
    UIEdgeInsets textInsets = UIEdgeInsetsMake(3, 6, 3, 6);
    NSString *displayText = [self formattedStreamCountdownSeconds:_streamCountdownDurationSeconds];

    if (_streamCountdownState == StreamCountdownStateRunning) {
        displayText = [self formattedStreamCountdownSeconds:_streamCountdownRemainingSeconds];
        foregroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
        backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22];
    } else if (_streamCountdownState == StreamCountdownStatePaused) {
        displayText = [self formattedStreamCountdownSeconds:_streamCountdownRemainingSeconds];
        foregroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.13];
    } else if (_streamCountdownState == StreamCountdownStateFinished) {
        displayText = @"DONE";
        foregroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        backgroundColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.16 alpha:0.92];
    }

    _countdownLabel.textInsets = textInsets;
    _countdownLabel.text = displayText;
    _countdownLabel.textColor = foregroundColor;
    _countdownLabel.backgroundColor = backgroundColor;
    CGSize displaySize = [self streamCountdownLabelSizeForText:displayText insets:textInsets];
    CGSize durationSize = [self streamCountdownLabelSizeForText:[self formattedStreamCountdownSeconds:_streamCountdownDurationSeconds] insets:textInsets];
    CGSize doneSize = [self streamCountdownLabelSizeForText:@"DONE" insets:textInsets];
    _countdownLabel.frame = CGRectMake(_countdownLabel.frame.origin.x,
                                       _countdownLabel.frame.origin.y,
                                       MAX(MAX(displaySize.width, durationSize.width), doneSize.width),
                                       MAX(MAX(displaySize.height, durationSize.height), doneSize.height));
    _countdownLabel.layer.cornerRadius = (_streamCountdownState == StreamCountdownStateIdle) ? 0 : (_countdownLabel.bounds.size.height / 2.0f);
    if (_streamCountdownState != StreamCountdownStateFinished) {
        [_countdownLabel.layer removeAllAnimations];
        _countdownLabel.transform = CGAffineTransformIdentity;
    }

    [self layoutTimeBatteryCountdownDisplay];
}

- (void)layoutTimeBatteryCountdownDisplay {
    if (!_timeLabel || !_batteryLabel) {
        return;
    }
    // Bottom-left info follows the OSC visibility, like the bottom-right buttons.
    _timeLabel.hidden = _oscHidden;
    _batteryLabel.hidden = _oscHidden;
    _countdownHitAreaView.hidden = _oscHidden;

    // Layout labels at bottom-left
    CGFloat leftMargin = 24.0f;
    CGFloat spacing = 16.0f;
    
    CGFloat timeX = leftMargin;
    CGFloat batteryX = timeX + _timeLabel.frame.size.width + spacing;
    CGFloat y = round([self stream_bottomRowCenterY] - _timeLabel.frame.size.height / 2.0f);
    
    _timeLabel.frame = CGRectMake(timeX, y, _timeLabel.frame.size.width, _timeLabel.frame.size.height);
    _batteryLabel.frame = CGRectMake(batteryX, y, _batteryLabel.frame.size.width, _batteryLabel.frame.size.height);

    if (_countdownHitAreaView && _countdownLabel) {
        CGFloat countdownX = CGRectGetMaxX(_batteryLabel.frame) + spacing;
        CGFloat labelWidth = _countdownLabel.frame.size.width;
        CGFloat labelHeight = _countdownLabel.frame.size.height;
        CGFloat hitWidth = MAX(48.0f, labelWidth);
        CGFloat hitHeight = MAX(32.0f, labelHeight);
        CGFloat centerY = CGRectGetMidY(_timeLabel.frame);
        CGFloat hitX = countdownX - ((hitWidth - labelWidth) / 2.0f);
        CGFloat hitY = centerY - (hitHeight / 2.0f);

        _countdownHitAreaView.frame = CGRectMake(hitX, hitY, hitWidth, hitHeight);
        _countdownLabel.frame = CGRectMake((hitWidth - labelWidth) / 2.0f,
                                           (hitHeight - labelHeight) / 2.0f,
                                           labelWidth,
                                           labelHeight);
    }

    [self.view bringSubviewToFront:_timeLabel];
    [self.view bringSubviewToFront:_batteryLabel];
    if (_countdownHitAreaView) {
        [self.view bringSubviewToFront:_countdownHitAreaView];
    }
    [self quickMenu_raiseToFront];
}

- (void)streamCountdownTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }

    if (_streamCountdownState == StreamCountdownStateIdle) {
        [self startStreamCountdownWithDuration:_streamCountdownDurationSeconds];
    } else if (_streamCountdownState == StreamCountdownStateRunning) {
        [self pauseStreamCountdown];
    } else if (_streamCountdownState == StreamCountdownStatePaused) {
        [self resumeStreamCountdown];
    } else if (_streamCountdownState == StreamCountdownStateFinished) {
        [self resetStreamCountdownToIdle];
    }
}

- (void)streamCountdownDoubleTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if (_streamCountdownState != StreamCountdownStateRunning &&
        _streamCountdownState != StreamCountdownStatePaused) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset timer?"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self resetStreamCountdownToIdle];
    }]];
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        UIView *sourceView = _countdownHitAreaView ?: self.view;
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionDown | UIPopoverArrowDirectionUp;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)streamCountdownLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self presentStreamCountdownDurationPicker];
    }
}

- (void)presentStreamCountdownDurationPicker {
#if TARGET_OS_TV
    return;
#else
    if (self.presentedViewController) {
        return;
    }

    UIAlertControllerStyle style = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad ? UIAlertControllerStyleActionSheet : UIAlertControllerStyleAlert;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Timer Duration"
                                                                   message:@"\n\n\n\n\n\n\n"
                                                            preferredStyle:style];
    _streamCountdownDurationPicker = [[UIPickerView alloc] initWithFrame:CGRectZero];
    _streamCountdownDurationPicker.dataSource = self;
    _streamCountdownDurationPicker.delegate = self;
    _streamCountdownDurationPicker.translatesAutoresizingMaskIntoConstraints = NO;

    NSInteger minuteRow = [self streamCountdownPickerMinutesForDuration:_streamCountdownDurationSeconds];
    NSInteger secondRow = [self streamCountdownPickerSecondRowForDuration:_streamCountdownDurationSeconds];
    [_streamCountdownDurationPicker selectRow:minuteRow inComponent:0 animated:NO];
    [_streamCountdownDurationPicker selectRow:secondRow inComponent:1 animated:NO];

    [alert.view addSubview:_streamCountdownDurationPicker];
    [NSLayoutConstraint activateConstraints:@[
        [_streamCountdownDurationPicker.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [_streamCountdownDurationPicker.topAnchor constraintEqualToAnchor:alert.view.topAnchor constant:48.0f],
        [_streamCountdownDurationPicker.widthAnchor constraintEqualToConstant:260.0f],
        [_streamCountdownDurationPicker.heightAnchor constraintEqualToConstant:150.0f]
    ]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        self->_streamCountdownDurationPicker = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Set"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        NSTimeInterval duration = [self selectedStreamCountdownPickerDuration];
        self->_streamCountdownDurationPicker = nil;
        [self applyStreamCountdownDuration:duration];
    }]];
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        UIView *sourceView = _countdownHitAreaView ?: self.view;
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionDown | UIPopoverArrowDirectionUp;
    }
    [self presentViewController:alert animated:YES completion:nil];
#endif
}

#if !TARGET_OS_TV
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return pickerView == _streamCountdownDurationPicker ? 2 : 0;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    if (pickerView != _streamCountdownDurationPicker) {
        return 0;
    }
    return component == 0 ? (kStreamCountdownMaximumPickerMinutes + 1) : kStreamCountdownPickerSecondRows;
}

- (CGFloat)pickerView:(UIPickerView *)pickerView widthForComponent:(NSInteger)component {
    return component == 0 ? 140.0f : 90.0f;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (component == 0) {
        return [NSString stringWithFormat:@"%ld min", (long)row];
    }
    return [NSString stringWithFormat:@"%02ld sec", (long)(row * kStreamCountdownPickerSecondStep)];
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (pickerView != _streamCountdownDurationPicker) {
        return;
    }

    if ([pickerView selectedRowInComponent:0] == 0 && [pickerView selectedRowInComponent:1] == 0) {
        [pickerView selectRow:1 inComponent:1 animated:YES];
    }
}
#endif

- (UIScreen *)streamCountdownCurrentScreen {
    return self.view.window.screen ?: [UIScreen mainScreen];
}

- (BOOL)streamCountdownBounds:(CGRect)bounds fillsScreen:(UIScreen *)screen {
    if (!screen || CGRectIsEmpty(bounds)) {
        return NO;
    }

    CGSize viewSize = bounds.size;
    CGSize screenSize = screen.bounds.size;
    CGFloat viewShortSide = MIN(viewSize.width, viewSize.height);
    CGFloat viewLongSide = MAX(viewSize.width, viewSize.height);
    CGFloat screenShortSide = MIN(screenSize.width, screenSize.height);
    CGFloat screenLongSide = MAX(screenSize.width, screenSize.height);
    return fabs(viewShortSide - screenShortSide) < 1.0f && fabs(viewLongSide - screenLongSide) < 1.0f;
}

- (BOOL)streamCountdownIsIPadPro11InchM4WithScreen:(UIScreen *)screen {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad || !screen) {
        return NO;
    }

    CGSize nativeSize = screen.nativeBounds.size;
    CGFloat nativeShortSide = MIN(nativeSize.width, nativeSize.height);
    CGFloat nativeLongSide = MAX(nativeSize.width, nativeSize.height);
    return fabs(nativeShortSide - 1668.0f) < 1.0f && fabs(nativeLongSide - 2420.0f) < 1.0f;
}

- (CGFloat)streamCountdownEdgeGlowCornerRadiusForBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds)) {
        return 0;
    }

    UIScreen *screen = [self streamCountdownCurrentScreen];
    if ([self streamCountdownIsIPadPro11InchM4WithScreen:screen] &&
        [self streamCountdownBounds:bounds fillsScreen:screen]) {
        return 24.0f;
    }

    UIEdgeInsets safeAreaInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeAreaInsets = self.view.window ? self.view.window.safeAreaInsets : self.view.safeAreaInsets;
    }

    CGFloat maxInset = MAX(MAX(safeAreaInsets.top, safeAreaInsets.bottom), MAX(safeAreaInsets.left, safeAreaInsets.right));
    if (maxInset <= 0) {
        return 0;
    }

    // UIKit does not expose the physical display corner radius; infer it from safe-area insets.
    CGFloat radius;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        if (maxInset < 16.0f) {
            return 0;
        }
        radius = MIN(28.0f, MAX(18.0f, maxInset));
    } else {
        if (maxInset < 30.0f) {
            return 0;
        }
        radius = MIN(58.0f, MAX(39.0f, maxInset));
    }

    return MIN(radius, MIN(bounds.size.width, bounds.size.height) / 2.0f);
}

- (CAGradientLayer *)streamCountdownEdgeGlowGradientWithFrame:(CGRect)frame
                                                        start:(CGPoint)start
                                                          end:(CGPoint)end
                                                        color:(UIColor *)color
                                                    blendMode:(NSString *)blendMode {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.frame = frame;
    layer.startPoint = start;
    layer.endPoint = end;
    layer.colors = @[(id)color.CGColor, (id)[color colorWithAlphaComponent:0.0].CGColor];
    layer.locations = @[@0.0, @1.0];
    layer.compositingFilter = blendMode;
    layer.contentsScale = [UIScreen mainScreen].scale;
    return layer;
}

- (void)addStreamCountdownEdgeGlowBandToView:(UIView *)view
                                       width:(CGFloat)width
                                       color:(UIColor *)color
                                   blendMode:(NSString *)blendMode {
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds) || width <= 0) {
        return;
    }

    CGFloat bandWidth = MIN(width, MIN(bounds.size.width, bounds.size.height) / 2.0f);
    NSArray<CAGradientLayer *> *layers = @[
        [self streamCountdownEdgeGlowGradientWithFrame:CGRectMake(0, 0, bounds.size.width, bandWidth)
                                                 start:CGPointMake(0.5, 0.0)
                                                   end:CGPointMake(0.5, 1.0)
                                                 color:color
                                             blendMode:blendMode],
        [self streamCountdownEdgeGlowGradientWithFrame:CGRectMake(0, bounds.size.height - bandWidth, bounds.size.width, bandWidth)
                                                 start:CGPointMake(0.5, 1.0)
                                                   end:CGPointMake(0.5, 0.0)
                                                 color:color
                                             blendMode:blendMode],
        [self streamCountdownEdgeGlowGradientWithFrame:CGRectMake(0, 0, bandWidth, bounds.size.height)
                                                 start:CGPointMake(0.0, 0.5)
                                                   end:CGPointMake(1.0, 0.5)
                                                 color:color
                                             blendMode:blendMode],
        [self streamCountdownEdgeGlowGradientWithFrame:CGRectMake(bounds.size.width - bandWidth, 0, bandWidth, bounds.size.height)
                                                 start:CGPointMake(1.0, 0.5)
                                                   end:CGPointMake(0.0, 0.5)
                                                 color:color
                                             blendMode:blendMode]
    ];

    for (CAGradientLayer *layer in layers) {
        [view.layer addSublayer:layer];
    }
}

- (void)addStreamCountdownEdgeGlowBorderToView:(UIView *)view
                                         color:(UIColor *)color
                                     blendMode:(NSString *)blendMode {
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds)) {
        return;
    }

    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat borderWidth = 2.0f / scale;

    CALayer *borderLayer = [CALayer layer];
    borderLayer.frame = bounds;
    borderLayer.backgroundColor = [UIColor clearColor].CGColor;
    borderLayer.borderColor = color.CGColor;
    borderLayer.borderWidth = borderWidth;
    borderLayer.cornerRadius = view.layer.cornerRadius;
    if (@available(iOS 13.0, *)) {
        borderLayer.cornerCurve = kCACornerCurveContinuous;
    }
    borderLayer.compositingFilter = blendMode;
    borderLayer.contentsScale = scale;
    [view.layer addSublayer:borderLayer];
}

- (void)removeStreamCountdownEdgeGlowFeedback {
    [_streamCountdownEdgeGlowView.layer removeAllAnimations];
    [_streamCountdownEdgeGlowView removeFromSuperview];
    _streamCountdownEdgeGlowView = nil;
}

- (void)playStreamCountdownEdgeGlowFeedback {
#if TARGET_OS_TV
    return;
#else
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) {
        return;
    }

    [self removeStreamCountdownEdgeGlowFeedback];

    UIView *edgeGlowView = [[UIView alloc] initWithFrame:bounds];
    edgeGlowView.backgroundColor = [UIColor clearColor];
    edgeGlowView.userInteractionEnabled = NO;
    edgeGlowView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    edgeGlowView.alpha = 0.0f;
    edgeGlowView.layer.masksToBounds = YES;
    edgeGlowView.layer.cornerRadius = [self streamCountdownEdgeGlowCornerRadiusForBounds:bounds];
    if (@available(iOS 13.0, *)) {
        edgeGlowView.layer.cornerCurve = kCACornerCurveContinuous;
    }

    CGFloat minSide = MIN(bounds.size.width, bounds.size.height);
    CGFloat softWidth = MIN(116.0f, MAX(68.0f, minSide * 0.1225f));
    CGFloat hotWidth = MIN(30.0f, MAX(18.0f, minSide * 0.03f));
    UIColor *softYellow = [UIColor colorWithRed:1.0f green:0.78f blue:0.08f alpha:0.22f];
    UIColor *hotWhite = [UIColor colorWithWhite:1.0f alpha:0.64f];
    UIColor *borderWhite = [UIColor colorWithWhite:1.0f alpha:0.85f];
    CGFloat restingAlpha = 0.64f;

    [self addStreamCountdownEdgeGlowBandToView:edgeGlowView
                                         width:softWidth
                                         color:softYellow
                                     blendMode:@"screenBlendMode"];
    [self addStreamCountdownEdgeGlowBandToView:edgeGlowView
                                         width:hotWidth
                                         color:hotWhite
                                     blendMode:@"plusLighter"];
    [self addStreamCountdownEdgeGlowBorderToView:edgeGlowView
                                           color:borderWhite
                                       blendMode:@"plusLighter"];

    _streamCountdownEdgeGlowView = edgeGlowView;
    [self.view addSubview:edgeGlowView];
    [self.view bringSubviewToFront:edgeGlowView];

    [UIView animateKeyframesWithDuration:3.5
                                   delay:0
                                 options:UIViewKeyframeAnimationOptionCalculationModeCubic
                              animations:^{
        [UIView addKeyframeWithRelativeStartTime:0.00 relativeDuration:0.06 animations:^{
            edgeGlowView.alpha = 1.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.06 relativeDuration:0.14 animations:^{
            edgeGlowView.alpha = 0.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.20 relativeDuration:0.06 animations:^{
            edgeGlowView.alpha = 1.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.26 relativeDuration:0.14 animations:^{
            edgeGlowView.alpha = 0.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.40 relativeDuration:0.06 animations:^{
            edgeGlowView.alpha = 1.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.46 relativeDuration:0.14 animations:^{
            edgeGlowView.alpha = 0.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.60 relativeDuration:0.06 animations:^{
            edgeGlowView.alpha = 1.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.66 relativeDuration:0.14 animations:^{
            edgeGlowView.alpha = 0.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.80 relativeDuration:0.06 animations:^{
            edgeGlowView.alpha = 1.0f;
        }];
        [UIView addKeyframeWithRelativeStartTime:0.86 relativeDuration:0.14 animations:^{
            edgeGlowView.alpha = restingAlpha;
        }];
    } completion:^(BOOL finished) {
        if (finished && self->_streamCountdownEdgeGlowView == edgeGlowView) {
            edgeGlowView.alpha = restingAlpha;
        }
    }];
#endif
}

- (void)playStreamCountdownFinishedFeedback {
    if (_streamCountdownFinishFeedbackShown) {
        return;
    }
    _streamCountdownFinishFeedbackShown = YES;

#if !TARGET_OS_TV
    if (@available(iOS 10.0, *)) {
        UINotificationFeedbackGenerator *feedbackGenerator = [[UINotificationFeedbackGenerator alloc] init];
        [feedbackGenerator notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
#endif

    [self playStreamCountdownEdgeGlowFeedback];

    _countdownLabel.transform = CGAffineTransformIdentity;
    [UIView animateKeyframesWithDuration:0.55
                                   delay:0
                                 options:UIViewKeyframeAnimationOptionCalculationModeCubic
                              animations:^{
        [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:0.5 animations:^{
            self->_countdownLabel.transform = CGAffineTransformMakeScale(1.16, 1.16);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{
            self->_countdownLabel.transform = CGAffineTransformIdentity;
        }];
    } completion:nil];
}

#pragma mark - Snap ratio (16:9 / FULL)

// With auto detection available (iPad-size host display) the ratio follows the
// detector: content inside the centred 16:9 region -> 16:9 (snap it to the
// top), anything else -> FULL. A tap on the ratio button overrides for this
// session and is dropped the moment the detector's fit verdict flips, exactly
// like the OSC mode button. Without auto detection the button keeps its old
// persisted behaviour.
- (NSInteger)snap_effectiveRatioMode {
    if (!_oscAutoDetectApplicable) return _settings.snapScreenRatioMode.integerValue;
    if (_snapRatioOverride != SnapRatioOverrideNone) return (_snapRatioOverride == SnapRatioOverrideSixteenNine) ? 0 : 1;
    return _snapDetectedFits ? 0 : 1;
}

- (void)snap_syncOverrideToStreamView {
    SnapRatioOverride override = SnapRatioOverrideNone;
    if (_oscAutoDetectApplicable) {
        override = ([self snap_effectiveRatioMode] == 0) ? SnapRatioOverrideSixteenNine : SnapRatioOverrideFull;
    }
    _streamView.snapRatioOverride = override;
}

- (void)toggleSnapRatio {
    NSInteger mode = [self snap_effectiveRatioMode] == 0 ? 1 : 0;
    if (_oscAutoDetectApplicable) {
        _snapRatioOverride = (mode == 0) ? SnapRatioOverrideSixteenNine : SnapRatioOverrideFull;
    } else {
        // Persist to NSUserDefaults so侧栏也能读到
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"snapScreenRatioMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        // 立即更新内存 settings
        _settings.snapScreenRatioMode = [NSNumber numberWithInteger:mode];
    }
    [self applySnapToTopAnimated:YES];
}

// Eased re-layout for ratio changes while the stream is up. The frames are
// model values, so touch mapping and the keyboard lift's originalFrame are
// final immediately; only the picture glides.
- (void)applySnapToTopAnimated:(BOOL)animated {
    if (!animated) {
        [self applySnapToTopIfNeeded];
        return;
    }
    [UIView animateWithDuration:0.3
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                     animations:^{ [self applySnapToTopIfNeeded]; }
                     completion:nil];
}

#pragma mark - OSC visibility & hide mode

// One visibility bit (`_oscHidden`, toggled by the right-edge swipe and driven
// by the letterbox detector) and one mode that decides what hidden means:
//   game    -> OscPresentationTranslucent (alpha ~0, still tappable)
//   desktop -> OscPresentationOff        (hidden + non-interactive, touch = mouse)
// Nothing is torn down in either state. The bottom chrome (mode / ratio / gyro /
// rotation buttons, time + battery) follows the visibility bit, which is why the
// old ON/OFF button could no longer own it: it hid together with the OSC.
//
// Auto mode needs the host display to match the iPad's aspect ratio (the
// "iPad-size" virtual display): a 16:9 game then arrives letterboxed inside the
// frame while the desktop fills it. On a plain 16:9 host nothing can be told
// apart, so the mode falls back to game and the manual visibility is persisted
// like before.
static NSString * const kOscHiddenKey = @"oscHidden";

- (OscHideMode)osc_effectiveHideMode {
    if (_oscModeOverride != OscHideModeAuto) return _oscModeOverride;
    if (!_oscAutoDetectApplicable) return OscHideModeGame;
    return (_oscDetectedContent == StreamContentClassGame) ? OscHideModeGame : OscHideModeDesk;
}

- (NSString *)osc_modeButtonTitle {
    switch (_oscModeOverride) {
        case OscHideModeGame: return @"GAME";
        case OscHideModeDesk: return @"DESK";
        case OscHideModeAuto: break;
    }
    return ([self osc_effectiveHideMode] == OscHideModeGame) ? @"AUTO·GAME" : @"AUTO·DESK";
}

- (void)osc_applyPresentation {
    OscPresentation presentation = OscPresentationShown;
    if (_oscHidden) {
        presentation = ([self osc_effectiveHideMode] == OscHideModeGame)
            ? OscPresentationTranslucent : OscPresentationOff;
    }
    [self->_streamView setOscPresentation:presentation];
    [self updateSnapRatioButton];
    [self layoutTimeBatteryCountdownDisplay];
}

- (void)setOscHidden:(BOOL)hidden {
    _oscHidden = hidden;
    if (!_oscAutoDetectApplicable) {
        [[NSUserDefaults standardUserDefaults] setBool:hidden forKey:kOscHiddenKey];
    }
    [self osc_applyPresentation];
}

// Right-edge swipe.
- (void)toggleOscVisibility {
    // Avoid interference when widget layout tool is open
    if (self->_streamView.widgetToolOpened) return;
    [self setOscHidden:!_oscHidden];
}

// Mode button tap: AUTO -> GAME -> DESK -> AUTO. Overrides last for this stream
// session and are dropped the moment the detector's verdict flips (the user
// corrected a misdetection; once the content really changes, auto resumes).
- (void)cycleOscHideMode {
    if (self->_streamView.widgetToolOpened) return;
    switch (_oscModeOverride) {
        case OscHideModeAuto: _oscModeOverride = OscHideModeGame; break;
        case OscHideModeGame: _oscModeOverride = OscHideModeDesk; break;
        case OscHideModeDesk: _oscModeOverride = OscHideModeAuto; break;
    }
    [self osc_applyPresentation];
}

// Per-stream setup, from connectionStarted (main queue): the renderer exists and
// the view has its final bounds by then. reConfigStreamViewRealtime also runs
// mid-stream (settings sheet closed), so it must NOT reset this state.
- (void)osc_configureForStream {
    _oscModeOverride = OscHideModeAuto;
    _oscDetectedContent = StreamContentClassUnknown;
    _snapRatioOverride = SnapRatioOverrideNone;
    _snapDetectedFits = NO;

    CGFloat streamAspect = (_streamConfig.height > 0) ? (CGFloat)_streamConfig.width / (CGFloat)_streamConfig.height : 0;
    self->_streamMan.videoRenderer.letterboxDetector.delegate = self;
    [self osc_updateAutoDetectApplicabilityForStreamAspect:streamAspect];

    if (_oscAutoDetectApplicable) {
        // Desktop until the detector says game: touch drives the mouse from the
        // first frame, and the OSC appears by itself once a game comes up.
        _oscHidden = YES;
    } else {
        _oscHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kOscHiddenKey];
    }
    [self osc_applyPresentation];
}

// Auto needs (a) decoded frames to look at and (b) a host display shaped like
// the screen. Re-evaluated on every stream aspect change, see
// handleStreamAspectRatioChanged:.
- (void)osc_updateAutoDetectApplicabilityForStreamAspect:(CGFloat)streamAspect {
    VideoDecoderRenderer *renderer = self->_streamMan.videoRenderer;
    CGSize bounds = self.view.bounds.size;
    CGFloat screenAspect = (bounds.height > 0) ? bounds.width / bounds.height : 0;
    BOOL applicable = renderer.providesDecodedFrames
        && streamAspect > 0 && screenAspect > 0
        && fabs(streamAspect - screenAspect) < 0.04;
    _oscAutoDetectApplicable = applicable;
    [renderer.letterboxDetector reset];
    renderer.letterboxDetector.enabled = applicable;
    Log(LOG_I, @"OSC auto hide-mode %@ (stream %.3f vs screen %.3f, decoded frames %d)",
        applicable ? @"enabled" : @"unavailable", streamAspect, screenAspect, renderer.providesDecodedFrames);
}

// Rotation / split view changes the screen aspect under a live stream. Only
// a change of the applicable flag is acted on, so a same-orientation relayout
// doesn't throw the detector's verdict away.
- (void)osc_reevaluateAutoDetectApplicabilityAfterLayout {
    if (!_hasConnectionStarted) return;
    VideoDecoderRenderer *renderer = self->_streamMan.videoRenderer;
    // The decoded aspect, not StreamView's: reConfig re-seeds that one from the
    // configured size and would hide a host resolution change.
    CGFloat streamAspect = renderer.streamAspectRatio > 0 ? renderer.streamAspectRatio : _streamView.streamAspectRatio;
    CGSize bounds = self.view.bounds.size;
    CGFloat screenAspect = (bounds.height > 0) ? bounds.width / bounds.height : 0;
    BOOL applicable = renderer.providesDecodedFrames
        && streamAspect > 0 && screenAspect > 0
        && fabs(streamAspect - screenAspect) < 0.04;
    if (applicable == _oscAutoDetectApplicable) return;
    [self osc_updateAutoDetectApplicabilityForStreamAspect:streamAspect];
    _oscDetectedContent = StreamContentClassUnknown;
    _snapDetectedFits = NO;
    _snapRatioOverride = SnapRatioOverrideNone;
    _oscModeOverride = OscHideModeAuto;
    if (!applicable) {
        // Back on a non-matching screen: the old manual visibility applies again.
        _oscHidden = [[NSUserDefaults standardUserDefaults] boolForKey:kOscHiddenKey];
    }
    if (!self->_streamView.widgetToolOpened) [self osc_applyPresentation];
    // The caller applies the snap layout right after this.
}

#pragma mark StreamLetterboxDetectorDelegate

- (void)letterboxDetector:(StreamLetterboxDetector *)detector
    didChangeContentClass:(StreamContentClass)contentClass
          fitsSixteenNine:(BOOL)fitsSixteenNine {
    if (detector != self->_streamMan.videoRenderer.letterboxDetector) return; // stale session
    BOOL classChanged = (contentClass != _oscDetectedContent);
    BOOL fitChanged = (fitsSixteenNine != _snapDetectedFits);
    _oscDetectedContent = contentClass;
    _snapDetectedFits = fitsSixteenNine;
    Log(LOG_I, @"OSC auto hide-mode: content is now %@, fits 16:9 %d",
        contentClass == StreamContentClassGame ? @"game" : @"desktop", fitsSixteenNine);
    if (classChanged) {
        _oscModeOverride = OscHideModeAuto;
        // Game -> bring the OSC up; desktop -> put it away so touch drives the mouse.
        _oscHidden = (contentClass != StreamContentClassGame);
    }
    if (fitChanged) {
        _snapRatioOverride = SnapRatioOverrideNone;
    }
    if (classChanged) [self backdrop_updateRegions]; // pause over letterbox bars
    // Never yank widgets out from under the layout editor; the state is kept and
    // applied by the next user action / reConfig.
    if (self->_streamView.widgetToolOpened) return;
    if (classChanged) [self osc_applyPresentation];
    if (fitChanged || classChanged) [self applySnapToTopAnimated:YES];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self stream_publishOrientationLockAndRefresh];
    
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
    _bgGracefulStopTask = UIBackgroundTaskInvalid;
    _bgStopEpoch = 0;

    _streamView = [[StreamView alloc] initWithFrame:self.view.frame];
    [self stream_publishOrientationLockAndRefresh];
    
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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleStreamAspectRatioChanged:)
                                                 name:@"StreamAspectRatioChanged"
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
        if (!_metalBackdropView) {
            _metalBackdropView = [[UIView alloc] initWithFrame:self.view.bounds];
            _metalBackdropView.backgroundColor = [UIColor blackColor];
            _metalBackdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _metalBackdropView.userInteractionEnabled = NO;
            _metalBackdropView.hidden = YES; // unhidden once streaming is configured
            [self.view insertSubview:_metalBackdropView atIndex:0];
        }
        // Insert Metal view at the bottom of the view hierarchy (above the backdrop)
        [self.view insertSubview:self.metalViewController.view aboveSubview:_metalBackdropView];
        [self.metalViewController didMoveToParentViewController:self];
        // Tell the widget reload which sibling is the video surface, so the
        // touchPad band anchors ABOVE it instead of above subviews[0] (which
        // is the backdrop after the layering pass — pads would otherwise get
        // buried under the opaque video on any post-layering widget reload).
        _streamView.metalVideoSiblingView = self.metalViewController.view;
    }

    // Snap-to-top must be (re)applied AFTER the Metal view controller exists:
    // the earlier reConfig pass in this method ran before it was created, so
    // its liftMetalVideoViewIfNeeded was a no-op — the touch layer was
    // shifted but the video wasn't until the next reConfig (e.g. toggling
    // anything in the sidebar), which is exactly the "snap not applied on
    // entry" symptom.
    [self applySnapToTopIfNeeded];

    _mainFrameViewcontroller.sessionLaunchedWithAbsoluteTouch = _settings.touchMode.intValue == AbsoluteTouch;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self teardownDummyEventLink];
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
            if (self->_hasLeftStreamPage) {
                return;
            }
            if (!online) {
                [self beginSelfHealReconnectLoopWithOverlay:YES];
            } else {
                [self startStreamManager];
            }
        });
    });
}

- (void)startStreamManager {
    // Central guard: async completions (initial probe, reconnect probes,
    // connection callbacks) must never start a session on a popped VC.
    if (_hasLeftStreamPage) return;
    if (_streamMan != nil) return;
    _hasConnectionStarted = NO;
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamVideoRenderView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
}

- (void)beginSelfHealReconnectLoopWithOverlay:(BOOL)showOverlay {
    // Same guard as startStreamManager: never revive on a popped VC.
    if (_hasLeftStreamPage) return;
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
                    // The probe outlives the loop: if the user already left the
                    // stream page (returnToMainFrame stopped the loop and nil'd
                    // the timer), starting a StreamManager here would create a
                    // zombie session on a popped view controller.
                    if (selfRef->_hasLeftStreamPage || selfRef->_reconnectTimer == nil) {
                        return;
                    }
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
    [self backdrop_updateRegions]; // the lift moves the picture under the capsules
}

- (void)keyboardWillHide{
    [_streamView keyboardWillHide];
    [self backdrop_updateRegions];
}

- (void)handleWidgetLayoutGesture{
    [self configOscLayoutTool];
    [self openWidgetLayoutTool];
}

- (void)openWidgetLayoutTool{
    _streamView.widgetToolOpened = true;
    [self stream_suspendOrientationLockAndRefresh];
    [self->_streamView disableOnScreenControls];
    [self->_streamView clearOnScreenWidgets]; // clear all onScreenKeyboardButtons before entering edit mode
    _layoutOnScreenControlsVC.toolbarStackView.hidden = false;
    _layoutOnScreenControlsVC.toolbarRootView.hidden = false;
    [self quickMenu_dismissAnimated:NO];
    [self presentViewController:_layoutOnScreenControlsVC animated:YES completion:nil];
}


- (void)bringUpSoftKeyboard{
    [self->_streamView readyToBringUpSoftKeyboardByToolbox];
}

- (void)enterPip{
    [self.pipController startPictureInPicture];
}

- (void)handleStreamAspectRatioChanged:(NSNotification *)notification {
    NSNumber *aspectRatioNum = notification.userInfo[@"aspectRatio"];
    if (aspectRatioNum && _streamView) {
        CGFloat aspectRatio = [aspectRatioNum doubleValue];
        Log(LOG_I, @"Updating StreamView aspect ratio to %.4f", aspectRatio);
        _streamView.streamAspectRatio = aspectRatio;

        // The host changed resolution mid-stream. If the stream no longer matches
        // the screen, letterboxing can't be read any more — and a game switching
        // the display to its own 16:9 mode is itself a strong "game" signal, so
        // bring the OSC up. Back to a matching aspect: auto resumes from scratch.
        BOOL wasApplicable = _oscAutoDetectApplicable;
        [self osc_updateAutoDetectApplicabilityForStreamAspect:aspectRatio];
        _oscDetectedContent = StreamContentClassUnknown;
        _snapDetectedFits = NO;
        _snapRatioOverride = SnapRatioOverrideNone;
        if (wasApplicable && !_oscAutoDetectApplicable) {
            _oscModeOverride = OscHideModeAuto;
            _oscHidden = NO;
        }
        if (!self->_streamView.widgetToolOpened) {
            [self osc_applyPresentation];
            [self applySnapToTopAnimated:YES];
        }
    }
}

- (void)oscLayoutClosed{
    // Handle the callback
    _streamView.widgetToolOpened = false;
    [self->_streamView disableOnScreenControls]; // add this to get realtime back menu working.
    [self->_streamView reloadOnScreenControlsWith:(ControllerSupport*)_controllerSupport
                                        andConfig:(StreamConfiguration*)_streamConfig];
    [self->_streamView showOnScreenControls];
    [self->_streamView reloadOnScreenWidgetViews]; //update keyboard buttons here
    [self stream_publishOrientationLockAndRefresh];
    // A detector verdict that arrived while the editor was open was recorded but
    // not applied (never yank widgets out from under the editor); apply it now.
    [self osc_applyPresentation];
    [self applySnapToTopIfNeeded];
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
        [self stream_suspendOrientationLockAndRefresh];
        [_controllerSupport cleanup];

        [UIApplication sharedApplication].idleTimerDisabled = NO;

        // Deliberate teardown of a healthy connection: the graceful
        // LiStopConnection lets the host tear its session down cleanly, so the
        // next connection needs no gamepad reattach. If the connection never
        // established or ended abnormally (error alert -> return to main), the
        // host may hold zombie state — keep the flag set so the next session
        // still reattaches.
        //
        // The flag is cleared only AFTER LiStopConnection completes: clearing
        // it before the async stop finishes raced against a late
        // connectionTerminated (connection already dead when the user exited,
        // e.g. after iOS suspended the app mid-stream). That race marked dirty
        // sessions as clean, so the next session skipped the gamepad reattach
        // and streamed into a host whose zombie session still held the pad
        // slot — OSC dead until the following reconnect.
        BOOL hadStarted = _hasConnectionStarted;
        // Strong capture on purpose: the block must outlive the pop (runs
        // ~0-2s later) to read the final abnormal-termination verdict. It is
        // not stored anywhere, so the VC is released right after it runs.
        [_streamMan stopStreamWithCompletion:^{
            // Hop to main to serialize with connectionTerminated's
            // main-queue work before reading the verdict. A detached
            // termination callback that was spawned but hadn't written the
            // flag when LiStopConnection returned can in principle still
            // lose this race, but that window is microseconds against the
            // seconds-long stop — and the failure mode is self-correcting
            // (flag wrongly cleared -> one session without reattach -> the
            // next abnormal end sets it again).
            dispatch_async(dispatch_get_main_queue(), ^{
                if (hadStarted && !self->_connectionEndedAbnormally) {
                    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"VoidStreamSessionDirty"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                } else if (hadStarted) {
                    NSLog(@"[InputDiag] exit with abnormal termination — keeping session dirty flag");
                }
            });
        }];

        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        if (_sessionHeartbeatTimer != nil) {
            [_sessionHeartbeatTimer invalidate];
            _sessionHeartbeatTimer = nil;
        }
        if (_timeBatteryUpdateTimer != nil) {
            [_timeBatteryUpdateTimer invalidate];
            _timeBatteryUpdateTimer = nil;
        }
        if (_streamCountdownUpdateTimer != nil) {
            [_streamCountdownUpdateTimer invalidate];
            _streamCountdownUpdateTimer = nil;
        }
        // _statsUpdateTimer retains self (target-based repeating timer): if any
        // exit path ever pops this VC without going through returnToMainFrame,
        // a live stats timer would leak the whole controller graph.
        if (_statsUpdateTimer != nil) {
            [_statsUpdateTimer invalidate];
            _statsUpdateTimer = nil;
        }
        _hasLeftStreamPage = YES;
        [self stopSelfHealReconnectLoop];
        if (self.metalViewController) {
            if (_streamView.metalVideoSiblingView == self.metalViewController.view) {
                _streamView.metalVideoSiblingView = nil;
            }
            [self.metalViewController.view removeFromSuperview];
            [self.metalViewController removeFromParentViewController];
            self.metalViewController = nil;
            NSLog(@"Metal renderer stopped and cleaned up.");
        }
        if (_metalBackdropView) {
            [_metalBackdropView removeFromSuperview];
            _metalBackdropView = nil;
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

- (void)prepareAutoEnterStateForReturnToMainFrameAllowingBackgroundResume:(BOOL)allowBackgroundResume {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (allowBackgroundResume) {
        NSString *lastHostName = [defaults stringForKey:@"AutoEnterLastStreamHostName"];
        if (lastHostName.length > 0) {
            [defaults setObject:lastHostName forKey:@"AutoEnterDesktopHostName"];
            [defaults setBool:YES forKey:@"AutoEnterTriggered"];
            [defaults removeObjectForKey:@"AutoEnterSuppressOnce"];
        }
        else {
            [defaults setBool:YES forKey:@"AutoEnterSuppressOnce"];
            [defaults setBool:NO forKey:@"AutoEnterTriggered"];
        }
    }
    else {
        [defaults setBool:YES forKey:@"AutoEnterSuppressOnce"];
        [defaults setBool:NO forKey:@"AutoEnterTriggered"];
    }
    [defaults synchronize];
}

- (void)returnToMainFrameAllowingBackgroundAutoResume:(BOOL)allowBackgroundResume {
    [self resetFinishedStreamCountdownToIdleIfNeeded];

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
    [_streamCountdownUpdateTimer invalidate];
    _streamCountdownUpdateTimer = nil;

    // Leaving the stream page must also cancel a running self-heal loop, or an
    // in-flight probe could revive the stream on a popped view controller.
    _hasLeftStreamPage = YES;
    [self stopSelfHealReconnectLoop];

    [self prepareAutoEnterStateForReturnToMainFrameAllowingBackgroundResume:allowBackgroundResume];
    [self.navigationController popToRootViewControllerAnimated:NO];
    
    _extWindow = nil;
    
    self.mainFrameViewcontroller.settingsExpandedInStreamView = false; // reset this flag to false
}

- (void) returnToMainFrame {
    [self returnToMainFrameAllowingBackgroundAutoResume:NO];
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

    [self returnToMainFrameAllowingBackgroundAutoResume:YES];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self backdrop_updateRegions];
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

    // Cancel any pending background graceful stop — the user came back while
    // the stream is still alive, so let it continue seamlessly.
    _bgStopEpoch++;
    [self endBackgroundGracefulStopTask];

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
    
    [self refreshStreamCountdownFromClockWithFeedback:YES];
    [self updateTimeBatteryDisplay];

    [self->_streamMan.videoRenderer resetFramePacing];
    _isRestoringFromPiP = NO;
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self resetFinishedStreamCountdownToIdleIfNeeded];
    [self backdrop_updateRegions]; // capsules are off screen: stop sampling (PiP keeps decoding)

    NSLog(@"did enter background, %d, %@, %d", _settings.enablePIP, self.pipController, self.pipController.isPictureInPictureActive);
    // Metal/MTKView command submission in the background gets the app killed by
    // the OS. PiP only needs the AVSampleBufferDisplayLayer fed, which is not
    // Metal work, so GPU renderers are paused whether or not PiP is active.
    if ([_settings.renderingBackend intValue] == RENDER_METAL && self.metalViewController) {
        Log(LOG_I, @"Pausing Metal renderer on background");
        [self.metalViewController pauseRendering];
    }

    if (self.imguiView && self.imguiView.mtkView) {
        self.imguiView.mtkView.paused = YES;
        self.imguiView.mtkView.enableSetNeedsDisplay = NO;
        Log(LOG_I, @"Pausing ImGui renderer on background");
    }

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }

    // Terminate the stream if the app is inactive for ... The 0-minute
    // ("disconnect") setting is handled synchronously below instead: a
    // 0-interval timer needs a runloop pass to fire, and iOS can freeze the
    // process before that happens (then applicationDidBecomeActive
    // invalidates it on thaw) — the stream then dies without a graceful
    // disconnect and the host keeps a zombie pad slot for its ping timeout.
    if (_settings.backgroundSessionTimer.intValue > 0) {
        Log(LOG_I, @"Starting inactivity termination timer with %d min", _settings.backgroundSessionTimer.intValue);
        _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60*(double)_settings.backgroundSessionTimer.intValue
                                      target:self
                                    selector:@selector(inactiveTimerExpired:)
                                    userInfo:nil
                                     repeats:NO];
    }

    // Guard against silent suspension (see the _bgGracefulStopTask ivar
    // comment). Backgrounded streaming normally survives on the `audio`
    // background mode (that's what the minutes-scale inactivity timer above
    // is designed around). But when that keep-alive is NOT holding — audio
    // route lost, another app took the session, system reclaiming us — iOS
    // suspends the app with the connection mid-air: no ENet disconnect ever
    // reaches the host, whose zombie session keeps the gamepad slot for its
    // full ping timeout, and a quick resume then streams into the wrong pad
    // slot (OSC dead all session). The background task below buys guaranteed
    // CPU; a watchdog polls backgroundTimeRemaining and tears the stream
    // down gracefully — with time to spare — once suspension looms. PiP and
    // AirPlay legitimately keep running — skip. Deliberate semantic choice:
    // that exemption also covers the 0-minute ("disconnect") immediate stop
    // below — PiP/AirPlay count as the user still watching, not as
    // backgrounding. (The legacy 0-interval inactivity timer used to kill
    // even an active PiP; nothing sane wants that.)
    BOOL pipActive = self.pipController && self.pipController.isPictureInPictureActive;
    NSLog(@"[InputDiag] didEnterBackground pip=%d airplay=%d leftPage=%d remaining=%.0fs",
          pipActive, [self isAirPlaying], _hasLeftStreamPage,
          [UIApplication sharedApplication].backgroundTimeRemaining);
    if (!_hasLeftStreamPage && !pipActive && ![self isAirPlaying]) {
        _bgStopEpoch++;
        NSUInteger epoch = _bgStopEpoch;
        [self endBackgroundGracefulStopTask];
        __weak typeof(self) weakSelf = self;
        __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
        bgTask = [[UIApplication sharedApplication]
            beginBackgroundTaskWithName:@"VoidGracefulStreamStop"
                      expirationHandler:^{
            // Fallback only — the watchdog below normally acts ~15s earlier.
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && epoch == strongSelf->_bgStopEpoch) {
                // Enqueue the teardown and end the task immediately (no time
                // budget left to wait on the linger).
                [strongSelf performBackgroundGracefulStopForEpoch:epoch endTaskAfterDelay:0];
            } else if (bgTask != UIBackgroundTaskInvalid &&
                       (!strongSelf || strongSelf->_bgGracefulStopTask == bgTask)) {
                // Stale/cancelled round whose task nobody else owns anymore
                // (or the VC is gone): end our own task so iOS doesn't kill
                // the process over an unfinished background task.
                [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
                if (strongSelf) {
                    strongSelf->_bgGracefulStopTask = UIBackgroundTaskInvalid;
                }
            }
        }];
        _bgGracefulStopTask = bgTask;
        if (bgTask == UIBackgroundTaskInvalid) {
            NSLog(@"[InputDiag] background watchdog: task DENIED by system");
        }
        if (_settings.backgroundSessionTimer.intValue == 0) {
            // "disconnect" keep-alive setting: stop synchronously while this
            // handler still has guaranteed CPU. The cleanup detach frees the
            // host's pad slots before the process can be frozen, so even a
            // swipe-kill right after this leaves no zombie holding slot 0 —
            // the next session's arrival binds the right pad immediately.
            NSLog(@"[InputDiag] background disconnect setting — stopping stream now");
            [self performBackgroundGracefulStopForEpoch:epoch endTaskAfterDelay:4.0];
        } else {
            [self scheduleBackgroundSuspensionWatchdogForEpoch:epoch afterDelay:2.0];
        }
    }

#if !TARGET_OS_TV

#endif
}

// Polls every 5s while backgrounded. With audio keep-alive holding,
// backgroundTimeRemaining stays effectively unbounded and streaming continues
// under the inactivity timer's authority; once the remaining budget starts
// draining (keep-alive lost, suspension approaching) we still have ~15s — do
// the graceful stop now and let the disconnect finish comfortably.
- (void)scheduleBackgroundSuspensionWatchdogForEpoch:(NSUInteger)epoch afterDelay:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || epoch != strongSelf->_bgStopEpoch) {
            return;  // foregrounded (cancel) or superseded by a newer round
        }
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            return;  // becameActive is about to cancel us anyway
        }
        NSTimeInterval remaining = [UIApplication sharedApplication].backgroundTimeRemaining;
        NSLog(@"[InputDiag] background watchdog poll: remaining=%.0fs", remaining);
        if (remaining < 20.0) {
            [strongSelf performBackgroundGracefulStopForEpoch:epoch endTaskAfterDelay:4.0];
        } else {
            [strongSelf scheduleBackgroundSuspensionWatchdogForEpoch:epoch afterDelay:4.0];
        }
    });
}

// One-shot (per _bgStopEpoch) graceful teardown while backgrounded. No-op if
// the user already returned to foreground or left the stream page. The
// background task is ended after `endTaskDelay` (bounded, non-blocking) so
// the async LiStopConnection can finish its ENet linger first; the delayed
// end captures the task id directly and thus survives the VC being released.
- (void)performBackgroundGracefulStopForEpoch:(NSUInteger)epoch endTaskAfterDelay:(NSTimeInterval)endTaskDelay {
    if (epoch != _bgStopEpoch) {
        return;  // cancelled (foregrounded) or already handled
    }
    _bgStopEpoch++;

    if (!_hasLeftStreamPage &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        Log(LOG_I, @"Gracefully stopping stream before background suspension");
        NSLog(@"[InputDiag] background graceful stop: tearing stream down before suspension");
        [self returnToMainFrameAllowingBackgroundAutoResume:YES];
    }

    UIBackgroundTaskIdentifier task = _bgGracefulStopTask;
    _bgGracefulStopTask = UIBackgroundTaskInvalid;
    if (task != UIBackgroundTaskInvalid) {
        if (endTaskDelay > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endTaskDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] endBackgroundTask:task];
            });
        } else {
            [[UIApplication sharedApplication] endBackgroundTask:task];
        }
    }
}

- (void)endBackgroundGracefulStopTask {
    if (_bgGracefulStopTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_bgGracefulStopTask];
        _bgGracefulStopTask = UIBackgroundTaskInvalid;
    }
}

// See the _sessionHeartbeatTimer ivar comment. Stops itself once the page is
// left or the connection ends abnormally — a heartbeat that kept beating past
// the connection's death would make the next session underestimate how long
// the host zombie still holds the pad slot.
- (void)startSessionHeartbeat {
    [_sessionHeartbeatTimer invalidate];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:[[NSDate date] timeIntervalSince1970] forKey:@"VoidStreamLastAliveAt"];
    __weak typeof(self) weakSelf = self;
    _sessionHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_hasLeftStreamPage || strongSelf->_connectionEndedAbnormally) {
            [timer invalidate];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setDouble:[[NSDate date] timeIntervalSince1970]
                                                  forKey:@"VoidStreamLastAliveAt"];
    }];
}

- (void)expandSettingsView{
    self.mainFrameViewcontroller.settingsExpandedInStreamView = true; //notify mainFrameViewContorller that this is a setting expansion in stream view, some settings shall be disabled.
    [_dummyEventLink setPaused:YES]; // keep-alive off while the settings menu is up
    [self.mainFrameViewcontroller expandSettingsView];
}

// Anti-stutter keep-alive (upstream 689221f1/03cf4631): fire a no-op input
// event once per frame so Wi-Fi power save can't idle the uplink between
// real inputs, which shows up as periodic stutter on non-AWDL networks.
- (void)startDummyEventLinkIfEnabled {
    if (_settings.sendDummyEvent) {
        if (!_dummyEventLink) {
            _dummyEventLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(dummyEventTick:)];
            if (_settings.framerate.intValue > 0) {
                _dummyEventLink.preferredFramesPerSecond = _settings.framerate.intValue;
            }
            [_dummyEventLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        }
        _dummyEventLink.paused = NO;
    }
    else {
        [_dummyEventLink setPaused:YES];
    }
}

- (void)dummyEventTick:(CADisplayLink *)link {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        // Key 0xFF doesn't exist, so the host discards the event; it only
        // has to keep the input socket busy.
        LiSendKeyboardEvent(0xFF, KEY_ACTION_UP, 0);
    });
}

- (void)teardownDummyEventLink {
    // The runloop retains the link's target (self); invalidate is what
    // actually breaks the cycle — paused alone would leak this VC.
    [_dummyEventLink invalidate];
    _dummyEventLink = nil;
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
    if (gestureRecognizer == _rightEdgeToggleOscRecognizer || gestureRecognizer == _rightEdgeOverControlRecognizer) {
        CustomEdgeSlideGestureRecognizer *edgeRecognizer = (CustomEdgeSlideGestureRecognizer *)gestureRecognizer;
        CGPoint location = [touch locationInView:gestureRecognizer.view];
        CGRect bounds = gestureRecognizer.view.bounds;
        // Must match the recognizer's own success window (EDGE_TOLERANCE): a touch
        // that can't possibly complete the gesture must not become a candidate.
        // The old code widened this to 24pt and pre-suppressed ALL OSC input for the
        // touch's whole lifetime (beginRightEdgeGestureSuppressionForTouch) — every
        // touch landing in the band froze the widgets, zeroed active sticks, and
        // left widgets that missed their touchesBegan computing stick offsets from
        // a stale anchor once the window lifted. The suppression machinery stays
        // dormant (never armed).
        CGFloat tolerance = edgeRecognizer.EDGE_TOLERANCE;
        BOOL withinEdge = NO;

        if (edgeRecognizer.edges & UIRectEdgeRight) {
            // Strict comparisons to match the recognizer's own success test
            // (CustomEdgeSlideGestureRecognizer touchesEnded).
            withinEdge = location.x > (CGRectGetMaxX(bounds) - tolerance);
        } else if (edgeRecognizer.edges & UIRectEdgeLeft) {
            withinEdge = location.x < tolerance;
        } else if (edgeRecognizer.edges & UIRectEdgeTop) {
            withinEdge = location.y <= tolerance;
        } else if (edgeRecognizer.edges & UIRectEdgeBottom) {
            withinEdge = location.y >= (CGRectGetMaxY(bounds) - tolerance);
        }

        if (!withinEdge) {
            return NO;
        }

        // Classify what sits under the touch. Two recognizers split the edge strip:
        //   - nothing / a UIControl / bare stream  → passive recognizer (observes,
        //     never delays or cancels the view's touches; decides on lift);
        //   - a tap-style OSC control (button widget of any slide mode, legacy
        //     face/shoulder/trigger/start/select layer) → over-control recognizer
        //     (delays the control's touchesBegan, decides within ~70–180ms);
        //   - a drag-style control (pad widget, legacy stick or d-pad) → neither.
        //     Dragging is that control's own language, so a leftward drag there is
        //     never an edge gesture (same rule as before this split).
        BOOL onTapControl = NO;
        BOOL onDragControl = NO;
        for (UIView *hitView = touch.view; hitView != nil; hitView = hitView.superview) {
            if ([hitView isKindOfClass:[OnScreenWidgetView class]]) {
                OnScreenWidgetView *widget = (OnScreenWidgetView *)hitView;
                if (widget.widgetType == WidgetTypeEnumButton) onTapControl = YES;
                else onDragControl = YES;
                break;
            }
        }
        if (!onTapControl && !onDragControl) {
            // Legacy CALayer OSC buttons don't appear as views.
            if ([self->_streamView pointHitsVisibleLegacyTapButton:location]) {
                onTapControl = YES;
            } else if ([self->_streamView pointHitsAnyVisibleLegacyOscButton:location]) {
                onDragControl = YES; // stick or d-pad layer
            }
        }
        if (onDragControl) {
            return NO;
        }
        if (gestureRecognizer == _rightEdgeOverControlRecognizer) {
            // Never withhold touches while the layout tool is open: dragging a
            // widget from the edge is the editor's primary interaction, and the
            // toggle is a no-op there anyway (toggleOscVisibility bails).
            if (self->_streamView.widgetToolOpened) {
                return NO;
            }
            return onTapControl;
        }
        return !onTapControl;
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
        // Video is about to appear: reveal the black backdrop (bottom-most).
        // The reConfig pass that normally does this ran during viewDidLoad,
        // BEFORE the Metal view/backdrop existed — without this, the strip
        // uncovered by the snap shift shows the themed background until the
        // next reConfig.
        if (self->_metalBackdropView && self->_metalBackdropView.superview) {
            [self.view sendSubviewToBack:self->_metalBackdropView];
            self->_metalBackdropView.hidden = NO;
        }

        [self->_streamView showOnScreenControls];
        [self osc_configureForStream];

        // Re-apply snap-to-top now that the view hierarchy is final-sized and
        // the Metal view (if any) exists — idempotent, covers any case where
        // the viewDidLoad-time application ran against pre-layout bounds.
        [self applySnapToTopIfNeeded];

        // 串流连接建立后，应用当前屏幕方向的方向锁定
        [self osc_applyLockForCurrentOrientation];
        
        // Dirty-session detection: the flag is raised while a stream connection
        // is live and only cleared on deliberate teardown. Seeing it already set
        // here means the previous connection ended without a graceful stop
        // (crash, force-kill, or a self-heal reconnect) — the host may then hold
        // a zombie gamepad slot that eats all OSC/controller input, so schedule
        // a protocol-level reattach. Must run BEFORE connectionEstablished sends
        // the first controller arrivals, so a kill in between still reads dirty.
        // See -reattachGamepadsAfterDirtySessionWithLastAlive:.
        BOOL previousSessionDirty;
        NSTimeInterval previousSessionLastAlive;
        {
            NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
            previousSessionDirty = [defaults boolForKey:@"VoidStreamSessionDirty"];
            // Snapshot the PREVIOUS session's heartbeat before this session
            // starts overwriting it below.
            previousSessionLastAlive = [defaults doubleForKey:@"VoidStreamLastAliveAt"];
            [defaults setBool:YES forKey:@"VoidStreamSessionDirty"];
            [defaults synchronize];
        }
        self->_connectionEndedAbnormally = NO;
        [self startSessionHeartbeat];

        [self->_controllerSupport connectionEstablished];

        if (previousSessionDirty) {
            NSLog(@"[InputDiag] previous session ended dirty — scheduling gamepad reattach");
            [self->_controllerSupport reattachGamepadsAfterDirtySessionWithLastAlive:previousSessionLastAlive];
        }

        if (self->_settings.statsOverlayEnabled) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
        
        // Start time and battery update timer (update every minute)
        [self restartTimeBatteryUpdateTimer];
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);

    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);

    if (errorCode != ML_ERROR_GRACEFUL_TERMINATION) {
        _connectionEndedAbnormally = YES;
    }

    // This callback fires on a moonlight-common thread, not main. Capture the
    // StreamManager we're tearing down in a local strong ref: we stop it below on
    // this thread, and the main-queue block nils the ivar only if it still points
    // at this same manager. Nil-ing the ivar directly from the main block would
    // race the `[... stopStream]` at the tail (main could win and send stopStream
    // to nil → old connection never torn down), and could also clobber a fresh
    // manager a later reconnect installed.
    StreamManager* terminatedStreamMan = _streamMan;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [self resetFinishedStreamCountdownToIdleIfNeeded];
        
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
                    NSString* errorHint = VLTerminationHintForErrorCode(errorCode);
                    if (errorHint != nil) {
                        message = [message stringByAppendingFormat:@"\n\n%@", errorHint];
                    }
                    break;
                }
            }
        }
        
        // For offline/network class errors, self-heal instead of blocking.
        // ML_ERROR_CONTROL_DISCONNECT_TIMEOUT / ML_ERROR_CONTROL_UNEXPECTED_DISCONNECT
        // are the control stream dropping (host crash or network blip) — the same
        // class of failure, reported as a bare -1 before common-c 48c4572c.
        if (portFlags != 0 || errorCode == ETIMEDOUT || errorCode == ECONNREFUSED ||
            errorCode == ML_ERROR_CONTROL_DISCONNECT_TIMEOUT ||
            errorCode == ML_ERROR_CONTROL_UNEXPECTED_DISCONNECT) {
            // Drop the dead StreamManager so startStreamManager (guarded by
            // `if (_streamMan != nil) return`) can actually build a fresh one when
            // the host comes back. Without this, self-heal probes detect "online"
            // but the restart is a no-op and the stream never resumes. Only clear
            // if the ivar still points at the manager that just terminated.
            if (self->_streamMan == terminatedStreamMan) {
                self->_streamMan = nil;
            }
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

    [terminatedStreamMan stopStream];
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

    _connectionEndedAbnormally = YES;

    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    // Callback thread, not main — capture the manager we're stopping so the main
    // block can nil the ivar by identity without racing the tail stopStream.
    // (See connectionTerminated: for the full rationale.)
    StreamManager* failedStreamMan = _streamMan;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [self resetFinishedStreamCountdownToIdleIfNeeded];
        
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
            // See connectionTerminated: drop the dead StreamManager so the self-heal
            // loop can rebuild one once the host is reachable again — by identity, to
            // avoid clobbering a manager a concurrent reconnect may have installed.
            if (self->_streamMan == failedStreamMan) {
                self->_streamMan = nil;
            }
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

    [failedStreamMan stopStream];
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
            // PiP is driven by the AVSampleBufferDisplayLayer content source. With
            // the Metal backend that layer exists but is never fed frames, so PiP
            // would show a blank window while keeping the app "active" in the
            // background — only offer PiP on the AVSB backend.
            if (self->_settings.enablePIP && [self->_settings.renderingBackend intValue] == RENDER_AVSB) {
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
    // Decoded 4K frames retained in already-consumed FrameQueue slots are the
    // biggest recreatable allocation we hold (up to ~15 IOSurface buffers).
    [[FrameQueue sharedInstance] purgeStaleSlots];
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
    if ([self osc_editorRotationLocked]) { return NO; } // honored on iOS < 16
    if ([self stream_orientationLockActive]) { return NO; }
    return YES;
}

// The OSC layout editor is presented OverCurrentContext, so UIKit consults THIS
// presenter (not the editor) for orientation. Honor the editor's rotation lock
// here so locking it actually freezes the screen while editing.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([self osc_editorRotationLocked]) {
        return [self osc_lockedOrientationMask];
    }
    if ([self stream_orientationLockActive]) {
        return gStreamOrientationLockedMask;
    }
    return [super supportedInterfaceOrientations]; // unchanged default when not locked
}

- (BOOL)osc_editorRotationLocked {
    UIViewController *presented = self.presentedViewController;
    return [presented isKindOfClass:[LayoutOnScreenControlsViewController class]]
        && [(LayoutOnScreenControlsViewController *)presented isRotationLocked];
}

- (UIInterfaceOrientationMask)osc_lockedOrientationMask {
    UIInterfaceOrientation cur = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene) { cur = scene.interfaceOrientation; }
    }
    switch (cur) {
        case UIInterfaceOrientationLandscapeLeft:      return UIInterfaceOrientationMaskLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:     return UIInterfaceOrientationMaskLandscapeRight;
        case UIInterfaceOrientationPortrait:           return UIInterfaceOrientationMaskPortrait;
        case UIInterfaceOrientationPortraitUpsideDown: return UIInterfaceOrientationMaskPortraitUpsideDown;
        default: break;
    }
    return (self.view.bounds.size.width > self.view.bounds.size.height)
        ? UIInterfaceOrientationMaskLandscape
        : UIInterfaceOrientationMaskPortrait;
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
        [self osc_reevaluateAutoDetectApplicabilityAfterLayout];
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
