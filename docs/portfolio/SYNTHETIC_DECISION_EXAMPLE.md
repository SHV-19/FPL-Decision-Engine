# Two-minute decision walkthrough — synthetic inputs

> **Illustration only.** This is a deliberately invented FPL scenario designed to explain source authority and legality. It is **not** a replayed API call, production test, actual recommendation or evidence of rank improvement.

## The question

A manager asks: **“Should I replace a defender before the next gameweek, or keep the transfer?”**

The team has a valid 15-player squad, **one free transfer** and **£0.5m** in the bank. The defender proposed for sale has a **£5.0m selling price**. The AI identifies a promising **£6.0m defender** from Club A, but the current squad already owns three Club A players.

## How the decision engine should reason

| Stage | Evidence / check | Expected treatment |
|---|---|---|
| Football evidence | Availability, minutes, recent form, xGI and upcoming fixtures | Candidate may look attractive, but this does not authorize the move |
| Team authority | Confirm fresh authenticated editable 15-player current team | Block an actionable call if the private squad cannot be refreshed |
| Budget | £5.0m selling price + £0.5m bank = **£5.5m** versus £6.0m target | **£0.5m shortfall**; reject the proposed transfer |
| Club rule | Already three players from Club A | Adding a fourth without first removing another Club A player is illegal |
| Decision value | Compare HOLD, another legal replacement, or a multi-transfer route with any hit/option cost | Explain the trade-off; do not substitute raw player rank for decision quality |
| Recommendation | Structured model proposal → deterministic checks | Repair with a legal route once, or **block** |
| Execution | Manager chooses what to do on Official FPL | No automatic transactions |
| Research | Record pre-AI judgment, advice, actual behavior and later outcome where attributable | Treat it as evidence for future study, not a demonstrated causal effect |

**Takeaway:** Even an apparently promising player can be a bad *or impossible* transfer. Explaining the constraint matters as much as recommending the alternative.

## Demonstrating a second failure condition

Suppose the same scenario uses a cached 15-player snapshot after private authentication expired. Public player data might refresh normally, but that is **not enough** to assert present ownership, bank or free transfers. The correct actionable state is **blocked / requires reconnection**, not “proceed based on the last-known team.”

## What a reviewer can inspect

- [Historical public decision-rule description](../DECISION_ENGINE.md)
- [Curated PowerShell source for AI proposal validation](../../src/automation/Run-CopilotAI.ps1)
- [Architecture and trust boundaries](ARCHITECTURE_MAP.md)
- [Known release gates](../RELEASE_READINESS.md)

**What this example does not prove:** That the latest private runtime passed these checks in a fresh post-reconnect test, that the best alternative would improve rank, or that live predictions outperform another model.

## Why this example matters beyond FPL

The same design pattern appears in constrained planning and analytics applications: collect authoritative state, compare alternatives with evidence, reject infeasible actions, preserve human control, and evaluate decisions separately from noisy outcomes.