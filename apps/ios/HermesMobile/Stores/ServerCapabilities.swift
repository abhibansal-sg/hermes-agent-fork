import Foundation

/// Observable record of stock gateway capabilities used by the native app.
///
/// Each feature is one of three states:
///   - ``State/unknown`` — not yet probed (the safe default; UI shows the
///     feature optimistically until a probe proves it unavailable, except where
///     the contract says otherwise).
///   - ``State/available`` — the probe (or a passive signal) confirmed support.
///   - ``State/unavailable`` — the probe proved the endpoint is missing.
///
/// Capability strategy (cached per server URL + app version in
/// `UserDefaults` so reconnects don't re-probe; a `configure()` to a NEW URL or
/// an app-version change re-probes):
///   - **filesystem**: an independent stock `/api/fs/default-cwd` probe.
///   - **profiles**: one independent stock-route probe.
///   - **broadcast**: passive — marked available when the connection router sees
///     the first event carrying `stored_session_id`; otherwise stays unknown
///     (it is never provably unavailable, which is acceptable).
///
/// `@MainActor`-isolated; stores and views read it on the main actor. The actual
/// HTTP probe runs on a `Sendable` helper so it stays off the main actor.
@MainActor
@Observable
final class ServerCapabilities {

    /// Tri-state support for one feature.
    enum State: String, Sendable, Codable {
        case unknown
        case available
        case unavailable
    }

    /// `stored_session_id` enrichment on broadcast frames. Set passively.
    private(set) var broadcast: State = .unknown
    /// Stock `GET /api/fs/*` + `/api/git/file-diff` file presentation surface.
    /// Probed independently from the mobile plugin so stock Hermes enables the
    /// browser even when no plugin is installed.
    private(set) var fs: State = .unknown
    /// `subagent.*` event emission (F4A-A2). PASSIVE — it can't be eagerly probed
    /// (it only fires when the agent delegates). Set via ``noteSubagentObserved()``
    /// the first time the connection router sees a `subagent.*` frame; stays
    /// `.unknown` until then (never provably unavailable, which is acceptable —
    /// the subagent-tree surface simply has no data on a stock server). Single
    /// writer of this file is F4A-A1; A2 only calls the passive setter.
    private(set) var subagentEvents: State = .unknown
    /// The F4b multi-profile switcher capability. Probed EAGERLY at connect (like
    /// `fs`/`upload`) by hitting `GET /api/profiles/sessions` — the cross-profile
    /// AGGREGATE rail, which is the route genuinely NEW at the upstream rebase: a
    /// `200` with a well-formed `{"sessions":[…]}` body ⇒ available, a `404`/`405`
    /// ⇒ unavailable.
    ///
    /// NOTE the probe deliberately does NOT hit `GET /api/profiles` — that route
    /// already exists on today's server (the desktop profiles page) and would
    /// classify our live 9119 as available, breaking dormancy. EVERY profile
    /// affordance (the drawer switcher, the aggregate rail, per-session profile
    /// threading) gates on `profiles == .available`, so a stock / pre-multi-profile
    /// gateway (today's live 9119) shows none of the switcher chrome and never
    /// errors — the F4b dormancy guarantee.
    private(set) var profiles: State = .unknown
    /// The server URL the current snapshot was probed against. A `configure()` to
    /// a different URL invalidates the snapshot and forces a re-probe.
    private var probedServerURL: String?
    /// The app version the current snapshot was probed against. A version change
    /// (the branch-only feature set may shift between builds) forces a re-probe.
    private var probedAppVersion: String?

    init() {}

    // MARK: - Probe entry point

