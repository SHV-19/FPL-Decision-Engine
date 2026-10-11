# Collaborate, review or explore FPL Decision Engine

This project may be useful as a **constraint-aware sports analytics case study** and as a **human–AI decision research prototype**. The best first conversation is a review of a specific problem, not a claim of validated performance superiority.

## Where expertise could improve it

### Sports analytics and data engineering

Could a transfer-quality evaluation distinguish expected opportunity from realized FPL points, account for uncertainty in minutes, and handle multi-gameweek opportunity cost? A useful review would critique signal provenance, constraints, choice-set construction and evaluation windows.

### Human–AI interaction research

How should an experiment measure whether AI advice changes a manager's *initial* preference, confidence, calibration, or decision process, without conflating advice impact with realized football luck? A useful review would propose within-person controls, denominators, and disclosure of selection effects.

### Software engineering and product analytics

How can the local pipeline become easier to test with public/synthetic data while keeping private authentication and manager histories protected? A useful review would focus on deterministic rule fixtures, isolated data contracts, state freshness and reproducible QA.

## What is available

The [curated V4.1.2 public code](../../src/automation), [architecture explanation](ARCHITECTURE_MAP.md), [synthetic decision scenario](SYNTHETIC_DECISION_EXAMPLE.md), and [research-methods brief](RESEARCH_BRIEF.md) are public and reviewable. The later private Windows runtime and personally attributable research data are **not** shared.

## How to reach out

[**Open a public collaboration inquiry**](https://github.com/SHV-19/FPL-Decision-Engine/issues/new/choose) with:

- Your interest: football data, human–AI research, or system engineering.
- The exact hypothesis, constraint or issue you want to discuss.
- What you would like to review or reproduce.
- Whether you need a public/synthetic example rather than private FPL data.

GitHub issues are public. **Never include** credentials, OIDC tokens, private account screenshots, personal identifiers, third-party manager profiles or unpublished raw research records.

## A concrete starting research question

> Does explicit rule validation reduce structurally illegal recommendations, and how does its presence affect human trust and willingness to follow AI advice?

A responsible study would predefine the baseline, sample, decision opportunities, exclusion criteria, what counts as an invalid proposal, and how confidence or behavior will be measured. **No controlled experimental result is claimed today.**

## Licensing and limitations

The public repository is a curated showcase without a selected general-use open-source license. Please ask before proposing redistribution or incorporation of its code elsewhere. [Full release-readiness boundaries](../RELEASE_READINESS.md).