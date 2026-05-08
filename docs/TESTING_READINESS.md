# ML Integration Testing Readiness

## 1) v0 Scope Freeze
In scope for v0 test environment:
- Host detection
- Official distro catalog refresh
- Download/checksum/signature workflow
- VM install scaffold pipeline
- Shared resources and launcher package generation
- Health and auto-heal package regeneration
- Uninstall, cleanup, and receipt verification
- Developer escalation (GitHub issue and email draft)

Out of scope for v0:
- Full production-grade Linux app window coherence
- Fully unattended install completion across every distro/version
- Cross-host migration

## 2) Repository and Release Plumbing
Required:
- GitHub remote configured
- CI checks on push and pull requests
- Issue templates for defect and feature intake

## 3) Deterministic Test Mode
Required behavior:
- Runtime paths can be redirected to isolated test roots
- No destructive operations outside designated test root
- Ability to run with fixture feeds in future iteration

## 4) Installer Lifecycle Coverage
Minimum lifecycle states:
- `idle -> validating -> scaffolding -> ready`
- Any failure transitions to `failed` with reason

## 5) Security and Credentials
Minimum test requirements:
- Keychain token load/save/clear works
- Diagnostics do not include secrets
- Signature checks fail cleanly when keyring is missing

## 6) Initial Test Matrix
Hosts:
- Apple Silicon macOS
- Intel macOS

Distros:
- Ubuntu
- Fedora
- Debian

Runtimes:
- Apple Virtualization.framework
- QEMU fallback

## 7) Automated Test Expectations
Must pass before environment runs:
- Registry restore/reconcile tests
- Cleanup/no-trace tests
- Token persistence tests
- UI smoke tests

### Step 4 Queue UI Deferment Note
- Date recorded: May 8, 2026.
- Decision: Step 4 queue control XCUI automation is deferred.
- Reason: current local runner has recurring xcodebuild/simulator permission/launch instability, causing flaky and non-actionable UI results.
- Current coverage: Step 4 runtime fleet queue behavior is covered by unit and end-to-end integration tests in `ML_IntegrationTests`.
- Exit criteria to remove deferment:
  - stable UI runner in local/CI
  - add one focused Step 4 queue XCUI flow (`Queue Start` + queue state transition assertions)

## 8) Observability
Per run logs should include:
- Correlation ID
- VM ID
- Stage
- Result
- Timestamp

## 9) Environment Prerequisites
- Virtualization support on host
- Sufficient disk and memory
- Network access for distro feeds (or fixtures)
- Required keyrings imported for signature enforcement

## 10) Entry Criteria (Go/No-Go)
Go when all are true:
- Build passes
- Tests pass
- No blocker-severity open issues
- Matrix hosts/fixtures are ready
- Rollback/cleanup validation completed

## 11) Step 5 Automation Progress
- See `docs/STEP5_AUTOMATION_PROGRESS_GUIDE.md` for:
  - signal-to-status mapping for `ci-stability` and `e2e-runtime-tests`
  - Step 5 readiness gate interpretation
  - validation workflow and coverage references