    /// Probe (or reuse a cached probe of) the gateway at `serverURL`.
    ///
    /// Called by ``ConnectionStore`` after a successful `configure`/connect. If a
    /// cached snapshot exists for this exact `serverURL` + current app version,
    /// it is restored and no network call is made. Otherwise the eager probes
    /// run and the result is cached.
    ///
    /// Broadcast enrichment stays passive (``noteBroadcastObserved()``) and is
    /// preserved across a cache restore so a known value survives reconnect.
    func probe(serverURL: String, rest: RestClient, force: Bool = false) async {
        let version = Self.currentAppVersion
        var reusedPartialCache = false

        // Reuse a cached snapshot for the same server + app version: a reconnect
        // to a server we already probed must not re-probe (contract E1).
        //
        // `force` bypasses BOTH the in-memory short-circuit and the disk-cache
        // restore (R1 #57): after the socket actually DROPPED, the same URL may
        // now serve a different gateway (a restart swapping stock↔patched on
        // the same port), and the cached snapshot would pin features hidden —
        // or shown against 404ing routes — for the rest of the app version.
        // The reconnect path passes `force: true`; the initial connect keeps
        // the cheap cached path.
        if !force {
            if probedServerURL == serverURL,
               probedAppVersion == version,
               fs != .unknown,
               profiles != .unknown {
                return
            }
            if let cached = Self.loadCache(),
               cached.serverURL == serverURL,
               cached.appVersion == version {
                applyCache(cached)
                // A cache is reusable only when every eager capability is
                // conclusive. Build 149 persisted `profiles: unknown` beside a
                // known filesystem result, then treated that partial snapshot as
                // complete forever, hiding the profile picker across launches.
                if fs != .unknown, profiles != .unknown { return }
                reusedPartialCache = true
            }
        }

        if !reusedPartialCache {
            // Fresh server (or new app version): reset passive/derived state so
            // a stale prior-server value can't leak through, then probe.
            broadcast = .unknown
            fs = .unknown
            subagentEvents = .unknown
            profiles = .unknown
            probedServerURL = serverURL
            probedAppVersion = version
        }

        // Files and profiles are independent stock capabilities. A partial
        // cache re-probes only its unknown fields so a transient outage cannot
        // erase a conclusive capability while repairing a different one.
        let cachedFS = fs
        let cachedProfiles = profiles
        async let fsProbe = cachedFS == .unknown
            ? Self.probeStockFS(rest: rest)
            : cachedFS
        async let profilesProbe = cachedProfiles == .unknown
            ? Self.probeProfiles(rest: rest)
            : cachedProfiles
        let (fsState, profilesState) = await (fsProbe, profilesProbe)
        // The connection (and thus serverURL) may have changed while we awaited;
        // only apply if we're still probing the same server.
        guard probedServerURL == serverURL else { return }
        fs = fsState
        profiles = profilesState
        persist()
    }

    /// Clear all capability state (used on an explicit disconnect). The cached
    /// snapshot is intentionally retained so a reconnect to the same server can
    /// reuse it; only the live in-memory state resets to `.unknown`.
    func reset() {
        broadcast = .unknown
        fs = .unknown
        subagentEvents = .unknown
        profiles = .unknown
        probedServerURL = nil
        probedAppVersion = nil
    }

    #if DEBUG
    #endif

    // MARK: - Passive / derived signals

    /// Mark broadcast enrichment available — called by the connection router the
    /// first time an event carries `stored_session_id`. Idempotent; only the
    /// first transition persists.
    func noteBroadcastObserved() {
        guard broadcast != .available else { return }
        broadcast = .available
        persist()
    }

    /// Mark `subagent.*` emission available — called by the connection router the
    /// first time a `subagent.*` frame routes (F4A-A2). Idempotent; only the
    /// first transition persists. Passive (never proves unavailable), mirroring
    /// ``noteBroadcastObserved()``.
    func noteSubagentObserved() {
        guard subagentEvents != .available else { return }
        subagentEvents = .available
        persist()
    }

    #if DEBUG
    /// DEBUG-only: force the `profiles` capability state without a network
    /// probe, so UITestSeed can populate the multi-profile drawer offline.
    /// Mirrors the existing `profileThreadingAvailableForTesting` seam on
    /// SessionStore. Never compiled into Release.
    func _seedProfilesCapabilityForTesting(_ state: State) {
        profiles = state
    }
    #endif

