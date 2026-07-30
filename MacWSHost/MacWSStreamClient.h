#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

#include "macws_stream_protocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface MacWSStreamWindow : NSObject
@property(nonatomic, readonly) MacWSStreamWindowDescriptor descriptor;
@property(nonatomic, readonly) NSString *title;
- (instancetype)initWithDescriptor:(MacWSStreamWindowDescriptor)descriptor
                              title:(NSString *)title NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface MacWSSurfaceFrame : NSObject
@property(nonatomic, readonly) MacWSStreamFrameDescriptor descriptor;
@property(nonatomic, readonly) IOSurfaceRef surface;
@property(nonatomic, readonly) uint64_t receiptTime;
- (instancetype)initWithDescriptor:(MacWSStreamFrameDescriptor)descriptor
                            surface:(IOSurfaceRef)surface
                        receiptTime:(uint64_t)receiptTime NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@class MacWSStreamClient;

@protocol MacWSStreamClientDelegate <NSObject>
- (void)streamClient:(MacWSStreamClient *)client
       statusChanged:(NSString *)status
           connected:(BOOL)connected;
- (void)streamClient:(MacWSStreamClient *)client
      receivedWindows:(NSArray<MacWSStreamWindow *> *)windows;
- (void)streamClient:(MacWSStreamClient *)client
        receivedFrame:(MacWSSurfaceFrame *)frame;
@end

@interface MacWSStreamClient : NSObject
@property(nonatomic, weak, nullable) id<MacWSStreamClientDelegate> delegate;
@property(nonatomic, readonly, getter=isConnected) BOOL connected;
@property(nonatomic, readonly) MacWSStreamMode mode;
@property(nonatomic, readonly) uint32_t windowID;

- (void)subscribeToMode:(MacWSStreamMode)mode windowID:(uint32_t)windowID;
- (void)requestWindowList;
- (void)unsubscribe;
- (void)releaseFrame:(MacWSSurfaceFrame *)frame;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
