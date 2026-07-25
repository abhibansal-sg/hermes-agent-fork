# Hermes Mobile release gaps — 2026-07-26

This note supersedes any older handoff that assumes the private S13
approval/clarification seam is installed in Hermes core.

## Fixed and physically proved

- New-chat send, reply, cache write, session switching, and force-close/reopen
  repaint passed on the iPhone Air against the stock gateway path.
- Project loading, active-turn pagination, and completion push navigation
  passed focused physical-device checks.
- Hermes core remains unmodified stock v0.19 at
  `8fc278207b0f5b25e567966f9615e1b1737f62af`.

## Known product gap

- A clarification notification can open its owning session, but after the app
  was killed or disconnected the clarification card cannot always be rebuilt.
  Stock v0.19 exposes neither a public pending-clarification snapshot nor a
  public resolver. The discarded S13 experiment supplied those private waiter
  details by patching core; it is intentionally not part of this release.
  Any future correction must stay in the Hermes Mobile plugin/relay/iOS edge
  and must not patch Hermes core.

## Release-head checks still required

- Re-prove remote Live Activity start/update/end on the TestFlight-signed build.
- Re-prove durable outbox delivery through an isolated gateway disconnect and
  reconnect.
- Re-run the clarification acceptance slice only after a stock-compatible edge
  contract exists; do not treat a simulator or mocked pending endpoint as
  proof.

These items are explicit follow-up gates, not reasons to add a second
transcript, replay engine, session registry, or custom gateway protocol.
