//
//  DataManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/28/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.1
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "AppDelegate.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "TemporarySettings.h"

@interface DataManager : NSObject

typedef NS_ENUM(NSUInteger, UINavigationBarHeight) {
    UINavigationBarHeightIPad = 50,
    UINavigationBarHeightIPhone = 44
};

typedef NS_ENUM(NSInteger, TouchMode) {
    RelativeTouch,
    NativeTouch,
    AbsoluteTouch,
    NativeTouchOnly
};

// What a stationary Apple Pencil contact becomes (NSUserDefaults @"pencilHoldMode").
// Off: the left button goes down on contact (hold = left hold). Otherwise the
// press is withheld until the contact declares itself: move = left drag,
// lift = left click, and a contact that stays put is
//   LongPress:          right button after pencilHoldDelay
//   LongPressHardPress: right button after pencilHoldDelay, or at once when
//                       pressed past pencilHardPressThreshold
//   HardPressOnly:      right button only when pressed hard; after the delay
//                       a light hold is a held LEFT button
typedef NS_ENUM(NSInteger, PencilHoldMode) {
    PencilHoldModeOff = 0,
    PencilHoldModeLongPress = 1,
    PencilHoldModeLongPressHardPress = 2,
    PencilHoldModeHardPressOnly = 3,
};
#define PencilHoldDelayDefault 500.0f   // ms
#define PencilHoldDelayMin 300.0f
#define PencilHoldDelayMax 1000.0f
#define PencilHardPressThresholdDefault 65.0f // % of maximumPossibleForce
#define PencilHardPressThresholdMin 40.0f
#define PencilHardPressThresholdMax 90.0f
// Palm rejection (NSUserDefaults @"palmRejection" / @"palmRadiusThreshold").
// A direct touch is a palm when the pencil tip is on the glass, or when its
// majorRadius reaches the threshold (x1 while the pencil hovers, x1.5 without
// a pencil in range, since then a wide fingertip is the only other candidate).
#define PalmRadiusThresholdDefault 40.0f // pt; fingertips measure 10–25
#define PalmRadiusThresholdMin 25.0f
#define PalmRadiusThresholdMax 80.0f
// Pencil tuning (NSUserDefaults keys below).
// Squeeze scroll is quantized to whole wheel notches (one notch = what every
// app treats as a wheel click, with a haptic tick): this many points of hover
// travel per notch. NSUserDefaults @"pencilScrollPointsPerNotch".
#define PencilScrollPointsPerNotchDefault 8.0f
#define PencilScrollPointsPerNotchMin 3.0f
#define PencilScrollPointsPerNotchMax 30.0f
// Squeeze scroll, continuous zone: beyond this many points from the zone
// centre the scroll runs on its own, up to this many notches per second at
// the far end of a 120pt ramp. Pulling back inside re-centres the zone. NSUserDefaults @"pencilScrollZoneRadius" / @"pencilScrollMaxRate".
#define PencilScrollZoneRadiusDefault 100.0f
#define PencilScrollZoneRadiusMin 40.0f
#define PencilScrollZoneRadiusMax 300.0f
#define PencilScrollMaxRateDefault 30.0f
#define PencilScrollMaxRateMin 5.0f
#define PencilScrollMaxRateMax 80.0f

typedef NS_ENUM(NSInteger, TouchEventPriorityEnum) {
    AsyncNativeTouchOff,
    EqualPriority,
    TouchDownPriority,// deprecated by GUI
    TouchMovePriority// deprecated by GUI
};

typedef NS_ENUM(NSInteger, GyroMode) {
    GyroModeOff,
    GyroModeAuto,
    AlwaysDevice,
    AlwaysController
};

// Where the device's gyroscope should be routed when active.
//   MapGyroToMotion (default) — host receives DS4-style controller motion
//                               events. Requires a game with native gyro support.
//   MapGyroToRightStick       — synthesize a right-thumbstick input on iPad,
//                               max-blended with physical stick. Works with
//                               any controller-input game (Switch emu, PC games).
//   MapGyroToMouse            — synthesize relative mouse motion. For PC games
//                               that aim with mouse, no gamepad needed.
//   MapGyroToOff              — disable all gyro emission regardless of GyroMode.
typedef NS_ENUM(NSInteger, MapGyroTo) {
    MapGyroToMotion,
    MapGyroToRightStick,
    MapGyroToMouse,
    MapGyroToOff
};

