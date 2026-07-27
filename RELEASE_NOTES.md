# Hermes Mobile — Release Notes

## Build 135 — Lean Stock Data Wiring — 2026-07-27

### Improved

- Active transcript opening and “load earlier” now share one bounded stock-gateway read.
- Removed broad session prefetch and the remaining plugin-era transcript hydration paths.
- Project and cache results are fenced to the current gateway, profile, and request so stale responses cannot paint a newer connection.
- An empty cached project is now treated as loaded instead of spinning indefinitely.

### Worth testing

- Open a long session, switch away and back, then load earlier messages; confirm the same transcript remains stable.
- Switch gateways or profiles while projects are loading; confirm results from the former connection never appear.
- Open a project with no sessions; confirm it settles on an empty state rather than continuing to load.

## Build 133 — Notification Privacy — 2026-07-26

### Fixed

- Forgetting a gateway now removes the phone’s APNs token from the push registry before erasing its credentials, so an unpaired app no longer receives notifications.

### Worth testing

- Choose **Forget Gateway & Remove Local Data**, then trigger activity from the former gateway and confirm no notification reaches the unpaired phone.

## Build 113 — Mobile Foundation — 2026-07-16

### What’s new

- Offline-first sessions and transcripts with scope-safe caches, atomic manifest updates, cached content during sync, and offline search.
- A durable work pipeline for prompts, App Intents, Share-sheet jobs, drafts, and attachments that resumes safely after relaunch.
- Background manifest refresh, silent sync handling, and suspension-time state flushing.
- A durable approval inbox plus notification actions that work from cold launch, with APNs authority and duplicate suppression.
- App Lock safeguards, immediate app-switcher privacy shielding, and separate **Go Offline** and **Forget Gateway** controls.

### Improved

- Revision-safe widgets and semantic Live Activity updates.
- Richer chat rendering for Mermaid, SVG, inline images, URL embeds, alerts, and file diffs.
- More truthful iPad connection state, offline composer behavior, prompt-history recall, and provider-setting guards.

### Worth testing

- Queue a prompt, App Intent, or Share-sheet item; kill and relaunch the app; confirm it resumes once without duplication.
- Lock the phone during a running turn; verify completion/approval notifications arrive once and their actions open the correct session.
- Go offline, browse cached sessions/search, then reconnect and confirm content refreshes without disappearing.
- Use App Lock and the app switcher; confirm protected content is never exposed in snapshots.
