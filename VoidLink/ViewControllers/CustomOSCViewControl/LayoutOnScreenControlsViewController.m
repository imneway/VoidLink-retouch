//
//  LayoutOnScreenControlsViewController.m
//  Moonlight
//
//  Created by Long Le on 9/27/22.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//
//  Modified by True砖家 since 2024.6.24
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "LayoutOnScreenControlsViewController.h"
#import "OSCProfilesTableViewController.h"
#import "OnScreenButtonState.h"
//#import "OnScreenControls.h"
#import "OSCProfilesManager.h"
#import "LocalizationHelper.h"
#import "VoidLink-Swift.h"
#import "ThemeManager.h"

@interface LayoutOnScreenControlsViewController ()

@end


@implementation LayoutOnScreenControlsViewController {
    BOOL isToolbarHidden;
    OSCProfilesManager* profilesManager;
    OnScreenWidgetView* selectedWidgetView;
    CALayer* selectedControllerLayer;
    CGRect controllerLoadedBounds;
    bool widgetViewSelected;
    bool controllerLayerSelected;
    bool viewWillBeResized;
    __weak IBOutlet NSLayoutConstraint *toolbarTopConstraintiPhone;
    __weak IBOutlet NSLayoutConstraint *toolbarTopConstraintiPad;
    UIColor* trashCanStoryBoardColor;
    BOOL widgetPanelMovedByTouch;
    CGPoint widgetPanelStoredCenter;
    CGPoint latestTouchLocation;
    UIImpactFeedbackGenerator *vibrationGenerator;
    BOOL rotationUnlocked;          // NO (default) = screen rotation locked while editing
    UIButton *rotationLockButton;   // top toolbar lock toggle
}

// MARK: - 方向锁定 持久化Key（与列表页一致）
static NSString * const kOSCLockedPortraitProfileName = @"OSCLockedPortraitProfileName";
static NSString * const kOSCLockedLandscapeProfileName = @"OSCLockedLandscapeProfileName";

// 根据当前视图 bounds 判断是否横屏
- (BOOL)osc_isCurrentLandscapeInViewBounds {
    return self.view.bounds.size.width > self.view.bounds.size.height;
}

// 获取锁定名
- (NSString *)osc_lockedProfileNameForLandscape:(BOOL)isLandscape {
    NSString *key = isLandscape ? kOSCLockedLandscapeProfileName : kOSCLockedPortraitProfileName;
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

// 应用锁定并在需要时重载 UI
- (void)osc_applyLockForCurrentOrientationAndReloadIfNeeded {
    BOOL isLandscape = [self osc_isCurrentLandscapeInViewBounds];
    NSString *lockedName = [self osc_lockedProfileNameForLandscape:isLandscape];
    if (lockedName.length == 0) {
        return;
    }
    NSMutableArray *all = [profilesManager getAllProfiles];
    OSCProfile *found = nil;
    for (OSCProfile *p in all) {
        if ([p.name isEqualToString:lockedName]) { found = p; break; }
    }
    if (!found) {
        return;
    }
    if ([profilesManager isTemplateProfile:found.name]) {
        return;
    }
    if (![[[profilesManager getSelectedProfile] name] isEqualToString:found.name]) {
        [profilesManager setProfileToSelected:found.name];
        // 在编辑界面需要重载两套控件
        [self reloadLegacyOnScreenControls];
        [self reloadOnScreenWidgetViews];
    }
}

@synthesize trashCanButton;
@synthesize undoButton;
@synthesize OSCSegmentSelected;
@synthesize toolbarRootView;
@synthesize chevronView;
@synthesize chevronImageView;

- (UIInterfaceOrientationMask)getCurrentOrientation{
    CGFloat screenHeightInPoints = CGRectGetHeight([[UIScreen mainScreen] bounds]);
    CGFloat screenWidthInPoints = CGRectGetWidth([[UIScreen mainScreen] bounds]);
    //lock the orientation accordingly after streaming is started
    if(screenWidthInPoints > screenHeightInPoints) return UIInterfaceOrientationMaskLandscape;
    else return UIInterfaceOrientationMaskPortrait|UIInterfaceOrientationMaskPortraitUpsideDown;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // Default while editing: rotation is LOCKED, so a rotation can't reload the
    // editor and disturb in-progress edits. Freeze to the orientation we're in
    // until the user taps the lock button to unlock.
    if (!rotationUnlocked) {
        return [self osc_currentInterfaceOrientationMask];
    }
    return [self getCurrentOrientation]; // 90 Degree rotation not allowed in streaming or app view
}

- (BOOL)shouldAutorotate {
    // Honored on iOS < 16; iOS 16+ relies on supportedInterfaceOrientations above.
    return rotationUnlocked;
}

// Mask for the single orientation we are currently displayed in, so a locked
// editor refuses to rotate to any other orientation.
- (UIInterfaceOrientationMask)osc_currentInterfaceOrientationMask {
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
    // Fallback before the scene orientation is known: derive from the view bounds.
    return (self.view.bounds.size.width > self.view.bounds.size.height)
        ? UIInterfaceOrientationMaskLandscape
        : UIInterfaceOrientationMaskPortrait;
}

// Floating lock toggle (top-trailing). Locked by default; tapping unlocks so the
// user can deliberately rotate, then re-locks. Keeping rotation locked while
// editing avoids the whole class of "rotation reloads the editor and disturbs /
// drops in-progress edits" problems.
- (void)osc_setupRotationLockButton {
    if (rotationLockButton) { return; }
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    btn.layer.cornerRadius = 18.0;
    btn.clipsToBounds = YES;
    [btn addTarget:self action:@selector(osc_toggleRotationLock:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    [NSLayoutConstraint activateConstraints:@[
        [btn.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
        [btn.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
        [btn.widthAnchor constraintEqualToConstant:36.0],
        [btn.heightAnchor constraintEqualToConstant:36.0],
    ]];
    rotationLockButton = btn;
    [self osc_updateRotationLockButton];
}

- (void)osc_updateRotationLockButton {
    if (@available(iOS 13.0, *)) {
        NSString *symbol = rotationUnlocked ? @"lock.rotation.open" : @"lock.rotation";
        [rotationLockButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    }
    rotationLockButton.accessibilityLabel = rotationUnlocked ? @"屏幕方向已解锁" : @"屏幕方向已锁定";
    [self.view bringSubviewToFront:rotationLockButton];
}

- (void)osc_toggleRotationLock:(id)sender {
    rotationUnlocked = !rotationUnlocked;
    [self osc_updateRotationLockButton];
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

- (void) viewWillDisappear:(BOOL)animated{
    OnScreenWidgetView.editMode = false;
    for (OnScreenWidgetView* widgetView in self.onScreenWidgetViews){
        [widgetView.stickBallLayer removeFromSuperlayer];
        [widgetView.crossMarkLayer removeFromSuperlayer];
    }
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"OscLayoutCloseNotification" object:self];
}

- (CGPoint)denormalizeWidgetPosition:(CGPoint)position {
    // NSLog(@"position: %f, %f", position.x, position.y);
    CGPoint newPosition = position;
    if(position.x < 1.0 && position.y < 1.0){
        newPosition.x = position.x * self.view.bounds.size.width;
        newPosition.y = position.y * self.view.bounds.size.height;
    }
    return newPosition;
}

- (void)reloadLegacyOnScreenControls{
    [self.layoutOSC updateControls];  // creates and saves a 'Default' OSC profile or loads the o//ne the user selected on the previous screen
    [self addInnerAnalogSticksToOuterAnalogLayers];
    [self.layoutOSC.layoutChanges removeAllObjects];  // since a new OSC profile is being loaded, this will remove all previous layout changes made from the array
    [self OSCLayoutChanged];    // fades the 'Undo Button' out
}

// Place / re-place a single widget in the editor's view hierarchy so the global
// z-order contract holds across reload, create, modify, and post-drag re-anchor:
//     streamOverlay < fullscreenTrigger < touchPad widgets < legacy OSC CALayers
//       < button widgets < widgetPanelStack < toolbar
// Runtime mirrors this contract in StreamView.reloadOnScreenWidgetViews. The
// legacy OSC band lives in self.view.layer.sublayers as pure CALayers added by
// layoutOSC.show — it has no UIView anchor, so we sandwich the pad band against
// the highest subview *below* it (the fullscreen trigger if present, otherwise
// the stream overlay), letting insertSubview:above slip the new pad into the
// sublayers slot right before the legacy CALayers were appended.
//
// Editor-only note: pads receive touches normally in edit mode (no hitTest
// passthrough), so the user can still tap-select and drag them. The visual
// stacking still matches runtime so the WYSIWYG is honest.
//
// Idempotent w.r.t. widgetView already being a subview — insertSubview:above/below
// just moves it. Caller is responsible for adding widgetView to self.onScreenWidgetViews.
- (void)insertWidgetInEditorZOrder:(OnScreenWidgetView*)widgetView {
    if (widgetView.widgetType == WidgetTypeEnumFullscreenTrigger) {
        if (self.streamOverlay) {
            // Fullscreen trigger sits just above the stream preview, below every
            // other widget and the panel — same contract as before this refactor.
            [self.view insertSubview:widgetView aboveSubview:self.streamOverlay];
        } else {
            // No stream overlay yet (shouldn't happen post-viewDidLoad, but stay
            // defensive) — fall back to the legacy "just below the panel" slot.
            [self.view insertSubview:widgetView belowSubview:self.widgetPanelStack];
        }
        return;
    }
    if (widgetView.widgetType == WidgetTypeEnumTouchPad) {
        // Find the highest "lower anchor" already in view: the topmost fullscreen
        // trigger if present, else the stream overlay. self.view.subviews iterates
        // bottom→top, so we keep updating `anchor` as we encounter qualifying
        // anchors and let the loop end naturally — that picks the highest one.
        // Inserting aboveSubview:anchor drops the pad's layer into the sublayers
        // slot right after the anchor's layer, landing above the fullscreen trigger
        // but below the legacy OSC CALayers that layoutOSC.show appended later.
        // Subsequent pads use the previous pad as their anchor so newer-on-top
        // stacking holds within the pad band.
        UIView* anchor = self.streamOverlay;
        for (UIView* sv in self.view.subviews) {
            if (sv == widgetView) continue;
            if (![sv isKindOfClass:[OnScreenWidgetView class]]) continue;
            OnScreenWidgetView* w = (OnScreenWidgetView*)sv;
            if (w.widgetType == WidgetTypeEnumFullscreenTrigger ||
                w.widgetType == WidgetTypeEnumTouchPad) {
                anchor = sv;
            }
        }
        if (anchor) {
            [self.view insertSubview:widgetView aboveSubview:anchor];
        } else {
            // Defensive (no overlay, no trigger, no other pad yet) — drop just
            // below the widget panel; any button added later still ends up on top.
            [self.view insertSubview:widgetView belowSubview:self.widgetPanelStack];
        }
        return;
    }
    // Default (button / uninitialized) — just below the widget panel as before.
    // This appends after every pad and after the legacy OSC CALayers in sublayers,
    // putting buttons at the top of the widget zone.
    [self.view insertSubview:widgetView belowSubview:self.widgetPanelStack];
}

- (void)reloadOnScreenWidgetViews{
    NSLog(@"reloadOnScreenWidgets %f", CACurrentMediaTime());
    OnScreenWidgetView.editMode = true;
    [self hideStickIndicators];

    // Drop selection state before tearing down the views, otherwise selectedWidgetView can end
    // up pointing at a detached (orphaned) widget and downstream code (trashCanTapped, sliders,
    // delete-on-overlap) would operate on the orphan.
    self->selectedWidgetView = nil;
    self->widgetViewSelected = false;

    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[OnScreenWidgetView class]]) {
            [subview removeFromSuperview];
        }
    }

    [self.onScreenWidgetViews removeAllObjects];

    
    NSLog(@"reload os Key here");
    
    // _activeCustomOscButtonPositionDict will be updated every time when the osc profile is reloaded
    OSCProfile *oscProfile = [profilesManager getSelectedProfile]; //returns the currently selected OSCProfile
    BOOL fullscreenTriggerInstantiated = NO;

    // Two-pass build to enforce the editor's z-order contract independent of
    // profile storage order (matches StreamView.reloadOnScreenWidgetViews):
    //   streamOverlay < fullscreenTrigger < touchPad widgets < button widgets < widgetPanelStack < toolbar
    // Pass 1: instantiate + configure all widgets, bucket by widgetType.
    // Pass 2: attach in z-order fullscreen → pad → button via the shared
    //         insertWidgetInEditorZOrder: helper, then run setLocation /
    //         resize / adjust which all require a superview.
    NSMutableArray<OnScreenWidgetView*>* fullscreenWidgets = [NSMutableArray array];
    NSMutableArray<OnScreenWidgetView*>* padWidgets = [NSMutableArray array];
    NSMutableArray<OnScreenWidgetView*>* otherWidgets = [NSMutableArray array];
    NSMutableArray<OnScreenButtonState*>* fullscreenStates = [NSMutableArray array];
    NSMutableArray<OnScreenButtonState*>* padStates = [NSMutableArray array];
    NSMutableArray<OnScreenButtonState*>* otherStates = [NSMutableArray array];

    for (NSData *buttonStateEncoded in oscProfile.buttonStates) {
        // OnScreenButtonState* buttonState = [NSKeyedUnarchiver unarchivedObjectOfClass:[OnScreenButtonState class] fromData:buttonStateEncoded error:nil];
        OnScreenButtonState* buttonState = [profilesManager unarchiveButtonStateEncoded:buttonStateEncoded];
        if(buttonState.buttonType == CustomOnScreenWidget){
            // Match the runtime guard in StreamView.reloadOnScreenWidgetViews: defensively dedupe
            // duplicate fullscreen entries from a corrupted profile so the editor never shows two
            // overlapping handles.
            BOOL isFullscreen = [buttonState.widgetShape isEqualToString:@"fullscreen"];
            if(isFullscreen && fullscreenTriggerInstantiated) continue;
            OnScreenWidgetView* widgetView = [[OnScreenWidgetView alloc] initWithCmdString:buttonState.name buttonLabel:buttonState.alias shape:buttonState.widgetShape]; //reconstruct widgetView
            if(widgetView.widgetType == WidgetTypeEnumFullscreenTrigger){
                fullscreenTriggerInstantiated = YES;
            }
            widgetView.guidelineDelegate = (id<OnScreenWidgetGuidelineUpdateDelegate>)self;
            widgetView.translatesAutoresizingMaskIntoConstraints = NO; // weird but this is mandatory, or you will find no key views added to the right place
            widgetView.widthFactor = buttonState.widthFactor;
            widgetView.heightFactor = buttonState.heightFactor;
            widgetView.borderWidth = buttonState.borderWidth;
            [widgetView setVibrationWithStyle:buttonState.vibrationStyle];
            widgetView.mouseButtonAction = buttonState.mouseButtonAction;
            widgetView.sensitivityFactorX = buttonState.sensitivityFactorX;
            widgetView.sensitivityFactorY = buttonState.sensitivityFactorY;
            widgetView.trackballDecelerationRate = buttonState.decelerationRate;
            widgetView.stickIndicatorOffset = buttonState.stickIndicatorOffset;
            widgetView.minStickOffset = buttonState.minStickOffset;
            if (buttonState.stickInputScale > 0) widgetView.stickInputScale = buttonState.stickInputScale;
            if (buttonState.stickResponseExponent >= 1.0) widgetView.stickResponseExponent = buttonState.stickResponseExponent;
            widgetView.stickInvertVertical = buttonState.stickInvertVertical;
            widgetView.stickInvertHorizontal = buttonState.stickInvertHorizontal;
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

    // Pass 2 — attach each bucket in z-order. insertWidgetInEditorZOrder:
    // picks the correct anchor per widgetType; within a bucket we iterate in
    // profile order so the relative order of same-type widgets is stable.
    for (NSUInteger i = 0; i < fullscreenWidgets.count; i++) {
        OnScreenWidgetView* widgetView = fullscreenWidgets[i];
        OnScreenButtonState* buttonState = fullscreenStates[i];
        [self insertWidgetInEditorZOrder:widgetView];
        // Pin the handle to the view midpoint on every reload, ignoring any persisted
        // position (a stale off-center value would otherwise let a plain tap land on the
        // trash button via the touchesEnded overlap check, deleting the widget without a
        // drag). Save path may serialize whatever center the handle ended up at, but this
        // override makes that data effectively dead — every reload re-anchors here.
        [widgetView setLocationWithPosition:CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds))];
        [widgetView resizeWidgetView]; // resize must be called after relocation
        [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
        [widgetView adjustBorderWithWidth:buttonState.borderWidth];
        [self.onScreenWidgetViews addObject:widgetView];
    }
    for (NSUInteger i = 0; i < padWidgets.count; i++) {
        OnScreenWidgetView* widgetView = padWidgets[i];
        OnScreenButtonState* buttonState = padStates[i];
        [self insertWidgetInEditorZOrder:widgetView];
        buttonState.position = [self denormalizeWidgetPosition:buttonState.position];
        [widgetView setLocationWithPosition:buttonState.position];
        [widgetView resizeWidgetView]; // resize must be called after relocation
        [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
        [widgetView adjustBorderWithWidth:buttonState.borderWidth];
        [self.onScreenWidgetViews addObject:widgetView];
    }
    for (NSUInteger i = 0; i < otherWidgets.count; i++) {
        OnScreenWidgetView* widgetView = otherWidgets[i];
        OnScreenButtonState* buttonState = otherStates[i];
        [self insertWidgetInEditorZOrder:widgetView];
        buttonState.position = [self denormalizeWidgetPosition:buttonState.position];
        [widgetView setLocationWithPosition:buttonState.position];
        [widgetView resizeWidgetView]; // resize must be called after relocation
        [widgetView adjustTransparencyWithAlpha:buttonState.backgroundAlpha];
        [widgetView adjustBorderWithWidth:buttonState.borderWidth];
        [self.onScreenWidgetViews addObject:widgetView];
    }
}

- (void) viewDidLoad {
    [super viewDidLoad];
    profilesManager = [OSCProfilesManager sharedManager:self.view.bounds];
    self.onScreenWidgetViews = [[NSMutableSet alloc] init]; // will be revised to read persisted data , somewhere else
    [OSCProfilesManager setOnScreenWidgetViewsSet:self.onScreenWidgetViews];   // pass the keyboard button dict to profiles manager
    
    //isToolbarHidden = NO;   // keeps track if the toolbar is hidden up above the screen so that we know whether to hide or show it when the user taps the toolbar's hide/show button
    viewWillBeResized = false;
    
    /* add curve to bottom of chevron tab view */
    UIBezierPath *maskPath = [UIBezierPath bezierPathWithRoundedRect:self.chevronView.bounds byRoundingCorners:(UIRectCornerBottomLeft | UIRectCornerBottomRight) cornerRadii:CGSizeMake(10.0, 10.0)];
    CAShapeLayer *maskLayer = [[CAShapeLayer alloc] init];
    maskLayer.frame = self.view.bounds;
    maskLayer.path  = maskPath.CGPath;
    self.chevronView.layer.mask = maskLayer;
    
    /* Add swipe gesture to toolbar to allow user to swipe it up and off screen */
    UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(moveToolbar:)];
    swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
    [self.toolbarRootView addGestureRecognizer:swipeUp];
    
    /* Add tap gesture to toolbar's chevron to allow user to tap it in order to move the toolbar on and off screen */
    UITapGestureRecognizer *singleFingerTap =
    [[UITapGestureRecognizer alloc] initWithTarget:self
                                            action:@selector(moveToolbar:)];
    [self.chevronView addGestureRecognizer:singleFingerTap];
    
    // 创建白色半透明 overlay
    [self setupStreamOverlay];
    
    self.layoutOSC = [[LayoutOnScreenControls alloc] initWithView:self.view controllerSup:nil streamConfig:nil oscLevel:OSCSegmentSelected];
    self.layoutOSC._level = OnScreenControlsLevelCustom;
    self.layoutOSC.layoutToolVC = self;
    //[self.layoutOSC show];  // draw on screen controls
    [self.layoutOSC show];  // draw on screen controls

    [self addInnerAnalogSticksToOuterAnalogLayers]; // allows inner and analog sticks to be dragged together around the screen together as one unit which is the expected behavior
    
    self.undoButton.alpha = 0.3;    // no changes to undo yet, so fade out the undo button a bit
    
    NSMutableArray* allProfiles = [profilesManager getAllProfiles];
    /*
     if ([allProfiles count] == 0) { // if no saved OSC profiles exist yet then create one called 'Default' and associate it with Moonlight's legacy 'Full' OSC layout that's already been laid out on the screen at this point
     [profilesManager saveProfileWithName:@"Default" andButtonLayers:self.layoutOSC.OSCButtonLayers];
     [profilesManager importDefaultTemplates];
     }*/
    if (![profilesManager findProfileByName:DEFAULT_TEMPLATE_NAME1 inProfileArray:allProfiles]){
        [profilesManager importDefaultTemplates];
    }
        
    /* This will animate the toolbar with a subtle up and down motion intended to telegraph to the user that they can hide the toolbar if they wish*/
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        [UIView animateWithDuration:0.3
                              delay:0.25
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut animations:^{ // Animate toolbar up a a very small distance. Note the 0.35 time delay is necessary to avoid a bug that keeps animations from playing if the animation is presented immediately on a modally presented VC
            self.toolbarRootView.frame = CGRectMake(self.toolbarRootView.frame.origin.x, self.toolbarRootView.frame.origin.y - 25, self.toolbarRootView.frame.size.width, self.toolbarRootView.frame.size.height);
        }
                         completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3
                                  delay:0
                 usingSpringWithDamping:0.7
                  initialSpringVelocity:1.0
                                options:UIViewAnimationOptionCurveEaseIn animations:^{ // Animate the toolbar back down that same distance
                self.toolbarRootView.frame = CGRectMake(self.toolbarRootView.frame.origin.x, self.toolbarRootView.frame.origin.y + 25, self.toolbarRootView.frame.size.width, self.toolbarRootView.frame.size.height);
            }
                             completion:^(BOOL finished) {
                NSLog (@"done");
            }];
        }];
    });
    trashCanStoryBoardColor = trashCanButton.tintColor;
    self.toolbarRootView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toolbarRootView.layer.shadowOffset = CGSizeMake(0, 0);
    self.toolbarRootView.layer.shadowOpacity = 0.5;
    self.toolbarRootView.layer.shadowRadius = 7;
    
    vibrationGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
}

