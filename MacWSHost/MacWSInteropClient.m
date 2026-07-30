#import "MacWSInteropClient.h"

#import <UIKit/UIKit.h>

#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <xpc/xpc.h>

#include "macws_interop_protocol.h"

static NSString *const MacWSImportsHostRoot =
    @"/var/mnt/rootfs/Users/Shared/MacWS Imports";
static NSString *const MacWSRootFSHostPrefix = @"/var/mnt/rootfs";

@interface MacWSInteropClient ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic) uint64_t originID;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t lastRemoteOrigin;
@property(nonatomic) uint64_t lastRemoteGeneration;
@end

@implementation MacWSInteropClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.macwsguide.host.interop-client",
                                       DISPATCH_QUEUE_SERIAL);
        arc4random_buf(&_originID, sizeof(_originID));
        if (!_originID) _originID = 1;
    }
    return self;
}

- (void)dealloc { [self invalidate]; }

- (void)publishStatus:(NSString *)status connected:(BOOL)connected {
    self.connected = connected;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate interopClient:self statusChanged:status
                           connected:connected];
    });
}

- (BOOL)ensureConnection {
    if (self.connection) return YES;
    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) return NO;
    xpc_connection_t connection = createMach(MACWS_INTEROP_SERVICE,
                                              self.queue, 0);
    if (!connection) return NO;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        [weakSelf handleEvent:event];
    });
    xpc_connection_resume(connection);
    self.connection = connection;
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_HELLO);
    xpc_dictionary_set_uint64(hello, MACWS_INTEROP_KEY_PROTOCOL_VERSION,
                              MACWS_INTEROP_VERSION);
    xpc_connection_send_message(connection, hello);
    return YES;
}

- (void)connect {
    dispatch_async(self.queue, ^{
        if (self.isConnected) return;
        if (![self ensureConnection]) {
            [self publishStatus:@"macOS 互操作服务离线" connected:NO];
            return;
        }
    });
}

- (void)sendSubscription {
    if (!self.connection) return;
    xpc_object_t subscribe = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(subscribe, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_SUBSCRIBE);
    xpc_connection_send_message(self.connection, subscribe);
}

static void MacWSDigest(NSData *data, uint8_t output[16]) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    memcpy(output, digest, 16);
}

- (void)publishData:(NSData *)data kind:(MacWSInteropKind)kind
                type:(NSString *)type {
    if (!data.length || data.length > MACWS_INTEROP_MAX_INLINE_BYTES) {
        [self publishStatus:@"剪贴板内容为空或超过 8 MiB，请改用文件导入"
                  connected:self.isConnected];
        return;
    }
    dispatch_async(self.queue, ^{
        if (![self ensureConnection]) {
            [self publishStatus:@"macOS 互操作服务离线" connected:NO];
            return;
        }
        MacWSInteropItemDescriptor descriptor = {
            .magic = MACWS_INTEROP_MAGIC,
            .version = MACWS_INTEROP_VERSION,
            .size = sizeof(MacWSInteropItemDescriptor),
            .kind = kind,
            .flags = MacWSInteropInlinePayload | MacWSInteropFromIOS,
            .generation = ++self.generation,
            .originID = self.originID,
            .payloadLength = data.length,
        };
        MacWSDigest(data, descriptor.digest);
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_OP,
                                  MACWS_INTEROP_OP_PUBLISH_CLIPBOARD);
        xpc_dictionary_set_data(request, MACWS_INTEROP_KEY_DESCRIPTOR,
                                &descriptor, sizeof(descriptor));
        xpc_dictionary_set_data(request, MACWS_INTEROP_KEY_PAYLOAD,
                                data.bytes, data.length);
        xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_TYPE,
                                  type.UTF8String);
        xpc_connection_send_message(self.connection, request);
        [self publishStatus:@"已发送到 macOS 剪贴板" connected:YES];
    });
}

