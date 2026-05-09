# Known UI Test Deferments

## Current Release

- Test: `ML_IntegrationUITests.testCoherenceSchemaWarningAndRepairActionVisibility`
- Status: Quarantined (non-blocking for this release)
- Scope: CI/UI test workflow only; core unit tests and focused Step 6 UI smokes remain required.
- Failure signature: UI snapshot timeout with main run loop busy (intermittent).
- Mitigation in place:
  - CI skips this one test in `.github/workflows/swift.yml`.
  - Release handoff note is visible in-app under Step 6.

## Exit Criteria to Unquarantine

1. Test passes 10/10 consecutive local runs.
2. Test passes 10/10 consecutive CI runs.
3. No new UI runtime warnings are introduced by the fix.
4. Remove the `-skip-testing` entry from CI and re-validate full UI suite.
