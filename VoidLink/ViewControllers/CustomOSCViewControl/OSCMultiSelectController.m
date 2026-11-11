//
//  OSCMultiSelectController.m
//  VoidLink
//

#import "OSCMultiSelectController.h"
#import "LayoutOnScreenControlsViewController.h"
#import "OnScreenButtonState.h"
#import "VoidLink-Swift.h"

NSString *OSCOffsetDescription(CGPoint offset) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    long dx = lround(offset.x), dy = lround(offset.y);
    if (dx != 0) [parts addObject:[NSString stringWithFormat:@"%@ %ld", dx > 0 ? @"→" : @"←", labs(dx)]];
    if (dy != 0) [parts addObject:[NSString stringWithFormat:@"%@ %ld", dy > 0 ? @"↓" : @"↑", labs(dy)]];
    return [parts componentsJoinedByString:@"  "];
}

typedef NS_ENUM(NSInteger, OSCAlignMode) {
    OSCAlignLeft, OSCAlignHCenter, OSCAlignRight,
    OSCAlignTop, OSCAlignVCenter, OSCAlignBottom,
    OSCDistributeH, OSCDistributeV,
};

static NSString * const kStepDefaultsKey = @"OSCMultiSelectStepIndex";
static const CGFloat kHighlightOutset = 4.0;

#pragma mark - Batch record

@interface OSCBatchMoveItem : NSObject
@property (nonatomic, strong) id target;            // OnScreenWidgetView or CALayer
@property (nonatomic) CGPoint oldPosition;
@property (nonatomic) CGPoint newPosition;
@property (nonatomic, strong, nullable) OnScreenButtonState *legacyState; // entry added to layoutOSC.layoutChanges
@property (nonatomic) NSUInteger widgetChangeCount; // widget.layoutChanges.count right after commit
@end
@implementation OSCBatchMoveItem
@end

@interface OSCBatchMove : NSObject
@property (nonatomic, copy) NSArray<OSCBatchMoveItem *> *items;
@property (nonatomic) NSUInteger legacyCountAfterCommit;
@end
@implementation OSCBatchMove
@end

#pragma mark -

@interface OSCMultiSelectController () <UIGestureRecognizerDelegate>
@end

@implementation OSCMultiSelectController {
    __weak LayoutOnScreenControlsViewController *_editor;

    NSMutableArray *_selection;                 // ordered, OnScreenWidgetView / CALayer
    NSMapTable<id, NSValue *> *_snapshot;       // positions on entry, for Cancel
    NSMutableArray<OSCBatchMove *> *_history;
    CGPoint _offsetBaseline;                    // group top-left when the selection last changed
    BOOL _hasBaseline;

    // editor chrome saved on entry
    BOOL _savedPanelHidden;
    CGFloat _savedToolbarAlpha;

    // UI
    UITapGestureRecognizer *_tap;
    CALayer *_highlightContainer;
    UIView *_bar;
    UIStackView *_outerStack, *_leftGroup, *_midGroup, *_topRow;
    UIButton *_cancelButton, *_selectAllButton, *_alignButton, *_doneButton;
    NSArray<UIButton *> *_arrowButtons;
    UIButton *_coordButton;
    UILabel *_offsetLabel;
    UISegmentedControl *_stepControl;
    BOOL _barCompact;
    BOOL _barPlaced;

    NSTimer *_repeatTimer;
    CGPoint _repeatDirection;
}

- (instancetype)initWithEditor:(LayoutOnScreenControlsViewController *)editor {
    if ((self = [super init])) {
        _editor = editor;
        _selection = [NSMutableArray array];
        _history = [NSMutableArray array];
    }
    return self;
}

- (UIView *)hostView { return _editor.view; }

#pragma mark - Items

