//
//  StreamView.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.

//  Modified by True砖家 since 2024.6.1
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "StreamView.h"
#include <Limelight.h>
#import "DataManager.h"
#import "TemporarySettings.h"
#import "Plot.h"
#import "ControllerSupport.h"
#import "KeyboardSupport.h"
#import "VoidLink-Swift.h"
#import "OSCProfilesManager.h"
#import "NativeTouchPointer.h"
#import "NativeTouchHandler.h"
#import "PureNativeTouchHandler.h"
#import "RelativeTouchHandler.h"
#import "AbsoluteTouchHandler.h"
#import "KeyboardInputField.h"
#import "CustomTapGestureRecognizer.h"
#import "LocalizationHelper.h"


static const double X1_MOUSE_SPEED_DIVISOR = 2.5;

static BOOL RSPADALT2ValueNear(CGFloat value, CGFloat target, CGFloat tolerance) {
    return fabs(value - target) < tolerance;
}

static BOOL RSPADALT2ShouldMigrateLegacyAimDefaults(OnScreenWidgetView *widgetView, OnScreenButtonState *buttonState) {
    if (!widgetView.hasAimTweak || buttonState.aimTuningVersion > 0) {
        return NO;
    }

    BOOL legacyFirstPreset =
        RSPADALT2ValueNear(buttonState.stickInputScale, 55, 0.5) &&
        RSPADALT2ValueNear(buttonState.stickResponseExponent, 1.62, 0.02) &&
        RSPADALT2ValueNear(buttonState.aimMaxOutputScale, 0.72, 0.02);
    BOOL legacyDeadZonePreset =
        RSPADALT2ValueNear(buttonState.stickInputScale, 55, 0.5) &&
        RSPADALT2ValueNear(buttonState.stickResponseExponent, 1.12, 0.02) &&
        RSPADALT2ValueNear(buttonState.aimMaxOutputScale, 0.90, 0.02);
    BOOL legacyRSVPADPreset =
        RSPADALT2ValueNear(buttonState.stickInputScale, 55, 0.5) &&
        RSPADALT2ValueNear(buttonState.stickResponseExponent, 1.00, 0.02) &&
        RSPADALT2ValueNear(buttonState.aimMaxOutputScale, 1.00, 0.02);
    BOOL legacyCumulativePreset =
        RSPADALT2ValueNear(buttonState.stickInputScale, 35, 0.5) &&
        RSPADALT2ValueNear(buttonState.stickResponseExponent, 1.00, 0.02) &&
        RSPADALT2ValueNear(buttonState.aimMaxOutputScale, 1.00, 0.02);

    return legacyFirstPreset || legacyDeadZonePreset || legacyRSVPADPreset || legacyCumulativePreset;
}

static BOOL RSPADALT2ShouldMigrateLinearAimDefaults(OnScreenWidgetView *widgetView, OnScreenButtonState *buttonState) {
    if (!widgetView.hasAimTweak || buttonState.aimTuningVersion != 2) {
        return NO;
    }

    BOOL previousLinearDefault =
        RSPADALT2ValueNear(buttonState.aimTrackpadGain, 5.20, 0.05) &&
        (RSPADALT2ValueNear(buttonState.aimTrackpadDeadzoneCompensation, 0.16, 0.02) ||
         RSPADALT2ValueNear(buttonState.aimTrackpadDeadzoneCompensation, 0.00, 0.005)) &&
        RSPADALT2ValueNear(buttonState.aimTrackpadResponseDuration, 0.060, 0.005) &&
        RSPADALT2ValueNear(buttonState.aimMaxOutputScale, 0.92, 0.02);

    return previousLinearDefault;
}

/*
 Stream Video has been moved out of this class to _renderView in StreamFrameViewController.
 */
@implementation StreamView {
    UIView* streamFrameTopLayerView;
    TemporarySettings* settings;
    
    OnScreenControls* onScreenControls;
    
    KeyboardInputField* keyInputField;
    BOOL isInputingText;
    NSMutableSet* keysDown;
    float streamAspectRatio;


    
    // iOS 13.4 mouse support
    NSInteger lastMouseButtonMask;
    float lastMouseX;
    float lastMouseY;
    CGPoint lastScrollTranslation;
    
    // Citrix X1 mouse support
    X1Mouse* x1mouse;
    double accumulatedMouseDeltaX;
    double accumulatedMouseDeltaY;
    
    int localMousePointerMode;
    
    UIResponder* touchHandler;
    
    id<UserInteractionDelegate> interactionDelegate;
    NSTimer* interactionTimer;
    BOOL hasUserInteracted;
    
    NSDictionary<NSString *, NSNumber *> *dictCodes;
    CustomTapGestureRecognizer *keyboardToggleRecognizer;
    UIPanGestureRecognizer *discreteMouseWheelRecognizer;
    UIPanGestureRecognizer *continuousMouseWheelRecognizer;
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    UIHoverGestureRecognizer *stylusHoverRecognizer;
#endif
    CGFloat HeightViewLiftedTo;
    UILabel* keyboardToggleTip;
    
    UIKeyModifierFlags comboKeyModifierFlags;

    BOOL oscGestureSuppressed;
    NSUInteger rightEdgeGestureSuppressionDepth;
    NSMutableSet* suppressedGestureTouchAddrs;
}

