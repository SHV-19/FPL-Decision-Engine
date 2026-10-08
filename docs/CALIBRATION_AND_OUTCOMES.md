# Calibration and Outcomes

This project is a longitudinal **human–AI decision research foundation**, not a verified self-training machine-learning loop.

## What is actually recorded

The research layer can preserve:

- participant profile revisions, including stated risk preference, source trust and AI trust;
- pre-analysis preferred action;
- pre-analysis confidence;
- reason and evidence type;
- hunch category;
- raw user statement;
- natural-language signal classification;
- model recommendation;
- final intended action;
- whether the manager changed their mind;
- whether the model was accepted or overruled;
- evidence that changed the manager's mind;
- later Official FPL team state;
- Gameweek outcomes and close receipts.

The post-GW5 checkpoint contains approximately **709 research events**, five closed-GW archive receipts and only two rows in the legacy decision ledger. Decision outcomes therefore require reconstruction from the richer event stream rather than treating the old ledger as authoritative.

## Observable behavior signals

The natural-language research classifier can tag evidence/decision context such as:

- hunch / gut feeling;
- user opinion;
- eye test;
- tactical observation;
- external/social opinion;
- statistical evidence;
- ownership / EO concern;
- differential preference;
- captaincy;
- transfer-in / transfer-out consideration;
- hold / roll;
- bench / lineup;
- minutes / rotation prediction;
- performance prediction;
- price signal;
- availability;
- fixture matchup;
- rival context;
- explicit challenge to the model;
- team sentiment;
- loss-aversion language;
- recency signal.

These are **research observations, not diagnoses**. The code explicitly records that distinction.

## Bias hypotheses the data can support

The instrumentation was designed so future analysis can investigate:

### Confirmation bias
Did the manager seek or overweight evidence that supported an existing preferred action?

### Recency bias
Did one recent haul/blank materially shift belief despite a longer evidence window?

### Ownership / social-proof pressure
Did EO, template popularity or “everyone owns him” language drive the action?

### Loss aversion
Did protecting rank or fear of losing dominate the expected-value case?

### Differential / contrarian preference
Was being different itself rewarded beyond the football evidence?

### Team / club sentiment
Did support, distrust or refusal to own players from a club influence the decision?

### Automation bias / AI deference
Was a pre-model belief changed after the model recommendation, and was the model accepted despite weak supporting evidence?

### Hindsight / outcome bias
Was the ex-ante reasoning later judged mainly from the points result?

The current dataset does **not** justify claiming these biases have been measured reliably yet. The architecture makes them testable.

## Manager-intelligence research

The system also maintains descriptive strategy features for sampled managers:

- transfer frequency;
- hit frequency;
- no-transfer frequency;
- template similarity;
- post-haul buying proxy;
- rank momentum;
- historical pedigree;
- captain hindsight efficiency;
- 1/3/5-GW realized transfer alpha;
- hit-adjusted transfer alpha;
- transfer timing;
- ownership movement in sampled cohorts.

Behavior strata and archetype labels are heuristics with confidence caps. They are not proof that a manager is skilled, irrational, automated or a bot.

## Useful future measures

- decision coverage;
- model repair / block rate;
- initial belief vs model recommendation vs final action;
- accepted vs overruled model rate;
- changed-mind rate;
- confidence calibration;
- evidence-source usage;
- hit-adjusted transfer outcomes;
- captaincy decision review;
- ex-ante decision quality separately from realized points;
- sample-size and denominator reporting by decision type.

## Crucial cautions

- A successful outcome does not prove good reasoning.
- A bad outcome does not prove bad reasoning.
- Popularity in manager samples does not imply decision quality.
- A participant influenced by AI is not an untouched human baseline.
- Post-deadline actions must be attributed to the next actionable Gameweek.
- Sampled manager behavior is context, not a causal explanation.
- Support claims with denominator, sample composition and provenance.
- Label insufficient evidence explicitly.

No accuracy, causal benefit or machine-learning improvement claim is made from five Gameweeks alone.
