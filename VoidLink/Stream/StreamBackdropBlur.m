//
//  StreamBackdropBlur.m
//  VoidLink
//

#import "StreamBackdropBlur.h"
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

static const CFTimeInterval kSampleInterval = 1.0;
// Screen points per output pixel. The capsule layer magnifies the result
// with linear filtering, which on top of the blur reads as a smooth backdrop.
static const CGFloat kPointsPerPixel = 4.0;
// Box radius (output pixels) of each of the three passes; three box passes
// approximate a gaussian with sigma ~2.4 px ~ 10 pt.
static const int kBoxRadius = 2;
// Sampled around the capsule so its edges blur against real content, then
// cropped: 4 px = 16 pt.
static const int kMarginPixels = 4;
// Source samples per output pixel along each axis (box average).
static const int kSubSamples = 4;

typedef struct {
    BOOL active;
    CGRect norm;     // capsule rect, frame-normalised
    int innerW, innerH;
} BackdropSlot;

// Wrapped so a snapshot of all slots can be captured by value in a block.
typedef struct { BackdropSlot s[StreamBackdropBlurMaxSlots]; } BackdropSlots;

@implementation StreamBackdropBlur {
    dispatch_queue_t _queue;
    atomic_bool _busy;
    atomic_uint _generation;
    // @synchronized(self)
    BOOL _enabled;
    CFTimeInterval _lastSampleTime;
    BackdropSlot _slots[StreamBackdropBlurMaxSlots];
    // analysis queue only
    uint64_t _lastHash[StreamBackdropBlurMaxSlots];
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.voidlink.backdrop-blur",
                                       dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        atomic_init(&_busy, false);
        atomic_init(&_generation, 0);
    }
    return self;
}

- (BOOL)enabled {
    @synchronized (self) { return _enabled; }
}

- (void)setEnabled:(BOOL)enabled {
    @synchronized (self) {
        if (enabled == _enabled) return;
        if (enabled) _lastSampleTime = 0; // first frame right away
        _enabled = enabled;
        // The host clears the capsules when sampling stops, so whatever was
        // delivered before is gone: drop in-flight results and the dedup hashes.
        // Bumped under the lock that snapshots slots + generation together.
        atomic_fetch_add(&_generation, 1);
    }
    dispatch_async(_queue, ^{ memset(self->_lastHash, 0, sizeof(self->_lastHash)); });
}

- (void)setSlot:(NSUInteger)slot normalizedRect:(CGRect)normalizedRect pointSize:(CGSize)pointSize {
    if (slot >= StreamBackdropBlurMaxSlots) return;
    BackdropSlot next = {0};
    if (!CGRectIsNull(normalizedRect) && !CGRectIsEmpty(normalizedRect) && pointSize.width > 0 && pointSize.height > 0) {
        next.active = YES;
        next.norm = normalizedRect;
        next.innerW = MAX(1, (int)ceil(pointSize.width / kPointsPerPixel));
        next.innerH = MAX(1, (int)ceil(pointSize.height / kPointsPerPixel));
    }
    @synchronized (self) {
        BackdropSlot cur = _slots[slot];
        BOOL same = (cur.active == next.active)
            && (!next.active || (CGRectEqualToRect(cur.norm, next.norm) && cur.innerW == next.innerW && cur.innerH == next.innerH));
        if (same) return;
        _slots[slot] = next;
        _lastSampleTime = 0; // resample on the next frame
        // Results computed for the old geometry must not land after this, and
        // the new geometry must deliver even if its pixels hash the same.
        atomic_fetch_add(&_generation, 1);
    }
    dispatch_async(_queue, ^{ self->_lastHash[slot] = 0; });
}

- (void)offerPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CFTimeInterval now = CACurrentMediaTime();
    BackdropSlots slots;
    unsigned generation;
    @synchronized (self) {
        if (!_enabled || now - _lastSampleTime < kSampleInterval) return;
        bool expected = false;
        if (!atomic_compare_exchange_strong(&_busy, &expected, true)) return;
        _lastSampleTime = now;
        memcpy(slots.s, _slots, sizeof(slots.s));
        generation = atomic_load(&_generation); // consistent with the snapshot
    }
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(_queue, ^{
        [self analyze:pixelBuffer slots:slots.s generation:generation];
        CVPixelBufferRelease(pixelBuffer);
        atomic_store(&self->_busy, false);
    });
}

#pragma mark - Analysis (utility queue)

typedef struct {
    const uint8_t *y; size_t yStride;
    const uint8_t *c; size_t cStride;
    size_t width, height;
    int bytesPerSample;   // 1 (8-bit) or 2 (10-bit MSB-aligned in 16)
    int chromaShiftX, chromaShiftY;
    BOOL fullRange;
} YUVPlanes;

