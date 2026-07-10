//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.16
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "ControllerSupport.h"
#import "VoidController.h"

NSString* const VoidGyroSettingsDidChangeNotification = @"VoidGyroSettingsDidChangeNotification";

#import "OnScreenControls.h"

#import "DataManager.h"
#import "VoidLink-Swift.h"
#include "Limelight.h"

@import GameController;
#if !TARGET_OS_TV
    @import CoreMotion;
#endif
@import AudioToolbox;

static const double MOUSE_SPEED_DIVISOR = 1.25;
static NSString * const PhysicalControllerComboDefaultsKey = @"physicalControllerComboMappingsV1";
static NSString * const PhysicalControllerComboDidChangeNotification = @"PhysicalControllerComboMappingsDidChangeNotification";
static const float PHYSICAL_COMBO_TRIGGER_PRESS_THRESHOLD = 0.55f;
static const float PHYSICAL_COMBO_TRIGGER_RELEASE_THRESHOLD = 0.25f;
// How long a '*' tap target stays down before it auto-releases (vs. a normal target,
// which is held until the physical source is released).
static const uint32_t PHYSICAL_COMBO_TAP_HOLD_MS = 50;

@interface ControllerSupport()

@property (assign,nonatomic) bool shallDisableGyroHotSwitch;
@property (atomic, assign) BOOL forceGyroOverrideSet;

- (void)clearGyroOutputForAllControllers;

@end


@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
    id _gyroSettingsObserver;
    id _physicalControllerComboSettingsObserver;

    NSLock *_controllerStreamLock;
    NSMutableDictionary *_voidControllers;
    NSMutableDictionary<NSString*, NSDictionary*> *_physicalControllerComboCommandsBySource;
    id<ControllerSupportDelegate> _delegate;
    StreamConfiguration* _streamConfig;
    
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollX;
    float accumulatedScrollY;
    
    OnScreenControls *_osc;
    VoidController *_oscController;
    NSMutableSet* _activeGCControllers;
    
#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;
    // Invalidates pending delayed gamepad-reattach blocks when the session they
    // were scheduled for ends (cleanup) or is replaced (updateControllerSupport),
    // so they can't fire packets into a torn-down or brand-new connection.
    NSUInteger _reattachEpoch;
    bool _swapABButtons;
    bool _swapXYButtons;
    int _gyroMode;
    int _mapGyroTo;          // MapGyroTo enum, see DataManager.h
    BOOL _gyroInvertPitch;   // flip Y axis output (vertical flip)
    BOOL _gyroInvertYaw;     // flip X axis output (horizontal flip)
    CGFloat _gyroSensitivity;
    bool _captureMouse;

    // Motion-button gating: counts of currently-held GYRO and GYROPAUSE buttons.
    // Mutated from the main thread (touch handlers); read from background timer
    // closures. NSTimer block reads are best-effort — a missed sample is fine.
    int _motionButtonHoldCount;
    int _motionButtonPauseCount;
}

// Conversion factor: rotation rate (deg/s) → stick value (-32766..+32766).
// Tuned so 120°/s yields full deflection at gyroSensitivity=1.0 — moderate
// head turn maxes out, gentle aim adjustments produce ~10-20% stick which
// feels responsive without being twitchy. User can tune via gyroSensitivity.
static const CGFloat GYRO_TO_STICK_DPS_PER_FULL = 120.0f;
static const CGFloat GYRO_TO_STICK_SCALE = 32766.0f / GYRO_TO_STICK_DPS_PER_FULL;
// Mouse mode: deg/s → pixels-per-tick. Calibrated so a slow head turn drives
// the cursor at a comfortable rate; user tunes via gyroSensitivity.
static const CGFloat GYRO_TO_MOUSE_SCALE = 0.18f;

// Clamp helper to int16_t range expected by Limelight stick events.
static inline int16_t clamp_int16(CGFloat v) {
    if (v > 32766) return 32766;
    if (v < -32766) return -32766;
    return (int16_t)v;
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

#define MAX_MAGNITUDE(x, y) (abs(x) > abs(y) ? (x) : (y))

// MARK: - Motion-button gating

// YES when motion events should be emitted right now. Decision order:
//   1. GYROPAUSE always wins (emergency suspend, even over forceGyroEnabled)
//   2. Explicit stream-view GYRO ON forces emission past the hold gate
//   3. GYRO widgets registered -> at least one must be held
//   4. Explicit stream-view GYRO OFF suppresses passive legacy emission
//   5. No motion widgets or explicit switch -> legacy always-on
// Read under the same lock as push/pop to avoid races between the gyro timer
// (background thread, ~60Hz reads) and touch handlers (main thread).
- (BOOL) motionEmissionAllowed {
    BOOL hasToggle = self.hasGyroToggleButton;
    BOOL hasPause  = self.hasGyroPauseButton;
    BOOL hasGlobalOverride = self.forceGyroOverrideSet;
    BOOL globalForce = self.forceGyroEnabled;
    @synchronized (self) {
        if (hasPause && _motionButtonPauseCount > 0) return NO;
        if (hasGlobalOverride && globalForce) return YES;
        if (hasToggle) return _motionButtonHoldCount > 0;
        if (hasGlobalOverride) return NO;
        return YES;
    }
}

- (void) pushMotionButtonHold {
    @synchronized (self) { _motionButtonHoldCount++; }
}

- (void) popMotionButtonHold {
    @synchronized (self) {
        if (_motionButtonHoldCount > 0) _motionButtonHoldCount--;
    }
}

- (void) pushMotionButtonPause {
    @synchronized (self) { _motionButtonPauseCount++; }
}

- (void) popMotionButtonPause {
    @synchronized (self) {
        if (_motionButtonPauseCount > 0) _motionButtonPauseCount--;
    }
}

- (void) resetMotionButtonHolds {
    @synchronized (self) {
        _motionButtonHoldCount = 0;
        _motionButtonPauseCount = 0;
    }
}

- (void) clearMotionControlButtonRegistration {
    self.hasGyroToggleButton = NO;
    self.hasGyroPauseButton = NO;
    [self resetMotionButtonHolds];
}

// MARK: - Physical controller combo mapping

- (void)ensurePhysicalControllerComboStateForController:(VoidController *)controller {
    if (!controller) return;
    @synchronized(controller) {
        if (!controller.comboSourcePressedStates) controller.comboSourcePressedStates = [[NSMutableDictionary alloc] init];
        if (!controller.comboSourceGenerations) controller.comboSourceGenerations = [[NSMutableDictionary alloc] init];
        if (!controller.comboActiveTargetsBySource) controller.comboActiveTargetsBySource = [[NSMutableDictionary alloc] init];
        if (!controller.comboTargetHoldCounts) controller.comboTargetHoldCounts = [[NSMutableDictionary alloc] init];
    }
}

- (void)reloadPhysicalControllerComboMappings {
    NSArray *storedMappings = [[NSUserDefaults standardUserDefaults] arrayForKey:PhysicalControllerComboDefaultsKey];
    NSMutableDictionary<NSString*, NSDictionary*> *commandsBySource = [[NSMutableDictionary alloc] init];

    for (id item in storedMappings) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *mapping = (NSDictionary *)item;
        id enabledValue = mapping[@"enabled"];
        if (enabledValue != nil && ![enabledValue boolValue]) continue;

        NSString *source = [CommandManager normalizedPhysicalControllerComboSource:mapping[@"source"]];
        NSString *command = [mapping[@"command"] isKindOfClass:[NSString class]] ? mapping[@"command"] : nil;
        NSArray<NSString *> *tokens = command.length > 0 ? [CommandManager extractPhysicalControllerComboTokensFrom:command] : nil;
        if (source.length == 0 || tokens.count == 0) continue;

        NSMutableArray<NSString *> *targets = [tokens mutableCopy];
        uint32_t delayMs = 0;
        NSString *last = targets.lastObject;
        if ([last hasSuffix:@"MS"]) {
            NSString *delayText = [last substringToIndex:last.length - 2];
            delayMs = (uint32_t)delayText.integerValue;
            [targets removeLastObject];
        }
        if (targets.count == 0) continue;

        commandsBySource[source] = @{
            @"targets": [targets copy],
            @"delayMs": @(delayMs)
        };
    }

    @synchronized(self) {
        _physicalControllerComboCommandsBySource = commandsBySource;
    }
}

- (NSDictionary *)physicalControllerComboCommandForSource:(NSString *)source {
    if (source.length == 0) return nil;
    @synchronized(self) {
        return _physicalControllerComboCommandsBySource[source];
    }
}

- (BOOL)physicalControllerComboHasMappingForSource:(NSString *)source {
    return [self physicalControllerComboCommandForSource:source] != nil;
}

- (NSInteger)nextPhysicalControllerComboGenerationForSource:(NSString *)source controller:(VoidController *)controller {
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        NSInteger generation = [controller.comboSourceGenerations[source] integerValue] + 1;
        controller.comboSourceGenerations[source] = @(generation);
        return generation;
    }
}

// A '*' tap marker can ride on a target string (e.g. "OSCA*" = press then auto-release);
// strip it for flag / trigger lookups so the target still resolves to its button.
- (NSString *)physicalControllerComboStrippedTarget:(NSString *)target {
    return [target hasSuffix:@"*"] ? [target substringToIndex:target.length - 1] : target;
}

- (int)physicalControllerComboButtonFlagForTarget:(NSString *)target {
    target = [self physicalControllerComboStrippedTarget:target];
    if ([target isEqualToString:@"OSCA"]) return A_FLAG;
    if ([target isEqualToString:@"OSCB"]) return B_FLAG;
    if ([target isEqualToString:@"OSCX"]) return X_FLAG;
    if ([target isEqualToString:@"OSCY"]) return Y_FLAG;
    if ([target isEqualToString:@"OSCL1"]) return LB_FLAG;
    if ([target isEqualToString:@"OSCR1"]) return RB_FLAG;
    if ([target isEqualToString:@"OSCL3"]) return LS_CLK_FLAG;
    if ([target isEqualToString:@"OSCR3"]) return RS_CLK_FLAG;
    if ([target isEqualToString:@"OSCSTART"]) return PLAY_FLAG;
    if ([target isEqualToString:@"OSCSELECT"]) return BACK_FLAG;
    if ([target isEqualToString:@"OSCUP"]) return UP_FLAG;
    if ([target isEqualToString:@"OSCDOWN"]) return DOWN_FLAG;
    if ([target isEqualToString:@"OSCLEFT"]) return LEFT_FLAG;
    if ([target isEqualToString:@"OSCRIGHT"]) return RIGHT_FLAG;
    if ([target isEqualToString:@"DS4TCHBTN"]) return TOUCHPAD_FLAG;
    if ([target isEqualToString:@"PADDLE1"]) return PADDLE1_FLAG;
    if ([target isEqualToString:@"PADDLE2"]) return PADDLE2_FLAG;
    if ([target isEqualToString:@"PADDLE3"]) return PADDLE3_FLAG;
    if ([target isEqualToString:@"PADDLE4"]) return PADDLE4_FLAG;
    if ([target isEqualToString:@"MISC"]) return MISC_FLAG;
    return 0;
}

- (BOOL)physicalControllerComboIsLeftTriggerTarget:(NSString *)target {
    return [[self physicalControllerComboStrippedTarget:target] isEqualToString:@"OSCL2"];
}