- (CGFloat)currentSnapOffset {
    DataManager* dm = [[DataManager alloc] init];
    TemporarySettings* s = [dm getSettings];
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (!isPad) {
        return 0.0f;
    }
    if (s.snapScreenToTop) {
        // 只对“外部黑边”（设备 vs 实际串流宽高比）对齐，避免触点映射偏移
        CGFloat viewWidth = self.bounds.size.width;
        CGFloat viewHeight = self.bounds.size.height;
        CGFloat frameAspect = self->streamAspectRatio; // 实际视频帧宽高比
        if (frameAspect <= 0.0f) frameAspect = 16.0f/9.0f;
        CGFloat frameHeight = viewWidth / frameAspect; // iPad：按宽等比
        CGFloat topBlackBar = (viewHeight - frameHeight) / 2.0f;
        if (topBlackBar < 0) topBlackBar = 0;
        return topBlackBar;
    }
    return 0.0f;
}

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig
 streamFrameTopLayerView:(UIView* )topLayerView{
    self->comboKeyModifierFlags = (UIKeyModifierControl|UIKeyModifierAlternate|UIKeyModifierShift);

    self->streamFrameTopLayerView = topLayerView;
    self.streamFrameTopLayerView = topLayerView; // this will be used as a read-only pointer for other class
    self->interactionDelegate = interactionDelegate;
    self->streamAspectRatio = (float)streamConfig.width / (float)streamConfig.height;
    self.streamAspectRatio = self->streamAspectRatio;
    
    settings = [[[DataManager alloc] init] getSettings];
    
    localMousePointerMode = streamConfig.localMousePointerMode;
    
    keysDown = [[NSMutableSet alloc] init];
    suppressedGestureTouchAddrs = [NSMutableSet set];
    rightEdgeGestureSuppressionDepth = 0;
    oscGestureSuppressed = NO;
    // Guarantee a clean, non-suppressed input state on every (re)configuration so a
    // right-edge suppression that never received its matching "end" can't leave OSC
    // input dead until force-quit. Clears the process-wide static too.
    [OnScreenWidgetView forceResetGestureSuppression];
    keyInputField = [[KeyboardInputField alloc] initWithFrame:CGRectZero];
    [keyInputField setKeyboardType:UIKeyboardTypeDefault];
    [keyInputField setAutocorrectionType:UITextAutocorrectionTypeNo];
    [keyInputField setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [keyInputField setSpellCheckingType:UITextSpellCheckingTypeNo];
    [self addSubview:keyInputField];
    
    isInputingText = false;
    [self refreshKeyboardToggleRecognizer:settings.keyboardToggleFingers.intValue]; //will be
    keyboardToggleTip = [[UILabel alloc] init];
    // keyboardToggleTip.frame = CGRectMake(0, 0, 35, 100);
    keyboardToggleTip.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    keyboardToggleTip.text = [LocalizationHelper localizedStringForKey:@"Tap where you're going to input text, view will be lifted automatically  "];
    keyboardToggleTip.font = [UIFont systemFontOfSize:25];
    keyboardToggleTip.textAlignment = NSTextAlignmentCenter;
    keyboardToggleTip.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    keyboardToggleTip.userInteractionEnabled = false;
    keyboardToggleTip.numberOfLines = 1;
    keyboardToggleTip.layer.cornerRadius = 10;
    keyboardToggleTip.clipsToBounds = true;
    NSLog(@"setup streamView %f", CACurrentMediaTime());
    
    // if(settings.touchMode.intValue == NativeTouchOnly) [self addGestureRecognizer:keyboardToggleRecognizer]; //keep legacy approach in pure native mode
    // else [self->streamFrameTopLayerView addGestureRecognizer:keyboardToggleRecognizer]; //add to the superview in other modes
    
    // [self->streamFrameTopLayerView addGestureRecognizer:keyboardToggleRecognizer]; //add to the superview in other modes
    
#if TARGET_OS_TV
    // tvOS requires RelativeTouchHandler to manage Apple Remote input
    self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
#else
    // iOS uses touch Mode depending on user preference
        
    switch (settings.touchMode.intValue) {
        case NativeTouch:
            keyboardToggleRecognizer.immediateTriggering = false;
            self->touchHandler = [[NativeTouchHandler alloc] initWithView:self andSettings:settings];break;
        case NativeTouchOnly:
            keyboardToggleRecognizer.immediateTriggering = false;
            self->touchHandler = [[PureNativeTouchHandler alloc] initWithView:self andSettings:settings];break;
        case RelativeTouch:
            self->touchHandler = [[RelativeTouchHandler alloc] initWithView:self andSettings:settings];
            keyboardToggleRecognizer.immediateTriggering = false;
            // if(settings.onscreenControls.intValue == OnScreenControlsLevelCustom) keyboardToggleRecognizer.numberOfTouchesRequired = 3; //deprecated: fixing keyboard taps to 3, in order to invoke OSC rebase in stream view by 4-finger tap.
            break;
        case AbsoluteTouch:
            self->touchHandler = [[AbsoluteTouchHandler alloc] initWithView:self];
            keyboardToggleRecognizer.immediateTriggering = true; //triggers signal in touchesBegan callback stage
            break;
            
        default:
            break;
    }
    
    // we'll render on-screen controls on the toplayer too:
    onScreenControls = [[OnScreenControls alloc] initWithView:self->streamFrameTopLayerView controllerSup:controllerSupport streamConfig:streamConfig];  // don't delete, this is mandatory
    /*
    // here we pass the tap recognizer to the onscreencontrols obj
    if (settings.touchMode.intValue == RelativeTouch){
        RelativeTouchHandler* relativeTouchHandler = (RelativeTouchHandler*) touchHandler;
        onScreenControls.mouseRightClickTapRecognizer = relativeTouchHandler.mouseRightClickTapRecognizer;
    } */
    
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    if (settings.touchMode.intValue != RelativeTouch && settings.touchMode.intValue != NativeTouch ) {
        Log(LOG_I, @"On-screen controls disabled in non-relative touch mode");
        [onScreenControls setLevel:OnScreenControlsLevelOff];
        
        //pass touchesCaptureByOnScreenButtons Set to the native touchhandler, this NSSet is init witihin onscreencontrols class, don't do it again in native touch handler class
        [OnScreenControls.touchAddrsCapturedByOnScreenControls removeAllObjects]; // reset the attribute to nil
        
        /*
        if(settings.touchMode.intValue == NativeTouch){
            NativeTouchHandler* nativeTouchHandler = (NativeTouchHandler* )touchHandler;
            nativeTouchHandler.touchesCapturedByOnScreenButtons = onScreenControls.touchesCapturedByOnScreenButtons;
            touchHandler = nativeTouchHandler;
        }; // pass touchHandler to onScreenControl
         */
    }
    //else if (level == OnScreenControlsLevelAuto) {
    else if (false) { // level auto cancelled in settings
        [controllerSupport initAutoOnScreenControlMode:onScreenControls];
    }
    else {
        Log(LOG_I, @"Setting manual on-screen controls level: %d", (int)level);
        [onScreenControls setLevel:level];
    }
    // It would be nice to just use GCMouse on iOS 14+ and the older API on iOS 13
    // but unfortunately that isn't possible today. GCMouse doesn't recognize many
    // mice correctly, but UIKit does. We will register for both and ignore UIKit
    // events if a GCMouse is connected.
    if (@available(iOS 13.4, *)) {
        [self addInteraction:[[UIPointerInteraction alloc] initWithDelegate:self]];
        
        UIPanGestureRecognizer *discreteMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedDiscrete:)];
        discreteMouseWheelRecognizer.maximumNumberOfTouches = 0;
        discreteMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskDiscrete;
        discreteMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:discreteMouseWheelRecognizer];
        
        UIPanGestureRecognizer *continuousMouseWheelRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheelMovedContinuous:)];
        continuousMouseWheelRecognizer.maximumNumberOfTouches = 0;
        continuousMouseWheelRecognizer.allowedScrollTypesMask = UIScrollTypeMaskContinuous;
        continuousMouseWheelRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        [self addGestureRecognizer:continuousMouseWheelRecognizer];
    }
    
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        UIHoverGestureRecognizer *stylusHoverRecognizer = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(sendStylusHoverEvent:)];
        stylusHoverRecognizer.allowedTouchTypes = @[@(UITouchTypePencil)];
        [self addGestureRecognizer:stylusHoverRecognizer];
    }
#endif
#endif
    
    x1mouse = [[X1Mouse alloc] init];
    x1mouse.delegate = self;
    
    if (settings.btMouseSupport) {
        [x1mouse start];
    }
    
    // This is critical to ensure keyboard events are delivered to this
    // StreamView and not our parent UIView, especially on tvOS.
    [self becomeFirstResponder];

    // Apply base snap offset for Metal renderer if needed at startup
    [self liftMetalVideoViewIfNeeded:0];

}


- (void)refreshKeyboardToggleRecognizer:(uint8_t)numberOfTouches{
    [self->_streamFrameTopLayerView removeGestureRecognizer:keyboardToggleRecognizer];
    keyboardToggleRecognizer = [[CustomTapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleKeyboard)];
    keyboardToggleRecognizer.numberOfTouchesRequired = numberOfTouches; //will be changed accordinly by touch modes.
    keyboardToggleRecognizer.tapDownTimeThreshold = 0.2; // tap down time threshold in seconds.
    keyboardToggleRecognizer.delaysTouchesBegan = NO;
    keyboardToggleRecognizer.delaysTouchesEnded = NO;
    [self->_streamFrameTopLayerView addGestureRecognizer:keyboardToggleRecognizer];
}

- (void)keyboardWillShow:(NSNotification *)notification{
    // NSLog(@"keyboard will show markmark %f", CACurrentMediaTime());
    if(settings.liftStreamViewForKeyboard && !isInputingText){
        NSDictionary *userInfo = notification.userInfo;
        // Get the keyboard size from the notification
        CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        // NSLog(@"keyboard will show markmark, lowest height %f", keyboardToggleRecognizer.lowestTouchPointHeight);
        if(keyboardFrame.size.height < CGRectGetHeight([[UIScreen mainScreen] bounds]) * 0.25) return; // return in case of abnormal keyboard height
        HeightViewLiftedTo = keyboardFrame.size.height - keyboardToggleRecognizer.lowestTouchPointHeight + CGRectGetHeight([[UIScreen mainScreen] bounds]) * 0.1; // lift the StreamView to the height of lowest touch point of multi-finger tap gesture, while reserving the view of 1/10 screen height for remote typing.
        if(HeightViewLiftedTo < 0) HeightViewLiftedTo = 0;  // set HeightViewLiftedTo to 0 if it is high enough and not going to be covered by keyboard.
        CGRect liftedStreamFrame = self.frame;
        liftedStreamFrame.origin.y -= HeightViewLiftedTo;
        self.frame = liftedStreamFrame;
        
        // Also lift Metal video view if using Metal rendering backend
        [self liftMetalVideoViewIfNeeded:HeightViewLiftedTo];
        
        isInputingText = true;
        [self refreshKeyboardToggleRecognizer:settings.keyboardToggleFingers.intValue];
        [keyboardToggleTip removeFromSuperview];
    }
    NSLog(@"keyboard will show %f", CACurrentMediaTime());
}

// this method also deals with recovering streamview when local keyboard is turned off
- (void)keyboardWillHide{
    // NSLog(@"keyboard will hide markmark %f", CACurrentMediaTime());

    keyboardToggleRecognizer.numberOfTouchesRequired = settings.keyboardToggleFingers.intValue; // reset this number
    if(isInputingText){
        self.frame = _originalFrame;
        
        // Also restore Metal video view if using Metal rendering backend
        [self liftMetalVideoViewIfNeeded:0];
        
        isInputingText = NO;
    }
}

