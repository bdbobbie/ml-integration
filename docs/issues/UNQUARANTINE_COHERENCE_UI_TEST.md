# Tracking Issue: Unquarantine Coherence Warning UI Test

## Title
Unquarantine `ML_IntegrationUITests.testCoherenceSchemaWarningAndRepairActionVisibility`

## Problem Statement
`testCoherenceSchemaWarningAndRepairActionVisibility` is intermittently failing with UI snapshot timeouts (`main run loop busy`) in UI automation sessions. The test is currently quarantined for release continuity.

## Current Workaround
- CI skips this test via:
  - `.github/workflows/swift.yml`
  - `-skip-testing:"ML IntegrationUITests/ML_IntegrationUITests/testCoherenceSchemaWarningAndRepairActionVisibility"`

## Owner
- UI Automation / Runtime Integration

## Target
- Remove quarantine before next milestone cut.

## Repro Context
- Typical signal in logs:
  - `Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s`

## Acceptance Criteria
1. Test passes 10/10 consecutive runs locally.
2. Test passes 10/10 consecutive runs in CI.
3. No reliance on ad-hoc sleeps; synchronization uses deterministic UI markers.
4. CI `-skip-testing` entry removed and UI suite remains green.

## Verification Commands
```bash
cd "/Users/tbdoadmin/ML Integration"
for i in 1 2 3 4 5 6 7 8 9 10; do
  xcodebuild -project "ML Integration.xcodeproj" \
    -scheme "ML Integration" \
    -testPlan "ML Integration" \
    -destination "platform=macOS" \
    -only-testing:"ML IntegrationUITests/ML_IntegrationUITests/testCoherenceSchemaWarningAndRepairActionVisibility" \
    test || break
done
```