- (BOOL)physicalControllerComboIsRightTriggerTarget:(NSString *)target {
    return [[self physicalControllerComboStrippedTarget:target] isEqualToString:@"OSCR2"];
}

- (uint32_t)physicalControllerComboSupportedButtonFlags {
    uint32_t flags = 0;
    @synchronized(self) {
        for (NSDictionary *command in _physicalControllerComboCommandsBySource.allValues) {
            NSArray<NSString *> *targets = command[@"targets"];
            for (NSString *target in targets) {
                flags |= [self physicalControllerComboButtonFlagForTarget:target];
            }
        }
    }
    return flags;
}

- (void)physicalControllerComboReleaseTarget:(NSString *)target controller:(VoidController *)controller {
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        NSInteger count = [controller.comboTargetHoldCounts[target] integerValue];
        if (count <= 1) {
            [controller.comboTargetHoldCounts removeObjectForKey:target];
            int flag = [self physicalControllerComboButtonFlagForTarget:target];
            if (flag != 0) {
                controller.comboButtonFlags &= ~flag;
            } else if ([self physicalControllerComboIsLeftTriggerTarget:target]) {
                controller.comboLeftTrigger = 0;
            } else if ([self physicalControllerComboIsRightTriggerTarget:target]) {
                controller.comboRightTrigger = 0;
            }
        } else {
            controller.comboTargetHoldCounts[target] = @(count - 1);
        }
    }
    [self updateFinished:controller];
}

- (BOOL)physicalControllerComboPressTarget:(NSString *)target source:(NSString *)source generation:(NSInteger)generation controller:(VoidController *)controller {
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        BOOL sourceStillPressed = [controller.comboSourcePressedStates[source] boolValue];
        NSInteger currentGeneration = [controller.comboSourceGenerations[source] integerValue];
        if (!sourceStillPressed || currentGeneration != generation) {
            return NO;
        }

        NSMutableArray<NSString *> *activeTargets = controller.comboActiveTargetsBySource[source];
        if (!activeTargets) {
            activeTargets = [[NSMutableArray alloc] init];
            controller.comboActiveTargetsBySource[source] = activeTargets;
        }
        [activeTargets addObject:target];

        NSInteger count = [controller.comboTargetHoldCounts[target] integerValue] + 1;
        controller.comboTargetHoldCounts[target] = @(count);

        int flag = [self physicalControllerComboButtonFlagForTarget:target];
        if (flag != 0) {
            controller.comboButtonFlags |= flag;
        } else if ([self physicalControllerComboIsLeftTriggerTarget:target]) {
            controller.comboLeftTrigger = 0xFF;
        } else if ([self physicalControllerComboIsRightTriggerTarget:target]) {
            controller.comboRightTrigger = 0xFF;
        }
    }
    // '*' tap target: auto-release shortly after pressing, rather than holding it until
    // the physical source is released.
    if ([target hasSuffix:@"*"]) {
        [self schedulePhysicalControllerComboTapReleaseForTarget:target source:source generation:generation controller:controller];
    }
    [self updateFinished:controller];
    return YES;
}

- (BOOL)physicalControllerComboPressTargets:(NSArray<NSString *> *)targets source:(NSString *)source generation:(NSInteger)generation controller:(VoidController *)controller {
    if (targets.count == 0) return NO;
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        BOOL sourceStillPressed = [controller.comboSourcePressedStates[source] boolValue];
        NSInteger currentGeneration = [controller.comboSourceGenerations[source] integerValue];
        if (!sourceStillPressed || currentGeneration != generation) {
            return NO;
        }

        NSMutableArray<NSString *> *activeTargets = controller.comboActiveTargetsBySource[source];
        if (!activeTargets) {
            activeTargets = [[NSMutableArray alloc] init];
            controller.comboActiveTargetsBySource[source] = activeTargets;
        }

        for (NSString *target in targets) {
            [activeTargets addObject:target];

            NSInteger count = [controller.comboTargetHoldCounts[target] integerValue] + 1;
            controller.comboTargetHoldCounts[target] = @(count);

            int flag = [self physicalControllerComboButtonFlagForTarget:target];
            if (flag != 0) {
                controller.comboButtonFlags |= flag;
            } else if ([self physicalControllerComboIsLeftTriggerTarget:target]) {
                controller.comboLeftTrigger = 0xFF;
            } else if ([self physicalControllerComboIsRightTriggerTarget:target]) {
                controller.comboRightTrigger = 0xFF;
            }
        }
    }
    // '*' tap targets in the batch: auto-release each shortly after pressing.
    for (NSString *target in targets) {
        if ([target hasSuffix:@"*"]) {
            [self schedulePhysicalControllerComboTapReleaseForTarget:target source:source generation:generation controller:controller];
        }
    }
    [self updateFinished:controller];
    return YES;
}

// Releases a '*' tap target a short time after it was pressed (vs. holding to source release).
// The hold-count machinery makes the eventual source-release of the same target a harmless
// no-op (count already at 0), so taps never leak a stuck button.
- (void)schedulePhysicalControllerComboTapReleaseForTarget:(NSString *)target source:(NSString *)source generation:(NSInteger)generation controller:(VoidController *)controller {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)PHYSICAL_COMBO_TAP_HOLD_MS * NSEC_PER_MSEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Skip if a newer source press/release has superseded this one (generation bumps on
        // every source state change). Otherwise a fast re-press within the tap window would
        // have its hold cut short by the previous press's timer; the superseding event does
        // its own release (source-release frees all active targets anyway).
        @synchronized(controller) {
            if ([controller.comboSourceGenerations[source] integerValue] != generation) return;
        }
        [strongSelf physicalControllerComboReleaseTarget:target controller:controller];
    });
}

- (void)schedulePhysicalControllerComboTargets:(NSArray<NSString *> *)targets
                                        source:(NSString *)source
                                    generation:(NSInteger)generation
                                       delayMs:(uint32_t)delayMs
                                         index:(NSUInteger)index
                                    controller:(VoidController *)controller {
    if (index >= targets.count) return;
    if (delayMs == 0) {
        [self physicalControllerComboPressTargets:targets source:source generation:generation controller:controller];
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^pressStep)(void) = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL didPress = [strongSelf physicalControllerComboPressTarget:targets[index]
                                                                source:source
                                                            generation:generation
                                                            controller:controller];
        if (!didPress) return;
        [strongSelf schedulePhysicalControllerComboTargets:targets
                                                    source:source
                                                generation:generation
                                                   delayMs:delayMs
                                                     index:index + 1
                                                controller:controller];
    };

    if (index == 0 || delayMs == 0) {
        pressStep();
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMs * NSEC_PER_MSEC),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                       pressStep);
    }
}

- (void)physicalControllerComboReleaseSource:(NSString *)source controller:(VoidController *)controller {
    NSArray<NSString *> *targetsToRelease;
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        targetsToRelease = [controller.comboActiveTargetsBySource[source] copy];
        [controller.comboActiveTargetsBySource removeObjectForKey:source];
    }

    for (NSString *target in [targetsToRelease reverseObjectEnumerator]) {
        [self physicalControllerComboReleaseTarget:target controller:controller];
    }
}

- (BOOL)handlePhysicalControllerComboSource:(NSString *)source pressed:(BOOL)pressed controller:(VoidController *)controller {
    NSDictionary *command = [self physicalControllerComboCommandForSource:source];
    if (!command || !controller) return NO;

    [self ensurePhysicalControllerComboStateForController:controller];
    BOOL previousPressed;
    @synchronized(controller) {
        previousPressed = [controller.comboSourcePressedStates[source] boolValue];
        if (previousPressed == pressed) {
            return YES;
        }
        controller.comboSourcePressedStates[source] = @(pressed);
    }

    NSInteger generation = [self nextPhysicalControllerComboGenerationForSource:source controller:controller];
    if (pressed) {
        NSArray<NSString *> *targets = command[@"targets"];
        uint32_t delayMs = (uint32_t)[command[@"delayMs"] unsignedIntegerValue];
        @synchronized(controller) {
            controller.comboActiveTargetsBySource[source] = [[NSMutableArray alloc] init];
        }
        [self schedulePhysicalControllerComboTargets:targets
                                              source:source
                                          generation:generation
                                             delayMs:delayMs
                                               index:0
                                          controller:controller];
    } else {
        [self physicalControllerComboReleaseSource:source controller:controller];
    }

    return YES;
}

- (BOOL)physicalControllerComboTriggerPressedForSource:(NSString *)source value:(float)value controller:(VoidController *)controller {
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        BOOL previousPressed = [controller.comboSourcePressedStates[source] boolValue];
        if (previousPressed) {
            return value > PHYSICAL_COMBO_TRIGGER_RELEASE_THRESHOLD;
        }
        return value > PHYSICAL_COMBO_TRIGGER_PRESS_THRESHOLD;
    }
}

- (void)clearPhysicalControllerCombosForController:(VoidController *)controller {
    if (!controller) return;
    [self ensurePhysicalControllerComboStateForController:controller];
    @synchronized(controller) {
        for (NSString *source in controller.comboSourceGenerations.allKeys) {
            controller.comboSourceGenerations[source] = @([controller.comboSourceGenerations[source] integerValue] + 1);
        }
        [controller.comboSourcePressedStates removeAllObjects];
        [controller.comboActiveTargetsBySource removeAllObjects];
        [controller.comboTargetHoldCounts removeAllObjects];
        controller.comboButtonFlags = 0;
        controller.comboLeftTrigger = 0;
        controller.comboRightTrigger = 0;
    }
    [self updateFinished:controller];
}

- (void)clearPhysicalControllerCombosForAllControllers {
    for (VoidController *controller in _voidControllers.allValues) {
        [self clearPhysicalControllerCombosForController:controller];
    }
}

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    VoidController* voidController = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (voidController == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Rumble emulation for OSC
    }
    if (voidController == nil) {
        // No connected controller for this player
        return;
    }
    
    [voidController.lowFreqMotor setMotorAmplitude:lowFreqMotor];
    [voidController.highFreqMotor setMotorAmplitude:highFreqMotor];
}

-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger
{
    VoidController* controller = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Trigger rumble emulation for OSC
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    [controller.leftTriggerMotor setMotorAmplitude:leftTrigger];
    [controller.rightTriggerMotor setMotorAmplitude:rightTrigger];
}