- (void)liftMetalVideoViewIfNeeded:(CGFloat)liftHeight {
    // Check if we're using Metal rendering backend
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    if ([currentSettings.renderingBackend intValue] == RENDER_METAL) {
        CGFloat baseOffset = [self currentSnapOffset];
        CGFloat finalLift = baseOffset + liftHeight;
        // Find the StreamFrameViewController that contains the MetalViewController
        UIViewController* parentVC = nil;
        UIResponder* responder = self.streamFrameTopLayerView;
        while (responder && ![responder isKindOfClass:[UIViewController class]]) {
            responder = [responder nextResponder];
        }
        
        if ([responder isKindOfClass:[UIViewController class]]) {
            parentVC = (UIViewController*)responder;
            
            // Check if this is StreamFrameViewController with metalViewController property
            if ([parentVC respondsToSelector:@selector(metalViewController)]) {
                id metalViewController = [parentVC performSelector:@selector(metalViewController)];
                
                if (metalViewController && [metalViewController respondsToSelector:@selector(view)]) {
                    UIView* metalView = [metalViewController performSelector:@selector(view)];
                    
                    if (metalView) {
                        CGRect metalFrame = metalView.frame;
                        metalFrame.origin.y = -finalLift;
                        metalView.frame = metalFrame;
                        NSLog(@"Applied Metal video y-offset: %f (base %f + lift %f)", -finalLift, baseOffset, liftHeight);
                    }
                }
            }
        }
    }
}

-(void)readyToBringUpSoftKeyboardByToolbox{
    NSLog(@"change num of fingers required");
    [self refreshKeyboardToggleRecognizer:1];
    keyboardToggleTip.translatesAutoresizingMaskIntoConstraints = NO;
    NSLog(@"tip obj: %@", keyboardToggleTip);
    [self addSubview:keyboardToggleTip];
    [NSLayoutConstraint activateConstraints:@[
        [keyboardToggleTip.centerXAnchor constraintEqualToAnchor:self.centerXAnchor constant:0],
        [keyboardToggleTip.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-self.bounds.size.height*0.35],
        [keyboardToggleTip.heightAnchor constraintEqualToConstant:50]

        // reserve height for navigation bar
    ]];

}


