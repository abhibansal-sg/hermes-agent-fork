import Foundation
import CryptoKit
import UIKit
import UserNotifications

/// Persisted, bounded dedupe ledger for system-alert delivery. Keys already
/// contain gateway + device namespaces, so switching or re-pairing cannot make
/// one installation suppress another. Main-actor isolation serializes APNs and
/// live-event arrival races.
@MainActor
final class NotificationDeliveryLedger {
    static let defaultTTL: TimeInterval = 24 * 60 * 60
    static let defaultMaximumEntries = 256

    private let defaults: UserDefaults
    private let storageKey: String
    private let ttl: TimeInterval
    private let maximumEntries: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.notifications.deliveryLedger.v1",
        ttl: TimeInterval = defaultTTL,
        maximumEntries: Int = defaultMaximumEntries
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.maximumEntries = max(1, maximumEntries)
    }

    /// Atomically reserve one alert. Returns false when the same logical event
    /// was already reserved/delivered inside the TTL window.
    func claim(namespace: String, eventId: String, now: Date = Date()) -> Bool {
        guard !namespace.isEmpty, !eventId.isEmpty else { return false }
        let timestamp = now.timeIntervalSince1970
        let cutoff = timestamp - ttl
        var entries = load().filter { $0.value > cutoff }
        let key = Self.digest("\(namespace)|\(eventId)")
        if entries[key] != nil {
            persist(entries)
            return false
        }
        entries[key] = timestamp
        if entries.count > maximumEntries {
            let newest = entries.sorted { $0.value > $1.value }.prefix(maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        persist(entries)
        return true
    }

    var entryCount: Int { load().count }

    private func load() -> [String: TimeInterval] {
        (defaults.dictionary(forKey: storageKey) as? [String: TimeInterval]) ?? [:]
    }

    private func persist(_ entries: [String: TimeInterval]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(entries, forKey: storageKey)
        }
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// APNs-authority policy, correlated local fallback, tap handling, and haptics.
///
/// All entry points are `@MainActor`. Authorization is requested *lazily* — the
/// first time an approval/clarify actually arrives — so the user is never
/// ambushed with a permission dialog at first launch; the "asked once" flag is
/// persisted in `UserDefaults`.
///
/// A live event only schedules a local request when the persisted registration
/// state says APNs is unavailable/unhealthy. Healthy registrations leave system
/// alert ownership to APNs.
@MainActor
enum NotificationService {
    enum AlertKind: String, Sendable, Equatable {
        case approval
        case clarify
        case turnComplete = "turn_complete"
    }

    struct PresentationContext {
        let deviceScope: String
        let activeRuntimeId: String?
        let activeStoredId: String?
        let pushIsAuthoritative: Bool
    }

    struct CorrelatedAlert: Sendable, Equatable {
        let kind: AlertKind
        let eventId: String
        let gatewayScope: String
        let sessionId: String
        let storedSessionId: String?
        let requestId: String?

        var namespaceComponent: String { gatewayScope }
    }

    nonisolated(unsafe) static var presentationContextProvider:
        (@MainActor () -> PresentationContext?)?
    nonisolated(unsafe) static var localRequestSink:
        (@MainActor (UNNotificationRequest) -> Void)?
    nonisolated(unsafe) static var hapticSink: (@MainActor (AlertKind) -> Void)?
    private static var deliveryLedger = NotificationDeliveryLedger()

    static func setPresentationContextProvider(
        _ provider: @escaping @MainActor () -> PresentationContext?
    ) {
        presentationContextProvider = provider
    }

    static func setDeliveryLedgerForTesting(_ ledger: NotificationDeliveryLedger) {
        deliveryLedger = ledger
    }

    /// Apply APNs-authority policy to a live event. Missing server identity is
    /// never replaced with a client UUID: UI state still updates, but no system
    /// alert can be safely deduplicated.
    static func handleLiveAlert(
        _ alert: CorrelatedAlert?,
        title: String,
        body: String,
        deviceScope: String,
        pushIsAuthoritative: Bool,
        isActiveSession: Bool
    ) {
        guard let alert else { return }
        let namespace = "\(alert.gatewayScope)|\(deviceScope)"

        if isActiveSession {
            // The visible session never needs a system banner. Whichever path
            // arrives first reserves the event and owns the one in-app haptic.
            if deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) {
                emitHaptic(alert.kind)
            }
            return
        }
        guard !pushIsAuthoritative else { return }
        guard deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) else { return }
        postCorrelated(
            alert,
            title: title,
            body: body,
            namespace: namespace
        )
    }

    /// Foreground APNs policy: first arrival may alert for a non-active session;
    /// duplicates and the active session are silent. The ledger claim happens
    /// before the active-session check so a later WebSocket fallback cannot race.
    static func foregroundPresentationOptions(
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        guard let alert = decodeCorrelatedAlert(from: userInfo),
              let context = presentationContextProvider?() else {
            return [.banner, .sound]
        }
        let namespace = "\(alert.gatewayScope)|\(context.deviceScope)"
        guard deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) else {
            return []
        }
        let active = alert.sessionId == context.activeRuntimeId
            || (alert.storedSessionId != nil && alert.storedSessionId == context.activeStoredId)
        if active {
            emitHaptic(alert.kind)
            return []
        }
        return [.banner, .sound]
    }

    nonisolated static func decodeCorrelatedAlert(
        from userInfo: [AnyHashable: Any]
    ) -> CorrelatedAlert? {
        let custom = (userInfo["hermes"] as? [AnyHashable: Any]) ?? userInfo
        guard let rawKind = custom["event_type"] as? String,
              let kind = AlertKind(rawValue: rawKind),
              let eventId = nonEmpty(custom["event_id"] as? String),
              let gatewayScope = nonEmpty(custom["gateway_scope"] as? String),
              let sessionId = nonEmpty(custom["session_id"] as? String) else { return nil }
        return CorrelatedAlert(
            kind: kind,
            eventId: eventId,
            gatewayScope: gatewayScope,
            sessionId: sessionId,
            storedSessionId: nonEmpty(custom["stored_session_id"] as? String),
            requestId: nonEmpty(
                (custom["request_id"] as? String)
                    ?? (custom["approval_id"] as? String)
                    ?? (custom["turn_id"] as? String)
            )
        )
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    // Notification category identifiers — these are `UNNotificationCategory`
    // identifiers, NOT `UserDefaults` keys, so they stay local to this type.
    //
    // The `hermes.*` ids are the LOCAL-notification categories (B-wave, fired
    // in-process). The `HERMES_*` ids are the REMOTE APNs categories the gateway
    // stamps into `aps.category` (F2-S), which carry the actionable buttons. The
    // two namespaces coexist: a local approval notification has no action buttons
    // (it routes a tap to the inbox), while a remote `HERMES_APPROVAL` push
    // renders Approve / Deny inline (A1).
    private static let approvalCategory = "hermes.approval"
    private static let clarifyCategory = "hermes.clarify"

    // MARK: - Actionable push categories + actions (A1)
    //
    // BINDING (contract A1): registered exactly as
    //   HERMES_APPROVAL → APPROVE [.authenticationRequired],
    //                     DENY    [.destructive, .authenticationRequired]
    //   HERMES_CLARIFY  → REPLY   [text input]
    //   HERMES_TURN     → no actions (open-app only).
    //
    // `.authenticationRequired` is the OS-level half of the BINDING "no approval
    // action may fire from a locked, unauthenticated device": iOS will not even
    // deliver an `.authenticationRequired` action to the app until the device is
    // unlocked, so a locked-screen Approve/Deny tap first forces a device unlock.
    // (Verified against the SDK: `UNNotificationActionOptionAuthenticationRequired`
    // in UNNotificationAction.h.) The app-level half — an explicit `LAContext`
    // re-check for destructive approvals — is layered on top in `didReceive`.

    // `nonisolated` so the nonisolated decoders (`decodeTap`) and the unit tests
    // can read them without hopping to the main actor; they're immutable string
    // constants, so this is sound.

    /// Remote APNs category id for an approval request (carries action buttons).
    nonisolated static let remoteApprovalCategory = "HERMES_APPROVAL"
    /// Remote APNs category id for a clarification (open-app only).
    nonisolated static let remoteClarifyCategory = "HERMES_CLARIFY"
    /// Remote APNs category id for a long-turn completion (open-app only).
    nonisolated static let remoteTurnCategory = "HERMES_TURN"

    // MARK: - Tap routing (B5)

    /// What a tapped notification asks the app to do, decoded from the push
    /// payload's `event_type` + `session_id`. Both the local notifications fired
    /// here and the remote APNs alerts the gateway sends (see `push_notify.py` /
    /// `tui_gateway/server.py` `_push_hook`) share this contract: the custom keys
    /// live under the `hermes` block of the APNs payload, namespaced as
    /// `{"hermes": {"event_type": "approval"|"clarify"|"turn_complete",
    /// "session_id": <runtime sid>}}`. Local notifications post the same keys flat
    /// in `userInfo` (no `aps` envelope), so the decoder looks in both places.
    enum Tap: Sendable, Equatable {
        /// An approval / clarification needs the user — open its session (and
        /// surface the inbox if the session can't be located).
        case attention(sessionId: String, storedSessionId: String? = nil)
        /// A long turn finished — open its session.
        case turnComplete(sessionId: String, storedSessionId: String? = nil)
    }

    /// The app-supplied sink that routes a decoded tap into the live store graph.
    /// Wired once at launch by `HermesMobileApp` (it forwards to
    /// `HermesURLRouter.routePushTap`). Set on the main actor; read on the main
    /// actor from the delegate callback after a hop.
    nonisolated(unsafe) static var tapHandler: (@MainActor @Sendable (Tap) -> Void)?

    /// Install the app's tap router. Idempotent; safe to call at launch.
    static func setTapHandler(_ handler: @escaping @MainActor @Sendable (Tap) -> Void) {
        tapHandler = handler
    }

    /// Fire a local feedback notification for an action that couldn't land
    /// authoritatively (already handled, failed, not confirmed). No category /
    /// userInfo so a tap just opens the app.
    static func postFeedbackNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Decode a tap from a notification's `userInfo`. Tolerant of both shapes:
    /// the gateway's APNs payload (`userInfo["hermes"]`) and a local
    /// notification's flat keys. Returns `nil` for payloads we don't route.
    nonisolated static func decodeTap(from userInfo: [AnyHashable: Any]) -> Tap? {
        // Prefer the namespaced `hermes` block (remote APNs), fall back to flat.
        let custom: [AnyHashable: Any]
        if let block = userInfo["hermes"] as? [AnyHashable: Any] {
            custom = block
        } else {
            custom = userInfo
        }
        guard
            let sessionId = (custom["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }

        // QA-3 S12: the push payload may carry the persistent STORED session id
        // the relay resolved at drive time. When present, the tap router opens
        // that id directly (SessionStore.open is keyed by the stored id) instead
        // of relying on the inbox's runtime→stored map, which is empty for an
        // ordinary (non-attention) turn_complete of a compressed/old session.
        // NOTE: the parens END the optional chain BEFORE `.flatMap` — without
        // them Swift resolves `.flatMap` on the unwrapped `String` (a Sequence
        // of Character), not `Optional<String>` (integration fix; the lane's
        // un-parenthesized form compiled nowhere — String.Element has no
        // `isEmpty`).
        let storedSessionId = ((custom["stored_session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }

        let eventType = (custom["event_type"] as? String)?.lowercased() ?? ""
        switch eventType {
        case "approval", "clarify":
            return .attention(sessionId: sessionId, storedSessionId: storedSessionId)
        case "turn_complete":
            return .turnComplete(sessionId: sessionId, storedSessionId: storedSessionId)
        default:
            // No `event_type` (the F2-S remote payload routes by `aps.category`
            // instead of a flat event_type). Fall back to the APNs category so a
            // tapped HERMES_APPROVAL / HERMES_CLARIFY still surfaces its session
            // as "attention", and HERMES_TURN as "open the session".
            switch apsCategory(in: userInfo) {
            case remoteApprovalCategory, remoteClarifyCategory:
                return .attention(sessionId: sessionId, storedSessionId: storedSessionId)
            case remoteTurnCategory:
                return .turnComplete(sessionId: sessionId, storedSessionId: storedSessionId)
            default:
                // A session id is present but no event_type / category — treat as
                // plain "open the session" (older / local notifications).
                return .turnComplete(sessionId: sessionId, storedSessionId: storedSessionId)
            }
        }
    }

    /// The `aps.category` value from a notification's `userInfo`, if present.
    /// On a delivered remote notification the category also rides on
    /// `UNNotificationContent.categoryIdentifier`; this reads it straight from
    /// the raw payload so the decoder is exercisable in unit tests.
    nonisolated static func apsCategory(in userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["aps"] as? [AnyHashable: Any])?["category"] as? String
    }

    /// Ask for notification authorization. Also installs the foreground-
    /// presentation delegate so notifications fired while the app is active still
    /// show a banner + play a sound.
    ///
    /// `force` distinguishes the once-per-install LAUNCH path (`false` — suppress
    /// the prompt after the first ask so we never nag on every cold start) from an
    /// EXPLICIT user action (`true` — toggling notifications ON in Settings).
    /// `requestAuthorization` only presents the system dialog when status is
    /// `.notDetermined`, so re-calling with `force` is safe: it lets a user who
    /// dismissed the first prompt ("Don't Allow"/"Ask Next Time") get it again by
    /// toggling ON (the latch previously swallowed that forever). When already
    /// `.denied`, the OS returns the denial without a prompt and Settings surfaces
    /// its "Open Settings" path.
    static func requestAuthorizationIfNeeded(force: Bool = false) {
        Task { @MainActor in
            _ = await requestAuthorizationStatusIfNeeded(force: force)
        }
    }

    /// Async variant for remote-push registration: returns the settled system
    /// authorization state so callers can avoid asking APNs for a token when iOS
    /// has already denied alert delivery (the Settings UI must then show a real
    /// "not authorized" state, not a fake OK).
    static func requestAuthorizationStatusIfNeeded(force: Bool = false) async -> UNAuthorizationStatus {
        registerCategories()
        let defaults = UserDefaults.standard
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus
        }
        if !force {
            guard !defaults.bool(forKey: DefaultsKeys.notificationsDidRequestAuthorization) else {
                return settings.authorizationStatus
            }
        }

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { _, _ in
                // Latch "asked once" only AFTER the dialog resolves (release
                // audit): setting it before meant an app kill mid-dialog consumed
                // the one-shot without an answer — the prompt never re-showed.
                defaults.set(true, forKey: DefaultsKeys.notificationsDidRequestAuthorization)
                UNUserNotificationCenter.current().getNotificationSettings { updated in
                    continuation.resume(returning: updated.authorizationStatus)
                }
            }
        }
    }

    // MARK: - Category registration (A1)

    /// Register open-app push categories with the notification center.
    ///
    /// Idempotent and cheap; called from `requestAuthorizationIfNeeded()` (so the
    /// categories exist before any push lands) and again at launch via
    /// ``setActionHandler(_:)``. `setNotificationCategories` REPLACES the whole
    /// set, so we register all categories in one call.
    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(
            remoteNotificationCategoriesForTesting()
        )
    }

    /// Build the remote APNs categories. Exposed internally for host tests;
    /// `registerCategories()` is still the only production registration path.
    nonisolated static func remoteNotificationCategoriesForTesting() -> Set<UNNotificationCategory> {
        let approvalCat = UNNotificationCategory(
            identifier: remoteApprovalCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let clarifyCat = UNNotificationCategory(
            identifier: remoteClarifyCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let turnCat = UNNotificationCategory(
            identifier: remoteTurnCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        return [approvalCat, clarifyCat, turnCat]
    }

    private static func postCorrelated(
        _ alert: CorrelatedAlert,
        title: String,
        body: String,
        namespace: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        switch alert.kind {
        case .approval: content.categoryIdentifier = approvalCategory
        case .clarify: content.categoryIdentifier = clarifyCategory
        case .turnComplete: content.categoryIdentifier = remoteTurnCategory
        }
        var info: [AnyHashable: Any] = [
            "event_type": alert.kind.rawValue,
            "event_id": alert.eventId,
            "gateway_scope": alert.gatewayScope,
            "session_id": alert.sessionId,
        ]
        if let storedSessionId = alert.storedSessionId {
            info["stored_session_id"] = storedSessionId
        }
        if let requestId = alert.requestId {
            info["request_id"] = requestId
        }
        content.userInfo = info
        let identifier = "hermes." + NotificationDeliveryLedger.digest(
            "\(namespace)|\(alert.eventId)"
        ).prefix(40)
        let request = UNNotificationRequest(
            identifier: String(identifier), content: content, trigger: nil
        )
        if let localRequestSink {
            localRequestSink(request)
        } else {
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    private static func emitHaptic(_ kind: AlertKind) {
        if let hapticSink {
            hapticSink(kind)
            return
        }
        switch kind {
        case .approval, .clarify: approvalHaptic()
        case .turnComplete: turnCompleteHaptic()
        }
    }

    // MARK: - Haptics

    /// Warning haptic — used when an approval/clarification needs attention.
    static func approvalHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Success haptic — used when a (long-running) turn completes.
    static func turnCompleteHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

}
