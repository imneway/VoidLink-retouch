//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ConnectionCallbacks.h"
#import "VideoDecoderRenderer.h"
#import "StreamConfiguration.h"
#import "BandwidthTracker.h"
#import "Plot.h"

#define CONN_TEST_SERVER "www.baidu.com"

// "Audio follows Game/Desk": the stream launches with host audio on (Sunshine
// leaves the PC's default device alone); the host agent moves the PC's default
// device to the virtual sink in game mode, and the iPad mutes itself in desk mode.
extern NSString * const VLAudioFollowsModeDefaultsKey;
BOOL VLAudioFollowsModeEnabled(void);   // default YES
// Mutes local playback (decoding continues so the Opus state stays in sync).
void VLSetStreamAudioMuted(BOOL muted);

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) terminateWithCompletion:(void (^)(void))completion;
-(void) main;
-(BandwidthTracker *) getBwTracker;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString*) getActiveCodecName;

@end
