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
// a little headroom absorbs encoder noise. Kept tight so dim game content
// (dark blue skies etc.) is not swallowed as "bar".
static const int kBlackLumaMax = 20;
// A line is "black" when at most this many of its samples are non-black.
static const int kLineMaxNonBlack = 2;
// Samples taken along each scanned line (columns of a row / rows of a column).
static const int kLineSamples = 256;
// Dark content can only make a measured bar LARGER (its rows pass the black
// test), never smaller, so the bar estimate is the minimum over the last few
// samples. A sprite or firefly touching the content edge once in this window
// pins the real bar. 8 samples = 4 s at the sampling cadence.
enum { kWindowSamples = 8 };
// A measurement this far (fraction of the extent) below the window minimum
// restarts the window — see UpdateAxis.
static const float kRestartDropFraction = 0.05f;
// Letterbox / pillarbox geometry, as fractions of the frame height / width.
// Loose on purpose: a 16:9 game on this ~1.45 display pads ~18% vertically,
// a 4:3 game ~8% horizontally, and some games pin the window to one edge so a
// single bar carries all of it. Past the maximum the frame is a loading screen
// (small logo on black) or a fade: the verdict holds instead of flipping.
static const float kMinTotalBarFraction = 0.05f;
static const float kMaxTotalBarFraction = 0.40f;
static const float kMinSingleBarFraction = 0.02f;
// Scanning stops here from each edge.
static const float kMaxScanFraction = 0.45f;
// 16:9 fit, in frame pixels: the measured bars may fall short of the ideal
// 16:9 letterbox by this much and still count (enter), and once fitting the
// shortfall must exceed the larger slack before the fit is dropped (leave),
// so a HUD edge or a toast drawn over the bar doesn't flap the snap.
static const int kFitEnterSlackPx = 10;
static const int kFitLeaveSlackPx = 24;
// A bar scan tolerates this many non-black rows before it stops, so a thin
// bright line at the very edge of the frame (window border, capture artifact)
// or a stray row inside the bar does not collapse the bar to zero height.
static const int kMaxBarGapRows = 3;
// Diagnostics: a measurement line is logged on every raw-class change and at
// least this often while sampling, so a Console capture shows what the
// detector actually sees (bar heights, pixel format) without a debugger.
static const CFTimeInterval kDiagLogInterval = 5.0;

typedef struct {
    size_t a[kWindowSamples];   // top or left
    size_t b[kWindowSamples];   // bottom or right
    int count;
    int next;
    BOOL edgesBlack;            // regime the window was collected in
} BarWindow;

static void BarWindowClear(BarWindow *w) {
    w->count = 0;
    w->next = 0;
}

static void BarWindowPush(BarWindow *w, size_t a, size_t b) {
    w->a[w->next] = a;
    w->b[w->next] = b;
    w->next = (w->next + 1) % kWindowSamples;
    if (w->count < kWindowSamples) w->count++;
}

static void BarWindowMin(const BarWindow *w, size_t *outA, size_t *outB) {
    size_t ma = SIZE_MAX, mb = SIZE_MAX;
    for (int i = 0; i < w->count; i++) {
        if (w->a[i] < ma) ma = w->a[i];
        if (w->b[i] < mb) mb = w->b[i];
    }
    *outA = ma;
    *outB = mb;
}

@implementation StreamLetterboxDetector {
    dispatch_queue_t _stateQueue;
    BOOL _enabled;                       // guarded by @synchronized(self)
    CFTimeInterval _lastSampleTime;      // guarded by @synchronized(self)
    CFTimeInterval _lastDiagLogTime;     // VT callback thread only
    StreamContentClass _lastDiagRaw;     // VT callback thread only
    BOOL _lastDiagFits;                  // VT callback thread only
    CFTimeInterval _lastFailureLogTime;  // VT callback thread only
    // Bar measurement windows (VT callback thread only). One ring per axis,
    // cleared whenever that axis' edge-black state flips (desktop <-> bars),
    // so a fresh game is measured from its first sample, not against the
    // desktop's zeros.
    BarWindow _vertical;                 // top / bottom
    BarWindow _horizontal;               // left / right
    StreamContentClass _current;         // _stateQueue
    StreamContentClass _pending;         // _stateQueue
    BOOL _currentFits;                   // _stateQueue
    BOOL _pendingFits;                   // _stateQueue
    BOOL _fitsHysteresis;                // guarded by @synchronized(self)
    CFTimeInterval _pendingSince;        // _stateQueue
    NSUInteger _pendingToken;            // _stateQueue
}

