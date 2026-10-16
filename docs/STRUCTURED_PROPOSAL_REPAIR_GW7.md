# Structured FPL Proposal: GW7 Failure Analysis and Regression Scope

> **Source scope:** A proposed fix against this public repository's curated historical V4.1.2 PowerShell implementation. It is **not** confirmation that the private, newer Windows build was updated or tested. Do not include personal FPL team details or raw paid API responses in public bug reports.

## Observed class of failure (sanitized)

A full-team model response failed structured JSON parsing and a one-attempt repair failed deterministic validation. The error categories were:

1. Incomplete/malformed structured output.
2. Incoming player not uniquely resolved against Official FPL.
3. Transfer cost above verified bank plus actual selling proceeds.
4. More than three players from one Official FPL club.

**Correct engine behavior:** No actionable Exact Call is published when any of these checks fail. A confidently worded model suggestion does **not** override the validator.

## Fixes proposed here

- Increase output allowance for the 15-player structured proposal and one optional repair; a short response budget can truncate otherwise useful JSON.
- Preserve actual Official-account **selling prices** and fail closed if bank, selling proceeds or canonical incoming prices are missing. Current market prices may overstate sale proceeds.
- Resolve each incoming player against Official FPL; do not trust model-provided club or price if the official universe is unavailable or ambiguous.
- Give the repair call a compact list of current squad identities and selling prices, verified bank, and Official FPL candidates with canonical names, clubs and prices. Prefer a legal HOLD over inventing an incoming player.
- Do not invoke paid repair if the authenticated team snapshot changed; check the snapshot again after a successful repair.

## What has NOT been established

- A fresh live authenticated squad, successful GW7 transfer recommendation or cross-version parity.
- A reliable player-ID-first schema for the private app; this public fix still uses exact canonical name matching plus deterministic identity rejection.
- Improved model accuracy, calibrated confidence or better FPL rank.
- End-to-end integration testing of the complete private application and every API response status.

## Reproducible regression checks

Run from repository root on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_proposal_gate.ps1
```

The synthetic-only checks import the isolated validation functions without starting any API worker and cover:

1. Valid hold.
2. Valid affordable transfer.
3. Insufficient budget.
4. Missing bank.
5. Unknown selling price.
6. Four players from one club.
7. Unknown incoming player.
8. Missing Official FPL player data.
9. Duplicate player in starting XI and bench.
10. Malformed structured JSON.

A separate **private runtime acceptance** is still required for snapshot drift during API calls, complete model output, repair token usage, UI status/terminal persistence and source freshness. Preserve a sanitized test receipt; never publish auth secrets, manager identifiers, screenshots or raw personal logs.

## Integration acceptance in the private Windows build

Before promoting this patch: compare the private source against the archived public function contracts, port only compatible changes, run the synthetic tests, then use **synthetic fixtures** to simulate team mutation before and after repair. Recheck the full legal squad and economic ledger after every repaired proposal. Only then run a fresh authorized account test with explicit user consent to incur inference costs. No Official FPL transaction should be automated.
