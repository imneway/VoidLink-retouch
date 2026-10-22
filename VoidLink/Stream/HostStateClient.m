//
//  HostStateClient.m
//  VoidLink
//

#import "HostStateClient.h"
#import "Logger.h"
#import <Network/Network.h>

// The agent heartbeats every second; 2.5 s of silence means the link is gone
// even if TCP hasn't noticed yet.
static const NSTimeInterval kStaleInterval = 2.5;
static const NSTimeInterval kReconnectMinDelay = 1.0;
static const NSTimeInterval kReconnectMaxDelay = 10.0;
static const size_t kMaxLineBytes = 64 * 1024;

@interface HostState ()
- (instancetype)initWithJSON:(NSDictionary *)json;
@end

@implementation HostState

- (instancetype)initWithJSON:(NSDictionary *)json {
    self = [super init];
    if (!self) return nil;
    NSString *mode = [json[@"mode"] isKindOfClass:[NSString class]] ? json[@"mode"] : @"desk";
    _mode = [mode copy];
    _game = [mode isEqualToString:@"game"];
    NSDictionary *top = [json[@"top"] isKindOfClass:[NSDictionary class]] ? json[@"top"] : nil;
    _process = [top[@"process"] isKindOfClass:[NSString class]] ? [top[@"process"] copy] : nil;
    _title = [top[@"title"] isKindOfClass:[NSString class]] ? [top[@"title"] copy] : nil;
    _taskbarOnDisplay = [json[@"taskbar_on_display"] boolValue];
    _displayPrimary = [json[@"display_primary"] boolValue];
    _displayFound = [json[@"display_found"] boolValue];
    _seq = [json[@"seq"] unsignedIntegerValue];
    return self;
}

@end

@implementation HostStateClient {
    NSString *_host;
    uint16_t _port;
    dispatch_queue_t _queue;
    nw_connection_t _connection;
    NSMutableData *_buffer;
    dispatch_source_t _staleTimer;
    NSTimeInterval _reconnectDelay;
    BOOL _running;
    BOOL _live;
    NSUInteger _generation; // bumps on every (re)connect so stale callbacks are ignored
}

+ (NSString *)hostWithoutPort:(NSString *)host {
    NSString *h = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([h hasPrefix:@"["]) { // [v6]:port or [v6]
        NSRange close = [h rangeOfString:@"]"];
        return close.location == NSNotFound ? h : [h substringWithRange:NSMakeRange(1, close.location - 1)];
    }
    NSArray<NSString *> *parts = [h componentsSeparatedByString:@":"];
    if (parts.count == 2) return parts[0]; // v4:port
    return h;                              // bare v4 or bare v6
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port {
    self = [super init];
    if (!self) return nil;
    _host = [[HostStateClient hostWithoutPort:host] copy];
    _port = port;
    _queue = dispatch_queue_create("com.voidlink.host-state", DISPATCH_QUEUE_SERIAL);
    _buffer = [NSMutableData data];
    _reconnectDelay = kReconnectMinDelay;
    return self;
}

- (void)dealloc {
    // No self in the block: this object is already going away. Just cancel
    // what it owns on its queue (the handlers hold self weakly).
    nw_connection_t connection = _connection;
    dispatch_source_t timer = _staleTimer;
    dispatch_async(_queue, ^{
        if (timer) dispatch_source_cancel(timer);
        if (connection) {
            nw_connection_set_state_changed_handler(connection, NULL);
            nw_connection_cancel(connection);
        }
    });
}

- (BOOL)live { return _live; }

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_running) return;
        self->_running = YES;
        self->_reconnectDelay = kReconnectMinDelay;
        [self queue_connect];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        self->_running = NO;
        self->_generation++;
        [self queue_teardownConnection];
        [self queue_setLive:NO];
    });
}

#pragma mark - Connection (on _queue)