- (void)viewDidDisappear:(BOOL)animated{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    OnScreenWidgetView.editMode = true;
    selectedWidgetView = nil;
    widgetPanelStoredCenter = self.widgetPanelStack.center;
    [super viewDidAppear:animated];
    // 进入编辑界面时按当前方向应用锁定
    [self osc_applyLockForCurrentOrientationAndReloadIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated{
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(legacyOscLayerTapped:)
                                                 name:@"LegacyOscCALayerSelectedNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleProfileTablViewDismiss)
                                                 name:@"OscLayoutTableViewCloseNotification"
                                               object:nil];
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadOnScreenWidgetViews)
                                                 name:@"OscLayoutProfileSelctedInTableView"   // This is a special notification for reloading the on screen keyboard buttons. which can't be executed by _oscProfilesTableViewController.needToUpdateOscLayoutTVC code block, and has to be triggered by a notification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(widgetViewTapped:)
                                                 name:@"OnScreenWidgetViewSelected"
                                               object:nil];
        
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OSCLayoutChanged) name:@"OSCLayoutChanged" object:nil];    // used to notifiy this view controller that the user made a change to the OSC layout so that the VC can either fade in or out its 'Undo button' which will signify to the user whether there are any OSC layout changes to undo
        
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleReturnToForeground)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleEnterBackground)
                                                 name: UIApplicationWillResignActiveNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange) // handle orientation change since i made portrait mode available
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
    // 监听StreamFrameViewController发送的屏幕变化通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleScreenChanged:)
                                                 name:@"ScreenChanged"
                                               object:nil];
    
    OnScreenWidgetView.editMode = true;
    [self handleMissingToolBarIcon:toolbarRootView];
    [self profileRefresh];
    [self osc_setupRotationLockButton]; // screen-rotation lock toggle (locked by default)
}

#pragma mark - Class Helper Functions

- (void)updateViewBounds{
    viewWillBeResized = false;
    selectedWidgetView = nil;
    selectedControllerLayer = nil;

    _oscProfilesTableViewController.layoutViewBounds = self.view.bounds;
    [OSCProfilesManager setOnScreenWidgetViewsSet:self.onScreenWidgetViews];   // pass the keyboard button dict to profiles manager
    [self reloadOnScreenWidgetViews];
    [self reloadLegacyOnScreenControls];
    
    // 确保 stream overlay 始终在最底层
    [self ensureStreamOverlayAtBottom];
}

- (void)handleEnterBackground{
    [self saveTapped:nil];
}

