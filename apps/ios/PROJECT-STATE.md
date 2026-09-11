# Hermes Mobile — project state

Single source of truth for "where is this project right now." Update on every
consolidation, ship, or gateway cutover. Historical narrative lives in git; this file
carries only current facts.

_Last reconciled: 2026-09-10 (post-Codex consolidation)._

## Where things live

| Thing | Location | Status |
|---|---|---|
| Canonical repo | `github.com/abhibansal-sg/hermes-agent-fork`, branch `main` | **The one home.** Stock NousResearch upstream + `apps/ios/` overlay + thin gateway providers (Option C). |
| Local checkout | `/Volumes/MainData/Developer/products/hermes-mobile` | Tracks fork `main`. No other clones or worktree colonies remain. |
| Standalone split | `github.com/abhibansal-sg/hermes-mobile` | **ARCHIVED 2026-09-10** — frozen at build 144, never received 145–150. |
| Ship pipeline | `/Volumes/MainData/Developer/products/hermes-loop` (`.loop-env` → `LOOP_TARGET_REPO` = this checkout) | Xcode Cloud workflow `779B7830 "Default"` is still bound to the ARCHIVED repo — needs repoint (UI-only action) before the next cloud ship. Local archive path (`SHIP-TESTFLIGHT.md`) works regardless. |
| Phone build | TestFlight **150** (2026-08-10, VALID) | Last shipped. `project.yml` `CURRENT_PROJECT_VERSION: 150`; next ship = 151. |
| Phone gateway | `:9119`, launchd `ai.hermes.dashboard`, checkout `/Volumes/MainData/Runtime/Hermes/hermes-agent` | **Pure stock NousResearch `main` 0.21.1**. Mobile plugin NOT enabled. |
| Prepared-but-undeployed gateway | `/Volumes/MainData/Runtime/Hermes/releases/hermes-agent-6851841112-mobile` (branch `archive/local/production-20260820-6851841112`) | Hermes 0.20.4 + the fork's H1/H2/H3 `tui_gateway` contracts (session watch / prompt admission / action authority). Never cut over. |
| Tracker | Linear team **ABH** | 37 open at reconciliation; see "Open loops". |
| Cleanup archive | `/Volumes/MainData/AgentTools/hermes-mobile-consolidation-20260910/` | Manifests of every branch/worktree/stash deleted on 09-10, `unique-branches.bundle` (528 branches with unpushed commits), dirty-worktree diffs, 15 stash patches. Recoverable by SHA. |

## Fork ↔ upstream drift (at reconciliation)

- Fork `main` `b12bb07f8b` = upstream `326bdfb7a2` (2026-08-09) + 681 fork commits.
- Upstream `main` is 11,758 commits ahead (0.20.x → 0.21.1). Production gateway already runs 0.21.1.
- Core patch surface on fork main vs its merge-base: **1,032 lines** across `tui_gateway/` (server.py +622, prompt_admission.py +115, methods_session.py +46, …), `hermes_cli/web_server.py` (+82), dashboard-auth. None of it is deployed.

## Open loops

1. **PR #279 Bot Mode** (`codex/abh-520-ios-bot-mode`, ABH-520/521/522/523). 2,951 files because it bundles an upstream convergence merge to `b4f978d983` (0.20.4). Only **5 fork-authored commits** matter (`64148e087b`, `a0475908e0`, `f6de0cf001`, `239e30d547`, `d74089b77d`). CI: iOS focused unit tests **FAIL** — but the same lane has failed on every branch since build 148 (`SessionRefreshTests.testFirstPairPaintsSmallCreatedSliceBeforeAuthoritativeRecentSnapshot` + 2 file-sandbox error-mapping tests), so it is a pre-existing red, not PR-specific. Device execution never happened (Xcode couldn't mount the DDI). **Decision pending**: split the 5 commits onto a fresh branch off a rebased main, or shelve.
2. **PR #266 `manage-execution`** (07-29) — stale, out-of-scope core seam. Close candidate.
3. **Rebase fork `main` onto upstream 0.21.1** so the seam ledger matches what production runs; then decide H1/H2/H3: deploy the prepared 0.20.4-mobile release (stale) / re-port onto 0.21.1 / drop.
4. **iOS CI is red on main** (see #1). Must be green before any merge claims.
5. **Device P0/P1s never re-verified on build 150**: ABH-514, 515, 516, 518 (filed 07-21, relay-era; relay transport is deleted — may be moot), ABH-504/506/508 (build 120 era).
6. **Xcode Cloud repoint** (operator UI action) — or keep shipping via the local archive path.
7. 8 Linear issues "In Progress" with no activity since 08-20 or earlier.

## Laws that still hold

- Gateway stays **strictly stock**; product changes live in `apps/ios/`, `plugins/hermes-mobile/`, `server/push-relay/`, and the seam files listed in `CONTRACT-DEPATCH.md` only.
- A `ship: TestFlight build N` commit is not proof build N exists — verify against ASC.
- "Merged to main" ≠ "on the phone" ≠ "on the gateway". Report all three separately.