-(void)updateTimerStateForController:(VoidController* )voidController{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // GyroMode==Off used to short-circuit the timer entirely, but with
        // mapGyroTo we may still need device gyro samples for the stick/mouse
        // synthesis even when the legacy DS4 motion path is disabled.
        BOOL needDeviceGyroForMapping = (voidController == _oscController) &&
            (_mapGyroTo == MapGyroToRightStick || _mapGyroTo == MapGyroToMouse);
        if(_gyroMode == GyroModeOff && !needDeviceGyroForMapping){
            [self stopTimerForController:voidController];
            return;
        }

        if(voidController.gamepad.motion.hasAttitudeAndRotationRate) [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
        if(voidController.gamepad.motion.hasRotationRate) [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];

        // Self-bootstrap motionTypes for the OSC controller in mapping mode.
        // The legacy path waits for the host to call setMotionEventState
        // (only happens with DS4 emulation, where the host receives motion).
        // For Xbox emulation + RightStick / Mouse mapping, the host never
        // requests motion, so we have to seed the type ourselves to make
        // the timer-setup loop below fire.
        if (needDeviceGyroForMapping) {
            if (!voidController.motionTypes) voidController.motionTypes = [[NSMutableSet alloc] init];
            [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
            if (voidController.reportRateHz == 0) voidController.reportRateHz = 60;
        }

        for(NSNumber* motionTypeObj in voidController.motionTypes){
            uint8_t motionType = motionTypeObj.intValue;

#if !TARGET_OS_TV //tvOS has no device motion
            if(voidController == _oscController){
                //Player has no controller *or* no motion for controller 1 *or* wants to override controller 1 motion with device motion
                if(!voidController.motionManager) {
                    voidController.motionManager = [[CMMotionManager alloc] init];
                }
                
                switch (motionType) {
                    case LI_MOTION_TYPE_ACCEL:
                        [voidController.accelTimer invalidate];
                        voidController.accelTimer = nil;
                        // Reset the last motion sample
                        CMAcceleration emptyDeviceAccelSample = {};
                        voidController.lastDeviceAccelSample = emptyDeviceAccelSample;
                        
                    {dispatch_async(dispatch_get_main_queue(), ^{
                        NSLog(@"setup device built-in gyro accelTimer");
                        voidController.hasAccelerometer = YES;
                        voidController.accelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                            // Orphan self-destruct: if this isn't the controller's current
                            // accelTimer, a newer setup superseded us (or teardown missed us).
                            // Kill self so a stale timer can't keep flooding input forever.
                            if (timer != voidController.accelTimer) { [timer invalidate]; return; }
                            if (![self motionEmissionAllowed]) return;
                            // Accel only matters for the DS4 motion path. Skip when
                            // gyro is being routed to stick/mouse — sending accel
                            // alone would produce inconsistent host-side motion state.
                            if (self->_mapGyroTo != MapGyroToMotion) return;
                            // Don't send duplicate samples
                            CMAcceleration lastDeviceAccelSample = voidController.lastDeviceAccelSample;
                            CMAcceleration deviceAccelSample = voidController.motionManager.deviceMotion.userAcceleration;
                            //userAcceleration does not contain gravity, add gravity to x, y and z values:
                            deviceAccelSample.x += voidController.motionManager.deviceMotion.gravity.x * self->_gyroSensitivity;
                            deviceAccelSample.y += voidController.motionManager.deviceMotion.gravity.y * self->_gyroSensitivity;
                            deviceAccelSample.z += voidController.motionManager.deviceMotion.gravity.z * self->_gyroSensitivity;
                            
                            if (memcmp(&deviceAccelSample, &lastDeviceAccelSample, sizeof(deviceAccelSample)) == 0) {
                                return;
                            }
                            voidController.lastDeviceAccelSample = deviceAccelSample;
                            
                            // Convert g to m/s^2
                            if(UIApplication.sharedApplication.windows.firstObject.windowScene.interfaceOrientation == 4){ //check for landscape left or landscape right
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_ACCEL,
                                                            deviceAccelSample.y * -9.80665f * self->_gyroSensitivity,
                                                            deviceAccelSample.z * -9.80665f * self->_gyroSensitivity,
                                                            deviceAccelSample.x * -9.80665f * self->_gyroSensitivity);
                            }
                            else{
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_ACCEL,
                                                            deviceAccelSample.y * +9.80665f * self->_gyroSensitivity,
                                                            deviceAccelSample.z * -9.80665f * self->_gyroSensitivity,
                                                            deviceAccelSample.x * +9.80665f * self->_gyroSensitivity);
                            }
                        }];
                    });}
                        break;
                    case LI_MOTION_TYPE_GYRO:
                        [voidController.gyroTimer invalidate];
                        voidController.gyroTimer = nil;
                        
                        NSLog(@"setup device built-in gyro updates (callback-driven)");
                        voidController.hasGyroscope = YES;
                        // Callback-driven delivery: Core Motion invokes the handler once
                        // per sensor sample, so the polling NSTimer plus its duplicate-
                        // sample memcmp (and the aliasing jitter of polling a ~100Hz
                        // sensor at an unrelated rate) go away. Repeated start calls
                        // simply replace the handler; stopTimerForController calls
                        // stopDeviceMotionUpdates, so no orphan can outlive teardown.
                        // Weak refs break the manager→handler→owner retain cycle.
                        // Rate 0 is the host's "stop reporting" request. The old
                        // never-firing NSTimer (interval 1/0 = inf) honored it by
                        // accident; with callbacks we must stop explicitly.
                        if (voidController.reportRateHz == 0) {
                            [voidController.motionManager stopDeviceMotionUpdates];
                            break;
                        }
                        voidController.motionManager.deviceMotionUpdateInterval = 1.0 / voidController.reportRateHz;
                        __weak VoidController* weakGyroController = voidController;
                        __weak ControllerSupport* weakSelf = self;
                        [voidController.motionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                                                          withHandler:^(CMDeviceMotion* deviceMotion, NSError* motionError) {
                            VoidController* voidController = weakGyroController;
                            ControllerSupport* strongSelf = weakSelf;
                            if (!voidController || !strongSelf || !deviceMotion) return;
                            BOOL emit = [strongSelf motionEmissionAllowed] && strongSelf->_mapGyroTo != MapGyroToOff;
                            // When suppressed, drop any leftover RightStick gyro
                            // contribution to 0 once. Otherwise the last non-zero
                            // value would keep blending into the physical stick.
                            if (!emit) {
                                if (voidController.gyroStickX != 0 || voidController.gyroStickY != 0) {
                                    @synchronized(voidController) {
                                        voidController.gyroStickX = 0;
                                        voidController.gyroStickY = 0;
                                    }
                                    [strongSelf updateFinished:voidController];
                                }
                                return;
                            }
                            CMRotationRate deviceGyroSample = deviceMotion.rotationRate;

                            // Extract pitch/yaw/roll in deg/s (game frame).
                            //
                            // CMRotationRate is in the device's intrinsic frame:
                            //   .x = rotation around long-edge axis
                            //   .y = rotation around short-edge axis
                            //   .z = rotation around screen-perpendicular axis
                            //
                            // In landscape, the user's intuition maps as:
                            //   tilting top edge toward you (look up/down) = rotation
                            //     around the short edge of the device → .y → pitch
                            //   twisting iPad horizontally (look left/right) = rotation
                            //     around the long edge of the device → .x → yaw
                            //   banking like an airplane (roll) = rotation around the
                            //     axis perpendicular to the screen → .z → roll
                            //
                            // The rotation mapping relates DEVICE axes to the on-screen
                            // game world, so the only input that matters is how far the
                            // UI/video is rotated on the device (interfaceOrientation).
                            // Gravity and hand posture are irrelevant to rotationRate.
                            // Query the window scene: windows.firstObject can belong to
                            // an external display and report a stale orientation.
                            UIInterfaceOrientation gyroUIOrientation = UIInterfaceOrientationLandscapeRight;
                            for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
                                if ([scene isKindOfClass:[UIWindowScene class]]) {
                                    gyroUIOrientation = ((UIWindowScene*)scene).interfaceOrientation;
                                    break;
                                }
                            }

                            // The DS4 motion path used .z for yaw (kept for backward
                            // compat with whatever host-side remap it relied on).
                            // Passthrough stays ungated — the host does its own filtering.
                            BOOL landscape = gyroUIOrientation == UIInterfaceOrientationLandscapeRight;
                            float ds4_pitch_dps = deviceGyroSample.y * (landscape ? 57.2957795f : -57.2957795f) * strongSelf->_gyroSensitivity;
                            float ds4_yaw_dps   = deviceGyroSample.z * 57.2957795f * strongSelf->_gyroSensitivity;
                            float ds4_roll_dps  = deviceGyroSample.x * (landscape ? 57.2957795f : -57.2957795f) * strongSelf->_gyroSensitivity;

                            // Sensor noise gate for the stick/mouse paths. Fusion-corrected
                            // rotationRate still jitters at rest; the old max-magnitude blend
                            // swallowed that behind any stick input, but additive blending
                            // forwards it, and with a host-side stick deadzone of 0 it reads
                            // as a slowly wandering crosshair. 0.01 rad/s ≈ 0.6°/s sits well
                            // below deliberate micro-aim speeds.
                            const double kGyroNoiseGateRads = 0.01;
                            double gatedGyroX = fabs(deviceGyroSample.x) < kGyroNoiseGateRads ? 0 : deviceGyroSample.x;
                            double gatedGyroY = fabs(deviceGyroSample.y) < kGyroNoiseGateRads ? 0 : deviceGyroSample.y;

                            // Stick / Mouse modes: express game yaw/pitch in device axes
                            // per UI orientation. Landscape reads yaw from device x and
                            // pitch from device y; portrait swaps the axes (the video's
                            // vertical axis lands on the other device axis). Base signs
                            // are chosen so both flip toggles OFF give the correct feel
                            // (the old base had yaw inverted, masked by horizontal flip ON).
                            const float gyroK = 57.2957795f * strongSelf->_gyroSensitivity;
                            float yaw_dps, pitch_dps;
                            switch (gyroUIOrientation) {
                                case UIInterfaceOrientationLandscapeLeft:
                                    yaw_dps   =  gatedGyroX * gyroK;
                                    pitch_dps = -gatedGyroY * gyroK;
                                    break;
                                case UIInterfaceOrientationPortrait:
                                    yaw_dps   = -gatedGyroY * gyroK;
                                    pitch_dps = -gatedGyroX * gyroK;
                                    break;
                                case UIInterfaceOrientationPortraitUpsideDown:
                                    yaw_dps   =  gatedGyroY * gyroK;
                                    pitch_dps =  gatedGyroX * gyroK;
                                    break;
                                case UIInterfaceOrientationLandscapeRight:
                                default:
                                    yaw_dps   = -gatedGyroX * gyroK;
                                    pitch_dps =  gatedGyroY * gyroK;
                                    break;
                            }
                            float roll_dps  = deviceGyroSample.z * 57.2957795f * strongSelf->_gyroSensitivity;

                            switch (strongSelf->_mapGyroTo) {
                                case MapGyroToMotion:
                                    // Preserve the legacy DS4 axis mapping — the
                                    // host emulator expects the original convention.
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_GYRO,
                                                                ds4_pitch_dps, ds4_yaw_dps, ds4_roll_dps);
                                    break;
                                case MapGyroToRightStick: {
                                    // Stick Y default-inverts: tilt up → positive pitch → +Y stick.
                                    // The user-facing flips re-apply on top of that base convention,
                                    // so "Vertical Flip" off ⇒ ySign = -1, on ⇒ ySign = +1.
                                    const float xSign = strongSelf->_gyroInvertYaw ? -1.0f : 1.0f;
                                    const float ySign = strongSelf->_gyroInvertPitch ? 1.0f : -1.0f;
                                    int16_t stickX = clamp_int16(yaw_dps * xSign * GYRO_TO_STICK_SCALE);
                                    int16_t stickY = clamp_int16(pitch_dps * ySign * GYRO_TO_STICK_SCALE);
                                    @synchronized(voidController) {
                                        voidController.gyroStickX = stickX;
                                        voidController.gyroStickY = stickY;
                                    }
                                    [strongSelf updateFinished:voidController];
                                    break;
                                }
                                case MapGyroToMouse: {
                                    const float xSign = strongSelf->_gyroInvertYaw ? -1.0f : 1.0f;
                                    const float ySign = strongSelf->_gyroInvertPitch ? 1.0f : -1.0f;
                                    int16_t mouseX = clamp_int16(yaw_dps * xSign * GYRO_TO_MOUSE_SCALE);
                                    int16_t mouseY = clamp_int16(pitch_dps * ySign * GYRO_TO_MOUSE_SCALE);
                                    if (mouseX != 0 || mouseY != 0) LiSendMouseMoveEvent(mouseX, mouseY);
                                    break;
                                }
                                default: break;
                            }
                        }];
                        break;
                }
            }
            
