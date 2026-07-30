// iOS-native thermal sensor snapshot for the mandatory MacWS watchdog.
// This runs outside the chroot so NSProcessInfo and AppleSmartBattery expose
// the real iPad thermal state. It is intentionally one-shot: the shell
// watchdog owns policy, sampling cadence, logging and teardown.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#include <inttypes.h>
#include <stdio.h>

static int64_t MacWSReadIntegerProperty(io_registry_entry_t service,
                                        CFStringRef key) {
    if (service == IO_OBJECT_NULL) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, key, kCFAllocatorDefault, 0);
    if (!value) return -1;
    int64_t result = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result);
    }
    CFRelease(value);
    return result;
}

static const char *MacWSThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return "nominal";
        case NSProcessInfoThermalStateFair: return "fair";
        case NSProcessInfoThermalStateSerious: return "serious";
        case NSProcessInfoThermalStateCritical: return "critical";
    }
    return "unknown";
}

static int MacWSThermalStateExitCode(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return 0;
        case NSProcessInfoThermalStateFair: return 2;
        case NSProcessInfoThermalStateSerious: return 3;
        case NSProcessInfoThermalStateCritical: return 4;
    }
    return 5;
}

int main(void) {
    @autoreleasepool {
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        NSProcessInfoThermalState thermalState = processInfo.thermalState;

        CFMutableDictionaryRef matching = IOServiceMatching(
            "AppleSmartBattery");
        io_service_t battery = matching
            ? IOServiceGetMatchingService(kIOMasterPortDefault, matching)
            : IO_OBJECT_NULL;
        int64_t temperature = MacWSReadIntegerProperty(
            battery, CFSTR("Temperature"));
        int64_t virtualTemperature = MacWSReadIntegerProperty(
            battery, CFSTR("VirtualTemperature"));
        if (battery != IO_OBJECT_NULL) IOObjectRelease(battery);

        int64_t effectiveTemperature = temperature;
        if (virtualTemperature > effectiveTemperature)
            effectiveTemperature = virtualTemperature;

        // AppleSmartBattery reports these two properties in centi-degrees C
        // on the target iPad (runtime witnesses: 2959 and 2989). Keep the raw
        // integers in the machine-readable output so the watchdog never has
        // to parse locale-dependent floating point.
        printf("thermal-state=%s raw=%ld low-power=%s "
               "battery-temp-centic=%" PRId64 " "
               "virtual-temp-centic=%" PRId64 " "
               "effective-temp-centic=%" PRId64 " uptime=%.3f\n",
               MacWSThermalStateName(thermalState), (long)thermalState,
               processInfo.lowPowerModeEnabled ? "yes" : "no",
               temperature, virtualTemperature, effectiveTemperature,
               processInfo.systemUptime);
        fflush(stdout);

        // Preserve a distinct exit status when numeric battery telemetry is
        // absent. The shell still parses thermal-state first: only an observed
        // critical state intervenes, while missing numeric data is log-only.
        if (effectiveTemperature < 0) return 6;
        return MacWSThermalStateExitCode(thermalState);
    }
}
