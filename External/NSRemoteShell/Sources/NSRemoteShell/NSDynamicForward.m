//
//  NSDynamicForward.m
//  NSRemoteShell
//
//  RFC 1928 SOCKS5 dynamic port forwarder bound to 127.0.0.1.
//

#import "NSDynamicForward.h"
#import <arpa/inet.h>
#import <fcntl.h>

static BOOL NSRSocksReadExact(int sock, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(sock, buf + got, len - got, 0);
        if (n < 0 && errno == EINTR) { continue; }
        if (n <= 0) { return NO; }
        got += (size_t)n;
    }
    return YES;
}

static BOOL NSRSocksWriteAll(int sock, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(sock, buf + sent, len - sent, 0);
        if (n < 0 && errno == EINTR) { continue; }
        if (n <= 0) { return NO; }
        sent += (size_t)n;
    }
    return YES;
}

static void NSRSocksSendReply(int sock, uint8_t rep) {
    uint8_t reply[10] = { 0x05, rep, 0x00, 0x01, 127, 0, 0, 1, 0, 0 };
    (void)NSRSocksWriteAll(sock, reply, sizeof(reply));
}

@interface NSDynamicForward ()

@property (nonatomic, readwrite, strong) NSNumber *localPort;
@property (nonatomic, readwrite, strong) NSNumber *timeout;
@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, readwrite, assign) int representedSocket;
@property (nonatomic, nonnull, readwrite, strong) NSMutableArray<NSRemoteChannelSocketPair *> *forwardSocketPair;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;
@property (nonatomic, nullable, copy) dispatch_block_t wakeHandler;
@property (nonatomic, nullable, strong) NSDynamicForwardContinuationBlock continuationDecisionBlock;
@property (nonatomic, readwrite) BOOL forwardCompleted;

@end

@implementation NSDynamicForward

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedSocket:(int)socketDescriptor
                             withLocalPort:(NSNumber *)withLocalPort
                               withTimeout:(NSNumber *)withTimeout
{
    self = [super init];
    if (self) {
        _localPort = withLocalPort;
        _timeout = withTimeout;
        _representedSession = representedSession;
        _representedSocket = socketDescriptor;
        _forwardSocketPair = [[NSMutableArray alloc] init];
        _forwardCompleted = NO;
    }
    return self;
}

- (void)onTermination:(dispatch_block_t)terminationHandler {
    self.terminationBlock = terminationHandler;
}

- (void)setContinuationChain:(NSDynamicForwardContinuationBlock)continuation {
    self.continuationDecisionBlock = continuation;
}

- (void)setWakeHandler:(nullable dispatch_block_t)wakeHandler {
    _wakeHandler = [wakeHandler copy];
}

- (void)setForwardCompleted:(BOOL)channelCompleted {
    if (_forwardCompleted != channelCompleted) {
        _forwardCompleted = channelCompleted;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.forwardCompleted = YES; return NO; }
    if (self.representedSocket <= 0) { self.forwardCompleted = YES; return NO; }
    return YES;
}

- (void)unsafeCallNonblockingOperations {
    if (self.forwardCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeAcceptClients];
    [self unsafeProcessAllSocket];
    [self unsafeChannelShouldTerminate];
}

- (void)unsafeProcessAllSocket {
    NSMutableArray<NSRemoteChannelSocketPair *> *alive = [[NSMutableArray alloc] init];
    for (NSRemoteChannelSocketPair *pair in self.forwardSocketPair) {
        if (![pair unsafeInsanityCheckAndReturnDidSuccess]) {
            [pair unsafeDisconnectAndPrepareForRelease];
            continue;
        }
        [pair unsafeCallNonblockingOperations];
        if (![pair unsafeInsanityCheckAndReturnDidSuccess]) {
            [pair unsafeDisconnectAndPrepareForRelease];
            continue;
        }
        [alive addObject:pair];
    }
    self.forwardSocketPair = alive;
}

- (void)unsafeAcceptClients {
    while (true) {
        struct sockaddr_in peeraddr;
        socklen_t peeraddrlen = sizeof(peeraddr);
        int clientSock = accept(self.representedSocket, (struct sockaddr *)&peeraddr, &peeraddrlen);
        if (clientSock <= 0) { return; }

        setsockopt(clientSock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));

        // Perform short blocking RFC 1928 handshake with bounded timeout.
        int flags = fcntl(clientSock, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(clientSock, F_SETFL, flags & ~O_NONBLOCK);
        }
        struct timeval tv;
        tv.tv_sec = 3;
        tv.tv_usec = 0;
        setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(clientSock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        NSString *destHost = nil;
        uint16_t destPort = 0;
        if (![self performSocks5HandshakeOnSocket:clientSock destHost:&destHost destPort:&destPort]) {
            close(clientSock);
            continue;
        }

        NSDate *deadline = [[NSDate alloc] initWithTimeIntervalSinceNow:MAX([self.timeout doubleValue], 5.0)];
        LIBSSH2_CHANNEL *channel = NULL;
        while (true) {
            if ([deadline timeIntervalSinceNow] < 0) {
                libssh2_session_set_last_error(self.representedSession, LIBSSH2_ERROR_TIMEOUT, NULL);
                break;
            }
            LIBSSH2_CHANNEL *opened = libssh2_channel_direct_tcpip_ex(self.representedSession,
                                                                      [destHost UTF8String],
                                                                      (int)destPort,
                                                                      "127.0.0.1",
                                                                      [self.localPort intValue]);
            if (opened) {
                channel = opened;
                break;
            }
            long rc = libssh2_session_last_errno(self.representedSession);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
                continue;
            }
            break;
        }

        if (!channel) {
            // Single target failure must not tear down the whole SOCKS5 listener.
            NSRSocksSendReply(clientSock, 0x05); // Connection refused
            close(clientSock);
            continue;
        }

        NSRSocksSendReply(clientSock, 0x00); // Succeeded

        // Switch client socket to non-blocking for event-loop multiplexing.
        int postFlags = fcntl(clientSock, F_GETFL, 0);
        if (postFlags >= 0) {
            fcntl(clientSock, F_SETFL, postFlags | O_NONBLOCK);
        }
        struct timeval zeroTV = { 0, 0 };
        setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &zeroTV, sizeof(zeroTV));
        setsockopt(clientSock, SOL_SOCKET, SO_SNDTIMEO, &zeroTV, sizeof(zeroTV));

        NSRemoteChannelSocketPair *pair = [[NSRemoteChannelSocketPair alloc] initWithSocket:clientSock
                                                                                withChannel:channel];
        if (self.wakeHandler) {
            [pair setOnSocketReadable:self.wakeHandler];
        }
        [self.forwardSocketPair addObject:pair];
    }
}

