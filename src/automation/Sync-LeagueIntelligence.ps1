param(
    [ValidateSet('Light','Deep')][string]$Mode='Light',
    [int]$LeagueId=0,
    [int]$BudgetSeconds=0,
    [switch]$Quiet,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$conn=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
if(-not $conn -or -not $conn.team_id){throw 'FPL Team ID is not configured.'}
$teamId=[int]$conn.team_id
$base='https://fantasy.premierleague.com/api'
$headers=@{'User-Agent'='Mozilla/5.0 FPL-Decision-Engine/2.8.1';'Accept'='application/json'}
$leagueDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\LEAGUES'
$rivalDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\RIVALS'
$intelDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\LEAGUE_INTELLIGENCE'
$snapDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\LEAGUE_SNAPSHOTS'
$currentDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT'
$statePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_league_intelligence.json'
New-Item -ItemType Directory -Force -Path $leagueDir,$rivalDir,$intelDir,$snapDir,$currentDir | Out-Null

$started=Get-Date
if($BudgetSeconds -le 0){$BudgetSeconds=if($Mode -eq 'Deep'){60}else{24}}
$errors=New-Object System.Collections.ArrayList
$leagueResults=New-Object System.Collections.ArrayList
$pagesFetched=0
$rivalsFetched=0

function Save-State([string]$State,[string]$Stage,[int]$Current,[int]$Total){
    $now=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status=$State
        mode=$Mode.ToUpperInvariant()
        process_id=$PID
        started_at_local=$started.ToString('o')
        completed_at_local=if($State -in @('SUCCESS','PARTIAL','FAILED')){$now.ToString('o')}else{$null}
        heartbeat_at_local=$now.ToString('o')
        duration_seconds=[math]::Round(($now-$started).TotalSeconds,1)
        budget_seconds=$BudgetSeconds
        stage=$Stage
        progress_current=$Current
        progress_total=$Total
        league_id=if($LeagueId -gt 0){$LeagueId}else{$null}
        pages_fetched=$script:pagesFetched
        rival_picks_fetched=$script:rivalsFetched
        errors=@($script:errors)
        leagues=@($script:leagueResults)
    }) $statePath 80
}
function Page-ForRank([int]$Rank){if($Rank -le 0){return 1};return [int]([math]::Max(1,[math]::Ceiling($Rank/50.0)))}
function Budget-Expired {return (((Get-Date)-$started).TotalSeconds -ge $BudgetSeconds)}
function Fetch-LeaguePage([int]$TargetLeagueId,[int]$PageNumber){
    $obj=Invoke-RestMethod -Uri "$base/leagues-classic/$TargetLeagueId/standings/?page_standings=$PageNumber" -Headers $headers -TimeoutSec 9
    $script:pagesFetched++
    return $obj
}

# Refresh the lightweight entry first. It supplies current mini-league membership
# and rank hints without crawling any standings pages.
$entry=$null
try{
    $entry=Invoke-RestMethod -Uri "$base/entry/$teamId/" -Headers $headers -TimeoutSec 9
    Write-JsonUtf8 $entry (Join-Path $currentDir 'entry.json') 100
}catch{
    [void]$errors.Add('Entry refresh failed; cached league membership will be used: '+$_.Exception.Message)
    $entry=Read-JsonSafe (Join-Path $currentDir 'entry.json')
}

$private=@()
if($entry -and $entry.leagues -and $entry.leagues.classic){
    $private=@($entry.leagues.classic | Where-Object {$_.league_type -eq 'x'} | Select-Object id,name,entry_rank,entry_last_rank,start_event,entry_can_leave,entry_can_admin)
    try{Write-JsonUtf8 $private (Join-Path $currentDir 'discovered_private_leagues.json') 40}catch{}
}else{
    $cachedPrivate=Read-JsonSafe (Join-Path $currentDir 'discovered_private_leagues.json')
    if($cachedPrivate){$private=@($cachedPrivate)}
}

