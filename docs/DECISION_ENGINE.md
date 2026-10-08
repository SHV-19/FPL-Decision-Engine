# Decision Engine

## Prediction is not decision value

A strong player forecast does not establish that a transfer is beneficial.

The engine treats a Gameweek decision as:

```text
football evidence
+ actual squad state
+ transfer economics
+ future flexibility
+ uncertainty
+ competitive context
+ manager belief / evidence
→ structured proposal
→ deterministic legality gate
→ Exact Call / conditional route / block
```

That design exists because the highest-scoring candidate can still be the wrong move when the manager would need a hit, destroy a useful future transfer path, lose selling value, create a weak bench or chase short-term rank noise.

## Stage 1 — establish authoritative state

The system starts with canonical Official FPL player/team IDs and a fresh authenticated editable 15-player squad for an actionable call.

Locked picks, cached teams and screenshots can provide context, but they cannot authorize current ownership.

If the current-team authority cannot be refreshed, the system blocks an actionable Exact Call rather than pretending the last-known team is current.

## Stage 2 — build football evidence

For each relevant player the deeper context can include:

- form, Official EP and points per game;
- minutes, starts and availability;
- goals, assists, clean sheets, bonus and BPS;
- xG, xA, xGI and xGC;
- xG/90, xA/90 and xGI/90;
- influence, creativity, threat and ICT;
- ownership and transfer movement;
- price;
- six upcoming fixtures with venue and Official FPL difficulty.

The public implementation also uses a transparent candidate-discovery heuristic:

```text
2.0 × ep_next + 0.8 × form + 1.3 × xGI_per90
```

It is a shortlist score, **not projected points** and not the final recommendation.

## Stage 3 — compare realistic routes

A focused question remains focused. A full Gameweek question expands into realistic transfer, captain, bench and chip routes.

The engine can compare:

- HOLD vs transfer;
- one free transfer vs rolling;
- transfer vs hit;
- immediate upside vs multi-GW fixture value;
- safe captain vs differential captain;
- starting XI and bench-order alternatives;
- preserving flexibility vs consuming it;
- rank protection vs upside when competitive context was explicitly requested.

Unknown free transfers are treated as **unknown**, not silently converted to zero.

## Stage 4 — keep strategy separate from football quality

LiveFPL and rival intelligence can enrich the decision with projected rank, EO, overlap, captain divergence and nearby-rival context.

Those signals never replace football evidence. A template pick is not automatically good; a differential is not automatically smart; a rival action is not automatically worth copying.

## Stage 5 — structured proposal

For a full actionable request, the model returns a structured proposal containing:

- status;
- Gameweek;
- formation;
- transfers;
- starting XI;
- bench;
- captain;
- vice-captain;
- chip;
- confidence;
- conditions;
- summary.

Focused keep/sell or captain questions do not need to fabricate a full squad plan.

## Stage 6 — deterministic validation

Code validates the proposal against Official/current state.

Checks include:

- current squad must contain 15 players;
- every transfer-out must be owned;
- transfer-in cannot already be owned;
- transfer position must match transfer-out position;
- Official FPL is authoritative for incoming player club, position and price;
- budget against bank + selling prices when complete;
- 15 unique players after transfers;
- maximum three players per club;
- exactly 11 starters;
- legal formation: 1 GK, 3–5 DEF, 2–5 MID, 1–3 FWD;
- four-player bench with exactly one goalkeeper;
- outfield bench order 1/2/3;
- captain and vice must both start and must be different.

If a proposal fails, it is repaired once or blocked rather than shown as an executable call.

## Stage 7 — human execution

The engine does not autonomously edit the Official FPL team.

The manager sees the Exact Call, makes the actual action separately in Official FPL, and the research layer later reconciles observed team changes with the recorded decision trail.

## Stage 8 — review without rewriting history

Post-Gameweek review keeps original evidence separate from realized luck.

The intended chain is:

```text
evidence → belief → recommendation → response → Official action → outcome → evaluation
```

A good outcome does not prove a good process, and a bad outcome does not prove a bad process.

For the full signal and bias-research design, see [Prediction and Decision Signals](PREDICTION_AND_DECISION_SIGNALS.md).
