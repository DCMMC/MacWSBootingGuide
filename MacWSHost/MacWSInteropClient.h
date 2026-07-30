#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MacWSInteropClient;

@protocol MacWSInteropClientDelegate <NSObject>
- (void)interopClient:(MacWSInteropClient *)client
        statusChanged:(NSString *)status
            connected:(BOOL)connected;
- (void)interopClient:(MacWSInteropClient *)client
 receivedMacOSFilesAtURLs:(NSArray<NSURL *> *)urls;
@end

@interface MacWSInteropClient : NSObject
@property(nonatomic, weak, nullable) id<MacWSInteropClientDelegate> delegate;
@property(nonatomic, readonly, getter=isConnected) BOOL connected;

- (void)connect;
// This is deliberately user initiated. Reading the general pasteboard in the
// background can trigger iPadOS paste privacy UI and is poor touch UX.
- (void)publishGeneralPasteboard;
- (void)stageAndPublishFiles:(NSArray<NSURL *> *)urls
                  completion:(void (^)(NSArray<NSURL *> *stagedURLs,
                                       NSError * _Nullable error))completion;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
