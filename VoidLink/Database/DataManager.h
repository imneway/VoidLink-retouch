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

// Apple Pencil Pro barrel roll while hovering (NSUserDefaults @"pencilRollMode").
typedef NS_ENUM(NSInteger, PencilRollMode) {
    PencilRollModeOff = 0,
    PencilRollModeArrowKeys = 1, // one Up/Down key per step
    PencilRollModeWheel = 2,     // one wheel notch per step
};
// Pencil tuning (NSUserDefaults @"pencilScrollSpeed" / @"pencilRollStep").
#define PencilScrollSpeedDefault 16.0f  // wheel units per point, 120 = one notch
#define PencilScrollSpeedMin 4.0f
#define PencilScrollSpeedMax 48.0f
#define PencilRollStepDefault 30.0f     // degrees per step
#define PencilRollStepMin 10.0f
#define PencilRollStepMax 90.0f
// Squeeze scroll, continuous zone: beyond this many points from where the
// squeeze started the scroll runs on its own, up to this many notches per
// second at the far end of a 200pt ramp. NSUserDefaults @"pencilScrollZoneRadius" / @"pencilScrollMaxRate".
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
