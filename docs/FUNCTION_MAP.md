# Source and function map

These are component-level responsibilities observed in the V4.1.2 audit, not a guarantee that every private runtime function is available in this public staging repository.

| Module | Role | Typical inputs | Outputs |
| --- | --- | --- | --- |
| `Sync-FPLAccount.ps1` | Refresh Official FPL account-related data | entry details, Official endpoints | account snapshots |
| `Resolve-CurrentTeam.ps1` | Resolve authenticated editable team | OIDC-authenticated context | canonical current-team data or block |
| `Sync-PublicData.ps1` | Refresh public FPL datasets | Official public API | players, teams and fixtures |
| `Sync-MatchdayLive.ps1` | Update locked-team live scoring | Official event-live and picks | matchday score context |
| `Sync-LiveFPL.ps1` | Add rank and EO enrichment | LiveFPL observations | contextual rank data |
| `Run-CopilotAI.ps1` | Build focused/full reasoning requests | canonical context and question | structured model response |
| `Evidence-Classifier.ps1` | Categorize supporting evidence | images/observations | attributed classifications |
| `Research-Lib.ps1` | Manage research event capture | interactions and decisions | append-friendly records |
| `Sync-LeagueIntelligence.ps1` | Refresh league-level context | public league data | standings/ecology views |
| `Sync-ManagerIntelligence.ps1` | Collect selected rival behaviors | Official manager histories | sampled observations |
| `Close-Gameweek.ps1` | Archive a gameweek | locked picks, results, event state | close receipt/history |
| `ControlCenter-Lib.ps1` | Shared app/server utilities | local state, APIs | data and UI support |
| `Start-ControlCenter.ps1` | Start the local product | configuration and runtime state | local Control Center |
| `Verify-System.ps1` | Verification/diagnostics | installed product state | readiness diagnostics |
| `control-center.html` | UI experience | local service responses | user dashboard and Decision Studio |

The private runtime source is not a recommended copy-paste deployment bundle because account credentials and research state require separate provisioning.