- (void)handleReturnToForeground {
    // [OSCProfilesManager setOnScreenWidgetViewsSet:self.onScreenWidgetViews];   // pass the keyboard button dict to profiles manager
    [self setupWidgetPanel];
    [self updateViewBounds];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    NSLog(@"📱 viewWillTransitionToSize: %@ -> %@", NSStringFromCGSize(self.view.bounds.size), NSStringFromCGSize(size));
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        NSLog(@"⚠️ 应用不在活跃状态，跳过旋转处理");
        return;
    }
    viewWillBeResized = true;
    NSLog(@"✅ 设置 viewWillBeResized = true");
    [self hideStickIndicators];
    [self saveTapped:nil];
    // 旋转开始时，先行应用方向锁定（下一个runloop再刷新全局UI）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self osc_applyLockForCurrentOrientationAndReloadIfNeeded];
    });

    // viewWillBeResized gates handleOrientationChangeForOnScreenWidgets so it only
    // rebuilds widgets on a genuine interface resize. It is set true just above but
    // is otherwise cleared only inside updateViewBounds — and a timing race (the
    // device-orientation notification's handleOrientationChange can fire and
    // early-return *before* this method sets the flag) can leave it stuck true after
    // a rotation. Once stuck, every later small tilt passes the guard and runs a
    // no-save reloadOnScreenWidgetViews that wipes any still-unsaved edit (e.g. a
    // brand-new widget that was never written to the profile). Clear it
    // deterministically once the rotation transition finishes, so only genuine
    // resizes — not subsequent small tilts — can trigger the rebuild.
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Coordinator completions fire on the main thread; dispatch_async keeps the
        // reset explicitly on the main queue (matching the osc_applyLock call above)
        // and defers it one more hop. deviceOrientationDidChange schedules
        // handleOrientationChangeForOnScreenWidgets via performSelector:afterDelay:0 at
        // rotation start, so it runs (and performs the genuine post-rotation reload
        // while the flag is still true) well before this deferred reset lands.
        dispatch_async(dispatch_get_main_queue(), ^{
            self->viewWillBeResized = false;
        });
    }];
}

- (void)deviceOrientationDidChange{
    NSLog(@"📱 deviceOrientationDidChange 被调用");
    [self performSelector:@selector(handleOrientationChangeForOnScreenWidgets) withObject:self afterDelay:0.0];
}

- (void)handleScreenChanged:(NSNotification *)notification {
    NSLog(@"📺 handleScreenChanged 被调用 - 来自StreamFrameViewController");
    
    // 只有在非布局编辑模式下才处理（即在串流界面中）
    
    // 应用方向锁定
    [self osc_applyLockForCurrentOrientationAndReloadIfNeeded];
}


- (void)handleOrientationChangeForOnScreenWidgets{
    NSLog(@"🔄 handleOrientationChangeForOnScreenWidgets 被调用，viewWillBeResized = %@", viewWillBeResized ? @"YES" : @"NO");
    if(!viewWillBeResized) {
        NSLog(@"❌ viewWillBeResized = NO，跳过处理");
        return;
    }
    
    // 应用方向锁定（编辑界面）
    [self osc_applyLockForCurrentOrientationAndReloadIfNeeded];
    
    [self setupWidgetPanel];
    [self updateViewBounds];
}

/* fades the 'Undo Button' in or out depending on whether the user has any OSC layout changes to undo */
- (void) OSCLayoutChanged {
    if ([self.layoutOSC.layoutChanges count] > 0) {
        self.undoButton.alpha = 1.0;
    }
    else {
        self.undoButton.alpha = 0.3;
    }
}

/* animates the toolbar up and off the screen or back down onto the screen */
- (void) moveToolbar:(UISwipeGestureRecognizer *)sender {
    BOOL isPad = [[UIDevice currentDevice].model hasPrefix:@"iPad"];
    NSLayoutConstraint *toolbarTopConstraint = isPad ? self->toolbarTopConstraintiPad : self->toolbarTopConstraintiPhone;
    if (isToolbarHidden == NO) {
        [UIView animateWithDuration:0.2 animations:^{   // animates toolbar up and off screen
            toolbarTopConstraint.constant -= self.toolbarRootView.frame.size.height;
            [self.view layoutIfNeeded];
        }
        completion:^(BOOL finished) {
            if (finished) {
                self->isToolbarHidden = YES;
                self.chevronImageView.image = [UIImage imageNamed:@"ChevronCompactDown"];
            }
        }];
    }
    else {
        [UIView animateWithDuration:0.2 animations:^{   // animates the toolbar back down into the screen
            toolbarTopConstraint.constant += self.toolbarRootView.frame.size.height;
            [self.view layoutIfNeeded];
        }
        completion:^(BOOL finished) {
            if (finished) {
                self->isToolbarHidden = NO;
                self.chevronImageView.image = [UIImage imageNamed:@"ChevronCompactUp"];
            }
        }];
    }
}

/**
 * Makes the inner analog stick layers a child layer of its corresponding outer analog stick layers so that both the inner and its corresponding outer layers move together when the user drags them around the screen as is the expected behavior when laying out OSC. Note that this is NOT expected behavior on the game stream view where the inner analog sticks move to follow toward the user's touch and their corresponding outer analog stick layers do not move
 */
- (void)addInnerAnalogSticksToOuterAnalogLayers {
    // right stick
    [self.layoutOSC._rightStickBackground addSublayer: self.layoutOSC._rightStick];
    self.layoutOSC._rightStick.position = CGPointMake(self.layoutOSC._rightStickBackground.frame.size.width / 2, self.layoutOSC._rightStickBackground.frame.size.height / 2);
    
    // left stick
    [self.layoutOSC._leftStickBackground addSublayer: self.layoutOSC._leftStick];
    self.layoutOSC._leftStick.position = CGPointMake(self.layoutOSC._leftStickBackground.frame.size.width / 2, self.layoutOSC._leftStickBackground.frame.size.height / 2);
}


#pragma mark - UIButton Actions

- (IBAction) closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction) trashCanTapped:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Delete Buttons Here"] message:[LocalizationHelper localizedStringForKey:@"Drag and drop buttons onto this trash can to remove them from the interface"] preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *ok = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (IBAction) undoTapped:(id)sender {
    UIAlertController * nothingToUndoAlertController = [UIAlertController alertControllerWithTitle: [LocalizationHelper localizedStringForKey:@"Nothing to Undo"] message: [LocalizationHelper localizedStringForKey: @"There are no changes to undo"] preferredStyle:UIAlertControllerStyleAlert];
    [nothingToUndoAlertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [nothingToUndoAlertController dismissViewControllerAnimated:NO completion:nil];
    }]];

    
    if(!widgetViewSelected){
        if([self.layoutOSC.layoutChanges count] > 0) { // check if there are layout changes to roll back to
            OnScreenButtonState *buttonState = [self.layoutOSC.layoutChanges lastObject];   //  Get the 'OnScreenButtonState' object that contains the name, position, and visiblity state of the button the user last moved
            
            CALayer *buttonLayer = [self.layoutOSC controllerLayerFromName:buttonState.name];   // get the on screen button layer that corresponds with the 'OnScreenButtonState' object that we retrieved above
            
            /* Set the button's position and visiblity to what it was before the user last moved it */
            buttonLayer.position = buttonState.position;
            buttonLayer.hidden = buttonState.isHidden;
            
            /* if user is showing or hiding dPad, then show or hide all four dPad button child layers as well since setting the 'hidden' property on the parent CALayer is not automatically setting the individual dPad child CALayers */
            if ([buttonLayer.name isEqualToString:@"dPad"]) {
                self.layoutOSC._upButton.hidden = buttonState.isHidden;
                self.layoutOSC._rightButton.hidden = buttonState.isHidden;
                self.layoutOSC._downButton.hidden = buttonState.isHidden;
                self.layoutOSC._leftButton.hidden = buttonState.isHidden;
            }
            
            /* if user is showing or hiding the left or right analog sticks, then show or hide their corresponding inner analog stick child layers as well since setting the 'hidden' property on the parent analog stick doesn't automatically hide its child inner analog stick CALayer */
            if ([buttonLayer.name isEqualToString:@"leftStickBackground"]) {
                self.layoutOSC._leftStick.hidden = buttonState.isHidden;
            }
            if ([buttonLayer.name isEqualToString:@"rightStickBackground"]) {
                self.layoutOSC._rightStick.hidden = buttonState.isHidden;
            }
            
            [self.layoutOSC.layoutChanges removeLastObject];
            
            [self OSCLayoutChanged]; // will fade the undo button in or out depending on whether there are any further changes to undo
        }
        else {  // there are no changes to undo. let user know there are no changes to undo
            [self presentViewController:nothingToUndoAlertController animated:YES completion:nil];
        }
    }
    else{
        NSInteger recordChangesCount = selectedWidgetView.layoutChanges.count;
        if(recordChangesCount>1) [selectedWidgetView undoRelocation];
        else [self presentViewController:nothingToUndoAlertController animated:YES completion:nil];
        self.undoButton.alpha = selectedWidgetView.layoutChanges.count>1 ? 1.0 : 0.3;
    }
}

- (void) presentFullscreenTriggerDuplicateAlert{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Duplicate Full-Screen Trigger"]
                                                                   message:[LocalizationHelper localizedStringForKey:@"Only one full-screen trigger widget is allowed per profile. Delete the existing one first."]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) presentInvalidWidgetCommandAlert{
    UIAlertController *savedAlertController = [UIAlertController alertControllerWithTitle: [LocalizationHelper localizedStringForKey:@"Invalid Input"] message: [LocalizationHelper localizedStringForKey:@"Check the command and parameter."] preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *readInstruction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Read Widget Instruction"]
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction *action){
        //[self saveTapped:nil];
        NSURL *url = [NSURL URLWithString:[LocalizationHelper localizedStringForKey:@"onScreenWidgetStackDoc"]];
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"OK"]
                                                           style:UIAlertActionStyleDefault
                                                     handler:nil];
    [savedAlertController addAction:readInstruction];
    [savedAlertController addAction:okAction];
    
    [self presentViewController:savedAlertController animated:YES completion:nil];
}

- (IBAction) addTapped:(id)sender{

    NSMutableDictionary* widgetInitParams = [NSMutableDictionary dictionary];

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@""]
                                                                             message:[LocalizationHelper localizedStringForKey:@"New On-Screen Widget"]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Command"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Alias label (optional)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Minimum stick offset (0~32766)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Shape (r/s/f)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
    }];


    UIAlertAction *readInstruction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Read Widget Instruction"]
                                                           style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action){
        //[self saveTapped:nil];
        NSURL *url = [NSURL URLWithString:[LocalizationHelper localizedStringForKey:@"onScreenWidgetStackDoc"]];
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }];
    
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"]
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"OK"]
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        [widgetInitParams setObject: alertController.textFields[0].text forKey:@"cmdString"]; // convert to uppercase
        [widgetInitParams setObject: alertController.textFields[1].text forKey:@"buttonLabel"]; // convert to uppercase
        [widgetInitParams setObject: alertController.textFields[2].text forKey:@"minStickOffsetString"]; // convert to uppercase
        [widgetInitParams setObject: alertController.textFields[3].text forKey:@"shape"]; // convert to uppercase
        [self createWidgetFromParams:widgetInitParams];
    }];
    [alertController addAction:readInstruction];
    [alertController addAction:cancelAction];
    [alertController addAction:okAction];
    [self presentViewController:alertController animated:YES completion:nil];
}