#endif
            else{
                NSLog(@"controller obj timer update: controller timer ");
                switch (motionType) {
                    case LI_MOTION_TYPE_ACCEL:
                        [voidController.accelTimer invalidate];
                        voidController.accelTimer = nil;
                        
                        if (voidController.reportRateHz && voidController.gamepad.motion.hasGravityAndUserAcceleration) {
                            // Reset the last motion sample
                            GCAcceleration emptyAccelSample = {};
                            voidController.lastAccelSample = emptyAccelSample;
                            NSLog(@"setup controller gyro accelTimer");
                            // Run on main (NSTimer scheduling needs a runloop). If we're already
                            // on main, call inline — dispatch_sync(main) from main thread deadlocks.
                            // Triggered when applyGyroModeSetting reruns from the gyro-settings
                            // notification observer, which dispatches on mainQueue.
                            void (^setupAccelTimer)(void) = ^{
                                voidController.hasAccelerometer = YES;
                                voidController.accelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                                    // Orphan self-destruct (see device accel timer above).
                                    if (timer != voidController.accelTimer) { [timer invalidate]; return; }
                                    if (![self motionEmissionAllowed]) return;
                                    // Don't send duplicate samples
                                    GCAcceleration lastAccelSample = voidController.lastAccelSample;
                                    GCAcceleration accelSample = voidController.gamepad.motion.acceleration;
                                    
                                    if (memcmp(&accelSample, &lastAccelSample, sizeof(accelSample)) == 0) {
                                        return;
                                    }
                                    voidController.lastAccelSample = accelSample;
                                    
                                    // Convert g to m/s^2
                                    //NSLog(@"sending controller gyro data, accelSample data 00: %f, playerIndex: %ld, obj: %@",accelSample.x, (long)voidController.gamepad.playerIndex, voidController);
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_ACCEL,
                                                                accelSample.x * -9.80665f * self->_gyroSensitivity,
                                                                accelSample.y * -9.80665f * self->_gyroSensitivity,
                                                                accelSample.z * -9.80665f * self->_gyroSensitivity);
                                }];
                            };
                            if ([NSThread isMainThread]) {
                                setupAccelTimer();
                            } else {
                                dispatch_sync(dispatch_get_main_queue(), setupAccelTimer);
                            }
                        }
                        break;

                    case LI_MOTION_TYPE_GYRO:
                        [voidController.gyroTimer invalidate];
                        voidController.gyroTimer = nil;
                        
                        if (voidController.reportRateHz && voidController.gamepad.motion.hasRotationRate) {
                            // Reset the last motion sample
                            GCRotationRate emptyGyroSample = {};
                            voidController.lastGyroSample = emptyGyroSample;
                            //dispatch_sync(dispatch_get_main_queue(), ^{
                            {dispatch_async(dispatch_get_main_queue(), ^{
                                voidController.hasGyroscope = YES;
                                voidController.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                                    // Orphan self-destruct (see device accel timer above).
                                    if (timer != voidController.gyroTimer) { [timer invalidate]; return; }
                                    if (![self motionEmissionAllowed]) return;
                                    // Don't send duplicate samples
                                    GCRotationRate lastGyroSample = voidController.lastGyroSample;
                                    GCRotationRate gyroSample = voidController.gamepad.motion.rotationRate;
                                    if (memcmp(&gyroSample, &lastGyroSample, sizeof(gyroSample)) == 0) {
                                        return;
                                    }
                                    voidController.lastGyroSample = gyroSample;
                                    
                                    // Convert rad/s to deg/s
                                    // NSLog(@"sending controller gyro data, gyroSample data 00: %f, playerIndex: %ld, obj: %@",gyroSample.x, (long)voidController.gamepad.playerIndex, voidController);
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_GYRO,
                                                                gyroSample.x * 57.2957795f * self->_gyroSensitivity,
                                                                gyroSample.z * 57.2957795f * self->_gyroSensitivity,
                                                                gyroSample.y * -57.2957795f * self->_gyroSensitivity);
                                }];
                                //  });
                            });}
                        }
                        break;
                }
            }
        }
        
        NSLog(@"controller obj timer, motionTypes: %lu", (unsigned long)voidController.motionTypes.count);

        // Set the motion sensor state if they require manual activation
        [self updateSensorSateForController:voidController];
        NSLog(@"sensor active: %d", voidController.gamepad.motion.sensorsActive);
    }
}

- (void)updateSensorSateForController:(VoidController* )voidController{
    if (@available(iOS 14.0, *)) {
        if (voidController.gamepad.motion.sensorsRequireManualActivation) {
            if ((voidController.hasGyroscope || voidController.hasAccelerometer) && _gyroMode != GyroModeOff) {
                voidController.gamepad.motion.sensorsActive = YES;
            }
            else {
                voidController.gamepad.motion.sensorsActive = NO;
            }
        }
    }
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // This is a moonlight-common host callback (ClSetMotionEventState) that fires
        // on a common thread. It mutates VoidController motion state and (re)builds
        // the accel/gyro NSTimers — all of which are otherwise only touched on the
        // main thread, where the timers live and fire. Marshal the whole body to main
        // so timer property reads/writes stay single-threaded (matches the setup path
        // and the timers' own self-guard read). async is safe: no return value, and
        // inline-if-already-main avoids a needless hop.
        void (^work)(void) = ^{
            NSLog(@"gyroMode: %ld", (long)self->_gyroMode);

            VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
            //using device motion
            if (voidController == nil || self->_gyroMode == AlwaysDevice) {
                // No connected controller for this player, use the _oscController instead
                voidController = self->_oscController;
                if(!voidController.motionTypes){
                    voidController.motionTypes = [[NSMutableSet alloc] init];
                }
                [voidController.motionTypes addObject:@(motionType)];

                voidController.hasGyroscope = NO;
                voidController.hasAccelerometer = NO;
                voidController.reportRateHz = reportRateHz;
            }

            voidController.controllerNumber = controllerNumber;

            if(voidController == self->_oscController) [self updateTimerStateForController:voidController];
        };
        if ([NSThread isMainThread]) {
            work();
        } else {
            dispatch_async(dispatch_get_main_queue(), work);
        }
    }
}

-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        VoidController* controller = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
        if (controller == nil) {
            // No connected controller for this player
            return;
        }
        
        if (controller.gamepad.light == nil) {
            // No LED control supported for this controller
            return;
        }
        
        controller.gamepad.light.color = [[GCColor alloc] initWithRed:(r / 255.0f) green:(g / 255.0f) blue:(b / 255.0f)];
    }
}

