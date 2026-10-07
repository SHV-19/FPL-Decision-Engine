# Technical blueprint

## Runtime and stack

The inspected checkpoint is a local-first Windows application primarily orchestrated with **PowerShell**, presenting a browser-based Control Center UI built with HTML/JavaScript. It consumes Official FPL APIs, authenticated current-team state, LiveFPL enrichment and a model-powered Deep Dive layer. JSON/JSONL and snapshots support current context and longitudinal research.

Do not assume Python-based forecasting, a hosted backend, training pipeline or production cloud deployment simply because the public presentation uses terms such as analytics and AI.

## Core modules and lifecycle

| Layer | Responsibility |
| --- | --- |
| Official ingestion | Public FPL bootstrap, fixtures, picks and event-live observations |
| Private team authority | Authenticated editable current team, renewal and canonical 15-player snapshot |
| Live enrichment | Projected/live-rank and effective-ownership signals from LiveFPL |
| Research | Evidence provenance, screenshots, observations, append-friendly event records |
| Deep Dive | Proportional reasoning context, structured AI recommendation |
| Exact Call validation | Squad legality, transfers, budget, club constraints, XI/bench/captain correctness |
| Matchday | Official locked picks × event-live points minus official transfer cost |
| Gameweek close | Preserve history and receipts to support review |
| UI | Control Center views for decisions, scores, leagues and observatory |

## Trust boundaries

Public data freshness does not imply authenticated editable-squad freshness. A historical locked squad or screenshot cannot replace current ownership authority. LLM fixture strings do not replace Official fixture IDs. A model can recommend a transfer; it cannot directly edit Official FPL through this application.

## Operational caution

The uploaded private archive included extensive sensitive account and competitor data. The public project must be a **curated code showcase**, not a deployable export of another person's FPL account state.

## Evaluation

Automated event capture does not itself establish causal learning. Post-GW5 normalization, replay, denominators and confidence-calibration evaluation remain future work.