- (IBAction) editTapped:(id)sender{
    
    NSMutableDictionary* widgetInitParams = [NSMutableDictionary dictionary];

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@""]
                                                                             message:[LocalizationHelper localizedStringForKey:@"Edit Selected Widget"]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    if(self->selectedWidgetView == nil) return;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Command"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.text = [self->selectedWidgetView.cmdString lowercaseString];
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Alias label (optional)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.text = self->selectedWidgetView.buttonLabel;
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Minimum stick offset (0~32766)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        if(self->selectedWidgetView.minStickOffset > 0) textField.text = [NSString stringWithFormat:@"%d", (int)self->selectedWidgetView.minStickOffset];
    }];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Shape (r/s/f)"];
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.text = self->selectedWidgetView.shape;
        if([self->selectedWidgetView.shape isEqualToString: @"largeSquare"]) textField.enabled = false;
    }];
    

    UIAlertAction *createNewAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Create New"]
                                                           style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
        [widgetInitParams setObject: alertController.textFields[0].text forKey:@"cmdString"];
        [widgetInitParams setObject: alertController.textFields[1].text forKey:@"buttonLabel"];
        [widgetInitParams setObject: alertController.textFields[2].text forKey:@"minStickOffsetString"];
        [widgetInitParams setObject: alertController.textFields[3].text forKey:@"shape"];
        [self updateWidget:self->selectedWidgetView byParams:widgetInitParams createNew:true];
    }];

    UIAlertAction *modifyAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Modify"]
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        [widgetInitParams setObject: alertController.textFields[0].text forKey:@"cmdString"];
        [widgetInitParams setObject: alertController.textFields[1].text forKey:@"buttonLabel"];
        [widgetInitParams setObject: alertController.textFields[2].text forKey:@"minStickOffsetString"];
        [widgetInitParams setObject: alertController.textFields[3].text forKey:@"shape"];
        [self updateWidget:self->selectedWidgetView byParams:widgetInitParams createNew:false];
    }];
    
    [alertController addAction:createNewAction];
    [alertController addAction:modifyAction];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (bool) isWidgetParamsValid:(NSMutableDictionary* )widgetInitParams{
    NSString *cmdString = [widgetInitParams[@"cmdString"] uppercaseString]; // convert to uppercase
    NSString *buttonLabel = widgetInitParams[@"buttonLabel"];
    NSString *minStickOffsetString = widgetInitParams[@"minStickOffsetString"];
    NSString *widgetShape = [widgetInitParams[@"shape"] lowercaseString];
        
    widgetInitParams[@"cmdString"] = cmdString;
    bool noValidKeyboardString = [CommandManager.shared extractKeyStringsFromComboCommandFrom:cmdString] == nil; // this is a invalid string.
    bool noValidSuperComboButtonString = [CommandManager.shared extractSinglCmdStringsFromComboKeysFrom:cmdString] == nil; // this is a invalid string.
    bool noValidMouseButtonString = ![CommandManager.mouseButtonMappings.allKeys containsObject:cmdString];
    bool noValidTouchPadString = ![CommandManager.touchPadCmds containsObject:cmdString];
    bool noValidOscButtonString = ![CommandManager.oscButtonMappings.allKeys containsObject:cmdString];
    bool noValidSpecialButtonString = ![CommandManager.specialOverlayButtonCmds containsObject:cmdString];
    bool paramInvalid = noValidKeyboardString && noValidMouseButtonString && noValidTouchPadString && noValidOscButtonString && noValidSpecialButtonString && noValidSuperComboButtonString;
    
    if([buttonLabel isEqualToString:@""]) widgetInitParams[@"buttonLabel"] = [[cmdString lowercaseString] capitalizedString];

    NSCharacterSet *nonDigitCharacterSet = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *trimmedString = [minStickOffsetString stringByTrimmingCharactersInSet:nonDigitCharacterSet];
    if(trimmedString.length != minStickOffsetString.length) paramInvalid = true;
    widgetInitParams[@"minStickOffsetString"] = trimmedString;
    
    NSSet* validShapes = [NSSet setWithObjects:@"round", @"square", @"largesquare", @"fullscreen", nil];
    if([widgetShape isEqualToString:@"r"]) widgetShape = @"round";
    else if([widgetShape isEqualToString:@"s"]) widgetShape = @"square";
    else if([widgetShape isEqualToString:@"f"]) widgetShape = @"fullscreen";
    else if([widgetShape isEqualToString:@""]) widgetShape = @"default";
    else if(![validShapes containsObject:widgetShape]){
        paramInvalid = true;}
    widgetInitParams[@"shape"] = widgetShape;

    if(!paramInvalid && [widgetShape isEqualToString:@"fullscreen"]){
        bool boundKey =
            !noValidKeyboardString ||
            !noValidMouseButtonString ||
            !noValidOscButtonString ||
            !noValidSuperComboButtonString;
        if(!boundKey){
            paramInvalid = true; // fullscreen trigger requires a real key/button/combo binding
        }
        if(!paramInvalid){
            for (OnScreenWidgetView *existing in self.onScreenWidgetViews) {
                if(existing.widgetType == WidgetTypeEnumFullscreenTrigger && existing != self->selectedWidgetView){
                    [self presentFullscreenTriggerDuplicateAlert];
                    return false; // short-circuit: suppress generic invalid alert
                }
            }
        }
    }

    if(paramInvalid) [self presentInvalidWidgetCommandAlert];
    return !paramInvalid;
}

- (void) updateWidget:(OnScreenWidgetView* )widget byParams:(NSMutableDictionary* )widgetInitParams createNew:(bool)createNew{
    if(![self isWidgetParamsValid:widgetInitParams]) return;
    // Creating a clone would leave us with two fullscreen triggers, which is forbidden.
    // (In modify mode the old widget is removed below, so the check in isWidgetParamsValid
    // already handles that path by excluding selectedWidgetView.)
    if(createNew && [widgetInitParams[@"shape"] isEqualToString:@"fullscreen"]){
        for (OnScreenWidgetView *existing in self.onScreenWidgetViews) {
            if(existing.widgetType == WidgetTypeEnumFullscreenTrigger){
                [self presentFullscreenTriggerDuplicateAlert];
                return;
            }
        }
    }
    OnScreenWidgetView* newWidget = [[OnScreenWidgetView alloc] initWithCmdString:widgetInitParams[@"cmdString"] buttonLabel:widgetInitParams[@"buttonLabel"] shape:widgetInitParams[@"shape"]]; //reconstruct widgetView
    newWidget.guidelineDelegate = (id<OnScreenWidgetGuidelineUpdateDelegate>)self;
    newWidget.translatesAutoresizingMaskIntoConstraints = NO; // weird but this is mandatory, or you will find no key views added to the right place
    newWidget.widthFactor = widget.widthFactor;
    newWidget.heightFactor = widget.heightFactor;
    newWidget.borderWidth = widget.borderWidth;
    newWidget.sensitivityFactorX = widget.sensitivityFactorX;
    newWidget.sensitivityFactorY = widget.sensitivityFactorY;
    newWidget.trackballDecelerationRate = widget.trackballDecelerationRate;
    newWidget.stickIndicatorOffset = widget.stickIndicatorOffset;
    newWidget.minStickOffset = [widgetInitParams[@"minStickOffsetString"] floatValue];
    // Only carry response-curve tunables across when both old and new are ALT pads;
    // otherwise the new widget keeps its type-appropriate init defaults.
    if (widget.hasResponseCurveTweak && newWidget.hasResponseCurveTweak) {
        newWidget.stickInputScale = widget.stickInputScale;
        newWidget.stickResponseExponent = widget.stickResponseExponent;
        newWidget.stickInvertVertical = widget.stickInvertVertical;
        newWidget.stickInvertHorizontal = widget.stickInvertHorizontal;
    }
    [newWidget setVibrationWithStyle:widget.vibrationStyle];
    newWidget.mouseButtonAction = widget.mouseButtonAction;
    newWidget.slideMode = widget.slideMode;
    // Z-order: fullscreenTrigger / touchPad / button each land in their own
    // layer band — see insertWidgetInEditorZOrder: for the full contract.
    [self insertWidgetInEditorZOrder:newWidget];

    if(createNew){
        if(newWidget.widgetType == WidgetTypeEnumFullscreenTrigger){
            [newWidget setLocationWithPosition:CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds))];
        } else {
            [newWidget setLocationWithPosition:CGPointMake(90, 130)];
        }
    }
    else [newWidget setLocationWithPosition:widget.center];
    [newWidget resizeWidgetView]; // resize must be called after relocation
    [newWidget adjustTransparencyWithAlpha:widget.backgroundAlpha];
    [newWidget adjustBorderWithWidth:widget.borderWidth];
    [self.onScreenWidgetViews addObject:newWidget];
    self->selectedWidgetView = newWidget;
    if(!createNew){
        [self.onScreenWidgetViews removeObject:widget];
        [widget removeFromSuperview];
    }
}


- (void) createWidgetFromParams: (NSMutableDictionary*) widgetInitParams{
    if(![self isWidgetParamsValid:widgetInitParams]) return;
    //saving & present the keyboard button:
    OnScreenWidgetView* widgetView = [[OnScreenWidgetView alloc] initWithCmdString:widgetInitParams[@"cmdString"] buttonLabel:widgetInitParams[@"buttonLabel"] shape:widgetInitParams[@"shape"]];
    widgetView.guidelineDelegate = (id<OnScreenWidgetGuidelineUpdateDelegate>)self;
    widgetView.translatesAutoresizingMaskIntoConstraints = NO; // weird but this is mandatory, or you will find no key views added to the right place
    widgetView.minStickOffset = [widgetInitParams[@"minStickOffsetString"] floatValue];
    [self.onScreenWidgetViews addObject:widgetView];
    // Add to the editor view in the right z-order band (see insertWidgetInEditorZOrder:),
    // then anchor: fullscreen trigger goes to view center, everything else to a spawn slot.
    [self insertWidgetInEditorZOrder:widgetView];
    if(widgetView.widgetType == WidgetTypeEnumFullscreenTrigger){
        [widgetView setLocationWithPosition:CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds))];
    } else {
        [widgetView setLocationWithPosition:CGPointMake(90, 130)];
    }
    [widgetView resizeWidgetView];
    [widgetView setVibrationWithStyle:UIImpactFeedbackStyleLight];
}


/* show pop up notification that lets users choose to save the current OSC layout configuration as a profile they can load when they want. User can also choose to cancel out of this pop up */
- (IBAction) saveTapped:(id)sender {
    [OSCProfilesManager setLayoutViewBounds:self.view.bounds];
    
    if([self->profilesManager updateSelectedProfile:self.layoutOSC.OSCButtonLayers]){
        UIAlertController * savedAlertController = [UIAlertController alertControllerWithTitle: [NSString stringWithFormat:@""] message: [LocalizationHelper localizedStringForKey:@"Current profile updated successfully"] preferredStyle:UIAlertControllerStyleAlert];
        [savedAlertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        }]];
        if(sender) [self presentViewController:savedAlertController animated:YES completion:nil];
    }
    else{
        OSCProfile *selectedProfile = [profilesManager getSelectedProfile];
        NSString *message = [NSString stringWithFormat:@"模板布局'%@'不可被覆盖", selectedProfile.name];
        UIAlertController * savedAlertController = [UIAlertController alertControllerWithTitle: [NSString stringWithFormat:@""] message: message preferredStyle:UIAlertControllerStyleAlert];
        [savedAlertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.oscProfilesTableViewController profileViewRefresh]; // execute this will reset layout in OSC tool!
        }]];
        if(sender) [self presentViewController:savedAlertController animated:YES completion:nil];
    }
}

- (void)autoFitStack:(UIStackView* )stack{
    CGSize fittingSize = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGRect newFrame = stack.frame;
    newFrame.size = fittingSize;
    stack.frame = newFrame;
    [self updateClippedMaskForView:stack];
    if (@available(iOS 14, *)) nil;
    else [self applyShadowForiOS13:stack];
}

- (void)enableCommonWidgetTools{
    self.loadConfigTipLabel.hidden = YES;
    self.widgetSizeStack.hidden = NO;
    self.widgetHeightStack.hidden = NO;
    self.borderWidthAlphaStack.hidden = NO;
    if([self isIPhone]) self.vibrationStyleStack.hidden = NO;
    
    // 显示坐标控件
    self.coordinateControlStack.hidden = NO;
}

- (void)autoFitLabel:(UILabel* )label{
    label.adjustsFontSizeToFitWidth = true;
    label.minimumScaleFactor = 0.3;
    label.numberOfLines = 1;
}

- (void)hideStickIndicators{
    for(UIView* view in self.view.subviews){
        if([view isKindOfClass:[OnScreenWidgetView class]]){
            OnScreenWidgetView* widget = (OnScreenWidgetView* )view;
            [widget.crossMarkLayer setHidden:true];
            [widget.stickBallLayer setHidden:true];

        }
    }
}

/*
- (CGFloat)denormalizeSizeFactor:(CGFloat)sizeFactor{
    bool isNormalizedSizeFactor = sizeFactor > 6;
    return isNormalizedSizeFactor ? sizeFactor/10000*[UIScreen mainScreen].bounds.size.width
}
 */

