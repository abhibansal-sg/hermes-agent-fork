import XCTest
@testable import HermesMobile

final class ActionAuthorityClientTests: XCTestCase {
    private final class ScriptedTransport: GatewayWebSocketTask, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var captured: [[String: Any]] = []

        init() {
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"capabilities":["session_action_authority_v1"]}}}"#
            ))
        }

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if inbox.isEmpty {
                    waiter = continuation
                    lock.unlock()
                } else {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message,
                  let data = text.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else { return }
            capture(request)

            let result: String
            switch method {
            case "session.watch":
                result = #"{"session_id":"live-1","session_key":"stored-1","messages":[],"action_revision":4}"#
            case "session.takeover":
                result = #"{"session_id":"live-1","session_key":"stored-1","action_revision":5,"taken_over":true}"#
            default:
                result = #"{"status":"streaming"}"#
            }
            enqueue(.string(#"{"jsonrpc":"2.0","id":"\#(id)","result":\#(result)}"#))
            await Task.yield()
        }

        func params(for method: String) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return captured.first(where: { $0["method"] as? String == method })?["params"]
                as? [String: Any]
        }

        private func capture(_ request: [String: Any]) {
            lock.lock()
            captured.append(request)
            lock.unlock()
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }
    }

    func testGatewayEchoesLearnedRevisionAcrossTakeoverAndLaterActions() async throws {
        let transport = ScriptedTransport()
        let client = HermesGatewayClient(transportFactory: { _ in transport })
        try await client.connect(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test"
        )

        let watch: SessionOpenResult = try await client.request(
            "session.watch",
            params: .object(["session_key": .string("stored-1")])
        )
        XCTAssertEqual(watch.actionRevision, 4)

        _ = try await client.requestRaw(
            "session.takeover",
            params: .object(["session_id": .string("live-1")])
        )
        _ = try await client.requestRaw(
            "prompt.submit",
            params: .object([
                "session_id": .string("live-1"),
                "text": .string("hello"),
            ])
        )

        XCTAssertEqual(
            transport.params(for: "session.takeover")?["expected_action_revision"] as? Int,
            4
        )
        XCTAssertEqual(
            transport.params(for: "prompt.submit")?["expected_action_revision"] as? Int,
            5
        )
        await client.disconnect()
    }
}