-(void) updateLeftStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(VoidController*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(VoidController*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(VoidController*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(VoidController*)controller releasedButtons:(int)releasedButtons
{
    if ((controller.emulatingButtonFlags & EMULATING_SELECT) && (releasedButtons & (LB_FLAG | PLAY_FLAG))) {
        controller.lastButtonFlags &= ~BACK_FLAG;
        controller.emulatingButtonFlags &= ~EMULATING_SELECT;
    }
    
    if (controller.emulatingButtonFlags & EMULATING_SPECIAL) {
        // If Select is emulated, we use RB+Start to emulate special, otherwise we use Start+Select
        if (controller.supportedEmulationFlags & EMULATING_SELECT) {
            if (releasedButtons & (RB_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
        else {
            if (releasedButtons & (BACK_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
}

-(void) handleSpecialCombosPressed:(VoidController*)controller pressedButtons:(int)pressedButtons
{
    // Special button combos for select and special
    if (controller.lastButtonFlags & PLAY_FLAG) {
        // If LB and start are down, trigger select
        if (controller.lastButtonFlags & LB_FLAG) {
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                controller.lastButtonFlags |= BACK_FLAG;
                controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | LB_FLAG));
                controller.emulatingButtonFlags |= EMULATING_SELECT;
            }
        }
        else if (controller.supportedEmulationFlags & EMULATING_SPECIAL) {
            // If Select is emulated too, use RB+Start to emulate special
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                if (controller.lastButtonFlags & RB_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | RB_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
            else {
                // If Select is physical, use Start+Select to emulate special
                if (controller.lastButtonFlags & BACK_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | BACK_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
        }
    }
}

-(void) updateButtonFlags:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(uint16_t) getActiveGamepadMask
{
    return (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0);
}

-(void) updateFinished:(VoidController*)controller
{
    // --- Input-path diagnostic (throttled ≈1/sec) -------------------------------
    // Counts updateFinished calls per second and reports the last sender + payload.
    // A runaway rate (hundreds/sec) with a stale sender pointer fingers an orphan
    // timer flooding the stream; a normal rate while input feels dead points instead
    // at the gesture-suppression path. Cheap enough to leave always-on.
    {
        static NSInteger sDiagCallCount = 0;
        static CFTimeInterval sDiagLastLog = 0;
        sDiagCallCount++;
        CFTimeInterval now = CACurrentMediaTime();
        if (sDiagLastLog == 0) sDiagLastLog = now;
        if (now - sDiagLastLog >= 1.0) {
            NSLog(@"[InputDiag] updateFinished x%ld/%.1fs sender=%p osc=%d btn=0x%X L=(%d,%d) R=(%d,%d)",
                  (long)sDiagCallCount, now - sDiagLastLog, controller,
                  controller == _oscController,
                  (unsigned)(controller.lastButtonFlags | controller.comboButtonFlags),
                  controller.lastLeftStickX, controller.lastLeftStickY,
                  controller.lastRightStickX, controller.lastRightStickY);
            sDiagCallCount = 0;
            sDiagLastLog = now;
        }
    }
    // ----------------------------------------------------------------------------

    BOOL exitRequested = NO;

    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Handle Start+Select+L1+R1 gamepad quit combo
        if (controller.lastButtonFlags == (PLAY_FLAG | BACK_FLAG | LB_FLAG | RB_FLAG)) {
            controller.lastButtonFlags = 0;
            exitRequested = YES;
        }
        
        // Only send controller events if we successfully reported controller arrival
        if ([self reportControllerArrival:controller]) {
            uint32_t buttonFlags = controller.lastButtonFlags;
            uint8_t leftTrigger = controller.lastLeftTrigger;
            uint8_t rightTrigger = controller.lastRightTrigger;
            int16_t leftStickX = controller.lastLeftStickX;
            int16_t leftStickY = controller.lastLeftStickY;
            int16_t rightStickX = controller.lastRightStickX;
            int16_t rightStickY = controller.lastRightStickY;

            buttonFlags |= controller.comboButtonFlags;
            leftTrigger = MAX(leftTrigger, controller.comboLeftTrigger);
            rightTrigger = MAX(rightTrigger, controller.comboRightTrigger);
            
            // If this is merged with another controller, combine the inputs
            if (controller.mergedWithController) {
                buttonFlags |= controller.mergedWithController.lastButtonFlags | controller.mergedWithController.comboButtonFlags;
                leftTrigger = MAX(leftTrigger, MAX(controller.mergedWithController.lastLeftTrigger, controller.mergedWithController.comboLeftTrigger));
                rightTrigger = MAX(rightTrigger, MAX(controller.mergedWithController.lastRightTrigger, controller.mergedWithController.comboRightTrigger));
                leftStickX = MAX_MAGNITUDE(leftStickX, controller.mergedWithController.lastLeftStickX);
                leftStickY = MAX_MAGNITUDE(leftStickY, controller.mergedWithController.lastLeftStickY);
                rightStickX = MAX_MAGNITUDE(rightStickX, controller.mergedWithController.lastRightStickX);
                rightStickY = MAX_MAGNITUDE(rightStickY, controller.mergedWithController.lastRightStickY);
            }

            // Blend gyro-synthesized right stick contribution (when mapGyroTo
            // == RightStick the gyro handler writes here directly). Additive,
            // Steam/Switch-style: the thumb/pad sets the coarse direction and
            // the wrist adds fine corrections on top — including pulling back
            // while the stick is pegged. The old max-magnitude blend swallowed
            // whichever source was smaller, so gyro micro-aim died whenever
            // the stick was deflected (and vice versa). Resting sensor noise
            // is kept out by the noise gate at the gyro source.
            rightStickX = clamp_int16((CGFloat)rightStickX + (CGFloat)controller.gyroStickX);
            rightStickY = clamp_int16((CGFloat)rightStickY + (CGFloat)controller.gyroStickY);
            
            //NSLog(@"gamepadMask: %@", [self binaryRepresentationOfInteger:buttonFlags]); // we got the pressed OSC buttons here.
            
            // Player 0 is always present for OSC
            LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0, [self getActiveGamepadMask],
                                       buttonFlags, leftTrigger, rightTrigger,
                                       leftStickX, leftStickY, rightStickX, rightStickY);
        }
    }
    [_controllerStreamLock unlock];
    
    if (exitRequested) {
        // Invoke the delegate callback on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate streamExitRequested];
        });
    }
}


- (NSString *)binaryRepresentationOfInteger:(int)number {
    NSMutableString *binaryString = [NSMutableString string];
    int numBits = sizeof(number) * 8;

    for (int i = numBits - 1; i >= 0; i--) {
        [binaryString appendString:((number >> i) & 1) ? @"1" : @"0"];
    }

    return binaryString;
}


+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (controller.extendedGamepad != NULL) {
            // Re-enable system gestures on the gamepad buttons now
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateEnabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
    }
}

-(void) initializeControllerHaptics:(VoidController*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
    controller.leftTriggerMotor = [HapticContext createContextForLeftTrigger:controller.gamepad];
    controller.rightTriggerMotor = [HapticContext createContextForRightTrigger:controller.gamepad];
}

-(void) cleanupControllerHaptics:(VoidController*) controller
{
    [controller.lowFreqMotor cleanup];
    [controller.highFreqMotor cleanup];
    [controller.leftTriggerMotor cleanup];
    [controller.rightTriggerMotor cleanup];
}

-(void) cleanupControllerMotion:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // Stop sensor sampling timers
        [controller.gyroTimer invalidate];
        [controller.accelTimer invalidate];
        
        // Disable motion sensors if they require manual activation
        if (controller.gamepad && controller.gamepad.motion && controller.gamepad.motion.sensorsRequireManualActivation) {
            controller.gamepad.motion.sensorsActive = NO;
        }
    }
}

-(void) initializeControllerBattery:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.gamepad.battery) {
            // Poll for updated battery status every 30 seconds
            controller.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
                if ((GCDeviceBatteryState)controller.lastBatteryState != controller.gamepad.battery.batteryState ||
                    controller.lastBatteryLevel != controller.gamepad.battery.batteryLevel) {
                    uint8_t batteryState;
                    
                    switch (controller.gamepad.battery.batteryState) {
                        case GCDeviceBatteryStateFull:
                            batteryState = LI_BATTERY_STATE_FULL;
                            break;
                        case GCDeviceBatteryStateCharging:
                            batteryState = LI_BATTERY_STATE_CHARGING;
                            break;
                        case GCDeviceBatteryStateDischarging:
                            batteryState = LI_BATTERY_STATE_DISCHARGING;
                            break;
                        case GCDeviceBatteryStateUnknown:
                        default:
                            batteryState = LI_BATTERY_STATE_UNKNOWN;
                            break;
                    }
                    
                    LiSendControllerBatteryEvent(controller.playerIndex, batteryState, (uint8_t)(controller.gamepad.battery.batteryLevel * 100));
                    
                    controller.lastBatteryState = (ControllerDeviceBatteryState)controller.gamepad.battery.batteryState;
                    controller.lastBatteryLevel = controller.gamepad.battery.batteryLevel;
                }
            }];
            
            // Fire the timer immediately to send the initial battery state
            [controller.batteryTimer fire];
        }
    }
}

-(void) cleanupControllerBattery:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        [controller.batteryTimer invalidate];
    }
}

-(BOOL) reportControllerArrival:(VoidController*) voidController
{
    // Only report arrival once
    if (voidController.reportedArrival) {
        return YES;
    }
    
    uint8_t type = LI_CTYPE_UNKNOWN;
    uint16_t capabilities = 0;
    uint32_t supportedButtonFlags = 0;
    
    GCController *controller = voidController.gamepad;
    if (controller) {
        // This is a physical controller with a corresponding GCController object
        
        // Start is always present
        supportedButtonFlags |= PLAY_FLAG;
        
        // Detect buttons present in the GCExtendedGamepad profile
        if (controller.extendedGamepad.dpad) {
            supportedButtonFlags |= UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
        }
        if (controller.extendedGamepad.leftShoulder) {
            supportedButtonFlags |= LB_FLAG;
        }
        if (controller.extendedGamepad.rightShoulder) {
            supportedButtonFlags |= RB_FLAG;
        }
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad.buttonOptions) {
                supportedButtonFlags |= BACK_FLAG;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            if (controller.extendedGamepad.buttonHome) {
                supportedButtonFlags |= SPECIAL_FLAG;
            }
        }
        if (controller.extendedGamepad.buttonA) {
            supportedButtonFlags |= A_FLAG;
        }
        if (controller.extendedGamepad.buttonB) {
            supportedButtonFlags |= B_FLAG;
        }
        if (controller.extendedGamepad.buttonX) {
            supportedButtonFlags |= X_FLAG;
        }
        if (controller.extendedGamepad.buttonY) {
            supportedButtonFlags |= Y_FLAG;
        }
        if (@available(iOS 12.1, tvOS 12.1, *)) {
            if (controller.extendedGamepad.leftThumbstickButton) {
                supportedButtonFlags |= LS_CLK_FLAG;
            }
            if (controller.extendedGamepad.rightThumbstickButton) {
                supportedButtonFlags |= RS_CLK_FLAG;
            }
        }
        
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Xbox One/Series controller
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                supportedButtonFlags |= PADDLE1_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                supportedButtonFlags |= PADDLE2_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                supportedButtonFlags |= PADDLE3_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                supportedButtonFlags |= PADDLE4_FLAG;
            }
            if (@available(iOS 15.0, tvOS 15.0, *)) {
                if (controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                    supportedButtonFlags |= MISC_FLAG;
                }
            }
            
            // DualShock/DualSense controller
            if (controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                supportedButtonFlags |= TOUCHPAD_FLAG;
            }
            if (controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                capabilities |= LI_CCAP_TOUCHPAD;
            }
            
            
            // LI_CTYPE_UNKNOWN for option "Both"
            if(voidController.playerIndex == 0){
                type = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
            }
            
            if(voidController.playerIndex == 1 && _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN){
                type = LI_CTYPE_XBOX;
            }
            
            if(voidController.playerIndex >= 1 && _streamConfig.emulatedControllerType != LI_CTYPE_UNKNOWN){
                if ([controller.extendedGamepad isKindOfClass:[GCXboxGamepad class]]) {
                    type = LI_CTYPE_XBOX;
                }
                if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    type = LI_CTYPE_PS;
                }
                
                if (@available(iOS 14.5, tvOS 14.5, *)) {
                    if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                        type = LI_CTYPE_PS;
                    }
                }
            }
            
            
            
            // Detect supported haptics localities
            if (controller.haptics) {
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityHandles]) {
                    capabilities |= LI_CCAP_RUMBLE;
                }
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityTriggers]) {
                    capabilities |= LI_CCAP_TRIGGER_RUMBLE;
                }
            }
            
            // Detect supported motion sensors
            if (controller.motion) {
                if (controller.motion.hasGravityAndUserAcceleration) {
                    capabilities |= LI_CCAP_ACCEL;
                }
                if (controller.motion.hasRotationRate) {
                    capabilities |= LI_CCAP_GYRO;
                }
            }

            
            
            // Detect RGB LED support
            if (controller.light) {
                capabilities |= LI_CCAP_RGB_LED;
            }
            
            // Detect battery support
            if (controller.battery) {
                capabilities |= LI_CCAP_BATTERY_STATE;
            }
            
            bool controllerLacksGyro = (capabilities & LI_CCAP_GYRO) == 0;
            if(_streamConfig.emulatedControllerType == LI_CTYPE_PS && (_gyroMode == AlwaysDevice || (_gyroMode == GyroModeAuto && controllerLacksGyro)))
            {
                type = LI_CTYPE_PS;
                capabilities |= LI_CCAP_GYRO | LI_CCAP_ACCEL;
            }

            supportedButtonFlags |= [self physicalControllerComboSupportedButtonFlags];
        }
    }
    else {
        // This is a virtual controller corresponding to our OSC
        // set osc to PS to utilize built-in gyro when "both" is selected
        type = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
        
        /*
        if (_streamConfig.gyroMode != GyroModeOff) {
            type = LI_CTYPE_PS;
            capabilities = LI_CCAP_GYRO | LI_CCAP_ACCEL;
        }
        else {
            type = LI_CTYPE_XBOX;
            capabilities = 0;
        }
         */


        // Set the standard supported buttons for the virtual controller.
        supportedButtonFlags =
            PLAY_FLAG | BACK_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
            LB_FLAG | RB_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | A_FLAG | B_FLAG | X_FLAG | Y_FLAG;
    }

    // Report the new controller to the host
    // NB: This will fail if the connection hasn't been fully established yet
    // and we will try again later.
    if (LiSendControllerArrivalEvent(controller.playerIndex,
                                     [self getActiveGamepadMask],
                                     type,
                                     supportedButtonFlags,
                                     capabilities) != 0) {
        return NO;
    }
    
    // Begin polling for battery status
    [self initializeControllerBattery:voidController];
    
    // Remember that we've reported arrival already
    voidController.reportedArrival = YES;
    return YES;
}

