<div align="center">

# FPL Decision Engine
### Explainable football analytics for decisions, not just player rankings.

**Fantasy Premier League · Sports analytics · Human–AI decision making · Constraint validation**

> **The harder question:** A player may look like the best pick — but is signing them the best move for *this* squad, budget, gameweek and risk profile?

A local-first FPL decision-support project that combines **Official FPL data, squad and transfer rules, football evidence, LiveFPL context, and AI-assisted reasoning**. The model proposes; deterministic code checks whether the proposed squad action is legal; the manager remains in control.

[**See a 2-minute worked example**](docs/portfolio/SYNTHETIC_DECISION_EXAMPLE.md) · [**Architecture diagram**](docs/portfolio/ARCHITECTURE_MAP.md) · [**Explore the public source**](src/automation) · [**Research & collaboration**](docs/portfolio/COLLABORATE.md)

</div>

---

## Why this matters

Many FPL tools rank players. **A decision engine must compare feasible actions.** It needs to know which players are already owned, the transfer budget and free transfers, the cost of a points hit, legal lineups, future flexibility and the uncertainties in the evidence.

| Prediction | Decision | Strategy |
|---|---|---|
| Who looks promising on minutes, xGI, form and fixtures? | Is HOLD, a free transfer or a hit worthwhile *for this team*? | How should rank, effective ownership (EO), rivals and uncertainty influence the choice? |

**Example — synthetic, not a recorded matchday result:** Suppose a transfer recommendation would create **four players from one club**. It can look appealing on form and expected points, but the deterministic legality gate must reject it. The project also distinguishes a rejected/expired authenticated squad from a fresh current team; stale ownership cannot authorize an actionable Exact Call.

[Read the complete synthetic walkthrough →](docs/portfolio/SYNTHETIC_DECISION_EXAMPLE.md)

## The system at a glance

![Public-safe data and decision architecture](docs/portfolio/architecture-public-safe.svg)

1. **Establish authority.** Official FPL supplies player/fixture identities and scoring; the authenticated editable squad is required for current team advice. Public health is not proof of private account health.
2. **Enrich, with provenance.** LiveFPL contributes projected-rank/EO context. Human eye-test notes, opinions and screenshots stay attributed; none can overwrite Official squad state.
3. **Compare actions.** The decision layer considers transfer economics, lineups, captaincy, risk, near-term fixtures and future flexibility. A shortlist heuristic is **not** presented as predicted points.
4. **Validate rules.** Explicit checks cover owned players, budget, position, three-per-club, a unique 15-player squad, legal XI/bench and captain/vice constraints.
5. **Keep humans accountable.** Recommendations are advisory. Any real FPL transfer or chip action is performed manually on the Official FPL site.
6. **Capture research evidence.** The design records beliefs, model recommendations, user responses and gameweek records for later evaluation; full normalized outcome and causal research remain unfinished.

[Decision mechanics](docs/DECISION_ENGINE.md) · [Signal construction](docs/PREDICTION_AND_DECISION_SIGNALS.md) · [Source and function map](docs/FUNCTION_MAP.md)

## Choose the path that fits your work

| If you are… | Start here | What to evaluate |
|---|---|---|
| **Sports analyst / football-data engineer** | [Architecture & source contracts](docs/portfolio/ARCHITECTURE_MAP.md) | Football data provenance, source freshness, constraint-aware choices |
| **Researcher / PhD supervisor** | [Research design](docs/portfolio/RESEARCH_BRIEF.md) | Human–AI influence, calibration, bias hypotheses and missing baselines |
| **Product / BI hiring manager** | [Five-minute product story](docs/portfolio/PRESENTATION_STORY.md) | Problem framing, user workflow, trade-offs and honest verification |
| **Software engineer** | [Curated source](src/automation) and [technical blueprint](docs/TECHNICAL_BLUEPRINT.md) | PowerShell orchestration, rule checks, local UI and failure handling |
| **FPL user** | [Feature and demo walkthrough](docs/portfolio/OPERATOR_WALKTHROUGH.md) | Transfer/HOLD advice, XI/bench, live scores, league and decision research |

**Interested in collaboration?** [Read the specific research and engineering questions](docs/portfolio/COLLABORATE.md) or [open a public project inquiry](https://github.com/SHV-19/FPL-Decision-Engine/issues/new/choose). Do not share personal FPL credentials or private account data in issues.

## What is demonstrable — and what is not

| Evidence / scope | Current claim |
|---|---|
| Curated public code | **Available:** historical V4.1.2 checkpoint with PowerShell automation, Control Center UI and source-safety checks |
| Decision rules and data contracts | **Inspected in source:** structured proposals and deterministic legality logic |
| Historical local operation | **Recorded:** one runtime-v2 audit had 42 passed, 6 warnings and 16 not tested out of 64; a separate classic-league audit observed 21/21 configured leagues refreshed |
| Latest private editable-team authentication | **Open:** last explicit reconnect attempt reported a rejected/expired credential; a fresh authenticated squad has not been reverified |
| Full V5 private runtime / always-on deployment | **Not released publicly:** not represented by this curated repository |
| Prediction superiority / rank improvement / bias causal findings | **Not established:** these are evaluation questions, not validated outcomes |

The public repository is **not a ready-to-run hosted service**, and no independent synthetic application demo is published yet. The private Windows build, local caches, account data and research archives are deliberately excluded. [See the release-evidence gates](docs/RELEASE_READINESS.md) and [dated V5 engineering notes](docs/V5_ENGINEERING_PROGRESS_OCT2026.md).

## What is actually implemented?

The historically reviewed private product has a Windows-local **Control Center** (Home, Team, Live, Leagues, Decision Studio, Research and Advanced). The **Decision Engine** names the whole product; **Decision Studio** is the AI-assisted workflow within it. **FPL Decision Engine Studio** is a *separate private ChatGPT documentation plugin* and does not control the local app. The auxiliary Python V5 event console is an independent monitoring surface, not private squad authority.

**Technology:** PowerShell, HTML/JavaScript, Official Fantasy Premier League APIs, LiveFPL context, AI reasoning API, JSON/JSONL research records, and an auxiliary Python event monitor in later private work.

This project was built using **AI-assisted development**, with human-led problem definition, source authority rules, data/analytics requirements, system behavior, iterative debugging, QA criteria and release decisions. The presence of AI-generated code does not imply a proprietary trained FPL forecasting model. [How the project was built](docs/portfolio/BUILD_STORY_AND_QA.md).

## Explore in depth

[Portfolio hub](docs/portfolio/README.md) · [Product case study](docs/PRODUCT_CASE_STUDY.md) · [Architecture](docs/ARCHITECTURE.md) · [Prediction and decision signals](docs/PREDICTION_AND_DECISION_SIGNALS.md) · [Calibration and outcomes](docs/CALIBRATION_AND_OUTCOMES.md) · [Demo walk-through](docs/DEMO.md) · [Privacy and publication scope](docs/PRIVACY_AND_PUBLIC_SOURCE.md) · [Release readiness](docs/RELEASE_READINESS.md)

### Use and citation

This repository is a **curated public showcase**, not an open-source licensed turnkey product. No license has been selected for broader reuse. For academic attribution use the repository's [citation metadata](CITATION.cff); a DOI, peer-reviewed paper or empirically validated causal study is **not** claimed.

<sub>Independent Fantasy Premier League research project; not affiliated with or endorsed by the Premier League. Do not post account credentials, private manager identities, raw logs or screenshots in public issues.</sub>
