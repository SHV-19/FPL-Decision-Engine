# Building FPL Decision Engine — honest interview handbook

## 45-second build story

“I started with a decision problem: the best projected player may not be the best move for a specific team. I designed a local-first application that brings together authoritative FPL squad state, football metrics, fixtures, transfer economics, rank/EO context and manager judgment. AI generates structured options; deterministic constraints validate proposed transfers and lineups. I used AI-assisted development to accelerate PowerShell and UI iteration, while leading requirements, source-trust rules, workflow design, debugging, acceptance evidence and product trade-offs.”

## Questions to prepare for

**What is the backend?** A local PowerShell HTTP and orchestration layer, source-specific scripts and file-backed JSON/JSONL state; browser HTML/JavaScript front end. An auxiliary Python event console is a separate monitoring surface, not a cloud backend.

**Did you train a points predictor?** No proprietary trained model has been verified here. Official expected-points and underlying signals inform comparisons; a documented deterministic heuristic shortlists candidates, but is not projected points.

**Why use AI plus deterministic code?** A model can reason about trade-offs but can invent player ownership, budgets or formations. Hard-coded validation prevents free-form text from authorizing an impossible transfer.

**What does EO mean?** Effective ownership — contextual competitive exposure including captaincy. It is not football ability.

**What is provenance?** Source identity, authority and timing, so official points cannot silently be conflated with projected rank or a screenshot.

**What happens if authentication expires?** Current actionable Exact Calls must fail closed. Cached historic squad remains historical.

**What parts did you personally lead?** Requirements, analytics framing, data/source contracts, system behavior, user-facing workflow, testing criteria, iteration decisions and public/private release boundaries. AI-assisted code drafting is openly acknowledged.

**Has it increased rank?** Not demonstrated. Decision-event recording and short history do not prove a causal effect.

**What remains untested?** Fresh post-reconnect authentication, some transaction/cost edge cases, terminal AI-job persistence, long-running restart/sleep and full league-type coverage.

## Mini glossary

- **API**: machine-readable data exchange; **endpoint**: a particular API route.
- **Cache**: locally saved copy; freshness requires its own clock.
- **JSON/JSONL**: structured data / append-friendly event records.
- **OIDC**: authentication architecture used for private account access.
- **Heuristic**: practical ranking shortcut; not a calibrated predictive model.
- **Deterministic rule**: explicit check with the same result for the same verified inputs.
- **Calibration**: how well confidence reflects observed frequencies.
- **Fail closed**: deny actionable advice when a necessary trust condition fails.

See [Building With AI](../BUILDING_WITH_AI.md).