-(void) handleControllerTouchpad:(VoidController*)controller touch:(GCControllerDirectionPad*)touch index:(int)index
{
    controller_touch_context_t context = index == 0 ? controller.primaryTouch : controller.secondaryTouch;
    
    // This magic is courtesy of SDL
    float normalizedX = (1.0f + touch.xAxis.value) * 0.5f;
    float normalizedY = 1.0f - (1.0f + touch.yAxis.value) * 0.5f;
    
    // If we went from a touch to no touch, generate a touch up event
    if ((context.lastX || context.lastY) && (!touch.xAxis.value && !touch.yAxis.value)) {
        LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_UP, index, normalizedX, normalizedY, 1.0f);
    }
    else if (touch.xAxis.value || touch.yAxis.value) {
        // If we went from no touch to a touch, generate a touch down event
        if (!context.lastX && !context.lastY) {
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_DOWN, index, normalizedX, normalizedY, 1.0f);
        }
        else if (context.lastX != touch.xAxis.value || context.lastY != touch.yAxis.value) {
            // Otherwise it's just a move
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_MOVE, index, normalizedX, normalizedY, 1.0f);
        }
    }
    
    // We have to assign the whole struct because this is a property rather than a standard
    // field that we could modify through a pointer.
    if (index == 0) {
        controller.primaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
    else {
        controller.secondaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }
        
        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    BOOL mappedStart = [self handlePhysicalControllerComboSource:@"START" pressed:YES controller:voidController];
                    if (!mappedStart) {
                        [self setButtonFlag:voidController flags:PLAY_FLAG];
                        [self updateFinished:voidController];
                    }
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    if (mappedStart) {
                        [self handlePhysicalControllerComboSource:@"START" pressed:NO controller:voidController];
                    } else {
                        [self clearButtonFlag:voidController flags:PLAY_FLAG];
                        [self updateFinished:voidController];
                    }
                });
            };
        }
        
        if (controller.extendedGamepad != NULL) {
            // Disable system gestures on the gamepad to avoid interfering
            // with in-game controller actions
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateDisabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                if (voidController == nil) return;
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                unsigned char leftTrigger, rightTrigger;
                BOOL comboA = [self handlePhysicalControllerComboSource:@"A" pressed:gamepad.buttonA.pressed controller:voidController];
                BOOL comboB = [self handlePhysicalControllerComboSource:@"B" pressed:gamepad.buttonB.pressed controller:voidController];
                BOOL comboX = [self handlePhysicalControllerComboSource:@"X" pressed:gamepad.buttonX.pressed controller:voidController];
                BOOL comboY = [self handlePhysicalControllerComboSource:@"Y" pressed:gamepad.buttonY.pressed controller:voidController];
                
                if (self->_swapABButtons) {
                    if (!comboA) UPDATE_BUTTON_FLAG(voidController, B_FLAG, gamepad.buttonA.pressed);
                    if (!comboB) UPDATE_BUTTON_FLAG(voidController, A_FLAG, gamepad.buttonB.pressed);
                }
                else {
                    if (!comboA) UPDATE_BUTTON_FLAG(voidController, A_FLAG, gamepad.buttonA.pressed);
                    if (!comboB) UPDATE_BUTTON_FLAG(voidController, B_FLAG, gamepad.buttonB.pressed);
                }

                if (self->_swapXYButtons) {
                    if (!comboX) UPDATE_BUTTON_FLAG(voidController, Y_FLAG, gamepad.buttonX.pressed);
                    if (!comboY) UPDATE_BUTTON_FLAG(voidController, X_FLAG, gamepad.buttonY.pressed);
                }
                else {
                    if (!comboX) UPDATE_BUTTON_FLAG(voidController, X_FLAG, gamepad.buttonX.pressed);
                    if (!comboY) UPDATE_BUTTON_FLAG(voidController, Y_FLAG, gamepad.buttonY.pressed);
                }
                
                if (![self handlePhysicalControllerComboSource:@"UP" pressed:gamepad.dpad.up.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, UP_FLAG, gamepad.dpad.up.pressed);
                }
                if (![self handlePhysicalControllerComboSource:@"DOWN" pressed:gamepad.dpad.down.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, DOWN_FLAG, gamepad.dpad.down.pressed);
                }
                if (![self handlePhysicalControllerComboSource:@"LEFT" pressed:gamepad.dpad.left.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, LEFT_FLAG, gamepad.dpad.left.pressed);
                }
                if (![self handlePhysicalControllerComboSource:@"RIGHT" pressed:gamepad.dpad.right.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                }
                
                if (![self handlePhysicalControllerComboSource:@"L1" pressed:gamepad.leftShoulder.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, LB_FLAG, gamepad.leftShoulder.pressed);
                }
                if (![self handlePhysicalControllerComboSource:@"R1" pressed:gamepad.rightShoulder.pressed controller:voidController]) {
                    UPDATE_BUTTON_FLAG(voidController, RB_FLAG, gamepad.rightShoulder.pressed);
                }
                
                // Yay, iOS 12.1 now supports analog stick buttons
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (gamepad.leftThumbstickButton != nil) {
                        if (![self handlePhysicalControllerComboSource:@"L3" pressed:gamepad.leftThumbstickButton.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, LS_CLK_FLAG, gamepad.leftThumbstickButton.pressed);
                        }
                    }
                    if (gamepad.rightThumbstickButton != nil) {
                        if (![self handlePhysicalControllerComboSource:@"R3" pressed:gamepad.rightThumbstickButton.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, RS_CLK_FLAG, gamepad.rightThumbstickButton.pressed);
                        }
                    }
                }
                
                if (@available(iOS 13.0, tvOS 13.0, *)) {
                    // Options button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonOptions != nil) {
                        if (![self handlePhysicalControllerComboSource:@"SELECT" pressed:gamepad.buttonOptions.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, BACK_FLAG, gamepad.buttonOptions.pressed);
                        }

                        // For older MFi gamepads, the menu button will already be handled by
                        // the controllerPausedHandler.
                        if (![self handlePhysicalControllerComboSource:@"START" pressed:gamepad.buttonMenu.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, PLAY_FLAG, gamepad.buttonMenu.pressed);
                        }
                    }
                }
                
                if (@available(iOS 14.0, tvOS 14.0, *)) {
                    // Home/Guide button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonHome != nil) {
                        if (![self handlePhysicalControllerComboSource:@"HOME" pressed:gamepad.buttonHome.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, SPECIAL_FLAG, gamepad.buttonHome.pressed);
                        }
                    }
                    
                    // Xbox One/Series controllers
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                        GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleOne];
                        if (![self handlePhysicalControllerComboSource:@"PADDLE1" pressed:button.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, PADDLE1_FLAG, button.pressed);
                        }
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                        GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo];
                        if (![self handlePhysicalControllerComboSource:@"PADDLE2" pressed:button.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, PADDLE2_FLAG, button.pressed);
                        }
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                        GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleThree];
                        if (![self handlePhysicalControllerComboSource:@"PADDLE3" pressed:button.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, PADDLE3_FLAG, button.pressed);
                        }
                    }
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                        GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputXboxPaddleFour];
                        if (![self handlePhysicalControllerComboSource:@"PADDLE4" pressed:button.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, PADDLE4_FLAG, button.pressed);
                        }
                    }
                    if (@available(iOS 15.0, tvOS 15.0, *)) {
                        if (gamepad.controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                            GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputButtonShare];
                            if (![self handlePhysicalControllerComboSource:@"SHARE" pressed:button.pressed controller:voidController]) {
                                UPDATE_BUTTON_FLAG(voidController, MISC_FLAG, button.pressed);
                            }
                        }
                    }
                    
                    // DualShock/DualSense controllers
                    if (gamepad.controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                        GCControllerButtonInput *button = gamepad.controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton];
                        if (![self handlePhysicalControllerComboSource:@"TOUCHPAD" pressed:button.pressed controller:voidController]) {
                            UPDATE_BUTTON_FLAG(voidController, TOUCHPAD_FLAG, button.pressed);
                        }
                    }
                    if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                        [self handleControllerTouchpad:voidController
                                                 touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]
                                                 index:0];
                    }
                    if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]) {
                        [self handleControllerTouchpad:voidController
                                                 touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]
                                                 index:1];
                    }
                }
                
                leftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                leftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;
                
                rightStickX = gamepad.rightThumbstick.xAxis.value * 0x7FFE;
                rightStickY = gamepad.rightThumbstick.yAxis.value * 0x7FFE;
                
                if ([self physicalControllerComboHasMappingForSource:@"L2"]) {
                    BOOL pressed = [self physicalControllerComboTriggerPressedForSource:@"L2" value:gamepad.leftTrigger.value controller:voidController];
                    [self handlePhysicalControllerComboSource:@"L2" pressed:pressed controller:voidController];
                    leftTrigger = 0;
                } else {
                    leftTrigger = gamepad.leftTrigger.value * 0xFF;
                }
                if ([self physicalControllerComboHasMappingForSource:@"R2"]) {
                    BOOL pressed = [self physicalControllerComboTriggerPressedForSource:@"R2" value:gamepad.rightTrigger.value controller:voidController];
                    [self handlePhysicalControllerComboSource:@"R2" pressed:pressed controller:voidController];
                    rightTrigger = 0;
                } else {
                    rightTrigger = gamepad.rightTrigger.value * 0xFF;
                }
                
                [self updateLeftStick:voidController x:leftStickX y:leftStickY];
                [self updateRightStick:voidController x:rightStickX y:rightStickY];
                [self updateTriggers:voidController left:leftTrigger right:rightTrigger];
                [self updateFinished:voidController];
            };
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
    
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = nil;
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
#endif
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    if (_captureMouse){
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
            self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
            self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;
            
            short truncatedDeltaX = (short)self->accumulatedDeltaX;
            short truncatedDeltaY = (short)self->accumulatedDeltaY;
            
            if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
                LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);
                
                self->accumulatedDeltaX -= truncatedDeltaX;
                self->accumulatedDeltaY -= truncatedDeltaY;
            }
        };
    } else {
        mouse.mouseInput.mouseMovedHandler = nil;
    }

    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    };
    
    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            };
        }
    }
    
    // We use UIPanGestureRecognizer on iPadOS because it allows us to distinguish
    // between discrete and continuous scroll events and also works around a bug
    // in iPadOS 15 where discrete scroll events are dropped. tvOS only supports
    // GCMouse for mice, so we will have to just use it and hope for the best.
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollX += value;
        
        short truncatedScrollX = (short)self->accumulatedScrollX;
        
        if (truncatedScrollX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-truncatedScrollX * 20);
            
            self->accumulatedScrollX -= truncatedScrollX;
        }
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollY += value;
        
        short truncatedScrollY = (short)self->accumulatedScrollY;
        
        if (truncatedScrollY != 0) {
            LiSendHighResScrollEvent(truncatedScrollY * 20);
            
            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
#endif
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;
        
        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    
    [_osc setLevel:level];
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

-(VoidController* )controllerHasBeenAssignedDeprecated:(GCController*)controller{
    if(controller.playerIndex == 0) return nil;
    if(controller.playerIndex > 0){
            for(VoidController* voidController in _voidControllers){
                if(voidController.gamepad == controller) return voidController;
            }
    }
    return nil;
}


- (void)updateVoidController:(VoidController* )voidController withGCController:(GCController* )controller{
    //voidController.playerIndex = controller.playerIndex == -1 ? 0 : (uint8_t) controller.playerIndex;
    voidController.motionTypes = [[NSMutableSet alloc] init];
    voidController.supportedEmulationFlags = EMULATING_SPECIAL | EMULATING_SELECT;
    voidController.gamepad = controller;
    voidController.hasAccelerometer = NO;
    voidController.hasGyroscope = NO;

    
    if(voidController.gamepad.motion.hasAttitudeAndRotationRate){
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
        voidController.hasAccelerometer = YES;
        voidController.reportRateHz = 120;
    }
    if (@available(iOS 14.0, *)) {
        if(voidController.gamepad.motion.hasRotationRate) {
            [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
            voidController.hasGyroscope = YES;
            voidController.reportRateHz = 120;
        }
    }

    // Only player 0 shares state with the OSC. Merging every controller here
    // let the last-connected gamepad hijack _oscController.mergedWithController
    // and cross-contaminate multi-gamepad input (upstream 3e1423ff).
    if (voidController.playerIndex == 0) {
        voidController.mergedWithController = _oscController;
        _oscController.mergedWithController = voidController;
    }
    else {
        voidController.mergedWithController = nil;
        if (_oscController.mergedWithController == voidController) {
            _oscController.mergedWithController = nil;
        }
    }
    
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonOptions != nil) {
            // Disable select button emulation since we have a physical select button
            voidController.supportedEmulationFlags &= ~EMULATING_SELECT;
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonHome != nil) {
            // Disable special button emulation since we have a physical special button
            voidController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
        }
    }
    
    // Prepare controller haptics for use
    [self initializeControllerHaptics:voidController];
}

