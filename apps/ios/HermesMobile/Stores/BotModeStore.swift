import Foundation
import Observation

/// Bounded, presentation-only state for Bot Mode.
///
/// Hermes remains authoritative for profiles and chats. This store only keeps
/// the roster currently rendered by SwiftUI, records a transient loading/error
/// state, asks the existing clients to resolve a bot chat, then hands its
/// durable id to ``SessionStore/open(_:revealOnFirstPaint:bindRuntime:)``.
@MainActor
@Observable
final class BotModeStore {
    enum RosterPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    typealias ProfileLoader = @MainActor () async throws -> [ProfileSummary]
    typealias BotChatEnsurer = @MainActor (_ profile: String) async throws -> BotChatEnsureResult

    private(set) var profiles: [ProfileSummary] = []
    private(set) var rosterPhase: RosterPhase = .idle
    private(set) var openingProfileID: String?
    private(set) var openError: String?

    @ObservationIgnored private let profileLoader: ProfileLoader?
    @ObservationIgnored private let botChatEnsurer: BotChatEnsurer?
    @ObservationIgnored private var refreshGeneration = 0

    init(
        profileLoader: ProfileLoader? = nil,
        botChatEnsurer: BotChatEnsurer? = nil
    ) {
        self.profileLoader = profileLoader
        self.botChatEnsurer = botChatEnsurer
    }

    /// Refresh from the existing native `GET /api/profiles` surface. The roster
    /// is intentionally not persisted or transformed into a separate model.
    func refresh(using connection: ConnectionStore? = nil) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        rosterPhase = .loading

        do {
            let loaded: [ProfileSummary]
            if let profileLoader {
                loaded = try await profileLoader()
            } else if let rest = connection?.rest {
                loaded = try await rest.profiles()
            } else {
                throw BotModeError.notConnected
            }
            guard generation == refreshGeneration else { return }
            profiles = loaded
            rosterPhase = .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            rosterPhase = .failed(Self.message(for: error))
        }
    }

    /// Resolve one profile's canonical durable chat through Hermes, then open
    /// it with the established SessionStore/ChatStore selection and transcript
    /// pipeline. `runtimeSessionId` remains informational because it is not a
    /// durable selection identity.
    func open(
        _ profile: ProfileSummary,
        in sessions: SessionStore,
        using connection: ConnectionStore? = nil
    ) async -> BotChatDestination? {
        guard openingProfileID == nil else { return nil }

        let requestedProfile = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedProfile.isEmpty else {
            openError = "Hermes returned a profile without a stable identity."
            return nil
        }

        openingProfileID = profile.id
        openError = nil
        defer { openingProfileID = nil }

        do {
            let result: BotChatEnsureResult
            if let botChatEnsurer {
                result = try await botChatEnsurer(requestedProfile)
            } else if let connection {
                result = try await connection.client.ensureBotChat(profile: requestedProfile)
            } else {
                throw BotModeError.notConnected
            }

            let sessionID = result.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedProfile = result.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionID.isEmpty, !resolvedProfile.isEmpty else {
                throw BotModeError.invalidResponse
            }

            // Prefer a list row Hermes already supplied, preserving its display
            // metadata. A brand-new zero-message chat may not have reached the
            // rail yet, so construct only the minimal presentation row needed by
            // the existing SessionStore opening seam.
            let summary = sessions.sessions.first { candidate in
                candidate.id == sessionID
                    && Self.normalizedProfile(candidate.profile) == Self.normalizedProfile(resolvedProfile)
            } ?? SessionSummary(
                id: sessionID,
                title: resolvedProfile,
                preview: nil,
                startedAt: nil,
                messageCount: nil,
                source: nil,
                lastActive: nil,
                cwd: nil,
                profile: resolvedProfile
            )
            sessions.open(summary)
            return BotChatDestination(sessionID: sessionID, profile: resolvedProfile)
        } catch {
            openError = Self.message(for: error)
            return nil
        }
    }

    func dismissOpenError() {
        openError = nil
    }

    private static func normalizedProfile(_ profile: String?) -> String {
        profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? "Unable to contact Hermes." : description
    }

    private enum BotModeError: LocalizedError {
        case notConnected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConnected:
                "Connect to Hermes before loading or opening bots."
            case .invalidResponse:
                "Hermes returned an invalid bot chat response."
            }
        }
    }
}

/// Stable, durable navigation destination for Bot Mode. The runtime id remains
/// intentionally absent: SessionStore owns runtime binding and takeover.
struct BotChatDestination: Hashable, Sendable {
    let sessionID: String
    let profile: String
}