- (NSArray<CALayer *> *)legacyCandidates {
    LayoutOnScreenControls *osc = _editor.layoutOSC;
    NSMutableArray *out = [NSMutableArray array];
    for (CALayer *l in @[osc._aButton ?: NSNull.null, osc._bButton ?: NSNull.null, osc._xButton ?: NSNull.null,
                         osc._yButton ?: NSNull.null, osc._l1Button ?: NSNull.null, osc._l2Button ?: NSNull.null,
                         osc._r1Button ?: NSNull.null, osc._r2Button ?: NSNull.null, osc._selectButton ?: NSNull.null,
                         osc._startButton ?: NSNull.null, osc._dPadBackground ?: NSNull.null,
                         osc._leftStickBackground ?: NSNull.null, osc._rightStickBackground ?: NSNull.null]) {
        if ((id)l == NSNull.null) continue;
        if (l.hidden || l.superlayer != self.hostView.layer || l.opacity <= 0.01) continue;
        [out addObject:l];
    }
    return out;
}

- (BOOL)isSelectableWidget:(OnScreenWidgetView *)w {
    return w.superview == self.hostView && !w.hidden && w.alpha > 0.01
        && w.widgetType != WidgetTypeEnumFullscreenTrigger;
}

- (NSArray *)allSelectableItems {
    NSMutableArray *items = [NSMutableArray array];
    for (UIView *v in self.hostView.subviews) {
        if ([v isKindOfClass:[OnScreenWidgetView class]] && [self isSelectableWidget:(OnScreenWidgetView *)v]) [items addObject:v];
    }
    [items addObjectsFromArray:[self legacyCandidates]];
    return items;
}

- (CGRect)frameOf:(id)item {
    if ([item isKindOfClass:[UIView class]]) return ((UIView *)item).frame;
    CALayer *l = item;
    return [l convertRect:l.bounds toLayer:self.hostView.layer];
}

- (CGPoint)positionOf:(id)item {
    if ([item isKindOfClass:[UIView class]]) return ((UIView *)item).center;
    return ((CALayer *)item).position;
}

- (void)setPosition:(CGPoint)p of:(id)item {
    if ([item isKindOfClass:[OnScreenWidgetView class]]) {
        OnScreenWidgetView *w = item;
        w.center = p;
        w.storedCenter = p; // resize re-anchors to storedCenter; keep it in step
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ((CALayer *)item).position = p;
        [CATransaction commit];
    }
}

- (CGRect)selectionBounds {
    CGRect r = CGRectNull;
    for (id item in _selection) r = CGRectUnion(r, [self frameOf:item]);
    return r;
}

#pragma mark - Enter / exit

- (void)enter {
    if (_active || !_editor) return;
    _active = YES;
    [_selection removeAllObjects];
    _hasBaseline = NO;

    _snapshot = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory | NSMapTableObjectPointerPersonality
                                      valueOptions:NSMapTableStrongMemory];
    for (id item in [self allSelectableItems]) {
        [_snapshot setObject:[NSValue valueWithCGPoint:[self positionOf:item]] forKey:item];
    }

    for (OnScreenWidgetView *w in _editor.onScreenWidgetViews) w.userInteractionEnabled = NO;

    _savedPanelHidden = _editor.widgetPanelStack.hidden;
    _editor.widgetPanelStack.hidden = YES;
    _savedToolbarAlpha = _editor.toolbarRootView.alpha;
    _editor.toolbarRootView.userInteractionEnabled = NO;
    _editor.toolbarRootView.alpha = 0.35;

    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    _tap.delegate = self;
    [self.hostView addGestureRecognizer:_tap];

    // Zero-size container: CALayer -hitTest: never descends into it, so the
    // highlights don't intercept our own hit testing.
    _highlightContainer = [CALayer layer];
    _highlightContainer.frame = CGRectZero;
    _highlightContainer.zPosition = 1000;
    [self.hostView.layer addSublayer:_highlightContainer];

    [self buildBarIfNeeded];
    _bar.layer.zPosition = 1001;
    [self.hostView addSubview:_bar];
    [self.hostView bringSubviewToFront:_bar];
    _barPlaced = NO;
    [self layoutForBoundsChange];

    [self refresh];
    if (self.activeChanged) self.activeChanged(YES);
}