-(VoidController* )assignController:(GCController*)controller {
    NSLog(@"run assignController");

    bool newGCControllerArrival = ![_activeGCControllers containsObject:controller];
    
    if(!newGCControllerArrival){
        VoidController* voidController = [_voidControllers objectForKey:@(controller.playerIndex)];
        if(!voidController) {
            voidController = [[VoidController alloc] init];
        }
        [self updateVoidController:voidController withGCController:controller];
        [_voidControllers setObject:voidController forKey:[NSNumber numberWithInteger:voidController.playerIndex]];
        return voidController;
    }
    
    // extenal controller start from playerIndex 1 for option "Both"
    int startPlayIndex = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? 1 : 0;
    
    for (int i = startPlayIndex; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            
            VoidController* voidController = [[VoidController alloc] init];


            [_activeGCControllers addObject:controller];
            controller.playerIndex = i;
            voidController.playerIndex = i;
            [self updateVoidController:voidController withGCController:controller];
            
            [_voidControllers setObject:voidController forKey:[NSNumber numberWithInteger:controller.playerIndex]];
            
            Log(LOG_I, @"Assigning controller index: %d", i);
            
            return voidController;
            
        }
    }
    
    return nil;
}

-(VoidController*) getOscController {
    return _oscController;
}

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;
    
    if (streamConfig.multiController) {
        int i = 0;
        for (GCController* controller in [GCController controllers]) {
            if ([ControllerSupport isSupportedGamepad:controller]) {
                mask |= 1 << i++;
            }
        }
    }
    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. OSC is active in both
    // RelativeTouch and NativeTouch modes (StreamView only forces it Off for
    // AbsoluteTouch / NativeTouchOnly), so the handshake mask must advertise the OSC
    // gamepad in either — otherwise NativeTouch sessions hand Sunshine a zero mask
    // and rely on a post-connect arrival, widening the resume-time controller churn.
    BOOL touchModeAllowsOsc = (settings.touchMode.intValue == RelativeTouch ||
                               settings.touchMode.intValue == NativeTouch);
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && touchModeAllowsOsc) {
        mask |= 0x1;
    }
    
    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    return _voidControllers.count;
}

- (void)assignControllers{
    for (GCController* controller in [GCController controllers]) {
        NSLog(@"controller count: iterating");

        if ([ControllerSupport isSupportedGamepad:controller]) {
            NSLog(@"controller count: is supported,is contained by dict: %d", [_activeGCControllers containsObject:controller]);
                NSLog(@"controller obj +1 in dic");
                [self assignController:controller];
                NSLog(@"controller obj num in dict: %lu", (unsigned long)_voidControllers.allValues.count);
                [self registerControllerCallbacks:controller];
            // Note: We cannot report controller arrival to the host here,
            // because the connection has not been established yet.play
        }
    }
    NSLog(@"device gyro codes,update gyroMode: %d, controller count: %lu", _gyroMode, (unsigned long)_voidControllers.count);
}

- (void)updateCommonConfig:(StreamConfiguration* )streamConfig{
    _streamConfig = streamConfig;
    _multiController = streamConfig.multiController;
    _swapABButtons = streamConfig.swapABButtons;
    _swapXYButtons = streamConfig.swapXYButtons;
    [self reloadPhysicalControllerComboMappings];

    _oscController.playerIndex = 0;

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    _oscEnabled = _oscEnabled || (OnScreenControlsLevel)[currentSettings.onscreenControls integerValue] != OnScreenControlsLevelOff || streamConfig.gyroMode != GyroModeOff;
    _gyroSensitivity = currentSettings.gyroSensitivity.floatValue;
    _mapGyroTo = currentSettings.mapGyroTo.intValue;  // 0 = MapGyroToMotion (legacy default)
    _gyroInvertPitch = currentSettings.gyroInvertPitch;
    _gyroInvertYaw = currentSettings.gyroInvertYaw;
    self.forceGyroOverrideSet = [[NSUserDefaults standardUserDefaults] objectForKey:@"forceGyroEnabled"] != nil;
    self.forceGyroEnabled = currentSettings.forceGyroEnabled;
}

- (void)resetGyroInputForController:(VoidController* )voidController{
    if(voidController.hasAccelerometer) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_ACCEL,0,0,0);
    if(voidController.hasGyroscope) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_GYRO,0,0,0);
    if (@available(iOS 14.0, *)) {
        voidController.gamepad.motion.sensorsActive = false;
    }
}

- (void)clearGyroOutputForController:(VoidController* )voidController {
    if (!voidController) return;

    if (voidController.hasAccelerometer) {
        LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber, LI_MOTION_TYPE_ACCEL, 0, 0, 0);
    }
    if (voidController.hasGyroscope) {
        LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber, LI_MOTION_TYPE_GYRO, 0, 0, 0);
    }

    GCAcceleration emptyAccelSample = {};
    GCRotationRate emptyGyroSample = {};
#if !TARGET_OS_TV
    CMAcceleration emptyDeviceAccelSample = {};
    CMRotationRate emptyDeviceGyroSample = {};
    voidController.lastDeviceAccelSample = emptyDeviceAccelSample;
    voidController.lastDeviceGyroSample = emptyDeviceGyroSample;
#endif
    voidController.lastAccelSample = emptyAccelSample;
    voidController.lastGyroSample = emptyGyroSample;

    if (voidController.gyroStickX != 0 || voidController.gyroStickY != 0) {
        @synchronized(voidController) {
            voidController.gyroStickX = 0;
            voidController.gyroStickY = 0;
        }
        [self updateFinished:voidController];
    }
}

- (void)clearGyroOutputForAllControllers {
    [self clearGyroOutputForController:_oscController];
    for (VoidController* controller in _voidControllers.allValues) {
        [self clearGyroOutputForController:controller];
    }
}

- (void)stopTimerForAllControllers{
    [self stopTimerForController:_oscController];
    for(VoidController* controller in _voidControllers.allValues){
        [self stopTimerForController:controller];
    }
}

- (void)updateControllerSupport:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate {
    NSLog(@"update config call");

    _reattachEpoch++;
    _gyroMode = streamConfig.gyroMode;

    [self updateCommonConfig:streamConfig];
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    [self applyGyroModeSetting];
    
    [self assignControllers];
    
    NSLog(@"controllerNumbers: %d", _controllerNumbers);

    for(VoidController* controller in _voidControllers.allValues){
        NSLog(@"controller obj in dict: %@", controller);
    }
    
    [self updateFinished:_oscController];
}

-(id)initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate
{
    self = [super init];
    
    NSLog(@"controller support init");
    
    _delegate = delegate;
    _controllerStreamLock = [[NSLock alloc] init];
    _voidControllers = [[NSMutableDictionary alloc] init];
    _activeGCControllers = [[NSMutableSet alloc] init];
    _physicalControllerComboCommandsBySource = [[NSMutableDictionary alloc] init];
    [self reloadPhysicalControllerComboMappings];
    _controllerNumbers = 0;
    
    _captureMouse = (streamConfig.localMousePointerMode == 0);
    if (@available(iOS 14.0, tvOS 14.0, *)) {
            for (GCMouse* mouse in [GCMouse mice]) {
                [self registerMouseCallbacks:mouse];
            }
        }
    
    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
    Log(LOG_I, @"Controller connected!");
    
    GCController* controller = note.object;
    
    if (![ControllerSupport isSupportedGamepad:controller]) {
        // Ignore micro gamepads and motion controllers
        return;
    }
    
    //[self->_activeGCControllers addObject:controller];
    VoidController* voidController = [self assignController:controller];
        if (voidController) {
            // Register callbacks on the new controller
            [self registerControllerCallbacks:controller];
            
            // Report the controller arrival to the host if we're connected
            [self reportControllerArrival:voidController];
            
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            if((self->_gyroMode == GyroModeAuto && [self externalControllersHaveGyro]) || self->_gyroMode == AlwaysController){
                [self stopTimerForController:self->_oscController];
                [self updateTimerStateForController:voidController];
            }
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
}];
    
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self unregisterControllerCallbacks:controller];
        
        if([self->_activeGCControllers containsObject:controller]){
            [self->_activeGCControllers removeObject:controller];
            self->_controllerNumbers &= ~(1 << controller.playerIndex);
        }
        Log(LOG_I, @"Unassigning controller index: %ld", (long)controller.playerIndex);
        
        VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
        if (voidController) {
            [self stopTimerForController:voidController];
            [self clearPhysicalControllerCombosForController:voidController];
            
            // Stop haptics on this controller
            [self cleanupControllerHaptics:voidController];
            
            // Stop motion reports on this controller
            [self cleanupControllerMotion:voidController];
            
            // Stop battery reports on this controller
            [self cleanupControllerBattery:voidController];
            
            // Disassociate this controller from any controllers merged with it
            if (voidController.mergedWithController) {
                if(voidController.mergedWithController.mergedWithController == voidController) voidController.mergedWithController.mergedWithController = nil;
            }
            
            // Inform the server of the updated active gamepads before removing this controller
            [self updateFinished:voidController];
            
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            
            [self->_voidControllers removeObjectForKey:@(controller.playerIndex)];
            
            if((self->_voidControllers.allValues.count == 0 || ![self externalControllersHaveGyro]) && self->_gyroMode == GyroModeAuto) [self updateTimerStateForController:self->_oscController];
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
    }];
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");
            
            GCMouse* mouse = note.object;
            
            // Register for mouse events
            [self registerMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");
            
            GCMouse* mouse = note.object;
            
            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        //for(Controller* controller in _controllers) [self updateTimerStateForController:controller];
    }
    

    
    _oscController = [[VoidController alloc] init];
    _gyroMode = AlwaysDevice;

    // Live-update gyro routing & sensitivity when the user touches Settings
    // mid-stream. Without this, mapGyroTo / sensitivity changes would only
    // take effect on next reconnect.
    __weak typeof(self) weakSelf = self;
    _gyroSettingsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:VoidGyroSettingsDidChangeNotification
                                                                              object:nil
                                                                               queue:[NSOperationQueue mainQueue]
                                                                          usingBlock:^(NSNotification * _Nonnull note) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        DataManager* dm = [[DataManager alloc] init];
        TemporarySettings* s = [dm getSettings];
        int previousMapGyroTo = strongSelf->_mapGyroTo;
        BOOL previousForceGyroOverrideSet = strongSelf.forceGyroOverrideSet;
        BOOL previousForceGyroEnabled = strongSelf.forceGyroEnabled;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        strongSelf->_gyroSensitivity = s.gyroSensitivity.floatValue;
        strongSelf->_mapGyroTo = s.mapGyroTo.intValue;
        strongSelf->_gyroInvertPitch = s.gyroInvertPitch;
        strongSelf->_gyroInvertYaw = s.gyroInvertYaw;
        strongSelf.forceGyroOverrideSet = [defaults objectForKey:@"forceGyroEnabled"] != nil;
        strongSelf.forceGyroEnabled = s.forceGyroEnabled;
        if (strongSelf.forceGyroOverrideSet && !strongSelf.forceGyroEnabled &&
            (!previousForceGyroOverrideSet || previousForceGyroEnabled)) {
            [strongSelf clearGyroOutputForAllControllers];
        }
        // Re-evaluate timer state if mapGyroTo flipped between needs/doesn't
        // need device gyro — otherwise the legacy snapshot path is enough.
        if (previousMapGyroTo != strongSelf->_mapGyroTo) {
            [strongSelf applyGyroModeSetting];
        }
    }];

    _physicalControllerComboSettingsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:PhysicalControllerComboDidChangeNotification
                                                                                                  object:nil
                                                                                                   queue:[NSOperationQueue mainQueue]
                                                                                              usingBlock:^(NSNotification * _Nonnull note) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reloadPhysicalControllerComboMappings];
        [strongSelf clearPhysicalControllerCombosForAllControllers];
    }];

    [self updateCommonConfig:streamConfig];
    
    for(VoidController* voidController in _voidControllers.allValues){
        NSLog(@"stop external controller timer %@", voidController);
        [self stopTimerForController:voidController];
    }
    [self updateTimerStateForController:_oscController];

    [self assignControllers];
    
    _shallDisableGyroHotSwitch = streamConfig.gyroMode == GyroModeOff && _voidControllers.allValues.count == 0;
    NSLog(@"shallDisableGyroHotSwitch %d", _shallDisableGyroHotSwitch);
    
    return self;
}