- (void)toggleKeyboard{
    // NSLog(@"toggleKeyboard markmark, %d", isInputingText);
    if (isInputingText) {
        Log(LOG_D, @"Closing the keyboard");
        [keyInputField resignFirstResponder];
    } else {
        Log(LOG_D, @"Opening the keyboard");
        // Prepare the textbox used to capture keyboard events.
        keyInputField.delegate = self;
        keyInputField.text = @"0";
    #if !TARGET_OS_TV
    // Prepare the toolbar above the keyboard for more options
        if(settings.showKeyboardToolbar){
            UIToolbar *customToolbarView = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 44)];
            UIBarButtonItem *doneBarButton = [self createButtonWithImageNamed:@"DoneIcon.png" backgroundColor:[UIColor clearColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x00 isToggleable:NO];
            UIBarButtonItem *windowsBarButton = [self createButtonWithImageNamed:@"WindowsIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x5B isToggleable:YES];
            UIBarButtonItem *tabBarButton = [self createButtonWithImageNamed:@"TabIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x09 isToggleable:NO];
            UIBarButtonItem *shiftBarButton = [self createButtonWithImageNamed:@"ShiftIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0xA0 isToggleable:YES];
            UIBarButtonItem *escapeBarButton = [self createButtonWithImageNamed:@"EscapeIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x1B isToggleable:NO];
            UIBarButtonItem *controlBarButton = [self createButtonWithImageNamed:@"ControlIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x11 isToggleable:YES];
            UIBarButtonItem *altBarButton = [self createButtonWithImageNamed:@"AltIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x12 isToggleable:YES];
            UIBarButtonItem *deleteBarButton = [self createButtonWithImageNamed:@"DeleteIcon.png" backgroundColor:[UIColor blackColor] target:self action:@selector(toolbarButtonClicked:) keyCode:0x2E isToggleable:NO];
            UIBarButtonItem *flexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            
            [customToolbarView setItems:[NSArray arrayWithObjects:doneBarButton, windowsBarButton, escapeBarButton, tabBarButton, shiftBarButton, controlBarButton, altBarButton, deleteBarButton, flexibleSpace, nil]];
            keyInputField.inputAccessoryView = customToolbarView;
        }
    #endif
        [keyInputField becomeFirstResponder];
        [keyInputField addTarget:self action:@selector(onKeyboardPressed:) forControlEvents:UIControlEventEditingChanged];
        // Undo causes issues for our state management, so turn it off
        [keyInputField.undoManager disableUndoRegistration];
        
        //[keyboardToggleTip removeFromSuperview];
    }
}

- (void)startInteractionTimer {
    // Restart user interaction tracking
    hasUserInteracted = NO;
    
    BOOL timerAlreadyRunning = interactionTimer != nil;
    
    // Start/restart the timer
    [interactionTimer invalidate];
    interactionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                        target:self
                        selector:@selector(interactionTimerExpired:)
                        userInfo:nil
                        repeats:NO];
    
    // Notify the delegate if this was a new user interaction
    if (!timerAlreadyRunning) {
        [interactionDelegate userInteractionBegan];
    }
}

- (void)interactionTimerExpired:(NSTimer *)timer {
    if (!hasUserInteracted) {
        // User has finished touching the screen
        interactionTimer = nil;
        [interactionDelegate userInteractionEnded];
    }
    else {
        // User is still touching the screen. Restart the timer.
        [self startInteractionTimer];
    }
}

- (void) showOnScreenControls {
#if !TARGET_OS_TV
    if(!_widgetToolOpened) [onScreenControls show];
#endif
}

- (void) setOnScreenControls{

}

- (void) disableOnScreenControls {
#if !TARGET_OS_TV
    [onScreenControls setLevel:OnScreenControlsLevelOff];
#endif
}


// we'll enable on screen buttons, and disable on screen controllers for absolute touch
- (bool) isOscEnabled{
    return (settings.touchMode.intValue == RelativeTouch || settings.touchMode.intValue == NativeTouch) && settings.onscreenControls.intValue != OnScreenControlsLevelOff;
}

// we'll enable on screen buttons, and disable on screen controllers for absolute touch
- (bool) isOnScreenButtonEnabled{
    return (settings.touchMode.intValue == RelativeTouch || settings.touchMode.intValue == NativeTouch || settings.touchMode.intValue == AbsoluteTouch) && settings.onscreenControls.intValue == OnScreenControlsLevelCustom;
}

- (void) reloadOnScreenControlsRealtimeWith:(ControllerSupport*)controllerSupport
                         andConfig:(StreamConfiguration*)streamConfig {
    [self reloadOnScreenControlsWith:controllerSupport andConfig:streamConfig];
    if([self isOscEnabled]) [self showOnScreenControls];
    else [self disableOnScreenControls];
}

// Obscure OSC layers by alpha while keeping them interactive
- (void)setOscObscuredByAlpha:(BOOL)enabled {
#if !TARGET_OS_TV
    if (onScreenControls) {
        [onScreenControls setObscuredByAlpha:enabled];
    }
#endif
}

- (BOOL)isOscObscuredByAlpha {
#if !TARGET_OS_TV
    return onScreenControls ? [onScreenControls isObscuredByAlpha] : NO;
#else
    return NO;
#endif
}


- (void) reloadOnScreenControlsWith:(ControllerSupport*)controllerSupport
                         andConfig:(StreamConfiguration*)streamConfig {
    // 清理旧实例的所有图层，避免重复叠加
    if (onScreenControls != nil) {
        [onScreenControls setLevel:OnScreenControlsLevelOff];
    }
    
    // we'll render on-screen controllers on the toplayer too.
    onScreenControls = [[OnScreenControls alloc] initWithView:self->streamFrameTopLayerView controllerSup:controllerSupport streamConfig:streamConfig];
    /*
    // pass mouseRightClickTapRecognizer to onScreenControls obj here:
    if([self isOscEnabled]){
        
        RelativeTouchHandler* relativeTouchHandler = (RelativeTouchHandler *)touchHandler;
        onScreenControls.mouseRightClickTapRecognizer = relativeTouchHandler.mouseRightClickTapRecognizer;
    } */
    if([self isOscEnabled]) [onScreenControls setLevel:(OnScreenControlsLevel)settings.onscreenControls.intValue];
}


- (void) clearOnScreenWidgets{
    for (UIView *subview in self->streamFrameTopLayerView.subviews) {
        // 检查子视图是否是特定类型的实例
        if ([subview isKindOfClass:[OnScreenWidgetView class]]) {
            // 如果是，就添加到将要被移除的数组中
            [subview removeFromSuperview];
        }
    }
}

- (CGPoint)denormalizeWidgetPosition:(CGPoint)position {
    if(position.x < 1.0 && position.y < 1.0){
        position.x = position.x * streamFrameTopLayerView.bounds.size.width;
        position.y = position.y * streamFrameTopLayerView.bounds.size.height;
    }
    else{
        NSLog(@"invalid coords");
    }
    return position;
}

- (void) reloadOnScreenWidgetViews{

    // Diagnostic: if this fires repeatedly during play, some loop is thrashing the
    // widget hierarchy (each rebuild tears down widgets and drops in-flight touches).
    NSLog(@"[InputDiag] reloadOnScreenWidgetViews");

    // remove all keyboard widget views first
    [self clearOnScreenWidgets];
    // Reset motion-button gating before re-creating widgets — otherwise a layout
    // edit that removes all GYRO buttons would leave hasMotionControlButton stuck
    // at YES, suppressing all gyro emission with no button left to release it.
    [onScreenControls clearMotionControlButtonRegistration];

    // bool customOscEnabled = [self isOscEnabled] && settings.onscreenControls.intValue == OnScreenControlsLevelCustom;

    if(![self isOnScreenButtonEnabled]) return;
    
    OSCProfilesManager* profilesManager = [OSCProfilesManager sharedManager: self.bounds];
    OSCProfile *oscProfile = [profilesManager getSelectedProfile]; //returns the currently selected OSCProfile

    if(!OnScreenWidgetView.editMode){ // in edit mode, keyboard widget view will be updated within layoutool view controller.
        BOOL fullscreenTriggerInstantiated = NO;

        // Two-pass build so we can enforce a global z-order on the widget layer
        // (fullscreenTrigger < touchPad < button) independent of whatever order
        // widgets happen to live in inside oscProfile.buttonStates. Hit-testing
        // tracks the subviews array (not zPosition), so the same ordering also
        // lets a button overlapping a pad receive the touch.
        //
        // Pass 1: instantiate + configure every widget, wire the onScreenControls
        // back-reference, and bucket by widgetType. Pass 2: add to the view
        // hierarchy + setLocation/resize/adjust in the order fullscreen → pad → button.
        NSMutableArray<OnScreenWidgetView*>* fullscreenWidgets = [NSMutableArray array];
        NSMutableArray<OnScreenWidgetView*>* padWidgets = [NSMutableArray array];
        NSMutableArray<OnScreenWidgetView*>* otherWidgets = [NSMutableArray array];
        // Track each widget's source buttonState so Pass 2 can read position /
        // backgroundAlpha / borderWidth / textAlpha without re-unarchiving.
        NSMutableArray<OnScreenButtonState*>* fullscreenStates = [NSMutableArray array];
        NSMutableArray<OnScreenButtonState*>* padStates = [NSMutableArray array];
        NSMutableArray<OnScreenButtonState*>* otherStates = [NSMutableArray array];

        for (NSData *buttonStateEncoded in oscProfile.buttonStates) {
            OnScreenButtonState* buttonState = [profilesManager unarchiveButtonStateEncoded:buttonStateEncoded];
            if(buttonState.buttonType == CustomOnScreenWidget){
                // Defensive runtime guard: even if a malformed profile somehow persists more
                // than one fullscreen trigger (the editor blocks duplicates, but corrupted /
                // hand-edited NSUserDefaults could still get through), only ever instantiate
                // the first one — otherwise each instance attaches its own double-tap recognizer
                // to the shared superview and a single double-tap would fan out N times.
                BOOL isFullscreen = [buttonState.widgetShape isEqualToString:@"fullscreen"];
                if(isFullscreen && fullscreenTriggerInstantiated) continue;
                OnScreenWidgetView* widgetView = [[OnScreenWidgetView alloc] initWithCmdString:buttonState.name buttonLabel:buttonState.alias shape:buttonState.widgetShape]; //reconstruct widgetView
                if(widgetView.widgetType == WidgetTypeEnumFullscreenTrigger){
                    fullscreenTriggerInstantiated = YES;
                }
                //--------------------------------------------------
                onScreenControls.delegate = widgetView; // connecting onScreenControls to OnScreenWidgetView, sending the active instance for touchPad stick control
                [onScreenControls sendInstance];
                //--------------------------------------------------
                widgetView.translatesAutoresizingMaskIntoConstraints = NO; // weird but this is mandatory, or you will find no key views added to the right place
                widgetView.widthFactor = buttonState.widthFactor;
                widgetView.heightFactor = buttonState.heightFactor;
                widgetView.borderWidth = buttonState.borderWidth;
                widgetView.textAlpha = buttonState.textAlpha;
                [widgetView setVibrationWithStyle:buttonState.vibrationStyle];
                widgetView.mouseButtonAction = buttonState.mouseButtonAction;
                widgetView.sensitivityFactorX = buttonState.sensitivityFactorX;
                widgetView.sensitivityFactorY = buttonState.sensitivityFactorY;
                widgetView.aimSensitivityFactorX = buttonState.aimSensitivityFactorX > 0 ? buttonState.aimSensitivityFactorX : widgetView.sensitivityFactorX;
                widgetView.aimSensitivityFactorY = buttonState.aimSensitivityFactorY > 0 ? buttonState.aimSensitivityFactorY : widgetView.sensitivityFactorY;
                widgetView.trackballDecelerationRate = buttonState.decelerationRate;
                widgetView.stickIndicatorOffset = buttonState.stickIndicatorOffset;
                BOOL migrateLegacyAimDefaults = RSPADALT2ShouldMigrateLegacyAimDefaults(widgetView, buttonState) ||
                    RSPADALT2ShouldMigrateLinearAimDefaults(widgetView, buttonState);
                if (!migrateLegacyAimDefaults) {
                    widgetView.minStickOffset = buttonState.minStickOffset;
                    if (buttonState.stickInputScale > 0) {
                        widgetView.stickInputScale = buttonState.stickInputScale;
                    }
                    if (buttonState.stickResponseExponent >= 1.0) {
                        widgetView.stickResponseExponent = buttonState.stickResponseExponent;
                    }
                    if (buttonState.aimMaxOutputScale > 0) {
                        widgetView.aimMaxOutputScale = buttonState.aimMaxOutputScale;
                    }
                    if (buttonState.aimTuningVersion >= 2 && buttonState.aimTrackpadGain > 0) {
                        widgetView.aimTrackpadGain = buttonState.aimTrackpadGain;
                    }
                    if (buttonState.aimTuningVersion >= 2) {
                        widgetView.aimTrackpadDeadzoneCompensation = buttonState.aimTrackpadDeadzoneCompensation;
                    }
                    if (buttonState.aimTuningVersion >= 2 && buttonState.aimTrackpadResponseDuration > 0) {
                        widgetView.aimTrackpadResponseDuration = buttonState.aimTrackpadResponseDuration;
                    }
                }
                widgetView.aimTrackpadAxisSnapDegrees = buttonState.aimTrackpadAxisSnapDegrees;
                widgetView.aimRelativeModeEnabled = buttonState.aimRelativeModeEnabled;
                widgetView.aimRelativeActivationButton = buttonState.aimRelativeActivationButton;
                widgetView.stickInvertVertical = buttonState.stickInvertVertical;
                widgetView.stickInvertHorizontal = buttonState.stickInvertHorizontal;
                widgetView.doubleTapStickClickEnabled = buttonState.doubleTapStickClickEnabled;
                widgetView.slideMode = buttonState.slideMode;

                if(widgetView.widgetType == WidgetTypeEnumFullscreenTrigger){
                    [fullscreenWidgets addObject:widgetView];
                    [fullscreenStates addObject:buttonState];
                } else if(widgetView.widgetType == WidgetTypeEnumTouchPad){
                    [padWidgets addObject:widgetView];
                    [padStates addObject:buttonState];
                } else {
                    [otherWidgets addObject:widgetView];
                    [otherStates addObject:buttonState];
                }
            }
        }

        // Pass 2 — attach to streamFrameTopLayerView so the final sublayer order
        // (bottom → top) is:
        //   streamView / _scrollView (video, subviews index 0)
        //   fullscreen trigger       (insertSubview:atIndex:1)
        //   touchPad widgets         (insertSubview:aboveSubview:<lower anchor>)
        //   legacy OSC CALayers      (already in sublayers from onScreenControls.setLevel,
        //                             appended before reload runs)
        //   button widgets           (addSubview — appended at the tail of sublayers,
        //                             which lands above the legacy OSC layers and above
        //                             every pad)
        //
        // Pads need to slip *between* the fullscreen trigger and the legacy OSC layers
        // so the OSC layer art renders on top of them and so the touchPad's hitTest
        // passthrough (see OnScreenWidgetView.hitTest for the touchPad branch) routes
        // overlap touches to onScreenControls.handleTouchDownEvent. insertSubview:above
        // places the new layer right after the anchor's layer in the parent's sublayers
        // array, threading past any pure CALayers that were added later — exactly what
        // the fullscreen trigger's atIndex:1 contract already exploits.
        //
        // Each widget still runs the full setLocation → resize → transparency → border
        // sequence right after attach so the existing ordering contract
        // ("resize must be called after relocation") is preserved.

        // Anchor that pad widgets slip "just above" in sublayers. Starts as the stream
        // view container (subviews[0] of streamFrameTopLayerView), gets promoted to the
        // fullscreen trigger after that's inserted, and then walks up through each pad
        // so subsequent pads stack newer-on-top within the pad band.
        UIView* lowerAnchor = self->streamFrameTopLayerView.subviews.firstObject;

        // Fullscreen trigger — same atIndex:1 contract as before. The stream-rendering
        // view (self in non-AbsoluteTouch, or the wrapping _scrollView in AbsoluteTouch)
        // is always at index 0 of streamFrameTopLayerView (see
        // StreamFrameViewController.configZoomGestureAndAddStreamView). Avoid
        // `aboveSubview:self`, which raises in AbsoluteTouch mode because self is nested
        // inside _scrollView and isn't a direct subview of the host.
        for (NSUInteger i = 0; i < fullscreenWidgets.count; i++) {
            OnScreenWidgetView* widgetView = fullscreenWidgets[i];
            OnScreenButtonState* buttonState = fullscreenStates[i];
            [self->streamFrameTopLayerView insertSubview:widgetView atIndex:1];
            lowerAnchor = widgetView; // next pad slips above the fullscreen trigger
            // Runtime sizing comes from edge constraints in changeAndActivateContraints,
            // so storedCenter doesn't drive geometry here — but pin it to the midpoint
            // anyway so anything that later reads storedCenter (e.g., the editor reusing
            // the same OSCProfile) doesn't trip on a stale persisted position.
            [widgetView setLocationWithPosition:CGPointMake(CGRectGetMidX(self->streamFrameTopLayerView.bounds), CGRectGetMidY(self->streamFrameTopLayerView.bounds))];
            [widgetView resizeWidgetView]; // resize must be called after relocation
            [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
            [widgetView adjustBorderWithWidth:buttonState.borderWidth];
            [widgetView adjustTextAlphaWithAlpha:buttonState.textAlpha];
        }

        // touchPad widgets — chained "just above" the running lowerAnchor so each new
        // pad lands right above the previous pad (or above the fullscreen trigger /
        // stream view if it's the first), keeping the whole pad band below the legacy
        // OSC CALayer band that was already appended to the parent's sublayers earlier
        // by onScreenControls.setLevel.
        for (NSUInteger i = 0; i < padWidgets.count; i++) {
            OnScreenWidgetView* widgetView = padWidgets[i];
            OnScreenButtonState* buttonState = padStates[i];
            if (lowerAnchor) {
                [self->streamFrameTopLayerView insertSubview:widgetView aboveSubview:lowerAnchor];
            } else {
                // Defensive: streamFrameTopLayerView with no subviews — should never
                // happen post-setup, but fall back to a safe append so the widget
                // still attaches and the rest of the configure-resize chain runs.
                [self->streamFrameTopLayerView addSubview:widgetView];
            }
            lowerAnchor = widgetView; // newer pads stack above older pads within the band
            buttonState.position = [self denormalizeWidgetPosition:buttonState.position];
            [widgetView setLocationWithPosition:buttonState.position];
            [widgetView resizeWidgetView]; // resize must be called after relocation
            [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
            [widgetView adjustBorderWithWidth:buttonState.borderWidth];
            [widgetView adjustTextAlphaWithAlpha:buttonState.textAlpha];
        }

        // Button (and any future non-pad / non-fullscreen) widgets — appended last
        // so they sit on top of the pad layer.
        for (NSUInteger i = 0; i < otherWidgets.count; i++) {
            OnScreenWidgetView* widgetView = otherWidgets[i];
            OnScreenButtonState* buttonState = otherStates[i];
            [self->streamFrameTopLayerView addSubview:widgetView]; // add keyboard button to the stream frame view. must add it to the target view before setting location.
            buttonState.position = [self denormalizeWidgetPosition:buttonState.position];
            [widgetView setLocationWithPosition:buttonState.position];
            [widgetView resizeWidgetView]; // resize must be called after relocation
            [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
            [widgetView adjustBorderWithWidth:buttonState.borderWidth];
            [widgetView adjustTextAlphaWithAlpha:buttonState.textAlpha];
        }

        // Keep the freshly-rebuilt widgets in lockstep with the legacy OSC layers'
        // obscure-by-alpha state. OnScreenWidgetView.obscuredByAlpha is a STATIC that
        // survives this reload, while new widgets default to full alpha — so a reload
        // that happens while the OSC is hidden (right-edge swipe or the OSC ON/OFF
        // button) leaves the new widgets VISIBLE yet still flagged obscured. The next
        // tap then drops the tapped widget to 0.02 (it "disappears"), and only an
        // OSC ON/OFF toggle resynced it. Re-apply the current obscure state to both the
        // flag and the just-attached widgets so visibility and the flag can't diverge.
        BOOL oscObscured = [self isOscObscuredByAlpha];
        [OnScreenWidgetView setObscuredByAlpha:oscObscured];
        CGFloat widgetViewAlpha = oscObscured ? 0.02f : 1.0f;
        for (UIView *v in self->streamFrameTopLayerView.subviews) {
            if ([v isKindOfClass:[OnScreenWidgetView class]]) {
                v.alpha = widgetViewAlpha;
            }
        }
    }
}

- (OnScreenControlsLevel) getCurrentOscState {
    if (onScreenControls == nil) {
        return OnScreenControlsLevelOff;
    }
    else {
        return [onScreenControls getLevel];
    }
}


- (CGSize) getVideoAreaSize {
    // iPad：按屏宽等比；iPhone：原先的宽/高择优
    // 备注：以下为“始终按宽等比”的历史实现（已停用），用于问题回退或对比：
    // return CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (isPad) {
        return CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    } else {
        if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
            return CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
        } else {
            return CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
        }
    }
}

- (CGPoint) adjustCoordinatesForVideoArea:(CGPoint)point {
    // These are now relative to the StreamView, however we need to scale them
    // further to make them relative to the actual video portion.
    float x = point.x - self.bounds.origin.x;
    float y = point.y - self.bounds.origin.y;
    
    // For some reason, we don't seem to always get to the bounds of the window
    // so we'll subtract 1 pixel if we're to the left/below of the origin and
    // and add 1 pixel if we're to the right/above. It should be imperceptible
    // to the user but it will allow activation of gestures that require contact
    // with the edge of the screen (like Aero Snap).
    if (x < self.bounds.size.width / 2) {
        x--;
    }
    else {
        x++;
    }
    if (y < self.bounds.size.height / 2) {
        y--;
    }
    else {
        y++;
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize = [self getVideoAreaSize];
    // No visual offset is applied at mapping stage when the entire container is shifted
    CGFloat snapOffset = 0.0f;
    CGPoint videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                                      self.bounds.size.height / 2 - videoSize.height / 2 - snapOffset);
    
    // Confine the cursor to the video region. We don't just discard events outside
    // the region because we won't always get one exactly when the mouse leaves the region.
    return CGPointMake(MIN(MAX(x, videoOrigin.x), videoOrigin.x + videoSize.width) - videoOrigin.x,
                       MIN(MAX(y, videoOrigin.y), videoOrigin.y + videoSize.height) - videoOrigin.y);
}

#if !TARGET_OS_TV

- (uint16_t)getRotationFromAzimuthAngle:(float)azimuthAngle {
    // iOS reports azimuth of 0 when the stylus is pointing west, but Moonlight expects
    // rotation of 0 to mean the stylus is pointing north. Rotate the azimuth angle
    // clockwise by 90 degrees to convert from iOS to Moonlight rotation conventions.
    int32_t rotationAngle = (azimuthAngle - M_PI_2) * (180.f / M_PI);
    if (rotationAngle < 0) {
        rotationAngle += 360;
    }
    return (uint16_t)rotationAngle;
}

- (uint8_t)getTiltFromAltitudeAngle:(float)altitudeAngle {
    // iOS reports an altitude of 0 when the stylus is parallel to the touch surface,
    // while Moonlight expects a tilt of 0 when the stylus is perpendicular to the surface.
    // Subtract the tilt angle from 90 to convert from iOS to Moonlight tilt conventions.
    uint8_t altitudeDegs = abs((int16_t)(altitudeAngle * (180.f / M_PI)));
    return 90 - MIN(90, altitudeDegs);
}

- (BOOL)sendStylusEvent:(UITouch*)event {
    uint8_t type;
    
    // Don't touch stylus events if the host doesn't support them. We want to pass
    // them as normal touches for legacy hosts that don't understand pen events.
    if (!(LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS)) {
        return NO;
    }
    
    switch (event.phase) {
        case UITouchPhaseBegan:
            type = LI_TOUCH_EVENT_DOWN;
            break;
        case UITouchPhaseMoved:
            type = LI_TOUCH_EVENT_MOVE;
            break;
        case UITouchPhaseEnded:
            type = LI_TOUCH_EVENT_UP;
            break;
        case UITouchPhaseCancelled:
            type = LI_TOUCH_EVENT_CANCEL;
            break;
        default:
            return YES;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[event locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    return LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                          (event.force / event.maximumPossibleForce) / sin(event.altitudeAngle),
                          0.0f, 0.0f,
                          [self getRotationFromAzimuthAngle:[event azimuthAngleInView:self]],
                          [self getTiltFromAltitudeAngle:event.altitudeAngle]) != LI_ERR_UNSUPPORTED;
}

- (void)sendStylusHoverEvent:(UIHoverGestureRecognizer*)gesture API_AVAILABLE(ios(13.0)) {
    uint8_t type;
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            type = LI_TOUCH_EVENT_HOVER;
            break;

        case UIGestureRecognizerStateEnded:
            type = LI_TOUCH_EVENT_HOVER_LEAVE;
            break;

        default:
            return;
    }

    CGPoint location = [self adjustCoordinatesForVideoArea:[gesture locationInView:self]];
    CGSize videoSize = [self getVideoAreaSize];
    
    float distance = 0.0f;
#if defined(__IPHONE_16_1) || defined(__TVOS_16_1)
    if (@available(iOS 16.1, *)) {
        distance = gesture.zOffset;
    }
#endif
    
    uint16_t rotationAngle = LI_ROT_UNKNOWN;
    uint8_t tiltAngle = LI_TILT_UNKNOWN;
#if defined(__IPHONE_16_4) || defined(__TVOS_16_4)
    if (@available(iOS 16.4, *)) {
        rotationAngle = [self getRotationFromAzimuthAngle:[gesture azimuthAngleInView:self]];
        tiltAngle = [self getTiltFromAltitudeAngle:gesture.altitudeAngle];
    }
#endif
    
    LiSendPenEvent(type, LI_TOOL_TYPE_PEN, 0, location.x / videoSize.width, location.y / videoSize.height,
                   distance, 0.0f, 0.0f, rotationAngle, tiltAngle);
}

#endif

- (BOOL)shouldIgnoreTouchesForGestureSuppression:(NSSet *)touches consume:(BOOL)consume {
    BOOL matched = NO;
    for (UITouch *touch in touches) {
        NSNumber *addr = @((uintptr_t)touch);
        if ([suppressedGestureTouchAddrs containsObject:addr]) {
            matched = YES;
            if (consume) {
                [suppressedGestureTouchAddrs removeObject:addr];
            }
        }
    }

    if (oscGestureSuppressed) {
        return YES;
    }

    return matched;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    // if (@available(iOS 13.4, *)) {
    // cancel restriction of native touch for iOS13.3 & lower
    if (settings.touchMode.intValue == NativeTouchOnly) {
        [touchHandler touchesBegan:touches withEvent:event];
        return; //This is a native touch oriented fork, in pure native touch mode, this call back method deals with native touch only.
    }
    if (@available(iOS 13.4, *)) { // now only pencil events are restricted
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) return;
            }
        }
    }
    
#endif
    if ([self handleMouseButtonEvent:BUTTON_ACTION_PRESS
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch down");
    
    // Notify of user interaction and start expiration timer
    [self startInteractionTimer];

    if ([self shouldIgnoreTouchesForGestureSuppression:touches consume:NO]) {
        return;
    }

    if(settings.touchMode.intValue == NativeTouch || settings.touchMode.intValue == RelativeTouch){
        [self->onScreenControls handleTouchDownEvent:touches];
        [self->touchHandler touchesBegan:touches withEvent:event];
    }
    else if(![onScreenControls handleTouchDownEvent:touches]) [touchHandler touchesBegan:touches withEvent:event];
}

- (UIBarButtonItem *)createButtonWithImageNamed:(NSString *)imageName backgroundColor:(UIColor *)backgroundColor target:(id)target action:(SEL)action keyCode:(NSInteger)keyCode isToggleable:(BOOL)isToggleable {
    UIImage *image = [UIImage imageNamed:imageName];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setImage:image forState:UIControlStateNormal];
    button.frame = CGRectMake(0, 0, 30, 30);
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.imageView.backgroundColor = backgroundColor;
    button.imageView.layer.cornerRadius = 10.0;
    button.imageEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, "keyCode", @(keyCode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, "isToggleable", @(isToggleable), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, "isOn", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *barButton = [[UIBarButtonItem alloc] initWithCustomView:button];
    return barButton;
}

- (void)toolbarButtonClicked:(UIButton *)sender {
    BOOL isToggleable = [objc_getAssociatedObject(sender, "isToggleable") boolValue];
    BOOL isOn = [objc_getAssociatedObject(sender, "isOn") boolValue];
    if (isToggleable){
        isOn = !isOn;
        // Update the button's appearance based on its new state
        if (isOn) {
            sender.imageView.backgroundColor = [UIColor lightGrayColor];
        } else {
            sender.imageView.backgroundColor = [UIColor blackColor];
        }
    }
    // Update the new on/off state of the button
    objc_setAssociatedObject(sender, "isOn", @(isOn), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Get the keyCode parameter and convert to short for key press event
    short keyCode = [objc_getAssociatedObject(sender, "keyCode") shortValue];
    // Close keyboard if done button clicked
    if (!keyCode) {
        [keyInputField resignFirstResponder];
        isInputingText = false;
    }
    else {
        // Send key press event using keyCode parameter, toggle if necessary
        if (isToggleable){
            //	(@"keycode %x", keyCode);
            if (isOn){
                LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, 0);
                [keysDown addObject:@(keyCode)];
            } else {
                LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, 0);
                [keysDown removeObject:@(keyCode)];
            }
        }
        else {
            LiSendKeyboardEvent(keyCode, KEY_ACTION_DOWN, 0);
            usleep(50 * 1000);
            LiSendKeyboardEvent(keyCode, KEY_ACTION_UP, 0);
        }
    }
}

- (BOOL)handleMouseButtonEvent:(int)buttonAction forTouches:(NSSet *)touches withEvent:(UIEvent *)event {
    
    
    // NSLog(@"mouse click time: %f", CACurrentMediaTime()*1000);
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        UITouch* touch = [touches anyObject];
        if (touch.type == UITouchTypeIndirectPointer) {
            if (@available(iOS 14.0, *)) {
                if ([GCMouse current] != nil) {
                    // We'll handle this with GCMouse. Do nothing here.
                    return YES;
                }
            }
            
            UIEventButtonMask normalizedButtonMask;
            
            // iOS 14 includes the released button in the buttonMask for the release
            // event, while iOS 13 does not. Normalize that behavior here.
            if (@available(iOS 14.0, *)) {
                if (buttonAction == BUTTON_ACTION_RELEASE) {
                    normalizedButtonMask = lastMouseButtonMask & ~event.buttonMask;
                }
                else {
                    normalizedButtonMask = event.buttonMask;
                }
            }
            else {
                normalizedButtonMask = event.buttonMask;
            }
            
            UIEventButtonMask changedButtons = lastMouseButtonMask ^ normalizedButtonMask;
                        
            for (int i = BUTTON_LEFT; i <= BUTTON_X2; i++) {
                UIEventButtonMask buttonFlag;
                
                switch (i) {
                    // Right and Middle are reversed from what iOS uses
                    case BUTTON_RIGHT:
                        buttonFlag = UIEventButtonMaskForButtonNumber(2);
                        break;
                    case BUTTON_MIDDLE:
                        buttonFlag = UIEventButtonMaskForButtonNumber(3);
                        break;
                        
                    default:
                        buttonFlag = UIEventButtonMaskForButtonNumber(i);
                        break;
                }
                
                if (changedButtons & buttonFlag) {
                    LiSendMouseButtonEvent(buttonAction, i);
                }
            }
            
            lastMouseButtonMask = normalizedButtonMask;
            return YES;
        }
    }
#endif
    
    return NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    
    if (settings.touchMode.intValue == NativeTouchOnly) {
        [touchHandler touchesMoved:touches withEvent:event];
        return; //This is a native touch oriented fork, in pure native touch mode, this call back method deals with native touch only.
    }
    
    for (UITouch* touch in touches) {
        if (touch.type == UITouchTypePencil) {
            if ([self sendStylusEvent:touch]) return;
        }
        if (@available(iOS 13.4, *)) {
            UITouch *touch = [touches anyObject];
            if (touch.type == UITouchTypeIndirectPointer) {
                if (@available(iOS 14.0, *)) {
                    if ([GCMouse current] != nil) {
                        // We'll handle this with GCMouse. Do nothing here.
                        return;
                    }
                }
                // We must handle this event to properly support
                // drags while the middle, X1, or X2 mouse buttons are
                // held down. For some reason, left and right buttons
                // don't require this, but we do it anyway for them too.
                // Cursor movement without a button held down is handled
                // in pointerInteraction:regionForRequest:defaultRegion.
                [self updateCursorLocation:[touch locationInView:self] isMouse:YES];
                return;
            }
        }
#endif
    }
    
    hasUserInteracted = YES;

    if ([self shouldIgnoreTouchesForGestureSuppression:touches consume:NO]) {
        return;
    }

    if(self->settings.touchMode.intValue == NativeTouch || self->settings.touchMode.intValue == RelativeTouch){
        [self->touchHandler touchesMoved:touches withEvent:event];
        [self->onScreenControls handleTouchMovedEvent:touches];
    }
    else if(![self->onScreenControls handleTouchMovedEvent:touches]) [self->touchHandler touchesMoved:touches withEvent:event];
}

- (void) handleKeyCombos:(UIPress*) press{
    if(press.key.modifierFlags != comboKeyModifierFlags){
        return;
    }
    switch (press.key.keyCode) {
        case UIKeyboardHIDUsageKeyboardQ:
            [interactionDelegate streamExitRequested];
            break;
        case UIKeyboardHIDUsageKeyboardS:
            [interactionDelegate toggleStatsOverlay];
            break;
        case UIKeyboardHIDUsageKeyboardM:
            [interactionDelegate toggleMouseCapture];
            break;
        case UIKeyboardHIDUsageKeyboardC:
            [interactionDelegate toggleMouseVisible];
            break;
        default:
            break;
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            [self handleKeyCombos:press];
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:YES]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    if (@available(iOS 13.4, tvOS 13.4, *)) {
        for (UIPress* press in presses) {
            // For now, we'll treated it as handled if we handle at least one of the
            // UIPress events inside the set.
            if ([KeyboardSupport sendKeyEventForPress:press down:NO]) {
                // This will prevent the legacy UITextField from receiving the event
                handled = YES;
            }
        }
    }
    
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV

    if (settings.touchMode.intValue == NativeTouchOnly) {
        [touchHandler touchesEnded:touches withEvent:event];
        return; //This is a native touch oriented fork, in pure native touch mode, this call back method deals with native touch only.
    }
    
    if (@available(iOS 13.4, *)){ //now only pencil events are restricted
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) return;
            }
        }
    }