static inline int SampleY(const YUVPlanes *p, size_t x, size_t y) {
    const uint8_t *row = p->y + y * p->yStride;
    return p->bytesPerSample == 2 ? row[x * 2 + 1] : row[x];
}

static inline void SampleC(const YUVPlanes *p, size_t x, size_t y, int *cb, int *cr) {
    const uint8_t *row = p->c + (y >> p->chromaShiftY) * p->cStride;
    size_t cx = x >> p->chromaShiftX;
    if (p->bytesPerSample == 2) {
        *cb = row[cx * 4 + 1];
        *cr = row[cx * 4 + 3];
    } else {
        *cb = row[cx * 2];
        *cr = row[cx * 2 + 1];
    }
}

static BOOL PlanesForBuffer(CVPixelBufferRef pb, YUVPlanes *out) {
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    int bps; int sx = 1, sy = 1; BOOL full;
    switch (fmt) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  bps = 1; full = NO;  break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   bps = 1; full = YES; break;
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: bps = 2; full = NO;  break;
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  bps = 2; full = YES; break;
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: bps = 2; full = NO;  sy = 0; break;
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:  bps = 2; full = YES; sy = 0; break;
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: bps = 2; full = NO;  sx = 0; sy = 0; break;
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:  bps = 2; full = YES; sx = 0; sy = 0; break;
        default: return NO;
    }
    if (CVPixelBufferGetPlaneCount(pb) < 2) return NO;
    out->y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    out->c = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (!out->y || !out->c) return NO;
    out->yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    out->cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    out->width = CVPixelBufferGetWidthOfPlane(pb, 0);
    out->height = CVPixelBufferGetHeightOfPlane(pb, 0);
    out->bytesPerSample = bps;
    out->chromaShiftX = sx;
    out->chromaShiftY = sy;
    out->fullRange = full;
    return out->width > 0 && out->height > 0;
}

static inline uint8_t Clamp8(float v) {
    return v <= 0 ? 0 : (v >= 255 ? 255 : (uint8_t)(v + 0.5f));
}

// BT.709; the backdrop is blurred and tinted, so HDR/2020 hosts being a bit
// off in hue doesn't matter.
static void YCbCrToRGB(const YUVPlanes *p, float y, float cb, float cr, uint8_t *rgb) {
    if (!p->fullRange) {
        y = (y - 16.0f) * (255.0f / 219.0f);
        cb = (cb - 128.0f) * (255.0f / 224.0f);
        cr = (cr - 128.0f) * (255.0f / 224.0f);
    } else {
        cb -= 128.0f;
        cr -= 128.0f;
    }
    rgb[0] = Clamp8(y + 1.5748f * cr);
    rgb[1] = Clamp8(y - 0.1873f * cb - 0.4681f * cr);
    rgb[2] = Clamp8(y + 1.8556f * cb);
}

// One horizontal + one vertical box pass over an RGBX image, edge-clamped.
static void BoxBlurPass(uint8_t *img, uint8_t *tmp, int w, int h, int r) {
    const int n = 2 * r + 1;
    for (int y = 0; y < h; y++) {
        uint8_t *row = img + (size_t)y * w * 4, *dst = tmp + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            int s0 = 0, s1 = 0, s2 = 0;
            for (int k = -r; k <= r; k++) {
                int xx = x + k; xx = xx < 0 ? 0 : (xx >= w ? w - 1 : xx);
                s0 += row[xx * 4]; s1 += row[xx * 4 + 1]; s2 += row[xx * 4 + 2];
            }
            dst[x * 4] = s0 / n; dst[x * 4 + 1] = s1 / n; dst[x * 4 + 2] = s2 / n; dst[x * 4 + 3] = 255;
        }
    }
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) {
            int s0 = 0, s1 = 0, s2 = 0;
            for (int k = -r; k <= r; k++) {
                int yy = y + k; yy = yy < 0 ? 0 : (yy >= h ? h - 1 : yy);
                const uint8_t *px = tmp + ((size_t)yy * w + x) * 4;
                s0 += px[0]; s1 += px[1]; s2 += px[2];
            }
            uint8_t *d = img + ((size_t)y * w + x) * 4;
            d[0] = s0 / n; d[1] = s1 / n; d[2] = s2 / n; d[3] = 255;
        }
    }
}

static uint64_t HashBytes(const uint8_t *bytes, size_t len) {
    uint64_t h = 1469598103934665603ULL; // FNV-1a
    for (size_t i = 0; i < len; i++) { h ^= bytes[i]; h *= 1099511628211ULL; }
    return h;
}

