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
    return self;
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
        self.state = UIGestureRecognizerStateFailed;
        [self notifyDelegateWithSuccess:NO];
        capturedUITouch = nil;
        return;
    }
    UITouch *touch = [touches anyObject];
    capturedUITouch = touch;
    startPointX = [capturedUITouch locationInView:self.view].x;
    CGFloat streamFrameViewWidthInPoints = self.view.frame.size.width;
    if(_immediateTriggering){
        
        if(self.edges & UIRectEdgeLeft){
            if(startPointX < _EDGE_TOLERANCE){
                self.state = UIGestureRecognizerStateEnded;
                [self notifyDelegateWithSuccess:YES];
                capturedUITouch = nil;
            }
            // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }
        if(self.edges & UIRectEdgeRight){
            if(startPointX > streamFrameViewWidthInPoints - _EDGE_TOLERANCE){
                self.state = UIGestureRecognizerStateEnded;
                [self notifyDelegateWithSuccess:YES];
                capturedUITouch = nil;
            }
           // NSLog(@"startPointX  %f , normalizedGestureDeltaX %f", startPointX,  normalizedGestureDistance);
        }

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
        self.state = success ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed;
        [self notifyDelegateWithSuccess:success];
    }
    capturedUITouch = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self notifyDelegateWithSuccess:NO];
    capturedUITouch = nil;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    if (!delegateNotifiedForCurrentGesture) {
        [self notifyDelegateWithSuccess:NO];
    }
    delegateNotifiedForCurrentGesture = NO;
    capturedUITouch = nil;
    startPointX = 0.0f;
    [super reset];
}

- (void)notifyDelegateWithSuccess:(BOOL)success {
    if ([self.edgeDelegate respondsToSelector:@selector(edgeSlideGesture:didFinishWithSuccess:)]) {
        [self.edgeDelegate edgeSlideGesture:self didFinishWithSuccess:success];
    }
    delegateNotifiedForCurrentGesture = YES;
}

@end

