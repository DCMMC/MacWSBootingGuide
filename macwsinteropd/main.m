#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <CommonCrypto/CommonDigest.h>
#include <xpc/xpc.h>

#include "macws_interop_protocol.h"

static dispatch_queue_t InteropQueue;
static NSMutableSet *Clients;
static NSInteger LastPasteboardChange = -1;
static NSInteger AppliedPasteboardChange = -1;
static uint64_t DaemonOriginID;
static uint64_t Generation;
static uint64_t LastIncomingOrigin;
static uint64_t LastIncomingGeneration;

static void InteropLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void InteropLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MACWS-INTEROP %s\n", message.UTF8String);
    fflush(stderr);
}

static void Digest(NSData *data, uint8_t output[16]) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    memcpy(output, digest, 16);
}

static xpc_object_t EventForData(MacWSInteropKind kind, NSData *data,
                                 NSString *type) {
    MacWSInteropItemDescriptor descriptor = {
        .magic = MACWS_INTEROP_MAGIC,
        .version = MACWS_INTEROP_VERSION,
        .size = sizeof(MacWSInteropItemDescriptor),
        .kind = kind,
        .flags = MacWSInteropInlinePayload | MacWSInteropFromMacOS,
        .generation = ++Generation,
        .originID = DaemonOriginID,
        .payloadLength = data.length,
    };
    Digest(data, descriptor.digest);
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_EVENT,
                              MACWS_INTEROP_EVENT_CLIPBOARD);
    xpc_dictionary_set_data(event, MACWS_INTEROP_KEY_DESCRIPTOR,
                            &descriptor, sizeof(descriptor));
    xpc_dictionary_set_data(event, MACWS_INTEROP_KEY_PAYLOAD,
                            data.bytes, data.length);
    xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_TYPE, type.UTF8String);
    return event;
}

static void Broadcast(xpc_object_t event) {
    for (id object in [Clients copy]) {
        xpc_connection_t connection = (xpc_connection_t)object;
        xpc_connection_send_message(connection, event);
    }
}

static void PublishPasteboardIfChanged(void) {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger change = pasteboard.changeCount;
    if (change == LastPasteboardChange) return;
    LastPasteboardChange = change;
    if (change == AppliedPasteboardChange) return;

    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count) {
        xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(event, MACWS_INTEROP_KEY_EVENT,
                                  MACWS_INTEROP_EVENT_FILES_READY);
        xpc_object_t paths = xpc_array_create(NULL, 0);
        NSUInteger count = MIN(urls.count, MACWS_INTEROP_MAX_ITEMS);
        for (NSUInteger index = 0; index < count; index++) {
            NSString *path = urls[index].path;
            if (path.length && path.length <= MACWS_INTEROP_MAX_PATH_BYTES)
                xpc_array_set_string(paths, XPC_ARRAY_APPEND,
                                     path.fileSystemRepresentation);
        }
        xpc_dictionary_set_value(event, MACWS_INTEROP_KEY_ITEMS, paths);
        xpc_dictionary_set_uint64(event, "origin_id", DaemonOriginID);
        xpc_dictionary_set_uint64(event, "generation", ++Generation);
        Broadcast(event);
        return;
    }

    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (png.length && png.length <= MACWS_INTEROP_MAX_INLINE_BYTES) {
        Broadcast(EventForData(MacWSInteropKindPNG, png, @"public.png"));
        return;
    }
    NSString *string = [pasteboard stringForType:NSPasteboardTypeString];
    NSData *text = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (text.length && text.length <= MACWS_INTEROP_MAX_INLINE_BYTES)
        Broadcast(EventForData(MacWSInteropKindUTF8Text, text,
                               @"public.utf8-plain-text"));
}

static BOOL SafeImportedPath(NSString *path) {
    NSString *root = @"/Users/Shared/MacWS Imports";
    NSString *standard = path.stringByStandardizingPath;
    return [standard isEqualToString:root] ||
        [standard hasPrefix:[root stringByAppendingString:@"/"]];
}

static void ApplyInlineClipboard(xpc_object_t request) {
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(
        request, MACWS_INTEROP_KEY_DESCRIPTOR, &descriptorSize);
    if (!descriptorBytes || descriptorSize != sizeof(MacWSInteropItemDescriptor))
        return;
    MacWSInteropItemDescriptor descriptor;
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    if (!MacWSInteropItemDescriptorIsValid(&descriptor, descriptorSize) ||
        descriptor.originID == DaemonOriginID ||
        ((descriptor.flags & MacWSInteropFromIOS) == 0)) return;
    size_t payloadSize = 0;
    const void *payloadBytes = xpc_dictionary_get_data(
        request, MACWS_INTEROP_KEY_PAYLOAD, &payloadSize);
    if (!payloadBytes || payloadSize != descriptor.payloadLength ||
        payloadSize > MACWS_INTEROP_MAX_INLINE_BYTES) return;
    NSData *payload = [NSData dataWithBytes:payloadBytes length:payloadSize];
    uint8_t digest[16];
    Digest(payload, digest);
    if (memcmp(digest, descriptor.digest, sizeof(digest)) != 0) return;
    if (descriptor.originID == LastIncomingOrigin &&
        descriptor.generation <= LastIncomingGeneration) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    BOOL applied = NO;
    if (descriptor.kind == MacWSInteropKindUTF8Text) {
        NSString *text = [[NSString alloc] initWithData:payload
                                               encoding:NSUTF8StringEncoding];
        if (text) applied = [pasteboard setString:text
                                          forType:NSPasteboardTypeString];
    } else if (descriptor.kind == MacWSInteropKindPNG) {
        applied = [pasteboard setData:payload forType:NSPasteboardTypePNG];
    } else if (descriptor.kind == MacWSInteropKindJPEG) {
        applied = [pasteboard setData:payload
                              forType:@"public.jpeg"];
    }
    if (applied) {
        LastIncomingOrigin = descriptor.originID;
        LastIncomingGeneration = descriptor.generation;
        AppliedPasteboardChange = pasteboard.changeCount;
        LastPasteboardChange = AppliedPasteboardChange;
    }
}

