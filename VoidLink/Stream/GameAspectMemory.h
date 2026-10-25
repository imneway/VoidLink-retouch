//
//  GameAspectMemory.h
//  VoidLink
//
//  Per-process memory of how a game uses the iPad-shaped host display, keyed
//  by the exe name the host agent reports. A game that draws over the area a
//  16:9 letterbox would leave black is a full-display game: once that has
//  been seen often enough, its cutscene bars no longer snap the picture to
//  16:9. A tap on the ratio button while the game is on top is remembered for
//  that process too and wins over anything learned. Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted (main thread) after clearAll, so a live stream re-resolves its ratio.
extern NSNotificationName const GameAspectMemoryDidClearNotification;

@interface GameAspectMemory : NSObject

@property (class, nonatomic, readonly) GameAspectMemory *shared;

// Learned: the process was seen drawing into the 16:9 bar area often enough.
- (BOOL)isLearnedFullForProcess:(NSString *)process;
// Learned: the process kept its picture inside the 16:9 region for long
// enough. Tentative: one sighting of content in the bar area drops it.
- (BOOL)isLearnedSixteenNineForProcess:(NSString *)process;
- (void)setLearnedSixteenNineForProcess:(NSString *)process;
// The user's ratio choice for this process: @YES = 16:9, @NO = FULL, nil = none.
- (nullable NSNumber *)manualFitsForProcess:(NSString *)process;
- (void)setManualFits:(BOOL)fits forProcess:(NSString *)process;

// One sustained sighting of content in the bar area. Sightings closer than
// the minimum spacing to the previous one are ignored. Returns YES when this
// sighting made the process count as full-display. *count gets the number of
// sightings recorded so far.
- (BOOL)recordContentInBarsForProcess:(NSString *)process count:(NSUInteger *_Nullable)count;

// Forget everything (settings sidebar).
- (void)clearAll;

@end

NS_ASSUME_NONNULL_END