$targets=@()
if($LeagueId -gt 0){
    $targets=@([pscustomobject]@{id=$LeagueId;name=$null;entry_rank=$null;kind='EXPLICIT'})
}else{
    foreach($pl in @($private | Sort-Object @{Expression={if($_.entry_rank -ne $null){[int]$_.entry_rank}else{999999999}}})){
        $targets += [pscustomobject]@{id=[int]$pl.id;name=[string]$pl.name;entry_rank=$pl.entry_rank;kind='PRIVATE'}
    }
    foreach($rawLeagueId in @($conn.tracked_league_ids)){
        $candidateId=0
        try{$candidateId=[int]$rawLeagueId}catch{}
        if($candidateId -le 0){continue}
        if(@($targets | Where-Object {[int]$_.id -eq $candidateId}).Count -eq 0){
            $targets += [pscustomobject]@{id=$candidateId;name=$null;entry_rank=$null;kind='TRACKED'}
        }
    }
    # Live cockpit prioritization: highest-ranked memberships first. Deep mode
    # can cover more leagues; Light mode keeps the fast lane bounded.
    $limit=if($Mode -eq 'Deep'){20}else{6}
    $targets=@($targets | Select-Object -First $limit)
}

if($targets.Count -eq 0){
    Save-State 'SUCCESS' 'No leagues configured.' 0 0
    if(-not $Quiet){Write-Host 'No leagues configured; league intelligence skipped.' -ForegroundColor DarkGray}
    return
}