- (void)publishGeneralPasteboard {
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSArray<NSURL *> *urls = pasteboard.URLs;
    if (urls.count) {
        [self stageAndPublishFiles:urls completion:^(NSArray<NSURL *> *staged,
                                                    NSError *error) {
            [self publishStatus:error ? error.localizedDescription :
                [NSString stringWithFormat:@"已向 macOS 导入 %lu 个文件",
                 (unsigned long)staged.count] connected:error == nil];
        }];
        return;
    }
    UIImage *image = pasteboard.image;
    if (image) {
        NSData *png = UIImagePNGRepresentation(image);
        [self publishData:png kind:MacWSInteropKindPNG type:@"public.png"];
        return;
    }
    NSString *text = pasteboard.string;
    if (text.length) {
        [self publishData:[text dataUsingEncoding:NSUTF8StringEncoding]
                     kind:MacWSInteropKindUTF8Text
                     type:@"public.utf8-plain-text"];
        return;
    }
    [self publishStatus:@"iPadOS 剪贴板中没有可同步的文字、图片或文件"
              connected:self.isConnected];
}

- (void)stageAndPublishFiles:(NSArray<NSURL *> *)urls
                  completion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *batch = [MacWSImportsHostRoot stringByAppendingPathComponent:
            NSUUID.UUID.UUIDString];
        if (![NSFileManager.defaultManager createDirectoryAtPath:batch
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }
        NSMutableArray<NSURL *> *staged = [NSMutableArray array];
        NSMutableArray<NSString *> *chrootPaths = [NSMutableArray array];
        NSUInteger limit = MIN(urls.count, MACWS_INTEROP_MAX_ITEMS);
        for (NSUInteger index = 0; index < limit; index++) {
            NSURL *url = urls[index];
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSString *name = url.lastPathComponent.length
                ? url.lastPathComponent
                : [NSString stringWithFormat:@"Imported-%lu",
                   (unsigned long)index + 1];
            // lastPathComponent removes path traversal. A UUID batch
            // directory also prevents one import from overwriting another.
            NSString *stem = name.stringByDeletingPathExtension;
            NSString *extension = name.pathExtension;
            NSString *candidate = name;
            NSUInteger suffix = 2;
            while ([NSFileManager.defaultManager fileExistsAtPath:
                    [batch stringByAppendingPathComponent:candidate]]) {
                NSString *numbered = [NSString stringWithFormat:@"%@-%lu",
                    stem.length ? stem : @"Imported", (unsigned long)suffix++];
                candidate = extension.length
                    ? [numbered stringByAppendingPathExtension:extension]
                    : numbered;
            }
            NSURL *destination = [NSURL fileURLWithPath:
                [batch stringByAppendingPathComponent:candidate]];
            BOOL copied = [NSFileManager.defaultManager copyItemAtURL:url
                                                               toURL:destination
                                                               error:&error];
            if (scoped) [url stopAccessingSecurityScopedResource];
            if (!copied) break;
            [staged addObject:destination];
            NSString *chrootPath = [destination.path substringFromIndex:
                MacWSRootFSHostPrefix.length];
            [chrootPaths addObject:chrootPath];
        }
        if (!error && staged.count) {
            dispatch_async(self.queue, ^{
                if (![self ensureConnection]) return;
                xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
                xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_OP,
                                          MACWS_INTEROP_OP_IMPORT_FILES);
                xpc_object_t items = xpc_array_create(NULL, 0);
                for (NSString *path in chrootPaths)
                    xpc_array_set_string(items, XPC_ARRAY_APPEND,
                                         path.fileSystemRepresentation);
                xpc_dictionary_set_value(request, MACWS_INTEROP_KEY_ITEMS,
                                         items);
                xpc_connection_send_message(self.connection, request);
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(staged, error ?: (staged.count ? nil :
                [NSError errorWithDomain:@"MacWSInterop" code:1 userInfo:@{
                    NSLocalizedDescriptionKey: @"没有可导入的文件"
                }]));
        });
    });
}

