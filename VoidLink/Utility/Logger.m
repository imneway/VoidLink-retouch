//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Logger.h"
#import <os/log.h>

#if defined(NDEBUG)
static LogLevel LoggerLogLevel = LOG_I;
#else
// Debug is too spammy during discovery
// static LogLevel LoggerLogLevel = LOG_D;
static LogLevel LoggerLogLevel = LOG_I;
#endif

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    NSString* levelPrefix = @"";

    if (level < LoggerLogLevel) {
        return;
    }

    switch(level) {
        case LOG_D:
            levelPrefix = PRFX_DEBUG;
            break;
        case LOG_I:
            levelPrefix = PRFX_INFO;
            break;
        case LOG_W:
            levelPrefix = PRFX_WARN;
            break;
        case LOG_E:
            levelPrefix = PRFX_ERROR;
            break;
        default:
            levelPrefix = @"";
            assert(false);
            break;
    }
    NSString* prefixedString;
    if (tag) {
        prefixedString = [NSString stringWithFormat:@"%@ (%@) %@", levelPrefix, tag, fmt];
    } else {
        prefixedString = [NSString stringWithFormat:@"%@ %@", levelPrefix, fmt];
    }
    // Through NSLog every %@ / %s argument is redacted to <private> in the
    // device syslog, which hides the whole message once the format itself is
    // built at runtime. Format here and log the result public, so a sideloaded
    // build can be diagnosed from a Mac without the logging profile.
    NSString* message = [[NSString alloc] initWithFormat:prefixedString arguments:args];
    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    if (level == LOG_D) type = OS_LOG_TYPE_DEBUG;
    else if (level >= LOG_W) type = OS_LOG_TYPE_ERROR;
    os_log_with_type(OS_LOG_DEFAULT, type, "%{public}@", message);
}

void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, tag, fmt, args);
    va_end(args);
}