static void ApplyImportedFiles(xpc_object_t request) {
    xpc_object_t items = xpc_dictionary_get_value(request,
                                                   MACWS_INTEROP_KEY_ITEMS);
    if (!items || xpc_get_type(items) != XPC_TYPE_ARRAY) return;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    xpc_array_apply(items, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (urls.count >= MACWS_INTEROP_MAX_ITEMS ||
            xpc_get_type(value) != XPC_TYPE_STRING) return true;
        const char *pathBytes = xpc_string_get_string_ptr(value);
        NSString *path = pathBytes ? [NSString stringWithUTF8String:pathBytes]
                                   : nil;
        BOOL isDirectory = NO;
        if (path && SafeImportedPath(path) &&
            [NSFileManager.defaultManager fileExistsAtPath:path
                                                isDirectory:&isDirectory]) {
            [urls addObject:[NSURL fileURLWithPath:path isDirectory:isDirectory]];
        }
        return true;
    });
    if (!urls.count) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if ([pasteboard writeObjects:urls]) {
        AppliedPasteboardChange = pasteboard.changeCount;
        LastPasteboardChange = AppliedPasteboardChange;
    }
}

static void HandleMessage(xpc_connection_t peer, xpc_object_t message) {
    if (message == XPC_ERROR_CONNECTION_INVALID ||
        message == XPC_ERROR_CONNECTION_INTERRUPTED) {
        [Clients removeObject:(id)peer];
        return;
    }
    if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
    const char *operation = xpc_dictionary_get_string(message,
                                                       MACWS_INTEROP_KEY_OP);
    if (!operation) return;
    if (strcmp(operation, MACWS_INTEROP_OP_HELLO) == 0) {
        xpc_object_t ready = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_EVENT,
                                  MACWS_INTEROP_EVENT_READY);
        uint64_t version = xpc_dictionary_get_uint64(
            message, MACWS_INTEROP_KEY_PROTOCOL_VERSION);
        if (version != MACWS_INTEROP_VERSION) {
            xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_EVENT,
                                      MACWS_INTEROP_EVENT_ERROR);
            xpc_dictionary_set_string(ready, MACWS_INTEROP_KEY_MESSAGE,
                                      "protocol version mismatch");
        }
        xpc_dictionary_set_uint64(ready, MACWS_INTEROP_KEY_PROTOCOL_VERSION,
                                  MACWS_INTEROP_VERSION);
        xpc_connection_send_message(peer, ready);
    } else if (strcmp(operation, MACWS_INTEROP_OP_SUBSCRIBE) == 0) {
        LastPasteboardChange = -1;
        PublishPasteboardIfChanged();
    } else if (strcmp(operation, MACWS_INTEROP_OP_PUBLISH_CLIPBOARD) == 0) {
        ApplyInlineClipboard(message);
    } else if (strcmp(operation, MACWS_INTEROP_OP_IMPORT_FILES) == 0) {
        ApplyImportedFiles(message);
    }
}

static void AcceptConnection(xpc_connection_t peer) {
    [Clients addObject:(id)peer];
    xpc_connection_set_target_queue(peer, InteropQueue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        HandleMessage(peer, message);
    });
    xpc_connection_resume(peer);
}

int main(void) {
    @autoreleasepool {
        InteropQueue = dispatch_queue_create("com.macwsguide.interop.queue",
                                             DISPATCH_QUEUE_SERIAL);
        Clients = [NSMutableSet set];
        arc4random_buf(&DaemonOriginID, sizeof(DaemonOriginID));
        if (!DaemonOriginID) DaemonOriginID = 1;
        xpc_connection_t listener = xpc_connection_create_mach_service(
            MACWS_INTEROP_SERVICE, InteropQueue,
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) return 1;
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
                AcceptConnection((xpc_connection_t)event);
        });
        xpc_connection_resume(listener);
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, InteropQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ PublishPasteboardIfChanged(); });
        dispatch_resume(timer);
        InteropLog(@"READY service=%s protocol=%u origin=%llu",
            MACWS_INTEROP_SERVICE, MACWS_INTEROP_VERSION,
            (unsigned long long)DaemonOriginID);
        dispatch_main();
    }
}
