//
//  NSDynamicForward.h
//  NSRemoteShell
//
//  Local loopback SOCKS5 dynamic port forwarder (`ssh -D <port>`) over
//  libssh2 direct-tcpip channels (RFC 1928: no-auth CONNECT for IPv4,
//  remote-resolved domain names, and IPv6).
//

#import "GenericHeaders.h"
#import "GenericNetworking.h"
#import "NSRemoteShell.h"
#import "NSRemoteChannelSocketPair.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSDynamicForward : NSObject <NSRemoteOperableObject>

typedef BOOL (^NSDynamicForwardContinuationBlock)(void);

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedSocket:(int)socketDescriptor
                             withLocalPort:(NSNumber *)withLocalPort
                               withTimeout:(NSNumber *)withTimeout;

- (void)onTermination:(dispatch_block_t)terminationHandler;
- (void)setContinuationChain:(NSDynamicForwardContinuationBlock)continuation;
- (void)setWakeHandler:(nullable dispatch_block_t)wakeHandler;

- (void)unsafeCallNonblockingOperations;
- (BOOL)unsafeInsanityCheckAndReturnDidSuccess;
- (void)unsafeDisconnectAndPrepareForRelease;

@end

NS_ASSUME_NONNULL_END
