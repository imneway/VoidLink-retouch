//
//  TemporarySettings.h
//  Moonlight
//
//  Created by Cameron Gutman on 12/1/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.1
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "Settings+CoreDataClass.h"
#define OSC_TOOL_FINGERS 4


@interface TemporarySettings : NSObject

@property (nonatomic, retain) Settings * parent;

@property (nonatomic, retain) NSNumber * settingsMenuMode;
@property (nonatomic, retain) NSNumber * settingsMenuWidth;
@property (nonatomic, retain) NSNumber * bitrate;
@property (nonatomic, retain) NSNumber * framerate;
@property (nonatomic, retain) NSNumber * height;
@property (nonatomic, retain) NSNumber * width;
@property (nonatomic, retain) NSNumber * audioConfig;
@property (nonatomic, retain) NSNumber * onscreenControls;
@property (nonatomic, retain) NSNumber * gyroMode;
@property (nonatomic, retain) NSNumber * keyboardToggleFingers;
@property (nonatomic, retain) NSNumber * oscLayoutToolFingers;
@property (nonatomic, retain) NSNumber * slideToSettingsScreenEdge;
@property (nonatomic, retain) NSNumber * slideToSettingsDistance;
@property (nonatomic, retain) NSNumber * touchMoveEventInterval;
@property (nonatomic, retain) NSNumber * touchPointerVelocityFactor;
@property (nonatomic, retain) NSNumber * gyroSensitivity;
// Where iPad gyroscope sensor data is routed; see MapGyroTo enum.
// Stored in NSUserDefaults under @"mapGyroTo".
@property (nonatomic, retain) NSNumber * mapGyroTo;
// Per-axis gyro direction flips (apply only when mapGyroTo != Motion).
// Stored in NSUserDefaults under @"gyroInvertPitch" / @"gyroInvertYaw".
@property (nonatomic, assign) BOOL gyroInvertPitch;
@property (nonatomic, assign) BOOL gyroInvertYaw;
// Persistent stream-view toggle state. ControllerSupport treats an explicitly
// stored YES as global ON and an explicitly stored NO as passive legacy OFF;
// explicit GYRO widgets can still activate gyro. If the key has never been
// stored, legacy/widget gyro rules still apply.
// Stored in NSUserDefaults under @"forceGyroEnabled".
@property (nonatomic, assign) BOOL forceGyroEnabled;
@property (nonatomic, retain) NSNumber * emulatedControllerType;
@property (nonatomic, retain) NSNumber * mousePointerVelocityFactor;
@property (nonatomic, retain) NSNumber * pointerVelocityModeDivider;
@property (nonatomic, retain) NSString * uniqueId;
@property (nonatomic, retain) NSNumber * resolutionSelected;
@property (nonatomic, retain) NSNumber * externalDisplayMode;
@property (nonatomic, retain) NSNumber * localMousePointerMode;
@property (nonatomic, retain) NSNumber * backgroundSessionTimer;
@property (nonatomic) enum {
    CODEC_PREF_AUTO,
    CODEC_PREF_H264,
    CODEC_PREF_HEVC,
    CODEC_PREF_AV1,
} preferredCodec;
@property (nonatomic) BOOL enableYUV444;
@property (nonatomic) BOOL enablePIP;
@property (nonatomic) BOOL reverseMouseWheelDirection;
@property (nonatomic, retain) NSNumber * asyncNativeTouchPriority;
@property (nonatomic) BOOL multiController;
@property (nonatomic) BOOL swapABXYButtons;
@property (nonatomic) BOOL playAudioOnPC;
@property (nonatomic) BOOL optimizeGames;
@property (nonatomic) BOOL enableHdr;
@property (nonatomic) BOOL btMouseSupport;
// @property (nonatomic) BOOL absoluteTouchMode;
@property (nonatomic, retain) NSNumber * touchMode;
@property (nonatomic, retain) NSNumber * statsOverlayLevel;
@property (nonatomic) BOOL statsOverlayEnabled;
@property (nonatomic) BOOL liftStreamViewForKeyboard;
@property (nonatomic) BOOL showKeyboardToolbar;
@property (nonatomic) BOOL unlockDisplayOrientation;
@property (nonatomic) BOOL enableGraphs;
@property (nonatomic, retain) NSNumber * frameQueueSize;
@property (nonatomic, retain) NSNumber * graphOpacity;
@property (nonatomic, retain) NSNumber * renderingBackend;
@property (nonatomic, retain) NSNumber * framePacingMode;

// UI: 将串流画面上移并顶到更靠近屏幕顶部
@property (nonatomic) BOOL snapScreenToTop;          // 是否开启
@property (nonatomic, retain) NSNumber * snapScreenRatioMode; // 0: 16:9, 1: Full Screen

- (id) initFromSettings:(Settings*)settings;

@end
