import Foundation

// Stock provider inventory plus stock JSON-RPC credential mutations. Hermes is
// the credential and provider authority; iOS only renders redacted rows and
// transiently forwards a key through `model.save_key`.

// MARK: Provider domain types

/// The `auth_type` of a provider, as reported by the plugin's `/providers` list.
///
/// Only `api_key` providers can be provisioned from a raw key on mobile
/// (Tier A). The OAuth/external auth types (`oauth_device_code`,
/// `oauth_external`, `oauth_minimax`, `external_process`) CANNOT — the plugin
/// rejects them with a 4003-class "set up on desktop" error (parity with stock
/// `model.save_key`). `custom` marks a provider registered via the Tier B
/// custom-provider route (an OpenAI/Anthropic-compatible endpoint).
enum ProviderAuthType: String, Sendable, Equatable {
    case apiKey = "api_key"
    case oauthDeviceCode = "oauth_device_code"
    case oauthExternal = "oauth_external"
    case oauthMinimax = "oauth_minimax"
    case externalProcess = "external_process"
    /// A custom OpenAI/Anthropic-compatible provider (Tier B).
    case custom = "custom"

    /// Stock `model.save_key` accepts registered API-key providers. Custom and
    /// OAuth/external providers remain read-only in this panel.
    var provisionableFromKey: Bool { self == .apiKey }
}

/// One provider row from `GET <prefix>/providers`. The plugin's list projects
/// to a mobile-safe shape — it carries the slug, name, auth type, whether it is
/// the current main provider, the per-provider `authenticated` boolean, and the
/// curated model count, but NEVER a key value, env-var contents, or a secret.
///
/// Decoded leniently via a raw ``JSONValue`` read (the same lenient strategy the
/// other dynamic-key endpoints use) so a partial/legacy payload renders rather
/// than throwing. Mirrors the ``ModelProvider`` field set the model picker keys
/// off, minus the per-model list (the list endpoint omits `models`; the
/// key/custom responses include them).
struct ProviderRow: Identifiable, Sendable, Equatable, Hashable {
    let slug: String
    let name: String
    let authType: ProviderAuthType?
    let isCurrent: Bool
    let authenticated: Bool
    let totalModels: Int
    /// The curated model ids (present on the POST key/custom responses; the GET
    /// list omits this). `nil` = unknown / not provided by this response.
    let models: [String]?
    /// ABH-257: base_url for a custom provider (present only on custom rows).
    /// Used to pre-fill the edit/rotate form. `nil` for registered providers.
    let baseURL: String?
    /// ABH-257: api_mode for a custom provider (present only on custom rows).
    /// Used to pre-fill the edit/rotate form. `nil` for registered providers.
    let apiMode: ProviderAPIMode?
    /// STR-112: exact raw api_mode from a custom provider row. Known values map
    /// to ``apiMode`` as before; unknown values remain available for edit/save
    /// preservation instead of silently falling back to OpenAI-compatible.
    let rawAPIMode: String?

    var id: String { slug }

    /// Whether this provider can be provisioned from a raw API key on mobile
    /// (Tier A / Tier B). Delegates to the auth type: `api_key` and `custom`
    /// providers qualify; OAuth/external types must be set up on the desktop
    /// (the plugin rejects them with a 4003-class error), and a row whose
    /// `auth_type` we could not classify is conservatively NOT provisionable
    /// from mobile.
    var provisionableFromKey: Bool { authType?.provisionableFromKey ?? false }

    /// Memberwise init (so the list view can flip a row locally after a
    /// disconnect without re-decoding from JSON).
    init(
        slug: String,
        name: String,
        authType: ProviderAuthType?,
        isCurrent: Bool,
        authenticated: Bool,
        totalModels: Int,
        models: [String]?,
        baseURL: String? = nil,
        apiMode: ProviderAPIMode? = nil,
        rawAPIMode: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.authType = authType
        self.isCurrent = isCurrent
        self.authenticated = authenticated
        self.totalModels = totalModels
        self.models = models
        self.baseURL = baseURL
        self.apiMode = apiMode
        self.rawAPIMode = rawAPIMode ?? apiMode?.rawValue
    }

