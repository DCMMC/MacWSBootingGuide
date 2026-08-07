// MacWSHostSupport.h — shared statics for the MacWS Host app.
// Logging, runtime gates, frame/ack transport helpers and the HID keymap
// used by both main.m and MacWSMetalView.  Splitting these out of the
// former single-file application keeps each module compilable on its own.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

#import "macws_host_protocol.h"
#import "macws_stream_protocol.h"

// A string macro (not an extern array) so existing `sizeof(...)` uses and the
// sockaddr_un _Static_assert keep working unchanged.
#define MacWSInputSocketPath "/var/mnt/rootfs/private/tmp/macws_host_input.sock"

// Declares the native-device selector MacWSIOSurfaceReadOnlyTextureAlignment
// calls through a plain NSObject cast.
@interface NSObject (MacWSMetalIOSurfaceAlignment)
- (NSUInteger)iosurfaceReadOnlyTextureAlignmentBytes;
@end

FOUNDATION_EXPORT NSString *const MacWSFramePath;
FOUNDATION_EXPORT NSString *const MacWSCaptureAckPath;
FOUNDATION_EXPORT NSString *const MacWSLogPath;
FOUNDATION_EXPORT void MacWSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT BOOL MacWSHostDiagnosticsEnabled(void);
FOUNDATION_EXPORT BOOL MacWSLegacyFramebufferFallbackEnabled(void);
FOUNDATION_EXPORT BOOL MacWSAppInputEndpointReady(int32_t pid);
FOUNDATION_EXPORT double MacWSMachMilliseconds(uint64_t start, uint64_t end);
FOUNDATION_EXPORT BOOL MacWSStreamFrameGeometryEqual(
    MacWSStreamFrameDescriptor left, MacWSStreamFrameDescriptor right);
FOUNDATION_EXPORT NSUInteger MacWSIOSurfaceReadOnlyTextureAlignment(
    id<MTLDevice> device);
FOUNDATION_EXPORT CGFloat MacWSDensityModeFactor(MacWSHostDisplayDensity density);
FOUNDATION_EXPORT BOOL MacWSReadCaptureAck(uint64_t *generationOut);
FOUNDATION_EXPORT uint16_t MacWSMacKeyCodeForHIDUsage(NSInteger usage);
FOUNDATION_EXPORT uint32_t MacWSKeySymForHIDUsage(
    NSInteger usage, NSString *characters, UIKeyModifierFlags modifiers);
FOUNDATION_EXPORT NSInteger MacWSHIDUsageForASCII(uint32_t scalar);
