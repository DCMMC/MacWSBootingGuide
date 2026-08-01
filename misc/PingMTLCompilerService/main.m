@import Darwin;
@import Foundation;
@import Metal;
#include <mach/mach.h>
#include <stdio.h>
#include <uuid/uuid.h>

// The rootless iOS SDK bundled with Theos omits xpc/xpc.h.  Keep the probe on
// the stable C ABI instead of depending on private SDK headers.
typedef void *xpc_object_t;
typedef xpc_object_t xpc_connection_t;
typedef void (^xpc_handler_t)(xpc_object_t);
extern xpc_connection_t xpc_connection_create(const char *, void *);
extern void xpc_connection_set_event_handler(xpc_connection_t, xpc_handler_t);
extern void xpc_connection_resume(xpc_connection_t);
extern xpc_object_t xpc_dictionary_create(const char * const *,
                                          const xpc_object_t *, size_t);
extern void xpc_dictionary_set_uint64(xpc_object_t, const char *, uint64_t);
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t, xpc_object_t);

void xpc_add_bundle(char *, int);
void xpc_connection_set_instance(xpc_connection_t, uuid_t);
int main(int argc, const char * argv[]) {
	@autoreleasepool {
		printf("debugbydcmmc My pid: %d\n", getpid());
        // printf("Sleeping for 60 seconds to allow host to inject bootstrap port...\n");
        // sleep(60);

		void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", 1); assert(metal);
        NSLog(@"debugbydcmmc Metal.framework dlopen");
      xpc_add_bundle("/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc", 2);
		uuid_t uuid;
		uuid_generate(uuid);
		xpc_connection_t connection = xpc_connection_create("com.apple.MTLCompilerService", 0);
		xpc_connection_set_instance(connection, uuid);
		xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {
			NSLog(@"debugbydcmmc Process received event: %@",
                  [(__bridge id)object description]);
		});
		xpc_connection_resume(connection);

		xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_uint64(dict, "requestType", 9); // XPCCompilerConnection::checkConnectionActive(bool&)
		xpc_object_t object = xpc_connection_send_message_with_reply_sync(connection, dict);
		NSLog(@"debugbydcmmc Received synced event: %@",
              [(__bridge id)object description]);
		NSLog(@"debugbydcmmc XPC connection now: %@",
              [(__bridge id)connection description]);
		const char *holdValue = getenv("MACWS_PING_HOLD_SECONDS");
		unsigned holdSeconds = holdValue ? (unsigned)strtoul(holdValue, NULL, 10) : 1;
		if (holdSeconds > 30) holdSeconds = 30;
		sleep(holdSeconds);
	}
    return 0;
}
