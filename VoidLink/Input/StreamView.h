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

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
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

// Obscure OSC layers by alpha while keeping them interactive
- (void)setOscObscuredByAlpha:(BOOL)enabled;
- (BOOL)isOscObscuredByAlpha;

// Hold-to-suspend for the OSC ON/OFF button. While suspended the legacy OSC
// layers and every OnScreenWidgetView are hidden AND non-interactive, so the
// other hand's touches reach the host as plain mouse / native touch input.
// Nothing is torn down: resuming just un-hides. Survives an OSC / widget reload
// that happens mid-hold (the reload re-applies the suspension).
- (void)setOscTemporarilySuspended:(BOOL)suspended;
- (BOOL)isOscTemporarilySuspended;
// YES when the legacy OSC level is on or any widget is attached — i.e. there is
// something for a hold to suspend.
- (BOOL)hasAnyOnScreenControls;
// Whether any touch landed on the stream since the current suspension began.
// The host VC uses it to tell a plain tap on the button (toggle) from a hold
// during which the other hand operated the PC (never toggle).
- (BOOL)oscSuspensionSawStreamTouch;

// Multi-finger counting exemption. The finger holding the OSC ON/OFF button is
// on screen for the whole hold, and it shows up in [event allTouches] for every
// touch the stream receives — so a single left-hand tap would count as two
// fingers (right click / scroll / ignored in absolute mode) and a two-finger
// tap as three (keyboard toggle). Touch handlers and CustomTapGestureRecognizer
// route allTouches through +streamTouchesForEvent: to drop that finger.
+ (void)setMultiTouchExemptView:(UIView *)view;
+ (NSSet<UITouch *> *)streamTouchesForEvent:(UIEvent *)event;
+ (NSSet<UITouch *> *)streamTouchesFrom:(NSSet<UITouch *> *)touches;

- (CGSize) getVideoAreaSize;
- (CGPoint) adjustCoordinatesForVideoArea:(CGPoint)point;
- (uint16_t)getRotationFromAzimuthAngle:(float)azimuthAngle;

// Expose current visual top offset (iPad-only; 0 elsewhere)
- (CGFloat) currentSnapOffset;

- (OnScreenControlsLevel) getCurrentOscState;

-(void)readyToBringUpSoftKeyboardByToolbox;
- (void)keyboardWillShow:(NSNotification *)notification;
- (void)keyboardWillHide;
- (void)liftMetalVideoViewIfNeeded:(CGFloat)liftHeight;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

@end
