@import Darwin;
@import Foundation;
@import Metal;
#include <mach/mach.h>
#include <stdio.h>

void xpc_add_bundle(char *, int);
void xpc_connection_set_instance(xpc_connection_t, uuid_t);
int main(int argc, const char * argv[]) {
	@autoreleasepool {
		printf("debugbydcmmc My pid: %d\n", getpid());
        printf("Sleeping for 60 seconds to allow host to inject bootstrap port...\n");
        sleep(60);

		void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", 1); assert(metal);
        NSLog(@"debugbydcmmc Metal.framework dlopen");
      xpc_add_bundle("/home/Metal.framework/XPCServices/MTLCompilerService.xpc", 2);
		uuid_t uuid;
		uuid_generate(uuid);
		xpc_connection_t connection = xpc_connection_create("com.apple.MTLCompilerService", 0);
		xpc_connection_set_instance(connection, uuid);
		xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {
			NSLog(@"debugbydcmmc Process received event: %@", [object description]);
		});
		xpc_connection_resume(connection);

		xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_uint64(dict, "requestType", 9); // XPCCompilerConnection::checkConnectionActive(bool&)
		xpc_object_t object = xpc_connection_send_message_with_reply_sync(connection, dict);
		NSLog(@"debugbydcmmc Received synced event: %@", [object description]);
		NSLog(@"debugbydcmmc XPC connection now: %@", [connection description]);
		sleep(1);
	}
    return 0;
}