- (BOOL)performSocks5HandshakeOnSocket:(int)sock
                              destHost:(NSString * _Nullable * _Nonnull)outHost
                              destPort:(uint16_t *)outPort
{
    uint8_t greeting[2];
    if (!NSRSocksReadExact(sock, greeting, 2) || greeting[0] != 0x05) {
        return NO;
    }
    uint8_t nmethods = greeting[1];
    uint8_t methods[255];
    if (nmethods > 0 && !NSRSocksReadExact(sock, methods, nmethods)) {
        return NO;
    }
    BOOL supportsNoAuth = NO;
    for (uint8_t i = 0; i < nmethods; i++) {
        if (methods[i] == 0x00) { supportsNoAuth = YES; break; }
    }
    if (!supportsNoAuth) {
        uint8_t reject[2] = { 0x05, 0xFF };
        (void)NSRSocksWriteAll(sock, reject, 2);
        return NO;
    }
    uint8_t chosen[2] = { 0x05, 0x00 };
    if (!NSRSocksWriteAll(sock, chosen, 2)) {
        return NO;
    }

    uint8_t reqHeader[4];
    if (!NSRSocksReadExact(sock, reqHeader, 4) || reqHeader[0] != 0x05) {
        return NO;
    }
    if (reqHeader[1] != 0x01) { // Only CONNECT supported
        NSRSocksSendReply(sock, 0x07);
        return NO;
    }

    uint8_t atyp = reqHeader[3];
    NSString *host = nil;
    if (atyp == 0x01) { // IPv4
        uint8_t addr[4];
        if (!NSRSocksReadExact(sock, addr, 4)) { return NO; }
        char str[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, addr, str, sizeof(str))) { return NO; }
        host = [NSString stringWithUTF8String:str];
    } else if (atyp == 0x03) { // Domain name (resolved remotely by sshd)
        uint8_t len = 0;
        if (!NSRSocksReadExact(sock, &len, 1) || len == 0) { return NO; }
        char domain[256];
        if (!NSRSocksReadExact(sock, (uint8_t *)domain, len)) { return NO; }
        domain[len] = '\0';
        host = [[NSString alloc] initWithBytes:domain length:len encoding:NSUTF8StringEncoding];
    } else if (atyp == 0x04) { // IPv6
        uint8_t addr[16];
        if (!NSRSocksReadExact(sock, addr, 16)) { return NO; }
        char str[INET6_ADDRSTRLEN];
        if (!inet_ntop(AF_INET6, addr, str, sizeof(str))) { return NO; }
        host = [NSString stringWithUTF8String:str];
    } else {
        NSRSocksSendReply(sock, 0x08); // Address type not supported
        return NO;
    }

    uint8_t portBytes[2];
    if (!NSRSocksReadExact(sock, portBytes, 2)) { return NO; }
    uint16_t port = (uint16_t)(((uint16_t)portBytes[0] << 8) | (uint16_t)portBytes[1]);
    if (host.length == 0 || port == 0) {
        NSRSocksSendReply(sock, 0x01);
        return NO;
    }

    *outHost = host;
    *outPort = port;
    return YES;
}

- (BOOL)unsafeChannelShouldTerminate {
    if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
        self.forwardCompleted = YES;
        return YES;
    }
    return NO;
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    if (self.forwardCompleted) { return NO; }
    return [self seatbeltCheckPassed];
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.forwardCompleted) { self.forwardCompleted = YES; }
    if (!self.representedSession && self.representedSocket <= 0) { return; }
    int socket = self.representedSocket;
    if (socket > 0) {
        [GenericNetworking destroyNativeSocket:socket];
    }
    self.representedSession = NULL;
    self.representedSocket = 0;
    for (NSRemoteChannelSocketPair *pair in self.forwardSocketPair) {
        [pair unsafeDisconnectAndPrepareForRelease];
    }
    self.forwardSocketPair = [[NSMutableArray alloc] init];
    if (self.terminationBlock) { self.terminationBlock(); }
    self.terminationBlock = NULL;
}

@end
