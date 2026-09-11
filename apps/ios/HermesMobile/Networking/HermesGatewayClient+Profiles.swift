import Foundation

extension HermesGatewayClient {
    /// Resolve the durable canonical chat for one Hermes profile. This extends
    /// the existing long-lived gateway client; it does not create a second
    /// transport or local session authority.
    func ensureBotChat(profile: String) async throws -> BotChatEnsureResult {
        try await request(
            "profiles.ensure_bot_chat",
            params: .object(["profile": .string(profile)]),
            timeout: .seconds(120)
        )
    }
}
