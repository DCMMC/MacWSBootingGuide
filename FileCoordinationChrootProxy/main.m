@import Darwin;
#include <dlfcn.h>
#include <fcntl.h>
#include <xpc/xpc.h>

static void MacWSProgressBridgeLog(const char *message) {
    int fd = open("/var/jb/var/mobile/progress-bridge.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dprintf(fd, "[ProgressBridge pid=%d] %s\n", getpid(),
            message ?: "(null)");
    close(fd);
}

// Foundation's NSProgress wire protocol is implemented by the native iPadOS
// filecoordinationd.  The chroot root application domain cannot look that
// user/501 endpoint up directly, so this dedicated iOS XPC process relays the
// unmodified dictionaries and replies.  It deliberately does not share a
// binary with the chroot+exec proxies: loading libxpc in those launch stubs
// consumes XPC_FLAGS before the real macOS service can check in.
int main(void) {
    dispatch_queue_t queue = dispatch_queue_create(
        "com.macwsguide.progress-bridge", DISPATCH_QUEUE_SERIAL);
    typedef xpc_connection_t (*create_mach_service_fn)(
        const char *, dispatch_queue_t, uint64_t);
    create_mach_service_fn createMach = (create_mach_service_fn)dlsym(
        RTLD_DEFAULT, "xpc_connection_create_mach_service");
    xpc_connection_t upstream = createMach
        ? createMach("com.apple.ProgressReporting", queue, 0) : NULL;
    if (!upstream) {
        MacWSProgressBridgeLog("failed to create upstream connection");
        return 70;
    }
    xpc_connection_set_event_handler(upstream, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            MacWSProgressBridgeLog(xpc_dictionary_get_string(
                event, XPC_ERROR_KEY_DESCRIPTION));
        }
    });
    xpc_connection_resume(upstream);
    usleep(100000);
    MacWSProgressBridgeLog("ready");

    xpc_connection_t listener = createMach(
        "com.apple.ProgressReporting", queue,
        XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        MacWSProgressBridgeLog("failed to create local listener");
        return 71;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t object) {
        if (xpc_get_type(object) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)object;
        xpc_connection_set_target_queue(peer, queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t clientReply = xpc_dictionary_create_reply(event);
            if (!clientReply) {
                xpc_connection_send_message(upstream, event);
                return;
            }
            xpc_connection_send_message_with_reply(
                upstream, event, queue, ^(xpc_object_t upstreamReply) {
                    if (xpc_get_type(upstreamReply) != XPC_TYPE_DICTIONARY) {
                        MacWSProgressBridgeLog(
                            "upstream returned non-dictionary reply");
                        xpc_connection_cancel(peer);
                        return;
                    }
                    xpc_dictionary_apply(upstreamReply,
                        ^bool(const char *key, xpc_object_t value) {
                            xpc_dictionary_set_value(clientReply, key, value);
                            return true;
                        });
                    xpc_connection_send_message(peer, clientReply);
                });
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}
