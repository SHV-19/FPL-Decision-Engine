# Release Readiness and Verification Boundaries

> **Status:** A description of an ongoing private development effort. This is **not** production certification, a hosted deployment guide, or an announcement of a fully released V5 build.

FPL Decision Engine has a curated public V4.1.2 source showcase alongside later private development. The repository intentionally excludes account credentials, personal account data and the complete private Windows runtime. Public source review and local operational acceptance are therefore **separate checks**.

## Evidence standard

- **Inspected source** establishes that a contract or implementation exists in a particular revision; it does not establish parity with a newer private build.
- **Recorded tests** establish results at a defined time and scope; they do not prove continuous reliability.
- **UI observations** establish that something appeared on screen, not that persistence, source parity, or legality were verified.
- **Open verification** identifies scenarios where repeatable acceptance evidence is still needed.

A healthy public feed does not prove that a private editable squad is authenticated or fresh. Historical team state and archived advice must never be promoted into current actionable guidance.

## Release gates

| Area | Minimum independently verifiable evidence |
| --- | --- |
| Current-team authority | Authenticated refresh of the current editable Official FPL squad, gameweek and 15-player integrity; fail-closed behavior when unavailable |
| Proposal legality | Valid and invalid cases for transfers, budget, club limits, 15-player uniqueness, XI, bench and captain/vice |
| Action and cost safety | No unintended Official FPL transactions; no queued paid inference silently resumed |
| Data provenance | Independent source timestamps; Official points distinguished from projected rank and other enrichment; honest stale/error labels |
| Gameweek transitions | Locked historic state and next editable state never confused |
| Leagues and research | By-type coverage counts, missing/stale reports, sample verification and attributed human evidence |
| AI lifecycle | Visible response **and** persistent terminal job status separately confirmed; costs and failures accounted for |
| Reliability | Restart, worker ownership, backup/rollback and sleep/resume checks against the installed build |
| Publication | Reviewed diff, safety scan, no personal or private runtime export, explicit approval to publish |

Every check needs a dated build, expected and actual results, a status and a sanitized evidence reference. An unexecuted case is **not tested**, not passed.

## Current limitations

- The public repository is a curated showcase, not a complete or ready-to-run mirror of later private work.
- Historical audits and UI demonstrations do not establish uninterrupted monitoring, universal feature coverage, prediction superiority or improved FPL rank.
- Authenticated editable-team access can expire. A later private recovery attempt failed and fresh independent verification is required before certifying current team authority.
- An experimental unattended Windows caretaker was not retained as an accepted feature of the core-only configuration.
- Model suggestions are advisory; the manager performs any Official FPL actions separately.
- Research events and planned calibration/outcome studies do not by themselves demonstrate causal improvement from AI assistance.

## Privacy, licensing and next steps

Only reviewed, non-sensitive documentation or curated source should be considered for public release. Keep tokens, private account state, rival identities, local logs, screenshots, research archives and deployment backups outside public GitHub. The repository's licensing decision and intended reuse permissions should be reviewed before describing it as a reusable open-source package.

For the published implementation contracts, see [Architecture](ARCHITECTURE.md), [Decision Engine](DECISION_ENGINE.md), [Privacy and Public Source](PRIVACY_AND_PUBLIC_SOURCE.md) and the [README](../README.md).
