# Option C upstream-first forward-port ledger

Status: P-1 through H5 implemented; existing iOS app remains the release foundation

Upstream baseline: `31cedb4830191da7f8c3ea4b962d40997cd85b21`

Fork release head: `c1cb17ad281a2eaf38da2595b0a91584b6935c89`

Merge base: `306e2d2318745b48d0c9d249958b0190f65a07c9`

At the start of this forward-port, the fork had 604 local-only commits and 5,686
upstream-only commits. The integration branch records both parents but takes its stock
Hermes tree from upstream. A fork change is present only when this ledger explicitly
retains or rewrites it.

## Gate result so far

- The existing `apps/ios` application and `scripts/ios-build.sh` were forward-ported as
  their current fork tree. The merge parent preserves the complete fork ancestry.
- `.github/workflows/ios-tests.yml` was retained after a path-level audit found it was
  the only required iOS build surface outside `apps/ios` and the wrapper script. Its
  build invocation now uses the retained safe wrapper and watches wrapper changes.
- The uncommitted Timeline presentation-cache spike was preserved as a distinct commit.
- No `plugins/hermes-mobile`, `relay`, fork `server`, `tui_gateway`, dashboard-auth, or
  stock web-server change was imported with the app.
- The app compiles through the safe wrapper when asset compilation is excluded, and the
  focused Timeline test target builds for testing. Full asset compilation is currently
  blocked by the host CoreSimulator service failing `simctl`/`actool` with `ENOMEM`; this
  is an environment failure rather than an app compile failure.

## Disposition rules

Every fork-only item belongs to exactly one class:

1. **Retain unchanged at the client edge** — current iOS product behavior or build/test
   infrastructure that does not claim Hermes authority.
2. **Rewrite against current stock Hermes** — the user outcome remains, but the old core
   seam or protocol premise is obsolete.
3. **Contract into a thin provider** — credentials/ownership policy, durable prompt
   receipt storage, or optional Apple delivery only.
4. **Delete as duplicate authority** — attachment/file/transcript/timeline/workflow or
   relay authority already owned by stock Hermes.
5. **Compatibility read shim only** — temporarily required to read legacy data; never a
   new-write path.

## Retain unchanged at the client edge

| Surface | Disposition | Evidence/gate |
|---|---|---|
| `apps/ios` SwiftUI application, extensions, stores, and tests | Forward-ported in full, then evolved incrementally | Existing app remains the product foundation; no rewrite-from-scratch |
| `scripts/ios-build.sh` | Retain | All iOS builds remain machine-serialized and SIGTERM-only |
| `TimelineModels`, `TimelineReducer`, `TimelineStore` spike | Retain as bounded non-authoritative cache | Must pass privacy, retention, WAL/checkpoint, hydration-race, and canonical-reconcile gates before UI enablement |
| Keychain credential storage and generation-scoped client state | Retain, adapt wire protocol | Credentials remain device-local; Hermes remains live/canonical authority |
| Native SwiftUI transcript, composer, Turn Dock, accessibility, widgets, share extension | Retain | UI behavior is migrated behind stable stores, not replaced |

Retaining a client file does not approve every endpoint it currently calls. Network route
use is separately classified below.

## Rewrite against current stock Hermes

| Fork behavior/seam | Replacement |
|---|---|
| `TOKEN_AUTHENTICATORS`, `IDENTITY_VALIDATORS`, `SOCKET_OBSERVERS`, `SESSION_OWNERSHIP_CHECKERS` | Stock `DashboardAuthProvider` credentials plus H2 authenticated-principal propagation and generic action authorization |
| Device credential accepted as another long-lived WS `?token=` | Provider-verified bearer/refresh, stock one-use WS ticket, principal attached to `WSTransport`; legacy shared `?token=` remains loopback compatibility only |
| Fork WebSocket device lifecycle wrappers around every route | One stock authenticated transport context plus provider revocation callback; no per-route socket wrapper layer |
| Fork `register_prompt_receipt_provider()` and inline `prompt.submit` patch | H3 generic prompt-admission contract in current `tui_gateway/methods_prompt.py`; storage remains provider-owned |
| Ad-hoc device ownership checks on selected RPCs | One H2 admission helper covering live resume/activate, submit/queue/truncate, steer/redirect/interrupt, secure responses, attachments, conversation controls, session-scoped writes, and takeover |
| Plugin capability bundle detection | Individually versioned stock capabilities (`session_watch_v1`, `session_action_authority_v1`, `prompt_receipt_admission_v1`, `session_files_v1`) |
| iOS connection paths that assume non-loopback `--insecure` | Current upstream rule: non-loopback is always gated; loopback shared-token fallback is explicit and bounded |

