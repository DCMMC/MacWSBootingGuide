#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#include "macws_control_protocol.h"

// Minimal on-device witness for the typed MacWS Host control service.  This
// deliberately exposes only the same fixed operations as the public protocol;
// it is not a shell bridge and cannot launch arbitrary commands.
int main(int argc, const char *argv[]) {
    const char *operation = argc > 1 ? argv[1] : MACWS_CONTROL_OP_STATUS;
    xpc_connection_t (*createMachService)(
        const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    xpc_connection_t connection = createMachService
        ? createMachService(
              MACWS_CONTROL_SERVICE,
              dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0)
        : NULL;
    if (!connection) {
        fprintf(stderr, "macws_control_probe: connection create failed\n");
        return 69;
    }
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP, operation);
    if (strcmp(operation, MACWS_CONTROL_OP_LAUNCH_APP) == 0) {
        if (argc != 3) {
            fprintf(stderr,
                    "usage: macws_control_probe launch-app APP_ID\n");
            return 64;
        }
        xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_APP_ID, argv[2]);
    }

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        char *description = reply ? xpc_copy_description(reply) : NULL;
        fprintf(stderr, "macws_control_probe: invalid reply: %s\n",
                description ?: "<null>");
        free(description);
        return 70;
    }
    bool ok = xpc_dictionary_get_bool(reply, "ok");
    const char *message = xpc_dictionary_get_string(reply, "message");
    long long launchedPID = xpc_dictionary_get_int64(
        reply, "launched_app_pid");
    printf("ok=%s launched-pid=%lld message=%s\n",
           ok ? "yes" : "no", launchedPID, message ?: "");
    if (strcmp(operation, MACWS_CONTROL_OP_STATUS) == 0) {
        printf("system-settings-available=%s maps-available=%s\n",
               xpc_dictionary_get_bool(
                   reply, "system_settings_available") ? "yes" : "no",
               xpc_dictionary_get_bool(
                   reply, "maps_available") ? "yes" : "no");
    }
    return ok ? 0 : 1;
}