#endif
    if ([self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                          forTouches:touches
                           withEvent:event]) {
        // If it's a mouse event, we're done
        return;
    }
    
    Log(LOG_D, @"Touch up");
    
    hasUserInteracted = YES;

    if ([self shouldIgnoreTouchesForGestureSuppression:touches consume:YES]) {
        return;
    }

    if(settings.touchMode.intValue == NativeTouch || settings.touchMode.intValue == RelativeTouch){
        [self->touchHandler touchesEnded:touches withEvent:event]; // when touches ended, must call the native touchhandler before onScreenControls, since the NSSet of touches captured by on screen button shall be updated later
        [self->onScreenControls handleTouchUpEvent:touches];
    }
    else if(![onScreenControls handleTouchUpEvent:touches]) [touchHandler touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [touchHandler touchesCancelled:touches withEvent:event];
#if !TARGET_OS_TV
    if (settings.touchMode.intValue == NativeTouchOnly) return; //This is a native touch oriented fork, in pure native touch mode, this call back method deals with native touch only.
    if (@available(iOS 13.4, *)){ //now only pencil events are restricted
        for (UITouch* touch in touches) {
            if (touch.type == UITouchTypePencil) {
                if ([self sendStylusEvent:touch]) return;
            }
        }
    }
#endif
    if ([self shouldIgnoreTouchesForGestureSuppression:touches consume:YES]) {
        return;
    }
    [self handleMouseButtonEvent:BUTTON_ACTION_RELEASE
                      forTouches:touches
                       withEvent:event];
}