- (void)widgetViewTapped: (NSNotification *)notification{
    //self.undoButton.alpha = selectedWidgetView.layoutChanges.count>1 && !CGPointEqualToPoint(selectedWidgetView.layoutChanges.lastObject.CGPointValue, selectedWidgetView.initialCenter)? 1.0 : 0.3;
    [self hideStickIndicators];
    
    // receive the selected widgetView obj passed from the notification
    [self enableCommonWidgetTools];

    
    OnScreenWidgetView* widgetView = (OnScreenWidgetView* )notification.object;
    self->widgetViewSelected = true;
    self->controllerLayerSelected = false;
    self->selectedWidgetView = widgetView;
    
    [self autoFitLabel:self.currentProfileLabel];
    self.currentProfileLabel.textAlignment = NSTextAlignmentLeft;
    [self.currentProfileLabel setText:
     [LocalizationHelper localizedStringForKey:@"  Profile: %@     Widget: %@",
      [profilesManager getSelectedProfile].name,
      selectedWidgetView.buttonLabel]];
    
    self.undoButton.alpha = selectedWidgetView.layoutChanges.count>1 ? 1.0 : 0.3;
    
    [self.layoutOSC updateGuidelinesForOnScreenWidget:self->selectedWidgetView]; // shows guideline immediately when widget is tapped
    // setup slider values
    [self.widgetSizeSlider setValue: self->selectedWidgetView.deNormalizedWidthFactor];
    [self.widgetHeightSlider setValue: self->selectedWidgetView.deNormalizedHeightFactor];
    [self.widgetAlphaSlider setValue: self->selectedWidgetView.backgroundAlpha];
    [self.widgetBorderWidthSlider setValue:self->selectedWidgetView.borderWidth];
    
    bool isFullscreenTrigger = selectedWidgetView.widgetType == WidgetTypeEnumFullscreenTrigger;

    self.slidableStack.hidden = selectedWidgetView.widgetType != WidgetTypeEnumButton;
    [self.slidableSelector setSelectedSegmentIndex:selectedWidgetView.slideMode];

    bool showSensitivityFactorStack = selectedWidgetView.hasSensitivityTweak && !isFullscreenTrigger;
    bool showStickIndicatorOffsetStack = selectedWidgetView.hasStickIndicator && !isFullscreenTrigger;
    bool showResponseCurveStack = selectedWidgetView.hasResponseCurveTweak && !isFullscreenTrigger;

    self.sensitivityXStack.hidden = self.sensitivityYStack.hidden = !showSensitivityFactorStack;
    self.stickIndicatorOffsetStack.hidden = !showStickIndicatorOffsetStack;
    self.stickInputScaleStack.hidden = self.stickResponseExponentStack.hidden = !showResponseCurveStack;
    self.stickInvertVerticalStack.hidden = self.stickInvertHorizontalStack.hidden = !showResponseCurveStack;
    self.mouseDownButtonStack.hidden = isFullscreenTrigger || !([selectedWidgetView.cmdString containsString:@"MOUSEPAD"] && selectedWidgetView.widgetType == WidgetTypeEnumTouchPad);
    self.decelerationRateStack.hidden = isFullscreenTrigger || !([selectedWidgetView.cmdString containsString:@"TRACKBALL"] && selectedWidgetView.widgetType == WidgetTypeEnumTouchPad);

    // Fullscreen trigger is pinned (no size/position controls), transparent (no alpha/border),
    // and has no slide/mouse/sensitivity behavior — hide the unrelated stacks entirely.
    self.widgetSizeStack.hidden = isFullscreenTrigger;
    self.widgetHeightStack.hidden = isFullscreenTrigger;
    self.borderWidthAlphaStack.hidden = isFullscreenTrigger;
    if(isFullscreenTrigger){
        self.coordinateControlStack.hidden = YES;
    }
    
    [self autoFitStack:self.widgetPanelStack];

    if(showSensitivityFactorStack){
        [self.sensitivityXSlider setValue:self->selectedWidgetView.sensitivityFactorX];
        [self autoFitLabel:self.sensitivityXLabel];
        [self.sensitivityXLabel setText:[LocalizationHelper localizedStringForKey:@"SensitivityX: %.2f", self->selectedWidgetView.sensitivityFactorX]];
        [self autoFitLabel:self.sensitivityYLabel];
        [self.sensitivityYSlider setValue:self->selectedWidgetView.sensitivityFactorY];
        [self.sensitivityYLabel setText:[LocalizationHelper localizedStringForKey:@"SensitivityY: %.2f", self->selectedWidgetView.sensitivityFactorY]];
    }
    if(showStickIndicatorOffsetStack){
        // illustrating the indicator offset,
        [self hideStickIndicators];
        selectedWidgetView.touchBeganLocation = CGPointMake(CGRectGetWidth(selectedWidgetView.frame)/2, CGRectGetHeight(selectedWidgetView.frame)/4);
        [selectedWidgetView showStickIndicator];// this will create the indicator CAShapeLayers
        [self.stickIndicatorOffsetSlider setValue:self->selectedWidgetView.stickIndicatorOffset];
        [self autoFitLabel:self.stickIndicatorOffsetLabel];
        [self.stickIndicatorOffsetLabel setText:[LocalizationHelper localizedStringForKey:@"Indicator Offset: %.0f", self->selectedWidgetView.stickIndicatorOffset]];
        [self->selectedWidgetView updateStickIndicator];
    }
    if(showResponseCurveStack){
        [self.stickInputScaleSlider setValue:self->selectedWidgetView.stickInputScale];
        [self autoFitLabel:self.stickInputScaleLabel];
        [self.stickInputScaleLabel setText:[LocalizationHelper localizedStringForKey:@"Stick Range: %.0f", self->selectedWidgetView.stickInputScale]];
        [self.stickResponseExponentSlider setValue:self->selectedWidgetView.stickResponseExponent];
        [self autoFitLabel:self.stickResponseExponentLabel];
        [self.stickResponseExponentLabel setText:[LocalizationHelper localizedStringForKey:@"Stick Curve: %.2f", self->selectedWidgetView.stickResponseExponent]];
        self.stickInvertVerticalSwitch.on = self->selectedWidgetView.stickInvertVertical;
        self.stickInvertHorizontalSwitch.on = self->selectedWidgetView.stickInvertHorizontal;
    }
    [self autoFitLabel:self.widgetSizeLabel];
    

    [self.widgetSizeLabel setText:[LocalizationHelper localizedStringForKey:@"Size: %.2f", self->selectedWidgetView.deNormalizedWidthFactor]];
    
    [self autoFitLabel:self.widgetHeightLabel];
    [self.widgetHeightLabel setText:[LocalizationHelper localizedStringForKey:@"Height: %.2f", self->selectedWidgetView.deNormalizedHeightFactor]];
    
    [self autoFitLabel:self.widgetAlphaLabel];
    [self.widgetAlphaLabel setText:[LocalizationHelper localizedStringForKey:@"Alpha: %.2f", self->selectedWidgetView.backgroundAlpha]];
    
    [self autoFitLabel:self.widgetBorderWidthLabel];
    [self.widgetBorderWidthLabel setText:[LocalizationHelper localizedStringForKey:@"Border Width: %.2f", self->selectedWidgetView.borderWidth]];
    
    [self.decelerationRateSlider setValue:selectedWidgetView.trackballDecelerationRate];
    [self autoFitLabel:self.decelerationRateLabel];
    [self.decelerationRateLabel setText:[LocalizationHelper localizedStringForKey:@"Deceleration Rate: %.3f  ", selectedWidgetView.trackballDecelerationRate]];
    self.mouseButtonDownSelector.selectedSegmentIndex = selectedWidgetView.mouseButtonAction;

    if([self isIPhone]){
        self.vibrationStyleStack.hidden =
        [widgetView.cmdString containsString:@"MOUSEPAD"] ||
        [widgetView.cmdString containsString:@"TRACKBALL"];
        [self autoFitStack:self.widgetPanelStack];
        self.vibrationStyleSelector.selectedSegmentIndex = self->selectedWidgetView.vibrationStyle;
    }
    
    // 更新坐标显示
    [self updateCoordinateDisplay];
}


- (void)legacyOscLayerTapped: (NSNotification *)notification{
    [self enableCommonWidgetTools];
    CALayer* controllerLayer = (CALayer* )notification.object;
    [self hideStickIndicators];
    self->widgetViewSelected = false;
    self->selectedWidgetView = nil;
    
    self.stickIndicatorOffsetStack.hidden = true;
    self.sensitivityXStack.hidden = self.sensitivityYStack.hidden = true;
    self.mouseDownButtonStack.hidden = true;
    self.decelerationRateStack.hidden = true;
    self.stickInputScaleStack.hidden = self.stickResponseExponentStack.hidden = true;
    self.stickInvertVerticalStack.hidden = self.stickInvertHorizontalStack.hidden = true;
    
    self->controllerLayerSelected = true;
    self->selectedControllerLayer = controllerLayer;
    self->controllerLoadedBounds = controllerLayer.bounds;
    
    [self autoFitLabel:self.currentProfileLabel];
    self.currentProfileLabel.textAlignment = NSTextAlignmentLeft;
    [self.currentProfileLabel setText:
     [LocalizationHelper localizedStringForKey:@"  Profile: %@     Widget: %@",
      [profilesManager getSelectedProfile].name,
      selectedControllerLayer.name]];

    
    // setup slider values
    CGFloat sizeFactor = [OnScreenControls getControllerLayerSizeFactor:controllerLayer]; // calculated sizeFactor from loaded layer bounds.
    [self.widgetSizeSlider setValue:sizeFactor];
    [self.widgetHeightSlider setValue:sizeFactor];
    CGFloat alpha = [self.layoutOSC getControllerLayerOpacity:controllerLayer];
    [self.widgetAlphaSlider setValue:alpha];
    
    [self.widgetSizeLabel setText:[LocalizationHelper localizedStringForKey:@"Size: %.2f", sizeFactor]];
    [self.widgetHeightLabel setText:[LocalizationHelper localizedStringForKey:@"Height: %.2f", sizeFactor]];
    [self.widgetAlphaLabel setText:[LocalizationHelper localizedStringForKey:@"Alpha: %.2f", alpha]];
    if([self isIPhone]){
        self.vibrationStyleStack.hidden = NO;
        NSNumber *style = [OnScreenControls.layerVibrationStyleDic objectForKey:selectedControllerLayer.name];
        self.vibrationStyleSelector.selectedSegmentIndex = [style unsignedCharValue];
    }
    [self autoFitStack:_widgetPanelStack];
    
    // 更新坐标显示
    [self updateCoordinateDisplay];
}

- (void)widgetSizeSliderMoved:(UISlider* )sender{
    [self.widgetSizeLabel setText:[LocalizationHelper localizedStringForKey:@"Size: %.2f", sender.value]];
    [self.widgetHeightLabel setText:[LocalizationHelper localizedStringForKey:@"Height: %.2f", sender.value]]; // resizing the whole button
    [self.widgetHeightSlider setValue: sender.value];
    
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.translatesAutoresizingMaskIntoConstraints = true; // this is mandatory to prevent unexpected key view location change
        // when adjusting width, the widgetView height will be syncronized
        self->selectedWidgetView.widthFactor = self->selectedWidgetView.heightFactor = sender.value;
        [self->selectedWidgetView resizeWidgetView];
    }
    if(self->selectedControllerLayer != nil && self->controllerLayerSelected){
        [self.layoutOSC resizeControllerLayerWith:self->selectedControllerLayer and:sender.value];
    }
}

- (void)widgetHeightSliderMoved:(UISlider* )sender{
    [self.widgetHeightLabel setText:[LocalizationHelper localizedStringForKey:@"Height: %.2f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.translatesAutoresizingMaskIntoConstraints = true; // this is mandatory to prevent unexpected key view location change
        if([self->selectedWidgetView.shape isEqualToString:@"round"]) return; // don't change height for round buttons, except for dPad buttons which are in rectangle shape
        self->selectedWidgetView.heightFactor = sender.value;
        [self->selectedWidgetView resizeWidgetView];
    }
}

- (void)widgetAlphaSliderMoved:(UISlider* )sender{
    [self.widgetAlphaLabel setText:[LocalizationHelper localizedStringForKey:@"Alpha: %.2f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        [self->selectedWidgetView adjustTransparencyWithAlpha:sender.value];
    }

    if(self->selectedControllerLayer != nil && self->controllerLayerSelected){
        [self.layoutOSC adjustControllerLayerOpacityWith:self->selectedControllerLayer and:sender.value];
    }
    return;
}

- (void)widgetBorderWidthSliderMoved:(UISlider* )sender{
    [self.widgetBorderWidthLabel setText:[LocalizationHelper localizedStringForKey:@"Border Width: %.2f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        [self->selectedWidgetView adjustBorderWithWidth:sender.value];
    }
    return;
}

- (void)mouseDownButtonChanged:(UISegmentedControl* )sender{
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        selectedWidgetView.mouseButtonAction = _mouseButtonDownSelector.selectedSegmentIndex;
    }
}

- (void)slideModeChanged:(UISegmentedControl* )sender{
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        selectedWidgetView.slideMode = _slidableSelector.selectedSegmentIndex;
    }
}

- (void)vibrationStyleChanged:(UISegmentedControl* )sender{
    bool vibraiontOn;
    if (@available(iOS 13.0, *)) {
        vibraiontOn = sender.selectedSegmentIndex < UIImpactFeedbackStyleRigid+1;
    } else {
        vibraiontOn = sender.selectedSegmentIndex < UIImpactFeedbackStyleHeavy+1;
    }
    if(vibraiontOn){
        vibrationGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:sender.selectedSegmentIndex];
        [vibrationGenerator prepare];
        [vibrationGenerator impactOccurred];
        NSLog(@"vibration instance: %@", vibrationGenerator);
    }
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        [self->selectedWidgetView setVibrationWithStyle:sender.selectedSegmentIndex];
    }
    if(self->selectedControllerLayer != nil && self->controllerLayerSelected){
        [OnScreenControls.layerVibrationStyleDic setObject:@(sender.selectedSegmentIndex) forKey:self->selectedControllerLayer.name];
    }
}