Save-State 'SYNCING' 'Starting automatic league refresh.' 0 $targets.Count
$lockedGw=Get-LatestLockedGameweek $Root
$index=0
foreach($target in $targets){
    $index++
    if(Budget-Expired){
        [void]$errors.Add("League intelligence stopped at the ${BudgetSeconds}s safety budget; remaining leagues retain cache.")
        break
    }
    $lid=[int]$target.id
    Save-State 'SYNCING' ("Refreshing league {0}" -f $lid) $index $targets.Count
    try{
        $leaguePath=Join-Path $leagueDir ("league_$lid.json")
        $old=Read-JsonSafe $leaguePath
        $rankHint=0
        try{if($target.entry_rank -ne $null){$rankHint=[int]$target.entry_rank}}catch{}
        if($rankHint -le 0 -and $old -and $old.standings){
            $oldMe=$old.standings | Where-Object {[int]$_.entry -eq $teamId} | Select-Object -First 1
            if($oldMe){try{$rankHint=[int]$oldMe.rank}catch{}}
        }
        $userPage=Page-ForRank $rankHint
        $pages=New-Object System.Collections.ArrayList
        [void]$pages.Add(1)
        $candidatePages=[int[]]@(($userPage - 1),$userPage,($userPage + 1))
        foreach($pageCandidate in $candidatePages){
            if($pageCandidate -ge 1 -and -not $pages.Contains([int]$pageCandidate)){[void]$pages.Add([int]$pageCandidate)}
        }

        # Light mode starts with page 1 + the user's page. Adjacent pages are
        # added only for deeper refreshes or when they are the same small set.
        if($Mode -eq 'Light'){
            $lightPages=New-Object System.Collections.ArrayList
            [void]$lightPages.Add(1)
            if($userPage -gt 1){[void]$lightPages.Add($userPage)}
            $pages=$lightPages
        }

        $rows=@();$leagueInfo=$null;$actualPages=@()
        foreach($pageNumber in @($pages | Sort-Object)){
            if(Budget-Expired){break}
            $obj=Fetch-LeaguePage $lid ([int]$pageNumber)
            if(-not $leagueInfo){$leagueInfo=$obj.league}
            $rows += @($obj.standings.results)
            $actualPages += [int]$pageNumber
        }
        $rows=@($rows | Sort-Object entry -Unique | Sort-Object rank)
        if(-not $leagueInfo){throw 'FPL returned no league information.'}

        # Preserve the prior fetched window for movement comparisons.
        if($old){
            try{Write-JsonUtf8 $old (Join-Path $snapDir ("league_${lid}_previous.json")) 100}catch{}
        }
        $leagueOut=[ordered]@{
            league=$leagueInfo
            standings=$rows
            synced_at=(Get-Date).ToString('o')
            partial_window=$true
            pages_fetched=@($actualPages)
            refresh_mode=('AUTO_'+$Mode.ToUpperInvariant())
        }
        Write-JsonUtf8 $leagueOut $leaguePath 100
        try{Write-JsonUtf8 $leagueOut (Join-Path $snapDir ("league_${lid}_latest.json")) 100}catch{}

        $oldMap=@{}
        if($old -and $old.standings){foreach($oldRow in @($old.standings)){$oldMap[[int]$oldRow.entry]=$oldRow}}
        $movement=@()
        foreach($newRow in $rows){
            $oldRow=$null
            if($oldMap.ContainsKey([int]$newRow.entry)){$oldRow=$oldMap[[int]$newRow.entry]}
            $rankDelta=$null;$pointsDelta=$null
            if($oldRow){
                try{$rankDelta=[int]$oldRow.rank-[int]$newRow.rank}catch{}
                try{$pointsDelta=[int]$newRow.total-[int]$oldRow.total}catch{}
            }
            $movement += [pscustomobject]@{
                entry=[int]$newRow.entry
                team_name=[string]$newRow.entry_name
                manager_name=[string]$newRow.player_name
                rank=[int]$newRow.rank
                previous_rank=if($oldRow){$oldRow.rank}else{$null}
                rank_delta=$rankDelta
                points=[int]$newRow.total
                previous_points=if($oldRow){$oldRow.total}else{$null}
                points_delta=$pointsDelta
                event_points=$newRow.event_total
                is_me=([int]$newRow.entry -eq $teamId)
            }
        }
        $me=$movement | Where-Object {$_.is_me} | Select-Object -First 1
        $biggestRiser=$movement | Where-Object {$_.rank_delta -ne $null -and [int]$_.rank_delta -gt 0} | Sort-Object rank_delta -Descending | Select-Object -First 1
        $biggestFaller=$movement | Where-Object {$_.rank_delta -ne $null -and [int]$_.rank_delta -lt 0} | Sort-Object rank_delta | Select-Object -First 1
        $intel=[ordered]@{
            league_id=$lid
            league_name=$leagueInfo.name
            captured_at=(Get-Date).ToString('o')
            previous_captured_at=if($old){$old.synced_at}else{$null}
            user_rank=if($me){$me.rank}else{$null}
            user_rank_delta=if($me){$me.rank_delta}else{$null}
            biggest_riser=$biggestRiser
            biggest_faller=$biggestFaller
            movement=@($movement)
        }
        Write-JsonUtf8 $intel (Join-Path $intelDir ("league_${lid}.json")) 80

        # V4.0.0 research panel: sample manager behavior across different parts of
        # the fetched league window instead of only the leaders. The panel is
        # deduplicated by FPL entry and grows over repeated syncs because locked
        # picks are immutable and already-cached managers cost no network call.
        $rawRows=@($rows)
        $meStanding=$rawRows | Where-Object {[int]$_.entry -eq $teamId} | Select-Object -First 1
        $panelTarget=if($Mode -eq 'Deep'){30}else{18}
        $leaderN=if($Mode -eq 'Deep'){9}else{6};$nearN=if($Mode -eq 'Deep'){12}else{8}
        $panel=New-Object System.Collections.ArrayList;$reasons=@{}
        function Add-PanelRows([object[]]$Rows,[string]$Reason){
            foreach($rr in @($Rows)){
                if(-not $rr -or [int]$rr.entry -eq $teamId){continue};$id=[int]$rr.entry
                if(-not $reasons.ContainsKey($id)){[void]$panel.Add($rr);$reasons[$id]=New-Object System.Collections.ArrayList}
                if(-not ($reasons[$id] -contains $Reason)){[void]$reasons[$id].Add($Reason)}
            }
        }
        Add-PanelRows @($rawRows | Sort-Object rank | Select-Object -First $leaderN) 'LEADERS'
        if($meStanding){Add-PanelRows @($rawRows | Where-Object {[int]$_.entry -ne $teamId} | Sort-Object @{Expression={[math]::Abs([int]$_.rank-[int]$meStanding.rank)}} | Select-Object -First $nearN) 'NEAR_USER'}
        # Stratified observations from the fetched window reduce leader-only bias.
        $others=@($rawRows | Where-Object {[int]$_.entry -ne $teamId} | Sort-Object rank)
        if($others.Count -gt 0){
            $slots=if($Mode -eq 'Deep'){8}else{5}
            for($i=1;$i -le $slots;$i++){
                $idx=[math]::Min($others.Count-1,[math]::Max(0,[math]::Round(($i/([double]($slots+1)))*($others.Count-1))))
                Add-PanelRows @($others[$idx]) 'STRATIFIED_WINDOW'
            }
        }
        if($biggestRiser){Add-PanelRows @($rawRows | Where-Object {[int]$_.entry -eq [int]$biggestRiser.entry}) 'MOMENTUM_RISER'}
        if($biggestFaller){Add-PanelRows @($rawRows | Where-Object {[int]$_.entry -eq [int]$biggestFaller.entry}) 'MOMENTUM_FALLER'}
        $panel=@($panel | Sort-Object entry -Unique | Select-Object -First $panelTarget)
        $intel['research_sample_target']=$panelTarget
        $intel['research_sample_roster']=@($panel | ForEach-Object {[pscustomobject][ordered]@{entry=[int]$_.entry;team=[string]$_.entry_name;manager=[string]$_.player_name;rank=[int]$_.rank;points=[int]$_.total;sample_reasons=@($reasons[[int]$_.entry])}})
        $intel['research_sample_coverage_note']='Stratified sample of fetched standings pages, not a census of the entire league.'
        Write-JsonUtf8 $intel (Join-Path $intelDir ("league_${lid}.json")) 90

        # Locked picks are immutable. Fill the sampled panel incrementally until
        # the safety budget expires; later refreshes continue from cache.
        if($lockedGw -gt 0 -and $conn.sync_rival_picks_after_deadline -eq $true){
            foreach($rivalRow in @($panel)){
                if(Budget-Expired){break}
                $rid=[int]$rivalRow.entry;$rivalPath=Join-Path $rivalDir ("league_${lid}_entry_${rid}_GW{0:D2}.json" -f $lockedGw)
                if((Test-Path $rivalPath) -and -not $Force){continue}
                try{
                    $picks=Invoke-RestMethod -Uri "$base/entry/$rid/event/$lockedGw/picks/" -Headers $headers -TimeoutSec 8
                    Write-JsonUtf8 ([ordered]@{league_id=$lid;league_name=$leagueInfo.name;entry=$rid;entry_name=$rivalRow.entry_name;player_name=$rivalRow.player_name;rank=$rivalRow.rank;total=$rivalRow.total;event_total=$rivalRow.event_total;sample_reasons=@($reasons[$rid]);picks=$picks;synced_at=(Get-Date).ToString('o')}) $rivalPath 100
                    $rivalsFetched++
                }catch{[void]$errors.Add("rival $rid GW$lockedGw`: $($_.Exception.Message)")}
            }
        }

        [void]$leagueResults.Add([pscustomobject]@{
            id=$lid;name=$leagueInfo.name;ok=$true;pages=@($actualPages);rows=$rows.Count
            user_rank=if($me){$me.rank}else{$null};user_rank_delta=if($me){$me.rank_delta}else{$null}
            biggest_riser=if($biggestRiser){$biggestRiser.team_name}else{$null};biggest_faller=if($biggestFaller){$biggestFaller.team_name}else{$null}
            research_sample_target=$panelTarget;research_sample_roster_size=@($panel).Count
        })
    }catch{
        [void]$errors.Add("league $lid`: $($_.Exception.Message)")
        [void]$leagueResults.Add([pscustomobject]@{id=$lid;name=$target.name;ok=$false;error=$_.Exception.Message})
    }
}

$okCount=@($leagueResults | Where-Object {$_.ok -eq $true}).Count
$state=if($okCount -eq 0 -and $leagueResults.Count -gt 0){'FAILED'}elseif($errors.Count -gt 0){'PARTIAL'}else{'SUCCESS'}
Save-State $state 'Automatic league intelligence complete.' $leagueResults.Count $targets.Count
if(-not $Quiet){
    $tone=if($state -eq 'SUCCESS'){'Green'}elseif($state -eq 'PARTIAL'){'Yellow'}else{'Red'}
    Write-Host ("League intelligence {0}: {1}/{2} leagues in {3}s." -f $state,$okCount,$targets.Count,[math]::Round(((Get-Date)-$started).TotalSeconds,1)) -ForegroundColor $tone
}
return
