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
@property (nonatomic, readonly, copy, nullable) NSString *reason;
// mode == "desk" with reason "dialog": the game process is still on top,
// behind one of its dialogs. The OSC is parked, not put away: nothing the
// user chose is cleared. (reason "idle", an emulator's game list, is a real desk.)
@property (nonatomic, readonly) BOOL transientDesk;
// Where the agent has the PC's audio: "ipad" (default moved to the virtual sink) / "host"; nil from older agents.
@property (nonatomic, readonly, copy, nullable) NSString *audioRoute;
@property (nonatomic, readonly, copy, nullable) NSString *process;
@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly) BOOL taskbarOnDisplay;
@property (nonatomic, readonly) BOOL displayPrimary;
@property (nonatomic, readonly) BOOL displayFound;
@property (nonatomic, readonly) NSUInteger seq;
// About the window the agent judged by (top): whether it has the focus, is a
// covering (fullscreen-sized) window, and its client area in host pixels
// (0 when the agent predates the field).
@property (nonatomic, readonly) BOOL topForeground;
@property (nonatomic, readonly) BOOL topCoversDisplay;
@property (nonatomic, readonly) NSInteger topClientWidth;
@property (nonatomic, readonly) NSInteger topClientHeight;
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
// Same, with extra fields merged into the JSON object.
- (void)sendCommand:(NSString *)command arguments:(nullable NSDictionary<NSString *, id> *)arguments;

@end

NS_ASSUME_NONNULL_END