    func copy(
        isCurrent: Bool? = nil,
        authenticated: Bool? = nil
    ) -> ProviderRow {
        ProviderRow(
            slug: slug,
            name: name,
            authType: authType,
            isCurrent: isCurrent ?? self.isCurrent,
            authenticated: authenticated ?? self.authenticated,
            totalModels: totalModels,
            models: models,
            baseURL: baseURL,
            apiMode: apiMode
        )
    }

    init(json: JSONValue) {
        self.slug = json["slug"]?.stringValue ?? ""
        self.name = json["name"]?.stringValue ?? json["slug"]?.stringValue ?? ""
        let rawAuth = json["auth_type"]?.stringValue ?? ""
        self.authType = ProviderAuthType(rawValue: rawAuth)
        self.isCurrent = json["is_current"]?.boolValue ?? false
        self.authenticated = json["authenticated"]?.boolValue ?? false
        self.totalModels = json["total_models"]?.intValue ?? 0
        if let array = json["models"]?.arrayValue {
            // The custom/key responses carry `models` as a list of `{id}` objects
            // (the inventory builder's row shape); tolerate bare strings too.
            self.models = array.compactMap { $0["id"]?.stringValue ?? $0.stringValue }
        } else {
            self.models = nil
        }
        // ABH-257: custom-provider transport metadata for the edit/rotate form.
        self.baseURL = json["base_url"]?.stringValue
        let rawMode = json["api_mode"]?.stringValue ?? ""
        self.rawAPIMode = rawMode.isEmpty ? nil : rawMode
        self.apiMode = rawMode.isEmpty ? nil : ProviderAPIMode(rawValue: rawMode)
    }
}

/// Provider credential mutation result. The refreshed provider row is nested
/// under `provider`; validation
/// result fields are siblings at the response root. Preserve the gateway's
/// tri-state validation result: accepted, rejected, or saved-but-not-verified.
enum ProviderKeyValidationStatus: Sendable, Equatable {
    case verified
    case rejected
    case skipped
    case unknown

    init(json: JSONValue?) {
        if json?.boolValue == true {
            self = .verified
        } else if json?.boolValue == false {
            self = .rejected
        } else if json?.stringValue == "skipped" {
            self = .skipped
        } else {
            self = .unknown
        }
    }
}

/// A definitive rejection means the upstream provider rejected the key. The
/// `persisted` field distinguishes whether the rejected key was written:
/// `false` means nothing was saved, while `true` or `nil` preserves the older
/// persisted-on-reject behavior. A skipped validation means the key may be
/// persisted but was not verified.
struct ProviderKeyResult: Sendable, Equatable {
    let row: ProviderRow
    let validationStatus: ProviderKeyValidationStatus
    let validationDetail: String?
    let persisted: Bool?

    init(root: JSONValue) {
        let providerJSON = root["provider"] ?? root
        self.row = ProviderRow(json: providerJSON)
        self.validationStatus = ProviderKeyValidationStatus(json: root["validated"])
        self.validationDetail = root["validation_detail"]?.stringValue
        self.persisted = root["persisted"]?.boolValue
    }

    init(row: ProviderRow, validationStatus: ProviderKeyValidationStatus, persisted: Bool?) {
        self.row = row
        self.validationStatus = validationStatus
        self.validationDetail = nil
        self.persisted = persisted
    }
}

/// Stock `model.disconnect` result — slug, name, and disconnected flag.
struct ProviderDisconnectResult: Sendable, Equatable {
    let slug: String
    let name: String
    let disconnected: Bool

    init(json: JSONValue) {
        self.slug = json["slug"]?.stringValue ?? ""
        self.name = json["name"]?.stringValue ?? json["slug"]?.stringValue ?? ""
        self.disconnected = json["disconnected"]?.boolValue ?? false
    }
}

/// The `api_mode` of a custom (Tier B) provider — OpenAI-compatible chat
/// completions or Anthropic messages.
enum ProviderAPIMode: String, Sendable, CaseIterable, Identifiable {
    case openai
    case anthropicMessages = "anthropic_messages"

    var id: String { rawValue }

    /// The human-readable label for the custom-provider picker.
    var label: String {
        switch self {
        case .openai: return "OpenAI-compatible"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }
}

// MARK: - Provider/key-entry endpoints

extension RestClient {