- (void)queue_connect {
    if (!_running || _host.length == 0) return;
    NSUInteger generation = ++_generation;
    [_buffer setLength:0];
    NSString *portString = [NSString stringWithFormat:@"%u", _port];
    nw_endpoint_t endpoint = nw_endpoint_create_host(_host.UTF8String, portString.UTF8String);
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_options_t tcp = nw_protocol_stack_copy_transport_protocol(nw_parameters_copy_default_protocol_stack(params));
    nw_tcp_options_set_no_delay(tcp, true);
    nw_tcp_options_set_connection_timeout(tcp, 5);
    nw_connection_t connection = nw_connection_create(endpoint, params);
    _connection = connection;
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(connection, _queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_generation != generation) return;
        switch (state) {
            case nw_connection_state_ready:
                Log(LOG_I, @"[HostAgent] connected to %@:%u", self->_host, self->_port);
                self->_reconnectDelay = kReconnectMinDelay;
                [self queue_armStaleTimer];
                [self queue_receive:connection generation:generation];
                break;
            case nw_connection_state_failed:
            case nw_connection_state_cancelled:
                if (state == nw_connection_state_failed) {
                    Log(LOG_I, @"[HostAgent] connection failed (%d), retry in %.0fs",
                        error ? nw_error_get_error_code(error) : 0, self->_reconnectDelay);
                }
                [self queue_connectionLost];
                break;
            case nw_connection_state_waiting:
                // No route yet (host down, agent not installed): wait for a
                // bounded time, then recycle so the backoff keeps control.
                break;
            default:
                break;
        }
    });
    nw_connection_start(connection);
    // nw's own "waiting" can last forever; cap each attempt ourselves.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), _queue, ^{
        if (self->_generation != generation || self->_live) return;
        Log(LOG_I, @"[HostAgent] no agent at %@:%u, retry in %.0fs", self->_host, self->_port, self->_reconnectDelay);
        [self queue_connectionLost];
    });
}

- (void)queue_receive:(nw_connection_t)connection generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 16 * 1024, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_generation != generation) return;
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                [self->_buffer appendBytes:buffer length:size];
                return true;
            });
            [self queue_drainLines];
        }
        if (error || is_complete) {
            [self queue_connectionLost];
            return;
        }
        [self queue_receive:connection generation:generation];
    });
}

- (void)queue_drainLines {
    while (YES) {
        const uint8_t *bytes = _buffer.bytes;
        NSUInteger length = _buffer.length;
        NSUInteger newline = NSNotFound;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] == '\n') { newline = i; break; }
        }
        if (newline == NSNotFound) {
            if (length > kMaxLineBytes) [_buffer setLength:0]; // garbage, not our protocol
            return;
        }
        NSData *line = [_buffer subdataWithRange:NSMakeRange(0, newline)];
        [_buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        if (line.length == 0) continue;
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:line options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) continue;
        HostState *state = [[HostState alloc] initWithJSON:json];
        _lastState = state;
        [self queue_armStaleTimer];
        [self queue_setLive:YES];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.delegate hostStateClient:self didReceiveState:state];
        });
    }
}

- (void)queue_armStaleTimer {
    if (_staleTimer) { dispatch_source_cancel(_staleTimer); _staleTimer = nil; }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStaleInterval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        Log(LOG_I, @"[HostAgent] stale: no state for %.1fs, reconnecting", kStaleInterval);
        [self queue_connectionLost];
    });
    dispatch_resume(timer);
    _staleTimer = timer;
}

- (void)queue_teardownConnection {
    if (_staleTimer) { dispatch_source_cancel(_staleTimer); _staleTimer = nil; }
    if (_connection) {
        nw_connection_t connection = _connection;
        _connection = nil;
        nw_connection_set_state_changed_handler(connection, NULL);
        nw_connection_cancel(connection);
    }
    [_buffer setLength:0];
}

- (void)queue_connectionLost {
    _generation++;
    [self queue_teardownConnection];
    [self queue_setLive:NO];
    if (!_running) return;
    NSTimeInterval delay = _reconnectDelay;
    _reconnectDelay = MIN(kReconnectMaxDelay, _reconnectDelay * 2);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        [self queue_connect];
    });
}

- (void)queue_setLive:(BOOL)live {
    if (_live == live) return;
    _live = live;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.delegate hostStateClient:self liveChanged:live];
    });
}

@end