- (void)beginRightEdgeGestureSuppressionForTouch:(UITouch *)touch {
    if (!oscGestureSuppressed) {
        oscGestureSuppressed = YES;
        rightEdgeGestureSuppressionDepth = 1;
#if !TARGET_OS_TV
        if (onScreenControls != nil) {
            [onScreenControls cancelAllActiveTouches];
        }
#endif
        [OnScreenWidgetView beginGestureSuppression];
    } else {
        rightEdgeGestureSuppressionDepth = MAX(rightEdgeGestureSuppressionDepth, 1);
    }

    if (touch != nil) {
        [suppressedGestureTouchAddrs addObject:@((uintptr_t)touch)];
    }
}

- (void)endRightEdgeGestureSuppression {
    if (!oscGestureSuppressed) {
        if (suppressedGestureTouchAddrs.count > 0) {
            [suppressedGestureTouchAddrs removeAllObjects];
        }
        // Even when our per-instance flag is already clear, make sure the
        // process-wide static can't stay stuck true (it gates ALL OSC input).
        // The instance flag and the static could desync — e.g. a new StreamView
        // setup reset the instance flag while a prior begin left the static set —
        // and a stuck static suppressed every widget until force-quit.
        [OnScreenWidgetView endGestureSuppression];
        return;
    }

    if (rightEdgeGestureSuppressionDepth > 1) {
        rightEdgeGestureSuppressionDepth -= 1;
        return;
    }

    rightEdgeGestureSuppressionDepth = 0;
    oscGestureSuppressed = NO;
    [suppressedGestureTouchAddrs removeAllObjects];
    [OnScreenWidgetView endGestureSuppression];
}