    private nonisolated static func probeStockFS(rest: RestClient) async -> State {
        switch await rest.probeStockFSEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Profiles probe (F4b)

    /// `GET /api/profiles/sessions` (the aggregate rail, NEW at the rebase — NOT
    /// `GET /api/profiles`, which already exists on today's server). A multi-profile
    /// gateway returns `200` with a well-formed `{"sessions":[…]}` body (route
    /// exists ⇒ available); a pre-multi-profile gateway has no such route and
    /// returns `404`/`405` (unavailable). The probe is a read (side-effect-free).
    /// Mirrors ``probeFs``;
    /// the tri-state mapping (available→available, unavailable→unavailable,
    /// inconclusive→unknown) is identical, so a flaky probe leaves `profiles` at
    /// `.unknown` and the switcher stays hidden (the visibility gate requires
    /// `.available`).
    private nonisolated static func probeProfiles(rest: RestClient) async -> State {
        switch await rest.probeProfilesEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Persistence

    /// The serializable snapshot cached in `UserDefaults`. `fs`,
    /// `subagentEvents`, and `profiles` are `decodeIfPresent`-tolerant so a cache
    /// written by a pre-F4A / pre-F4b build (no such keys) restores cleanly as
    /// `.unknown` rather than failing the whole decode (which would force a
    /// needless re-probe).
    private struct Cache: Codable {
        var contractVersion: Int
        var serverURL: String
        var appVersion: String
        var broadcast: State
        var fs: State
        var subagentEvents: State
        var profiles: State

        enum CodingKeys: String, CodingKey {
            case contractVersion, serverURL, appVersion, broadcast, fs, subagentEvents, profiles
        }

        init(
            serverURL: String,
            appVersion: String,
            broadcast: State,
            fs: State,
            subagentEvents: State,
            profiles: State
        ) {
            self.contractVersion = ServerCapabilities.capabilityContractVersion
            self.serverURL = serverURL
            self.appVersion = appVersion
            self.broadcast = broadcast
            self.fs = fs
            self.subagentEvents = subagentEvents
            self.profiles = profiles
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 1
            serverURL = try c.decode(String.self, forKey: .serverURL)
            appVersion = try c.decode(String.self, forKey: .appVersion)
            broadcast = try c.decode(State.self, forKey: .broadcast)
            fs = try c.decodeIfPresent(State.self, forKey: .fs) ?? .unknown
            subagentEvents = try c.decodeIfPresent(State.self, forKey: .subagentEvents) ?? .unknown
            // `decodeIfPresent`-tolerant so a cache written by a pre-F4b build
            // (no `profiles` key) restores cleanly as `.unknown` rather than
            // failing the whole decode (which would force a needless re-probe).
            profiles = try c.decodeIfPresent(State.self, forKey: .profiles) ?? .unknown
        }
    }

    private func applyCache(_ cache: Cache) {
        probedServerURL = cache.serverURL
        probedAppVersion = cache.appVersion
        broadcast = cache.broadcast
        fs = cache.fs
        subagentEvents = cache.subagentEvents
        profiles = cache.profiles
    }

    private func persist() {
        guard let serverURL = probedServerURL, let appVersion = probedAppVersion else { return }
        // An entirely-inconclusive probe (every eager field still .unknown —
        // e.g. a forced reconnect re-probe against a server whose REST was
        // momentarily unreachable) is NOT knowledge: persisting it would
        // overwrite a good snapshot with unknowns that the next UNFORCED
        // probe restores verbatim, hiding pessimistic-gated features across
        // launches until the URL or app version changes (ABH-52 judge round).
        // Keep the prior snapshot; the in-memory unknowns last only until a
        // probe actually concludes.
        guard fs != .unknown || profiles != .unknown else { return }
        let cache = Cache(
            serverURL: serverURL,
            appVersion: appVersion,
            broadcast: broadcast,
            fs: fs,
            subagentEvents: subagentEvents,
            profiles: profiles
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKeys.serverCapabilities)
    }

    private nonisolated static func loadCache() -> Cache? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.serverCapabilities) else {
            return nil
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.contractVersion == capabilityContractVersion else { return nil }
        return cache
    }

    /// `"<short> (<build>)"` — matches the version string SettingsView renders, so
    /// the cache invalidates on any build bump.
    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Bump when a cached field changes authority/meaning. Version 3 removes
    /// the historical broad mobile-plugin capability family.
    nonisolated static let capabilityContractVersion = 3
}