    // MARK: - List the provider universe (the picker's data)

    /// Stock model inventory. Reveals names, auth hints, and authentication state
    /// but never credential values.
    func listProviders() async throws -> [ProviderRow] {
        let data = try await get(path: "/api/model/options?include_unconfigured=true")
        let root = try decodeJSONValue(from: data, context: "providers.list")
        let array = root["providers"]?.arrayValue
            ?? (root.arrayValue ?? [])
        return array.map(ProviderRow.init(json:))
    }

}

// Stock Hermes owns built-in provider credential mutations over JSON-RPC.
extension HermesGatewayClient {
    func saveModelProviderKey(slug: String, apiKey: String) async throws -> ProviderKeyResult {
        let root = try await requestRaw(
            "model.save_key",
            params: .object(["slug": .string(slug), "api_key": .string(apiKey)])
        )
        return ProviderKeyResult(
            row: ProviderRow(json: root["provider"] ?? root),
            validationStatus: .verified,
            persisted: true
        )
    }

    func disconnectModelProvider(slug: String) async throws -> ProviderDisconnectResult {
        let root = try await requestRaw(
            "model.disconnect",
            params: .object(["slug": .string(slug)])
        )
        return ProviderDisconnectResult(json: root)
    }
}


// MARK: - Stock Hermes toolset credential REST surface
//
// iOS consumes the same native routes as the Hermes desktop dashboard:
//
//   GET    /api/tools/toolsets/{name}/config
//   PUT    /api/tools/toolsets/{name}/env {"env":{"ENV_VAR":"..."}}
//   DELETE /api/env {"key":"ENV_VAR"}
//   PUT    /api/tools/toolsets/{name}/provider {"provider":"tag"}
//
// The GET response is explicitly redacted: env vars carry `is_set` only, never
// the stored value. PUT with an empty value clears the env var. This extension
// keeps the iOS app on the same RestClient plumbing as the provider-key surface
// (Host override, X-Hermes-Session-Token auth header, timeout, JSON helpers).

// MARK: Toolset config domain types

struct ToolsetConfig: Identifiable, Sendable, Equatable {
    let name: String
    let hasCategory: Bool
    let providers: [ToolsetConfigProvider]
    let activeProvider: String?

    var id: String { name }

    var displayName: String { Self.displayName(for: name) }

    var configuredCredentialCount: Int {
        providers.reduce(0) { total, provider in
            total + provider.envVars.filter(\.isSet).count
        }
    }

    var credentialCount: Int {
        providers.reduce(0) { $0 + $1.envVars.count }
    }

    var hasConfiguredCredential: Bool { configuredCredentialCount > 0 }

    init(
        name: String,
        hasCategory: Bool,
        providers: [ToolsetConfigProvider],
        activeProvider: String?
    ) {
        self.name = name
        self.hasCategory = hasCategory
        self.providers = providers
        self.activeProvider = activeProvider
    }

    init(json: JSONValue) {
        let name = json["name"]?.stringValue ?? ""
        self.name = name
        self.hasCategory = json["has_category"]?.boolValue ?? false
        self.activeProvider = json["active_provider"]?.stringValue
        self.providers = (json["providers"]?.arrayValue ?? []).map {
            ToolsetConfigProvider(json: $0, toolsetName: name)
        }
    }

    static func displayName(for name: String) -> String {
        switch name {
        case "web": return "Web Search"
        case "image_gen": return "Image Generation"
        default:
            return name
                .split(separator: "_")
                .map { part in
                    String(part.prefix(1)).uppercased() + String(part.dropFirst())
                }
                .joined(separator: " ")
        }
    }
}

struct ToolsetConfigProvider: Identifiable, Sendable, Equatable {
    let toolsetName: String
    let name: String
    let badge: String
    let tag: String
    let envVars: [ToolsetEnvVar]
    let postSetup: String?
    let requiresNousAuth: Bool
    let isActive: Bool

    var id: String { "\(toolsetName)::\(name)::\(tag)::\(badge)" }

