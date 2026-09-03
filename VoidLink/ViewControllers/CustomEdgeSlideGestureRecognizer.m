//
//  CustomEdgeSlideGestureRecognizer.m
//  VoidLink
//
//  Created by True砖家 on 2024/4/30.
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//

// #import <Foundation/Foundation.h>

#import "CustomEdgeSlideGestureRecognizer.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

@interface CustomEdgeSlideGestureRecognizer () {
    UITouch *capturedUITouch;
    CGFloat startPointX;
    CGPoint startPoint;
    CGFloat maxDisplacement;
    // Bumped whenever the tracked sequence ends; pending early-decision timers
    // compare against it and no-op if the sequence they were armed for is gone.
    NSUInteger sequenceGeneration;
    BOOL delegateNotifiedForCurrentGesture;
}

- (void)notifyDelegateWithSuccess:(BOOL)success;

@end

@implementation CustomEdgeSlideGestureRecognizer
//static CGFloat screenWidthInPoints;

- (instancetype)initWithTarget:(nullable id)target action:(nullable SEL)action {
    self = [super initWithTarget:target action:action];
//    screenWidthInPoints = CGRectGetWidth([UIApplication.sharedApplication.windows.firstObject.screen bounds]); // Get the screen's bounds (in points)
    _immediateTriggering = false;
    _EDGE_TOLERANCE = 10.0f;
    _earlyDecision = NO;
    _holdCheckDelay = 0.07;
    _holdSlop = 3.0f;
    _decisionTimeout = 0.18;
    return self;
}

- (BOOL)startIsAtEdge:(CGFloat)x viewWidth:(CGFloat)width {
    if ((self.edges & UIRectEdgeLeft) && x < _EDGE_TOLERANCE) return YES;
    if ((self.edges & UIRectEdgeRight) && x > width - _EDGE_TOLERANCE) return YES;
    return NO;
}

// Signed progress away from the edge the touch started at: positive when the
// finger travels inward (left edge → rightward, right edge → leftward).
- (CGFloat)inwardProgressForDx:(CGFloat)dx {
    if ((self.edges & UIRectEdgeRight) && startPointX > self.view.frame.size.width - _EDGE_TOLERANCE) {
        return -dx;
    }
    if ((self.edges & UIRectEdgeLeft) && startPointX < _EDGE_TOLERANCE) {
        return dx;
    }
    return 0;
}

- (void)finishSequenceWithState:(UIGestureRecognizerState)state success:(BOOL)success {
    sequenceGeneration++;
    capturedUITouch = nil;
    self.state = state;
    [self notifyDelegateWithSuccess:success];
}