// Unconditionally clear any right-edge gesture suppression, both the per-instance
// state and the process-wide OnScreenWidgetView static. Called on every stream-view
// (re)configuration so a suppression that never got a matching "end" self-heals
// instead of killing OSC input for the rest of the process lifetime.
- (void)resetRightEdgeGestureSuppression {
    rightEdgeGestureSuppressionDepth = 0;
    oscGestureSuppressed = NO;
    [suppressedGestureTouchAddrs removeAllObjects];
    [OnScreenWidgetView forceResetGestureSuppression];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil) {
        [self endRightEdgeGestureSuppression];
    }
}

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse {
    CGPoint normalizedLocation = [self adjustCoordinatesForVideoArea:location];
    CGSize videoSize = [self getVideoAreaSize];
    
    // Send the mouse position relative to the video region if it has changed
    // if we're receiving coordinates from a real mouse.
    //
    // NB: It is important for functionality (not just optimization) to only
    // send it if the value has changed. We will receive one of these events
    // any time the user presses a modifier key, which can result in errant
    // mouse motion when using a Citrix X1 mouse.
    if (normalizedLocation.x != lastMouseX || normalizedLocation.y != lastMouseY || !isMouse) {
        if (lastMouseX != 0 || lastMouseY != 0 || !isMouse) {
            LiSendMousePositionEvent(normalizedLocation.x, normalizedLocation.y, videoSize.width, videoSize.height);
        }
        
        if (isMouse) {
            lastMouseX = normalizedLocation.x;
            lastMouseY = normalizedLocation.y;
        }
    }
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion API_AVAILABLE(ios(13.4)) {
    if (@available(iOS 14.0, *)) {
        if ([GCMouse current] != nil && localMousePointerMode == 0) {
            // We'll handle this with GCMouse. Do nothing here.
            return nil;
        }
    }
    
    // This logic mimics what iOS does with AVLayerVideoGravityResizeAspect
    CGSize videoSize;
    CGPoint videoOrigin;
    // 与 getVideoAreaSize 保持一致
    // 备注：以下为“始终按宽等比”的历史实现（已停用），用于问题回退或对比：
    // videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    BOOL isPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (isPad) {
        videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
    } else {
        if (self.bounds.size.width > self.bounds.size.height * streamAspectRatio) {
            videoSize = CGSizeMake(self.bounds.size.height * streamAspectRatio, self.bounds.size.height);
        } else {
            videoSize = CGSizeMake(self.bounds.size.width, self.bounds.size.width / streamAspectRatio);
        }
    }
    // Remove unused variable from previous approach; not used in mapping now
    // No extra offset here; container shift handles visuals
    CGFloat snapOffset2 = 0.0f;
    videoOrigin = CGPointMake(self.bounds.size.width / 2 - videoSize.width / 2,
                              self.bounds.size.height / 2 - videoSize.height / 2 - snapOffset2);
    
    // Move the cursor on the host if no buttons are pressed.
    // Motion with buttons pressed in handled in touchesMoved:
    if (lastMouseButtonMask == 0) {
        [self updateCursorLocation:request.location isMouse:YES];
    }
    
    // The pointer interaction should cover the video region only
    return [UIPointerRegion regionWithRect:CGRectMake(videoOrigin.x, videoOrigin.y, videoSize.width, videoSize.height) identifier:nil];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region  API_AVAILABLE(ios(13.4)) {
    if(localMousePointerMode != 2){
        return [UIPointerStyle hiddenPointerStyle];
    }else{
        return nil;
    }
}

- (void)mouseWheelMovedContinuous:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    const short translationMultiplier = 120 * 20; // WHEEL_DELTA * 20
    
    {
        short translationDeltaY = ((currentScrollTranslation.y - lastScrollTranslation.y) / self.bounds.size.height) * translationMultiplier;
        if(settings.reverseMouseWheelDirection) translationDeltaY = - translationDeltaY;
        if (translationDeltaY != 0) {
            LiSendHighResScrollEvent(translationDeltaY);
            lastScrollTranslation = currentScrollTranslation;
        }
    }

    {
        short translationDeltaX = ((currentScrollTranslation.x - lastScrollTranslation.x) / self.bounds.size.width) * translationMultiplier;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-translationDeltaX);
            lastScrollTranslation = currentScrollTranslation;
        }
    }
}

