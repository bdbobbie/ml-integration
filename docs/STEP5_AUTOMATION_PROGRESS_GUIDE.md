# Step 5 Automation Progress Guide

This guide documents how Step 5 delivery actions progress and how to validate them.

## Step 5 Scope

Step 5 covers automation confidence and runtime end-to-end verification readiness:

- `ci-stability`
- `e2e-runtime-tests`

These actions are auto-progressed by planner/runtime readiness signals instead of manual-only status updates.

## Source Signals

Step 5 status is derived from:

- `plannerReady`: planner readiness gate (`isReadyForEnvironmentTesting`).
- `phaseSweepReady`: runtime phase sweep gate.
- `step4QueueReady`: Step 4 runtime queue readiness gate.
- `automationPassing`: readiness criterion `automation-passing`.

## Progression Rules

### `ci-stability`

- `pending` when planner is not ready.
- `inProgress` when planner is ready but automation is not yet passing.
- `complete` when `automationPassing == true`.

### `e2e-runtime-tests`

- `pending` when planner is not ready.
- `inProgress` when planner is ready but full runtime/automation gates are not all satisfied.
- `complete` only when all are true:
  - `automationPassing`
  - `phaseSweepReady`
  - `step4QueueReady`

## Step 5 Readiness Gate

Planner exposes a Step 5 readiness model with:

- `isReady`
- `blockers`
- `summary`

UI shows this summary and blocker preview in the Delivery Actions panel.

## Validation Workflow

1. Confirm planner readiness criteria are synchronized.
2. Confirm Step 4 queue readiness is `READY`.
3. Confirm phase sweep gate is ready.
4. Confirm automation passing criterion is true.
5. Verify delivery action statuses:
   - `ci-stability` -> `complete`
   - `e2e-runtime-tests` -> `complete`

## Test Coverage

Step 5 has dedicated automated coverage in `ML_IntegrationTests`, including:

- readiness gate tests for ready/blocked states
- consolidated progression integration test across signal transitions
- delivery action completion assertions for CI and E2E items
