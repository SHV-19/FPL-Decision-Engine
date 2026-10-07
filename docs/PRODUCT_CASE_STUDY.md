# Product case study — FPL Decision Engine

## Problem

Fantasy Premier League decisions are multi-objective: expected points are important, but so are existing squad ownership, transfers, transfer hits, bank balance, future fixtures, risk, effective ownership, league position and uncertainty. A player ranking alone cannot choose between holding a current asset, paying a hit, protecting league position or chasing upside.

## Product approach

The product aims to make the user journey **ask → decide → act → sync → learn**. It connects Official FPL as the authoritative data source, supplements it with LiveFPL rank/EO context, accepts human reasoning and external evidence as attributed inputs, and uses AI to propose a structured response. Deterministic code validates legal game actions before showing an actionable Exact Call.

## Engineering decisions and failures

The project was shaped by failures rather than only feature requests:

- Cached or screenshot-derived squads once risked being mistaken for the current team. An actionable Exact Call now requires refreshed, authenticated Official FPL ownership.
- AI sometimes produced illegal starting elevens or self-contradictory lineup prose. Structured proposals and deterministic squad/formation/bench checks are required.
- Delayed entry summary points were mistaken for live event points. The matchday score contract uses Official event-live player points from locked picks, with LiveFPL reserved for enrichment.
- Keyword-based question routing could trigger expensive unrelated league analysis. The newer routing separates focused questions from full-squad and strategic work.
- Research dashboards could look more authoritative than the sample deserved. The next release must report coverage and maturity, not hollow zero charts or invented conclusions.

## Human–AI evaluation

The research chain captures evidence, participant belief, model advice, user response, actual Official action and outcome where events can be reconstructed. The distinction between ex-ante decision quality and realized luck is essential. Human behavior after AI advice cannot be treated as an untouched human baseline.

## Honest project status

The installed checkpoint is V4.1.2 after GW5 of 2026/27. Five GWs provide a first small longitudinal research sample, not proof of an adaptive optimal policy. Full decision/outcome normalization is V5 work, not an achieved result.

## Ownership

Built through AI-assisted development. Human ownership covers research questions, requirements, workflow design, decision logic, source contracts, QA, failure analysis, methodology and release strategy.