- (void)exitRestoring:(BOOL)restore {
    if (!_active) return;
    [self stopRepeat];
    if (restore) {
        for (id item in _snapshot) {
            [self setPosition:[[_snapshot objectForKey:item] CGPointValue] of:item];
        }
    }
    [self teardown];
}

- (void)teardown {
    _active = NO;
    [_selection removeAllObjects];
    _snapshot = nil;

    for (OnScreenWidgetView *w in _editor.onScreenWidgetViews) w.userInteractionEnabled = YES;
    _editor.widgetPanelStack.hidden = _savedPanelHidden;
    _editor.toolbarRootView.userInteractionEnabled = YES;
    _editor.toolbarRootView.alpha = _savedToolbarAlpha > 0 ? _savedToolbarAlpha : 1.0;

    if (_tap) { [self.hostView removeGestureRecognizer:_tap]; _tap = nil; }
    [_highlightContainer removeFromSuperlayer];
    _highlightContainer = nil;
    [_bar removeFromSuperview];

    if (self.activeChanged) self.activeChanged(NO);
}

- (NSArray *)movedItems {
    NSMutableArray *moved = [NSMutableArray array];
    for (id item in _snapshot) {
        CGPoint old = [[_snapshot objectForKey:item] CGPointValue];
        CGPoint now = [self positionOf:item];
        if (fabs(old.x - now.x) > 0.01 || fabs(old.y - now.y) > 0.01) [moved addObject:item];
    }
    return moved;
}

- (void)cancelTapped {
    [self stopRepeat];
    if ([self movedItems].count == 0) { [self exitRestoring:YES]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃本次移动？"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self exitRestoring:YES];
    }]];
    [_editor presentViewController:alert animated:YES completion:nil];
}

- (void)doneTapped {
    [self stopRepeat];
    NSArray *moved = [self movedItems];
    if (moved.count > 0) {
        NSMutableArray<OSCBatchMoveItem *> *records = [NSMutableArray array];
        for (id item in moved) {
            OSCBatchMoveItem *rec = [OSCBatchMoveItem new];
            rec.target = item;
            rec.oldPosition = [[_snapshot objectForKey:item] CGPointValue];
            rec.newPosition = [self positionOf:item];
            if ([item isKindOfClass:[OnScreenWidgetView class]]) {
                OnScreenWidgetView *w = item;
                w.storedCenter = w.center;
                NSValue *last = w.layoutChanges.lastObject;
                if (!last || !CGPointEqualToPoint(last.CGPointValue, w.center)) {
                    w.layoutChanges = [w.layoutChanges arrayByAddingObject:[NSValue valueWithCGPoint:w.center]];
                }
                rec.widgetChangeCount = w.layoutChanges.count;
            } else {
                CALayer *l = item;
                OnScreenButtonState *state = [[OnScreenButtonState alloc] initWithButtonName:l.name
                                                                                 buttonType:LegacyOscButton
                                                                                andPosition:rec.oldPosition];
                state.isHidden = l.hidden;
                [_editor.layoutOSC.layoutChanges addObject:state];
                rec.legacyState = state;
            }
            [records addObject:rec];
        }
        OSCBatchMove *batch = [OSCBatchMove new];
        batch.items = records;
        batch.legacyCountAfterCommit = _editor.layoutOSC.layoutChanges.count;
        [_history addObject:batch];
    }
    [self teardown];
    if (moved.count > 0) _editor.undoButton.alpha = 1.0;
}

#pragma mark - Undo

- (BOOL)hasBatchHistory { return _history.count > 0; }

- (BOOL)canUndoBatchWithLegacyChangeCount:(NSUInteger)legacyChangeCount {
    OSCBatchMove *last = _history.lastObject;
    if (last == nil || legacyChangeCount > last.legacyCountAfterCommit) return NO;
    // A widget dragged or undone on its own since the batch has newer history;
    // that has to be unwound first or position and history would disagree.
    for (OSCBatchMoveItem *rec in last.items) {
        if (![rec.target isKindOfClass:[OnScreenWidgetView class]]) continue;
        OnScreenWidgetView *w = rec.target;
        NSValue *tail = w.layoutChanges.lastObject;
        if (w.layoutChanges.count != rec.widgetChangeCount || !tail || !CGPointEqualToPoint(tail.CGPointValue, rec.newPosition)) return NO;
    }
    return YES;
}