    init(
        toolsetName: String,
        name: String,
        badge: String,
        tag: String,
        envVars: [ToolsetEnvVar],
        postSetup: String?,
        requiresNousAuth: Bool,
        isActive: Bool
    ) {
        self.toolsetName = toolsetName
        self.name = name
        self.badge = badge
        self.tag = tag
        self.envVars = envVars
        self.postSetup = postSetup
        self.requiresNousAuth = requiresNousAuth
        self.isActive = isActive
    }

    init(json: JSONValue, toolsetName: String) {
        self.toolsetName = toolsetName
        self.name = json["name"]?.stringValue ?? ""
        self.badge = json["badge"]?.stringValue ?? ""
        self.tag = json["tag"]?.stringValue ?? ""
        self.envVars = (json["env_vars"]?.arrayValue ?? []).map(ToolsetEnvVar.init(json:))
        self.postSetup = json["post_setup"]?.stringValue
        self.requiresNousAuth = json["requires_nous_auth"]?.boolValue ?? false
        self.isActive = json["is_active"]?.boolValue ?? false
    }
}

struct ToolsetEnvVar: Identifiable, Sendable, Equatable, Hashable {
    let key: String
    let prompt: String
    let url: String?
    let defaultValue: String?
    let isSet: Bool

    var id: String { key }

    init(key: String, prompt: String, url: String?, defaultValue: String?, isSet: Bool) {
        self.key = key
        self.prompt = prompt
        self.url = url
        self.defaultValue = defaultValue
        self.isSet = isSet
    }

    init(json: JSONValue) {
        self.key = json["key"]?.stringValue ?? ""
        self.prompt = json["prompt"]?.stringValue ?? json["key"]?.stringValue ?? ""
        self.url = json["url"]?.stringValue
        self.defaultValue = json["default"]?.stringValue
        self.isSet = json["is_set"]?.boolValue ?? false
    }
}

enum ToolsetConfigCatalog {
    /// The server currently exposes toolset config one toolset at a time rather
    /// than a list endpoint. Keep this starter set aligned with the shipped top
    /// non-model credential panels ABH-262 asked to surface on iOS.
    /// "web" (Web Search) and "image_gen" (Image Generation) are the gateway's
    /// canonical configurable toolset keys (CONFIGURABLE_TOOLSETS in
    /// hermes_cli/tools_config.py). The individual TOOLS web_search / web_extract
    /// live INSIDE the "web" toolset — the config path segment is "web", not
    /// "web_search".
    static let configurableNames = ["web", "image_gen"]
}

// MARK: - Toolset credential endpoints

extension RestClient {

    /// Stock toolset config — returns provider/env-var status
    /// for one toolset. The response never includes a stored secret value.
    func getToolsetConfig(name: String) async throws -> ToolsetConfig {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        let data = try await get(path: "/api/tools/toolsets/\(encodedName)/config")
        let root = try decodeJSONValue(from: data, context: "toolsets.config")
        return ToolsetConfig(json: root)
    }

    /// Set through stock `/env`, clear through stock `DELETE /api/env`, then
    /// re-read the canonical redacted toolset config.
    @discardableResult
    func setToolsetCredential(name: String, key: String, value: String?) async throws -> ToolsetConfig {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var request = makeRequest(
            path: trimmed.isEmpty ? "/api/env" : "/api/tools/toolsets/\(encodedName)/env",
            method: trimmed.isEmpty ? "DELETE" : "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = trimmed.isEmpty
            ? .object(["key": .string(key)])
            : .object(["env": .object([key: .string(trimmed)])])
        request.httpBody = try encodeBody(body, context: "toolsets.setConfig")
        _ = try await perform(request)
        return try await getToolsetConfig(name: name)
    }

    /// Stock provider selection. Re-read after mutation because the native route
    /// returns mutation status, while the UI needs the canonical provider matrix.
    /// a configurable toolset. The refreshed config is returned so callers can
    /// update the active row from the server's canonical state.
    @discardableResult
    func selectToolsetProvider(name: String, provider: String) async throws -> ToolsetConfig {
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? name
        var request = makeRequest(
            path: "/api/tools/toolsets/\(encodedName)/provider", method: "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object(["provider": .string(provider)])
        request.httpBody = try encodeBody(body, context: "toolsets.selectProvider")
        _ = try await perform(request)
        return try await getToolsetConfig(name: name)
    }
}
