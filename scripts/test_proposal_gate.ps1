# Safe, synthetic-only regression checks for the published proposal gate.
# Run from Windows PowerShell 5.1 or PowerShell 7:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_proposal_gate.ps1
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source=Join-Path $Root 'src/automation/Run-CopilotAI.ps1'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count -gt 0){throw ('Source PowerShell syntax errors: '+((@($parseErrors | ForEach-Object {$_.Message})) -join ' | '))}

# Import only isolated pure/validation functions. Never start the AI worker.
$functions=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in @('Normalize-ProposalName','Validate-DeepTeamProposal','Normalize-DecisionConfidencePercent','Parse-StructuredTeamDecision')){
    $matches=@($functions | Where-Object {$_.Name -eq $name})
    if($matches.Count -ne 1){throw ("Expected one function named {0}; found {1}" -f $name,$matches.Count)}
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
$teamNames=@('Club A','Club B','Club C','Club D','Club E','Club F')
$names=@('GK_A','GK_B','DEF_A','DEF_B','DEF_C','DEF_D','DEF_E','MID_A','MID_B','MID_C','MID_D','MID_E','FWD_A','FWD_B','FWD_C')
$positions=@('GKP','GKP','DEF','DEF','DEF','DEF','DEF','MID','MID','MID','MID','MID','FWD','FWD','FWD')
$script:FakeBootstrap=[pscustomobject]@{
    teams=@(for($i=0;$i -lt $teamNames.Count;$i++){[pscustomobject]@{id=($i+1);name=$teamNames[$i]}})
    elements=@(
        [pscustomobject]@{id=101;web_name='MID_OK';first_name='Test';second_name='Ok';element_type=3;team=4;now_cost=60}
        [pscustomobject]@{id=102;web_name='MID_BAD_CLUB';first_name='Test';second_name='BadClub';element_type=3;team=1;now_cost=50}
    )
}
function Read-JsonSafe([string]$Path){return $script:FakeBootstrap}
$current=@(for($i=0;$i -lt $names.Count;$i++){
    [pscustomobject]@{id=($i+1);name=$names[$i];position=$positions[$i];team=$teamNames[$i % 6];selling_price_m=5.0;current_price_m=5.5}
})
$startNames=@('GK_A','DEF_A','DEF_B','DEF_C','MID_A','MID_B','MID_C','MID_D','FWD_A','FWD_B','FWD_C')
$benchNames=@('GK_B','DEF_D','DEF_E','MID_E')
function New-Proposal {
    $xi=@(foreach($name in $startNames){
        $p=@($current | Where-Object {$_.name -eq $name})[0]
        [pscustomobject]@{name=$p.name;position=$p.position;club=$p.team;price_m=5.0}
    })
    $bench=@(for($i=0;$i -lt $benchNames.Count;$i++){
        $p=@($current | Where-Object {$_.name -eq $benchNames[$i]})[0]
        [pscustomobject]@{order=$i;name=$p.name;position=$p.position;club=$p.team;price_m=5.0}
    })
    return [pscustomobject]@{
        schema_version=3;gameweek=7;status='NO_CHANGE';formation='3-4-3';transfers=@()
        captain='FWD_A';vice='MID_A';chip='HOLD';confidence=70
        conditions='';summary='Synthetic test';starting_xi=$xi;bench=$bench
    }
}
function New-TransferProposal([string]$Name,[string]$Club,[double]$Price){
    $proposal=New-Proposal
    $proposal.status='ACTIONABLE'
    $proposal.transfers=@([pscustomobject]@{out='MID_E';in=$Name;in_position='MID';in_club=$Club;in_price_m=$Price;note='Synthetic transfer'})
    $benchPlayer=@($proposal.bench | Where-Object {$_.name -eq 'MID_E'})[0]
    $benchPlayer.name=$Name;$benchPlayer.club=$Club;$benchPlayer.price_m=$Price
    return $proposal
}
$passed=0
function Assert-Case([string]$Name,$Errors,[bool]$Blocked,[string]$ExpectedFragment=''){
    $items=@($Errors | Where-Object {$_ -ne $null -and [string]$_ -ne ''})
    if($Blocked -and $items.Count -eq 0){throw "FAIL $Name : illegal proposal accepted"}
    if(-not $Blocked -and $items.Count -ne 0){throw ("FAIL {0}: valid proposal blocked: {1}" -f $Name,($items -join ' | '))}
    if($ExpectedFragment -and -not (($items -join ' | ') -like ('*'+$ExpectedFragment+'*'))){
        throw ("FAIL {0}: missing error fragment '{1}': {2}" -f $Name,$ExpectedFragment,($items -join ' | '))
    }
    $script:passed++
    Write-Host ("PASS {0}" -f $Name)
}
Assert-Case 'legal HOLD' (Validate-DeepTeamProposal (New-Proposal) $current 0.5) $false
Assert-Case 'legal single transfer' (Validate-DeepTeamProposal (New-TransferProposal 'MID_OK' 'Club D' 6.0) $current 1.0) $false
Assert-Case 'insufficient funds' (Validate-DeepTeamProposal (New-TransferProposal 'MID_OK' 'Club D' 6.0) $current 0.5) $true 'exceed budget'
Assert-Case 'missing bank' (Validate-DeepTeamProposal (New-TransferProposal 'MID_OK' 'Club D' 6.0) $current $null) $true 'Bank is missing'
$missingSell=@($current | ForEach-Object {$_ | ConvertTo-Json -Depth 4 | ConvertFrom-Json})
(@($missingSell | Where-Object {$_.name -eq 'MID_E'})[0]).selling_price_m=$null
Assert-Case 'missing selling price' (Validate-DeepTeamProposal (New-TransferProposal 'MID_OK' 'Club D' 6.0) $missingSell 1.0) $true 'selling prices'
Assert-Case 'more than three players from club' (Validate-DeepTeamProposal (New-TransferProposal 'MID_BAD_CLUB' 'Club A' 5.0) $current 1.0) $true 'more than 3'
Assert-Case 'unresolved incoming player' (Validate-DeepTeamProposal (New-TransferProposal 'MID_UNKNOWN' 'Club D' 5.0) $current 1.0) $true 'could not be uniquely matched'
$script:FakeBootstrap=[pscustomobject]@{teams=@();elements=@()}
Assert-Case 'no Official FPL data' (Validate-DeepTeamProposal (New-TransferProposal 'MID_OK' 'Club D' 6.0) $current 1.0) $true 'could not be uniquely matched'
$dup=New-Proposal
$dup.bench[3].name='FWD_A'
Assert-Case 'duplicate across XI and bench' (Validate-DeepTeamProposal $dup $current 0.5) $true 'more than once'
$malformed=Parse-StructuredTeamDecision '{"answer_markdown":"test","proposal":' $current 1.0
if($malformed.proposal -or [string]::IsNullOrWhiteSpace([string]$malformed.parse_error)){throw 'FAIL malformed structured response was not rejected'}
$passed++;Write-Host 'PASS malformed JSON fails closed'
Write-Host ("ALL {0} SYNTHETIC PROPOSAL GATE CHECKS PASSED" -f $passed)