None of the 16 fork-only commits touching `tui_gateway`/dashboard auth/web-server are
carried wholesale. Their behavior must be re-proven against the current split method
modules, auth middleware, WS ticket store, and session locks.

## Contract into thin providers

| Current module/responsibility | Smallest retained surface |
|---|---|
| `device_tokens.py` and device routes | A `DashboardAuthProvider`-compatible credential/refresh/revocation store, one-time pairing bootstrap, authenticated principal, ownership revision/policy state |
| `prompt_receipts.py` | Durable implementation of H3 reserve/complete/release; no session or transcript authority |
| `push_engine.py` plus APNs/Live Activity registration | Optional Apple delivery adapter consuming stock outcomes; no waiter/session lifecycle ownership |
| `mobile_pair.py` | Provider CLI that emits a short-lived one-use bootstrap code, never shared/final bearer credentials |
| Background notification response | Thin adapter into stock approval/clarify/action authorization; no duplicate approval resolver |

The provider package must remain fully removable: stock Hermes chat, attachments, files,
transcripts, and Desktop continue to work with all three providers absent.

## Delete as duplicate authority

The current broad dashboard plugin exposes 29 routes. The following groups are deleted
from new-write/read authority and replaced by stock mechanisms:

| Plugin routes/modules | Stock owner |
|---|---|
| `/upload`, `/attachments/{name}` | `image.attach_bytes`, `pdf.attach`, `file.attach`, `/api/media`; large files use session-scoped `/api/files/upload-stream` then `file.attach` |
| `/fs/list`, `/fs/read`, `/fs/diff` | Stock `/api/fs/*`, Git diff, managed-file APIs with generic optional session scope |
| `/sessions/search`, `/sessions/{id}/messages`, `/messages/around`, `transcript_sync.py` | Stock search and bounded 500-row transcript pages; client reconciliation/windowing |
| `/artifacts` | Index the bounded canonical iOS transcript cache; no server artifact authority |
| `/providers*`, `/toolsets*` | Stock provider/model/toolset APIs and RPCs |
| `/debug-share` | Stock `/api/ops/debug-share` |
| `pending_attention.py`, manifest/attention journals | Stock waiter/live state, H1 current snapshot, canonical transcript, and disposable client cache |
| `relay_client.py` chat/session transport | Stock `/api/ws` JSON-RPC only |
| `ios_turn_context.py` prompt mutation | Delete; presentation does not modify the system/user prompt |
| `gitbranch.py` | Stock session cwd/project metadata and `session.workspace.move` |
| Plugin takeover or session workflow | Stock H2 `session.takeover` and existing session methods |
| Semantic journal/raw-frame replay | Do not build |

Memory approval routes in the broad plugin are outside the continuity release. They are
not implicitly retained; any future consumer must independently prove that stock Hermes
lacks an equivalent and pass the footprint ladder.

## Compatibility read shims

Only legacy attachment bytes or provider data that have no stock read path may receive a
versioned read-only shim. Conditions:

- no new writes;
- no live session lookup or workflow state;
- explicit supported-client expiry;
- reversible package removal;
- deletion requires separate authorization after the compatibility window.

## Upstream developments that replace fork assumptions

