//
//  AppLockManager.swift
//  TamioMobile
//
//  Biometric / passcode app lock and privacy screen blur when switching apps.
//

import LocalAuthentication
import SwiftUI
import TamioDesign

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    static let enabledKey = "sb.moe.tamio.mobile.appLock.enabled"
    static let timeoutKey = "sb.moe.tamio.mobile.appLock.timeout"

    @Published private(set) var isLocked = false
    @Published private(set) var showsPrivacyCurtain = false
    @Published private(set) var authError: String?

    private var backgroundedAt: Date?
    private var authenticating = false

    private init() {
        if isEnabled {
            isLocked = true
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var timeoutSeconds: TimeInterval {
        let value = UserDefaults.standard.object(forKey: Self.timeoutKey) as? Int ?? 60
        return TimeInterval(max(0, value))
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            if isEnabled {
                showsPrivacyCurtain = true
            }
        case .background:
            if isEnabled {
                showsPrivacyCurtain = true
                if backgroundedAt == nil { backgroundedAt = Date() }
            }
        case .active:
            showsPrivacyCurtain = false
            guard isEnabled else {
                isLocked = false
                backgroundedAt = nil
                return
            }
            if let since = backgroundedAt, Date().timeIntervalSince(since) >= timeoutSeconds {
                isLocked = true
            }
            backgroundedAt = nil
            if isLocked {
                authenticate()
            }
        @unknown default:
            break
        }
    }

    func authenticate() {
        guard isLocked, !authenticating else { return }
        authenticating = true
        authError = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticating = false
            isLocked = false
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "Unlock Tamio to access your servers and terminals.")
        ) { [weak self] success, evalError in
            Task { @MainActor in
                guard let self else { return }
                self.authenticating = false
                if success {
                    self.isLocked = false
                    self.authError = nil
                } else {
                    self.authError = evalError?.localizedDescription
                }
            }
        }
    }
}

struct AppLockOverlay: View {
    @ObservedObject private var lock = AppLockManager.shared

    var body: some View {
        ZStack {
            if lock.showsPrivacyCurtain || lock.isLocked {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            if lock.isLocked {
                VStack(spacing: 18) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Tamio is Locked")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    if let error = lock.authError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Button {
                        lock.authenticate()
                    } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                            .font(.headline)
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                }
                .padding(24)
            }
        }
        .animation(.easeOut(duration: 0.2), value: lock.isLocked)
        .animation(.easeOut(duration: 0.15), value: lock.showsPrivacyCurtain)
    }
}