- (void)handleEvent:(xpc_object_t)event {
    if (event == XPC_ERROR_CONNECTION_INVALID ||
        event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        xpc_connection_t connection = self.connection;
        self.connection = nil;
        if (connection) xpc_connection_cancel(connection);
        [self publishStatus:@"macOS 互操作服务连接中断" connected:NO];
        return;
    }
    if (!event || xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *eventName = xpc_dictionary_get_string(event,
                                                       MACWS_INTEROP_KEY_EVENT);
    if (!eventName) return;
    if (strcmp(eventName, MACWS_INTEROP_EVENT_READY) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(
            event, MACWS_INTEROP_KEY_PROTOCOL_VERSION);
        if (version != MACWS_INTEROP_VERSION) {
            [self publishStatus:@"iOS/macOS 互操作协议版本不匹配"
                      connected:NO];
            return;
        }
        [self publishStatus:@"iOS/macOS 剪贴板与文件桥已连接" connected:YES];
        [self sendSubscription];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_CLIPBOARD) == 0) {
        [self applyClipboardEvent:event];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_FILES_READY) == 0) {
        [self applyFilesEvent:event];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_ERROR) == 0) {
        const char *message = xpc_dictionary_get_string(
            event, MACWS_INTEROP_KEY_MESSAGE);
        [self publishStatus:message
            ? [NSString stringWithUTF8String:message]
            : @"iOS/macOS 互操作服务错误" connected:NO];
    }
}

- (void)applyClipboardEvent:(xpc_object_t)event {
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(
        event, MACWS_INTEROP_KEY_DESCRIPTOR, &descriptorSize);
    if (!descriptorBytes || descriptorSize != sizeof(MacWSInteropItemDescriptor))
        return;
    MacWSInteropItemDescriptor descriptor;
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    if (!MacWSInteropItemDescriptorIsValid(&descriptor, descriptorSize) ||
        descriptor.originID == self.originID ||
        (descriptor.flags & MacWSInteropFromMacOS) == 0 ||
        (descriptor.originID == self.lastRemoteOrigin &&
         descriptor.generation <= self.lastRemoteGeneration)) return;
    size_t payloadSize = 0;
    const void *payloadBytes = xpc_dictionary_get_data(
        event, MACWS_INTEROP_KEY_PAYLOAD, &payloadSize);
    if (!payloadBytes || payloadSize != descriptor.payloadLength) return;
    NSData *payload = [NSData dataWithBytes:payloadBytes length:payloadSize];
    uint8_t digest[16];
    MacWSDigest(payload, digest);
    if (memcmp(digest, descriptor.digest, sizeof(digest)) != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
        if (descriptor.kind == MacWSInteropKindUTF8Text) {
            pasteboard.string = [[NSString alloc] initWithData:payload
                                                      encoding:NSUTF8StringEncoding];
        } else if (descriptor.kind == MacWSInteropKindPNG) {
            [pasteboard setData:payload forPasteboardType:@"public.png"];
        } else if (descriptor.kind == MacWSInteropKindJPEG) {
            [pasteboard setData:payload forPasteboardType:@"public.jpeg"];
        }
        self.lastRemoteOrigin = descriptor.originID;
        self.lastRemoteGeneration = descriptor.generation;
        [self publishStatus:@"已接收 macOS 剪贴板内容" connected:YES];
    });
}

- (void)applyFilesEvent:(xpc_object_t)event {
    xpc_object_t items = xpc_dictionary_get_value(event,
                                                   MACWS_INTEROP_KEY_ITEMS);
    if (!items || xpc_get_type(items) != XPC_TYPE_ARRAY) return;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    xpc_array_apply(items, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (urls.count >= MACWS_INTEROP_MAX_ITEMS ||
            xpc_get_type(value) != XPC_TYPE_STRING) return true;
        const char *pathBytes = xpc_string_get_string_ptr(value);
        if (!pathBytes || pathBytes[0] != '/') return true;
        NSString *path = [NSString stringWithUTF8String:pathBytes];
        NSString *hostPath = [MacWSRootFSHostPrefix
            stringByAppendingString:path.stringByStandardizingPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:hostPath])
            [urls addObject:[NSURL fileURLWithPath:hostPath]];
        return true;
    });
    if (!urls.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard.generalPasteboard.URLs = urls;
        [self.delegate interopClient:self receivedMacOSFilesAtURLs:urls];
        [self publishStatus:[NSString stringWithFormat:
            @"已接收 %lu 个 macOS 文件，可粘贴或拖到 iPadOS App",
            (unsigned long)urls.count] connected:YES];
    });
}

- (void)invalidate {
    xpc_connection_t connection = self.connection;
    self.connection = nil;
    self.connected = NO;
    if (connection) xpc_connection_cancel(connection);
}

@end