-(bool)externalControllersHaveGyro{
    for(VoidController* voidController in _voidControllers.allValues){
        if(voidController.hasGyroscope || voidController.hasAccelerometer) return true;
    }
    return false;
}


-(void)connectionEstablished {
    for (VoidController* voidController in _voidControllers.allValues) {
        [self updateFinished:voidController];
    }

    if (_oscEnabled) {
        [self setButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
        [self clearButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_gyroMode = self->_streamConfig.gyroMode;

        [self applyGyroModeSetting];
    });
}

// Client-side self-heal for a Sunshine host race after an unclean client exit
// (crash / force-kill). The zombie session's virtual gamepads are destroyed by
// a *deferred* task on the host, while their slot ids are released synchronously.
// The new session's controller arrival can therefore allocate the same id right
// before the deferred destroy runs, which silently kills the freshly created
// virtual pad — but the host still marks the slot allocated, so every later
// arrival is rejected and the legacy fallback allocation never triggers either.
// Result: all gamepad/OSC input for the whole session goes into a black hole
// while keyboard/mouse (no virtual device) keep working.
//
// Recovery is protocol-level: sending a controller event whose activeGamepadMask
// clears this slot's bit makes the host free the (dead) pad and reset the slot,
// and a re-sent arrival then allocates a brand-new device. Packets for one
// controller travel on a single reliable ENet channel, so the
// free -> arrival -> full-mask sequence cannot be reordered.
-(void) reattachGamepadsAfterDirtySession
{
    // Two cycles: shortly after connect (covers the host tearing the zombie
    // down at session takeover) and later (covers the zombie only dying by
    // ENet peer timeout, whose deferred cleanup can strike a second time).
    __weak typeof(self) weakSelf = self;
    NSUInteger epoch = _reattachEpoch;
    for (NSNumber* delay in @[@3.0, @13.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_reattachEpoch != epoch) {
                return;  // session ended or was replaced before we fired
            }
            [strongSelf performGamepadReattachCycle];
        });
    }
}

-(void) performGamepadReattachCycle
{
    [_controllerStreamLock lock];

    uint16_t fullMask = [self getActiveGamepadMask];
    NSMutableArray<VoidController*>* targets = [NSMutableArray array];
    if (_oscEnabled && _oscController != nil) {
        [targets addObject:_oscController];
    }
    [targets addObjectsFromArray:_voidControllers.allValues];

    NSMutableSet<NSNumber*>* handledPlayerIndexes = [NSMutableSet set];
    for (VoidController* voidController in targets) {
        short playerIndex = _multiController ? voidController.playerIndex : 0;
        if ([handledPlayerIndexes containsObject:@(playerIndex)]) {
            continue;  // merged OSC + physical share a slot; reattach it once
        }
        [handledPlayerIndexes addObject:@(playerIndex)];

        @synchronized(voidController) {
            // Detach: host frees this slot even if its device is already dead.
            LiSendMultiControllerEvent(playerIndex, fullMask & ~(1 << playerIndex),
                                       0, 0, 0, 0, 0, 0, 0);
            // Re-attach: force a fresh arrival so the host allocates a new pad.
            [self cleanupControllerBattery:voidController];
            voidController.batteryTimer = nil;
            voidController.reportedArrival = NO;
            BOOL reported = [self reportControllerArrival:voidController];
            NSLog(@"[InputDiag] gamepad reattach player=%d arrival=%@ mask=0x%X",
                  playerIndex, reported ? @"ok" : @"deferred", fullMask);
        }
    }

    [_controllerStreamLock unlock];
}

-(void)stopTimerForController:(VoidController* )voidController{
    [self resetGyroInputForController:voidController];
    if (@available(iOS 14.0, *)) {
        //NSLog(@"stop controller obj: %@, hasAcc %d, hasGyro %d", voidController, voidController.hasAccelerometer, voidController.hasGyroscope);
        // Invalidate unconditionally. The hasAccelerometer/hasGyroscope flags are
        // toggled asynchronously by the timer-setup blocks and by setMotionEventState,
        // so gating invalidation on them left a window where a live timer was skipped
        // here and became an orphan — running forever on the main runloop, flooding the
        // input stream every tick and stuttering/overriding real input until force-quit.
        [voidController.accelTimer invalidate];
        voidController.accelTimer = nil;
        [voidController.gyroTimer invalidate];
        voidController.gyroTimer = nil;
        // Device gyro is callback-driven now: removing the Core Motion handler
        // is the actual stop (also breaks the manager→handler retain path).
        // No-op for gamepad controllers whose motionManager is nil.
        [voidController.motionManager stopDeviceMotionUpdates];
    }
    // Clear any leftover gyro-synthesized stick contribution so subsequent
    // physical-stick / button updateFinished calls don't keep blending in
    // a stale value (would manifest as "stick stuck slightly off-center"
    // after disabling the gyro mid-stream).
    if (voidController.gyroStickX != 0 || voidController.gyroStickY != 0) {
        @synchronized(voidController) {
            voidController.gyroStickX = 0;
            voidController.gyroStickY = 0;
        }
        [self updateFinished:voidController];
    }
}

- (void)applyGyroModeSetting {
    // Stop all timers to ensure a clean slate before applying the new setting.
    [self stopTimerForAllControllers];

    // RightStick / Mouse mapping needs device-gyro samples regardless of the
    // legacy GyroMode dropdown (which only governs the DS4 motion path).
    BOOL needDeviceGyroForMapping = (_mapGyroTo == MapGyroToRightStick || _mapGyroTo == MapGyroToMouse);

    switch(_gyroMode) {
        case AlwaysController:
            // Activate timers only for physical controllers.
            for (VoidController* voidController in _voidControllers.allValues) {
                [self updateTimerStateForController:voidController];
            }
            // Even with AlwaysController, the user may want device gyro for stick mapping.
            if (needDeviceGyroForMapping) [self updateTimerStateForController:self->_oscController];
            break;

        case GyroModeAuto:
            // Prefer physical controller gyros if they exist.
            if ([self externalControllersHaveGyro]) {
                for (VoidController* voidController in _voidControllers.allValues) {
                    [self updateTimerStateForController:voidController];
                }
                if (needDeviceGyroForMapping) [self updateTimerStateForController:self->_oscController];
            } else {
                // Otherwise, fall back to the device gyro.
                [self updateTimerStateForController:self->_oscController];
            }
            break;

        case AlwaysDevice:
            // Always start the device gyro in this mode.
            [self updateTimerStateForController:self->_oscController];
            break;

        case GyroModeOff:
            // Legacy: nothing. New: still spin up device gyro if mapping needs it.
            if (needDeviceGyroForMapping) [self updateTimerStateForController:self->_oscController];
            break;
    }
}


-(void) cleanup
{
    _reattachEpoch++;
    // Snapshot the mask before _controllerNumbers is cleared below. The
    // zero-sweep at the end must carry the mask the host currently believes
    // in — with a cleared mask the events read as "these pads don't exist"
    // and the host ignores them instead of zeroing the latched sticks.
    uint16_t finalGamepadMask = [self getActiveGamepadMask];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
    if (_gyroSettingsObserver) [[NSNotificationCenter defaultCenter] removeObserver:_gyroSettingsObserver];
    if (_physicalControllerComboSettingsObserver) [[NSNotificationCenter defaultCenter] removeObserver:_physicalControllerComboSettingsObserver];
    
    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;
    _gyroSettingsObserver = nil;
    _physicalControllerComboSettingsObserver = nil;
    
    _controllerNumbers = 0;
    
    [self stopTimerForController:_oscController];
    for (VoidController* controller in [_voidControllers allValues]) {
        [self stopTimerForController:controller];
        [self cleanupControllerHaptics:controller];
        [self cleanupControllerMotion:controller];
        [self cleanupControllerBattery:controller];
    }

    // The host's virtual pad latches the last stick values it received; with
    // the host-side deadzone at 0, any residual (gyro tail, mid-drag rspad)
    // becomes endless character drift after the session. Zero everything now:
    // timers are already stopped so nothing can re-send, and the input stream
    // is still up (stopStream runs after cleanup returns). Harmless if the
    // connection is already gone — common-c drops events when uninitialized.
    _oscController.gyroStickX = 0;
    _oscController.gyroStickY = 0;
    for (VoidController* controller in [_voidControllers allValues]) {
        LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0, finalGamepadMask,
                                   0, 0, 0, 0, 0, 0, 0);
        // Also flatten any latched DS4 motion state (host-side gyro-to-stick
        // keeps integrating the last rotation rate it saw). Dropped by the
        // host if the pad reported no motion support.
        LiSendControllerMotionEvent((uint8_t)(_multiController ? controller.playerIndex : 0),
                                    LI_MOTION_TYPE_GYRO, 0, 0, 0);
    }
    LiSendMultiControllerEvent(0, finalGamepadMask, 0, 0, 0, 0, 0, 0, 0);
    LiSendControllerMotionEvent(0, LI_MOTION_TYPE_GYRO, 0, 0, 0);

    // The calls above only ENQUEUE packets; common-c's input send thread
    // transmits them, and LiStopConnection (stopStream runs right after
    // cleanup returns) destroys the queue with whatever is still in it.
    // Give the sender a beat to drain before teardown proceeds.
    usleep(50 * 1000);

    [_voidControllers removeAllObjects];
    
    #if !TARGET_OS_TV
        [self cleanupControllerMotion:_oscController];
        [_oscController.motionManager stopDeviceMotionUpdates];
    #endif
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
}

@end
