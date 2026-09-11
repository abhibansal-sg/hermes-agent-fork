# Focused lane repair — execution blocked locally

Base: `593c265ec8`, branch `fix/ios-focused-lane-red`. No production changes or skip-list changes.

## Root causes

- `SessionRefreshTests.testFirstPairPaintsSmallCreatedSliceBeforeAuthoritativeRecentSnapshot`: stale fixture after `2764511ec4fce573897f81155969fae70de7d006` (2026-08-11). Production correctly caps the stock `/api/sessions` request at 100, while the stub demanded the aggregate/native window of 200 and returned `URLError.badURL`. The provisional `quick` row then survives a failed refresh. Keep the two-phase paint assertions, require successful refresh outcome, and make the stock fixture demand 100.
- `FileSystemModelTests.testMapFSErrorEscape403`: stale plugin contract after `d80db9a1640daf946cf9dc19fcb5c9673b04bbcd` (2026-08-09). Stock path-based routes map HTTP 403 to an unreadable-file error. Renamed to `testMapFSErrorStock403IsUnreadable`, covering stock and legacy bodies. Existing local traversal rejection tests remain.
- `FileSystemModelTests.testMapFSErrorUnknownSession404IsNoActiveSession`: same migration/root cause. Stock file requests carry no session ID, so HTTP 404 is a path miss. Renamed to `testMapFSErrorStock404DoesNotInferSessionStateFromBody`, covering stock and legacy bodies. Missing canonical cwd still produces `noActiveSession` locally before a network request; the existing test for that remains.

History correction: the session-limit divergence is dated August 11, not August 10. The reported common build-148 onset does not establish the introduction date of all three failures.

## CI parity

Read `.github/workflows/ios-tests.yml` and its introduction in `f5052226fd`. Its only skips are two ClarifyCardNativeTests methods and NativeChromeSnapshotEvidenceTests. The complete history of `scripts/ios-build.sh` contains no `skip-testing` entries. Neither file was modified.

Ran `(cd apps/ios && xcodegen generate)`; generated project unchanged. No files were added to Xcode targets.

All invocations below ran from this worktree, with signing enabled and this environment prefix:

```sh
env -u HERMES_URL -u HERMES_TOKEN \
  -u TEST_RUNNER_HERMES_URL -u TEST_RUNNER_HERMES_TOKEN \
  HERMES_NO_DEV_GATEWAY_AUTOPROVISION=1 \
  HERMES_BUILD_TIMEOUT=2700 HERMES_BUILD_LOG=<log> \
  scripts/ios-build.sh <action> -scheme HermesMobile \
  -destination '<destination>' \
  -only-testing:HermesMobileTests/SessionRefreshTests \
  -only-testing:HermesMobileTests/FileSystemModelTests \
  -parallel-testing-enabled NO -retry-tests-on-failure \
  -resultBundlePath <bundle>
```

The three failing methods belong to **two**, not three, classes.

Actual run matrix (`/private/tmp/HermesMobile-ci-<suffix>.log` and `.xcresult`):

| suffix | action | destination | result |
|---|---|---|---|
| baseline | test | platform=iOS Simulator,name=iPhone 17 Pro Max | Asset compilation failed; zero tests |
| baseline-retry | test | same | Same asset compilation error |
| baseline-263 | test | platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.3.1 | Same error; actool still requested iOS 26.5 |
| baseline-reset | test | platform=iOS Simulator,name=iPhone 17 Pro Max | Build/signing completed; runner launch hung, then failed after simulator shutdown |
| baseline-erased | test-without-building | same | Runner launch hung on erased device, then failed after simulator shutdown; timeout prefix was 1200 |

No iPhone 16 was selected: available iPhone 17 Pro Max used instead. No OS pin on final two attempts; resolved to iOS 26.5.

Initial actool error: `Failed to find a suitable device for the type IBSimDeviceTypeiPad3x` with `Failed to initialize simulator device set`, `NSPOSIXErrorDomain 12 Cannot allocate memory`. Found the existing IB Support/Simulator Devices symlink pointed to missing `/private/tmp/gate-ib-devices`; recreated only that temporary destination. Per orchestrator direction, reset CoreSimulatorService once:

```sh
xcrun simctl shutdown all
killall -9 com.apple.CoreSimulator.CoreSimulatorService
sleep 5
xcrun simctl list devices >/dev/null
```

Asset compilation passed after reset. No xcodebuild process was force-killed. The baseline-reset executable was built before test edits. Sampling xcodebuild showed a wait in `SimDevice.launchApplicationWithID`/`host_support_mig_launch_app`, not test execution. Shut down all sims, waited for xcodebuild to exit, read xcresult, erased `89B9FC5E-1D0C-4F2C-9982-1825B2C7FD5D`, then ran test-without-building. After another no-event launch stall, shut down sims and stopped retries as directed.

## Observed evidence and limits

`xcrun swiftc -parse apps/ios/HermesMobileTests/SessionRefreshTests.swift apps/ios/HermesMobileTests/FileSystemModelTests.swift` and `git diff --check` pass. These are syntax/diff checks, **not passing unit tests**.

`xcrun xcresulttool get test-results summary --path /private/tmp/HermesMobile-ci-baseline-erased.xcresult`:

- totalTestCount: 1
- passedTests: 0
- failedTests: 1
- skippedTests: 0
- only failure: synthetic `HermesMobile encountered an error`, `Failed to install or launch the test runner. (Underlying Error: Invalid device state. (Underlying Error: ... Mach error -308 ... server died))`.

This is an infrastructure failure, not a failed test method. No method-level baseline or post-fix result was obtained. **Full target was not run**, and the repaired lane is NOT verified green. `/private/tmp/HermesMobile-ci-fix.xcresult` preserves a copy of this final blocked focused attempt, NOT a full-target success bundle.

## Required completion on a healthy simulator

First rerun the focused `test` command above to compile the edits. Then execute the full workflow command through the wrapper, with the same unset credential prefix, timeout 2700 and signing enabled:

```sh
scripts/ios-build.sh test -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:HermesMobileTests \
  -skip-testing:HermesMobileTests/ClarifyCardNativeTests/testApprovalCardMountsNativeSurfaceAndActions \
  -skip-testing:HermesMobileTests/ClarifyCardNativeTests/testLongChoiceWrapsInsideCardWidth \
  -skip-testing:HermesMobileTests/NativeChromeSnapshotEvidenceTests \
  -parallel-testing-enabled NO -retry-tests-on-failure \
  -resultBundlePath /private/tmp/HermesMobile-ci-full-verified.xcresult
```

Read the xcresult summary; reconcile method failures rather than assertion counts. Replace the preserved ci-fix bundle only after moving the blocked evidence aside. Do not push these commits until the missing verification is acknowledged by the orchestrator.