typedef NS_ENUM(NSInteger, FramePacingMode) {
    FramePacingModeOff,
    FramePacingModeLegacy,
    FramePacingModeQueue
};

typedef NS_ENUM(NSInteger, SettingsMenuMode) {
    AllSettings,
    FavoriteSettings,
    RemoveSettingItem,
};

- (void) saveSettingsWithBitrate:(NSInteger)bitrate
                       framerate:(NSInteger)framerate
                          height:(NSInteger)height
                           width:(NSInteger)width
                     audioConfig:(NSInteger)audioConfig
                onscreenControls:(NSInteger)onscreenControls
                        gyroMode:(NSInteger)gyroMode
          emulatedControllerType:(NSInteger)emulatedControllerType
           keyboardToggleFingers:(NSInteger)keyboardToggleFingers
            oscLayoutToolFingers:(NSInteger)oscLayoutToolFingers
       slideToSettingsScreenEdge:(NSInteger)slideToSettingsScreenEdge
         slideToSettingsDistance:(CGFloat)slideToSettingsDistance
      pointerVelocityModeDivider:(CGFloat)pointerVelocityModeDivider
      touchPointerVelocityFactor:(CGFloat)touchPointerVelocityFactor
      mousePointerVelocityFactor:(CGFloat)mousePointerVelocityFactor
                 gyroSensitivity:(CGFloat)gyroSensitivity
          touchMoveEventInterval:(NSInteger)touchMoveEventInterval
      reverseMouseWheelDirection:(BOOL)reverseMouseWheelDirection
                  asyncNativeTouchPriority:(NSInteger)asyncNativeTouchPriority
       liftStreamViewForKeyboard:(BOOL)liftStreamViewForKeyboard
             showKeyboardToolbar:(BOOL)showKeyboardToolbar
                   optimizeGames:(BOOL)optimizeGames
                 multiController:(BOOL)multiController
                    swapABButtons:(BOOL)swapABButtons
                    swapXYButtons:(BOOL)swapXYButtons
                   sendDummyEvent:(BOOL)sendDummyEvent
                       audioOnPC:(BOOL)audioOnPC
                  preferredCodec:(uint32_t)preferredCodec
                       enableYUV444:(BOOL)enableYUV444
                       enablePIP:(BOOL)enablePIP
                       enableHdr:(BOOL)enableHdr
                  btMouseSupport:(BOOL)btMouseSupport
               // absoluteTouchMode:(BOOL)absoluteTouchMode
                       touchMode:(NSInteger)touchMode
               statsOverlayLevel:(NSInteger)statsOverlayLevel
                    statsOverlayEnabled:(BOOL)statsOverlayEnabled
                   unlockDisplayOrientation:(BOOL)unlockDisplayOrientation
              resolutionSelected:(NSInteger)resolutionSelected
             externalDisplayMode:(NSInteger)externalDisplayMode
           localMousePointerMode:(NSInteger)localMousePointerMode
                  frameQueueSize:(NSInteger)frameQueueSize
                    enableGraphs:(BOOL)enableGraphs
                    graphOpacity:(NSInteger)graphOpacity
                renderingBackend:(NSInteger)renderingBackend
                framePacingMode:(NSInteger)framePacingMode
           backgroundSessionTimer:(NSInteger)backgroundSessionTimer;

- (NSArray*) getHosts;
- (void) updateHost:(TemporaryHost*)host;
- (void) updateAppsForExistingHost:(TemporaryHost *)host;
- (void) removeHost:(TemporaryHost*)host;
- (void) removeApp:(TemporaryApp*)app;
- (Settings*) retrieveSettings;
- (void) saveData;
- (TemporarySettings*) getSettings;

- (void) updateUniqueId:(NSString*)uniqueId;
- (NSString*) getUniqueId;

@end
