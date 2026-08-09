import Foundation

// MARK: - Optional Live Activity provider compatibility

extension RestClient {
    // MARK: - Live Activity token registration (A3)

    /// Result of a Live-Activity token register/unregister call. Soft, never a
    /// throw — a 404 just means the patched endpoint isn't deployed on this
    /// gateway, which must not break a device that can still run the activity
    /// locally.
    enum LiveActivityTokenOutcome: Sendable, Equatable {
        case success
        /// 404 — `/api/push/live-activity` isn't routed on this gateway.
        case notDeployed
        /// Any other status or a transport error.
        case failed
    }

    /// `POST /api/push/live-activity {"token","session_id","env"}` — upsert the
    /// activity's push token, keyed by session id. Re-POST on rotation.
    func registerLiveActivity(
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        await sendLiveActivity(method: "POST", token: token, sessionId: sessionId, env: env)
    }

    /// `DELETE /api/push/live-activity {"token","session_id","env"}` — unregister
    /// on activity end.
    func unregisterLiveActivity(
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        await sendLiveActivity(method: "DELETE", token: token, sessionId: sessionId, env: env)
    }

    /// Self-healing path-family retry (ABH-88): Live-Activity registration can
    /// race the connect-time capability probe (APNs callbacks are OS-timed), so
    /// a `404` on the resolved family retries once on the alternate. A 404 on
    /// BOTH families is the genuine "endpoint not deployed" → `.notDeployed`.
    private func sendLiveActivity(
        method: String,
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        let first = await sendLiveActivityAttempt(
            style: pathStyle, method: method, token: token, sessionId: sessionId, env: env
        )
        guard first == .notDeployed else { return first }
        return await sendLiveActivityAttempt(
            style: pathStyle.alternate, method: method, token: token,
            sessionId: sessionId, env: env
        )
    }

    private func sendLiveActivityAttempt(
        style: APIPathStyle,
        method: String,
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        var request = makeRequest(
            path: "\(style.mobileAPIPrefix)/push/live-activity", method: method
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "token": .string(token),
            "session_id": .string(sessionId),
            "env": .string(env),
        ])
        guard let payload = try? encodeBody(body, context: "push/live-activity") else {
            return .failed
        }
        request.httpBody = payload
        do {
            let (_, response) = try await authorizedDataResponse(for: request)
            if (200..<300).contains(response.statusCode) { return .success }
            if response.statusCode == 404 { return .notDeployed }
            return .failed
        } catch {
            return .failed
        }
    }
}
