param(
    [switch]$Quiet,
    [switch]$Force,
    [ValidateSet('Incremental','Deep')][string]$Mode='Incremental'
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$configPath=Join-Path $Root '06_CONFIG\manager_intelligence.json'
$config=Read-JsonSafe $configPath
if(-not $config){
    $config=[pscustomobject]@{
        enabled=$true
        track_private_top_n=10
        track_overall_top_n=50
        track_extra_public_top_n=50
        picks_backfill_gws=3
        detail_refresh_hours=12
        request_delay_ms=900
        max_extra_public_leagues=5
        smart_money_min_transfer_count=3
        smart_money_min_ownership_delta_pp=8
        strategy_signal_cap_pct=12
    }
    Write-JsonUtf8 $config $configPath 20
}
if($config.enabled -ne $true){
    if(-not $Quiet){Write-Host 'Manager Intelligence disabled in config.' -ForegroundColor Yellow}
return
}

function Config-Int([string]$Name,[int]$Default){
    try{
        $p=$config.PSObject.Properties[$Name]
        if($p -and $p.Value -ne $null){return [int]$p.Value}
    }catch{}
    return $Default
}
function Config-Double([string]$Name,[double]$Default){
    try{
        $p=$config.PSObject.Properties[$Name]
        if($p -and $p.Value -ne $null){return [double]$p.Value}
    }catch{}
    return $Default
}

$conn=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
$entry=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\entry.json')
$boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
if(-not $conn -or -not $conn.team_id -or -not $entry -or -not $boot){
    if(-not $Quiet){Write-Host 'Manager Intelligence waiting for connected/synced FPL account.' -ForegroundColor Yellow}
return
}

$miRoot=Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE'
$current=Join-Path $miRoot 'CURRENT'
$cohortDir=Join-Path $miRoot 'COHORTS'
$managerDir=Join-Path $miRoot 'MANAGERS'
$eventDir=Join-Path $miRoot 'EVENTS'
$processed=Join-Path $miRoot 'PROCESSED'
$snapshots=Join-Path $miRoot 'SNAPSHOTS'
New-Item -ItemType Directory -Force -Path $current,$cohortDir,$managerDir,$eventDir,$processed,$snapshots | Out-Null

$base='https://fantasy.premierleague.com/api'
$headers=@{'User-Agent'='Mozilla/5.0 FPL-Decision-Engine/2.5 ManagerIntelligence';'Accept'='application/json'}

# Incremental mode is deliberately bounded for normal weekly/full sync use.
# Deep mode exists for deliberate post-GW/model-maintenance runs.
$rawDelay=Config-Int 'request_delay_ms' 900
$delay=if($Mode -eq 'Incremental'){[math]::Min($rawDelay,300)}else{[math]::Min($rawDelay,500)}
$requestTimeout=if($Mode -eq 'Incremental'){10}else{15}
$overallTopCap=if($Mode -eq 'Incremental'){30}else{50}
$overallTopN=[math]::Min((Config-Int 'track_overall_top_n' 50),$overallTopCap)
$privateTopN=[math]::Min((Config-Int 'track_private_top_n' 10),10)
$extraPublicTopCap=if($Mode -eq 'Incremental'){15}else{30}
$extraPublicTopN=[math]::Min((Config-Int 'track_extra_public_top_n' 50),$extraPublicTopCap)
$maxExtraPublicCap=if($Mode -eq 'Incremental'){3}else{5}
$maxExtraPublic=[math]::Min((Config-Int 'max_extra_public_leagues' 5),$maxExtraPublicCap)
$maxManagers=if($Mode -eq 'Incremental'){50}else{120}
$picksBackfill=[math]::Max(1,(Config-Int 'picks_backfill_gws' 3))
$detailRefreshHours=Config-Double 'detail_refresh_hours' 12
$managerBudgetSeconds=if($Mode -eq 'Incremental'){75}else{180}
$managerWorkStarted=Get-Date

$lockedGw=Get-LatestLockedGameweek $Root
$lockedEvent=$null
if($lockedGw -gt 0){$lockedEvent=$boot.events | Where-Object {[int]$_.id -eq $lockedGw} | Select-Object -First 1}
$lockedFinished=($lockedEvent -and $lockedEvent.finished -eq $true)

function Get-TransferTemporalAttribution($Transfer){
    $apiGw=0;try{$apiGw=[int]$Transfer.event}catch{}
    $out=[ordered]@{
        api_event_gw=$apiGw
        derived_effective_gw=$null
        effective_gw=if($apiGw -gt 0){$apiGw}else{$null}
        transfer_time=$Transfer.time
        deadline_time=$null
        deadline_relation='UNKNOWN'
        temporal_attribution_status='UNKNOWN'
        late_for_api_event=$null
        hours_before_api_deadline=$null
    }
    $tt=$null
    try{$tt=[DateTimeOffset]::Parse([string]$Transfer.time).ToUniversalTime()}catch{return [pscustomobject]$out}
    $apiEvent=$boot.events | Where-Object {[int]$_.id -eq $apiGw} | Select-Object -First 1
    if($apiEvent -and $apiEvent.deadline_time){
        try{
            $deadline=[DateTimeOffset]::Parse([string]$apiEvent.deadline_time).ToUniversalTime()
            $out.deadline_time=$deadline.ToString('o')
            $out.hours_before_api_deadline=[math]::Round(($deadline-$tt).TotalHours,2)
            $out.late_for_api_event=($tt -ge $deadline)
            $out.deadline_relation=if($tt -lt $deadline){'BEFORE_API_EVENT_DEADLINE'}else{'AT_OR_AFTER_API_EVENT_DEADLINE'}
        }catch{}
    }
    foreach($candidate in @($boot.events | Where-Object {$_.deadline_time} | Sort-Object {[int]$_.id})){
        try{
            $cd=[DateTimeOffset]::Parse([string]$candidate.deadline_time).ToUniversalTime()
            if($tt -lt $cd){$out.derived_effective_gw=[int]$candidate.id;break}
        }catch{}
    }
    if($out.derived_effective_gw -ne $null -and $apiGw -gt 0){
        $out.temporal_attribution_status=if([int]$out.derived_effective_gw -eq $apiGw){'CONSISTENT'}else{'API_EVENT_TIME_MISMATCH'}
    } elseif($out.derived_effective_gw -ne $null){$out.temporal_attribution_status='DERIVED_ONLY'}
    return [pscustomobject]$out
}

$now=Get-Date
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$meta=[ordered]@{
    synced_at_local=$now.ToString('o')
    completed_at_local=$null
    duration_seconds=$null
    mode=$Mode
    status='STARTING'
    locked_gameweek=$lockedGw
    locked_gameweek_finished=$lockedFinished
    cohorts=0
    candidate_managers=0
    unique_managers=0
    manager_cap=$maxManagers
    manager_budget_seconds=$managerBudgetSeconds
    manager_budget_exhausted=$false
    detailed_managers_refreshed=0
    history_refresh_deferred=($lockedGw -gt 0 -and -not $lockedFinished)
    picks_fetched=0
    picks_reused=0
    event_live_fetched=0
    progress_current=0
    progress_total=0
    progress_stage='COHORTS'
    errors=@()
}

$metaPath=Join-Path $current '_manager_intelligence_sync_meta.json'

# Any terminating failure after metadata initialization must leave a useful
# FAILED record rather than a misleading STARTING/PROCESSING file.
trap {
    $failedAt=Get-Date
    try{
        $script:meta.status='FAILED'
        $script:meta.progress_stage='FAILED'
        $script:meta.completed_at_local=$failedAt.ToString('o')
        $script:meta.duration_seconds=[math]::Round(($failedAt-$script:now).TotalSeconds,1)
        $msg=$_.Exception.Message
        if(-not [string]::IsNullOrWhiteSpace($msg)){
            $script:meta.errors += $msg
        }
        Write-JsonUtf8 $script:meta $script:metaPath 40
    }catch{}
    throw
}

function Save-Meta([string]$Stage){
    $script:meta.progress_stage=$Stage
    Write-JsonUtf8 $script:meta $script:metaPath 40
}

function Sleep-Api { if($delay -gt 0){Start-Sleep -Milliseconds $delay} }

function Get-CachedJson([string]$Url,[string]$Path,[double]$MaxAgeHours=12,[switch]$AlwaysRefresh){
    $useCache=$false
    if((Test-Path $Path) -and -not $Force -and -not $AlwaysRefresh){
        try{
            $age=((Get-Date)-(Get-Item $Path).LastWriteTime).TotalHours
            if($age -lt $MaxAgeHours){$useCache=$true}
        }catch{}
    }
    if($useCache){ return (Read-JsonSafe $Path) }
    try{
        $obj=Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $requestTimeout
        Write-JsonUtf8 $obj $Path 100
        Sleep-Api
        return $obj
    }catch{
        $script:meta.errors += "$Url`: $($_.Exception.Message)"
        if(Test-Path $Path){return (Read-JsonSafe $Path)}
        return $null
    }
}

function Get-LeaguePage([int]$LeagueId,[int]$TopN=50){
    $cache=Join-Path $cohortDir ("league_{0}_standings.json" -f $LeagueId)
    # League membership changes slowly enough that normal incremental syncs can
    # reuse a 30-minute cache. -Force explicitly bypasses it.
    $obj=Get-CachedJson "$base/leagues-classic/$LeagueId/standings/?page_standings=1" $cache 0.5 -AlwaysRefresh:$Force
    if(-not $obj){return $null}
    $rows=@($obj.standings.results | Select-Object -First $TopN)
    return [pscustomobject]@{league=$obj.league;rows=$rows}
}

function Get-ManagerFolder([int]$EntryId){
    $p=Join-Path $managerDir ("entry_{0}" -f $EntryId)
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

function Add-Membership([System.Collections.ArrayList]$List,[string]$Type,[string]$Name,[int]$LeagueId,$Row){
    if(-not $Row){return}
    [void]$List.Add([pscustomobject]@{
        cohort_type=$Type
        cohort_name=$Name
        league_id=$LeagueId
        entry=[int]$Row.entry
        team_name=[string]$Row.entry_name
        manager_name=[string]$Row.player_name
        cohort_rank=[int]$Row.rank
        points=[int]$Row.total
        event_points=[int]$Row.event_total
    })
}

# 1) Build bounded cohorts.
$memberships=New-Object System.Collections.ArrayList
$leagueMeta=@($entry.leagues.classic)

# Overall public leaders.
$overall=$leagueMeta | Where-Object { $_.name -eq 'Overall' } | Select-Object -First 1
if(-not $overall){$overall=$leagueMeta | Where-Object { $_.league_type -eq 's' } | Select-Object -First 1}
if($overall){
    $ol=Get-LeaguePage ([int]$overall.id) $overallTopN
    if($ol){
        foreach($r in @($ol.rows)){Add-Membership $memberships 'ELITE_OVERALL' ([string]$ol.league.name) ([int]$overall.id) $r}
    }
}

# Private mini-league top managers + managers near the user, using the bounded
# league windows already cached by Sync-FPLAccount Full mode.
$privateLeagues=@($leagueMeta | Where-Object { $_.league_type -eq 'x' })
foreach($pl in $privateLeagues){
    $lfPath=Join-Path $Root ("02_DATA\FPL_ACCOUNT\LEAGUES\league_{0}.json" -f [int]$pl.id)
    $cachedLeague=Read-JsonSafe $lfPath
    $rows=@()
    $lname=[string]$pl.name
    if($cachedLeague -and $cachedLeague.standings){
        $rows=@($cachedLeague.standings | Sort-Object rank | Select-Object -First $privateTopN)
        if($cachedLeague.league -and $cachedLeague.league.name){$lname=[string]$cachedLeague.league.name}
    } else {
        $lf=Get-LeaguePage ([int]$pl.id) $privateTopN
        if($lf){$rows=@($lf.rows);$lname=[string]$lf.league.name}
    }
    foreach($r in $rows){Add-Membership $memberships 'PRIVATE_TOP' $lname ([int]$pl.id) $r}

    if($cachedLeague -and $cachedLeague.standings){
        $allSorted=@($cachedLeague.standings | Sort-Object rank)
        $me=$allSorted | Where-Object {[int]$_.entry -eq [int]$conn.team_id} | Select-Object -First 1
        if($me){
            $near=@($allSorted |
                Where-Object {[int]$_.entry -ne [int]$conn.team_id} |
                Sort-Object @{Expression={[math]::Abs([int]$_.rank-[int]$me.rank)}} |
                Select-Object -First 10)
            foreach($r in $near){
                if(@($rows | Where-Object {[int]$_.entry -eq [int]$r.entry}).Count -eq 0){
                    Add-Membership $memberships 'PRIVATE_NEARBY' $lname ([int]$pl.id) $r
                }
            }
        }
    }
}

# Explicit extra public leagues are strategy context, not permission to crawl
# hundreds of managers. Fetch a small top slice from at most a few leagues.
$extraIds=@()
if($conn.tracked_league_ids){
    $extraIds=@($conn.tracked_league_ids |
        ForEach-Object {[int]$_} |
        Select-Object -Unique |
        Select-Object -First $maxExtraPublic)
}
$knownPrivateIds=@($privateLeagues | ForEach-Object {[int]$_.id})
foreach($lid in $extraIds){
    if($overall -and [int]$overall.id -eq $lid){continue}
    $isPriv=($knownPrivateIds -contains $lid)
    $n=if($isPriv){$privateTopN}else{$extraPublicTopN}
    $lf=Get-LeaguePage $lid $n
    if($lf){
        $ctype=if($isPriv){'PRIVATE_TOP'}else{'PUBLIC_LEAGUE_TOP'}
        foreach($r in @($lf.rows)){Add-Membership $memberships $ctype ([string]$lf.league.name) $lid $r}
    }
}

# Always include SELF.
$selfRow=[pscustomobject]@{
    entry=[int]$conn.team_id
    entry_name=[string]$entry.name
    player_name=((([string]$entry.player_first_name)+' '+([string]$entry.player_last_name)).Trim())
    rank=if($entry.summary_overall_rank){[int]$entry.summary_overall_rank}else{0}
    total=if($entry.summary_overall_points){[int]$entry.summary_overall_points}else{0}
    event_total=if($entry.summary_event_points){[int]$entry.summary_event_points}else{0}
}
Add-Membership $memberships 'SELF' 'My FPL Team' 0 $selfRow

$meta.cohorts=@($memberships | Select-Object cohort_type,cohort_name,league_id -Unique).Count
$allCandidateIds=@($memberships | ForEach-Object {[int]$_.entry} | Select-Object -Unique)
$meta.candidate_managers=$allCandidateIds.Count

# Priority: SELF -> nearest private rivals -> private leaders -> elite overall ->
# extra public league leaders. Hard cap keeps one sync bounded.
$priorityTypes=@('SELF','PRIVATE_NEARBY','PRIVATE_TOP','ELITE_OVERALL','PUBLIC_LEAGUE_TOP')
$selected=New-Object System.Collections.ArrayList
foreach($ptype in $priorityTypes){
    $ids=@($memberships |
        Where-Object {$_.cohort_type -eq $ptype} |
        Sort-Object cohort_rank |
        ForEach-Object {[int]$_.entry} |
        Select-Object -Unique)
    foreach($id in $ids){
        if(-not $selected.Contains([int]$id)){
            [void]$selected.Add([int]$id)
            if($selected.Count -ge $maxManagers){break}
        }
    }
    if($selected.Count -ge $maxManagers){break}
}
$uniqueIds=@($selected)
$meta.unique_managers=$uniqueIds.Count
$meta.progress_total=$uniqueIds.Count
Save-Meta 'COHORTS_READY'

$cohortOut=[ordered]@{
    generated_at=$now.ToString('o')
    mode=$Mode
    locked_gameweek=$lockedGw
    locked_gameweek_finished=$lockedFinished
    candidate_manager_count=$allCandidateIds.Count
    tracked_manager_count=$uniqueIds.Count
    memberships=@($memberships)
    tracked_entry_ids=@($uniqueIds)
}
Write-JsonUtf8 $cohortOut (Join-Path $current 'cohorts.json') 50
if($lockedGw -gt 0){
    Write-JsonUtf8 $cohortOut (Join-Path $snapshots ("cohorts_GW{0:D2}_{1}.json" -f $lockedGw,$stamp)) 50
}

# 2) Event-level points are only finalized once the event is finished. Cache forever.
$eventPoints=@{}
$finishedEvents=@($boot.events | Where-Object {$_.finished -eq $true} | ForEach-Object {[int]$_.id})
$maxFinished=0
if($finishedEvents.Count -gt 0){$maxFinished=($finishedEvents | Measure-Object -Maximum).Maximum}
foreach($g in $finishedEvents){
    $ep=Join-Path $eventDir ("event_GW{0:D2}_live.json" -f $g)
    $had=Test-Path $ep
    $obj=Get-CachedJson "$base/event/$g/live/" $ep 999999
    if($obj){
        $pm=@{}
        foreach($el in @($obj.elements)){try{$pm[[int]$el.id]=[int]$el.stats.total_points}catch{}}
        $eventPoints[$g]=$pm
        if(-not $had){$meta.event_live_fetched++}
    }
}

$pmap=@{}
foreach($el in @($boot.elements)){$pmap[[int]$el.id]=[string]$el.web_name}
$totalPlayers=0
try{$totalPlayers=[int]$boot.total_players}catch{}
if($totalPlayers -le 0){$totalPlayers=10000000}

# 3) Incremental manager details.
#
# Critical live-GW rule:
#   A deadline passing does NOT mean history/transfers for the new GW are final.
#   During a live GW we collect immutable locked picks, but defer expensive
#   history/transfer refreshes until the GW itself is finished.
$managerData=@{}
$idx=0
foreach($id in $uniqueIds){
    if(((Get-Date)-$managerWorkStarted).TotalSeconds -ge $managerBudgetSeconds){
        $meta.manager_budget_exhausted=$true
        $meta.errors += "Manager Intelligence stopped at the ${managerBudgetSeconds}s safety budget. Remaining manager profiles keep their previous cache."
        break
    }
    $idx++
    $meta.progress_current=$idx
    $meta.progress_stage=("MANAGERS {0}/{1}" -f $idx,$uniqueIds.Count)
    if(($idx % 5) -eq 0 -or $idx -eq 1 -or $idx -eq $uniqueIds.Count){Save-Meta $meta.progress_stage}

    $mf=Get-ManagerFolder $id
    $historyPath=Join-Path $mf 'history.json'
    $transfersPath=Join-Path $mf 'transfers.json'
    $entryPath=Join-Path $mf 'entry.json'

    $history=$null
    $transfers=@()
    $mEntry=$null

    if([int]$id -eq [int]$conn.team_id){
        $history=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\history.json')
        $transfers=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\transfers.json')
        $mEntry=$entry
        if($history){Write-JsonUtf8 $history $historyPath 100}
        if($transfers){Write-JsonUtf8 $transfers $transfersPath 100}
        if($mEntry){Write-JsonUtf8 $mEntry $entryPath 100}
    } else {
        $history=Read-JsonSafe $historyPath
        $transfers=Read-JsonSafe $transfersPath
        if(-not $transfers){$transfers=@()}
        if(Test-Path $entryPath){$mEntry=Read-JsonSafe $entryPath}

        if($lockedFinished -or $Mode -eq 'Deep'){
            $cachedMax=0
            if($history -and $history.current){
                $evs=@($history.current | ForEach-Object {[int]$_.event})
                if($evs.Count -gt 0){$cachedMax=($evs | Measure-Object -Maximum).Maximum}
            }
            $needDetail=$Force -or ($lockedGw -gt 0 -and $cachedMax -lt $lockedGw) -or (-not $history)
            if($needDetail){
                $history=Get-CachedJson "$base/entry/$id/history/" $historyPath $detailRefreshHours -AlwaysRefresh
                if($history){$meta.detailed_managers_refreshed++}
                $transfers=Get-CachedJson "$base/entry/$id/transfers/" $transfersPath $detailRefreshHours -AlwaysRefresh
                if(-not $transfers){$transfers=@()}
            }
        }
    }

    $pickMap=@{}
    if($lockedGw -gt 0){
        if($Mode -eq 'Deep' -and $lockedFinished){
            $pickStart=[math]::Max(1,$lockedGw-$picksBackfill+1)
        }else{
            $pickStart=$lockedGw
        }
        for($g=$pickStart;$g -le $lockedGw;$g++){
            $pp=Join-Path $mf ("picks_GW{0:D2}.json" -f $g)
            $had=Test-Path $pp
            $pick=$null

            if([int]$id -eq [int]$conn.team_id){
                $selfPick=Join-Path $Root ("02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json" -f $g)
                if(Test-Path $selfPick){
                    $pick=Read-JsonSafe $selfPick
                    if($pick -and -not $had){Write-JsonUtf8 $pick $pp 100}
                }
            }

            if(-not $pick -and $had){
                $pick=Read-JsonSafe $pp
                if($pick){$meta.picks_reused++}
            }

            if(-not $pick){
                $pick=Get-CachedJson "$base/entry/$id/event/$g/picks/" $pp 999999
                if($pick){$meta.picks_fetched++}
            }

            if($pick){$pickMap[$g]=$pick}
        }
    }

    $managerData[$id]=[pscustomobject]@{
        entry=$mEntry
        history=$history
        transfers=@($transfers)
        picks=$pickMap
    }
}
# Downstream calculations only use managers actually processed in this bounded run.
$uniqueIds=@($managerData.Keys | ForEach-Object {[int]$_})
$meta.unique_managers=$uniqueIds.Count
$meta.progress_total=$uniqueIds.Count
Save-Meta 'PROCESSING'

# 4) Flatten gameweek history + pedigree.
$gwRows=New-Object System.Collections.ArrayList
$pedigreeRows=New-Object System.Collections.ArrayList
$transferRows=New-Object System.Collections.ArrayList
$rawTransferRows=New-Object System.Collections.ArrayList
$chipRows=New-Object System.Collections.ArrayList
$scoreRows=New-Object System.Collections.ArrayList
$pickRows=New-Object System.Collections.ArrayList

foreach($id in $uniqueIds){
    $d=$managerData[$id]
    if(-not $d -or -not $d.history){continue}
    $membership=@($memberships | Where-Object {[int]$_.entry -eq $id})
    $cohortTypes=(@($membership.cohort_type | Select-Object -Unique) -join '|')
    $teamName=if($d.entry){[string]$d.entry.name}else{[string]($membership | Select-Object -First 1).team_name}
    $managerName=if($d.entry){(([string]$d.entry.player_first_name)+' '+([string]$d.entry.player_last_name)).Trim()}else{[string]($membership | Select-Object -First 1).manager_name}

    $hist=@($d.history.current | Sort-Object event)
    $byEvent=@{};foreach($h in $hist){$byEvent[[int]$h.event]=$h}
    foreach($h in $hist){
        $g=[int]$h.event
        $prev=$byEvent[$g-1]
        $rankDelta=$null;$rankLogMomentum=$null
        if($prev -and $prev.overall_rank -and $h.overall_rank){
            $rankDelta=[int]$prev.overall_rank-[int]$h.overall_rank
            if([int]$h.overall_rank -gt 0 -and [int]$prev.overall_rank -gt 0){
                $rankLogMomentum=[math]::Round([math]::Log10([double]$prev.overall_rank/[double]$h.overall_rank),4)
            }
        }
        [void]$gwRows.Add([pscustomobject]@{
            entry=$id;team_name=$teamName;manager_name=$managerName;cohorts=$cohortTypes;gw=$g
            points=[int]$h.points;total_points=[int]$h.total_points;gw_rank=$h.rank;overall_rank=$h.overall_rank
            rank_improvement=$rankDelta;rank_log_momentum=$rankLogMomentum
            transfers=[int]$h.event_transfers;hit_cost=[int]$h.event_transfers_cost
            points_on_bench=[int]$h.points_on_bench;team_value=[math]::Round([double]$h.value/10.0,1);bank=[math]::Round([double]$h.bank/10.0,1)
        })
    }
    foreach($p in @($d.history.past)){
        $rank=[int]$p.rank
        $pedScore=35
        if($rank -le 1000){$pedScore=100}elseif($rank -le 10000){$pedScore=90}elseif($rank -le 100000){$pedScore=75}elseif($rank -le 500000){$pedScore=60}elseif($rank -le 1000000){$pedScore=50}
        [void]$pedigreeRows.Add([pscustomobject]@{entry=$id;team_name=$teamName;manager_name=$managerName;season=$p.season_name;points=$p.total_points;overall_rank=$rank;pedigree_score=$pedScore})
    }

    # Recent picks / captain records.
    foreach($g in @($d.picks.Keys | Sort-Object)){
        $pick=$d.picks[$g]
        $cap=$null;$vice=$null;$benchPts=0;$bestStarter=-999
        foreach($pk in @($pick.picks)){
            $playerId=[int]$pk.element;$pts=$null
            if($eventPoints.ContainsKey([int]$g) -and $eventPoints[[int]$g].ContainsKey($playerId)){$pts=[int]$eventPoints[[int]$g][$playerId]}
            if([int]$pk.position -gt 11 -and $pts -ne $null){$benchPts += $pts}
            if([int]$pk.position -le 11 -and $pts -ne $null -and $pts -gt $bestStarter){$bestStarter=$pts}
            if($pk.is_captain -eq $true){$cap=[pscustomobject]@{id=$playerId;name=$pmap[$playerId];points=$pts;multiplier=[int]$pk.multiplier}}
            if($pk.is_vice_captain -eq $true){$vice=[pscustomobject]@{id=$playerId;name=$pmap[$playerId];points=$pts}}
        }
        $capEff=$null
        if($cap -and $cap.points -ne $null -and $bestStarter -gt 0){$capEff=[math]::Round(100.0*[double]$cap.points/[double]$bestStarter,1);if($capEff -gt 100){$capEff=100}}
        [void]$pickRows.Add([pscustomobject]@{
            entry=$id;team_name=$teamName;manager_name=$managerName;gw=[int]$g;active_chip=$pick.active_chip
            captain_id=if($cap){$cap.id}else{$null};captain=if($cap){$cap.name}else{$null};captain_raw_points=if($cap){$cap.points}else{$null};captain_multiplier=if($cap){$cap.multiplier}else{$null}
            vice_id=if($vice){$vice.id}else{$null};vice=if($vice){$vice.name}else{$null};bench_points=$benchPts;captain_hindsight_efficiency=$capEff
        })
    }

    # Raw transfer/change ledger: exactly what the manager changed and how early it was done.
    $trans=@($d.transfers)
    foreach($tr in $trans){
        $eg=[int]$tr.event;$prevPts=$null
        $temporal=Get-TransferTemporalAttribution $tr
        if($eg -gt 1 -and $eventPoints.ContainsKey($eg-1) -and $eventPoints[$eg-1].ContainsKey([int]$tr.element_in)){$prevPts=[int]$eventPoints[$eg-1][[int]$tr.element_in]}
        [void]$rawTransferRows.Add([pscustomobject]@{
            entry=$id;team_name=$teamName;manager_name=$managerName;cohorts=$cohortTypes;gw=$eg;api_event_gw=$temporal.api_event_gw;effective_gw=$temporal.effective_gw;derived_effective_gw=$temporal.derived_effective_gw;time=$tr.time
            deadline_time=$temporal.deadline_time;deadline_relation=$temporal.deadline_relation;temporal_attribution_status=$temporal.temporal_attribution_status;late_for_api_event=$temporal.late_for_api_event
            player_out_id=[int]$tr.element_out;player_out=$pmap[[int]$tr.element_out];player_in_id=[int]$tr.element_in;player_in=$pmap[[int]$tr.element_in]
            out_cost=[math]::Round([double]$tr.element_out_cost/10.0,1);in_cost=[math]::Round([double]$tr.element_in_cost/10.0,1)
            hours_before_deadline=$temporal.hours_before_api_deadline;incoming_previous_gw_points=$prevPts;post_haul_buy=if($prevPts -ne $null){($prevPts -ge 8)}else{$null}
            temporal_guardrail='Official API event is preserved as the canonical effective GW; timestamp-derived GW is an audit field used to detect deadline-window mismatches.'
        })
    }

    # Chip ledger is available from manager history even when old picks are not backfilled.
    foreach($ch in @($d.history.chips)){
        $eg=[int]$ch.event;$before=$byEvent[$eg-1];$after=$byEvent[$eg];$after3=$byEvent[$eg+2]
        $rankDelta=$null;$rankDelta3=$null
        if($before -and $after -and $before.overall_rank -and $after.overall_rank){$rankDelta=[int]$before.overall_rank-[int]$after.overall_rank}
        if($before -and $after3 -and $before.overall_rank -and $after3.overall_rank){$rankDelta3=[int]$before.overall_rank-[int]$after3.overall_rank}
        [void]$chipRows.Add([pscustomobject]@{
            entry=$id;team_name=$teamName;manager_name=$managerName;cohorts=$cohortTypes;gw=$eg;chip=$ch.name;played_time=$ch.time
            gw_points=if($after){[int]$after.points}else{$null};rank_before=if($before){$before.overall_rank}else{$null};rank_after=if($after){$after.overall_rank}else{$null}
            rank_improvement_1gw=$rankDelta;rank_improvement_3gw=$rankDelta3
        })
    }

    # Realized transfer alpha. Approximate by raw FPL points of player-in vs player-out over 1/3/5 GWs.
    # Hit cost is charged once to the event group, never once per transfer.
    $groups=@($trans | Group-Object event)
    foreach($grp in $groups){
        # Avoid shadowing PowerShell's automatic $Event variable.
        $transferEvent=[int]$grp.Name
        $histEvent=$byEvent[$transferEvent]
        $hitCost=0;if($histEvent){$hitCost=[int]$histEvent.event_transfers_cost}
        foreach($horizon in @(1,3,5)){
            $last=$transferEvent+$horizon-1
            if($last -gt $maxFinished){continue}
            $inPts=0;$outPts=0;$complete=$true
            foreach($tr in @($grp.Group)){
                $inId=[int]$tr.element_in;$outId=[int]$tr.element_out
                for($g=$transferEvent;$g -le $last;$g++){
                    if(-not $eventPoints.ContainsKey($g)){$complete=$false;continue}
                    if($eventPoints[$g].ContainsKey($inId)){$inPts += [int]$eventPoints[$g][$inId]}
                    if($eventPoints[$g].ContainsKey($outId)){$outPts += [int]$eventPoints[$g][$outId]}
                }
            }
            if($complete){
                $rawDelta=$inPts-$outPts
                $netDelta=$rawDelta-$hitCost
                [void]$transferRows.Add([pscustomobject]@{
                    entry=$id;team_name=$teamName;manager_name=$managerName;cohorts=$cohortTypes;transfer_gw=$transferEvent;horizon_gws=$horizon
                    transfers_count=$grp.Count;hit_cost=$hitCost;incoming_points=$inPts;outgoing_points=$outPts;raw_delta=$rawDelta;net_delta_after_hit=$netDelta
                    successful_hit=if($hitCost -gt 0){($netDelta -gt 0)}else{$null}
                })
            }
        }
    }
}

# Export core ledgers.
@($gwRows) | Export-Csv (Join-Path $processed 'manager_gameweek_history.csv') -NoTypeInformation -Encoding UTF8
@($pedigreeRows) | Export-Csv (Join-Path $processed 'manager_pedigree.csv') -NoTypeInformation -Encoding UTF8
@($transferRows) | Export-Csv (Join-Path $processed 'manager_transfer_alpha.csv') -NoTypeInformation -Encoding UTF8
@($rawTransferRows) | Export-Csv (Join-Path $processed 'manager_transfer_events.csv') -NoTypeInformation -Encoding UTF8
@($chipRows) | Export-Csv (Join-Path $processed 'manager_chip_history.csv') -NoTypeInformation -Encoding UTF8
@($pickRows) | Export-Csv (Join-Path $processed 'manager_recent_captain_chip.csv') -NoTypeInformation -Encoding UTF8

# 5) Current elite ownership + smart-money movement.
function Get-PicksFor([int]$EntryId,[int]$Gw){
    $p=Join-Path (Get-ManagerFolder $EntryId) ("picks_GW{0:D2}.json" -f $Gw)
    if(Test-Path $p){return (Read-JsonSafe $p)}
    return $null
}
function Get-OwnershipRows($Ids,[int]$Gw){
    $counts=@{};$n=0
    foreach($id in @($Ids)){
        $pk=Get-PicksFor ([int]$id) $Gw
        if(-not $pk){continue};$n++
        foreach($x in @($pk.picks)){
            $playerId=[int]$x.element
            if(-not $counts.ContainsKey($playerId)){$counts[$playerId]=0}
            $counts[$playerId]++
        }
    }
    $rows=@()
    foreach($playerId in $counts.Keys){$rows += [pscustomobject]@{player_id=[int]$playerId;name=$pmap[[int]$playerId];count=[int]$counts[$playerId];sample=$n;pct=if($n -gt 0){[math]::Round(100.0*$counts[$playerId]/$n,1)}else{0}}}
    return @($rows)
}

$eliteIds=@($memberships | Where-Object {$_.cohort_type -eq 'ELITE_OVERALL'} | Sort-Object cohort_rank | Select-Object -First ([int]$config.track_overall_top_n) | ForEach-Object {[int]$_.entry})
$privateIds=@($memberships | Where-Object {$_.cohort_type -eq 'PRIVATE_TOP'} | ForEach-Object {[int]$_.entry} | Select-Object -Unique)
$smart=[ordered]@{gw=$lockedGw;elite_sample=0;private_sample=0;elite_buys=@();elite_sells=@();private_buys=@();private_sells=@();note=if($lockedGw -le 1){'Movement baseline begins after GW1; no fake smart-money signal is created from initial squads.'}else{$null}}
if($lockedGw -gt 1){
    foreach($bundle in @(
        [pscustomobject]@{name='elite';ids=$eliteIds},
        [pscustomobject]@{name='private';ids=$privateIds}
    )){
        $curr=Get-OwnershipRows $bundle.ids $lockedGw
        $prev=if($lockedGw -gt 1){Get-OwnershipRows $bundle.ids ($lockedGw-1)}else{@()}
        $prevMap=@{};foreach($r in @($prev)){$prevMap[[int]$r.player_id]=$r}
        $moves=@()
        foreach($r in @($curr)){
            $pp=0;if($prevMap.ContainsKey([int]$r.player_id)){$pp=[double]$prevMap[[int]$r.player_id].pct}
            $delta=[math]::Round([double]$r.pct-$pp,1)
            $moves += [pscustomobject]@{player_id=$r.player_id;name=$r.name;ownership_pct=$r.pct;previous_pct=$pp;delta_pp=$delta;sample=$r.sample}
        }
        # Include players fully sold out of the cohort.
        $currIds=@($curr | ForEach-Object {[int]$_.player_id})
        foreach($r in @($prev | Where-Object {$currIds -notcontains [int]$_.player_id})){
            $moves += [pscustomobject]@{player_id=$r.player_id;name=$r.name;ownership_pct=0;previous_pct=$r.pct;delta_pp=-[double]$r.pct;sample=$r.sample}
        }

        # Transfer counts this GW among the same managers.
        $tin=@{};$tout=@{}
        foreach($id in @($bundle.ids)){
            $d=$managerData[[int]$id];if(-not $d){continue}
            foreach($tr in @($d.transfers | Where-Object {[int]$_.event -eq $lockedGw})){
                $ii=[int]$tr.element_in;$oo=[int]$tr.element_out
                if(-not $tin.ContainsKey($ii)){$tin[$ii]=0};$tin[$ii]++
                if(-not $tout.ContainsKey($oo)){$tout[$oo]=0};$tout[$oo]++
            }
        }
        foreach($mv in $moves){
            $ii=[int]$mv.player_id
            $transferInCount=if($tin.ContainsKey($ii)){$tin[$ii]}else{0}
            $transferOutCount=if($tout.ContainsKey($ii)){$tout[$ii]}else{0}
            $mv | Add-Member -NotePropertyName transfers_in -NotePropertyValue $transferInCount
            $mv | Add-Member -NotePropertyName transfers_out -NotePropertyValue $transferOutCount
        }
        $buys=@($moves | Where-Object {$_.delta_pp -gt 0 -or $_.transfers_in -ge [int]$config.smart_money_min_transfer_count} | Sort-Object @{Expression='transfers_in';Descending=$true},@{Expression='delta_pp';Descending=$true} | Select-Object -First 10)
        $sells=@($moves | Where-Object {$_.delta_pp -lt 0 -or $_.transfers_out -ge [int]$config.smart_money_min_transfer_count} | Sort-Object @{Expression='transfers_out';Descending=$true},@{Expression='delta_pp';Descending=$false} | Select-Object -First 10)
        if($bundle.name -eq 'elite'){
            $smart.elite_sample=if($curr.Count -gt 0){[int]$curr[0].sample}else{0};$smart.elite_buys=$buys;$smart.elite_sells=$sells
        }else{
            $smart.private_sample=if($curr.Count -gt 0){[int]$curr[0].sample}else{0};$smart.private_buys=$buys;$smart.private_sells=$sells
        }
    }
}
Write-JsonUtf8 $smart (Join-Path $current 'smart_money.json') 40

# 6) Manager skill/profile scores. Deliberately confidence-capped early in the season.
foreach($id in $uniqueIds){
    $d=$managerData[$id];if(-not $d -or -not $d.history){continue}
    $hist=@($d.history.current | Sort-Object event)
    if($hist.Count -eq 0){continue}
    $latest=$hist[-1]
    $g=[int]$latest.event
    $rankQuality=50
    if($latest.overall_rank -and [int]$latest.overall_rank -gt 0){$rankQuality=[math]::Round(100.0*(1.0-[math]::Min(1.0,[double]$latest.overall_rank/[double]$totalPlayers)),1)}
    $momentum=50
    $back=$hist | Where-Object {[int]$_.event -eq [math]::Max(1,$g-3)} | Select-Object -First 1
    if($back -and $back.overall_rank -and $latest.overall_rank -and [int]$latest.overall_rank -gt 0 -and [int]$back.overall_rank -gt 0){
        $m=[math]::Log10([double]$back.overall_rank/[double]$latest.overall_rank)
        $momentum=[math]::Max(0,[math]::Min(100,[math]::Round(50+25*$m,1)))
    }
    $ped=@($pedigreeRows | Where-Object {[int]$_.entry -eq $id})
    $pedScore=50;if($ped.Count -gt 0){$pedScore=[math]::Round((($ped | Measure-Object pedigree_score -Average).Average),1)}
    $ta3=@($transferRows | Where-Object {[int]$_.entry -eq $id -and [int]$_.horizon_gws -eq 3})
    $transferAlphaScore=50;$avgAlpha=$null
    if($ta3.Count -gt 0){$avgAlpha=[math]::Round((($ta3 | Measure-Object net_delta_after_hit -Average).Average),2);$transferAlphaScore=[math]::Max(0,[math]::Min(100,[math]::Round(50+5*$avgAlpha,1)))}
    $hits3=@($ta3 | Where-Object {[int]$_.hit_cost -gt 0})
    $hitScore=50;$hitAvg=$null
    if($hits3.Count -gt 0){$hitAvg=[math]::Round((($hits3 | Measure-Object net_delta_after_hit -Average).Average),2);$hitScore=[math]::Max(0,[math]::Min(100,[math]::Round(50+5*$hitAvg,1)))}
    $cp=@($pickRows | Where-Object {[int]$_.entry -eq $id -and $_.captain_hindsight_efficiency -ne $null})
    $captainScore=50
    if($cp.Count -gt 0){$captainScore=[math]::Round((($cp | Measure-Object captain_hindsight_efficiency -Average).Average),1)}

    $totalTransfers=(($hist | Measure-Object event_transfers -Sum).Sum);if($totalTransfers -eq $null){$totalTransfers=0}
    $hitWeeks=@($hist | Where-Object {[int]$_.event_transfers_cost -gt 0}).Count
    $noTransferWeeks=@($hist | Where-Object {[int]$_.event_transfers -eq 0}).Count
    $tpg=[math]::Round([double]$totalTransfers/[math]::Max(1,$hist.Count),2)
    $hitRate=[math]::Round([double]$hitWeeks/[math]::Max(1,$hist.Count),2)
    $noTransferRate=[math]::Round([double]$noTransferWeeks/[math]::Max(1,$hist.Count),2)

    # Current template similarity vs elite modal ownership.
    $similarity=$null
    if($lockedGw -gt 0 -and $eliteIds.Count -gt 0){
        $own=Get-OwnershipRows $eliteIds $lockedGw
        $templateIds=@($own | Sort-Object pct -Descending | Select-Object -First 15 | ForEach-Object {[int]$_.player_id})
        $pk=Get-PicksFor $id $lockedGw
        if($pk){
            $mine=@($pk.picks | ForEach-Object {[int]$_.element})
            $overlap=@($mine | Where-Object {$templateIds -contains $_}).Count
            $similarity=[math]::Round(100.0*$overlap/15.0,1)
        }
    }

    # Kneejerk proxy: buys of a player immediately after an 8+ point GW.
    $chase=0;$eligible=0
    foreach($tr in @($d.transfers)){
        $eg=[int]$tr.event;if($eg -le 1){continue}
        $playerId=[int]$tr.element_in
        if($eventPoints.ContainsKey($eg-1) -and $eventPoints[$eg-1].ContainsKey($playerId)){
            $eligible++;if([int]$eventPoints[$eg-1][$playerId] -ge 8){$chase++}
        }
    }
    $chaseRate=$null;if($eligible -gt 0){$chaseRate=[math]::Round([double]$chase/$eligible,2)}

    # Population-integrity layer. These are uncertain research strata, never
    # definitive claims that a manager is a bot, casual, skilled or irrational.
    $observedGwCount=$hist.Count
    $transferWeeks=@($hist | Where-Object {[int]$_.event_transfers -gt 0}).Count
    $chipCount=@($d.history.chips).Count
    $managerPickRows=@($pickRows | Where-Object {[int]$_.entry -eq $id} | Sort-Object gw)
    $captainChanges=0;$lastCaptain=$null
    foreach($cpRow in $managerPickRows){
        if($lastCaptain -ne $null -and $cpRow.captain_id -ne $null -and [int]$cpRow.captain_id -ne [int]$lastCaptain){$captainChanges++}
        if($cpRow.captain_id -ne $null){$lastCaptain=[int]$cpRow.captain_id}
    }
    $populationStatus='INSUFFICIENT_EVIDENCE';$populationConfidence=[math]::Min(40,10+5*$observedGwCount)
    if($observedGwCount -ge 5){
        if($noTransferRate -ge 0.85 -and $chipCount -eq 0 -and $captainChanges -le 1){$populationStatus='INACTIVE_POSSIBLE';$populationConfidence=[math]::Min(80,35+5*$observedGwCount)}
        elseif($noTransferRate -ge 0.60 -and $transferWeeks -le [math]::Max(1,[math]::Floor($observedGwCount*0.35))){$populationStatus='LOW_ACTIVITY';$populationConfidence=[math]::Min(75,30+5*$observedGwCount)}
        else{$populationStatus='ACTIVE_OBSERVED';$populationConfidence=[math]::Min(90,40+5*$observedGwCount)}
    }
    $timingValues=@()
    foreach($tr2 in @($d.transfers)){
        $tc=Get-TransferTemporalAttribution $tr2
        if($tc.temporal_attribution_status -eq 'CONSISTENT' -and $tc.hours_before_api_deadline -ne $null){$timingValues += [double]$tc.hours_before_api_deadline}
    }
    $timingStd=$null
    if($timingValues.Count -ge 2){
        $avgTiming=(($timingValues | Measure-Object -Average).Average);$sumSq=0.0
        foreach($tv in $timingValues){$sumSq += [math]::Pow(([double]$tv-[double]$avgTiming),2)}
        $timingStd=[math]::Round([math]::Sqrt($sumSq/[double]$timingValues.Count),2)
    }
    $automationSignal='NONE';$automationConfidence=0
    if($observedGwCount -ge 8 -and $timingValues.Count -ge 6 -and $timingStd -ne $null -and $timingStd -le 0.08){$automationSignal='MODERATE_PATTERN';$automationConfidence=60}
    elseif($observedGwCount -ge 6 -and $timingValues.Count -ge 4 -and $timingStd -ne $null -and $timingStd -le 0.20){$automationSignal='WEAK_PATTERN';$automationConfidence=45}
    $decisionBehaviorStratum='MIXED_OR_UNKNOWN'
    if($similarity -ne $null -and $similarity -ge 85){$decisionBehaviorStratum='TEMPLATE_DOMINANT'}
    elseif($chaseRate -ne $null -and $chaseRate -ge 0.55){$decisionBehaviorStratum='REACTIVE_POST_HAUL'}
    elseif($hitRate -ge 0.25 -or $tpg -ge 1.3){$decisionBehaviorStratum='HIGH_ACTIVITY_AGGRESSIVE'}
    elseif($noTransferRate -ge 0.35){$decisionBehaviorStratum='PATIENT_LOW_TURNOVER'}
    elseif($similarity -ne $null -and $similarity -lt 60){$decisionBehaviorStratum='LOW_TEMPLATE_CONVERGENCE'}
    $trainingStatus='OBSERVE_ONLY'
    if($observedGwCount -ge 5 -and $populationStatus -eq 'ACTIVE_OBSERVED' -and $automationSignal -ne 'MODERATE_PATTERN'){$trainingStatus='ELIGIBLE_STRATIFIED'}

    $archetype='BALANCED'
    if($chaseRate -ne $null -and $chaseRate -ge 0.55 -and $avgAlpha -ne $null -and $avgAlpha -le 0){$archetype='KNEEJERKER'}
    elseif($hitRate -ge 0.25 -or $tpg -ge 1.3){$archetype='AGGRESSOR'}
    elseif($similarity -ne $null -and $similarity -ge 75 -and $hitRate -lt 0.12){$archetype='TEMPLATE_GRINDER'}
    elseif($similarity -ne $null -and $similarity -lt 60 -and $momentum -ge 60){$archetype='CONTRARIAN_CLIMBER'}
    elseif($noTransferRate -ge 0.35 -and $avgAlpha -ne $null -and $avgAlpha -gt 1){$archetype='PATIENT_PLANNER'}

    $weights=@(
        [pscustomobject]@{v=$rankQuality;w=0.25},
        [pscustomobject]@{v=$momentum;w=0.20},
        [pscustomobject]@{v=$pedScore;w=0.20},
        [pscustomobject]@{v=$transferAlphaScore;w=0.20},
        [pscustomobject]@{v=$captainScore;w=0.10},
        [pscustomobject]@{v=$hitScore;w=0.05}
    )
    $intel=0;foreach($w in $weights){$intel += [double]$w.v*[double]$w.w}
    $confidence=[math]::Min(95,20 + 10*$hist.Count + 5*$ped.Count + 5*$ta3.Count)
    $membership=@($memberships | Where-Object {[int]$_.entry -eq $id})
    $name=if($d.entry){(([string]$d.entry.player_first_name)+' '+([string]$d.entry.player_last_name)).Trim()}else{[string]($membership | Select-Object -First 1).manager_name}
    $team=if($d.entry){[string]$d.entry.name}else{[string]($membership | Select-Object -First 1).team_name}
    [void]$scoreRows.Add([pscustomobject]@{
        entry=$id;manager_name=$name;team_name=$team;cohorts=(@($membership.cohort_type | Select-Object -Unique)-join '|')
        intelligence_score=[math]::Round($intel,1);confidence_pct=[int]$confidence;archetype=$archetype
        rank_quality=$rankQuality;rank_momentum=$momentum;pedigree=$pedScore;transfer_alpha_score=$transferAlphaScore;avg_3gw_transfer_alpha=$avgAlpha
        hit_score=$hitScore;avg_3gw_hit_alpha=$hitAvg;captain_hindsight_efficiency=$captainScore
        transfers_per_gw=$tpg;hit_week_rate=$hitRate;no_transfer_week_rate=$noTransferRate;elite_template_similarity_pct=$similarity;post_haul_buy_rate=$chaseRate
        population_status=$populationStatus;population_confidence_pct=[int]$populationConfidence;decision_behavior_stratum=$decisionBehaviorStratum;automation_signal=$automationSignal;automation_signal_confidence_pct=$automationConfidence;transfer_timing_std_hours=$timingStd;observed_gameweeks=$observedGwCount;decision_process_training_status=$trainingStatus
        population_guardrail='Population classes are uncertain behavioral strata. AUTOMATION_PATTERN is not proof of a bot; rank is never used by itself to classify decision-process integrity.'
    })
}
@($scoreRows) | Sort-Object intelligence_score -Descending | Export-Csv (Join-Path $processed 'manager_scores.csv') -NoTypeInformation -Encoding UTF8

$populationRows=@($scoreRows | Select-Object entry,manager_name,team_name,cohorts,observed_gameweeks,population_status,population_confidence_pct,decision_behavior_stratum,automation_signal,automation_signal_confidence_pct,transfer_timing_std_hours,decision_process_training_status,population_guardrail)
@($populationRows) | Export-Csv (Join-Path $processed 'manager_population_integrity.csv') -NoTypeInformation -Encoding UTF8
$populationMix=@();foreach($pg in @($scoreRows | Group-Object population_status)){$populationMix += [pscustomobject]@{population_status=$pg.Name;count=$pg.Count}}
$stratumMix=@();foreach($sg in @($scoreRows | Group-Object decision_behavior_stratum)){$stratumMix += [pscustomobject]@{decision_behavior_stratum=$sg.Name;count=$sg.Count}}
$temporalMismatchCount=@($rawTransferRows | Where-Object {$_.temporal_attribution_status -eq 'API_EVENT_TIME_MISMATCH'}).Count
Write-JsonUtf8 ([ordered]@{
    generated_at=(Get-Date).ToString('o');manager_count=@($scoreRows).Count;raw_transfer_events=@($rawTransferRows).Count;temporal_mismatch_count=$temporalMismatchCount
    population_status_mix=@($populationMix);decision_behavior_strata=@($stratumMix);training_eligible_count=@($scoreRows | Where-Object {$_.decision_process_training_status -eq 'ELIGIBLE_STRATIFIED'}).Count
    policy='Raw manager frequency is descriptive only. Future Optimal Identity fitting must stratify/reweight manager behavior and must not let the largest casual/template/reactive population dominate simply because it is common.'
    guardrail='Automation signals are weak pattern flags, not bot identifications. Temporal mismatches are data-quality warnings, not silently corrected history.'
}) (Join-Path $processed 'population_skew_summary.json') 60

# Rank movers on latest completed/available history.
$movers=@()
if($lockedGw -gt 1){
    foreach($id in $uniqueIds){
        $rows=@($gwRows | Where-Object {[int]$_.entry -eq $id -and ([int]$_.gw -eq $lockedGw -or [int]$_.gw -eq ($lockedGw-1))} | Sort-Object gw)
        if($rows.Count -ge 2){
            $a=$rows[-2];$b=$rows[-1]
            if($a.overall_rank -and $b.overall_rank){
                $improve=[int]$a.overall_rank-[int]$b.overall_rank
                $movers += [pscustomobject]@{entry=$id;manager_name=$b.manager_name;team_name=$b.team_name;from_rank=[int]$a.overall_rank;to_rank=[int]$b.overall_rank;rank_improvement=$improve;gw_points=[int]$b.points}
            }
        }
    }
}
$topClimbers=@($movers | Sort-Object rank_improvement -Descending | Select-Object -First 8)
$topFallers=@($movers | Sort-Object rank_improvement | Select-Object -First 8)

$hitRows3=@($transferRows | Where-Object {[int]$_.horizon_gws -eq 3 -and [int]$_.hit_cost -gt 0})
$hitLab=[ordered]@{sample=$hitRows3.Count;successful=0;success_rate_pct=$null;avg_net_3gw=$null}
if($hitRows3.Count -gt 0){
    $succ=@($hitRows3 | Where-Object {$_.successful_hit -eq $true}).Count
    $hitLab.successful=$succ
    $hitLab.success_rate_pct=[math]::Round(100.0*$succ/$hitRows3.Count,1)
    $hitLab.avg_net_3gw=[math]::Round((($hitRows3 | Measure-Object net_delta_after_hit -Average).Average),2)
}

$summary=[ordered]@{
    generated_at=$now.ToString('o')
    status=if($uniqueIds.Count -gt 0){'CONNECTED'}else{'WAITING'}
    latest_locked_gw=$lockedGw
    cohorts=$meta.cohorts
    tracked_managers=$uniqueIds.Count
    elite_overall_count=$eliteIds.Count
    private_top_count=$privateIds.Count
    top_climbers=$topClimbers
    top_fallers=$topFallers
    smart_money=$smart
    hit_lab=$hitLab
    top_manager_profiles=@($scoreRows | Sort-Object intelligence_score -Descending | Select-Object -First 10)
    methodology_note='Manager Intelligence is a strategy/market layer. It never overrides raw football xPts. Locked picks are collected incrementally during a live GW; expensive history/transfer refreshes are deferred until the GW is finished. Transfer/hit alpha is approximate, not causal proof.'
}
Write-JsonUtf8 $summary (Join-Path $current 'summary.json') 60
if($lockedGw -gt 0){Write-JsonUtf8 $summary (Join-Path $snapshots ("manager_intelligence_GW{0:D2}_{1}.json" -f $lockedGw,$stamp)) 60}

$meta.status=if($uniqueIds.Count -gt 0){'CONNECTED'}else{'WAITING'}
$meta.progress_stage='COMPLETE'
$meta.progress_current=$meta.progress_total
$completed=Get-Date
$meta.completed_at_local=$completed.ToString('o')
$meta.duration_seconds=[math]::Round(($completed-$now).TotalSeconds,1)
Write-JsonUtf8 $meta (Join-Path $current '_manager_intelligence_sync_meta.json') 40
if(-not $Quiet){
    Write-Host ("Manager Intelligence [$Mode]: {0} managers across {1} cohort(s) in {2}s." -f $uniqueIds.Count,$meta.cohorts,$meta.duration_seconds) -ForegroundColor Green
    if($lockedGw -eq 0){Write-Host 'No locked Gameweek yet; detailed captain/transfer movement will begin after the deadline.' -ForegroundColor DarkGray}
    elseif(-not $lockedFinished){Write-Host 'Live GW detected: locked picks were collected, while history/transfer refresh was deferred until the GW finishes.' -ForegroundColor DarkGray}
    if($meta.errors.Count -gt 0){Write-Host ("Some optional manager requests failed ({0}); cached data was preserved." -f $meta.errors.Count) -ForegroundColor Yellow}
}
return