@synthesize currentContentClass = _current;
@synthesize currentFitsSixteenNine = _currentFits;

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
    @synchronized (self) {   // windows / hysteresis are touched under the same lock on the VT thread
        BarWindowClear(&_vertical);
        BarWindowClear(&_horizontal);
        _fitsHysteresis = NO;
    }
    dispatch_async(_stateQueue, ^{
        self->_current = StreamContentClassUnknown;
        self->_pending = StreamContentClassUnknown;
        self->_currentFits = NO;
        self->_pendingFits = NO;
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

static BOOL RowIsBlack(const uint8_t *base, size_t bytesPerRow, size_t width, size_t y, BOOL wide) {
    const uint8_t *row = base + y * bytesPerRow;
    int nonBlack = 0;
    size_t step = width / kLineSamples;
    if (step == 0) step = 1;
    for (size_t x = step / 2; x < width; x += step) {
        if (LumaAt(row, x, wide) > kBlackLumaMax && ++nonBlack > kLineMaxNonBlack) return NO;
    }
    return YES;
}

static BOOL ColumnIsBlack(const uint8_t *base, size_t bytesPerRow, size_t height, size_t x, BOOL wide) {
    int nonBlack = 0;
    size_t step = height / kLineSamples;
    if (step == 0) step = 1;
    for (size_t y = step / 2; y < height; y += step) {
        if (LumaAt(base + y * bytesPerRow, x, wide) > kBlackLumaMax && ++nonBlack > kLineMaxNonBlack) return NO;
    }
    return YES;
}

// Bar height from one edge: the extent of the leading run of black rows, where
// up to kMaxBarGapRows non-black rows in a row are skipped over. Returns the
// index just past the last black row seen (0 when the edge row isn't black and
// no black run follows within the gap allowance).
static size_t ScanBar(size_t maxScan, BOOL (^lineIsBlack)(size_t i)) {
    size_t bar = 0;
    int gap = 0;
    for (size_t i = 0; i < maxScan; i++) {
        if (lineIsBlack(i)) {
            bar = i + 1;
            gap = 0;
        } else if (++gap > kMaxBarGapRows) {
            break;
        }
    }
    return bar;
}

// Feeds one axis' fresh measurement into its window and returns the windowed
// estimate. The window restarts when the regime flips between "no plausible
// bar" (desktop; a 1-2 px dark border still counts as none) and "a bar on at
// least one side", so a fresh game is not held back by the desktop's zeros.
static void UpdateAxis(BarWindow *w, size_t a, size_t b, size_t extent, size_t *outA, size_t *outB) {
    size_t minBar = (size_t)(extent * kMinSingleBarFraction);
    BOOL edgesBlack = (a >= minBar || b >= minBar);
    BOOL restart = (w->count == 0 || edgesBlack != w->edgesBlack);
    if (!restart) {
        // Dark content can only inflate a measurement, so a bar reading well
        // BELOW the window's minimum is a real geometry change (new window
        // size): restart so the two sides don't mix old and new layouts. Small
        // dips (a toast drawn over the bar, sprite jitter) just join the window.
        size_t minA, minB;
        BarWindowMin(w, &minA, &minB);
        size_t bigDrop = (size_t)(extent * kRestartDropFraction);
        restart = (a + bigDrop < minA) || (b + bigDrop < minB);
    }
    if (restart) {
        BarWindowClear(w);
        w->edgesBlack = edgesBlack;
    }
    BarWindowPush(w, a, b);
    BarWindowMin(w, outA, outB);
}

// Bars on one axis: game geometry, desktop (no / negligible bars), or
// "too much black" (loading screen, fade) which holds the verdict.
typedef NS_ENUM(NSInteger, AxisClass) { AxisClassNone, AxisClassBars, AxisClassBlack };

static AxisClass ClassifyAxis(size_t a, size_t b, size_t extent, size_t maxScan) {
    if (a >= maxScan && b >= maxScan) return AxisClassBlack;
    float e = (float)extent;
    float total = (float)(a + b) / e;
    float small = (float)MIN(a, b) / e;
    float large = (float)MAX(a, b) / e;
    if (total <= kMaxTotalBarFraction) {
        return (total >= kMinTotalBarFraction && large >= kMinSingleBarFraction) ? AxisClassBars : AxisClassNone;
    }
    // Too much black in total. Bars are (near) symmetric, so when the smaller
    // side is a plausible bar the larger side is dark content that nothing has
    // touched yet (a night scene with the sprites all in the upper half);
    // assume the bar mirrors the small side. Otherwise it's a loading screen /
    // fade and the verdict holds.
    if (small >= kMinSingleBarFraction && 2 * small <= kMaxTotalBarFraction) return AxisClassBars;
    return AxisClassBlack;
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

    size_t maxScanV = (size_t)(height * kMaxScanFraction);
    size_t maxScanH = (size_t)(width * kMaxScanFraction);
    size_t topRaw = ScanBar(maxScanV, ^BOOL(size_t i) { return RowIsBlack(base, bytesPerRow, width, i, wide); });
    size_t bottomRaw = ScanBar(maxScanV, ^BOOL(size_t i) { return RowIsBlack(base, bytesPerRow, width, height - 1 - i, wide); });
    size_t leftRaw = ScanBar(maxScanH, ^BOOL(size_t i) { return ColumnIsBlack(base, bytesPerRow, height, i, wide); });
    size_t rightRaw = ScanBar(maxScanH, ^BOOL(size_t i) { return ColumnIsBlack(base, bytesPerRow, height, width - 1 - i, wide); });
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // A frame that is black to the scan limit on every edge says nothing on its
    // own (a fade, or a night scene whose sprites all missed the sampled lines):
    // it neither feeds the windows nor counts as an observation. A pending
    // switch keeps counting down; the Unknown-by-window case below (loading
    // screen geometry) is what cancels it.
    if (topRaw >= maxScanV && bottomRaw >= maxScanV && leftRaw >= maxScanH && rightRaw >= maxScanH) {
        if (now - _lastDiagLogTime >= kDiagLogInterval) {
            _lastDiagLogTime = now;
            Log(LOG_I, @"[Letterbox] frame black to the scan limit, skipped");
        }
        return;
    }

    size_t top, bottom, left, right;
    @synchronized (self) {
        UpdateAxis(&_vertical, topRaw, bottomRaw, height, &top, &bottom);
        UpdateAxis(&_horizontal, leftRaw, rightRaw, width, &left, &right);
    }

    AxisClass v = ClassifyAxis(top, bottom, height, maxScanV);
    AxisClass h = ClassifyAxis(left, right, width, maxScanH);
    StreamContentClass raw;
    if (v == AxisClassBars || h == AxisClassBars) {
        raw = StreamContentClassGame;
    } else if (v == AxisClassBlack || h == AxisClassBlack) {
        raw = StreamContentClassUnknown;     // hold
    } else {
        raw = StreamContentClassDesktop;
    }

    // Does the content sit inside the centred 16:9 region? Ideal 16:9 bars are
    // (H - W*9/16)/2 each; the content fits when both measured bars reach that
    // minus the slack. Larger bars (21:9 cutscenes, dark lower half under the
    // symmetry prior) still fit: snapping by the 16:9 offset clips nothing.
    BOOL fits = NO;
    @synchronized (self) {
        if (raw == StreamContentClassGame) {
            double ideal = ((double)height - (double)width * 9.0 / 16.0) / 2.0;
            if (ideal > 0) {
                double shortfall = MAX(ideal - (double)top, ideal - (double)bottom);
                fits = _fitsHysteresis ? (shortfall <= kFitLeaveSlackPx) : (shortfall <= kFitEnterSlackPx);
            }
        }
        // A held (Unknown) observation says nothing about the geometry; keep
        // the hysteresis so content accepted at 11-24 px short isn't re-tested
        // against the stricter entry slack afterwards.
        if (raw != StreamContentClassUnknown) _fitsHysteresis = fits;
    }

    if (raw != _lastDiagRaw || fits != _lastDiagFits || now - _lastDiagLogTime >= kDiagLogInterval) {
        _lastDiagRaw = raw;
        _lastDiagFits = fits;
        _lastDiagLogTime = now;
        Log(LOG_I, @"[Letterbox] raw=%@ fits16:9=%d tb=%zu/%zu (now %zu/%zu) lr=%zu/%zu (now %zu/%zu) of %zux%zu fmt=%c%c%c%c wide=%d",
            raw == StreamContentClassGame ? @"game" : (raw == StreamContentClassDesktop ? @"desktop" : @"black"),
            fits, top, bottom, topRaw, bottomRaw, left, right, leftRaw, rightRaw, width, height, FOURCC_CHARS(fmt), wide);
    }

    if (raw == StreamContentClassUnknown) {
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
        [self stateQueue_observe:raw fits:fits at:now];
    });
}

#pragma mark - Debounce (on _stateQueue)

- (void)stateQueue_observe:(StreamContentClass)raw fits:(BOOL)fits at:(CFTimeInterval)now {
    if (raw == _current && fits == _currentFits) {
        _pending = StreamContentClassUnknown;
        _pendingToken++;
        return;
    }
    if (raw == _pending && fits == _pendingFits) return; // already counting down
    _pending = raw;
    _pendingFits = fits;
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
    _currentFits = _pendingFits;
    _pending = StreamContentClassUnknown;
    StreamContentClass committed = _current;
    BOOL committedFits = _currentFits;
    Log(LOG_I, @"[Letterbox] verdict -> %@ fits16:9=%d", committed == StreamContentClassGame ? @"game" : @"desktop", committedFits);
    dispatch_async(dispatch_get_main_queue(), ^{
        // A reset/disable that raced the hop to main must not deliver a verdict
        // from the previous configuration.
        if (!self.enabled) return;
        [self.delegate letterboxDetector:self didChangeContentClass:committed fitsSixteenNine:committedFits];
    });
}

@end