// Builds the blurred image for one slot. Returns NULL when there is nothing
// to show; *unchanged is set when the result equals the last delivered one.
- (CGImageRef)copyImageForSlot:(NSUInteger)index slot:(BackdropSlot)slot planes:(const YUVPlanes *)p unchanged:(BOOL *)unchanged CF_RETURNS_RETAINED {
    *unchanged = NO;
    const int m = kMarginPixels;
    const int w = slot.innerW + 2 * m, h = slot.innerH + 2 * m;

    // Frame pixels per output pixel, from the capsule's normalised size.
    const double fx0 = slot.norm.origin.x * p->width, fy0 = slot.norm.origin.y * p->height;
    const double stepX = slot.norm.size.width * p->width / slot.innerW;
    const double stepY = slot.norm.size.height * p->height / slot.innerH;

    uint8_t *img = malloc((size_t)w * h * 4);
    uint8_t *tmp = malloc((size_t)w * h * 4);
    if (!img || !tmp) { free(img); free(tmp); return NULL; }

    for (int oy = 0; oy < h; oy++) {
        for (int ox = 0; ox < w; ox++) {
            float sy = 0, scb = 0, scr = 0;
            for (int j = 0; j < kSubSamples; j++) {
                double fy = fy0 + (oy - m + (j + 0.5) / kSubSamples) * stepY;
                size_t yy = fy < 0 ? 0 : (fy >= p->height ? p->height - 1 : (size_t)fy);
                for (int i = 0; i < kSubSamples; i++) {
                    double fx = fx0 + (ox - m + (i + 0.5) / kSubSamples) * stepX;
                    size_t xx = fx < 0 ? 0 : (fx >= p->width ? p->width - 1 : (size_t)fx);
                    int cb, cr;
                    SampleC(p, xx, yy, &cb, &cr);
                    sy += SampleY(p, xx, yy); scb += cb; scr += cr;
                }
            }
            const float inv = 1.0f / (kSubSamples * kSubSamples);
            uint8_t *d = img + ((size_t)oy * w + ox) * 4;
            YCbCrToRGB(p, sy * inv, scb * inv, scr * inv, d);
            d[3] = 255;
        }
    }
    for (int pass = 0; pass < 3; pass++) BoxBlurPass(img, tmp, w, h, kBoxRadius);
    free(tmp);

    // Crop the margin into a tightly packed inner image.
    const int iw = slot.innerW, ih = slot.innerH;
    uint8_t *inner = malloc((size_t)iw * ih * 4);
    if (!inner) { free(img); return NULL; }
    for (int y = 0; y < ih; y++) {
        memcpy(inner + (size_t)y * iw * 4, img + ((size_t)(y + m) * w + m) * 4, (size_t)iw * 4);
    }
    free(img);

    uint64_t hash = HashBytes(inner, (size_t)iw * ih * 4);
    if (hash == _lastHash[index]) {
        free(inner);
        *unchanged = YES;
        return NULL;
    }
    _lastHash[index] = hash;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(inner, iw, ih, 8, (size_t)iw * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    free(inner);
    return image;
}

- (void)analyze:(CVPixelBufferRef)pixelBuffer slots:(const BackdropSlot *)slots generation:(unsigned)generation {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    YUVPlanes planes;
    BOOL ok = PlanesForBuffer(pixelBuffer, &planes);
    CGImageRef images[StreamBackdropBlurMaxSlots] = {0};
    BOOL deliver[StreamBackdropBlurMaxSlots] = {0};
    for (NSUInteger i = 0; i < StreamBackdropBlurMaxSlots; i++) {
        if (!slots[i].active) { _lastHash[i] = 0; continue; }
        if (!ok) continue;
        BOOL unchanged = NO;
        images[i] = [self copyImageForSlot:i slot:slots[i] planes:&planes unchanged:&unchanged];
        deliver[i] = !unchanged && images[i] != NULL;
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    for (NSUInteger i = 0; i < StreamBackdropBlurMaxSlots; i++) {
        if (!deliver[i]) continue;
        CGImageRef image = images[i];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Geometry changed or sampling stopped since this frame was taken.
            if (atomic_load(&self->_generation) != generation || !self.enabled) {
                // Forget the hash so the next sample re-delivers.
                dispatch_async(self->_queue, ^{ self->_lastHash[i] = 0; });
            } else if (self.imageHandler) {
                self.imageHandler(i, image);
            }
            CGImageRelease(image);
        });
    }
}

@end
