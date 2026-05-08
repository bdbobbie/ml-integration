# Step 4 Runtime Fleet Operations

This note describes how to operate and recover multi-VM queue orchestration in Runtime Fleet.

## Scope

Step 4 covers:

- Concurrency limits for running VMs.
- Queued starts when capacity is full.
- Queue ordering (`FIFO` / `LIFO`) and manual reorder controls.
- Retry/backoff for queued failures and max-attempt drop behavior.
- Queue telemetry, queue health summaries, and JSON export actions.
- Step 4 readiness gate used by planner auto-progress for `multi-vm-concurrency`.

## Runtime Fleet Controls

In the Runtime Fleet section:

- Set **Concurrency Limit** (`1`, `2`, `3`).
- Set **Queue Order** (`FIFO`, `LIFO`).
- Use **Run Queue Tick Now** to force immediate scheduler processing.

Per-VM row actions:

- `Queue Start`: enqueue a blocked VM start.
- `Retry Now`: clear cooldown for that queued VM and make it immediately eligible.
- `Move Up` / `Move Down`: manual queue priority override.
- `Remove from Queue`: drop one queued item.

Queue-wide recovery actions:

- `Reset Queue Retries`: reset retry counters and cooldowns for all queued items.
- `Clear Queue`: remove all queued items and retry/cooldown metadata.
- `Clear Queue Events`: clear queue telemetry history.

## Queue Observability

Runtime Fleet exposes:

- Concurrency capacity summary.
- Queue health summary (`ready`, `cooling down`, `retry history`).
- Scheduler status summary (`idle`, `waiting capacity`, `ready`, `waiting cooldown`).
- Next attempt summary and countdown.
- Recent queue event preview.

Export actions:

- `Copy Queue Events JSON`: recent queue event stream snapshot.
- `Copy Queue State JSON`: full queue state snapshot including order, retries, cooldowns, and active runtime IDs.

## Recovery Playbook

If queued starts are not progressing:

1. Check `Queue scheduler` status.
2. If blocked by capacity, stop one running VM or increase concurrency limit.
3. If blocked by cooldown, use `Retry Now` for one VM or `Reset Queue Retries` for all.
4. If queue order is wrong, use `Move Up` / `Move Down`.
5. Export `Queue State JSON` and `Queue Events JSON` for escalation/debug history.

## Step 4 Readiness Gate

Planner auto-completion for `multi-vm-concurrency` is driven by runtime gate evaluation:

- Gate source: `RuntimeWorkbenchViewModel.step4QueueReadiness()`.
- Gate result:
  - `READY`: marks delivery action complete.
  - `BLOCKED`: reports blockers (for example stale queue references or metadata inconsistencies).

This keeps milestone status tied to real orchestration state, not manual status-only toggles.
