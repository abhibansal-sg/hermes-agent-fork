# Bot Mode stock gateway port (ABH-520)

## Contract

The iOS-only presentation from PR #279 is ported onto upstream 0.21.1.
The first commit preserves the original presentation for review; the second
replaces the obsolete fork RPC and capability with stock contracts.

- Roster and lookup: WebSocket `profiles.list {include_sessions:true}`.
- Require the existing REST-probed `ServerCapabilities.profiles == .available`
  AND `bot_mode_protocol:true` with `canonical_session` present on roster rows.
  Null means no canonical chat; absent means unsupported. WS contract state is
  reset on connection transitions, never persisted as a client session pointer.
- Existing canonical: open `resolved_id ?? id` through SessionStore with the
  owning profile. Existing watch/resume/drive behavior remains authoritative.
- Missing canonical: `session.create {profile, title:"Bot Chat", hidden:true,
  follow_profile_config:true}`, then `session.title {session_id:<runtime>,
  title:"Bot Chat"}`. Only after eager persistence is the stored ID opened.
- Title error containing `already in use` (case-insensitive): re-list and adopt
  that profile's winner, including its compression tip. Abandon the stray.
- Other errors, deferred persistence, or a missing winner fail closed. No
  compatibility kickoff prompt is sent: the stock contract persists the row,
  and the user speaks first. No REST/global model mutation is involved.
- `session.watch` / `session_watch_v1` are retained, with PR #279's profile
  threading. No core, desktop, CLI, or plugin modifications were necessary.

Pure canonical resolution and conflict decisions live in
`Models/BotChatResolution.swift`. BotModeStoreTests cover optional/absent/null
wire fields, compression tips, missing profiles/winners, local session routing,
and a scripted WebSocket creation/conflict flow asserting the exact RPC order
and parameters. ProtocolParityTests cover the REST + WS capability conjunction.

## Local verification

- `swiftc -parse`: PASS on all 14 changed Swift files.
- `xcodegen generate`: PASS; generated project delta adds only the new model's
  four registrations beyond the raw presentation port.
- `plutil -lint HermesMobile.xcodeproj/project.pbxproj`: OK.
- `git diff --check`: PASS; tracked conflict-marker scan: none.
- Generic-device build through `scripts/ios-build.sh`, `generic/platform=iOS`,
  `CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED**, wrapper rc=0.
- One focused simulator attempt, iPhone 17 Pro Max, BotModeStoreTests and
  ProtocolParityTests, parallel testing disabled: app and tests compiled, no
  Swift compiler errors. Runner launch stalled; after roughly nine minutes the
  owned xcodebuild was terminated with SIGTERM (no service resets or retries).
  Actual launch diagnostic: `Error Domain=NSMachErrorDomain Code=-308
  "(ipc/mig) server died"`; final banner `BUILD INTERRUPTED`, wrapper rc=143.
- `xcrun xcresulttool get test-results summary --path
  /private/tmp/HermesMobile-botmode.xcresult` could not read a summary:
  `Info.plist ... does not exist`. This is an aborted run, NOT passing tests.

Full local logs are retained (untracked/ignored) under
`apps/ios/.derivedData/botmode-device-build.log` and
`apps/ios/.derivedData/botmode-simulator-tests.log`.

Pending: GitHub's iOS focused unit tests is the execution verdict; no local
XCTest pass count or physical-device/UI acceptance is claimed. No push performed.