- (void)undoLastBatch {
    OSCBatchMove *batch = _history.lastObject;
    if (!batch) return;
    [_history removeLastObject];
    for (OSCBatchMoveItem *rec in batch.items) {
        if ([rec.target isKindOfClass:[OnScreenWidgetView class]]) {
            OnScreenWidgetView *w = rec.target;
            NSValue *last = w.layoutChanges.lastObject;
            if (last && CGPointEqualToPoint(last.CGPointValue, rec.newPosition) && w.layoutChanges.count > 1) {
                w.layoutChanges = [w.layoutChanges subarrayWithRange:NSMakeRange(0, w.layoutChanges.count - 1)];
            }
        } else if (rec.legacyState) {
            [_editor.layoutOSC.layoutChanges removeObjectIdenticalTo:rec.legacyState];
        }
        [self setPosition:rec.oldPosition of:rec.target];
    }
}

- (void)clearHistory { [_history removeAllObjects]; }

#pragma mark - Selection

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    for (UIView *v = touch.view; v; v = v.superview) {
        if (v == _bar) return NO;
    }
    return YES;
}

- (id)itemAtPoint:(CGPoint)p {
    // p is in hostView.layer space, which is each sublayer's superlayer space.
    CALayer *hit = nil;
    for (CALayer *sub in self.hostView.layer.sublayers.reverseObjectEnumerator) {
        if (sub == _highlightContainer || sub == _bar.layer) continue;
        if ((hit = [sub hitTest:p])) break;
    }
    NSArray<CALayer *> *legacy = [self legacyCandidates];
    for (CALayer *l = hit; l && l != self.hostView.layer; l = l.superlayer) {
        if ([l.delegate isKindOfClass:[OnScreenWidgetView class]]) {
            OnScreenWidgetView *w = (OnScreenWidgetView *)l.delegate;
            return [self isSelectableWidget:w] ? w : nil;
        }
        if ([legacy indexOfObjectIdenticalTo:l] != NSNotFound) return l;
    }
    return nil;
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    id item = [self itemAtPoint:[tap locationInView:self.hostView]];
    if (!item) return;
    NSUInteger idx = [_selection indexOfObjectIdenticalTo:item];
    if (idx == NSNotFound) [_selection addObject:item];
    else [_selection removeObjectAtIndex:idx];
    [self selectionChanged];
}

- (void)selectAllTapped {
    NSArray *all = [self allSelectableItems];
    BOOL allSelected = all.count > 0 && _selection.count == all.count;
    [_selection removeAllObjects];
    if (!allSelected) [_selection addObjectsFromArray:all];
    [self selectionChanged];
}

- (void)selectionChanged {
    [self resetBaseline];
    [self refresh];
}

- (void)resetBaseline {
    _hasBaseline = _selection.count > 0;
    if (_hasBaseline) _offsetBaseline = [self selectionBounds].origin;
}

#pragma mark - Moving

- (void)moveSelectionBy:(CGPoint)d {
    if (_selection.count == 0) return;
    CGRect b = [self selectionBounds];
    CGSize s = self.hostView.bounds.size;
    // Never push the group further out of the view; allow moving back in.
    if (d.x < 0) d.x = MAX(d.x, MIN(0, -CGRectGetMinX(b)));
    if (d.x > 0) d.x = MIN(d.x, MAX(0, s.width - CGRectGetMaxX(b)));
    if (d.y < 0) d.y = MAX(d.y, MIN(0, -CGRectGetMinY(b)));
    if (d.y > 0) d.y = MIN(d.y, MAX(0, s.height - CGRectGetMaxY(b)));
    if (d.x == 0 && d.y == 0) return;
    for (id item in _selection) {
        CGPoint p = [self positionOf:item];
        [self setPosition:CGPointMake(p.x + d.x, p.y + d.y) of:item];
    }
    [self refresh];
}