- (void)mouseWheelMovedDiscrete:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            break;
        
        case UIGestureRecognizerStateEnded:
        default:
            // Ignore recognition failure and other states
            lastScrollTranslation = CGPointMake(0, 0);
            return;
    }
    
    // Using velocityInView is 0 for discrete scroll events
    // when scrolling very slowly, but translationInView does work.
    CGPoint currentScrollTranslation = [gesture translationInView:self];
    
    {
        short translationDeltaY = currentScrollTranslation.y - lastScrollTranslation.y;
        if(settings.reverseMouseWheelDirection) translationDeltaY = - translationDeltaY;
        if (translationDeltaY != 0) {
            LiSendScrollEvent(translationDeltaY > 0 ? 1 : -1);
        }
    }

    {
        short translationDeltaX = currentScrollTranslation.x - lastScrollTranslation.x;
        if (translationDeltaX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHScrollEvent(translationDeltaX < 0 ? 1 : -1);
        }
    }
    
    lastScrollTranslation = currentScrollTranslation;
}

#endif

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (@available(iOS 13.0, *)) {
        // Disable the 3 finger tap gestures that trigger the copy/paste/undo toolbar on iOS 13+
        return gestureRecognizer.name == nil || ![gestureRecognizer.name hasPrefix:@"kbProductivity."];
    }
    else {
        return YES;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // This method is called when the "Return" key is pressed.
    LiSendKeyboardEvent(0x0d, KEY_ACTION_DOWN, 0);
    usleep(50 * 1000);
    LiSendKeyboardEvent(0x0d, KEY_ACTION_UP, 0);
    return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    for (NSNumber* keyCode in keysDown) {
        LiSendKeyboardEvent([keyCode shortValue], KEY_ACTION_UP, 0);
    }
    [keysDown removeAllObjects];
}

- (void)onKeyboardPressed:(UITextField *)textField {
    NSString* inputText = textField.text;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // If the text became empty, we know the user pressed the backspace key.
        if ([inputText isEqual:@""]) {
            LiSendKeyboardEvent(0x08, KEY_ACTION_DOWN, 0);
            usleep(50 * 1000);
            LiSendKeyboardEvent(0x08, KEY_ACTION_UP, 0);
        } else {
            // Character 0 will be our known sentinel value
            
            // Check if any characters exist which can't be represented in a basic key event
            for (int i = 1; i < [inputText length]; i++) {
                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];
                if (event.keycode == 0) {
                    // We found an unknown key, so send the entire string as UTF-8
                    const char* utf8String = [inputText UTF8String];
                    
                    // Skip the first character which is our sentinel
                    LiSendUtf8TextEvent(utf8String + 1, (int)strlen(utf8String) - 1);
                    return;
                }
            }
            
            // We didn't find any unknown characters, so send them all as basic key events
            for (int i = 1; i < [inputText length]; i++) {
                struct KeyEvent event = [KeyboardSupport translateKeyEvent:[inputText characterAtIndex:i] withModifierFlags:0];
                assert(event.keycode != 0);
                [self sendLowLevelEvent:event];
            }
        }
    });
    
    // Reset text field back to known state
    textField.text = @"0";
    
    // Move the insertion point back to the end of the text box
    UITextRange *textRange = [textField textRangeFromPosition:textField.endOfDocument toPosition:textField.endOfDocument];
    [textField setSelectedTextRange:textRange];
}

- (void)specialCharPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:0x20 withModifierFlags:[cmd modifierFlags]];
    event.keycode = [[dictCodes valueForKey:[cmd input]] intValue];
    [self sendLowLevelEvent:event];
}

- (void)keyPressed:(UIKeyCommand *)cmd {
    struct KeyEvent event = [KeyboardSupport translateKeyEvent:[[cmd input] characterAtIndex:0] withModifierFlags:[cmd modifierFlags]];
    [self sendLowLevelEvent:event];
}

- (void)sendLowLevelEvent:(struct KeyEvent)event {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // When we want to send a modified key (like uppercase letters) we need to send the
        // modifier ("shift") seperately from the key itself.
        if (event.modifier != 0) {
            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_DOWN, event.modifier);
        }
        // Let the host know these are not (necessarily) normalized to US English scancodes
        LiSendKeyboardEvent2(event.keycode, KEY_ACTION_DOWN, event.modifier, SS_KBE_FLAG_NON_NORMALIZED);
        usleep(50 * 1000);
        LiSendKeyboardEvent2(event.keycode, KEY_ACTION_UP, event.modifier, SS_KBE_FLAG_NON_NORMALIZED);
        if (event.modifier != 0) {
            LiSendKeyboardEvent(event.modifierKeycode, KEY_ACTION_UP, event.modifier);
        }
    });
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    NSString *charset = @"qwertyuiopasdfghjklzxcvbnm1234567890\t§[]\\'\"/.,`<>-´ç+`¡'º;ñ= ";
    
    NSMutableArray<UIKeyCommand *> * commands = [NSMutableArray<UIKeyCommand *> array];
    dictCodes = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt: 0x0d], @"\r", [NSNumber numberWithInt: 0x08], @"\b", [NSNumber numberWithInt: 0x1b], UIKeyInputEscape, [NSNumber numberWithInt: 0x28], UIKeyInputDownArrow, [NSNumber numberWithInt: 0x26], UIKeyInputUpArrow, [NSNumber numberWithInt: 0x25], UIKeyInputLeftArrow, [NSNumber numberWithInt: 0x27], UIKeyInputRightArrow, nil];
    
    [charset enumerateSubstringsInRange:NSMakeRange(0, charset.length)
                                options:NSStringEnumerationByComposedCharacterSequences
                             usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:0 action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierShift action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierControl action:@selector(keyPressed:)]];
                                 [commands addObject:[UIKeyCommand keyCommandWithInput:substring modifierFlags:UIKeyModifierAlternate action:@selector(keyPressed:)]];
                             }];
    
    for (NSString *c in [dictCodes keyEnumerator]) {
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:0
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierShift | UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierControl | UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
        [commands addObject:[UIKeyCommand keyCommandWithInput:c
                                                modifierFlags:UIKeyModifierAlternate
                                                       action:@selector(specialCharPressed:)]];
    }
    
    return commands;
}

- (void)connectedStateDidChangeWithIdentifier:(NSUUID * _Nonnull)identifier isConnected:(BOOL)isConnected {
    NSLog(@"Citrix X1 mouse state change: %@ -> %s",
          identifier, isConnected ? "connected" : "disconnected");
}

- (void)mouseDidMoveWithIdentifier:(NSUUID * _Nonnull)identifier deltaX:(int16_t)deltaX deltaY:(int16_t)deltaY {
    accumulatedMouseDeltaX += deltaX / X1_MOUSE_SPEED_DIVISOR;
    accumulatedMouseDeltaY += deltaY / X1_MOUSE_SPEED_DIVISOR;
    
    short shortX = (short)accumulatedMouseDeltaX;
    short shortY = (short)accumulatedMouseDeltaY;
    
    if (shortX == 0 && shortY == 0) {
        return;
    }
    
    LiSendMouseMoveEvent(shortX, shortY);
    
    accumulatedMouseDeltaX -= shortX;
    accumulatedMouseDeltaY -= shortY;
}

- (int) buttonFromX1ButtonCode:(enum X1MouseButton)button {
    switch (button) {
        case X1MouseButtonLeft:
            return BUTTON_LEFT;
        case X1MouseButtonRight:
            return BUTTON_RIGHT;
        case X1MouseButtonMiddle:
            return BUTTON_MIDDLE;
        default:
            return -1;
    }
}

- (void)mouseDownWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, [self buttonFromX1ButtonCode:button]);
}

- (void)mouseUpWithIdentifier:(NSUUID * _Nonnull)identifier button:(enum X1MouseButton)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, [self buttonFromX1ButtonCode:button]);
}

- (void)wheelDidScrollWithIdentifier:(NSUUID * _Nonnull)identifier deltaZ:(int8_t)deltaZ {
    LiSendScrollEvent(deltaZ);
}


#if !TARGET_OS_TV
- (BOOL)isMultipleTouchEnabled {
    return YES;
}
#endif

@end
