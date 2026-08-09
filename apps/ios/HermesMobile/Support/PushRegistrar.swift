import CryptoKit
import Foundation
import UserNotifications

/// Local notification preference owner.
///
/// Option C intentionally has no built-in APNs registry: remote delivery belongs
/// to an optional thin provider. Until that provider exists, this type preserves
/// the existing Settings surface and stable alert-deduplication namespace while
/// never posting a device token or claiming APNs authority.
@MainActor
@Observable
final class PushRegistrar {
    static let shared = PushRegistrar()

    @ObservationIgnored
    private weak var connection: ConnectionStore?
    @ObservationIgnored
    var authorizationRequester: (@MainActor (Bool) async -> UNAuthorizationStatus)?

    private(set) var isEnabled: Bool

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: DefaultsKeys.pushEnabled)
    }

    func attach(connection: ConnectionStore) {
        self.connection = connection
    }

    /// No remote provider is bundled in this release, so live WebSocket events
    /// retain local-alert ownership.
    var isAlertAuthorityRegistered: Bool { false }

    /// Stable, non-secret scope for local alert deduplication. It deliberately
    /// excludes credentials and changes when the gateway/device pairing changes.
    var notificationScope: String? {
        guard let connection, !connection.serverURLString.isEmpty else { return nil }
        let device = DefaultsKeys.pushRegistrationDeviceId(server: connection.serverURLString)
        let raw = "\(connection.serverURLString)|\(device)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "local_" + digest.prefix(24)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.pushEnabled)
        clearRemoteRegistrationState()
        if enabled { requestAuthorization(force: true) }
    }

    func ensureRegisteredForPairedGateway() {
        if UserDefaults.standard.object(forKey: DefaultsKeys.pushEnabled) == nil {
            isEnabled = true
            UserDefaults.standard.set(true, forKey: DefaultsKeys.pushEnabled)
        }
        clearRemoteRegistrationState()
        if isEnabled { requestAuthorization(force: false) }
    }

    /// Event preferences affect local WebSocket-derived alerts immediately; no
    /// server re-registration is required.
    func reRegisterEvents() {}

    /// Compatibility cleanup used by Forget Gateway.
    func unregisterRememberedToken(_ rememberedToken: String? = nil) async {
        _ = rememberedToken
        clearRemoteRegistrationState()
    }

    /// APNs callbacks may still arrive during an upgrade from an older build.
    /// Discard them: no provider has been authorized to receive the token.
    func didRegister(deviceToken: Data) {
        _ = deviceToken
        clearRemoteRegistrationState()
    }

    func didFailToRegister(error: Error) {
        _ = error
        clearRemoteRegistrationState()
    }

    private func requestAuthorization(force: Bool) {
        Task { @MainActor in
            if let authorizationRequester {
                _ = await authorizationRequester(force)
            } else {
                _ = await NotificationService.requestAuthorizationStatusIfNeeded(force: force)
            }
        }
    }

    private func clearRemoteRegistrationState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.removeObject(forKey: DefaultsKeys.pushLastEvents)
        defaults.removeObject(forKey: DefaultsKeys.pushLastEnv)
        defaults.removeObject(forKey: DefaultsKeys.pushLastRegistrationScope)
        defaults.set(false, forKey: DefaultsKeys.pushRegistrationHealthy)
    }
}
