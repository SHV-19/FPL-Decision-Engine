# Prediction and Decision Signals

The FPL Decision Engine does **not** reduce the problem to one black-box projected-points number.

Its design separates three things that are easy to blur together:

1. **player evidence** — what the available football/FPL data says about a player;
2. **candidate discovery** — which alternatives deserve comparison;
3. **decision value** — whether a move is actually worth making for this squad, this manager and this Gameweek.

That separation is deliberate. A player can look excellent in isolation and still be the wrong transfer once selling value, a hit, future fixtures, rank strategy, uncertainty and opportunity cost are included.

## Player and team evidence

For the deeper decision path, the implementation builds a canonical player record from Official FPL data. Where available, the context includes:

- price and current availability/status;
- chance of playing next round and news;
- form;
- Official FPL `ep_next` and `ep_this`;
- points per game, total points and current-event points;
- minutes and starts;
- goals, assists and clean sheets;
- bonus and BPS;
- expected goals, expected assists and expected goal involvements;
- expected goals conceded;
- xG/90, xA/90 and xGI/90;
- influence, creativity, threat and ICT index;
- selected-by percentage;
- transfers in/out for the event;
- the next six Official FPL fixtures, including opponent, venue and FPL difficulty.

The engine therefore has both **result data** and **underlying-process data**. It can distinguish, for example, a player who recently returned points from a player whose role, minutes and underlying numbers still support the move.

## Candidate discovery is not the final prediction

The public V4.1.2 source contains a deterministic shortlist heuristic:

```text
discovery_score = 2.0 × ep_next
                + 0.8 × form
                + 1.3 × xGI_per90
```

That score is intentionally labeled **candidate discovery only**. It is not called projected points and it is not allowed to become the final decision by itself.

Its job is simply to stop the reasoning layer from searching the entire player universe blindly. The deeper comparison can then use fixtures, price, squad fit, availability, expected minutes, transfer economics, risk and the manager's actual situation.

## Squad economics and constraints

For owned players the engine can carry:

- current selling price;
- purchase price;
- bank;
- free-transfer state when known;
- squad position;
- captain/vice state;
- starting/bench state.

A move is therefore evaluated as a route from the **actual current 15**, not as a generic player-vs-player ranking.

The deterministic validator checks, where data is available:

- transfer-out player is actually owned;
- transfer-in player is not already owned;
- transfer preserves FPL position;
- Official FPL is authoritative for incoming player's club, position and current price;
- incoming cost fits bank plus selling prices;
- post-transfer squad still contains 15 unique players;
- maximum three players per club;
- XI contains exactly 11;
- legal formation;
- bench contains one goalkeeper plus three ordered outfield substitutes;
- captain and vice-captain are different and both start.

**AI proposes. Code validates. The manager decides.**

## Fixtures and time horizon

The engine constructs a six-fixture run for every team, not only the current squad.

That lets it compare:

- immediate fixture quality;
- home/away sequence;
- one-week upside vs multi-week value;
- whether a transfer creates another likely transfer soon;
- whether holding preserves flexibility.

The system therefore treats a transfer as a **multi-period resource-allocation decision**, not merely a one-Gameweek points contest.

## Competitive context

When explicitly relevant, LiveFPL and league/manager intelligence add a separate strategy layer:

- projected/live rank;
- effective ownership;
- squad and XI overlap;
- differential count;
- rival-only and user-only starters;
- captain divergence;
- chip state;
- gap to nearby rivals or league leaders;
- rank movement;
- sampled manager behavior.

This layer is deliberately subordinate to football evidence. High ownership is not proof that a player is good, and a rival move is not a command to copy it.

## Manager-intelligence research

The private runtime also studies manager behavior over time. Public source includes logic for:

- transfer frequency;
- hit-week rate;
- no-transfer rate;
- template similarity;
- post-haul buying rate;
- captain hindsight efficiency;
- 1/3/5-GW realized transfer alpha;
- hit-adjusted transfer outcomes;
- historical pedigree;
- rank momentum;
- transfer timing;
- cohort ownership movement.

These are descriptive research features, not personality diagnoses or proof of skill. The implementation explicitly caps confidence early in the season and records population/temporal guardrails.

## Human evidence is first-class, but provenance matters

The system can capture natural-language and screenshot evidence including:

- hunches and gut feelings;
- user opinions;
- eye-test observations;
- tactical observations;
- statistical evidence;
- social/external opinions;
- ownership/EO concerns;
- differential preference;
- captaincy context;
- transfer-in/out consideration;
- hold/roll preference;
- bench/lineup thinking;
- minutes/rotation predictions;
- performance predictions;
- price signals;
- availability/injury news;
- fixture/matchup observations;
- rival context;
- explicit model challenge;
- team/club sentiment;
- loss-aversion language;
- recency signals.

A crucial rule is that these are **observed signals, not diagnoses**. An external person's opinion remains external evidence. A screenshot cannot silently become proof of ownership. A user's hunch remains a hunch.

## Bias and AI-influence research

The research design is built to make several decision effects inspectable rather than invisible:

- **confirmation bias** — whether evidence is being selected mainly to support an existing preference;
- **recency bias** — whether a recent haul or blank disproportionately changes the decision;
- **ownership / social-proof pressure** — whether EO/template popularity is driving the move;
- **loss aversion** — whether rank protection or fear of losing is dominating expected value;
- **differential/contrarian preference** — whether uniqueness itself is being over-rewarded;
- **club/team sentiment** — whether allegiance or distrust affects evaluation;
- **automation bias / AI deference** — whether the manager changes a pre-model view simply because the model disagrees;
- **hindsight bias / outcome bias** — whether the result is later used to rewrite whether the original reasoning was good.

The implementation does not claim it has already proven or eliminated these biases. It records the evidence needed to study them.

## The pre-model / post-model chain

The research layer can explicitly record:

```text
evidence
→ pre-analysis belief
→ stated confidence
→ AI recommendation
→ changed mind?
→ accepted / overruled model?
→ final intended action
→ Official FPL action
→ outcome
→ retrospective evaluation
```

That distinction matters because a participant exposed to AI is no longer an untouched human baseline.

The system therefore keeps separate records for:

- what the user believed before analysis;
- what evidence supported that belief;
- what the model recommended;
- whether the user accepted or overruled the model;
- what evidence changed the user's mind;
- what was actually changed in Official FPL;
- what happened afterward.

## Decision quality is not the same as outcome

A 15-point captain can still have been a bad ex-ante choice. A one-point captain can still have been defensible.

The system therefore tries to preserve:

- information available at the time;
- uncertainty;
- source provenance;
- confidence;
- alternative routes;
- actual outcome separately from original reasoning.

The post-GW5 dataset is still too small and incomplete to claim causal improvement or a self-training optimal policy. The research foundation exists; full normalized outcome evaluation is future work.
