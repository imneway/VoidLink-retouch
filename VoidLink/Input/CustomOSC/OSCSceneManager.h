//
//  OSCSceneManager.h
//  VoidLink
//
//  Scenes replace the old per-orientation "locks". Each scene points at a layout
//  (OSC profile) by name; the stream picks the scene from the current state
//  (portrait / landscape / landscape while a full-display game is on) and shows
//  the layout bound to it. Bindings are never cleared automatically: a binding
//  that points at a missing layout simply resolves to the Default layout until
//  the user rebinds it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OSCScene) {
    OSCScenePortrait = 0,
    OSCSceneLandscape = 1,
    OSCSceneLandscapeFullGame = 2,
};

static const NSInteger OSCSceneCount = 3;

/// Posted (main thread) whenever a scene binding changes. object = nil.
extern NSString * const OSCSceneBindingsDidChangeNotification;

@interface OSCSceneManager : NSObject

/// One-time migration from the old lock keys / selected profile. Safe to call often.
+ (void)migrateIfNeeded;

/// Raw binding: the layout name stored for the scene, or nil when unset.
/// For the full-game scene nil means "same as landscape".
+ (nullable NSString *)boundProfileNameForScene:(OSCScene)scene;

/// Bind a layout to a scene (nil unbinds). Posts OSCSceneBindingsDidChangeNotification.
+ (void)bindProfileName:(nullable NSString *)name toScene:(OSCScene)scene;

/// The layout the scene should actually show: the bound layout when it exists,
/// the landscape layout for an unbound full-game scene, else "Default".
+ (NSString *)resolvedProfileNameForScene:(OSCScene)scene existingNames:(NSArray<NSString *> *)names;

/// Scenes whose raw binding names this layout (for list badges).
+ (NSArray<NSNumber *> *)scenesBoundToProfileName:(NSString *)name;

/// Keep bindings pointing at a layout that was renamed.
+ (void)noteProfileRenamedFrom:(NSString *)oldName to:(NSString *)newName;

/// Drop bindings pointing at a deleted layout (they then resolve to Default).
+ (void)noteProfileDeleted:(NSString *)name;

+ (NSString *)localizedNameForScene:(OSCScene)scene;
+ (NSString *)shortLocalizedNameForScene:(OSCScene)scene;

@end

NS_ASSUME_NONNULL_END
