import Foundation

struct AttentionDetail: Codable, Sendable, Equatable {
    let description: String?
    let question: String?
    let choices: [String]

    init(description: String? = nil, question: String? = nil, choices: [String] = []) {
        self.description = description
        self.question = question
        self.choices = choices
    }
}

/// Durable local lifecycle. `responding` and `failedRetryable` are overlays on
/// server pending truth; only a newer server revision or a tombstone may clear
/// them, preventing an older live frame/snapshot from resurrecting a response.
enum AttentionLifecycle: String, Codable, Sendable, Equatable {
    case pending
    case responding
    case resolvedElsewhere = "resolved_elsewhere"
    case expired
    case failedRetryable = "failed_retryable"

    var contributesToPendingCount: Bool {
        switch self {
        case .pending, .responding, .failedRetryable: true
        case .resolvedElsewhere, .expired: false
        }
    }

    var isTerminal: Bool {
        self == .resolvedElsewhere || self == .expired
    }
}

/// Display-safe row persisted in GRDB. It deliberately contains no command
/// output, response text, tool secrets, or conversation content.
struct PersistedAttentionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let requestId: String
    let sessionId: String
    let storedSessionId: String?
    let kind: String
    let safeTitle: String
    let detail: AttentionDetail
    let destructive: Bool
    let createdAt: Double
    let expiresAt: Double?
    var revision: Int64
    var state: AttentionLifecycle
    var updatedAt: Double

    init(id: String, requestId: String, sessionId: String, storedSessionId: String?,
         kind: String, safeTitle: String, detail: AttentionDetail,
         destructive: Bool = false, createdAt: Double, expiresAt: Double? = nil,
         revision: Int64 = 0, state: AttentionLifecycle = .pending,
         updatedAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.requestId = requestId; self.sessionId = sessionId
        self.storedSessionId = storedSessionId?.nilIfBlank; self.kind = kind
        self.safeTitle = safeTitle; self.detail = detail; self.destructive = destructive
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.revision = revision
        self.state = state; self.updatedAt = updatedAt
    }
}

struct AttentionSnapshot: Sendable, Equatable {
    let items: [PersistedAttentionItem]

    var pendingCount: Int { items.reduce(0) { $0 + ($1.state.contributesToPendingCount ? 1 : 0) } }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