- (void)armEarlyDecisionTimers {
    NSUInteger gen = ++sequenceGeneration;
    __weak typeof(self) weakSelf = self;
    // Hold check: a finger that hasn't travelled `holdSlop` yet is resting on
    // something, not sliding. Fail now so the control underneath gets its touch
    // with as little delay as possible.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_holdCheckDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || gen != self->sequenceGeneration || self->capturedUITouch == nil) return;
        if (self->maxDisplacement < self->_holdSlop) {
            [self finishSequenceWithState:UIGestureRecognizerStateFailed success:NO];
        }
    });
    // Absolute budget: whatever is still undecided by now is not an edge slide.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_decisionTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || gen != self->sequenceGeneration || self->capturedUITouch == nil) return;
        [self finishSequenceWithState:UIGestureRecognizerStateFailed success:NO];
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // [super touchesBegan:touches withEvent:event];
    if (capturedUITouch != nil) {
        // An edge slide is strictly single-finger. The old code overwrote
        // capturedUITouch with the newest touch; when the FIRST finger then
        // lifted, touchesEnded nil'ed the capture without notifying, and the
        // second finger's lift matched nothing — the recognizer stranded in
        // Possible with the edge-gesture suppression (begun in
        // shouldReceiveTouch) never released, eating ALL OSC input for the
        // rest of the session. Fail the gesture outright instead, which
        // notifies the edgeDelegate and lifts the suppression immediately.
        [self finishSequenceWithState:UIGestureRecognizerStateFailed success:NO];
        return;
    }
    UITouch *touch = [touches anyObject];
    capturedUITouch = touch;
    startPoint = [capturedUITouch locationInView:self.view];
    startPointX = startPoint.x;
    maxDisplacement = 0;
    CGFloat streamFrameViewWidthInPoints = self.view.frame.size.width;
    if(_immediateTriggering){
        
        if(self.edges & UIRectEdgeLeft){
            if(startPointX < _EDGE_TOLERANCE){
                [self finishSequenceWithState:UIGestureRecognizerStateEnded success:YES];
            }
            // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }
        if(self.edges & UIRectEdgeRight){
            if(startPointX > streamFrameViewWidthInPoints - _EDGE_TOLERANCE){
                [self finishSequenceWithState:UIGestureRecognizerStateEnded success:YES];
            }
           // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }
        return;
    }
    if (_earlyDecision) {
        if (![self startIsAtEdge:startPointX viewWidth:streamFrameViewWidthInPoints]) {
            // Can never succeed; don't hold the view's touches hostage.
            [self finishSequenceWithState:UIGestureRecognizerStateFailed success:NO];
            return;
        }
        [self armEarlyDecisionTimers];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_earlyDecision || capturedUITouch == nil || ![touches containsObject:capturedUITouch]) {
        return;
    }
    CGPoint p = [capturedUITouch locationInView:self.view];
    CGFloat dx = p.x - startPoint.x;
    CGFloat dy = p.y - startPoint.y;
    maxDisplacement = MAX(maxDisplacement, MAX(fabs(dx), fabs(dy)));
    CGFloat width = self.view.frame.size.width;
    CGFloat thresholdPt = _normalizedThresholdDistance * width;
    CGFloat inward = [self inwardProgressForDx:dx];
    if (inward >= thresholdPt && fabs(dx) >= fabs(dy)) {
        [self finishSequenceWithState:UIGestureRecognizerStateEnded success:YES];
        return;
    }
    // Clearly not an edge slide: mostly vertical travel, or pulling back toward
    // (past) the edge. Fail right away so the withheld touch reaches the view.
    CGFloat directionSlop = _holdSlop * 3;
    if ((fabs(dy) > directionSlop && fabs(dy) > fabs(dx)) || inward < -directionSlop) {
        [self finishSequenceWithState:UIGestureRecognizerStateFailed success:NO];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // [super touchesEnded:touches withEvent:event];

    if (capturedUITouch == nil) {
        // Sequence already finished (failed on a multi-touch join, or an
        // unrelated touch is ending). Nothing to evaluate, and crucially do
        // NOT touch state here.
        return;
    }
    if (![touches containsObject:capturedUITouch]) {
        // Some other touch ended while our candidate is still down; keep
        // tracking the candidate. The old unconditional `capturedUITouch =
        // nil` below is what orphaned the state machine.
        return;
    }
    if([touches containsObject:capturedUITouch]){
        CGFloat _endPointX = [capturedUITouch locationInView:self.view].x;
        CGFloat screenWidthInPoints = self.view.frame.size.width;
        CGFloat normalizedGestureDistance = fabs(_endPointX - startPointX)/screenWidthInPoints;
        BOOL success = NO;
        
        if(self.edges & UIRectEdgeLeft){
            if(startPointX < _EDGE_TOLERANCE && normalizedGestureDistance > _normalizedThresholdDistance){
                success = YES;
            }
            // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }
        if(self.edges & UIRectEdgeRight){
            if((startPointX > (screenWidthInPoints - _EDGE_TOLERANCE)) && normalizedGestureDistance > _normalizedThresholdDistance){
                success = YES;
            }
           // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }
        [self finishSequenceWithState:(success ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed) success:success];
        return;
    }
    capturedUITouch = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    sequenceGeneration++;
    [self notifyDelegateWithSuccess:NO];
    capturedUITouch = nil;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    if (!delegateNotifiedForCurrentGesture) {
        [self notifyDelegateWithSuccess:NO];
    }
    delegateNotifiedForCurrentGesture = NO;
    sequenceGeneration++;
    capturedUITouch = nil;
    startPointX = 0.0f;
    startPoint = CGPointZero;
    maxDisplacement = 0;
    [super reset];
}

- (void)notifyDelegateWithSuccess:(BOOL)success {
    if ([self.edgeDelegate respondsToSelector:@selector(edgeSlideGesture:didFinishWithSuccess:)]) {
        [self.edgeDelegate edgeSlideGesture:self didFinishWithSuccess:success];
    }
    delegateNotifiedForCurrentGesture = YES;
}

@end
