import Foundation

/// ABH-520: stock registry identity is the exact title, never a client pointer.
struct CanonicalBotSession: Decodable, Sendable, Equatable {
    let id: String
    let resolvedId: String?
    let rootTitle: String?
    let title: String?
    let preview: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
}

struct BotProfilesResult: Decodable, Sendable {
    let profiles: [ProfileSummary]
    let botModeProtocol: Bool?

    var supportsBotMode: Bool {
        botModeProtocol == true && profiles.allSatisfy(\.hasCanonicalSessionField)
    }
}

enum BotChatResolution {
    // Protocol identity, not a configurable display label.
    static let title = "Bot Chat"

    enum Decision: Equatable {
        case open(String)
        case create
    }

    static func resolve(_ result: BotProfilesResult, profile: String) throws -> Decision {
        guard result.supportsBotMode else { throw ResolutionError.unsupported }
        guard let row = result.profiles.first(where: { $0.name == profile }) else {
            throw ResolutionError.missingProfile
        }
        guard let canonical = row.canonicalSession else { return .create }
        let id = canonical.resolvedId ?? canonical.id
        guard !id.isEmpty else { throw ResolutionError.invalidResponse }
        return .open(id)
    }

    static func shouldAdoptWinner(message: String) -> Bool {
        message.range(of: "already in use", options: .caseInsensitive) != nil
    }

    static func adoptWinner(_ result: BotProfilesResult, profile: String) throws -> String {
        guard case .open(let id) = try resolve(result, profile: profile) else {
            throw ResolutionError.missingWinner
        }
        return id
    }

    enum ResolutionError: LocalizedError {
        case unsupported, missingProfile, invalidResponse, missingWinner
        var errorDescription: String? {
            switch self {
            case .unsupported: "This gateway does not support the stock Bot Chat contract."
            case .missingProfile: "The selected Hermes profile no longer exists."
            case .invalidResponse: "Hermes returned an invalid canonical chat identity."
            case .missingWinner: "Another writer created Bot Chat, but its registry row is not available. Retry opening the bot."
            }
        }
    }
}