- (CGFloat)step {
    static const CGFloat steps[] = {1, 5, 10};
    NSInteger i = _stepControl.selectedSegmentIndex;
    return steps[(i >= 0 && i < 3) ? i : 0];
}

- (CGPoint)directionFor:(UIButton *)b {
    switch (b.tag) {
        case 0: return CGPointMake(-1, 0);
        case 1: return CGPointMake(0, -1);
        case 2: return CGPointMake(0, 1);
        default: return CGPointMake(1, 0);
    }
}

- (void)arrowDown:(UIButton *)b {
    [self stopRepeat];
    _repeatDirection = [self directionFor:b];
    [self stepOnce];
    _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(startFastRepeat) userInfo:nil repeats:NO];
}

- (void)startFastRepeat {
    _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.07 target:self selector:@selector(stepOnce) userInfo:nil repeats:YES];
}

- (void)stepOnce {
    CGFloat s = [self step];
    [self moveSelectionBy:CGPointMake(_repeatDirection.x * s, _repeatDirection.y * s)];
}

- (void)stopRepeat {
    [_repeatTimer invalidate];
    _repeatTimer = nil;
}

- (void)coordTapped {
    if (_selection.count == 0) return;
    CGRect b = [self selectionBounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"左上角坐标" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *axis in @[@"X", @"Y"]) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = axis;
            tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            tf.text = [NSString stringWithFormat:@"%.0f", [axis isEqualToString:@"X"] ? CGRectGetMinX(b) : CGRectGetMinY(b)];
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"移动" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *xs = weakAlert.textFields[0].text, *ys = weakAlert.textFields[1].text;
        CGRect now = [self selectionBounds];
        CGFloat x = xs.length ? xs.doubleValue : CGRectGetMinX(now);
        CGFloat y = ys.length ? ys.doubleValue : CGRectGetMinY(now);
        [self moveSelectionBy:CGPointMake(x - CGRectGetMinX(now), y - CGRectGetMinY(now))];
    }]];
    [_editor presentViewController:alert animated:YES completion:nil];
}

- (void)align:(OSCAlignMode)mode {
    if (_selection.count < 2) return;
    CGRect b = [self selectionBounds];

    if (mode == OSCDistributeH || mode == OSCDistributeV) {
        if (_selection.count < 3) return;
        BOOL h = mode == OSCDistributeH;
        NSArray *sorted = [_selection sortedArrayUsingComparator:^NSComparisonResult(id a, id c) {
            CGRect fa = [self frameOf:a], fc = [self frameOf:c];
            CGFloat va = h ? CGRectGetMinX(fa) : CGRectGetMinY(fa);
            CGFloat vc = h ? CGRectGetMinX(fc) : CGRectGetMinY(fc);
            return va < vc ? NSOrderedAscending : (va > vc ? NSOrderedDescending : NSOrderedSame);
        }];
        CGFloat total = 0;
        for (id item in sorted) { CGRect f = [self frameOf:item]; total += h ? f.size.width : f.size.height; }
        CGFloat gap = ((h ? b.size.width : b.size.height) - total) / (CGFloat)(sorted.count - 1);
        CGFloat cursor = h ? CGRectGetMinX(b) : CGRectGetMinY(b);
        for (id item in sorted) {
            CGRect f = [self frameOf:item];
            CGPoint p = [self positionOf:item];
            if (h) { p.x += cursor - CGRectGetMinX(f); cursor += f.size.width + gap; }
            else   { p.y += cursor - CGRectGetMinY(f); cursor += f.size.height + gap; }
            [self setPosition:p of:item];
        }
    } else {
        for (id item in _selection) {
            CGRect f = [self frameOf:item];
            CGPoint p = [self positionOf:item];
            switch (mode) {
                case OSCAlignLeft:    p.x += CGRectGetMinX(b) - CGRectGetMinX(f); break;
                case OSCAlignHCenter: p.x += CGRectGetMidX(b) - CGRectGetMidX(f); break;
                case OSCAlignRight:   p.x += CGRectGetMaxX(b) - CGRectGetMaxX(f); break;
                case OSCAlignTop:     p.y += CGRectGetMinY(b) - CGRectGetMinY(f); break;
                case OSCAlignVCenter: p.y += CGRectGetMidY(b) - CGRectGetMidY(f); break;
                case OSCAlignBottom:  p.y += CGRectGetMaxY(b) - CGRectGetMaxY(f); break;
                default: break;
            }
            [self setPosition:p of:item];
        }
    }
    // Relative positions changed, so the running offset no longer means anything.
    [self resetBaseline];
    [self refresh];
}

