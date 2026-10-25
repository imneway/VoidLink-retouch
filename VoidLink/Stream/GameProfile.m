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
        bg3.deskNudge = GameNudgeMouseMiddleClick;
        bg3.gameNudge = GameNudgeGamepadL3;
        table = @{ @"bg3.exe": bg3, @"bg3_dx11.exe": bg3 };
    });
    return table;
}

+ (GameProfile *)profileForProcess:(NSString *)process {
    if (process.length == 0) return nil;
    return [self table][process.lowercaseString];
}

@end
