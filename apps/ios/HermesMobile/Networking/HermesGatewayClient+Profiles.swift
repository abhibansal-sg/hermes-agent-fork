import Foundation

extension HermesGatewayClient {
    func botProfiles() async throws -> BotProfilesResult {
        try await request("profiles.list", params: .object(["include_sessions": .bool(true)]))
    }

    /// ABH-520: mirror stock Desktop's lookup → create → eager title flow.
    /// No prompt is needed to persist a titled row; the user speaks first.
    func ensureBotChat(profile: String) async throws -> BotChatEnsureResult {
        let roster = try await botProfiles()
        switch try BotChatResolution.resolve(roster, profile: profile) {
        case .open(let id):
            return BotChatEnsureResult(sessionId: id, profile: profile, created: false, runtimeSessionId: nil)
        case .create:
            break
        }
        try Task.checkCancellation()
        let created: SessionOpenResult = try await request("session.create", params: .object([
            "profile": .string(profile),
            "title": .string(BotChatResolution.title),
            "hidden": .bool(true),
            "follow_profile_config": .bool(true),
        ]))
        guard let storedID = created.storedSessionId, !storedID.isEmpty, !created.sessionId.isEmpty else {
            throw BotChatResolution.ResolutionError.invalidResponse
        }
        do {
            let titled = try await requestRaw("session.title", params: .object([
                "session_id": .string(created.sessionId),
                "title": .string(BotChatResolution.title),
            ]))
            // Fail closed if persistence was deferred: never prompt into a stray.
            guard titled["pending"]?.boolValue != true else {
                throw BotChatResolution.ResolutionError.invalidResponse
            }
        } catch {
            guard BotChatResolution.shouldAdoptWinner(message: error.localizedDescription) else { throw error }
            let winner = try await botProfiles()
            let id = try BotChatResolution.adoptWinner(winner, profile: profile)
            return BotChatEnsureResult(sessionId: id, profile: profile, created: false, runtimeSessionId: nil)
        }
        return BotChatEnsureResult(
            sessionId: storedID, profile: profile, created: true, runtimeSessionId: created.sessionId
        )
    }
}
