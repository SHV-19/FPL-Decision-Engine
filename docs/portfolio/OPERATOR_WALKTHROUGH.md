# Control Center — safe operator and demonstration guide

This is a **feature-level walkthrough** of the historically reviewed local app, not a claim that your private current squad is authenticated today.

## Safe startup

Use the tested launcher shipped with your local Windows installation. Confirm one Control Center instance, source-by-source status and correct gameweek. The private launcher, credentials and local paths are intentionally not replicated in this public repository.

## Feature tour

| View | What to show | What to say |
|---|---|---|
| Home | Official points/rank context and bank/FT where authenticated | “This is the manager context, not a standalone points table.” |
| Team | Canonical 15, XI, bench and captain/vice | “Current advice is blocked without fresh Official editable team authority.” |
| Live | Official event-live score separate from projected rank/EO | “LiveFPL is enrichment, not Official scoring.” |
| Leagues | Membership coverage, rank, movements and rivals | “Coverage has numeric boundaries and may be partial.” |
| Decision Studio | Transfer/HOLD, captain, XI, chips and validated suggestions | “AI proposes; hard-coded FPL rules gate legality.” |
| Research | Stated prior opinion, observations, advice and archives | “This is a foundation for evaluation; not causal proof yet.” |
| Advanced | Source freshness, reauthentication, AI-cost controls | “Controls and secrets remain local.” |

## Suggested demonstration (no private information)

Narrate a **synthetic** manager with one free transfer and an injured defender. Compare HOLD against a replacement whose football metrics look strong but whose price or club combination makes the transfer impossible. The explanation is useful even without a working authenticated private session.

## Troubleshooting by interpretation

- `AUTH_REJECTED_OR_EXPIRED`, `AUTH_REQUIRED` or `SQUAD_STALE`: reconnect in the private local app; do not promote last-known team into a current action.
- GW mismatch: distinguish locked historical gameweek from next editable one.
- Rank differs from score: check Official points versus LiveFPL projected rank and separate timestamps.
- Old AI advice: it is historical, never an automatic current recommendation.
- Pending paid AI job: do not relaunch or auto-resume without explicit consent.
- Missing league results: report counts, types and ages, not “all green.”

No automatic Official FPL transfers/chips are claimed. Actual account changes are human actions on the Official FPL website.

See [Architecture](ARCHITECTURE_MAP.md) and [Release readiness](../RELEASE_READINESS.md).