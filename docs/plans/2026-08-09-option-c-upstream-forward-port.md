# Option C upstream-first forward-port ledger

Status: implementation gate P-1

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
| Plugin capability bundle detection | Individually versioned stock capabilities (`session_watch_v1`, `session_action_auth_v1`, `prompt_receipt_admission_v1`, `session_files_v1`) |
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
