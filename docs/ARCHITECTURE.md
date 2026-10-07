# Architecture

**Checkpoint:** V4.1.2 post-GW5, 2026/27 season.

The private implementation uses a local PowerShell orchestration/runtime and browser-based Control Center. Source-of-truth hierarchy:

1. Official FPL: public bootstrap/player and fixture data, locked picks and live points, authenticated editable current-team state.
2. LiveFPL: projected rank, effective ownership and live context enrichment.
3. Screenshots, opinions and hunches: attributed evidence, never ownership authority.
4. AI: analytical recommendations, with code enforcing legal Exact Calls.

## Decision pipeline

Actionable question → refresh authenticated current team → validate 15-player snapshot → construct scoped context → AI structured proposal → deterministic validations → Exact Call / repair / block.

Matchday score follows Official picks and Official event-live scoring, with a separate freshness clock for each source.

## Research pipeline

Interaction and evidence events are recorded in append-friendly JSONL; closed-GW receipts, Official history/picks and Deep Dive archives supply further context. Normalizing events to decisions and outcomes is planned V5 work. Old two-row decision ledger is not authoritative.

## Release boundaries

The curated public package excludes mutable account/auth config, access/refresh tokens, caches, raw research events, screenshots, rivals/managers, GW archives, close receipts and personal profiles. A public-code representation cannot be confused with a ready-to-run sample account.