#pragma mark - Refresh

- (void)refresh {
    [self refreshHighlights];

    NSUInteger n = _selection.count;
    BOOL any = n > 0;
    for (UIButton *b in _arrowButtons) b.enabled = any;
    _coordButton.enabled = any;
    _alignButton.enabled = n >= 2;
    _alignButton.menu = [self alignMenu];

    NSArray *all = [self allSelectableItems];
    BOOL allSelected = all.count > 0 && n == all.count;
    [_selectAllButton setTitle:allSelected ? @"全不选" : @"全选" forState:UIControlStateNormal];

    if (any) {
        CGRect b = [self selectionBounds];
        [_coordButton setTitle:[NSString stringWithFormat:@"%.0f, %.0f", CGRectGetMinX(b), CGRectGetMinY(b)] forState:UIControlStateNormal];
        CGPoint off = _hasBaseline ? CGPointMake(CGRectGetMinX(b) - _offsetBaseline.x, CGRectGetMinY(b) - _offsetBaseline.y) : CGPointZero;
        _offsetLabel.text = OSCOffsetDescription(off);
    } else {
        [_coordButton setTitle:@"—" forState:UIControlStateNormal];
        _offsetLabel.text = @"";
    }
    _offsetLabel.hidden = _offsetLabel.text.length == 0;
}

- (void)refreshHighlights {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in [_highlightContainer.sublayers copy]) [l removeFromSuperlayer];
    UIColor *color = [UIColor systemYellowColor];
    for (id item in _selection) {
        CGRect f = CGRectInset([self frameOf:item], -kHighlightOutset, -kHighlightOutset);
        CGFloat radius;
        if ([item isKindOfClass:[UIView class]]) radius = ((UIView *)item).layer.cornerRadius + kHighlightOutset;
        else radius = MIN(f.size.width, f.size.height) / 2.0;
        radius = MIN(radius, MIN(f.size.width, f.size.height) / 2.0);

        CAShapeLayer *s = [CAShapeLayer layer];
        s.path = [UIBezierPath bezierPathWithRoundedRect:f cornerRadius:radius].CGPath;
        s.fillColor = [color colorWithAlphaComponent:0.12].CGColor;
        s.strokeColor = color.CGColor;
        s.lineWidth = 3.0;
        s.shadowColor = color.CGColor;
        s.shadowOpacity = 0.9;
        s.shadowRadius = 6.0;
        s.shadowOffset = CGSizeZero;
        [_highlightContainer addSublayer:s];
    }
    [CATransaction commit];
}

- (UIMenu *)alignMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *(^act)(NSString *, NSString *, OSCAlignMode) = ^UIAction *(NSString *title, NSString *symbol, OSCAlignMode mode) {
        return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil handler:^(UIAction *a) {
            [weakSelf align:mode];
        }];
    };
    UIMenu *h = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        act(@"左对齐", @"align.horizontal.left", OSCAlignLeft),
        act(@"水平居中", @"align.horizontal.center", OSCAlignHCenter),
        act(@"右对齐", @"align.horizontal.right", OSCAlignRight),
    ]];
    UIMenu *v = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        act(@"顶对齐", @"align.vertical.top", OSCAlignTop),
        act(@"垂直居中", @"align.vertical.center", OSCAlignVCenter),
        act(@"底对齐", @"align.vertical.bottom", OSCAlignBottom),
    ]];
    UIAction *dh = act(@"水平等间距", @"distribute.horizontal.center", OSCDistributeH);
    UIAction *dv = act(@"垂直等间距", @"distribute.vertical.center", OSCDistributeV);
    if (_selection.count < 3) {
        dh.attributes = UIMenuElementAttributesDisabled;
        dv.attributes = UIMenuElementAttributesDisabled;
    }
    UIMenu *d = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[dh, dv]];
    return [UIMenu menuWithTitle:@"" children:@[h, v, d]];
}