- (void)sensitivityXSliderMoved:(UISlider* )sender{
    [self.sensitivityXLabel setText:[LocalizationHelper localizedStringForKey:@"SensitivityX: %.2f", sender.value]];
    [self.sensitivityYLabel setText:[LocalizationHelper localizedStringForKey:@"SensitivityY: %.2f", sender.value]];
    [self.sensitivityYSlider setValue:sender.value];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.sensitivityFactorX = sender.value;
        self->selectedWidgetView.sensitivityFactorY = sender.value;
    }
    return;
}

- (void)sensitivityYSliderMoved:(UISlider* )sender{
    [self.sensitivityYLabel setText:[LocalizationHelper localizedStringForKey:@"SensitivityY: %.2f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected) self->selectedWidgetView.sensitivityFactorY = sender.value;
    return;
}

- (void)decelerationRateSliderMoved:(UISlider* )sender{
    [self.decelerationRateLabel setText:[LocalizationHelper localizedStringForKey:@"Deceleration Rate: %.3f  ", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected) self->selectedWidgetView.trackballDecelerationRate = sender.value;
    return;
}


- (void)stickIndicatorOffsetSliderMoved:(UISlider* )sender{
    [self.stickIndicatorOffsetLabel setText:[LocalizationHelper localizedStringForKey:@"Indicator Offset: %.0f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.stickIndicatorOffset = sender.value;
        [self->selectedWidgetView updateStickIndicator];
    }
    return;
}

- (void)stickInputScaleSliderMoved:(UISlider* )sender{
    [self.stickInputScaleLabel setText:[LocalizationHelper localizedStringForKey:@"Stick Range: %.0f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.stickInputScale = sender.value;
    }
}

- (void)stickResponseExponentSliderMoved:(UISlider* )sender{
    [self.stickResponseExponentLabel setText:[LocalizationHelper localizedStringForKey:@"Stick Curve: %.2f", sender.value]];
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.stickResponseExponent = sender.value;
    }
}

- (void)installResponseCurveSliders{
    UIColor* whiteColor = [UIColor whiteColor];
    UIFont* labelFont = [UIFont systemFontOfSize:18];
    UIColor* sliderTint = [UIColor colorWithRed:0.188 green:0.690 blue:0.780 alpha:0.5];

    // Range slider: physical finger travel (in points) for full deflection.
    self.stickInputScaleLabel = [[UILabel alloc] init];
    self.stickInputScaleLabel.font = labelFont;
    self.stickInputScaleLabel.textColor = whiteColor;
    self.stickInputScaleLabel.text = [LocalizationHelper localizedStringForKey:@"Stick Range"];
    [self.stickInputScaleLabel.widthAnchor constraintEqualToConstant:160].active = YES;

    self.stickInputScaleSlider = [[UISlider alloc] init];
    self.stickInputScaleSlider.minimumValue = 30;
    self.stickInputScaleSlider.maximumValue = 120;
    self.stickInputScaleSlider.value = 55;
    self.stickInputScaleSlider.tintColor = sliderTint;
    [self.stickInputScaleSlider addTarget:self action:@selector(stickInputScaleSliderMoved:) forControlEvents:UIControlEventValueChanged];

    self.stickInputScaleStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.stickInputScaleLabel, self.stickInputScaleSlider]];
    self.stickInputScaleStack.axis = UILayoutConstraintAxisHorizontal;
    self.stickInputScaleStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stickInputScaleStack.heightAnchor constraintEqualToConstant:20].active = YES;
    self.stickInputScaleStack.hidden = YES;
    [self.widgetPanelStack addArrangedSubview:self.stickInputScaleStack];

    // Curve exponent slider: 1.0 (linear) .. 2.5 (strong precision).
    self.stickResponseExponentLabel = [[UILabel alloc] init];
    self.stickResponseExponentLabel.font = labelFont;
    self.stickResponseExponentLabel.textColor = whiteColor;
    self.stickResponseExponentLabel.text = [LocalizationHelper localizedStringForKey:@"Stick Curve"];
    [self.stickResponseExponentLabel.widthAnchor constraintEqualToConstant:160].active = YES;

    self.stickResponseExponentSlider = [[UISlider alloc] init];
    self.stickResponseExponentSlider.minimumValue = 1.0;
    self.stickResponseExponentSlider.maximumValue = 2.5;
    self.stickResponseExponentSlider.value = 1.38;
    self.stickResponseExponentSlider.tintColor = sliderTint;
    [self.stickResponseExponentSlider addTarget:self action:@selector(stickResponseExponentSliderMoved:) forControlEvents:UIControlEventValueChanged];

    self.stickResponseExponentStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.stickResponseExponentLabel, self.stickResponseExponentSlider]];
    self.stickResponseExponentStack.axis = UILayoutConstraintAxisHorizontal;
    self.stickResponseExponentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stickResponseExponentStack.heightAnchor constraintEqualToConstant:20].active = YES;
    self.stickResponseExponentStack.hidden = YES;
    [self.widgetPanelStack addArrangedSubview:self.stickResponseExponentStack];

    // Vertical / horizontal output flip switches. Apply on the host-bound
    // values only; finger-space indicator visuals stay un-mirrored.
    self.stickInvertVerticalLabel = [[UILabel alloc] init];
    self.stickInvertVerticalLabel.font = labelFont;
    self.stickInvertVerticalLabel.textColor = whiteColor;
    self.stickInvertVerticalLabel.text = [LocalizationHelper localizedStringForKey:@"Vertical Flip"];
    [self.stickInvertVerticalLabel.widthAnchor constraintEqualToConstant:160].active = YES;

    self.stickInvertVerticalSwitch = [[UISwitch alloc] init];
    self.stickInvertVerticalSwitch.onTintColor = sliderTint;
    [self.stickInvertVerticalSwitch addTarget:self action:@selector(stickInvertVerticalChanged:) forControlEvents:UIControlEventValueChanged];

    self.stickInvertVerticalStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.stickInvertVerticalLabel, self.stickInvertVerticalSwitch]];
    self.stickInvertVerticalStack.axis = UILayoutConstraintAxisHorizontal;
    self.stickInvertVerticalStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stickInvertVerticalStack.alignment = UIStackViewAlignmentCenter;
    [self.stickInvertVerticalStack.heightAnchor constraintEqualToConstant:30].active = YES;
    self.stickInvertVerticalStack.hidden = YES;
    [self.widgetPanelStack addArrangedSubview:self.stickInvertVerticalStack];

    self.stickInvertHorizontalLabel = [[UILabel alloc] init];
    self.stickInvertHorizontalLabel.font = labelFont;
    self.stickInvertHorizontalLabel.textColor = whiteColor;
    self.stickInvertHorizontalLabel.text = [LocalizationHelper localizedStringForKey:@"Horizontal Flip"];
    [self.stickInvertHorizontalLabel.widthAnchor constraintEqualToConstant:160].active = YES;

    self.stickInvertHorizontalSwitch = [[UISwitch alloc] init];
    self.stickInvertHorizontalSwitch.onTintColor = sliderTint;
    [self.stickInvertHorizontalSwitch addTarget:self action:@selector(stickInvertHorizontalChanged:) forControlEvents:UIControlEventValueChanged];

    self.stickInvertHorizontalStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.stickInvertHorizontalLabel, self.stickInvertHorizontalSwitch]];
    self.stickInvertHorizontalStack.axis = UILayoutConstraintAxisHorizontal;
    self.stickInvertHorizontalStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stickInvertHorizontalStack.alignment = UIStackViewAlignmentCenter;
    [self.stickInvertHorizontalStack.heightAnchor constraintEqualToConstant:30].active = YES;
    self.stickInvertHorizontalStack.hidden = YES;
    [self.widgetPanelStack addArrangedSubview:self.stickInvertHorizontalStack];
}

- (void)stickInvertVerticalChanged:(UISwitch* )sender{
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.stickInvertVertical = sender.on;
    }
}

- (void)stickInvertHorizontalChanged:(UISwitch* )sender{
    if(self->selectedWidgetView != nil && self->widgetViewSelected){
        self->selectedWidgetView.stickInvertHorizontal = sender.on;
    }
}

- (void)showIndicatorOffset{
    selectedWidgetView.touchBeganLocation = CGPointMake(CGRectGetWidth(selectedWidgetView.frame)/2, CGRectGetHeight(selectedWidgetView.frame)/4);
    [selectedWidgetView showStickIndicator];
}


