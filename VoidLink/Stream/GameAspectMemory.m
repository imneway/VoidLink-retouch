//
//  GameAspectMemory.m
//  VoidLink
//

#import "GameAspectMemory.h"

NSNotificationName const GameAspectMemoryDidClearNotification = @"GameAspectMemoryDidClearNotification";

static NSString * const kDefaultsKey = @"gameAspectMemoryV1";
static NSString * const kSightingsKey = @"sightings";   // NSArray<NSNumber *> of epoch seconds
static NSString * const kFullKey = @"full";             // BOOL
static NSString * const kManualKey = @"manualFits";     // BOOL, absent = no choice

// Three separate sightings, each at least a minute after the previous one: an
// in-game overlay (Steam's Shift+Tab draws over the whole display, bars
// included) is opened briefly and rarely three times in a row.
static const NSUInteger kSightingsToLearn = 3;
static const NSTimeInterval kMinSightingSpacing = 60.0;

@implementation GameAspectMemory {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_entries;
}

+ (GameAspectMemory *)shared {
    static GameAspectMemory *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[GameAspectMemory alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionary];
        NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDefaultsKey];
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self->_entries[key] = [obj mutableCopy];
            }
        }];
    }
    return self;
}

static NSString *Key(NSString *process) {
    return process.lowercaseString;
}

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:_entries forKey:kDefaultsKey];
}

- (NSMutableDictionary *)entryFor:(NSString *)process create:(BOOL)create {
    NSString *key = Key(process);
    if (key.length == 0) return nil;
    NSMutableDictionary *entry = _entries[key];
    if (!entry && create) {
        entry = [NSMutableDictionary dictionary];
        _entries[key] = entry;
    }
    return entry;
}

- (BOOL)isLearnedFullForProcess:(NSString *)process {
    return [[self entryFor:process create:NO][kFullKey] boolValue];
}

- (NSNumber *)manualFitsForProcess:(NSString *)process {
    id value = [self entryFor:process create:NO][kManualKey];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

- (void)setManualFits:(BOOL)fits forProcess:(NSString *)process {
    NSMutableDictionary *entry = [self entryFor:process create:YES];
    if (!entry) return;
    entry[kManualKey] = @(fits);
    [self save];
}

- (BOOL)recordContentInBarsForProcess:(NSString *)process count:(NSUInteger *)count {
    NSMutableDictionary *entry = [self entryFor:process create:YES];
    if (!entry) return NO;
    NSArray *old = [entry[kSightingsKey] isKindOfClass:[NSArray class]] ? entry[kSightingsKey] : @[];
    NSMutableArray<NSNumber *> *sightings = [old mutableCopy];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSNumber *last = sightings.lastObject;
    BOOL wasFull = [entry[kFullKey] boolValue];
    if (!last || now - last.doubleValue >= kMinSightingSpacing) {
        [sightings addObject:@(now)];
        while (sightings.count > kSightingsToLearn) [sightings removeObjectAtIndex:0];
        entry[kSightingsKey] = sightings;
        if (sightings.count >= kSightingsToLearn) entry[kFullKey] = @YES;
        [self save];
    }
    if (count) *count = sightings.count;
    return !wasFull && [entry[kFullKey] boolValue];
}

- (void)clearAll {
    [_entries removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kDefaultsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:GameAspectMemoryDidClearNotification object:self];
}

@end
