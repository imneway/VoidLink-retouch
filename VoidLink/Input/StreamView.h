//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.16
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.


//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "VoidLink-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void)userInteractionBegan;
- (void)userInteractionEnded;
- (void)streamExitRequested;
- (void)toggleStatsOverlay;
- (void)toggleMouseCapture;
- (void)toggleMouseVisible;
// Ask the host agent to show/hide the Windows touch keyboard. Returns NO when
// no agent link is live, so the caller can fall back to a keystroke.
- (BOOL)requestHostTouchKeyboardToggle;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate, UIPencilInteractionDelegate>
#endif

@property (assign, nonatomic) UIView* streamFrameTopLayerView;
// The Metal video view when it renders as a SIBLING of this view on the top
// layer (nil in the AVSB path, where video renders inside this view). Widget
// reload anchors the touchPad band ABOVE it — see reloadOnScreenWidgetViews.
@property (weak, nonatomic) UIView* metalVideoSiblingView;
@property (assign, nonatomic) CGFloat streamAspectRatio;
@property (assign, nonatomic) CGRect originalFrame;
@property (assign, nonatomic) bool widgetToolOpened;


- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig
 streamFrameTopLayerView:(UIView* )topLayerView
;
- (void) showOnScreenControls;
- (void) setOnScreenControls;
- (void) disableOnScreenControls;
- (void) reloadOnScreenControlsRealtimeWith:(ControllerSupport*)controllerSupport
                          andConfig:(StreamConfiguration*)streamConfig;
- (void) reloadOnScreenControlsWith:(ControllerSupport*)controllerSupport
                          andConfig:(StreamConfiguration*)streamConfig;
- (void) clearOnScreenWidgets;
- (void) reloadOnScreenWidgetViews;

- (void)beginRightEdgeGestureSuppressionForTouch:(UITouch *)touch;
- (void)endRightEdgeGestureSuppression;
// Whether the point (in streamFrameTopLayerView coordinates) lands on a visible
// legacy OSC CALayer button. Forwarded to OnScreenControls for callers (the host
// VC's gesture delegate) that don't hold the OnScreenControls instance.
- (BOOL)pointHitsAnyVisibleLegacyOscButton:(CGPoint)point;
// Tap-style legacy layers only (no sticks / d-pad). See OnScreenControls.
- (BOOL)pointHitsVisibleLegacyTapButton:(CGPoint)point;

// How the OSC (legacy layers + widgets) is presented. The host VC picks the
// hidden flavour from its game/desktop mode: Translucent for games (alpha ~0,
// still tappable), Off for the desktop (hidden and non-interactive so touches
// reach the host as mouse / native touch). Nothing is torn down in either
// hidden state; a reload re-applies the current presentation.
typedef NS_ENUM(NSInteger, OscPresentation) {
    OscPresentationShown = 0,
    OscPresentationTranslucent,
    OscPresentationOff,
};
- (void)setOscPresentation:(OscPresentation)presentation;
- (OscPresentation)oscPresentation;

// Temporary suspension (the host agent parks the OSC behind an emulator's
// dialog / game list). While suspended the legacy OSC layers and every
// OnScreenWidgetView are hidden AND non-interactive, so touches reach the
// host as plain mouse / native touch input. Nothing is torn down: resuming
// just un-hides. Survives an OSC / widget reload (the reload re-applies it).
- (void)setOscTemporarilySuspended:(BOOL)suspended;
- (BOOL)isOscTemporarilySuspended;
// When set, finger touches that would reach the host (mouse / native touch)
// are withheld for as long as the OSC is active (Shown or Translucent, not
// held-suspended, not in the layout editor). OSC widgets and legacy layers
// still get their touches; pencil, trackpad and mouse are unaffected. For
// games that flip to a keyboard+mouse UI on any stray mouse event.
@property (nonatomic) BOOL blockStreamTouchesWhileOscActive;
// Same block, forced by the game on top (GameProfile) regardless of the switch.
@property (nonatomic) BOOL forceStreamTouchBlock;
// Main thread, at the start of every pencil contact that reached the stream
// (the pencil never touches the OSC). Used by per-game pencil -> DESK.
@property (nonatomic, copy, nullable) void (^pencilContactBegan)(void);
// Per-game: ignore the pencil's double tap (GameProfile).
@property (nonatomic) BOOL pencilDoubleTapDisabled;
// NSUserDefaults key behind it (settings sidebar switch).
extern NSString * const StreamViewBlockStreamTouchDefaultsKey;
// YES when the legacy OSC level is on or any widget is attached — i.e. there is
// something to suspend.
- (BOOL)hasAnyOnScreenControls;

// Multi-finger counting exemption. The finger holding the OSC mode button is
// on screen for the whole hold, and it shows up in [event allTouches] for every
// touch the stream receives — so a single left-hand tap would count as two
// fingers (right click / scroll / ignored in absolute mode) and a two-finger
// tap as three (keyboard toggle). Touch handlers and CustomTapGestureRecognizer
// route allTouches through +streamTouchesForEvent: to drop that finger.
+ (void)setMultiTouchExemptView:(UIView *)view;
+ (NSSet<UITouch *> *)streamTouchesForEvent:(UIEvent *)event;
+ (NSSet<UITouch *> *)streamTouchesFrom:(NSSet<UITouch *> *)touches;
// Same filters, but touches withheld by the OSC touch block still count. For gestures
// that must keep working while the stream itself ignores fingers (layout editor tap).
+ (NSSet<UITouch *> *)streamTouchesFrom:(NSSet<UITouch *> *)touches includingWithheld:(BOOL)includeWithheld;
+ (NSSet<UITouch *> *)streamTouchesForEvent:(UIEvent *)event includingWithheld:(BOOL)includeWithheld;

- (CGSize) getVideoAreaSize;
- (CGPoint) adjustCoordinatesForVideoArea:(CGPoint)point;
- (uint16_t)getRotationFromAzimuthAngle:(float)azimuthAngle;

// Expose current visual top offset (iPad-only; 0 elsewhere)
- (CGFloat) currentSnapOffset;
// Snap target override. None follows the persisted snapScreenRatioMode
// setting; the others force the target. Set by the host VC when the letterbox
// detector / a session tap decides the ratio.
typedef NS_ENUM(NSInteger, SnapRatioOverride) {
    SnapRatioOverrideNone = 0,
    SnapRatioOverrideSixteenNine,
    SnapRatioOverrideFull,
};
@property (assign, nonatomic) SnapRatioOverride snapRatioOverride;

- (OnScreenControlsLevel) getCurrentOscState;

-(void)readyToBringUpSoftKeyboardByToolbox;
- (void)toggleKeyboard;
- (void)keyboardWillShow:(NSNotification *)notification;
- (void)keyboardWillHide;
- (void)liftMetalVideoViewIfNeeded:(CGFloat)liftHeight;
// Extra upward shift currently applied for the on-screen keyboard (0 when it
// is down). The host VC keeps it when it re-bases the snap offset.
- (CGFloat)activeKeyboardLift;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
