# Public showcase status — 7 October 2026

## Verified project baseline

The private local FPL Decision Engine checkpoint is **V4.1.2 after Gameweek 5**. V5 normalization and evidence-driven learning are planned; do not describe them as shipped.

## Public GitHub status

This GitHub repository is **public** and contains its recruiter-facing README, architecture/case-study documentation, technical mapping, ethical AI-development disclosure, privacy boundaries, example configuration and CI safety workflow.

**The sanitized implementation source has been prepared separately but has not yet been transferred into this repository.** Public documentation is not a substitute for verifiable source code. Do not mark this as a fully published source release until the curated source files have been uploaded and inspected.

## What must remain private

Access/refresh tokens; cookies, local authentication state and API keys; private FPL/LiveFPL caches; identifiable mini-league and rival/manager histories; screenshots; research event logs; GW archives and close receipts; private participant profiles; backups, local absolute paths and generated logs.

## Release gate

1. Upload the curated implementation source (not the raw audit ZIP).
2. Review all changed files and run repository-wide privacy and secret scans.
3. Confirm GitHub Actions success on the final revision.
4. Add accurate About description/topics; verify documentation links.
5. Only then describe the repository as containing a complete public source showcase.