#pragma mark - Bar UI

- (UIButton *)textButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.tintColor = UIColor.whiteColor;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildBarIfNeeded {
    if (_bar) return;

    _bar = [[UIView alloc] init];
    _bar.layer.cornerRadius = 16;
    _bar.layer.shadowColor = UIColor.blackColor.CGColor;
    _bar.layer.shadowOpacity = 0.35;
    _bar.layer.shadowRadius = 10;
    _bar.layer.shadowOffset = CGSizeZero;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.layer.cornerRadius = 16;
    blur.clipsToBounds = YES;
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [_bar addSubview:blur];

    _cancelButton = [self textButton:@"取消" action:@selector(cancelTapped)];
    _selectAllButton = [self textButton:@"全选" action:@selector(selectAllTapped)];
    _alignButton = [self textButton:@"对齐" action:nil];
    [_alignButton setImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    _alignButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    _alignButton.imageEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    _alignButton.showsMenuAsPrimaryAction = YES;

    _doneButton = [self textButton:@"完成" action:@selector(doneTapped)];
    _doneButton.backgroundColor = UIColor.systemTealColor;
    _doneButton.layer.cornerRadius = 8;

    NSArray *symbols = @[@"arrowtriangle.left.fill", @"arrowtriangle.up.fill", @"arrowtriangle.down.fill", @"arrowtriangle.right.fill"];
    NSMutableArray *arrows = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = i;
        [b setImage:[UIImage systemImageNamed:symbols[i] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13]] forState:UIControlStateNormal];
        b.tintColor = UIColor.whiteColor;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
        b.layer.cornerRadius = 8;
        [b.widthAnchor constraintEqualToConstant:36].active = YES;
        [b.heightAnchor constraintEqualToConstant:34].active = YES;
        [b addTarget:self action:@selector(arrowDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(stopRepeat) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [arrows addObject:b];
    }
    _arrowButtons = arrows;

    _coordButton = [self textButton:@"—" action:@selector(coordTapped)];
    _coordButton.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    [_coordButton.widthAnchor constraintGreaterThanOrEqualToConstant:84].active = YES;

    _offsetLabel = [[UILabel alloc] init];
    _offsetLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    _offsetLabel.textColor = UIColor.systemTealColor;
    [_offsetLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    _stepControl = [[UISegmentedControl alloc] initWithItems:@[@"1", @"5", @"10"]];
    NSInteger savedStep = [[NSUserDefaults standardUserDefaults] integerForKey:kStepDefaultsKey];
    _stepControl.selectedSegmentIndex = (savedStep >= 0 && savedStep < 3) ? savedStep : 0;
    [_stepControl addTarget:self action:@selector(stepChanged) forControlEvents:UIControlEventValueChanged];
    _stepControl.selectedSegmentTintColor = UIColor.systemTealColor;
    [_stepControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];

    UIStackView *arrowStack = [[UIStackView alloc] initWithArrangedSubviews:arrows];
    arrowStack.spacing = 6;

    _leftGroup = [[UIStackView alloc] initWithArrangedSubviews:@[_cancelButton, _selectAllButton, _alignButton]];
    _leftGroup.spacing = 2;
    _leftGroup.alignment = UIStackViewAlignmentCenter;

    _midGroup = [[UIStackView alloc] initWithArrangedSubviews:@[arrowStack, _coordButton, _offsetLabel, _stepControl]];
    _midGroup.spacing = 8;
    _midGroup.alignment = UIStackViewAlignmentCenter;

    _topRow = [[UIStackView alloc] init];
    _topRow.alignment = UIStackViewAlignmentCenter;
    _topRow.distribution = UIStackViewDistributionEqualSpacing;

    _outerStack = [[UIStackView alloc] init];
    _outerStack.translatesAutoresizingMaskIntoConstraints = NO;
    _outerStack.alignment = UIStackViewAlignmentCenter;
    _outerStack.spacing = 10;
    [_bar addSubview:_outerStack];

    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:_bar.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:_bar.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:_bar.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:_bar.bottomAnchor],
        [_outerStack.leadingAnchor constraintEqualToAnchor:_bar.leadingAnchor constant:8],
        [_outerStack.trailingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:-8],
        [_outerStack.topAnchor constraintEqualToAnchor:_bar.topAnchor constant:8],
        [_outerStack.bottomAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:-8],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBarPan:)];
    [_bar addGestureRecognizer:pan];

    _barCompact = NO;
    [self arrangeBarCompact:NO force:YES];
}

