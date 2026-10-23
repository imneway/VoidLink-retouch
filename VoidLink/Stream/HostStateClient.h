//
//  HostStateClient.h
//  VoidLink
//
//  Client for the VoidLink host agent (utilities/pc/voidlink-host-agent):
//  a TCP line stream of JSON objects describing what sits on the streamed
//  display. Connects to the same address the stream uses, reconnects on its
//  own, and reports "stale" when nothing arrived for a while so the caller
//  can fall back to pixel-based detection.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const uint16_t HostStateClientDefaultPort = 48100;

@interface HostState : NSObject
@property (nonatomic, readonly) BOOL game;               // mode == "game"
@property (nonatomic, readonly, copy) NSString *mode;
@property (nonatomic, readonly, copy, nullable) NSString *process;
@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly) BOOL taskbarOnDisplay;
@property (nonatomic, readonly) BOOL displayPrimary;
@property (nonatomic, readonly) BOOL displayFound;
@property (nonatomic, readonly) NSUInteger seq;
@end

@class HostStateClient;

@protocol HostStateClientDelegate <NSObject>
// Main queue. Every line the agent sends (heartbeats included).
- (void)hostStateClient:(HostStateClient *)client didReceiveState:(HostState *)state;
// Main queue. Fired when the first state arrives after a (re)connect, and
// when no state arrived for the staleness interval or the link dropped.
- (void)hostStateClient:(HostStateClient *)client liveChanged:(BOOL)live;
@end

@interface HostStateClient : NSObject

// host: the stream's host string ("1.2.3.4", "1.2.3.4:47989", "[::1]:47989"
// or a bare IPv6); any port in it is dropped.
- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port;

@property (nonatomic, weak) id<HostStateClientDelegate> delegate;
@property (nonatomic, readonly) BOOL live;
@property (nonatomic, readonly, nullable) HostState *lastState;

- (void)start;
- (void)stop;

// Sends {"cmd": command} as one JSON line to the agent. Fire-and-forget:
// dropped (with a log line) when the link is not live. Any queue.
- (void)sendCommand:(NSString *)command;

@end

NS_ASSUME_NONNULL_END