- `session.active_list` and `session.activate` are the stock live-session surface.
- Desktop HUD handoff confirms one live driver transport; H1 adds watch without rebinding.
- `messages_omitted` is not an empty transcript; adopted running turns hydrate after settle.
- Desktop uses one stale-runtime resolver across submit, attachment, and safe controls.
- `session.workspace.move` and session-info cwd own workspace selection.
- Native image/PDF/file attachment RPCs now cover remote, Docker, cold-container, and
  multi-backend delivery.
- REST transcripts are bounded/paged and resume/export safety limits are configurable.
- `gateway/turn_lease.py` and active-turn crash markers supply safety invariants but govern
  the messaging gateway, not `tui_gateway` cross-device ownership.
- Dashboard auth supplies provider registration, bearer sessions, refresh, RFC 8252 for
  Desktop, and one-use WS tickets. H2 extends identity continuity into JSON-RPC and
  loopback capable clients; it does not create a mobile auth stack.

## P-1 exit criteria

- [x] Clean branch starts at audited upstream.
- [x] Fork ancestry retained without importing the fork tree wholesale.
- [x] Existing iOS app and safe build wrapper forward-ported.
- [x] Timeline spike preserved separately.
- [x] Swift application compile proven through the wrapper.
- [x] Focused Timeline test target builds for testing.
- [x] Full asset build/test is formally waived for P-1: `simctl` and `actool` both fail
  in CoreSimulatorService with `ENOMEM`, while asset-excluded Swift compilation and the
  focused test build succeed. The full run remains a required later verification gate.
- [x] Broad plugin/core changes classified before implementation.
- [x] Review confirms no required non-iOS client/build file was omitted; the path-level
  fork audit retained `.github/workflows/ios-tests.yml` and classified the remaining
  matches as archived design evidence or intentionally excluded duplicate plugin authority.

H1/H2/H3 work may begin only after the final two unchecked items are resolved or formally
waived with evidence.

## H1 implementation result

- Stock `tui_gateway` now exposes `session.watch`, addressable by runtime
  `session_id` or canonical stored `session_key`.
- The watch response reuses the stock bounded live-session projection, including
  canonical visible messages, `inflight`, queued prompt, runtime info, and status.
- The method never changes the driver transport, renderer columns, or activity
  timestamp. `session.activate` remains the explicit rebinding/handoff operation.
- Both stdio and WebSocket `gateway.ready` frames advertise the versioned
  `session_watch_v1` capability through one shared payload builder.
- The existing iOS app records versioned gateway capabilities per accepted
  connection generation, prefers `session.watch`, and keeps `session.active_list`
  as an older-stock fallback.
- A watched running snapshot hydrates as a foreign mirrored turn on iOS: partial
  output is visible, `localTurnInFlight` stays false, and prompt submission remains
  the deliberate watch-to-drive transition.
- Because stock session events remain driver-routed, iOS refreshes the bounded
  watch snapshot only while selected: 250 ms while working, 2 s while idle. An
  observed settle uses the existing canonical transcript backfill; no broadcast,
  replay, or observer authority is added to the gateway.

Verification evidence:

- 912 tests across `tests/test_tui_gateway_server.py` and `tests/tui_gateway/` pass.
- Focused `ProtocolParityTests` test target builds successfully in Swift 6 complete
  concurrency mode through `scripts/ios-build.sh` with the asset catalog excluded.
- Runtime simulator execution remains blocked by the host CoreSimulatorService
  `ENOMEM` failure confirmed independently through `simctl`.

## H2 implementation result

- Dashboard-auth `Session` can carry an optional provider-verified `client_id`.
  Providers that omit it retain user-scoped compatibility; the gateway never
  accepts a client-asserted identity from JSON-RPC params.
- One-use WS tickets preserve the verified client/user identity through the
  upgrade and attach a transport-neutral `AuthenticatedPrincipal` to
  `WSTransport`. Internal, loopback, and stdio links also have explicit stable
  local principals.
- Every newly registered live session records its action owner, revision, and
  owner transport. Legacy live records are claimed by their first mutation.
- One central dispatcher admission seam covers live prompt/file/attachment,
  session-control, secure-response, and subagent mutations. Same-owner actions
  succeed; foreign owners receive `4091`; stale optimistic revisions receive
  `4092`. Read methods, including `session.watch`, never enter this seam.
