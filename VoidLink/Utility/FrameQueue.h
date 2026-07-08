#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "Frame.h"
#import "FloatBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface FrameQueue : NSObject

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic) FloatBuffer *frameDropMetrics;
@property (nonatomic) int highWaterMark;
@property (nonatomic, readonly) int maxCapacity;
@property (atomic) BOOL paused;

+ (instancetype)sharedInstance;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)isEmpty;
- (void)clear;
// Release frames retained in already-consumed ring slots (memory pressure)
- (void)purgeStaleSlots;
- (int)enqueue:(Frame *)frame;
- (int)enqueue:(Frame *)frame withSlackSize:(int)slack;
- (nullable Frame *)dequeue;
- (nullable Frame *)dequeueWithTimeout:(CFTimeInterval)timeout;
- (CFTimeInterval)estimatedFramerate;
- (int)currentSoftCap;
- (void)waitForEnqueue;
// The queue is a process-wide singleton but stream sessions can overlap during
// self-heal reconnects: start/stop are owner-scoped so a dying session's
// cleanup cannot stop the queue the new session just started.
- (void)startForConsumer:(id)owner;
- (void)stopForConsumer:(id)owner;

@end

NS_ASSUME_NONNULL_END
