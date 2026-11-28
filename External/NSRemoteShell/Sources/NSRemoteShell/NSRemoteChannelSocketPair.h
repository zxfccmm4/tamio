//
//  NSRemoteChannelSocketPair.h
//  
//
//  Created by Lakr Aream on 2022/3/9.
//

#import "GenericHeaders.h"
#import "GenericNetworking.h"
#import "NSRemoteShell.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSRemoteChannelSocketPair : NSObject <NSRemoteOperableObject>

@property (nonatomic, readwrite, assign) int socket;
@property (nonatomic, readwrite, nullable, assign) LIBSSH2_CHANNEL *channel;
@property (nonatomic, readwrite, assign) BOOL completed;

- (instancetype)initWithSocket:(int)socket
                   withChannel:(LIBSSH2_CHANNEL*)channel;

/// Optional callback invoked when the local socket becomes readable so the
/// owning session event loop wakes immediately.
- (void)setOnSocketReadable:(nullable dispatch_block_t)handler;

@end

NS_ASSUME_NONNULL_END