- (void)stepChanged {
    [[NSUserDefaults standardUserDefaults] setInteger:_stepControl.selectedSegmentIndex forKey:kStepDefaultsKey];
}

/// Wide: one row  [取消 全选 对齐] [◀▲▼▶ 坐标 偏移 步长] [完成]
/// Narrow: two rows, actions on top, movement below.
- (void)arrangeBarCompact:(BOOL)compact force:(BOOL)force {
    if (!force && compact == _barCompact) return;
    _barCompact = compact;
    for (UIView *v in [_outerStack.arrangedSubviews copy]) { [_outerStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (UIView *v in [_topRow.arrangedSubviews copy]) { [_topRow removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (compact) {
        _outerStack.axis = UILayoutConstraintAxisVertical;
        _outerStack.alignment = UIStackViewAlignmentFill;
        [_topRow addArrangedSubview:_leftGroup];
        [_topRow addArrangedSubview:_doneButton];
        [_outerStack addArrangedSubview:_topRow];
        [_outerStack addArrangedSubview:_midGroup];
    } else {
        _outerStack.axis = UILayoutConstraintAxisHorizontal;
        _outerStack.alignment = UIStackViewAlignmentCenter;
        [_outerStack addArrangedSubview:_leftGroup];
        [_outerStack addArrangedSubview:_midGroup];
        [_outerStack addArrangedSubview:_doneButton];
    }
}

- (void)layoutForBoundsChange {
    if (!_active || !_bar) return;
    CGRect bounds = self.hostView.bounds;
    UIEdgeInsets safe = self.hostView.safeAreaInsets;

    // Measure the single-row layout; fall back to two rows if it doesn't fit.
    [self arrangeBarCompact:NO force:NO];
    CGSize wide = [_bar systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    BOOL compact = wide.width > bounds.size.width - safe.left - safe.right - 24;
    [self arrangeBarCompact:compact force:NO];
    CGSize size = [_bar systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];

    CGPoint center = _bar.center;
    if (!_barPlaced) {
        center = CGPointMake(CGRectGetMidX(bounds), bounds.size.height - MAX(safe.bottom, 12) - size.height / 2 - 8);
        _barPlaced = YES;
    }
    _bar.bounds = CGRectMake(0, 0, size.width, size.height);
    _bar.center = [self clampedBarCenter:center];
}

- (CGPoint)clampedBarCenter:(CGPoint)c {
    CGRect bounds = self.hostView.bounds;
    CGFloat hw = _bar.bounds.size.width / 2, hh = _bar.bounds.size.height / 2;
    c.x = MIN(MAX(c.x, hw), MAX(hw, bounds.size.width - hw));
    c.y = MIN(MAX(c.y, hh), MAX(hh, bounds.size.height - hh));
    return c;
}

- (void)handleBarPan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.hostView];
    _bar.center = [self clampedBarCenter:CGPointMake(_bar.center.x + t.x, _bar.center.y + t.y)];
    [pan setTranslation:CGPointZero inView:self.hostView];
}

@end
