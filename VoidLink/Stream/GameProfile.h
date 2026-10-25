//
//  GameProfile.h
//  VoidLink
//
//  Per-game behaviour on the iPad, keyed by the exe name the host agent
//  reports for the game on top. Generic behaviour stays generic; a profile
//  only adds what a particular game needs (Baldur's Gate 3 mixes gamepad and
//  mouse play, so it gets the touch block, pencil -> DESK and input-device
//  nudges). Lookup is case-insensitive.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GameNudgeKind) {
    GameNudgeNone = 0,
    GameNudgeMouseMiddleClick,   // a mouse button the game ignores: flips it to KB&M
    GameNudgeKeyboardKey,        // a key the game ignores (nudgeKeyCode): flips it to KB&M
    GameNudgeGamepadL3,          // a gamepad button the game ignores: flips it to controller
};

@interface GameProfile : NSObject

@property (nonatomic, readonly, copy) NSString *name;
// Block finger touches from the stream while the OSC is up, whatever the
// sidebar switch says.
@property (nonatomic, readonly) BOOL forceTouchBlock;
// A pencil contact on the stream in GAME mode switches to DESK.
@property (nonatomic, readonly) BOOL pencilSwitchesToDesk;
// Sent after the bottom-left corner switches to DESK / GAME, so a game that
// styles its UI after the last input device follows the switch.
@property (nonatomic, readonly) GameNudgeKind deskNudge;
@property (nonatomic, readonly) GameNudgeKind gameNudge;
// Windows virtual-key code for GameNudgeKeyboardKey.
@property (nonatomic, readonly) uint16_t nudgeKeyCode;
// The right-edge swipe does what the bottom-left corner does (DESK <-> GAME)
// instead of toggling the OSC's visibility.
@property (nonatomic, readonly) BOOL edgeSwipeSwitchesMode;
// The pencil's double tap (host touch keyboard) is ignored.
@property (nonatomic, readonly) BOOL pencilDoubleTapDisabled;

+ (nullable GameProfile *)profileForProcess:(nullable NSString *)process;

@end

NS_ASSUME_NONNULL_END