- `session.takeover` requires the caller's expected revision and atomically
  changes owner, increments the revision, and rebinds the driver transport.
  A concurrent resume cannot overwrite a foreign claim.
- `gateway.ready` advertises `session_action_authority_v1`. Live snapshots and
  create/resume results carry the current revision so clients do not infer it.
- The existing iOS gateway client keeps a connection-local revision projection,
  echoes Hermes' revision on later session actions, and explicitly calls
  `session.takeover` before changing a watched session from observation to file/
  prompt driving. This projection is not authorization authority; every decision
  remains server-side.

Verification evidence:

- 921 tests across `tests/test_tui_gateway_server.py` and `tests/tui_gateway/`
  pass (one unrelated skip).
- 124 dashboard-auth tests pass; one pre-existing sidecar URL test is sensitive
  to the developer machine's configured public dashboard URL and fails its
  `bound_host=None` premise in that environment. The new ticket-principal test
  passes independently.
- The focused `ActionAuthorityClientTests` Swift 6 test target builds for testing
  through `scripts/ios-build.sh` with the asset catalog excluded.
- Runtime simulator execution and asset compilation remain blocked by the same
  host CoreSimulatorService `ENOMEM` failure recorded for H1.

## H3 implementation result

- Stock `tui_gateway` now owns one central `prompt.submit` admission contract.
  Requests without `client_message_id`, and installations without a receipt
  provider, preserve the legacy handler and response shape exactly.
- With a provider active, Hermes validates a canonical lowercase UUID, sanitizes
  and fingerprints the behavior-changing request fields against the stable
  compression-lineage root, and reserves the identity before truncation, queue,
  interrupt, or prompt mutation can run.
- Accepted dispositions are limited to the stock prompt outcomes `streaming`,
  `queued`, `steered`, and `redirected`. Replays return the original disposition
  with `deduplicated=true`; changed payloads return `4093`; live reservations
  return `in_progress`; a reservation abandoned across a process boundary becomes
  `indeterminate`. Handler rejection releases the reservation for a safe retry.
- Hermes carries the admitted ID as display-only user-message metadata through
  inline turns, busy queues, and isolated compute-host turns. The canonical
  transcript projects it as `client_message_id` for iOS outbox reconciliation;
  prompt text and the model-facing cached prefix remain unchanged.
- The removable `hermes-mobile` backend plugin implements only the
  reserve/complete/release store in a profile-scoped SQLite database. It uses
  parameterized SQL, `BEGIN IMMEDIATE`, 30-day retention, private permissions,
  the stock Hermes journal-mode safety policy (WAL when safe, guarded DELETE
  fallback otherwise), and `synchronous=FULL`; it cannot execute, queue,
  rewrite, attach, or replay a prompt.
- `gateway.ready` advertises `prompt_receipt_admission_v1` only when stock plugin
  discovery successfully registers a provider. The existing iOS app keeps its
  durable outbox and now recognizes every stock accepted prompt disposition,
  including `redirected`.
- A durable receipt records Hermes' accepted admission disposition, not proof
  that the model turn completed. A crash after reservation but before admission
  completion remains explicitly `indeterminate`; no duplicate durable execution
  queue or second transcript/workflow authority is introduced.

Verification evidence:

- 941 tests across `tests/test_tui_gateway_server.py` and `tests/tui_gateway/`
  pass.
- 55 stock plugin and dashboard-auth contract/ticket tests pass.
- The 19 focused H3 tests cover replay, conflicting fingerprints, concurrent
  reservation, rejection release, completion failure, restart ambiguity,
  profile isolation, retention, permissions, provider absence/discovery,
  compression lineage, queue separation, and canonical metadata projection.
- The focused `OutboxProcessorTests` Swift 6 test target builds for testing
  through `scripts/ios-build.sh` with the asset catalog excluded.
- Runtime simulator execution remains blocked by the previously documented host
  CoreSimulatorService `ENOMEM` failure; no raw `xcodebuild` was used.

