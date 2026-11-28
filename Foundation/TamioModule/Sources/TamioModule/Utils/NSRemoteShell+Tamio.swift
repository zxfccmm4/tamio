//
//  NSRemoteShell+Tamio.swift
//  TamioModule
//
//  Shared shell scaffolding, previously copy-pasted across both apps.
//

import Foundation
import NSRemoteShell

public extension NSRemoteShell {
    /// Returns a shell preconfigured with the machine's address and port.
    /// An unparsable port keeps the historical 0 value, which simply fails
    /// to connect and surfaces through the usual error path.
    @discardableResult
    static func configured(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        configured(host: machine.remoteAddress, port: machine.remotePort, timeout: timeout)
            .setupProxyCommand(machine.proxyCommand)
    }

    /// Returns a shell preconfigured with the given address and port string.
    @discardableResult
    static func configured(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        NSRemoteShell().applyConnection(host: host, port: port, timeout: timeout)
    }

    /// Applies connection parameters to an existing shell, returning self for chaining.
    @discardableResult
    func applyConnection(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        KnownHosts.install()
        return setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: Int(port) ?? 0))
            .setupConnectionTimeout(timeout)
    }

    /// Applies the machine's connection parameters to an existing shell.
    @discardableResult
    func applyConnection(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        applyConnection(host: machine.remoteAddress, port: machine.remotePort, timeout: timeout)
            .setupProxyCommand(machine.proxyCommand)
    }

    /// Tries each identity in order as the server's user, reconnecting when
    /// the user changes (a server saved before servers had a user signs in as
    /// each identity's own; the remote side authenticates per connection).
    /// Returns true when the shell ends up authenticated.
    @discardableResult
    func authenticateWithAutoIdentities(
        _ identities: [RDIdentity],
        for machine: RDMachine,
        hint: ((String) -> Void)? = nil
    ) -> Bool {
        var previousUsername: String?
        for identity in identities {
            let username = machine.loginUsername(with: identity)
            guard !username.isEmpty else { continue }
            hint?("[i] trying to authenticate as \(username) with \(identity.displayName)")
            if let prev = previousUsername, prev != username {
                requestDisconnectAndWait()
                requestConnectAndWait()
            }
            previousUsername = username
            identity.callAuthenticationWith(remote: self, username: username)
            if isConnected, isAuthenticated {
                break
            }
        }
        return isConnected && isAuthenticated
    }

    /// Outcome of `connectAndAuthenticate`.
    enum ConnectAndAuthenticateResult {
        /// Connected and authenticated.
        case success
        /// The initial connection failed.
        case connectFailed
        /// Connected, but authentication failed.
        case authenticateFailed
    }

    /// Signs a connected shell in the way the server is set to: with no
    /// credentials when it says so (the protocol's "none" request, which a
    /// server that trusts the connection itself accepts, Tailscale SSH for
    /// one), else with `identity`, else with each of `autoIdentities` in
    /// turn. Returns true when the shell ends up authenticated.
    @discardableResult
    func authenticate(
        for machine: RDMachine,
        identity: RDIdentity?,
        autoIdentities: [RDIdentity] = [],
        hint: ((String) -> Void)? = nil
    ) -> Bool {
        if machine.signsInWithoutCredentials {
            let username = machine.loginUsername(with: nil)
            hint?("[i] signing in as \(username) with no password or key")
            authenticateWithoutCredentials(username)
        } else if let identity {
            identity.callAuthenticationWith(remote: self, username: machine.loginUsername(with: identity))
        } else {
            authenticateWithAutoIdentities(autoIdentities, for: machine, hint: hint)
        }
        return isConnected && isAuthenticated
    }

    /// Connects through `machine.jumpHostIDs` (if configured) using in-process
    /// libssh2 direct-tcpip tunnels so multi-hop ProxyJump works identically on
    /// macOS and iOS with independent host-key verification on every hop.
    /// Returns an error description when a jump hop fails, or nil when ready to connect `self`.
    func prepareJumpTunnelIfNeeded(
        for machine: RDMachine,
        timeout: NSNumber,
        autoIdentities: [RDIdentity] = [],
        hint: ((String) -> Void)? = nil
    ) -> String? {
        guard !machine.jumpHostIDs.isEmpty else { return nil }
        let chain: [RDMachine]
        do {
            chain = try machine.resolvedJumpChain { id in
                let candidate = TamioStore.shared.workerMachine(for: id)
                return candidate.isNotPlaceholder() ? candidate : nil
            }
        } catch {
            return error.localizedDescription
        }
        guard !chain.isEmpty else { return nil }

        var parentShell: NSRemoteShell?
        for (index, hop) in chain.enumerated() {
            hint?("[i] connecting jump host \(hop.name) (\(index + 1)/\(chain.count))")
            let hopShell = NSRemoteShell.configured(for: hop, timeout: timeout)
            if let prev = parentShell {
                let hopPort = NSNumber(value: Int(hop.remotePort) ?? 22)
                let tunnelFD = prev.requestOpenDirectTunnelSocket(toHost: hop.remoteAddress, port: hopPort)
                guard tunnelFD > 0 else {
                    let msg = prev.getLastError() ?? String(localized: "Jump host \(prev.remoteHost) could not reach \(hop.name).")
                    prev.requestDisconnectAndWait()
                    prev.destroyPermanently()
                    hopShell.destroyPermanently()
                    return msg
                }
                hopShell.setupTunnelSocket(tunnelFD, ownedParentShell: prev)
            }
            KnownHosts.install()
            hopShell.requestConnectAndWait()
            guard hopShell.isConnected else {
                let msg = hopShell.hostKeyRefusal ?? hopShell.getLastError()
                    ?? String(localized: "Could not reach jump host \(hop.name).")
                hopShell.requestDisconnectAndWait()
                hopShell.destroyPermanently()
                return msg
            }
            let hopIdentity = TamioStore.shared.workerAssociatedIdentity(for: hop)
            guard hopShell.authenticate(for: hop, identity: hopIdentity, autoIdentities: autoIdentities, hint: hint) else {
                let msg = String(localized: "Could not sign in to jump host \(hop.name) as \(hop.loginUsername(with: hopIdentity)).")
                hopShell.requestDisconnectAndWait()
                hopShell.destroyPermanently()
                return msg
            }
            parentShell = hopShell
        }

        guard let lastJump = parentShell else { return nil }
        let targetPort = NSNumber(value: Int(machine.remotePort) ?? 22)
        let leafFD = lastJump.requestOpenDirectTunnelSocket(toHost: machine.remoteAddress, port: targetPort)
        guard leafFD > 0 else {
            let msg = lastJump.getLastError() ?? String(localized: "Jump host \(lastJump.remoteHost) could not reach \(machine.remoteAddress):\(targetPort).")
            lastJump.requestDisconnectAndWait()
            lastJump.destroyPermanently()
            return msg
        }
        setupTunnelSocket(leafFD, ownedParentShell: lastJump)
        return nil
    }

    /// Connects (blocking), then signs in as `authenticate(for:identity:)`
    /// does. Shared by the terminal, file-transfer and monitor bootstraps.
    @discardableResult
    func connectAndAuthenticate(
        identity: RDIdentity?,
        autoIdentities: [RDIdentity],
        for machine: RDMachine,
        hint: ((String) -> Void)? = nil
    ) -> ConnectAndAuthenticateResult {
        KnownHosts.install()
        if let jumpFailure = prepareJumpTunnelIfNeeded(for: machine, timeout: operationTimeout, autoIdentities: autoIdentities, hint: hint) {
            hint?("[!] \(jumpFailure)")
            return .connectFailed
        }
        requestConnectAndWait()
        guard isConnected else { return .connectFailed }
        return authenticate(for: machine, identity: identity, autoIdentities: autoIdentities, hint: hint)
            ? .success : .authenticateFailed
    }
}
