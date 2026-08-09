import Foundation

// MARK: - Stock Hermes file-browser REST surface
//
// Hermes owns working files through its stock desktop/dashboard routes. Those
// routes accept absolute gateway-local paths, while the iOS browser deliberately
// keeps its navigation state relative to the active session cwd. This extension
// is the bounded presentation adapter between the two contracts: it resolves a
// relative path under the canonical cwd echoed by `session.create`/`resume`/
// `session.info`, calls the stock route, and maps the desktop response into the
// existing native viewer models. It does not persist files or create another
// filesystem authority.
extension RestClient {

    /// Side-effect-free availability check for the stock Hermes filesystem
    /// contract. The response shape matters: an unrelated route returning 200
    /// must not enable the browser.
    func probeStockFSEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "/api/fs/default-cwd", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .inconclusive }
            switch response.statusCode {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["cwd"] is String else { return .inconclusive }
                return .available
            case 404, 405:
                return .unavailable
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    private struct StockFSList: Decodable {
        struct Entry: Decodable {
            let name: String
            let isDirectory: Bool
        }

        let entries: [Entry]
        let error: String?
    }

    private struct StockFSReadText: Decodable {
        let binary: Bool
        let byteSize: Int
        let mimeType: String?
        let path: String
        let text: String
        let truncated: Bool
    }

    private struct StockFSDataURL: Decodable {
        let dataUrl: String
    }

    private struct StockFSDiff: Decodable {
        let diff: String
    }

    // MARK: - List a directory under the canonical session cwd

    /// `GET /api/fs/list?path=<absolute>` using the cwd Hermes reported for the
    /// active runtime. `path` remains relative in the UI (`nil`/empty = cwd).
    func fsList(cwd: String, path: String? = nil) async throws -> FSListResult {
        let resolved = try Self.resolveFSPath(cwd: cwd, path: path)
        let request = makeRequest(
            path: "/api/fs/list?" + Self.fsQuery([
                URLQueryItem(name: "path", value: resolved.absolute)
            ]),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            let payload = try decode(
                StockFSList.self,
                from: data,
                context: "fs.list",
                strategy: .useDefaultKeys
            )
            if let error = payload.error {
                switch error {
                case "ENOENT", "ENOTDIR": throw FSReadError.notAFile
                case "EACCES": throw FSReadError.other("That folder isn't readable.")
                default: throw FSReadError.other("Couldn't read that folder (\(error)).")
                }
            }
            return FSListResult(
                root: resolved.root,
                path: resolved.relative,
                entries: payload.entries.map {
                    FSEntry(name: $0.name, isDir: $0.isDirectory, size: 0, modified: nil)
                },
                truncated: false
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Read a file under the session cwd

    /// `GET /api/fs/read-text?path=<absolute>` — stock Hermes text preview.
    func fsRead(cwd: String, path: String) async throws -> FSReadResult {
        let resolved = try Self.resolveFSPath(cwd: cwd, path: path)
        let request = makeRequest(
            path: "/api/fs/read-text?" + Self.fsQuery([
                URLQueryItem(name: "path", value: resolved.absolute)
            ]),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            let payload = try decode(
                StockFSReadText.self,
                from: data,
                context: "fs.read",
                strategy: .useDefaultKeys
            )
            return FSReadResult(
                path: resolved.relative,
                size: payload.byteSize,
                mimeType: payload.mimeType,
                encoding: payload.binary ? .binary : .utf8,
                content: payload.binary ? nil : payload.text,
                truncated: payload.truncated
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Read an image file as a data URL

    /// `GET /api/fs/read-data-url?path=<absolute>` — stock Hermes binary/image
    /// read used by the native image preview.
    func fsReadAsDataURL(cwd: String, path: String) async throws -> FSReadResult {
        let resolved = try Self.resolveFSPath(cwd: cwd, path: path)
        let request = makeRequest(
            path: "/api/fs/read-data-url?" + Self.fsQuery([
                URLQueryItem(name: "path", value: resolved.absolute)
            ]),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            let payload = try decode(
                StockFSDataURL.self,
                from: data,
                context: "fs.read.image",
                strategy: .useDefaultKeys
            )
            return FSReadResult(
                path: resolved.relative,
                size: 0,
                encoding: .binary,
                content: nil,
                truncated: false,
                dataURL: payload.dataUrl
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Diff a file under the session cwd

    /// `GET /api/git/file-diff?path=<cwd>&file=<relative>` — stock Hermes'
    /// working-tree-vs-HEAD preview. Clean/non-repo outcomes are empty diffs.
    func fsDiff(cwd: String, path: String) async throws -> FSDiffResult {
        let resolved = try Self.resolveFSPath(cwd: cwd, path: path)
        let request = makeRequest(
            path: "/api/git/file-diff?" + Self.fsQuery([
                URLQueryItem(name: "path", value: resolved.root),
                URLQueryItem(name: "file", value: resolved.relative)
            ]),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            let payload = try decode(
                StockFSDiff.self,
                from: data,
                context: "fs.diff",
                strategy: .useDefaultKeys
            )
            return FSDiffResult(
                path: resolved.relative,
                diff: payload.diff,
                hasChanges: !payload.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Helpers

    struct ResolvedFSPath: Equatable, Sendable {
        let root: String
        let relative: String
        let absolute: String
    }

    /// Resolve UI-relative navigation under Hermes' canonical runtime cwd.
    /// Absolute tool-result paths are accepted only when they remain inside the
    /// cwd; traversal and cross-workspace paths never become implicit reads.
    static func resolveFSPath(cwd: String, path: String?) throws -> ResolvedFSPath {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty, trimmedCwd.hasPrefix("/") else {
            throw FSReadError.noActiveSession
        }
        guard !trimmedCwd.contains("\0"), !(path ?? "").contains("\0") else {
            throw FSReadError.pathEscapesRoot
        }

        let root = URL(fileURLWithPath: trimmedCwd, isDirectory: true).standardizedFileURL.path
        let rawPath = path ?? ""
        let absolute: String
        if rawPath.isEmpty {
            absolute = root
        } else if rawPath.lowercased().hasPrefix("file:"),
                  let fileURL = URL(string: rawPath),
                  fileURL.isFileURL,
                  fileURL.host == nil || fileURL.host == "" || fileURL.host == "localhost" {
            absolute = fileURL.standardizedFileURL.path
        } else if rawPath.hasPrefix("/") {
            absolute = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        } else {
            absolute = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(rawPath)
                .standardizedFileURL.path
        }

        let rootPrefix = root == "/" ? "/" : root + "/"
        guard absolute == root || absolute.hasPrefix(rootPrefix) else {
            throw FSReadError.pathEscapesRoot
        }
        let relative: String
        if absolute == root {
            relative = ""
        } else if root == "/" {
            relative = String(absolute.dropFirst())
        } else {
            relative = String(absolute.dropFirst(root.count + 1))
        }
        return ResolvedFSPath(root: root, relative: relative, absolute: absolute)
    }

    /// Percent-encode stock route query values without cloning request plumbing.
    static func fsQuery(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
    }

    /// Map a thrown ``RestError/badStatus`` into the file-specific
    /// ``FSReadError`` cases the UI renders specially; pass anything else through
    /// as ``FSReadError/other`` carrying the original message.
    static func mapFSError(_ error: RestError) -> FSReadError {
        switch error {
        case .badStatus(let code, let body):
            switch code {
            case 413:
                return .tooLarge(size: Self.parseSizeField(from: body))
            case 403:
                return .other("That file isn't readable.")
            case 404:
                return .notAFile
            default:
                return .other(error.errorDescription ?? "HTTP \(code)")
            }
        case .network, .decoding:
            return .other(error.errorDescription ?? "Request failed")
        }
    }

    /// Pull the `"size"` int out of a `413` body (`{"error":"file too
    /// large","size":N}`) for the "Too large (N)" detail; tolerant of absence.
    private static func parseSizeField(from body: String) -> Int? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let size = object["size"] as? Int { return size }
        if let size = object["size"] as? Double { return Int(size) }
        return nil
    }
}

// MARK: - ABH-368 system log viewer

/// Errors surfaced by ``RestClient/systemLogs``. The gateway's `GET /api/logs`
/// returns `400 {"detail":"Unknown log file: foo"}` for an unrecognized `file`
/// param — that is mapped to ``unknownFile`` so the viewer shows "Unknown log
/// file" rather than a generic HTTP error.
enum SystemLogError: Error, LocalizedError, Sendable {
    /// `400` — the `file` key is not in the server's `LOG_FILES`.
    case unknownFile(detail: String)
    /// Any other failure (network, decoding, unexpected status).
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unknownFile(let detail):
            return detail.isEmpty ? "Unknown log file." : detail
        case .other(let message):
            return message
        }
    }
}

extension RestClient {

    // MARK: - System logs tail

    /// `GET /api/logs?file=…&level=…&search=…` — fetch a filtered tail of a
    /// system log file. The server reads up to N lines from the end of the file
    /// (100 by default, capped at 500; 2000 when a search term narrows the
    /// window), applies the `level` (minimum-level) and `search` (case-
    /// insensitive substring) filters server-side, and returns
    /// `{file, lines:[…]}`.
    ///
    /// An unknown `file` key yields a `400` → ``SystemLogError/unknownFile``.
    /// A file that exists but has no content (e.g. `desktop.log` on a headless
    /// server) yields a successful `200` with an empty `lines` array — the
    /// viewer treats that as an honest "no lines" state, NOT an error.
    ///
    /// - Parameters:
    ///   - file: The log file key (e.g. "agent", "errors", "gateway"). The
    ///     valid set comes from the server's `LOG_FILES` — the viewer reads it
    ///     defensively and never hardcodes a list the gateway might not have.
    ///   - level: An optional minimum severity (DEBUG/INFO/WARNING/ERROR).
    ///     `.all` omits the param entirely (the server treats absent as no
    ///     filter).
    ///   - search: An optional case-insensitive substring. Omitted when empty.
    ///   - lineCount: The max lines to return (server caps at 500; 2000 with
    ///     search). Defaults to 200 — enough for a phone tail without flooding.
    /// - Returns: The decoded `{file, lines}` payload.
    func systemLogs(
        file: String,
        level: SystemLogLevel = .all,
        search: String = "",
        lineCount: Int = 200
    ) async throws -> SystemLogResult {
        let query = Self.logsQuery(
            file: file,
            level: level,
            search: search,
            lineCount: lineCount
        )
        // /api/logs is a stock gateway route, so it
        // hangs off /api directly regardless of pathStyle. The existing
        // makeRequest joins the path under baseURL, and the Host override +
        // bearer auth headers are applied uniformly.
        let request = makeRequest(path: "/api/logs?\(query)", method: "GET")
        do {
            let data = try await perform(request)
            return try decode(
                SystemLogResult.self,
                from: data,
                context: "systemLogs",
                strategy: .useDefaultKeys
            )
        } catch let error as RestError {
            throw Self.mapLogsError(error)
        }
    }

    // MARK: - Helpers

    /// Build the `file`/`level`/`search`/`lines` query string, percent-encoding
    /// each value so a search term with spaces or special chars survives. `level`
    /// is omitted entirely for `.all` (the server treats absent/`ALL`/empty as no
    /// filter); `search` is omitted when blank.
    static func logsQuery(
        file: String,
        level: SystemLogLevel,
        search: String,
        lineCount: Int
    ) -> String {
        var items = [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "lines", value: String(lineCount)),
        ]
        if level.isLevel {
            items.append(URLQueryItem(name: "level", value: level.rawValue))
        }
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmedSearch))
        }
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    /// Map a thrown ``RestError/badStatus`` into ``SystemLogError``: a `400`
    /// from `/api/logs` means an unknown file key (surfaced as a clear
    /// "Unknown log file" message); anything else is `.other`.
    static func mapLogsError(_ error: RestError) -> SystemLogError {
        switch error {
        case .badStatus(let code, let body):
            if code == 400 {
                // The server body is FastAPI's {"detail": "Unknown log file: foo"}
                let detail = Self.parseDetailField(from: body) ?? body
                return .unknownFile(detail: detail)
            }
            return .other(error.errorDescription ?? "HTTP \(code)")
        case .network, .decoding:
            return .other(error.errorDescription ?? "Request failed")
        }
    }

    /// Pull the `"detail"` string out of a FastAPI error body
    /// (`{"detail":"Unknown log file: foo"}`); tolerant of absence.
    private static func parseDetailField(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["detail"] as? String
    }
}
