//
//  CustomEdgeSlideGestureRecognizer.h
//  VoidLink
//
//  Created by True砖家 on 2024/4/30.
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//

#ifndef CustomEdgeSlideGestureRecognizer_h
#define CustomEdgeSlideGestureRecognizer_h
// CustomEdgeSlideGestureRecognizer.h
#import <UIKit/UIKit.h>

@class CustomEdgeSlideGestureRecognizer;

@protocol CustomEdgeSlideGestureRecognizerDelegate <NSObject>
- (void)edgeSlideGesture:(CustomEdgeSlideGestureRecognizer *)recognizer didFinishWithSuccess:(BOOL)success;
@end

@interface CustomEdgeSlideGestureRecognizer : UIGestureRecognizer

@property (nonatomic, assign) UIRectEdge edges; // Specify the edge(s) you want to recognize the swipe gesture on
@property (nonatomic, assign) CGFloat normalizedThresholdDistance; // Distance from the edge to start recognizing the gesture
@property (nonatomic, assign) bool immediateTriggering;
@property (nonatomic, assign) CGFloat EDGE_TOLERANCE;
@property (nonatomic, weak) id<CustomEdgeSlideGestureRecognizerDelegate> edgeDelegate;

// Early-decision mode. Default (NO): the recognizer observes passively and only
// decides when the finger lifts. YES: it resolves DURING the touch so it can be
// paired with delaysTouchesBegan — recognizes as soon as the finger has slid
// `normalizedThresholdDistance` away from the edge (and more sideways than
// vertically), and FAILS early when the touch is clearly not an edge slide:
//   - the finger is still within `holdSlop` points after `holdCheckDelay`
//     (a tap / hold on whatever sits under it), or
//   - it moves mostly vertically past `holdSlop` * 3, or
//   - `decisionTimeout` elapses without recognition.
// Failing hands the withheld touch to the view beneath, so a control under the
// finger sees a normal (slightly delayed) touch sequence and never a stray press.
@property (nonatomic, assign) BOOL earlyDecision;
@property (nonatomic, assign) NSTimeInterval holdCheckDelay;   // default 0.07s
@property (nonatomic, assign) CGFloat holdSlop;                // default 3pt
@property (nonatomic, assign) NSTimeInterval decisionTimeout;  // default 0.18s

@end
#endif /* CustomEdgeSlideGestureRecognizer_h */
