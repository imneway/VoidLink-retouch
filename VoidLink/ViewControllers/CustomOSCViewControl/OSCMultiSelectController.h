//
//  OSCMultiSelectController.h
//  VoidLink
//
//  Multi-select mode for the OSC layout editor: tap to pick several controls
//  (custom widgets and legacy OSC layers), then nudge / place / align them as a
//  group from a floating move bar. Owns its own UI and selection state; the
//  editor VC only enters/exits it and routes undo to it.
//

#import <UIKit/UIKit.h>

@class LayoutOnScreenControlsViewController;

NS_ASSUME_NONNULL_BEGIN

/// "→ 10  ↑ 5" style offset text (screen y grows downward, so arrows read
/// unambiguously). Axes under half a point are omitted; returns "" when both are.
NSString *OSCOffsetDescription(CGPoint offset);

@interface OSCMultiSelectController : NSObject

- (instancetype)initWithEditor:(LayoutOnScreenControlsViewController *)editor;

@property (nonatomic, readonly) BOOL active;

/// Called after entering and after exiting, so the editor can swap its own chrome.
@property (nonatomic, copy, nullable) void (^activeChanged)(BOOL active);

- (void)enter;
/// Leave multi-select. restore = YES puts every control back where it was on entry.
- (void)exitRestoring:(BOOL)restore;

/// Re-place the move bar after the editor's bounds change.
- (void)layoutForBoundsChange;

/// Batch-move undo. `legacyChangeCount` is layoutOSC.layoutChanges.count now; a
/// legacy drag made after the last batch is newer and must be undone first.
- (BOOL)canUndoBatchWithLegacyChangeCount:(NSUInteger)legacyChangeCount;
- (BOOL)hasBatchHistory;
- (void)undoLastBatch;
/// Drop batch history (profile reload / rebuild replaces the objects it refers to).
- (void)clearHistory;

@end

NS_ASSUME_NONNULL_END
