//
//  GameProfile.m
//  VoidLink
//

#import "GameProfile.h"

@interface GameProfile ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL forceTouchBlock;
@property (nonatomic) BOOL pencilSwitchesToDesk;
@property (nonatomic) GameNudgeKind deskNudge;
@property (nonatomic) GameNudgeKind gameNudge;
@property (nonatomic) uint16_t nudgeKeyCode;
@property (nonatomic) BOOL edgeSwipeSwitchesMode;
@property (nonatomic) BOOL pencilDoubleTapDisabled;
@end

@implementation GameProfile

+ (NSDictionary<NSString *, GameProfile *> *)table {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Baldur's Gate 3: bg3_dx11.exe (DirectX 11) or bg3.exe (Vulkan).
        GameProfile *bg3 = [[GameProfile alloc] init];
        bg3.name = @"Baldur's Gate 3";
        bg3.forceTouchBlock = YES;
        bg3.pencilSwitchesToDesk = YES;
        // Towards KB&M a key, not a mouse button: right after a load the game
        // kept ignoring the middle click. F16: unbound in the game and in the
        // host's AutoHotkey script (which takes F13 and F17-F19).
        bg3.deskNudge = GameNudgeKeyboardKey;
        bg3.nudgeKeyCode = 0x7F;   // VK_F16
        bg3.gameNudge = GameNudgeGamepadL3;
        bg3.edgeSwipeSwitchesMode = YES;
        bg3.pencilDoubleTapDisabled = YES;
        table = @{ @"bg3.exe": bg3, @"bg3_dx11.exe": bg3 };
    });
    return table;
}

+ (GameProfile *)profileForProcess:(NSString *)process {
    if (process.length == 0) return nil;
    return [self table][process.lowercaseString];
}

@end
