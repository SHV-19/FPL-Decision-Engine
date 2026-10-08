# Curated public-source release — 7 October 2026

The repository publishes a curated **V4.1.2 post-GW5 implementation subset**: 15 PowerShell automation modules, a Control Center HTML UI, and the public-source safety checker.

The source branch was reviewed in pull request #3, and the source-safety GitHub Action passed before it was merged into `main`. This is an auditable code showcase, not a turnkey local deployment.

## Deliberately excluded

Private configuration and access/refresh tokens; account/session state; personal screenshots; manager/rival snapshots; research events; gameweek archives and close receipts; migrations and backup packages.

## Release status and constraints

- **Implemented checkpoint:** V4.1.2
- **Next learning release:** V5 — not claimed complete
- **Curated source:** published to `src/automation`, `src/ui` and `scripts`
- **Automated security scans:** passed in PR #3
- **External usability:** requires private configuration, authenticated FPL and data-source access; no ready-to-run synthetic demonstration is provided
- **Branding:** product naming remains subject to final approval