## H4 native credential contract

Backend provider result:

- The stock dashboard-auth stack now distinguishes session providers that can
  verify/refresh credentials from providers that intentionally expose a human browser
  login. This generic flag keeps native-only providers in Bearer verification and
  refresh while excluding them from `/login`, auto-SSO, native OAuth broker selection,
  and login-provider discovery.
- The removable `hermes-mobile` provider owns only profile-scoped native credentials.
  It stores SHA-256 hashes of 256-bit random bootstraps/access/refresh tokens in
  `plugins/hermes-mobile/native_auth.sqlite3`, with private directory/file modes,
  parameterized SQL, `BEGIN IMMEDIATE`, `synchronous=FULL`, and the stock Hermes
  WAL/network-filesystem fallback policy. No raw credential is persisted or logged.
- `hermes mobile-pair --url https://…` mints a five-minute, single-use bootstrap.
  The QR/deep link contains `kind=provider`, the public gated gateway URL, and only
  that bootstrap. The command refuses cleartext HTTP and never embeds final access or
  refresh credentials.
- The bootstrap is exchanged exactly once at
  `/api/plugins/hermes-mobile/pair/exchange`. The route is opted into the stock exact-
  path token-auth seam, validates the provider/scope, consumes the bootstrap atomically,
  and returns a non-cacheable standard native credential bundle with a stable
  `client_id`.
- Access tokens expire after 15 minutes. Refresh tokens expire after 30 days and rotate
  on every stock `/auth/native/refresh` call; rotation invalidates the prior access and
  refresh pair. Best-effort provider revocation invalidates both. Store outages use the
  stock `ProviderError`/503 semantics rather than being misreported as bad credentials.
- After exchange, no plugin transport is involved: REST uses stock
  `Authorization: Bearer`, WebSocket connects mint a stock one-use 30-second
  `/api/auth/ws-ticket`, and `/api/ws?ticket=…` carries the verified user/client
  principal into H2 action authority. The provider has no transcript, file,
  attachment, timeline, queue, relay, or workflow tables.
- Existing shared loopback-token gateways remain a separate compatibility mode. The
  provider credential mode is for current non-loopback gated Hermes endpoints; iOS will
  preserve the loopback fallback while preferring the provider bundle for remote
  gateways.

Backend verification evidence:

- Eight focused provider tests cover protocol compliance, hidden login discovery,
  hashed/private bootstrap storage, TTL, single use, concurrent exchange, rotating
  refresh, access invalidation, revocation, expiry, store-outage semantics, HTTPS-only
  pairing URLs, non-cacheable exchange, stock Bearer auth, and stock WS ticket identity.
- 161 dashboard-auth/provider regression tests pass across the focused provider file,
  native OAuth, WS tickets, 401 re-auth, token auth, plugin hook, and all bundled
  dashboard-auth provider suites.
- Ruff, Python compilation, and `git diff --check` pass.

Existing-iOS client result:

- The current SwiftUI application remains the product foundation. Pair parsing adds
  `kind=provider&bootstrap=…` without changing the legacy shared/device/manual-token
  payloads; provider pairing requires HTTPS and stores no bootstrap value.
- The access/refresh pair and stable provider/user/client metadata are committed as one
  server-scoped Keychain value. A successful provider commit removes the legacy shared
  token only afterwards; cold launch prefers the provider bundle and retains the legacy
  fallback when no bundle exists.
- One `NativeCredentialController` actor owns the live credential for the active server.
  REST requests, capability probes, uploads, ticket minting, and reconnects share its
  single refresh flight. A rotated pair is usable only after its atomic Keychain commit;
  commit failure poisons the actor and routes the app to re-pair instead of replaying the
  consumed refresh token.
- Remote REST uses stock Bearer auth and preserves the URL's real Host. Legacy
  loopback/Serve requests keep `X-Hermes-Session-Token` and the loopback Host override.
  Direct extension-level URLSession calls were folded into the common authorized
  response path, including one 401 retry.
