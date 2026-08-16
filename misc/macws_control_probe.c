#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#include "macws_control_protocol.h"

// Procursus/Theos' public iOS 16 XPC shim intentionally declares only a
// small subset of libxpc.  Keep this witness buildable on-device without
// weakening its reply validation; the symbols below are exported by the
// platform libxpc and are present in Apple's complete SDK headers.
extern const struct _xpc_type_s _xpc_type_dictionary;
#ifndef XPC_TYPE_DICTIONARY
#define XPC_TYPE_DICTIONARY (&_xpc_type_dictionary)
#endif
xpc_type_t xpc_get_type(xpc_object_t object);
char *xpc_copy_description(xpc_object_t object);
bool xpc_dictionary_get_bool(xpc_object_t dictionary, const char *key);
int64_t xpc_dictionary_get_int64(xpc_object_t dictionary, const char *key);
void xpc_dictionary_set_int64(xpc_object_t dictionary, const char *key,
                              int64_t value);

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
    } else if (strcmp(operation, MACWS_CONTROL_OP_LAUNCH_PATH) == 0) {
        if (argc != 3) {
            fprintf(stderr,
                    "usage: macws_control_probe launch-path /absolute/App.app\n");
            return 64;
        }
        xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_APP_PATH,
                                  argv[2]);
    } else if (strcmp(operation, MACWS_CONTROL_OP_REFRESH_DOCK) == 0) {
        if (argc != 3) {
            fprintf(stderr,
                    "usage: macws_control_probe refresh-dock TARGET_PID\n");
            return 64;
        }
        char *end = NULL;
        long value = strtol(argv[2], &end, 10);
        if (!end || *end != '\0' || value <= 1 || value > INT32_MAX) {
            fprintf(stderr, "invalid target pid: %s\n", argv[2]);
            return 64;
        }
        xpc_dictionary_set_int64(request, MACWS_CONTROL_KEY_TARGET_PID,
                                 (int64_t)value);
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
        const char *startupLog = xpc_dictionary_get_string(
            reply, "startup_log");
        printf("protocol=%llu startup-retry=%s startup-log-bytes=%zu "
               "phase=%s error=%s "
               "system-settings-available=%s maps-available=%s\n",
               (unsigned long long)xpc_dictionary_get_uint64(
                   reply, "protocol_version"),
               xpc_dictionary_get_bool(
                   reply, "startup_retry_available") ? "yes" : "no",
               startupLog ? strlen(startupLog) : 0,
               xpc_dictionary_get_string(reply, "phase") ?: "",
               xpc_dictionary_get_string(reply, "last_error") ?: "",
               xpc_dictionary_get_bool(
                   reply, "system_settings_available") ? "yes" : "no",
               xpc_dictionary_get_bool(
                   reply, "maps_available") ? "yes" : "no");
    }
    return ok ? 0 : 1;
}