- (void)handleMissingToolBarIcon:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)subview;
            button.imageView.image = [button.imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            button.tintColor = [UIColor systemTealColor];
            if(@available(iOS 13.0, *)) nil;
            else{
                NSLog(@"missing image %d", button==_saveButton);
                button.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
                [button setImage:nil forState:UIControlStateNormal];
                if(button==_exitButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Exit"] forState:UIControlStateNormal];
                if(button==trashCanButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Del"] forState:UIControlStateNormal];
                if(button==undoButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Undo"] forState:UIControlStateNormal];
                if(button==_saveButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Save"] forState:UIControlStateNormal];
                if(button==_loadButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Load"] forState:UIControlStateNormal];
                if(button==_addButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Add"] forState:UIControlStateNormal];
                if(button==_editButton) [button setTitle:[LocalizationHelper localizedStringForKey:@"Edit"] forState:UIControlStateNormal];

            }
        }
        [self handleMissingToolBarIcon:subview];
    }
}


- (void)setupWidgetPanel{
    self.widgetPanelStack.hidden = NO;
    self.loadConfigTipLabel.hidden = NO;
    
    // 初始隐藏坐标控件
    self.coordinateControlStack.hidden = YES;

    self.widgetPanelStack.layoutMargins = UIEdgeInsetsMake(10, 10, 10, 10);
    self.widgetPanelStack.layoutMarginsRelativeArrangement = YES;
    self.widgetPanelStack.layer.cornerRadius = 16;
    self.widgetPanelStack.clipsToBounds = YES;
    
    self.widgetPanelStack.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    
    [self.currentProfileLabel setText:[LocalizationHelper localizedStringForKey:@"Profile: %@",[profilesManager getSelectedProfile].name]];
    self.currentProfileLabel.layer.cornerRadius = [self isIPhone] ? 9 : 12;
    self.currentProfileLabel.clipsToBounds = YES;
    self.currentProfileLabel.textAlignment = NSTextAlignmentCenter;

    self.widgetSizeStack.userInteractionEnabled = YES;
    for(UIView* view in _widgetPanelStack.subviews){
        view.userInteractionEnabled = YES;
        if([view isKindOfClass:[UILabel class]]){
            UILabel* label = (UILabel* )view;
            label.font = [UIFont systemFontOfSize:18];
            label.textColor = [UIColor whiteColor];
        }
    }
    
    [self.widgetSizeSlider addTarget:self action:@selector(widgetSizeSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.widgetSizeLabel.text = [LocalizationHelper localizedStringForKey:@"Size"];
    self.widgetSizeStack.hidden = YES;

    [self.widgetHeightSlider addTarget:self action:@selector(widgetHeightSliderMoved:) forControlEvents:(UIControlEventValueChanged)];

    self.widgetHeightLabel.text = [LocalizationHelper localizedStringForKey:@"Height"];
    self.widgetHeightStack.hidden = YES;

    [self.widgetAlphaSlider addTarget:self action:@selector(widgetAlphaSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.widgetAlphaLabel.text = [LocalizationHelper localizedStringForKey:@"Alpha"];
   
    [self.widgetBorderWidthSlider addTarget:self action:@selector(widgetBorderWidthSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.widgetBorderWidthLabel.text = [LocalizationHelper localizedStringForKey:@"Border Width"];
    self.borderWidthAlphaStack.hidden = YES;
  
    [self.sensitivityXSlider addTarget:self action:@selector(sensitivityXSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.sensitivityXLabel.text = [LocalizationHelper localizedStringForKey:@"SensitivityX"];
    self.sensitivityXStack.hidden = YES;
    
    [self.sensitivityYSlider addTarget:self action:@selector(sensitivityYSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.sensitivityYLabel.text = [LocalizationHelper localizedStringForKey:@"SensitivityY"];
    self.sensitivityYStack.hidden = YES;

    
    [self.decelerationRateSlider addTarget:self action:@selector(decelerationRateSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.decelerationRateLabel.text = [LocalizationHelper localizedStringForKey:@"Deceleration Rate"];
    self.decelerationRateStack.hidden = YES;

    
    // stick indicator offset slider
    //self.stickIndicatorOffsetSlider.hidden = YES;
    [self.stickIndicatorOffsetSlider addTarget:self action:@selector(stickIndicatorOffsetSliderMoved:) forControlEvents:(UIControlEventValueChanged)];
    self.stickIndicatorOffsetLabel.text = [LocalizationHelper localizedStringForKey:@"Indicator Offset"];
    self.stickIndicatorOffsetStack.hidden = YES;

    // ALT-pad response curve sliders (built programmatically, no storyboard outlets).
    // Inserted into the bottom of widgetPanelStack so they appear after the existing
    // sensitivity sliders. Visibility gated by `hasResponseCurveTweak` (set on RSPADALT/LSPADALT).
    [self installResponseCurveSliders];
    
    NSDictionary *whiteFontAttributes = @{
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };

    [self.mouseButtonDownSelector addTarget:self action:@selector(mouseDownButtonChanged:) forControlEvents:(UIControlEventValueChanged)];
    [self.mouseButtonDownSelector setTitleTextAttributes:whiteFontAttributes forState:UIControlStateNormal];
    self.mouseDownButtonStack.hidden = YES;

    [self.slidableSelector addTarget:self action:@selector(slideModeChanged:) forControlEvents:(UIControlEventValueChanged)];
    [self.slidableSelector setTitleTextAttributes:whiteFontAttributes forState:UIControlStateNormal];
    self.slidableStack.hidden = YES;

    
    if([self isIPhone]){
        [self.vibrationStyleSelector addTarget:self action:@selector(vibrationStyleChanged:) forControlEvents:(UIControlEventValueChanged)];
        self.vibrationStyleStack.hidden = YES;
        [self.vibrationStyleSelector setTitleTextAttributes:whiteFontAttributes forState:UIControlStateNormal];

    }
    
    [self.view bringSubviewToFront:self.toolbarRootView];
    [self.view insertSubview:self.widgetPanelStack belowSubview:self.toolbarRootView];
    
    // 设置坐标控件
    [self setupCoordinateControls];
    
    // 确保 stream overlay 始终在最底层
    [self ensureStreamOverlayAtBottom];
    self.widgetPanelStack.translatesAutoresizingMaskIntoConstraints = YES;
    
    
    CGRect frame = CGRectMake(0, 0, self.widgetPanelStack.frame.size.width, self.widgetPanelStack.frame.size.height);
    //frame.origin = CGPointMake(self.view.bounds.size.width/2, 100);
    frame.origin = CGPointMake(self.view.bounds.size.width/2-self.widgetPanelStack.frame.size.width/2, 100);
    self.widgetPanelStack.frame = frame;
    
    
    [self autoFitStack:self.widgetPanelStack];
    
    if([self isIPhone]) {
        for(UIView* view in _widgetPanelStack.arrangedSubviews){
            view.transform = CGAffineTransformMakeScale(0.83, 0.83);
        }
        self.widgetPanelStack.layoutMargins = UIEdgeInsetsMake(3, 2, 7, 2);
        
        self.widgetPanelStack.clipsToBounds = YES;

        CAShapeLayer *maskLayer = [CAShapeLayer layer];
        CGRect visibleRect = CGRectInset(self.widgetPanelStack.bounds, 40, 0); // 左右各裁掉
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:visibleRect cornerRadius:12];
        maskLayer.path = path.CGPath;

        self.widgetPanelStack.layer.mask = maskLayer;
        
        if (@available(iOS 13.0, *) && self.vibrationStyleSelector.numberOfSegments == 6) {
        } else {
            [self.vibrationStyleSelector removeSegmentAtIndex:3 animated:NO];
            [self.vibrationStyleSelector removeSegmentAtIndex:3 animated:NO];
        }
    }
}

- (void)applyShadowForiOS13:(UIStackView* )stack {
    stack.backgroundColor = [UIColor clearColor];
    
    for(UIView* view in stack.arrangedSubviews){
        if([view isKindOfClass:[UIStackView class]]){
            UIStackView* subStack = (UIStackView* )view;
            for(UIView* view in subStack.arrangedSubviews){
                if([view isKindOfClass:[UILabel class]]){
                    view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
                    view.layer.cornerRadius = 6;
                    view.clipsToBounds = YES;
                    UILabel* label = (UILabel* )view;
                    label.textAlignment = NSTextAlignmentCenter;
                }
                else{
                    view.tintColor= [UIColor systemTealColor];
                    view.layer.shadowColor = [[UIColor blackColor] colorWithAlphaComponent:0.9].CGColor;
                    //view.layer.shadowColor = [UIColor blackColor].CGColor;
                    view.layer.shadowOffset = CGSizeMake(1, 1);
                    view.layer.shadowOpacity = 1;
                    view.layer.shadowRadius = 5;
                }
            }
        }
        else{
            view.layer.cornerRadius = 10;
            view.clipsToBounds = YES;
            view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
        }
    }
}


- (void)updateClippedMaskForView:(UIView* )view{
    if([self isIPhone]){
        CAShapeLayer *maskLayer = [CAShapeLayer layer];
        view.layer.mask = nil;
        CGRect visibleRect = CGRectInset(view.bounds, 40, 0); // 左右各裁掉 20pt
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:visibleRect cornerRadius:12];
        maskLayer.path = path.CGPath;
        view.layer.mask = maskLayer;
    }
}

- (BOOL)isIPhone{
    return ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
}

- (void)handleProfileTablViewDismiss{
    [self profileRefresh];
    // 关闭列表后，按当前方向应用锁定
    [self osc_applyLockForCurrentOrientationAndReloadIfNeeded];
}

/* Basically the same method as loadTapped, without parameter*/
// Make sure whenever self view controller load the selected profile and layout its buttons.
- (void)profileRefresh{
    UIStoryboard *storyboard;
    BOOL isIPhone = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    if (isIPhone) {
        storyboard = [UIStoryboard storyboardWithName:@"iPhone" bundle:nil];
    }
    else {
        storyboard = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
    }
    
    // setup: current profile lable, button width slider, button height slider & button alpha slider
    [self setupWidgetPanel];
    
    //initialiaze _oscProfilesTableViewController
    self->_oscProfilesTableViewController = [storyboard instantiateViewControllerWithIdentifier:@"OSCProfilesTableViewController"];
    
    //this part is just for registration, will not be immediately executed.
    self->_oscProfilesTableViewController.needToUpdateOscLayoutTVC = ^() {   // a block that will be called when the modally presented 'OSCProfilesTableViewController' VC is dismissed. By the time the 'OSCProfilesTableViewController' VC is dismissed the user would have potentially selected a different OSC profile with a different layout and they want to see this layout on this 'LayoutOnScreenControlsViewController.' This block of code will load the profile and then hide/show and move each OSC button to their appropriate position
        NSLog(@"profile profile");
        [self reloadLegacyOnScreenControls];
        self->_oscProfilesTableViewController.currentOSCButtonLayers = self.layoutOSC.OSCButtonLayers; //pass updated OSCLayout to OSCProfileTableView again
    };
    
    [self.oscProfilesTableViewController profileViewRefresh]; // execute this will make sure OSCLayout is updated from persisted profile, not any cache.
    [self reloadOnScreenWidgetViews];

    // [self presentViewController:vc animated:YES completion:nil];
}

- (void) presentProfilesTableView{
    [self saveTapped:nil];
    [self hideStickIndicators];
    selectedWidgetView = nil;
    UIStoryboard *storyboard;
    BOOL isIPhone = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    if (isIPhone) {
        storyboard = [UIStoryboard storyboardWithName:@"iPhone" bundle:nil];
    }
    else {
        storyboard = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
    }
    
    _oscProfilesTableViewController = [storyboard instantiateViewControllerWithIdentifier:@"OSCProfilesTableViewController"];
    _oscProfilesTableViewController.layoutViewBounds = self.view.bounds;
    
    _oscProfilesTableViewController.needToUpdateOscLayoutTVC = ^() {   // a block that will be called when the modally presented 'OSCProfilesTableViewController' VC is dismissed. By the time the 'OSCProfilesTableViewController' VC is dismissed the user would have potentially selected a different OSC ofile with a different layout and they want to see this layout on this 'LayoutOnScreenControlsViewController.' This block of code will load the proffile and then hide/show and move each OSC button to their appropriate position
        [self reloadLegacyOnScreenControls];
    };

    self.widgetPanelStack.hidden = YES;
    
    _oscProfilesTableViewController.currentOSCButtonLayers = self.layoutOSC.OSCButtonLayers;
    
    // _oscProfilesTableViewController.modalPresentationStyle = UIModalPresentationCurrentContext;
    _oscProfilesTableViewController.modalPresentationStyle = UIModalPresentationOverCurrentContext;

    // 添加半透明黑色 overlay 到当前控制器视图之上
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
    overlay.tag = 987654; // 识别用
    [self.view addSubview:overlay];
    [self.view bringSubviewToFront:overlay];

    // 点击 overlay 关闭弹窗
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissProfilesByOverlayTap)];
    [overlay addGestureRecognizer:tap];

    // 监听移除 overlay 的通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeProfilesOverlay) name:@"OSCProfilesOverlayRemove" object:nil];

    [self presentViewController:_oscProfilesTableViewController animated:YES completion:^{
        // 确保 overlay 仍在最上面可点击
        UIView *ov = [self.view viewWithTag:987654];
        if (ov) [self.view bringSubviewToFront:ov];
    }];
}

/* Presents the view controller that lists all OSC profiles the user can choose from */
- (IBAction) loadTapped:(id)sender {
    [self presentProfilesTableView];
}


#pragma mark - Touch

- (void)updateGuidelinesForOnScreenWidget:(id)sender{
    OnScreenWidgetView* widget = (OnScreenWidgetView* )sender;
    [self.layoutOSC updateGuidelinesForOnScreenWidget:widget];
    [self.view bringSubviewToFront:widget];
    
    // 确保 stream overlay 始终在最底层
    [self ensureStreamOverlayAtBottom];
    
    trashCanButton.tintColor = trashCanButton.titleLabel.textColor = [self layerIsOverlappingWithTrashcanButton:widget.layer] ? [UIColor redColor] : trashCanStoryBoardColor;

    self.undoButton.alpha = 1.0;
}

- (BOOL) widgetPanelTouched:(UITouch *)touch{
    CGPoint touchPoint = [touch locationInView:_widgetPanelStack];
    UIView *touchedView = [_widgetPanelStack hitTest:touchPoint withEvent:nil];
    return touchedView != nil;
}

- (void) handleWidgetPanelMove:(UITouch *)touch{
    if(!widgetPanelMovedByTouch) return;
    CGPoint currentLocation = [touch locationInView:self.view];
    CGFloat offsetX = currentLocation.x - latestTouchLocation.x;
    CGFloat offsetY = currentLocation.y - latestTouchLocation.y;
    _widgetPanelStack.center = CGPointMake(_widgetPanelStack.center.x+offsetX, _widgetPanelStack.center.y+offsetY);
    latestTouchLocation = currentLocation;
    widgetPanelStoredCenter = _widgetPanelStack.center;
}

// A touch can reach this view controller's touch handlers through the responder
// chain even when it actually landed on an OnScreenWidgetView — every widget calls
// super.touchesBegan/Moved, which propagates the event up to here. In that case the
// user is dragging that widget (the widget moves itself), so we must NOT also feed
// the touch to layoutOSC, or a legacy OSC layer (dpad / select / stick …) gets
// grabbed as layerBeingDragged and dragged to the finger. Walk up from the hit-test
// view so a touch on a widget's non-interactive label subview still counts.
- (BOOL)osc_touchLandedOnWidget:(UITouch *)touch {
    for (UIView *v = touch.view; v != nil; v = v.superview) {
        if ([v isKindOfClass:[OnScreenWidgetView class]]) return YES;
    }
    return NO;
}

- (void) touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {

    UITouch* touch = touches.anyObject;
    widgetPanelMovedByTouch = [self widgetPanelTouched:touch];
    if(widgetPanelMovedByTouch){
        latestTouchLocation = [touch locationInView:self.view];
    }

    for (UITouch* touch in touches) {
        
        CGPoint touchLocation = [touch locationInView:self.view];
        touchLocation = [[touch view] convertPoint:touchLocation toView:nil];
        CALayer *layer = [self.view.layer hitTest:touchLocation];
        
        // 检查是否点击了toolbar相关的控件
        BOOL isToolbarTouched = (layer == self.toolbarRootView.layer ||
                                layer == self.chevronView.layer ||
                                layer == self.chevronImageView.layer ||
                                layer == self.toolbarStackView.layer ||
                                layer == self.view.layer);
        
        // 如果点击了toolbar，直接返回
        if (isToolbarTouched) {
            return;
        }
        
        // 检查是否点击了widgetPanelStack
        BOOL isWidgetPanelTouched = [self widgetPanelTouched:touch];
        if (isWidgetPanelTouched) {
            // 如果点击了widgetPanelStack，不传递给layoutOSC
            return;
        }

        // Touch landed on a widget → it handles its own drag; don't let layoutOSC
        // grab a legacy OSC layer for it (see osc_touchLandedOnWidget:).
        if ([self osc_touchLandedOnWidget:touch]) {
            return;
        }
    }
    [self.layoutOSC touchesBegan:touches withEvent:event];
}

- (void) touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {

    [self handleWidgetPanelMove:touches.anyObject];

    // Touch landed on a widget → it moves itself; don't drag a legacy OSC layer
    // along with it (see osc_touchLandedOnWidget:). Without this, the bottom-left
    // dpad/select layer can flash to the finger and follow it during a widget drag.
    if ([self osc_touchLandedOnWidget:touches.anyObject]) {
        return;
    }

    // -------- for OSC buttons
    [self.layoutOSC touchesMoved:touches withEvent:event];
    
    trashCanButton.tintColor = trashCanButton.titleLabel.textColor = [self layerIsOverlappingWithTrashcanButton:self.layoutOSC.layerBeingDragged] ? [UIColor redColor] : trashCanStoryBoardColor;
}

- (bool)touchWithinTashcanButton:(UITouch* )touch {
    CGPoint locationInView = [touch locationInView:self.view];
    
    // Convert the location to the button's coordinate system
    CGPoint locationInButton = [self.view convertPoint:locationInView toView:trashCanButton];
    bool ret = CGRectContainsPoint(trashCanButton.bounds, locationInButton);
    // NSLog(@"within button: %d", ret);
    // Check if the location is within the button's bounds
    return ret;
}

- (bool)layerIsOverlappingWithTrashcanButton:(CALayer* )layer{
    CALayer *commonLayer = self.view.layer; // 假设它们在同一个 superview 下

    CGRect rect1 = [layer convertRect:layer.bounds toLayer:commonLayer];
    CGRect rect2 = [trashCanButton.layer convertRect:trashCanButton.layer.bounds toLayer:commonLayer];
    return CGRectIntersectsRect(rect1, rect2);
}


- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    
    // removing keyboard buttons objs
    // UITouch *touch = [touches anyObject]; // Get the first touch in the set
    _widgetPanelStack.userInteractionEnabled = true;
    
    // Re-anchor the just-released widget back into its z-order band. During a
    // drag, updateGuidelinesForOnScreenWidget: bringSubviewToFront's the widget
    // so the user can see what they're moving; this restores the per-type
    // contract: fullscreenTrigger above streamOverlay, touchPad just below the
    // lowest button (top of the pad layer), button just below the widget panel
    // (top of the button layer). insertWidgetInEditorZOrder: encapsulates all
    // three cases.
    if(selectedWidgetView){
        [self insertWidgetInEditorZOrder:selectedWidgetView];
    }

    if(!isToolbarHidden
       && self->selectedWidgetView != nil
       && [self layerIsOverlappingWithTrashcanButton:selectedWidgetView.layer]){
        [self->selectedWidgetView removeFromSuperview];
        [self.onScreenWidgetViews removeObject:self->selectedWidgetView];
        [self hideStickIndicators];
        [selectedWidgetView.buttonDownVisualEffectLayer removeFromSuperlayer];
        // Clear selection state so the inspector / undo flow doesn't keep a dangling pointer
        // to the just-deleted widget.
        self->selectedWidgetView = nil;
        self->widgetViewSelected = false;
    }
    
    
    //removing OSC buttons
    if (!isToolbarHidden && self.layoutOSC.layerBeingDragged != nil &&
        [self layerIsOverlappingWithTrashcanButton:self.layoutOSC.layerBeingDragged]) { // check if user wants to throw OSC button into the trash can
        // here we're going to delete something
        
        self.layoutOSC.layerBeingDragged.hidden = YES;
        
        if ([self.layoutOSC.layerBeingDragged.name isEqualToString:@"dPad"]) { // if user is hiding dPad, then hide all four dPad button child layers as well since setting the 'hidden' property on the parent dPad CALayer doesn't automatically hide the four child CALayer dPad buttons
            self.layoutOSC._upButton.hidden = YES;
            self.layoutOSC._rightButton.hidden = YES;
            self.layoutOSC._downButton.hidden = YES;
            self.layoutOSC._leftButton.hidden = YES;
        }
        
        /* if user is hiding left or right analog sticks, then hide their corresponding inner analog stick child layers as well since setting the 'hidden' property on the parent analog stick doesn't automatically hide its child inner analog stick CALayer */
        if ([self.layoutOSC.layerBeingDragged.name isEqualToString:@"leftStickBackground"]) {
            self.layoutOSC._leftStick.hidden = YES;
        }
        if ([self.layoutOSC.layerBeingDragged.name isEqualToString:@"rightStickBackground"]) {
            self.layoutOSC._rightStick.hidden = YES;
        }
    }
    [self.layoutOSC touchesEnded:touches withEvent:event];
    
    // 检查模板布局是否被修改，弹出提示
    OSCProfile *currentProfile = [profilesManager getSelectedProfile];
    if(currentProfile && [profilesManager isTemplateProfile:currentProfile.name] && [self.layoutOSC.layoutChanges count] > 0){
        NSString *message = [NSString stringWithFormat:@"模板布局'%@'不可被修改", currentProfile.name];
        UIAlertController * movedAlertController = [UIAlertController alertControllerWithTitle: [NSString stringWithFormat:@""] message: message preferredStyle:UIAlertControllerStyleAlert];
        [movedAlertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.oscProfilesTableViewController profileViewRefresh];
        }]];
        [self presentViewController:movedAlertController animated:YES completion:nil];
    }
    
    
    trashCanButton.tintColor = trashCanButton.titleLabel.textColor = trashCanStoryBoardColor;
    widgetPanelMovedByTouch = false;
}

// 点击 overlay 收起配置列表
- (void)dismissProfilesByOverlayTap{
    if (self->_oscProfilesTableViewController) {
        [self->_oscProfilesTableViewController dismissViewControllerAnimated:YES completion:^{
            [self removeProfilesOverlay];
        }];
    }
    else {
        [self removeProfilesOverlay];
    }
}

- (void)removeProfilesOverlay{
    UIView *overlay = [self.view viewWithTag:987654];
    if (overlay) {
        [overlay removeFromSuperview];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OSCProfilesOverlayRemove" object:nil];
    
    // 确保 stream overlay 始终在最底层
    [self ensureStreamOverlayAtBottom];
}

#pragma mark - Stream Overlay

- (void)setupStreamOverlay {
    // 创建白色半透明 overlay
    self.streamOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.streamOverlay.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.3];
    self.streamOverlay.userInteractionEnabled = NO; // 不拦截触摸事件
    self.streamOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.streamOverlay.tag = 999999; // 使用特殊标签标识我们的 overlay
    
    // 将 overlay 添加到视图的最底层（在串流画面之上，但在所有控件之下）
    [self.view insertSubview:self.streamOverlay atIndex:0];
    
    NSLog(@"✅ Stream overlay 已创建并添加到视图层次结构");
}

- (void)ensureStreamOverlayAtBottom {
    // 确保 stream overlay 始终在最底层
    if (self.streamOverlay && self.streamOverlay.superview) {
        [self.view sendSubviewToBack:self.streamOverlay];
    }
}

#pragma mark - Coordinate Controls

- (void)setupCoordinateControls {
    // 设置坐标控件的初始状态
    self.coordinateControlStack.hidden = YES;
    
    // 设置坐标标签的样式
    self.coordinateLabel.font = [UIFont systemFontOfSize:17];
    self.coordinateLabel.textColor = [UIColor whiteColor];
    self.coordinateLabel.text = @"坐标：[0], [0]";
    
    // 设置方向按钮的样式
    [self.moveUpButton setTintColor:[UIColor systemTealColor]];
    [self.moveDownButton setTintColor:[UIColor systemTealColor]];
    [self.moveLeftButton setTintColor:[UIColor systemTealColor]];
    [self.moveRightButton setTintColor:[UIColor systemTealColor]];
    
    // 设置按钮背景和圆角
    [self.moveUpButton setBackgroundColor:[UIColor whiteColor]];
    [self.moveDownButton setBackgroundColor:[UIColor whiteColor]];
    [self.moveLeftButton setBackgroundColor:[UIColor whiteColor]];
    [self.moveRightButton setBackgroundColor:[UIColor whiteColor]];
    
    // 设置圆角
    self.moveUpButton.layer.cornerRadius = 6.0;
    self.moveDownButton.layer.cornerRadius = 6.0;
    self.moveLeftButton.layer.cornerRadius = 6.0;
    self.moveRightButton.layer.cornerRadius = 6.0;
    
    // 设置按钮的图片大小（12pt）
    UIImage *upImage = [UIImage systemImageNamed:@"arrowtriangle.up.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]];
    UIImage *downImage = [UIImage systemImageNamed:@"arrowtriangle.down.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]];
    UIImage *leftImage = [UIImage systemImageNamed:@"arrowtriangle.left.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]];
    UIImage *rightImage = [UIImage systemImageNamed:@"arrowtriangle.right.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]];
    
    [self.moveUpButton setImage:upImage forState:UIControlStateNormal];
    [self.moveDownButton setImage:downImage forState:UIControlStateNormal];
    [self.moveLeftButton setImage:leftImage forState:UIControlStateNormal];
    [self.moveRightButton setImage:rightImage forState:UIControlStateNormal];
}

- (void)updateCoordinateDisplay {
    if (self->selectedWidgetView != nil && self->widgetViewSelected) {
        if (self->selectedWidgetView.widgetType == WidgetTypeEnumFullscreenTrigger) {
            // Pinned widget: no coordinate readout, no nudge buttons.
            self.coordinateControlStack.hidden = YES;
            return;
        }
        // 显示WidgetView的坐标
        CGPoint center = self->selectedWidgetView.center;
        self.coordinateLabel.text = [NSString stringWithFormat:@"坐标：[%.0f], [%.0f]", center.x, center.y];
        self.coordinateControlStack.hidden = NO;
    } else if (self->selectedControllerLayer != nil && self->controllerLayerSelected) {
        // 显示Legacy OSC按钮的坐标
        CGPoint position = self->selectedControllerLayer.position;
        self.coordinateLabel.text = [NSString stringWithFormat:@"坐标：[%.0f], [%.0f]", position.x, position.y];
        self.coordinateControlStack.hidden = NO;
    } else {
        // 没有选中任何控件时隐藏坐标控件
        self.coordinateControlStack.hidden = YES;
    }
}

- (void)moveSelectedControlByOffset:(CGPoint)offset {
    if (self->selectedWidgetView != nil && self->widgetViewSelected) {
        if (self->selectedWidgetView.widgetType == WidgetTypeEnumFullscreenTrigger) {
            return; // pinned widget — direction-pad nudges must not relocate it
        }
        // 移动WidgetView
        CGPoint newCenter = CGPointMake(self->selectedWidgetView.center.x + offset.x,
                                       self->selectedWidgetView.center.y + offset.y);
        self->selectedWidgetView.center = newCenter;
        [self updateCoordinateDisplay];
    } else if (self->selectedControllerLayer != nil && self->controllerLayerSelected) {
        // 移动Legacy OSC按钮
        CGPoint newPosition = CGPointMake(self->selectedControllerLayer.position.x + offset.x, 
                                         self->selectedControllerLayer.position.y + offset.y);
        self->selectedControllerLayer.position = newPosition;
        [self updateCoordinateDisplay];
    }
}

- (IBAction)moveUpButtonTapped:(id)sender {
    [self moveSelectedControlByOffset:CGPointMake(0, -1)];
}

- (IBAction)moveDownButtonTapped:(id)sender {
    [self moveSelectedControlByOffset:CGPointMake(0, 1)];
}

- (IBAction)moveLeftButtonTapped:(id)sender {
    [self moveSelectedControlByOffset:CGPointMake(-1, 0)];
}

- (IBAction)moveRightButtonTapped:(id)sender {
    [self moveSelectedControlByOffset:CGPointMake(1, 0)];
}

@end
