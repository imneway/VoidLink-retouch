//
//  StreamLetterboxDetector.m
//  VoidLink
//

#import "StreamLetterboxDetector.h"
#import <QuartzCore/QuartzCore.h>

// Sampling cadence and debounce.
static const CFTimeInterval kSampleInterval = 0.5;
static const CFTimeInterval kDebounceInterval = 2.0;

// Luma (8-bit scale) at or below this counts as black. Limited-range black is 16;
// the headroom absorbs encoder noise and ringing next to the bar edge.
static const int kBlackLumaMax = 24;
// A row is "black" when at least this fraction of its samples are black.
static const float kRowBlackFraction = 0.98f;
// Columns sampled per row.
static const int kColumnSamples = 64;
// Letterbox geometry, as fractions of the frame height. Loose on purpose:
// a 16:9 game on a 4:3 display pads ~25% in total, 16:10 content ~17%, and
// some games pin the window to the top so one bar carries all of it.
static const float kMinTotalBarFraction = 0.05f;
static const float kMaxTotalBarFraction = 0.40f;
static const float kMinSingleBarFraction = 0.02f;
// Scanning stops here from each edge; past it the frame is treated as all-black.
static const float kMaxScanFraction = 0.45f;
// The band between the bars must carry at least this much non-black content,
// or the frame is a loading / fade-to-black screen and the verdict holds.
static const float kMinMiddleContentFraction = 0.05f;

@implementation StreamLetterboxDetector {
    dispatch_queue_t _stateQueue;
    BOOL _enabled;                       // guarded by @synchronized(self)
    CFTimeInterval _lastSampleTime;      // guarded by @synchronized(self)
    StreamContentClass _current;         // _stateQueue
    StreamContentClass _pending;         // _stateQueue
    CFTimeInterval _pendingSince;        // _stateQueue
    NSUInteger _pendingToken;            // _stateQueue
}

@synthesize currentContentClass = _current;

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.voidlink.letterbox-detector", DISPATCH_QUEUE_SERIAL);
        _current = StreamContentClassUnknown;
        _pending = StreamContentClassUnknown;
    }
    return self;
}

- (void)reset {
    @synchronized (self) {
        _lastSampleTime = 0;
    }
    dispatch_async(_stateQueue, ^{
        self->_current = StreamContentClassUnknown;
        self->_pending = StreamContentClassUnknown;
        self->_pendingToken++;
    });
}

- (void)setEnabled:(BOOL)enabled {
    BOOL was;
    @synchronized (self) {
        was = _enabled;
        _enabled = enabled;
    }
    if (was && !enabled) [self reset];
}

- (BOOL)enabled {
    @synchronized (self) {
        return _enabled;
    }
}

#pragma mark - Sampling

// Reads one luma sample as an 8-bit value. 10-bit biplanar formats (x420 etc.)
// keep their 10 bits in the MSBs of a 16-bit little-endian word.
static inline int LumaAt(const uint8_t *row, size_t x, BOOL wide) {
    if (wide) {
        uint16_t v = ((const uint16_t *)row)[x];
        return v >> 8;
    }
    return row[x];
}

static BOOL RowIsBlack(const uint8_t *base, size_t bytesPerRow, size_t width, size_t y, BOOL wide, int *outNonBlack) {
    const uint8_t *row = base + y * bytesPerRow;
    int black = 0;
    int samples = 0;
    size_t step = width / kColumnSamples;
    if (step == 0) step = 1;
    for (size_t x = step / 2; x < width; x += step) {
        samples++;
        if (LumaAt(row, x, wide) <= kBlackLumaMax) black++;
    }
    if (outNonBlack) *outNonBlack = samples - black;
    return samples > 0 && (float)black >= kRowBlackFraction * (float)samples;
}

- (void)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CFTimeInterval now = CACurrentMediaTime();
    @synchronized (self) {
        if (!_enabled) return;
        if (now - _lastSampleTime < kSampleInterval) return;
        _lastSampleTime = now;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    const uint8_t *base;
    size_t bytesPerRow, width, height;
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    } else {
        base = CVPixelBufferGetBaseAddress(pixelBuffer);
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        width = CVPixelBufferGetWidth(pixelBuffer);
        height = CVPixelBufferGetHeight(pixelBuffer);
    }
    if (!base || width < 16 || height < 16) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    // Biplanar luma planes are either 1 or 2 bytes per sample.
    BOOL wide = (bytesPerRow / width) >= 2;

    size_t maxScan = (size_t)(height * kMaxScanFraction);
    size_t top = 0;
    while (top < maxScan && RowIsBlack(base, bytesPerRow, width, top, wide, NULL)) top++;
    size_t bottom = 0;
    while (bottom < maxScan && RowIsBlack(base, bytesPerRow, width, height - 1 - bottom, wide, NULL)) bottom++;

    BOOL allBlack = (top >= maxScan && bottom >= maxScan);
    if (!allBlack) {
        // Content check across the band between the bars.
        size_t bandTop = top, bandBottom = height - bottom;
        int nonBlack = 0, samples = 0;
        const int rows = 16;
        for (int i = 0; i < rows; i++) {
            size_t y = bandTop + ((bandBottom - bandTop) * (2 * i + 1)) / (2 * rows);
            int rowNonBlack = 0;
            RowIsBlack(base, bytesPerRow, width, y, wide, &rowNonBlack);
            nonBlack += rowNonBlack;
            samples += kColumnSamples;
        }
        allBlack = (float)nonBlack < kMinMiddleContentFraction * (float)samples;
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if (allBlack) {
        // Loading / fade: hold the current verdict AND drop any pending switch, so a
        // single contradicting sample right before a black screen can't commit
        // unseen two seconds later.
        dispatch_async(_stateQueue, ^{
            self->_pending = StreamContentClassUnknown;
            self->_pendingToken++;
        });
        return;
    }

    float h = (float)height;
    float total = (float)(top + bottom) / h;
    float single = (float)MAX(top, bottom) / h;
    BOOL letterboxed = total >= kMinTotalBarFraction && total <= kMaxTotalBarFraction && single >= kMinSingleBarFraction;
    StreamContentClass raw = letterboxed ? StreamContentClassGame : StreamContentClassDesktop;

    dispatch_async(_stateQueue, ^{
        [self stateQueue_observe:raw at:now];
    });
}

#pragma mark - Debounce (on _stateQueue)

- (void)stateQueue_observe:(StreamContentClass)raw at:(CFTimeInterval)now {
    if (raw == _current) {
        _pending = StreamContentClassUnknown;
        _pendingToken++;
        return;
    }
    if (raw == _pending) return; // already counting down
    _pending = raw;
    _pendingSince = now;
    NSUInteger token = ++_pendingToken;
    // Time-based rather than sample-count-based: a static desktop produces very
    // few frames, so a change seen in a single frame must still commit once it
    // has gone uncontradicted for the debounce window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDebounceInterval * NSEC_PER_SEC)), _stateQueue, ^{
        [self stateQueue_commitIfStillPending:token];
    });
}

- (void)stateQueue_commitIfStillPending:(NSUInteger)token {
    if (token != _pendingToken || _pending == StreamContentClassUnknown) return;
    if (!self.enabled) return;
    _current = _pending;
    _pending = StreamContentClassUnknown;
    StreamContentClass committed = _current;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate letterboxDetector:self didChangeContentClass:committed];
    });
}

@end
