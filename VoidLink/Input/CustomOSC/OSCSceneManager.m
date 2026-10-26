//
//  OSCSceneManager.m
//  VoidLink
//

#import "OSCSceneManager.h"
#import "OSCProfile.h"
#import "OnScreenButtonState.h"
#import "LocalizationHelper.h"

NSString * const OSCSceneBindingsDidChangeNotification = @"OSCSceneBindingsDidChangeNotification";

static NSString * const kScenePortraitKey = @"OSCScenePortraitProfile";
static NSString * const kSceneLandscapeKey = @"OSCSceneLandscapeProfile";
static NSString * const kSceneFullGameKey = @"OSCSceneFullGameProfile";
static NSString * const kSceneMigrationKey = @"OSCSceneMigrationV1";

// Old per-orientation lock keys (pre-scene builds).
static NSString * const kLegacyPortraitLockKey = @"OSCLockedPortraitProfileName";
static NSString * const kLegacyLandscapeLockKey = @"OSCLockedLandscapeProfileName";
static NSString * const kLegacyLandscapeFullLockKey = @"OSCLockedLandscapeFullProfileName";

static NSString * const kDefaultProfileName = @"Default";

@implementation OSCSceneManager

+ (NSString *)keyForScene:(OSCScene)scene {
    switch (scene) {
        case OSCScenePortrait: return kScenePortraitKey;
        case OSCSceneLandscape: return kSceneLandscapeKey;
        case OSCSceneLandscapeFullGame: return kSceneFullGameKey;
    }
    return kSceneLandscapeKey;
}

+ (BOOL)isTemplateName:(NSString *)name {
    return [name isEqualToString:kDefaultProfileName]
        || [name isEqualToString:DEFAULT_TEMPLATE_NAME1]
        || [name isEqualToString:DEFAULT_TEMPLATE_NAME2];
}

+ (void)migrateIfNeeded {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kSceneMigrationKey]) return;

    NSString *portraitLock = [ud stringForKey:kLegacyPortraitLockKey];
    NSString *landscapeLock = [ud stringForKey:kLegacyLandscapeLockKey];
    NSString *fullLock = [ud stringForKey:kLegacyLandscapeFullLockKey];

    // Before scenes, an unlocked orientation showed whatever layout was "selected".
    // Carry that over so the user keeps seeing the same layout after the update.
    NSString *selected = [self selectedProfileNameFromStorage];
    if (selected.length > 0 && [self isTemplateName:selected] && ![selected isEqualToString:kDefaultProfileName]) {
        selected = nil;   // a bare widget template was never a real layout choice
    }

    NSString *portrait = portraitLock.length > 0 ? portraitLock : selected;
    NSString *landscape = landscapeLock.length > 0 ? landscapeLock : selected;

    if (portrait.length > 0) [ud setObject:portrait forKey:kScenePortraitKey];
    if (landscape.length > 0) [ud setObject:landscape forKey:kSceneLandscapeKey];
    if (fullLock.length > 0) [ud setObject:fullLock forKey:kSceneFullGameKey];

    [ud removeObjectForKey:kLegacyPortraitLockKey];
    [ud removeObjectForKey:kLegacyLandscapeLockKey];
    [ud removeObjectForKey:kLegacyLandscapeFullLockKey];
    [ud setBool:YES forKey:kSceneMigrationKey];
}

// Read the selected profile name straight from the archived profile list, so the
// migration does not depend on OSCProfilesManager being initialised with a bounds.
+ (nullable NSString *)selectedProfileNameFromStorage {
    NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"OSCProfiles"];
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSError *err = nil;
    NSSet *classes = [NSSet setWithObjects:[NSString class], [NSMutableData class], [NSMutableArray class], [OSCProfile class], [OnScreenButtonState class], nil];
    NSArray *encoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&err];
    if (![encoded isKindOfClass:[NSArray class]]) return nil;
    for (NSData *d in encoded) {
        if (![d isKindOfClass:[NSData class]]) continue;
        OSCProfile *p = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:d error:nil];
        if ([p isKindOfClass:[OSCProfile class]] && p.isSelected) return p.name;
    }
    return nil;
}

+ (nullable NSString *)boundProfileNameForScene:(OSCScene)scene {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:[self keyForScene:scene]];
    return v.length > 0 ? v : nil;
}

+ (void)bindProfileName:(nullable NSString *)name toScene:(OSCScene)scene {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *key = [self keyForScene:scene];
    NSString *old = [ud stringForKey:key];
    if ((old.length == 0 && name.length == 0) || (old && name && [old isEqualToString:name])) return;
    if (name.length > 0) [ud setObject:name forKey:key];
    else [ud removeObjectForKey:key];
    [self postChange];
}

+ (void)postChange {
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OSCSceneBindingsDidChangeNotification object:nil];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

+ (NSString *)resolvedProfileNameForScene:(OSCScene)scene existingNames:(NSArray<NSString *> *)names {
    NSString *bound = [self boundProfileNameForScene:scene];
    if (bound.length > 0 && [names containsObject:bound]) return bound;
    if (scene == OSCSceneLandscapeFullGame) {
        // Unbound (or dangling) full-game scene follows the landscape scene.
        return [self resolvedProfileNameForScene:OSCSceneLandscape existingNames:names];
    }
    return kDefaultProfileName;
}

+ (NSArray<NSNumber *> *)scenesBoundToProfileName:(NSString *)name {
    if (name.length == 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger s = 0; s < OSCSceneCount; s++) {
        NSString *bound = [self boundProfileNameForScene:(OSCScene)s];
        if (bound && [bound isEqualToString:name]) [out addObject:@(s)];
    }
    return out;
}

+ (void)noteProfileRenamedFrom:(NSString *)oldName to:(NSString *)newName {
    if (oldName.length == 0 || newName.length == 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL changed = NO;
    for (NSInteger s = 0; s < OSCSceneCount; s++) {
        NSString *key = [self keyForScene:(OSCScene)s];
        if ([[ud stringForKey:key] isEqualToString:oldName]) {
            [ud setObject:newName forKey:key];
            changed = YES;
        }
    }
    if (changed) [self postChange];
}

+ (void)noteProfileDeleted:(NSString *)name {
    if (name.length == 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL changed = NO;
    for (NSInteger s = 0; s < OSCSceneCount; s++) {
        NSString *key = [self keyForScene:(OSCScene)s];
        if ([[ud stringForKey:key] isEqualToString:name]) {
            [ud removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) [self postChange];
}

+ (NSString *)localizedNameForScene:(OSCScene)scene {
    switch (scene) {
        case OSCScenePortrait: return [LocalizationHelper localizedStringForKey:@"Scene portrait"];
        case OSCSceneLandscape: return [LocalizationHelper localizedStringForKey:@"Scene landscape"];
        case OSCSceneLandscapeFullGame: return [LocalizationHelper localizedStringForKey:@"Scene full-screen game"];
    }
    return @"";
}

+ (NSString *)shortLocalizedNameForScene:(OSCScene)scene {
    switch (scene) {
        case OSCScenePortrait: return [LocalizationHelper localizedStringForKey:@"Scene short portrait"];
        case OSCSceneLandscape: return [LocalizationHelper localizedStringForKey:@"Scene short landscape"];
        case OSCSceneLandscapeFullGame: return [LocalizationHelper localizedStringForKey:@"Scene short full-screen game"];
    }
    return @"";
}

@end
