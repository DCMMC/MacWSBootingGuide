#import "MacWSHostDiagnostics.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static NSString *const MacWSLogPath =
    @"/var/mobile/Library/Logs/MacWSHost.log";

BOOL MacWSHostDiagnosticsEnabled(void) {
    static dispatch_once_t onceToken;
    static BOOL enabled;
    dispatch_once(&onceToken, ^{
        enabled = NSProcessInfo.processInfo.environment[
            @"MACWS_RUNTIME_DIAGNOSTICS"] != nil ||
            access("/var/mnt/rootfs/private/tmp/macws_runtime_diagnostics",
                   F_OK) == 0;
    });
    return enabled;
}

double MacWSMachMilliseconds(uint64_t start, uint64_t end) {
    if (!start || end < start) return -1.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ (void)mach_timebase_info(&timebase); });
    if (!timebase.denom) return -1.0;
    long double nanoseconds = (long double)(end - start) *
        timebase.numer / timebase.denom;
    return (double)(nanoseconds / 1000000.0L);
}

void MacWSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:args];
    va_end(args);
    NSLog(@"%@", message);

    static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&logLock);
    FILE *file = fopen(MacWSLogPath.fileSystemRepresentation, "a");
    if (file) {
        fprintf(file, "%.3f %s\n", NSDate.date.timeIntervalSince1970,
                message.UTF8String);
        fclose(file);
    }
    pthread_mutex_unlock(&logLock);
}
