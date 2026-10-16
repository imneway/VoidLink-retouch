//
//  StreamLetterboxDetector.m
//  VoidLink
//

#import "StreamLetterboxDetector.h"
#import "Logger.h"
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
static const float kMinMiddleContentFraction = 0.02f;
// A bar scan tolerates this many non-black rows before it stops, so a thin
// bright line at the very edge of the frame (window border, capture artifact)
// or a stray row inside the bar does not collapse the bar to zero height.
static const int kMaxBarGapRows = 3;
// Diagnostics: a measurement line is logged on every raw-class change and at
// least this often while sampling, so a Console capture shows what the
// detector actually sees (bar heights, pixel format) without a debugger.
static const CFTimeInterval kDiagLogInterval = 5.0;

@implementation StreamLetterboxDetector {
    dispatch_queue_t _stateQueue;
    BOOL _enabled;                       // guarded by @synchronized(self)
    CFTimeInterval _lastSampleTime;      // guarded by @synchronized(self)
    CFTimeInterval _lastDiagLogTime;     // VT callback thread only
    StreamContentClass _lastDiagRaw;     // VT callback thread only
    CFTimeInterval _lastFailureLogTime;  // VT callback thread only
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

#define FOURCC_CHARS(f) (char)((f) >> 24), (char)((f) >> 16), (char)((f) >> 8), (char)(f)

static BOOL PixelFormatIsWide(OSType fmt) {
    switch (fmt) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return YES;
        default:
            return NO;
    }
}

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

// Bar height from one edge: the extent of the leading run of black rows, where
// up to kMaxBarGapRows non-black rows in a row are skipped over. Returns the
// index just past the last black row seen (0 when the edge row isn't black and
// no black run follows within the gap allowance).
static size_t ScanBar(const uint8_t *base, size_t bytesPerRow, size_t width, BOOL wide, size_t maxScan,
                      size_t (^rowAt)(size_t i)) {
    size_t bar = 0;
    int gap = 0;
    for (size_t i = 0; i < maxScan; i++) {
        if (RowIsBlack(base, bytesPerRow, width, rowAt(i), wide, NULL)) {
            bar = i + 1;
            gap = 0;
        } else if (++gap > kMaxBarGapRows) {
            break;
        }
    }
    return bar;
}

- (void)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CFTimeInterval now = CACurrentMediaTime();
    @synchronized (self) {
        if (!_enabled) return;
        if (now - _lastSampleTime < kSampleInterval) return;
        _lastSampleTime = now;
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    CVReturn lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (lockResult != kCVReturnSuccess) {
        if (now - _lastFailureLogTime >= kDiagLogInterval) {
            _lastFailureLogTime = now;
            Log(LOG_W, @"[Letterbox] lock failed %d, fmt %c%c%c%c", (int)lockResult, FOURCC_CHARS(fmt));
        }
        return;
    }

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
        if (now - _lastFailureLogTime >= kDiagLogInterval) {
            _lastFailureLogTime = now;
            Log(LOG_W, @"[Letterbox] unreadable buffer: base %p %zux%zu fmt %c%c%c%c", base, width, height, FOURCC_CHARS(fmt));
        }
        return;
    }
    // 10-bit biplanar formats store each sample in a 16-bit word; everything
    // else we can receive is 8-bit. Decided from the format, not from the row
    // stride, which may carry alignment padding.
    BOOL wide = PixelFormatIsWide(fmt);

    size_t maxScan = (size_t)(height * kMaxScanFraction);
    size_t top = ScanBar(base, bytesPerRow, width, wide, maxScan, ^size_t(size_t i) { return i; });
    size_t bottom = ScanBar(base, bytesPerRow, width, wide, maxScan, ^size_t(size_t i) { return height - 1 - i; });

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

    float h = (float)height;
    float total = (float)(top + bottom) / h;
    float single = (float)MAX(top, bottom) / h;
    BOOL letterboxed = total >= kMinTotalBarFraction && total <= kMaxTotalBarFraction && single >= kMinSingleBarFraction;
    StreamContentClass raw = allBlack ? StreamContentClassUnknown
                           : (letterboxed ? StreamContentClassGame : StreamContentClassDesktop);

    if (raw != _lastDiagRaw || now - _lastDiagLogTime >= kDiagLogInterval) {
        _lastDiagRaw = raw;
        _lastDiagLogTime = now;
        Log(LOG_I, @"[Letterbox] raw=%@ top=%zu bottom=%zu of %zux%zu fmt=%c%c%c%c wide=%d stride=%zu",
            raw == StreamContentClassGame ? @"game" : (raw == StreamContentClassDesktop ? @"desktop" : @"black"),
            top, bottom, width, height, FOURCC_CHARS(fmt), wide, bytesPerRow);
    }

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
    Log(LOG_I, @"[Letterbox] verdict -> %@", committed == StreamContentClassGame ? @"game" : @"desktop");
    dispatch_async(dispatch_get_main_queue(), ^{
        // A reset/disable that raced the hop to main must not deliver a verdict
        // from the previous configuration.
        if (!self.enabled) return;
        [self.delegate letterboxDetector:self didChangeContentClass:committed];
    });
}

@end