- Every provider WebSocket attempt mints a fresh stock ticket immediately before
  connect and uses `/api/ws?ticket=…`; provider access and refresh tokens never enter a
  WebSocket URL. Every post-ticket and post-connect state mutation remains fenced by the
  existing connection generation.
- Provider mode skips the old plugin device-token auto-upgrade, so no second credential
  owner is created. Forget removes both credential formats. Optional APNs/Live Activity
  delivery remains a later thin-provider milestone.

Client verification evidence:

- Swift 6 complete-concurrency application and unit-test targets build for testing
  through `scripts/ios-build.sh` when the asset catalog is excluded.
- Focused tests cover additive provider/legacy payload parsing, Bearer-vs-legacy headers,
  single-flight refresh, terminal rotated-persistence failure, ticket refresh/freshness,
  and provider Keychain round-trip/preference/deletion.
- Runtime execution is still environment-blocked: CoreSimulator cannot initialize its
  device set (`ENOMEM`), and the connected physical iPhone test launch reached signed
  device preflight but required the locked phone to be unlocked. No raw `xcodebuild`
  invocation was used.

## H5 stock attachment authority result

- The existing composer and durable outbox now send normalized images directly through
  stock `image.attach_bytes`. The former plugin multipart `/upload` → `image.attach`
  write path, its iOS response model, and its REST client methods were removed.
- Arbitrary working files continue through stock `file.attach`; no plugin file store or
  second attachment registry is introduced. Base64 construction stays off the main actor,
  and Hermes returns the canonical gateway-local path used by prompt echo/reconciliation.
- Sent-image thumbnails preserve the full canonical path and read through authenticated
  stock `/api/media`. The plugin `/attachments/{name}` endpoint remains only as an
  explicitly read-only compatibility fallback for legacy transcript hints whose old
  upload paths are outside stock media roots; no new write can create that shape.
- The composer attachment affordance no longer depends on the plugin upload capability.
  Stock Hermes is the authority in both shared-token and provider-authenticated modes.
- Focused tests prove `image.attach_bytes` carries the expected session/base64 payload,
  clears the pending item only after Hermes returns a path, preserves full-path transcript
  hints, and decodes/queries stock media reads. The full Swift 6 test target builds for
  testing through the safe wrapper with asset compilation excluded.

## H6a stock working-file authority result

- The existing native file browser/viewer remains in place as bounded presentation UI,
  but all working-file reads now use stock Hermes routes: `/api/fs/list`,
  `/api/fs/read-text`, `/api/fs/read-data-url`, and `/api/git/file-diff`. The old mobile
  plugin `/fs/list`, `/fs/read`, and `/fs/diff` calls are gone; no replacement plugin
  file service or storage layer was introduced.
- Hermes runtime snapshots and `session.info` are the sole source of the active canonical
  cwd. `ConnectionStore` holds only the current, non-persisted presentation value and
  clears it at every session/transport boundary. A successful `session.cwd.set` applies
  Hermes' returned info immediately, with a post-await active-session fence so a late
  response cannot overwrite a newly selected session.
- The iOS REST adapter resolves its relative navigation paths under that canonical cwd,
  accepts absolute and `file://` tool-result paths only when they remain inside the cwd,
  and rejects traversal/cross-workspace paths before issuing a request. Hermes still owns
  authentication, path resolution, file contents, Git state, and every cwd mutation.
- Filesystem capability is independently probed through stock `/api/fs/default-cwd`.
  Plugin absence no longer hides native file browsing, and the capability-cache contract
  was revisioned so historical plugin-derived filesystem verdicts cannot survive the
  authority change.
- Focused URLProtocol/model tests cover stock desktop response adaptation, absolute query
  construction and `+` encoding, stock Git diff routing, missing cwd, traversal/outside
  rejection, absolute tool paths, `file://` paths, and filesystem capability independent
  of plugin availability. The complete Swift 6 app and unit-test targets build for testing
  through `scripts/ios-build.sh` with asset compilation excluded. Runtime execution remains
  subject to the previously recorded CoreSimulator `ENOMEM` host failure.
