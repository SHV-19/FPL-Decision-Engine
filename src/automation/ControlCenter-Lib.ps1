$ErrorActionPreference = 'Stop'

function Read-JsonSafe([string]$Path) {
    if(-not (Test-Path $Path)){ return $null }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonUtf8($Object,[string]$Path,[int]$Depth=100) {
    $parent=Split-Path -Parent $Path
    if($parent){ New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    # Windows PowerShell/PowerShell caps ConvertTo-Json at depth 100.
    # Several runtime structures legitimately request a higher convenience
    # depth; clamp centrally rather than crashing the worker.
    $effectiveDepth=$Depth
    if($effectiveDepth -gt 100){$effectiveDepth=100}
    if($effectiveDepth -lt 2){$effectiveDepth=2}
    ConvertTo-Json -InputObject $Object -Depth $effectiveDepth | Set-Content -Encoding UTF8 $Path
}

# V3 research functions are optional to core status construction but are
# loaded here when present so every runtime path shares one event contract.
$researchLibPath=Join-Path $PSScriptRoot 'Research-Lib.ps1'
if(Test-Path $researchLibPath){. $researchLibPath}

function Repair-MojibakeText([string]$Text) {
    if([string]::IsNullOrEmpty($Text)){return $Text}
    if($Text -notmatch '[\u00C2\u00C3\u00E2\u00F0]'){return $Text}
    try{
        $cp=[Text.Encoding]::GetEncoding(1252)
        $utf8=New-Object Text.UTF8Encoding($false,$true)
        $bytes=$cp.GetBytes($Text)
        $fixed=$utf8.GetString($bytes)
        $before=[regex]::Matches($Text,'[\u00C2\u00C3\u00E2\u00F0]').Count
        $after=[regex]::Matches($fixed,'[\u00C2\u00C3\u00E2\u00F0]').Count
        if($after -lt $before){return $fixed}
    }catch{}
    return $Text
}

function Repair-ObjectStrings($Value,[int]$Depth=0) {
    if($null -eq $Value -or $Depth -gt 16){return $Value}
    if($Value -is [string]){return (Repair-MojibakeText ([string]$Value))}
    if($Value -is [System.Collections.IDictionary]){
        foreach($key in @($Value.Keys)){
            try{$Value[$key]=Repair-ObjectStrings ($Value[$key]) ($Depth+1)}catch{}
        }
        return $Value
    }
    if($Value -is [System.Collections.IList]){
        for($i=0;$i -lt $Value.Count;$i++){
            try{$Value[$i]=Repair-ObjectStrings ($Value[$i]) ($Depth+1)}catch{}
        }
        return $Value
    }
    if($Value -is [ValueType]){return $Value}
    try{
        foreach($prop in @($Value.PSObject.Properties)){
            try{$prop.Value=Repair-ObjectStrings ($prop.Value) ($Depth+1)}catch{}
        }
    }catch{}
    return $Value
}

function Get-EngineGameweek([string]$Root) {
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if($boot){
        $ev=$boot.events | Where-Object { $_.is_next -eq $true } | Select-Object -First 1
        if(-not $ev){ $ev=$boot.events | Where-Object { $_.is_current -eq $true } | Select-Object -First 1 }
        if(-not $ev){ $ev=$boot.events | Where-Object { $_.finished -ne $true } | Select-Object -First 1 }
        if($ev){ return [int]$ev.id }
    }
    $state=Read-JsonSafe (Join-Path $Root '06_CONFIG\project_state.json')
    if($state -and $state.current_gameweek){ return [int]$state.current_gameweek }
    return 1
}

function Get-LatestLockedGameweek([string]$Root) {
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if(-not $boot){ return 0 }
    $now=[DateTime]::UtcNow
    $locked=@()
    foreach($ev in @($boot.events)){
        try{ if($ev.deadline_time -and $now -ge [DateTime]::Parse($ev.deadline_time).ToUniversalTime()){$locked += $ev} }catch{}
    }
    $last=$locked | Sort-Object id -Descending | Select-Object -First 1
    if($last){return [int]$last.id}
    return 0
}

function Get-FplDeadlinePassed([string]$Root,[int]$Gameweek) {
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if(-not $boot){ return $false }
    $ev=$boot.events | Where-Object { [int]$_.id -eq $Gameweek } | Select-Object -First 1
    if(-not $ev -or -not $ev.deadline_time){ return $false }
    try { return ([DateTime]::UtcNow -ge [DateTime]::Parse($ev.deadline_time).ToUniversalTime()) } catch { return $false }
}

function Sanitize-FileName([string]$Name) {
    $safe=[IO.Path]::GetFileName($Name)
    foreach($c in [IO.Path]::GetInvalidFileNameChars()){ $safe=$safe.Replace([string]$c,'_') }
    return $safe
}


function Get-LocalAgeSeconds($Value) {
    if(-not $Value){return $null}
    try{
        $dt=[DateTimeOffset]::Parse([string]$Value)
        $age=([DateTimeOffset]::Now-$dt).TotalSeconds
        if($age -lt 0){$age=0}
        return [math]::Round($age,0)
    }catch{return $null}
}

function Get-FileTimestamp([string]$Path) {
    try{
        if(Test-Path $Path){return (Get-Item -LiteralPath $Path).LastWriteTime.ToString('o')}
    }catch{}
    return $null
}

function Get-MetaTimestamp($Meta) {
    if(-not $Meta){return $null}
    foreach($name in @('completed_at_local','synced_at_local','private_current_team_synced_at','generated_at')){
        try{
            $p=$Meta.PSObject.Properties[$name]
            if($p -and $p.Value){return [string]$p.Value}
        }catch{}
    }
    return $null
}


function Get-OfficialLiveTeamState([string]$Root,[int]$Gameweek,$Boot,$Fixtures,$PublicMeta) {
    $result=[ordered]@{
        available=$false
        gameweek=$Gameweek
        source='OFFICIAL_FPL_EVENT_LIVE'
        fetched_at=$null
        points=$null
        gross_selected_points=$null
        transfer_cost=0
        bench_points=$null
        captain=$null
        vice_captain=$null
        captain_points=$null
        active_chip=$null
        finished_count=0
        in_play_count=0
        to_play_count=0
        unknown_count=0
        matchday_active=$false
        matchday_started=$false
        fixture_count=0
        finished_fixture_count=0
        players=@()
        automatic_subs=@()
        note='Official live score is calculated from locked picks and the Official FPL event-live feed. Final autosubs/captain promotion can still change after FPL processes fixtures.'
        reason=$null
    }
    try{
        $liveGw=$Gameweek
        try{if($PublicMeta -and $PublicMeta.current_live_event -ne $null){$liveGw=[int]$PublicMeta.current_live_event}}catch{}
        if($liveGw -le 0){$result.reason='No locked/current Gameweek is available yet.';return [pscustomobject]$result}
        $result.gameweek=$liveGw
        try{if($PublicMeta -and $PublicMeta.event_live_fetched_at){$result.fetched_at=[string]$PublicMeta.event_live_fetched_at}}catch{}
        if(-not $result.fetched_at){$result.fetched_at=Get-FileTimestamp (Join-Path $Root '02_DATA\CURRENT\event_live_current.json')}

        $eventLive=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\event_live_current.json')
        if(-not $eventLive -or -not $eventLive.elements){$result.reason='Official FPL event-live cache is not available yet.';return [pscustomobject]$result}
        $pickPath=Join-Path $Root ('02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json' -f $liveGw)
        $lockedPicks=Read-JsonSafe $pickPath
        if(-not $lockedPicks -or -not $lockedPicks.picks -or @($lockedPicks.picks).Count -lt 15){$result.reason=('Locked GW{0} picks are not cached yet.' -f $liveGw);return [pscustomobject]$result}
        if(-not $Boot -or -not $Boot.elements){$result.reason='Official FPL bootstrap cache is unavailable.';return [pscustomobject]$result}

        $elementById=@{};$liveById=@{};$teamShort=@{}
        foreach($el in @($Boot.elements)){try{$elementById[[int]$el.id]=$el}catch{}}
        foreach($le in @($eventLive.elements)){try{$liveById[[int]$le.id]=$le}catch{}}
        foreach($tm in @($Boot.teams)){try{$teamShort[[int]$tm.id]=[string]$tm.short_name}catch{}}

        $fixtureByTeam=@{};$eventFixtures=@()
        foreach($fx in @($Fixtures)){
            try{
                if($fx.event -eq $null -or [int]$fx.event -ne $liveGw){continue}
                $eventFixtures += $fx
                foreach($tid in @([int]$fx.team_h,[int]$fx.team_a)){
                    if(-not $fixtureByTeam.ContainsKey($tid)){$fixtureByTeam[$tid]=@()}
                    $fixtureByTeam[$tid]=@($fixtureByTeam[$tid])+@($fx)
                }
            }catch{}
        }
        $result.fixture_count=$eventFixtures.Count
        $finishedFixtures=0;$startedAny=$false
        foreach($fx in $eventFixtures){
            $fxFinished=($fx.finished -eq $true -or $fx.finished_provisional -eq $true)
            if($fxFinished){$finishedFixtures++}
            if($fx.started -eq $true){$startedAny=$true}
        }
        $result.finished_fixture_count=$finishedFixtures
        $result.matchday_started=$startedAny
        $result.matchday_active=($startedAny -and $eventFixtures.Count -gt 0 -and $finishedFixtures -lt $eventFixtures.Count)

        $autos=@();try{if($lockedPicks.automatic_subs){$autos=@($lockedPicks.automatic_subs)}}catch{}
        $effectiveMultiplier=@{}
        foreach($ep in @($lockedPicks.picks)){try{$effectiveMultiplier[[int]$ep.element]=[int]$ep.multiplier}catch{}}
        foreach($sub in $autos){
            try{
                $outId=[int]$sub.element_out;$inId=[int]$sub.element_in
                if($effectiveMultiplier.ContainsKey($outId)){$effectiveMultiplier[$outId]=0}
                if($effectiveMultiplier.ContainsKey($inId)){$effectiveMultiplier[$inId]=1}
            }catch{}
        }

        $gross=0.0;$bench=0.0;$rows=@();$captainName=$null;$viceName=$null;$captainPts=$null
        foreach($pk in @($lockedPicks.picks | Sort-Object position)){
            $eid=[int]$pk.element
            $el=if($elementById.ContainsKey($eid)){$elementById[$eid]}else{$null}
            $lv=if($liveById.ContainsKey($eid)){$liveById[$eid]}else{$null}
            $pts=0.0;$mins=0;$played=$false
            try{if($lv -and $lv.stats.total_points -ne $null){$pts=[double]$lv.stats.total_points}}catch{}
            try{if($lv -and $lv.stats.minutes -ne $null){$mins=[int]$lv.stats.minutes}}catch{}
            try{if($lv -and $lv.stats.played -eq $true){$played=$true}}catch{}
            if($mins -gt 0){$played=$true}
            $mult=0
            try{if($effectiveMultiplier.ContainsKey($eid)){$mult=[int]$effectiveMultiplier[$eid]}else{$mult=[int]$pk.multiplier}}catch{}
            $pos=0;try{$pos=[int]$pk.position}catch{}
            if($mult -gt 0){$gross += ($pts*$mult)}
            if($pos -gt 11){$bench += $pts}

            $teamId=$null
            try{if($el){$teamId=[int]$el.team}}catch{}
            $teamFixtures=@()
            if($teamId -ne $null -and $fixtureByTeam.ContainsKey($teamId)){$teamFixtures=@($fixtureByTeam[$teamId])}
            $hasInPlay=$false;$hasToPlay=$false;$allFinished=($teamFixtures.Count -gt 0)
            foreach($fx in $teamFixtures){
                $started=($fx.started -eq $true)
                $finished=($fx.finished -eq $true -or $fx.finished_provisional -eq $true)
                if($started -and -not $finished){$hasInPlay=$true}
                if(-not $started){$hasToPlay=$true}
                if(-not $finished){$allFinished=$false}
            }
            $state='UNKNOWN'
            if($hasInPlay){$state='IN_PLAY'}elseif($hasToPlay){$state='TO_PLAY'}elseif($allFinished){$state='FINISHED'}elseif($played){$state='FINISHED'}
            if($pos -le 11){
                switch($state){
                    'FINISHED' {$result.finished_count++}
                    'IN_PLAY' {$result.in_play_count++}
                    'TO_PLAY' {$result.to_play_count++}
                    default {$result.unknown_count++}
                }
            }
            $name=if($el){[string]$el.web_name}else{[string]$eid}
            if($pk.is_captain -eq $true){$captainName=$name;$captainPts=[math]::Round($pts*$mult,0)}
            if($pk.is_vice_captain -eq $true){$viceName=$name}
            $rows += [pscustomobject]@{
                element=$eid;name=$name;club=if($teamId -ne $null -and $teamShort.ContainsKey($teamId)){$teamShort[$teamId]}else{$null};position=$pos;multiplier=$mult;points=[math]::Round($pts,0);selected_points=[math]::Round($pts*$mult,0);minutes=$mins;state=$state;is_captain=($pk.is_captain -eq $true);is_vice_captain=($pk.is_vice_captain -eq $true)
            }
        }
        $cost=0
        try{if($lockedPicks.entry_history -and $lockedPicks.entry_history.event_transfers_cost -ne $null){$cost=[int]$lockedPicks.entry_history.event_transfers_cost}}catch{}
        $result.available=$true
        $result.points=[math]::Round(($gross-$cost),0)
        $result.gross_selected_points=[math]::Round($gross,0)
        $result.transfer_cost=$cost
        $result.bench_points=[math]::Round($bench,0)
        $result.captain=$captainName
        $result.vice_captain=$viceName
        $result.captain_points=$captainPts
        try{$result.active_chip=[string]$lockedPicks.active_chip}catch{}
        $result.players=@($rows)
        $result.automatic_subs=@($autos)
        return [pscustomobject]$result
    }catch{
        $result.reason=$_.Exception.Message
        return [pscustomobject]$result
    }
}

function Get-ControlCenterStatus([string]$Root) {
    $dash=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\dashboard_state.json')
    if(-not $dash){ $dash=[pscustomobject]@{ season='2026/27'; gameweek=(Get-EngineGameweek $Root); summary=[pscustomobject]@{}; decision=[pscustomobject]@{}; squad=@(); market=[pscustomobject]@{}; rivals=[pscustomobject]@{rows=@()}; alerts=@(); history=@() } }

    $conn=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
    $entry=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\entry.json')
    $syncMeta=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json')
    $publicMeta=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\_sync_meta.json')
    $liveMeta=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\_livefpl_sync_meta.json')
    $liveTeam=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\live_team.json')
    $livePrices=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\prices.json')
    $liveTransfers=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\top_transfers.json')
    $liveElite=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\elite.json')
    $livePlanner=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\planner_snapshot.json')
    $miSummary=Read-JsonSafe (Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE\CURRENT\summary.json')
    $miMeta=Read-JsonSafe (Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE\CURRENT\_manager_intelligence_sync_meta.json')
    $syncStatusPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
    $syncRun=Read-JsonSafe $syncStatusPath
    $leagueRefreshRun=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_league_refresh.json')
    $leagueIntelRun=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_league_intelligence.json')
    $closeStatePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_close_gameweek.json'
    $closeGameweekRun=Read-JsonSafe $closeStatePath
    if($closeGameweekRun -and ([string]$closeGameweekRun.status).ToUpperInvariant() -eq 'CLOSING'){
        $closeWorkerAlive=$false
        $closeStartupGrace=$false
        try{
            if($closeGameweekRun.process_id){
                $closeWorkerAlive=($null -ne (Get-Process -Id ([int]$closeGameweekRun.process_id) -ErrorAction SilentlyContinue))
            }else{
                $closeHeartbeat=$null
                try{if($closeGameweekRun.heartbeat_at_local){$closeHeartbeat=[datetime]::Parse([string]$closeGameweekRun.heartbeat_at_local)}}catch{}
                if($closeHeartbeat -and ((Get-Date)-$closeHeartbeat).TotalSeconds -lt 12){$closeStartupGrace=$true}
            }
        }catch{$closeWorkerAlive=$false}
        if(-not $closeWorkerAlive -and -not $closeStartupGrace){
            # v2.8.6: receipts remain authoritative. If the worker committed the
            # archive before its final status write, recover SUCCESS instead of
            # falsely telling the user the close failed.
            $receipt=$null
            try{
                $gwNumber=[int]$closeGameweekRun.gameweek
                if($gwNumber -gt 0){
                    $receiptPath=Join-Path $Root ("08_ARCHIVE\GAMEWEEKS\GW{0:D2}\LATEST_CLOSED_RECEIPT.json" -f $gwNumber)
                    $receipt=Read-JsonSafe $receiptPath
                }
            }catch{$receipt=$null}
            if($receipt -and ([string]$receipt.status).ToUpperInvariant() -eq 'CLOSED' -and ([string]$receipt.run_id) -eq ([string]$closeGameweekRun.run_id)){
                $closeRecovered=[ordered]@{
                    status='SUCCESS';run_id=$closeGameweekRun.run_id;process_id=$closeGameweekRun.process_id;gameweek=$closeGameweekRun.gameweek;stage='COMPLETE'
                    progress_current=5;progress_total=5;progress_percent=100;started_at_local=$closeGameweekRun.started_at_local;heartbeat_at_local=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');completed_at_local=if($receipt.completed_at){[string]$receipt.completed_at}else{(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')}
                    duration_seconds=$closeGameweekRun.duration_seconds;message=("GW{0:D2} CLOSED. Recovered from durable close receipt." -f ([int]$closeGameweekRun.gameweek));review_pack=$receipt.review_pack;archive_path=$receipt.archive_path;error=$null;warnings=@($receipt.warnings)
                }
                try{Write-JsonUtf8 $closeRecovered $closeStatePath 50}catch{}
                $closeGameweekRun=[pscustomobject]$closeRecovered
            }else{
                $closeNow=Get-Date
                $closeStarted=$null
                try{if($closeGameweekRun.started_at_local){$closeStarted=[datetime]::Parse([string]$closeGameweekRun.started_at_local)}}catch{}
                $closeDuration=$null
                if($closeStarted){$closeDuration=[math]::Round(($closeNow-$closeStarted).TotalSeconds,1);if($closeDuration -lt 0){$closeDuration=$null}}
                $closeDiagnostic='Background close worker is no longer running.'
                try{
                    $closeErrLog=Join-Path $Root '04_OUTPUT\DASHBOARD\close_gameweek_stderr.log'
                    if(Test-Path $closeErrLog){
                        $closeTail=@(Get-Content -LiteralPath $closeErrLog -Tail 8 -ErrorAction SilentlyContinue | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)}) -join ' | '
                        if($closeTail){
                            if($closeTail.Length -gt 700){$closeTail=$closeTail.Substring($closeTail.Length-700)}
                            $closeDiagnostic='Close worker stopped. Last PowerShell error: '+$closeTail
                        }
                    }
                }catch{}
                $closeRecovered=[ordered]@{
                    status='FAILED'
                    run_id=$closeGameweekRun.run_id
                    process_id=$closeGameweekRun.process_id
                    gameweek=$closeGameweekRun.gameweek
                    stage='WORKER_STOPPED'
                    progress_current=if($closeGameweekRun.progress_current -ne $null){$closeGameweekRun.progress_current}else{0}
                    progress_total=if($closeGameweekRun.progress_total -ne $null){$closeGameweekRun.progress_total}else{5}
                    progress_percent=if($closeGameweekRun.progress_percent -ne $null){$closeGameweekRun.progress_percent}else{0}
                    started_at_local=$closeGameweekRun.started_at_local
                    heartbeat_at_local=$closeGameweekRun.heartbeat_at_local
                    completed_at_local=$closeNow.ToString('yyyy-MM-dd HH:mm:ss')
                    duration_seconds=$closeDuration
                    message='Gameweek close worker stopped before completion. No CLOSED state is being claimed.'
                    review_pack=$closeGameweekRun.review_pack
                    archive_path=$closeGameweekRun.archive_path
                    error=$closeDiagnostic
                }
                try{Write-JsonUtf8 $closeRecovered $closeStatePath 50}catch{}
                $closeGameweekRun=[pscustomobject]$closeRecovered
            }
        }
    }

    # v2.5 sync jobs run in a separate PowerShell worker so /api/status remains
    # responsive. A SYNCING marker is only stale when the recorded worker PID
    # is no longer alive.
    if($syncRun -and ([string]$syncRun.status).ToUpperInvariant() -eq 'SYNCING'){
        $workerAlive=$false
        $startupGrace=$false
        try{
            if($syncRun.process_id){
                $workerAlive=($null -ne (Get-Process -Id ([int]$syncRun.process_id) -ErrorAction SilentlyContinue))
            } elseif(([string]$syncRun.current_source).ToUpperInvariant() -eq 'STARTING'){
                # v2.5.1: parent writes STARTING before the process exists.
                # Allow a short launch grace period rather than instantly
                # converting a legitimate startup into PARTIAL/RECOVERED.
                $hb=$null
                try{
                    if($syncRun.heartbeat_at_local){$hb=[datetime]::Parse([string]$syncRun.heartbeat_at_local)}
                }catch{}
                if($hb -and ((Get-Date)-$hb).TotalSeconds -lt 12){$startupGrace=$true}
            }
        }catch{$workerAlive=$false}

        if(-not $workerAlive -and -not $startupGrace){
            $now=Get-Date
            $started=$null
            try{
                if($syncRun.started_at_local){
                    $started=[datetime]::Parse([string]$syncRun.started_at_local)
                }
            }catch{}
            $duration=$null
            if($started){
                $duration=[math]::Round(($now-$started).TotalSeconds,1)
                if($duration -lt 0){$duration=$null}
            }

            $recovered=[ordered]@{
                status='PARTIAL'
                mode=if($syncRun.mode){$syncRun.mode}else{'UNKNOWN'}
                run_id=$syncRun.run_id
                process_id=$syncRun.process_id
                started_at_local=if($syncRun.started_at_local){[string]$syncRun.started_at_local}else{$null}
                completed_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
                heartbeat_at_local=$syncRun.heartbeat_at_local
                duration_seconds=$duration
                current_source=$null
                sources=@($syncRun.sources)
                recovered_stale_sync=$true
                recovered_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
                summary='Previous background sync worker is no longer running. The stale SYNCING marker was cleared automatically and data already fetched was retained.'
            }
            try{Write-JsonUtf8 $recovered $syncStatusPath 40}catch{}
            $syncRun=[pscustomobject]$recovered
        }
    }

    $connectRun=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_connect.json')
    $gw=Get-EngineGameweek $Root

    $summary=[ordered]@{}
    if($dash.summary){
        foreach($p in $dash.summary.PSObject.Properties){ $summary[$p.Name]=$p.Value }
    }
    if($entry){
        $summary['team_name']=$entry.name
        $summary['rank']=$entry.summary_overall_rank
        $summary['points']=$entry.summary_overall_points
        if($entry.summary_event_points -ne $null){$summary['event_points']=$entry.summary_event_points}
        if($publicMeta -and $publicMeta.current_live_event){$summary['event_points_gameweek']=[int]$publicMeta.current_live_event}
        if($entry.last_deadline_value -ne $null){ $summary['team_value_m']=[math]::Round([double]$entry.last_deadline_value/10.0,1) }
        if($entry.last_deadline_bank -ne $null){ $summary['bank_m']=[math]::Round([double]$entry.last_deadline_bank/10.0,1) }
        $summary['connection']='CONNECTED'
        $summary['team_id']=$entry.id
    } elseif($conn -and $conn.team_id) {
        $summary['connection']='CONFIGURED_NOT_SYNCED'
        $summary['team_id']=$conn.team_id
    } else {
        $summary['connection']='NOT_CONNECTED'
    }

    $shots=(Get-ChildItem (Join-Path $Root '_DROP_SCREENSHOTS_HERE') -File -ErrorAction SilentlyContinue | Where-Object { @('.png','.jpg','.jpeg','.webp','.gif') -contains $_.Extension.ToLower() }).Count
    $updates=(Get-ChildItem (Join-Path $Root '_INCOMING_RELEASES') -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count
    $latestPack=Get-ChildItem (Join-Path $Root '04_OUTPUT\UPLOAD_PACKS') -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $latestReview=Get-ChildItem (Join-Path $Root '04_OUTPUT\REVIEW_PACKS') -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $privateLeagues=@()
    $leaguesPath=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\discovered_private_leagues.json'
    $privateLeaguesObj=Read-JsonSafe $leaguesPath
    if($privateLeaguesObj){ $privateLeagues=@($privateLeaguesObj) }

    # Connected FPL data can override dashboard display state without waiting for a ChatGPT patch.
    # Source labels are only upgraded after a complete 15-player squad is actually built.
    $displaySquad=@($dash.squad)
    $squadSource='MODEL_RECOMMENDATION'
    $squadGameweek=$null
    $squadConfirmedCurrent=$false
    $displayRivals=$dash.rivals
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    $pickObj=$null
    $candidateSquadSource=$null
    $candidateSquadGameweek=$null
    $accountMeta=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json')
    $my=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\my-team.json')
    if($my -and $my.picks -and $accountMeta -and $accountMeta.private_current_team -eq $true){
        $pickObj=$my
        $candidateSquadSource='PRIVATE_CURRENT_TEAM'
        $candidateSquadGameweek=$gw
    } elseif($my -and $my.picks -and @($my.picks).Count -ge 15 -and $accountMeta){
        # Auth can expire independently of the locally cached editable squad.
        # Keep the last successfully authenticated 15-player team as the best
        # available pre-deadline state, but never label it as live-confirmed.
        $pickObj=$my
        $candidateSquadSource='LAST_KNOWN_CURRENT_TEAM'
        try{$candidateSquadGameweek=[int]$accountMeta.private_current_team_gameweek}catch{$candidateSquadGameweek=$gw}
        if(-not $candidateSquadGameweek){$candidateSquadGameweek=$gw}
    }
    $lockedGw=Get-LatestLockedGameweek $Root
    if(-not $pickObj -and $lockedGw -gt 0){
        $pickObj=Read-JsonSafe (Join-Path $Root ('02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json' -f $lockedGw))
        if($pickObj){
            if($lockedGw -lt $gw -and -not (Get-FplDeadlinePassed $Root $gw)){$candidateSquadSource='LAST_LOCKED_FPL_TEAM'}else{$candidateSquadSource='LOCKED_FPL_TEAM'}
            $candidateSquadGameweek=$lockedGw
        }
    }
    if(-not $pickObj){
        $pickObj=Read-JsonSafe (Join-Path $Root ('02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json' -f $gw))
        if($pickObj){$candidateSquadSource='LOCKED_FPL_TEAM';$candidateSquadGameweek=$gw}
    }
    if($pickObj -and $pickObj.picks -and $boot){
        $pmap=@{};$tmap=@{};$shortmap=@{};$posmap=@{}
        foreach($x in $boot.elements){$pmap[[int]$x.id]=$x}
        foreach($x in $boot.teams){$tmap[[int]$x.id]=(Repair-MojibakeText ([string]$x.name));$shortmap[[int]$x.id]=(Repair-MojibakeText ([string]$x.short_name))}
        foreach($x in $boot.element_types){$posmap[[int]$x.id]=$x.singular_name_short}

        # V3 pitch context: deterministic fixture labels from Official FPL team IDs.
        $fixtureByTeam=@{}
        $fixtureRows=@(Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\fixtures.json'))
        foreach($teamObj in @($boot.teams)){
            $tid=[int]$teamObj.id
            $teamFixtures=@($fixtureRows | Where-Object {$_.event -ne $null -and [int]$_.event -eq [int]$gw -and ([int]$_.team_h -eq $tid -or [int]$_.team_a -eq $tid)})
            if($teamFixtures.Count -eq 0){
                $nextEvent=@($fixtureRows | Where-Object {$_.event -ne $null -and [int]$_.event -gt [int]$gw -and ([int]$_.team_h -eq $tid -or [int]$_.team_a -eq $tid)} | Sort-Object {[int]$_.event} | Select-Object -First 1)
                if($nextEvent.Count){$targetEvent=[int]$nextEvent[0].event;$teamFixtures=@($fixtureRows | Where-Object {$_.event -ne $null -and [int]$_.event -eq $targetEvent -and ([int]$_.team_h -eq $tid -or [int]$_.team_a -eq $tid)})}
            }
            $labels=@()
            foreach($fx in $teamFixtures){
                if([int]$fx.team_h -eq $tid){$opp=[int]$fx.team_a;$venue='H'}else{$opp=[int]$fx.team_h;$venue='A'}
                $oppName=$shortmap[$opp];if(-not $oppName){$oppName=$tmap[$opp]}
                if($oppName){$labels += ($oppName+' ('+$venue+')')}
            }
            if($labels.Count){$fixtureByTeam[$tid]=($labels -join ' + ')}
        }

        $actual=@()
        foreach($pk in @($pickObj.picks)){
            $el=$pmap[[int]$pk.element];if(-not $el){continue}
            $role='START';if([int]$pk.position -gt 11){$role='BENCH_'+([int]$pk.position-11)}
            if($pk.is_captain -eq $true){$role+='_C'}elseif($pk.is_vice_captain -eq $true){$role+='_VC'}
            $availability='Available'
            $statusCode=([string]$el.status).ToLowerInvariant()
            if($statusCode -ne 'a'){
                $chance=$null;try{if($el.chance_of_playing_next_round -ne $null){$chance=[int]$el.chance_of_playing_next_round}}catch{}
                if($chance -ne $null){$availability=($chance.ToString()+'% chance')}
                elseif($statusCode -eq 'i'){$availability='Injured'}
                elseif($statusCode -eq 's'){$availability='Suspended'}
                elseif($statusCode -eq 'd'){$availability='Doubt'}
                else{$availability='Unavailable'}
            }
            $signal=if($statusCode -eq 'a'){'KEEP'}else{'MONITOR'}
            $actual += [pscustomobject]@{name=(Repair-MojibakeText ([string]$el.web_name));club=$tmap[[int]$el.team];position=$posmap[[int]$el.element_type];price=[math]::Round([double]$el.now_cost/10.0,1);role=$role;element=[int]$el.id;opponent_label=$fixtureByTeam[[int]$el.team];availability=$availability;news=(Repair-MojibakeText ([string]$el.news));signal=$signal}
        }
        if($actual.Count -eq 15){
            $displaySquad=$actual
            $squadSource=$candidateSquadSource
            $squadGameweek=$candidateSquadGameweek
            $squadConfirmedCurrent=($candidateSquadSource -eq 'PRIVATE_CURRENT_TEAM' -and [int]$candidateSquadGameweek -eq [int]$gw)
        }
    }

    # Repair legacy display names from older Windows PowerShell HTTP decoding.
    foreach($sp in @($displaySquad)){
        try{$sp.name=Repair-MojibakeText ([string]$sp.name)}catch{}
        try{$sp.club=Repair-MojibakeText ([string]$sp.club)}catch{}
    }

    # PRE-DEADLINE LIVE SUMMARY OVERRIDE
    # The public /entry endpoint exposes last-deadline bank/value, which is stale
    # before GW1 and after unsaved/new transfers. When authenticated my-team is
    # available, it is the source of truth for the editable squad header.
    if($squadSource -in @('PRIVATE_CURRENT_TEAM','LAST_KNOWN_CURRENT_TEAM') -and $my){
        $liveBank=$null
        $liveValue=$null
        $liveLimit=$null
        $liveMade=$null

        try{
            if($my.transfers -and $my.transfers.bank -ne $null){
                $liveBank=[math]::Round([double]$my.transfers.bank/10.0,1)
            }
        }catch{}
        try{
            if($my.transfers -and $my.transfers.value -ne $null){
                $liveValue=[math]::Round([double]$my.transfers.value/10.0,1)
            }
        }catch{}
        try{if($my.transfers -and $my.transfers.limit -ne $null){$liveLimit=$my.transfers.limit}}catch{}
        try{if($my.transfers -and $my.transfers.made -ne $null){$liveMade=[int]$my.transfers.made}}catch{}

        # FPL's "value" semantics can vary by endpoint/season. For the dashboard
        # TEAM VALUE card we want current squad purchase-list cost, which is
        # unambiguous and matches the Transfers page: sum current now_cost.
        if($displaySquad.Count -ge 15){
            $currentSquadCost=[math]::Round((($displaySquad | Measure-Object -Property price -Sum).Sum),1)
            if($currentSquadCost -gt 0){$liveValue=$currentSquadCost}
        }

        if($liveBank -ne $null){$summary['bank_m']=$liveBank}
        if($liveValue -ne $null){$summary['team_value_m']=$liveValue}

        # Transfer-window truthfulness.
        # FPL uses a null/absent limit in some states. That must NEVER leak an
        # old dashboard value such as "Unlimited" into GW2+.
        $preSeasonUnlimited=($lockedGw -eq 0 -and $gw -eq 1)
        $activeUnlimitedChip=$false
        try{
            if($my.active_chip){
                $chipName=([string]$my.active_chip).ToLowerInvariant()
                if($chipName -match 'wildcard|freehit|free_hit'){$activeUnlimitedChip=$true}
            }
        }catch{}
        try{
            foreach($chip in @($my.chips)){
                $chipName=([string]$chip.name).ToLowerInvariant()
                $chipState=([string]$chip.status_for_entry).ToLowerInvariant()
                if(-not $chipState){$chipState=([string]$chip.status).ToLowerInvariant()}
                if($chipName -match 'wildcard|freehit|free_hit' -and $chipState -eq 'active'){
                    $activeUnlimitedChip=$true
                }
            }
        }catch{}

        $summary['free_transfers_gameweek']=$gw
        if($activeUnlimitedChip){
            $summary['free_transfers']='Unlimited'
            $summary['free_transfers_source']='ACTIVE_CHIP'
        }elseif($preSeasonUnlimited){
            $summary['free_transfers']='Unlimited'
            $summary['free_transfers_source']='GW1_PRE_DEADLINE'
        }elseif($liveLimit -ne $null){
            try{
                $limitInt=[int]$liveLimit
                $madeInt=0
                if($liveMade -ne $null){$madeInt=[int]$liveMade}
                $summary['free_transfers']=[math]::Max(0,$limitInt-$madeInt)
                $summary['free_transfers_source']='PRIVATE_MY_TEAM'
            }catch{
                $summary['free_transfers']='Unavailable'
                $summary['free_transfers_source']='INVALID_PRIVATE_LIMIT'
            }
        }else{
            # Once GW1 has locked, "Unlimited" without a real unlimited chip is
            # false information. Prefer an explicit unavailable state.
            $summary['free_transfers']='Unavailable'
            $summary['free_transfers_source']='PRIVATE_LIMIT_UNAVAILABLE'
        }
    }

    # Never carry a stale Unlimited label beyond the actual GW1 pre-deadline window.
    if($lockedGw -gt 0 -or $gw -gt 1){
        try{
            if(([string]$summary['free_transfers']).ToLowerInvariant() -eq 'unlimited'){
                $summary['free_transfers']='Unavailable'
                $summary['free_transfers_source']='STALE_UNLIMITED_SANITIZED'
            }
        }catch{}
    }
    if(-not $summary.Contains('free_transfers_gameweek')){$summary['free_transfers_gameweek']=$gw}

    # A model/ChatGPT decision is tied to the exact FPL team state it reviewed.
    # Compare stable official FPL element IDs + lineup roles, NOT display names or prices.
    # Real player/captain/vice/starting-XI/bench-order changes still invalidate.
    $displayDecision=$dash.decision
    $decisionStale=$false
    $decisionMatchMode='NONE'

    function Get-NormalizedSquadText([object]$p){
        $n=[string]$p.name
        if($n){
            try{
                $formD=$n.Normalize([Text.NormalizationForm]::FormD)
                $sb=New-Object Text.StringBuilder
                foreach($ch in $formD.ToCharArray()){
                    if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark){
                        [void]$sb.Append($ch)
                    }
                }
                $n=$sb.ToString().Normalize([Text.NormalizationForm]::FormC)
            }catch{}
        }
        return (($n.ToLowerInvariant() -replace '[^a-z0-9]','') + '|' +
                (([string]$p.club).ToLowerInvariant() -replace '[^a-z0-9]','') + '|' +
                ([string]$p.role).ToUpperInvariant())
    }

    if($squadSource -eq 'PRIVATE_CURRENT_TEAM' -and $displaySquad.Count -ge 15 -and $dash.squad){
        $reviewedSquad=@($dash.squad)
        $liveHaveIds=(@($displaySquad | Where-Object {[int]$_.element -gt 0}).Count -eq $displaySquad.Count)
        $reviewedHaveIds=(@($reviewedSquad | Where-Object {[int]$_.element -gt 0}).Count -eq $reviewedSquad.Count)

        if($liveHaveIds -and $reviewedHaveIds){
            $decisionMatchMode='FPL_ELEMENT_ID_AND_ROLE'
            $liveKeys=@($displaySquad | ForEach-Object {
                ('{0}|{1}' -f [int]$_.element,([string]$_.role).ToUpperInvariant())
            } | Sort-Object)
            $reviewedKeys=@($reviewedSquad | ForEach-Object {
                ('{0}|{1}' -f [int]$_.element,([string]$_.role).ToUpperInvariant())
            } | Sort-Object)
        } else {
            $decisionMatchMode='NORMALIZED_NAME_CLUB_ROLE_FALLBACK'
            $liveKeys=@($displaySquad | ForEach-Object {Get-NormalizedSquadText $_} | Sort-Object)
            $reviewedKeys=@($reviewedSquad | ForEach-Object {Get-NormalizedSquadText $_} | Sort-Object)
        }

        if(($liveKeys -join "`n") -ne ($reviewedKeys -join "`n")){
            $decisionStale=$true
            $liveCaptain=$displaySquad | Where-Object {([string]$_.role) -match '_C($|_)'} | Select-Object -First 1
            $liveVice=$displaySquad | Where-Object {([string]$_.role) -match '_VC($|_)'} | Select-Object -First 1
            $displayDecision=[ordered]@{
                transfer='LIVE TEAM CHANGED | DEEP DIVE TO RE-EVALUATE'
                captain=if($liveCaptain){$liveCaptain.name}else{'Unavailable'}
                vice=if($liveVice){$liveVice.name}else{'Unavailable'}
                chip='PENDING CURRENT CALL'
                strategy='LIVE SQUAD AHEAD OF REVIEW'
                confidence=0
                finalized=$false
                reason='Your actual FPL player IDs or lineup roles differ from the last stored decision. Old advice is hidden intentionally. Ask Deep Dive for the current call; required data refreshes automatically.'
            }
        }
    }

    # A finalized decision is also scoped to the Gameweek it was analyzed for.
    # Once FPL rolls the decision window forward (e.g. GW1 is live and the app
    # correctly shows decision GW2), never relabel the old GW1 verdict as "GW2 final".
    $decisionGameweek=$null
    try{if($dash.gameweek){$decisionGameweek=[int]$dash.gameweek}}catch{}
    if($decisionGameweek -and $decisionGameweek -lt $gw){
        $decisionStale=$true
        $decisionMatchMode='OUTDATED_GAMEWEEK'
        $displayDecision=[ordered]@{
            transfer='CURRENT GW CALL | ASK DEEP DIVE'
            captain='Unavailable'
            vice='Unavailable'
            chip='PENDING CURRENT CALL'
            strategy=("GW{0} DECISION WINDOW | DEEP DIVE READY" -f $gw)
            confidence=0
            finalized=$false
            reason=("The stored engine decision belongs to GW{0}. Ask Deep Dive for the current GW{1} call; the question-aware orchestrator refreshes the required sources automatically." -f $decisionGameweek,$gw)
        }
    }

    $squadDisplayStatus='MODEL_RECOMMENDATION'
    $squadDisplayReason='The app is showing the latest model recommendation.'
    $squadNextAction='Uploaded screenshots are read automatically by the next Deep Dive.'
    if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){
        $squadDisplayStatus='LIVE_PRE_DEADLINE'
        $squadDisplayReason='Private local FPL read confirmed the current pre-deadline squad.'
        $squadNextAction='No action required.'
    } elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){
        $squadDisplayStatus='LAST_KNOWN_CURRENT_TEAM'
        $lastTeamStamp=$null
        try{$lastTeamStamp=[string]$accountMeta.private_current_team_last_success_at}catch{}
        if($lastTeamStamp){
            $squadDisplayReason=("Showing the last successfully authenticated 15-player current-team snapshot from {0}. Current-team authentication is no longer live, so changes made after that snapshot cannot be confirmed." -f $lastTeamStamp)
        } else {
            $squadDisplayReason='Showing the last successfully authenticated 15-player current-team snapshot. Current-team authentication is no longer live, so later changes cannot be confirmed.'
        }
        $squadNextAction='Reconnect current-team authentication now. Exact team calls are blocked while the editable squad is only LAST KNOWN.'
    } elseif($squadSource -eq 'LOCKED_FPL_TEAM'){
        $squadDisplayStatus='LIVE_LOCKED'
        $squadDisplayReason=("Official FPL locked picks confirmed all 15 players for GW{0}." -f $squadGameweek)
        $squadNextAction='Locked picks are cached automatically.'
    } elseif($squadSource -eq 'LAST_LOCKED_FPL_TEAM'){
        $squadDisplayStatus='LAST_LOCKED_PRE_DEADLINE'
        $squadDisplayReason=("Showing the last confirmed locked team from GW{0}. It is not confirmation of the editable GW{1} team." -f $squadGameweek,$gw)
        $squadNextAction='Authenticated current-team sync is required to confirm any post-deadline transfers or lineup changes.'
    } elseif(-not (Get-FplDeadlinePassed $Root $gw) -and $shots -gt 0){
        $squadDisplayStatus='SCREENSHOTS_READY_FOR_DEEP_DIVE'
        $squadDisplayReason="$shots screenshot(s) are ready. The next Deep Dive attaches and reads them directly alongside synced FPL evidence."
        $squadNextAction='Open Deep Dive and ask the decision question. No ChatGPT Pack is required.'
    } elseif(-not (Get-FplDeadlinePassed $Root $gw) -and $privateEnabled){
        $squadDisplayStatus='PRIVATE_READ_WAITING'
        $squadDisplayReason='Private pre-deadline read is enabled, but a current live squad was not returned.'
        $squadNextAction='Reconnect auth if needed, or upload a current-team screenshot and ask Deep Dive.'
    } elseif(-not (Get-FplDeadlinePassed $Root $gw)){
        $squadDisplayStatus='MODEL_PRE_DEADLINE'
        $squadDisplayReason='Public FPL does not expose your editable pre-deadline squad. Quick Live Sync can refresh account data, but cannot confirm current picks.'
        $squadNextAction='Either use the optional private pre-deadline read or upload a current-team screenshot and ask Deep Dive.'
    }

    if($privateLeagues.Count -gt 0 -and $conn -and $conn.team_id){
        $primary=$privateLeagues | Sort-Object entry_rank | Select-Object -First 1
        $lf=Read-JsonSafe (Join-Path $Root ("02_DATA\FPL_ACCOUNT\LEAGUES\league_$($primary.id).json"))
        if($lf -and $lf.standings){
            $me=$lf.standings | Where-Object {[int]$_.entry -eq [int]$conn.team_id} | Select-Object -First 1
            $rr=@()
            foreach($row in @($lf.standings | Sort-Object rank | Select-Object -First 25)){
                $gap=$null;if($me){$delta=[int]$row.total-[int]$me.total;if($delta -gt 0){$gap="+$delta"}else{$gap=[string]$delta}}
                $rr += [pscustomobject]@{rank=$row.rank;name=$row.entry_name;manager=$row.player_name;points=$row.total;event_points=$row.event_total;gap=$gap;entry=$row.entry}
            }
            $displayRivals=[pscustomobject]@{status='CONNECTED_MINI_LEAGUE';league=$lf.league.name;rows=$rr}
            if($me){$summary['mini_league_rank']=$me.rank}
        }
    }

    # v2.5.2: build a browser payload for every discovered/tracked league.
    # Previously the UI intentionally exposed only the single "primary" league.
    $rivalLeagues=@()
    $leagueIds=@()
    foreach($pl in @($privateLeagues)){
        try{
            $lid=[int]$pl.id
            if($lid -gt 0 -and $leagueIds -notcontains $lid){$leagueIds += $lid}
        }catch{}
    }
    foreach($tid in @($trackedLeagueIds)){
        try{
            $lid=[int]$tid
            if($lid -gt 0 -and $leagueIds -notcontains $lid){$leagueIds += $lid}
        }catch{}
    }

    foreach($lid in $leagueIds){
        $pl=$privateLeagues | Where-Object {[int]$_.id -eq [int]$lid} | Select-Object -First 1
        $lf=Read-JsonSafe (Join-Path $Root ("02_DATA\FPL_ACCOUNT\LEAGUES\league_$lid.json"))
        $lname=$null
        if($lf -and $lf.league -and $lf.league.name){$lname=[string]$lf.league.name}
        elseif($pl -and $pl.name){$lname=[string]$pl.name}
        else{$lname=("League {0}" -f $lid)}

        $me=$null
        $rows=@()
        if($lf -and $lf.standings){
            $me=$lf.standings | Where-Object {[int]$_.entry -eq [int]$conn.team_id} | Select-Object -First 1
            foreach($row in @($lf.standings | Sort-Object rank)){
                $isMe=([int]$row.entry -eq [int]$conn.team_id)
                $reportedPoints=[int]$row.total
                $resolvedPoints=$reportedPoints
                $pointsSource='OFFICIAL_LEAGUE_ENDPOINT'
                if($isMe -and $summary.Contains('points') -and $summary['points'] -ne $null){
                    $officialAccountPoints=[int]$summary['points']
                    if($officialAccountPoints -ne $reportedPoints){
                        $resolvedPoints=$officialAccountPoints
                        $pointsSource='OFFICIAL_ENTRY_RESOLVED'
                    }
                }
                $gap=$null
                if($me){
                    $selfPoints=[int]$me.total
                    if($summary.Contains('points') -and $summary['points'] -ne $null){$selfPoints=[int]$summary['points']}
                    $delta=$resolvedPoints-$selfPoints
                    if($delta -gt 0){$gap="+$delta"}else{$gap=[string]$delta}
                }
                $rows += [pscustomobject]@{
                    rank=$row.rank
                    name=$row.entry_name
                    manager=$row.player_name
                    points=$resolvedPoints
                    reported_points=$reportedPoints
                    points_source=$pointsSource
                    event_points=$row.event_total
                    gap=$gap
                    entry=$row.entry
                    is_me=$isMe
                }
            }
        }

        $rankHint=$null
        try{if($pl -and $pl.entry_rank -ne $null){$rankHint=[int]$pl.entry_rank}}catch{}
        $rivalLeagues += [pscustomobject]@{
            id=[int]$lid
            name=$lname
            kind=if($pl){'PRIVATE'}else{'TRACKED'}
            cached=($lf -ne $null)
            synced_at=if($lf){$lf.synced_at}else{$null}
            partial_window=if($lf){$lf.partial_window}else{$null}
            pages_fetched=if($lf -and $lf.pages_fetched){@($lf.pages_fetched)}else{@()}
            user_rank=if($me){$me.rank}else{$rankHint}
            user_points=if($summary.Contains('points') -and $summary['points'] -ne $null){$summary['points']}elseif($me){$me.total}else{$null}
            official_user_points=if($summary.Contains('points')){$summary['points']}else{$null}
            feed_points_lag=if($me -and $summary.Contains('points') -and $summary['points'] -ne $null){[int]$summary['points']-[int]$me.total}else{$null}
            league_feed_lagging=if($me -and $summary.Contains('points') -and $summary['points'] -ne $null){([int]$summary['points'] -ne [int]$me.total)}else{$false}
            resolved_user_points_source=if($me -and $summary.Contains('points') -and $summary['points'] -ne $null -and [int]$summary['points'] -ne [int]$me.total){'OFFICIAL_ENTRY_RESOLVED'}else{'OFFICIAL_LEAGUE_ENDPOINT'}
            rows=@($rows)
        }
    }

    $rivalLeagues=@($rivalLeagues | Sort-Object `
        @{Expression={if($_.kind -eq 'PRIVATE'){0}else{1}}}, `
        @{Expression={if($_.user_rank -ne $null){[int]$_.user_rank}else{999999999}}}, `
        @{Expression={$_.name}})


    # v2.6.0 Rival Radar. Uses only cached locked picks; never guesses.
    $rivalIntelLeagues=@()
    $playerNameById=@{}
    if($boot){
        foreach($el in @($boot.elements)){
            try{$playerNameById[[int]$el.id]=[string]$el.web_name}catch{}
        }
    }

    $comparisonGw=$lockedGw
    $selfComparisonPick=$null
    if($comparisonGw -gt 0){
        $selfComparisonPick=Read-JsonSafe (Join-Path $Root ("02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json" -f $comparisonGw))
    }

    $selfStartIds=@();$selfSquadIds=@();$selfCaptainId=$null
    if($selfComparisonPick -and $selfComparisonPick.picks){
        foreach($pk in @($selfComparisonPick.picks)){
            try{
                $eid=[int]$pk.element
                $selfSquadIds += $eid
                if([int]$pk.position -le 11){$selfStartIds += $eid}
                if($pk.is_captain -eq $true){$selfCaptainId=$eid}
            }catch{}
        }
    }

    # Optional Manager Intelligence profile merge.
    $miScoreMap=@{}
    $scoreCsv=Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE\PROCESSED\manager_scores.csv'
    if(Test-Path $scoreCsv){
        try{
            foreach($sr in @(Import-Csv $scoreCsv)){
                try{$miScoreMap[[int]$sr.entry]=$sr}catch{}
            }
        }catch{}
    }

    foreach($league in @($rivalLeagues)){
        $rows=@($league.rows)
        $me=$rows | Where-Object {$_.is_me -eq $true} | Select-Object -First 1
        if(-not $me -and $connTeamId){
            $me=$rows | Where-Object {[int]$_.entry -eq [int]$connTeamId} | Select-Object -First 1
        }

        $movementIntel=Read-JsonSafe (Join-Path $Root ("02_DATA\FPL_ACCOUNT\LEAGUE_INTELLIGENCE\league_{0}.json" -f [int]$league.id))
        $movementMap=@{}
        if($movementIntel -and $movementIntel.movement){
            foreach($moveRow in @($movementIntel.movement)){
                try{$movementMap[[int]$moveRow.entry]=$moveRow}catch{}
            }
        }

        $leader=$rows | Sort-Object rank | Select-Object -First 1
        $above=@()
        if($me){
            $above=@($rows | Where-Object {[int]$_.rank -lt [int]$me.rank} | Sort-Object rank -Descending)
        }
        $nearestAbove=$above | Select-Object -First 1
        $below=@()
        if($me){
            $below=@($rows | Where-Object {[int]$_.rank -gt [int]$me.rank} | Sort-Object rank)
        }
        $nearestBelow=$below | Select-Object -First 1

        # Bounded sample: top managers plus managers nearest the user.
        $targets=@($rows | Where-Object {$_.is_me -ne $true} | Sort-Object rank | Select-Object -First 8)
        if($me){
            $near=@($rows | Where-Object {$_.is_me -ne $true} |
                Sort-Object @{Expression={[math]::Abs([int]$_.rank-[int]$me.rank)}} |
                Select-Object -First 10)
            $targets=@($targets+$near | Sort-Object entry -Unique)
        }

        $comparisons=@()
        foreach($row in $targets){
            $rid=[int]$row.entry
            $rivalPickObj=$null

            if($comparisonGw -gt 0){
                $acctPath=Join-Path $Root ("02_DATA\FPL_ACCOUNT\RIVALS\league_{0}_entry_{1}_GW{2:D2}.json" -f [int]$league.id,$rid,$comparisonGw)
                if(Test-Path $acctPath){
                    $wrap=Read-JsonSafe $acctPath
                    if($wrap -and $wrap.picks -and $wrap.picks.picks){$rivalPickObj=$wrap.picks}
                    elseif($wrap -and $wrap.picks){$rivalPickObj=$wrap}
                }
            }

            if(-not $rivalPickObj -and $comparisonGw -gt 0){
                $miPickPath=Join-Path $Root ("02_DATA\MANAGER_INTELLIGENCE\MANAGERS\entry_{0}\picks_GW{1:D2}.json" -f $rid,$comparisonGw)
                if(Test-Path $miPickPath){$rivalPickObj=Read-JsonSafe $miPickPath}
            }

            $startIds=@();$squadIds=@();$captainId=$null;$activeChip=$null
            if($rivalPickObj -and $rivalPickObj.picks){
                $activeChip=$rivalPickObj.active_chip
                foreach($pk in @($rivalPickObj.picks)){
                    try{
                        $eid=[int]$pk.element
                        $squadIds += $eid
                        if([int]$pk.position -le 11){$startIds += $eid}
                        if($pk.is_captain -eq $true){$captainId=$eid}
                    }catch{}
                }
            }

            $startOverlap=$null;$squadOverlap=$null;$diffCount=$null
            $rivalOnly=@();$userOnly=@()
            if($selfStartIds.Count -gt 0 -and $startIds.Count -gt 0){
                $shared=@($startIds | Where-Object {$selfStartIds -contains $_} | Select-Object -Unique)
                $startOverlap=$shared.Count
                $rivalOnlyIds=@($startIds | Where-Object {$selfStartIds -notcontains $_} | Select-Object -Unique)
                $userOnlyIds=@($selfStartIds | Where-Object {$startIds -notcontains $_} | Select-Object -Unique)
                $diffCount=$rivalOnlyIds.Count
                $rivalOnly=@($rivalOnlyIds | ForEach-Object {
                    if($playerNameById.ContainsKey([int]$_)){$playerNameById[[int]$_]}else{"Player $_"}
                })
                $userOnly=@($userOnlyIds | ForEach-Object {
                    if($playerNameById.ContainsKey([int]$_)){$playerNameById[[int]$_]}else{"Player $_"}
                })
            }

            if($selfSquadIds.Count -gt 0 -and $squadIds.Count -gt 0){
                $squadOverlap=@($squadIds | Where-Object {$selfSquadIds -contains $_} | Select-Object -Unique).Count
            }

            $miProfile=$null
            if($miScoreMap.ContainsKey($rid)){$miProfile=$miScoreMap[$rid]}

            $gapToUser=$null
            if($me -and $row.points -ne $null -and $me.points -ne $null){
                $gapToUser=[int]$row.points-[int]$me.points
            }

            $leverage='UNKNOWN'
            if($diffCount -ne $null -and $gapToUser -ne $null){
                if([math]::Abs($gapToUser) -le 15 -and $diffCount -ge 4){$leverage='HIGH'}
                elseif([math]::Abs($gapToUser) -le 30 -or $diffCount -ge 3){$leverage='MEDIUM'}
                else{$leverage='LOW'}
            }

            $rankDelta=$null;$pointsDelta=$null
            if($movementMap.ContainsKey($rid)){
                $move=$movementMap[$rid]
                $rankDelta=$move.rank_delta
                $pointsDelta=$move.points_delta
            }
            $gwSwing=$null
            if($me -and $row.event_points -ne $null -and $me.event_points -ne $null){
                try{$gwSwing=[int]$row.event_points-[int]$me.event_points}catch{}
            }
            $threatScore=0.0
            if($gapToUser -ne $null){
                $gapAbs=[math]::Abs([int]$gapToUser)
                if($gapAbs -le 5){$threatScore+=40}elseif($gapAbs -le 15){$threatScore+=30}elseif($gapAbs -le 30){$threatScore+=20}elseif($gapAbs -le 60){$threatScore+=10}
            }
            if($diffCount -ne $null){$threatScore += [math]::Min(24,[double]$diffCount*4)}
            if($rankDelta -ne $null -and [int]$rankDelta -gt 0){$threatScore += [math]::Min(16,[double]$rankDelta*2)}
            if($gwSwing -ne $null -and [int]$gwSwing -gt 0){$threatScore += [math]::Min(12,[double]$gwSwing)}
            if($captainId -and $selfCaptainId -and [int]$captainId -ne [int]$selfCaptainId){$threatScore+=8}
            if($miProfile -and $miProfile.intelligence_score -ne $null){
                try{$threatScore += [math]::Min(10,[double]$miProfile.intelligence_score/10.0)}catch{}
            }
            $threatScore=[math]::Round([math]::Min(100,$threatScore),1)

            $comparisons += [pscustomobject]@{
                entry=$rid
                rank=$row.rank
                team=$row.name
                manager=$row.manager
                points=$row.points
                event_points=$row.event_points
                gap_to_user=$gapToUser
                gw_swing_vs_user=$gwSwing
                rank_delta=$rankDelta
                points_delta=$pointsDelta
                threat_score=$threatScore
                comparison_available=($rivalPickObj -ne $null)
                starting_xi_overlap=$startOverlap
                squad_overlap=$squadOverlap
                differential_count=$diffCount
                rival_only_starters=@($rivalOnly)
                user_only_starters=@($userOnly)
                captain_id=$captainId
                captain=if($captainId -and $playerNameById.ContainsKey([int]$captainId)){$playerNameById[[int]$captainId]}else{$null}
                captain_same=if($captainId -and $selfCaptainId){([int]$captainId -eq [int]$selfCaptainId)}else{$null}
                active_chip=$activeChip
                leverage=$leverage
                archetype=if($miProfile){$miProfile.archetype}else{$null}
                intelligence_score=if($miProfile){$miProfile.intelligence_score}else{$null}
                transfers_per_gw=if($miProfile){$miProfile.transfers_per_gw}else{$null}
                hit_week_rate=if($miProfile){$miProfile.hit_week_rate}else{$null}
                no_transfer_week_rate=if($miProfile){$miProfile.no_transfer_week_rate}else{$null}
                elite_template_similarity_pct=if($miProfile){$miProfile.elite_template_similarity_pct}else{$null}
                captain_hindsight_efficiency=if($miProfile){$miProfile.captain_hindsight_efficiency}else{$null}
                post_haul_buy_rate=if($miProfile){$miProfile.post_haul_buy_rate}else{$null}
                manager_confidence_pct=if($miProfile){$miProfile.confidence_pct}else{$null}
                population_status=if($miProfile){$miProfile.population_status}else{$null}
                population_confidence_pct=if($miProfile){$miProfile.population_confidence_pct}else{$null}
                decision_behavior_stratum=if($miProfile){$miProfile.decision_behavior_stratum}else{$null}
                automation_signal=if($miProfile){$miProfile.automation_signal}else{$null}
                decision_process_training_status=if($miProfile){$miProfile.decision_process_training_status}else{$null}
            }
        }

        $available=@($comparisons | Where-Object {$_.comparison_available -eq $true -and $_.starting_xi_overlap -ne $null})
        $avgOverlap=$null;$avgDiffs=$null
        if($available.Count -gt 0){
            $avgOverlap=[math]::Round((($available | Measure-Object starting_xi_overlap -Average).Average),1)
            $avgDiffs=[math]::Round((($available | Measure-Object differential_count -Average).Average),1)
        }

        # V3.1.1 exploratory League DNA: every dimension is derived from the
        # sampled rival comparison panel. Missing manager-intelligence fields stay null.
        $archCounts=@{};$captainCounts=@{};$activityRows=@();$hitRows=@();$intelRows=@();$templateRows=@()
        foreach($cmp in @($available)){
            $arch=[string]$cmp.archetype;if(-not [string]::IsNullOrWhiteSpace($arch)){if(-not $archCounts.ContainsKey($arch)){$archCounts[$arch]=0};$archCounts[$arch]++}
            if($cmp.captain_id){$ck=[string]$cmp.captain_id;if(-not $captainCounts.ContainsKey($ck)){$captainCounts[$ck]=0};$captainCounts[$ck]++}
            if($cmp.transfers_per_gw -ne $null){$activityRows += [double]$cmp.transfers_per_gw}
            if($cmp.hit_week_rate -ne $null){$hitRows += ([double]$cmp.hit_week_rate*100)}
            if($cmp.intelligence_score -ne $null){$intelRows += [double]$cmp.intelligence_score}
            if($cmp.elite_template_similarity_pct -ne $null -and [double]$cmp.elite_template_similarity_pct -gt 0){$templateRows += [double]$cmp.elite_template_similarity_pct}
        }
        $archMix=@();foreach($ak in @($archCounts.Keys | Sort-Object)){$archMix += [pscustomobject][ordered]@{archetype=$ak;count=[int]$archCounts[$ak];share_percent=if($available.Count -gt 0){[math]::Round(([int]$archCounts[$ak]/[double]$available.Count)*100)}else{0}}}
        $captainDiversity=$null;$captainConvergence=$null
        if($available.Count -gt 0 -and $captainCounts.Count -gt 0){
            $captainDiversity=[math]::Round(($captainCounts.Count/[double]$available.Count)*100)
            $maxCaptain=0;foreach($cv in $captainCounts.Values){if([int]$cv -gt $maxCaptain){$maxCaptain=[int]$cv}}
            $captainConvergence=[math]::Round(($maxCaptain/[double]$available.Count)*100)
        }
        $populationCounts=@{};$behaviorStrataCounts=@{}
        foreach($cmp in @($available)){
            $ps=[string]$cmp.population_status;if([string]::IsNullOrWhiteSpace($ps)){$ps='UNCLASSIFIED'};if(-not $populationCounts.ContainsKey($ps)){$populationCounts[$ps]=0};$populationCounts[$ps]++
            $bs=[string]$cmp.decision_behavior_stratum;if([string]::IsNullOrWhiteSpace($bs)){$bs='UNCLASSIFIED'};if(-not $behaviorStrataCounts.ContainsKey($bs)){$behaviorStrataCounts[$bs]=0};$behaviorStrataCounts[$bs]++
        }
        $populationMix=@();foreach($pk in @($populationCounts.Keys | Sort-Object)){$populationMix += [pscustomobject]@{status=$pk;count=[int]$populationCounts[$pk];share_percent=if($available.Count){[math]::Round(100*[int]$populationCounts[$pk]/[double]$available.Count)}else{0}}}
        $behaviorMix=@();foreach($bk in @($behaviorStrataCounts.Keys | Sort-Object)){$behaviorMix += [pscustomobject]@{stratum=$bk;count=[int]$behaviorStrataCounts[$bk];share_percent=if($available.Count){[math]::Round(100*[int]$behaviorStrataCounts[$bk]/[double]$available.Count)}else{0}}}
        $eligibleForDecisionModel=@($available | Where-Object {$_.decision_process_training_status -eq 'ELIGIBLE_STRATIFIED'})
        $largestBehaviorShare=0;if($behaviorMix.Count -gt 0){$largestBehaviorShare=[int](($behaviorMix | Sort-Object share_percent -Descending | Select-Object -First 1).share_percent)}
        $leagueDna=[ordered]@{
            sample_size=$available.Count
            decision_model_eligible_sample_size=$eligibleForDecisionModel.Count
            population_integrity_mix=@($populationMix | Sort-Object count -Descending)
            decision_behavior_strata=@($behaviorMix | Sort-Object count -Descending)
            population_skew_warning=if($largestBehaviorShare -ge 60){'One observed behavior stratum dominates this sample. Raw frequencies must not be used as optimal-policy training weights.'}else{$null}
            xi_overlap_with_you=if($avgOverlap -ne $null){[math]::Round(($avgOverlap/11.0)*100)}else{$null}
            xi_divergence_from_you=if($avgDiffs -ne $null){[math]::Round(($avgDiffs/11.0)*100)}else{$null}
            captain_diversity_index=$captainDiversity
            captain_convergence_pct=$captainConvergence
            average_transfers_per_gw=if($activityRows.Count -gt 0){[math]::Round((($activityRows | Measure-Object -Average).Average),2)}else{$null}
            average_hit_week_rate_pct=if($hitRows.Count -gt 0){[math]::Round((($hitRows | Measure-Object -Average).Average),1)}else{$null}
            manager_strength_proxy=if($intelRows.Count -gt 0){[math]::Round((($intelRows | Measure-Object -Average).Average),1)}else{$null}
            elite_template_similarity_pct=if($templateRows.Count -gt 0){[math]::Round((($templateRows | Measure-Object -Average).Average),1)}else{$null}
            archetype_mix=@($archMix | Sort-Object count -Descending)
            maturity=if($available.Count -ge 20){'SUPPORTED'}elseif($available.Count -ge 8){'TENTATIVE'}else{'EMERGING'}
            guardrail='League DNA is an exploratory description of the sampled managers, not a fixed personality label for the whole league. Raw population frequency is descriptive; future policy learning uses stratified eligibility so common kneejerk/template/casual behavior cannot dominate simply by volume.'
        }

        $rivalIntelLeagues += [pscustomobject]@{
            id=$league.id
            name=$league.name
            kind=$league.kind
            comparison_gw=$comparisonGw
            user_rank=if($me){$me.rank}else{$league.user_rank}
            user_points=if($me){$me.points}else{$league.user_points}
            leader_team=if($leader){$leader.name}else{$null}
            leader_manager=if($leader){$leader.manager}else{$null}
            leader_points=if($leader){$leader.points}else{$null}
            gap_to_leader=if($me -and $leader){[int]$leader.points-[int]$me.points}else{$null}
            nearest_above_team=if($nearestAbove){$nearestAbove.name}else{$null}
            nearest_above_manager=if($nearestAbove){$nearestAbove.manager}else{$null}
            nearest_above_points=if($nearestAbove){$nearestAbove.points}else{$null}
            gap_to_nearest_above=if($me -and $nearestAbove){[int]$nearestAbove.points-[int]$me.points}else{$null}
            nearest_below_team=if($nearestBelow){$nearestBelow.name}else{$null}
            nearest_below_manager=if($nearestBelow){$nearestBelow.manager}else{$null}
            nearest_below_points=if($nearestBelow){$nearestBelow.points}else{$null}
            gap_to_nearest_below=if($me -and $nearestBelow){[int]$me.points-[int]$nearestBelow.points}else{$null}
            user_rank_delta=if($movementIntel){$movementIntel.user_rank_delta}else{$null}
            biggest_riser=if($movementIntel){$movementIntel.biggest_riser}else{$null}
            biggest_faller=if($movementIntel){$movementIntel.biggest_faller}else{$null}
            sampled_rivals=$available.Count
            research_sample_target=if($movementIntel -and $movementIntel.research_sample_target){[int]$movementIntel.research_sample_target}else{$null}
            research_sample_roster_size=if($movementIntel -and $movementIntel.research_sample_roster){@($movementIntel.research_sample_roster).Count}else{0}
            research_sample_coverage_note=if($movementIntel){[string]$movementIntel.research_sample_coverage_note}else{''}
            average_starting_xi_overlap=$avgOverlap
            average_differentials=$avgDiffs
            league_dna=[pscustomobject]$leagueDna
            comparisons=@($comparisons | Sort-Object threat_score -Descending)
        }
    }

    $crossThreat=@{}
    foreach($intelLeague in @($rivalIntelLeagues)){
        foreach($cmp in @($intelLeague.comparisons | Where-Object {$_.comparison_available -eq $true})){
            $key=[string]$cmp.entry
            if(-not $crossThreat.ContainsKey($key)){
                $crossThreat[$key]=[ordered]@{
                    entry=$cmp.entry;team=$cmp.team;manager=$cmp.manager;league_count=0;threat_score_total=0.0
                    closest_gap=$null;max_rank_rise=0;positive_gw_swing_total=0;leagues=@()
                }
            }
            $agg=$crossThreat[$key]
            $agg.league_count++
            $agg.threat_score_total=[double]$agg.threat_score_total+[double]$cmp.threat_score
            if($cmp.gap_to_user -ne $null){
                $gapAbs=[math]::Abs([int]$cmp.gap_to_user)
                if($agg.closest_gap -eq $null -or $gapAbs -lt [int]$agg.closest_gap){$agg.closest_gap=$gapAbs}
            }
            if($cmp.rank_delta -ne $null -and [int]$cmp.rank_delta -gt [int]$agg.max_rank_rise){$agg.max_rank_rise=[int]$cmp.rank_delta}
            if($cmp.gw_swing_vs_user -ne $null -and [int]$cmp.gw_swing_vs_user -gt 0){$agg.positive_gw_swing_total += [int]$cmp.gw_swing_vs_user}
            $agg.leagues += [pscustomobject]@{id=$intelLeague.id;name=$intelLeague.name;gap=$cmp.gap_to_user;threat_score=$cmp.threat_score}
        }
    }
    $crossThreatRows=@()
    foreach($aggKey in @($crossThreat.Keys)){
        $agg=$crossThreat[$aggKey]
        $agg['cross_league_threat_score']=[math]::Round(([double]$agg.threat_score_total + ([math]::Max(0,[int]$agg.league_count-1)*12)),1)
        $crossThreatRows += [pscustomobject]$agg
    }
    $crossThreatRows=@($crossThreatRows | Sort-Object cross_league_threat_score -Descending)

    # Manager Genome: aggregate each observed manager once across overlapping leagues.
    # This avoids double-counting a manager merely because they appear in many leagues.
    $genomeMap=@{}
    foreach($intelLeague in @($rivalIntelLeagues)){
        foreach($cmp in @($intelLeague.comparisons | Where-Object {$_.comparison_available -eq $true})){
            $gk=[string]$cmp.entry
            if(-not $genomeMap.ContainsKey($gk)){
                $genomeMap[$gk]=[ordered]@{entry=$cmp.entry;team=$cmp.team;manager=$cmp.manager;league_ids=@();league_names=@();observations=0;threat_total=0.0;diff_total=0.0;diff_n=0;archetype=$cmp.archetype;intelligence_score=$cmp.intelligence_score;transfers_per_gw=$cmp.transfers_per_gw;hit_week_rate=$cmp.hit_week_rate;template_similarity_pct=$cmp.elite_template_similarity_pct;manager_confidence_pct=$cmp.manager_confidence_pct;population_status=$cmp.population_status;population_confidence_pct=$cmp.population_confidence_pct;decision_behavior_stratum=$cmp.decision_behavior_stratum;automation_signal=$cmp.automation_signal;decision_process_training_status=$cmp.decision_process_training_status}
            }
            $g=$genomeMap[$gk];$g.observations++
            if($g.league_ids -notcontains $intelLeague.id){$g.league_ids += $intelLeague.id;$g.league_names += $intelLeague.name}
            $g.threat_total=[double]$g.threat_total+[double]$cmp.threat_score
            if($cmp.differential_count -ne $null){$g.diff_total=[double]$g.diff_total+[double]$cmp.differential_count;$g.diff_n++}
            if(-not $g.archetype -and $cmp.archetype){$g.archetype=$cmp.archetype}
        }
    }
    $managerGenome=@()
    foreach($gk in $genomeMap.Keys){
        $g=$genomeMap[$gk]
        $managerGenome += [pscustomobject][ordered]@{
            entry=$g.entry;team=$g.team;manager=$g.manager;league_count=@($g.league_ids).Count;league_ids=@($g.league_ids);league_names=@($g.league_names);observations=$g.observations
            archetype=$g.archetype;intelligence_score=$g.intelligence_score;manager_confidence_pct=$g.manager_confidence_pct;transfers_per_gw=$g.transfers_per_gw;hit_week_rate=$g.hit_week_rate;template_similarity_pct=$g.template_similarity_pct
            population_status=$g.population_status;population_confidence_pct=$g.population_confidence_pct;decision_behavior_stratum=$g.decision_behavior_stratum;automation_signal=$g.automation_signal;decision_process_training_status=$g.decision_process_training_status
            average_threat_score=if($g.observations -gt 0){[math]::Round(([double]$g.threat_total/[double]$g.observations),1)}else{$null}
            average_xi_differentials_vs_you=if($g.diff_n -gt 0){[math]::Round(([double]$g.diff_total/[double]$g.diff_n),1)}else{$null}
        }
    }
    $managerGenome=@($managerGenome | Sort-Object @{Expression='league_count';Descending=$true},@{Expression='average_threat_score';Descending=$true} | Select-Object -First 60)
    $globalRisers=@()
    $globalFallers=@()
    foreach($intelLeague in @($rivalIntelLeagues)){
        if($intelLeague.biggest_riser){$globalRisers += [pscustomobject]@{league=$intelLeague.name;league_id=$intelLeague.id;manager=$intelLeague.biggest_riser.manager_name;team=$intelLeague.biggest_riser.team_name;rank_delta=$intelLeague.biggest_riser.rank_delta;points_delta=$intelLeague.biggest_riser.points_delta}}
        if($intelLeague.biggest_faller){$globalFallers += [pscustomobject]@{league=$intelLeague.name;league_id=$intelLeague.id;manager=$intelLeague.biggest_faller.manager_name;team=$intelLeague.biggest_faller.team_name;rank_delta=$intelLeague.biggest_faller.rank_delta;points_delta=$intelLeague.biggest_faller.points_delta}}
    }
    $rivalIntel=[ordered]@{
        comparison_gameweek=$comparisonGw
        user_captain=if($selfCaptainId -and $playerNameById.ContainsKey([int]$selfCaptainId)){$playerNameById[[int]$selfCaptainId]}else{$null}
        leagues=@($rivalIntelLeagues)
        biggest_cross_league_threat=if($crossThreatRows.Count -gt 0){$crossThreatRows[0]}else{$null}
        cross_league_threats=@($crossThreatRows | Select-Object -First 12)
        manager_genome=@($managerGenome)
        biggest_riser=if($globalRisers.Count -gt 0){$globalRisers | Sort-Object rank_delta -Descending | Select-Object -First 1}else{$null}
        biggest_faller=if($globalFallers.Count -gt 0){$globalFallers | Sort-Object rank_delta | Select-Object -First 1}else{$null}
        manager_genome_note='Manager Genome deduplicates managers by FPL entry across overlapping observed leagues. V3.2.1 adds population-integrity and behavior strata so inactive/automation-like/template/reactive observations are not silently treated as equivalent training examples. All such labels are uncertain and descriptive; automation signals are never proof of bots.'
        note='Rival threat combines point proximity, XI divergence, current-GW swing, rank movement, captain divergence and optional Manager Intelligence. It is strategy evidence, not a football-quality score.'
    }

    # LiveFPL is an enrichment layer only. Official FPL remains authoritative.
    $liveStatus='NOT_SYNCED';$liveLastSync=$null;$liveErrors=@();$liveTeamLinked=$false
    if($liveMeta){
        $liveStatus=[string]$liveMeta.status
        $liveLastSync=$liveMeta.synced_at_local
        if($liveMeta.errors){$liveErrors=@($liveMeta.errors)}
        $liveTeamLinked=($liveMeta.team_ok -eq $true)
    }
    $gwRank=$null;$projectedRank=$null;$similarity=$null;$liveBench=$null;$liveProjectedTotal=$null;$liveCaptainPoints=$null;$liveGamesPlayed=$null
    $benchSource=$null;$benchDetails=@()
    if($liveTeam){
        # LiveFPL uses negative/sentinel ranks such as -1 when a projected
        # rank is not available. Never expose those as real ranks.
        try{
            if($liveTeam.GWrank -ne $null){
                $tmpGw=[long]$liveTeam.GWrank
                if($tmpGw -gt 0){$gwRank=$tmpGw}
            }
        }catch{}
        try{
            if($liveTeam.GWrank2 -ne $null){
                $tmpProjected=[long]$liveTeam.GWrank2
                if($tmpProjected -gt 0){$projectedRank=$tmpProjected}
            }
        }catch{}
        if($liveTeam.avg_similarity -ne $null){$similarity=$liveTeam.avg_similarity}
        try{if($liveTeam.total -ne $null){$liveProjectedTotal=[double]$liveTeam.total}}catch{}
        try{if($liveTeam.cap_pts -ne $null){$liveCaptainPoints=[double]$liveTeam.cap_pts}}catch{}
        try{if($liveTeam.games_played -ne $null){$liveGamesPlayed=[string]$liveTeam.games_played}}catch{}
        try{
            if($liveTeam.bench -ne $null){
                $liveBench=[double]$liveTeam.bench
                $benchSource='LIVEFPL_FALLBACK'
            }
        }catch{}
    }

    # Bench points should mean raw points currently sitting on the user's
    # locked FPL bench. LiveFPL's `bench` field is not stable across live-feed
    # versions and has returned 0 while Official FPL shows bench scorers.
    # Calculate this from the authoritative locked picks + bootstrap event_points.
    if($lockedGw -gt 0 -and $boot){
        $lockedBenchPicks=Read-JsonSafe (Join-Path $Root ('02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json' -f $lockedGw))
        if($lockedBenchPicks -and $lockedBenchPicks.picks){
            $eventMap=@{}
            foreach($el in @($boot.elements)){
                try{$eventMap[[int]$el.id]=$el}catch{}
            }
            $benchTotal=0.0;$benchKnown=0;$benchDetails=@()
            foreach($bp in @($lockedBenchPicks.picks | Where-Object {[int]$_.position -gt 11} | Sort-Object position)){
                $eid=[int]$bp.element
                if(-not $eventMap.ContainsKey($eid)){continue}
                $el=$eventMap[$eid]
                $pts=$null
                try{if($el.event_points -ne $null){$pts=[double]$el.event_points}}catch{}
                if($pts -ne $null){
                    $benchTotal += $pts
                    $benchKnown++
                    $benchDetails += [pscustomobject]@{
                        element=$eid
                        name=[string]$el.web_name
                        points=$pts
                        bench_position=([int]$bp.position-11)
                    }
                }
            }
            if($benchKnown -gt 0){
                $liveBench=$benchTotal
                $benchSource='OFFICIAL_FPL_LOCKED_BENCH'
            }
        }
    }

    $priceRisers=@();$priceFallers=@();$priceFeedMeaningful=$false
    if($livePrices){
        $priceRows=@()
        foreach($pr in @($livePrices.PSObject.Properties)){
            $v=$pr.Value
            if(-not $v){continue}
            $progress=$null;$tonight=$null;$perHour=$null
            try{if($v.progress -ne $null){$progress=[double]$v.progress}}catch{}
            try{if($v.progress_tonight -ne $null){$tonight=[double]$v.progress_tonight}}catch{}
            try{if($v.per_hour -ne $null){$perHour=[double]$v.per_hour}}catch{}
            $nm=[string]$v.name
            if([string]::IsNullOrWhiteSpace($nm) -and $boot){
                $el=$boot.elements | Where-Object {[int]$_.id -eq [int]$pr.Name} | Select-Object -First 1
                if($el){$nm=$el.web_name}
            }
            if(-not [string]::IsNullOrWhiteSpace($nm)){
                $priceRows += [pscustomobject]@{id=$pr.Name;name=$nm;progress=$progress;tonight=$tonight;per_hour=$perHour;cost=$v.cost}
            }
        }
        $meaningfulRows=@($priceRows | Where-Object {
            ($_.progress -ne $null -and [math]::Abs([double]$_.progress) -gt 0.0001) -or
            ($_.tonight -ne $null -and [math]::Abs([double]$_.tonight) -gt 0.0001)
        })
        $priceFeedMeaningful=($meaningfulRows.Count -gt 0)
        if($priceFeedMeaningful){
            $priceRisers=@($priceRows | Where-Object {$_.progress -ne $null -and [double]$_.progress -gt 0} | Sort-Object progress -Descending | Select-Object -First 6)
            $priceFallers=@($priceRows | Where-Object {$_.progress -ne $null -and [double]$_.progress -lt 0} | Sort-Object progress | Select-Object -First 6)
        }
    }

    $topTransferRows=@()
    if($liveTransfers -and $boot){
        $playerNameMap=@{};foreach($el in @($boot.elements)){$playerNameMap[[int]$el.id]=$el.web_name}
        foreach($tr in @($liveTransfers | Select-Object -First 8)){
            try{
                $outId=[int]$tr[0];$inId=[int]$tr[1]
                $count=$tr[2];$share=$tr[3]
                $topTransferRows += [pscustomobject]@{out_id=$outId;out_name=$playerNameMap[$outId];in_id=$inId;in_name=$playerNameMap[$inId];volume=$count;share=$share}
            }catch{}
        }
    }

    $connTeamId=$null;$privateEnabled=$false;$lastAccountSync=$null;$lastPublicSync=$null;$latestPackName=$null;$latestReviewName=$null;$trackedLeagueIds=@();$plannerId=$null
    if($conn){$connTeamId=$conn.team_id;$privateEnabled=($conn.private_current_team_enabled -eq $true);$plannerId=$conn.livefpl_planner_id;if($conn.tracked_league_ids){$trackedLeagueIds=@($conn.tracked_league_ids)}}
    $hunch=Read-JsonSafe (Join-Path $Root '06_CONFIG\manager_hunch.json')
    if(-not $hunch){$hunch=[pscustomobject]@{}}
    $copilotThread=Read-JsonSafe (Join-Path $Root '06_CONFIG\copilot_thread.json')
    if(-not $copilotThread){$copilotThread=[pscustomobject]@{version=1;updated_at=$null;messages=@()}}
    $copilotMessages=@($copilotThread.messages)
    $copilotPending=@($copilotMessages | Where-Object {
        ([string]$_.role).ToUpperInvariant() -eq 'USER' -and
        ([string]$_.status).ToUpperInvariant() -eq 'PENDING'
    })

    # Direct AI state. The API key itself is Windows-DPAPI encrypted and never
    # returned to the browser/status API.
    $copilotAiConfigPath=Join-Path $Root '06_CONFIG\copilot_api_config.json'
    $copilotAiConfig=Read-JsonSafe $copilotAiConfigPath
    if(-not $copilotAiConfig){
        $copilotAiConfig=[pscustomobject]@{
            model='gpt-5.4-nano'
            web_model='gpt-5.6-luna'
            deep_model='gpt-5.6-luna'
            monthly_budget_usd=0.25
            max_output_tokens=700
            allow_web_search=$false
            input_price_per_million=0.20
            output_price_per_million=1.25
            web_input_price_per_million=0.20
            web_output_price_per_million=1.20
            web_search_price_per_call=0.01
        }
    }

    $copilotAiKeyPath=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
    $copilotAiKeyConfigured=Test-Path $copilotAiKeyPath

    $usagePath=Join-Path $Root '02_DATA\PROCESSED\copilot_api_usage.json'
    $usageObj=Read-JsonSafe $usagePath
    $usageEvents=@()
    if($usageObj -and $usageObj.events){$usageEvents=@($usageObj.events)}
    elseif($usageObj -is [array]){$usageEvents=@($usageObj)}

    $monthPrefix=(Get-Date).ToString('yyyy-MM')
    $monthEvents=@($usageEvents | Where-Object {([string]$_.created_at).StartsWith($monthPrefix)})
    $monthSpend=0.0
    foreach($ue in $monthEvents){
        try{$monthSpend += [double]$ue.estimated_cost_usd}catch{}
    }
    $monthSpend=[math]::Round($monthSpend,6)

    $aiWorker=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\copilot_ai_worker.json')
    $aiWorkerAlive=$false
    if($aiWorker -and $aiWorker.process_id){
        try{$aiWorkerAlive=($null -ne (Get-Process -Id ([int]$aiWorker.process_id) -ErrorAction SilentlyContinue))}catch{}
    }
    $aiQueued=@($copilotMessages | Where-Object {
        ([string]$_.mode).ToUpperInvariant() -in @('API','API_DEEP') -and
        ([string]$_.status).ToUpperInvariant() -in @('QUEUED','RUNNING')
    }).Count
    $aiFailed=@($copilotMessages | Where-Object {([string]$_.mode).ToUpperInvariant() -in @('API','API_DEEP') -and ([string]$_.status).ToUpperInvariant() -eq 'FAILED'}).Count
    $aiDeepQueued=@($copilotMessages | Where-Object {
        ([string]$_.mode).ToUpperInvariant() -eq 'API_DEEP' -and
        ([string]$_.status).ToUpperInvariant() -in @('QUEUED','RUNNING')
    }).Count

    $copilotAiState=[ordered]@{
        configured=$copilotAiKeyConfigured
        model=[string]$copilotAiConfig.model
        monthly_budget_usd=[double]$copilotAiConfig.monthly_budget_usd
        month_estimated_spend_usd=$monthSpend
        month_remaining_usd=[math]::Max(0,[math]::Round(([double]$copilotAiConfig.monthly_budget_usd-$monthSpend),6))
        requests_this_month=$monthEvents.Count
        max_output_tokens=[int]$copilotAiConfig.max_output_tokens
        web_search_default=([bool]$copilotAiConfig.allow_web_search)
        worker_alive=$aiWorkerAlive
        worker_stage=if($aiWorker){$aiWorker.stage}else{'IDLE'}
        worker_note=if($aiWorker){$aiWorker.note}else{$null}
        worker_message_id=if($aiWorker){$aiWorker.message_id}else{$null}
        queued_or_running=$aiQueued
        deep_queued_or_running=$aiDeepQueued
        failed_count=$aiFailed
        pricing_note='Local estimate for this app only; provider billing is authoritative and may include usage outside this app.'
    }
    $hunchReview=Read-JsonSafe (Join-Path $Root '06_CONFIG\hunch_review.json')
    if(-not $hunchReview){$hunchReview=[pscustomobject]@{}}
    $hunchHistory=Read-JsonSafe (Join-Path $Root '02_DATA\PROCESSED\hunch_history.json')
    if(-not $hunchHistory){$hunchHistory=@()}
    if($syncMeta){$lastAccountSync=Get-MetaTimestamp $syncMeta}
    if($publicMeta){$lastPublicSync=Get-MetaTimestamp $publicMeta}
    if($latestPack){$latestPackName=$latestPack.Name}
    if($latestReview){$latestReviewName=$latestReview.Name}
    $deadlinePassed=Get-FplDeadlinePassed $Root $gw
    $allFixtures=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\fixtures.json')
    $officialLive=Get-OfficialLiveTeamState $Root $gw $boot $allFixtures $publicMeta
    $liveTickPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_live_tick.json'
    $liveTickRun=Read-JsonSafe $liveTickPath
    if($liveTickRun -and ([string]$liveTickRun.status).ToUpperInvariant() -eq 'SYNCING'){
        $tickAlive=$false;$tickGrace=$false
        try{if($liveTickRun.process_id){$tickAlive=($null -ne (Get-Process -Id ([int]$liveTickRun.process_id) -ErrorAction SilentlyContinue))}}catch{}
        try{if(-not $liveTickRun.process_id -and $liveTickRun.heartbeat_at_local){$tickGrace=((Get-Date)-[datetime]::Parse([string]$liveTickRun.heartbeat_at_local)).TotalSeconds -lt 10}}catch{}
        if(-not $tickAlive -and -not $tickGrace){
            try{$liveTickRun.status='FAILED';$liveTickRun.completed_at_local=(Get-Date).ToString('o');$liveTickRun.message='Previous matchday live worker stopped before writing completion; the next automatic tick may retry.';Write-JsonUtf8 $liveTickRun $liveTickPath 30}catch{}
        }
    }
    if($officialLive -and $officialLive.available -eq $true){$liveBench=$officialLive.bench_points;$benchSource='OFFICIAL_FPL_EVENT_LIVE';$summary['event_points_live']=$officialLive.points;$summary['event_points_live_gameweek']=$officialLive.gameweek}

    # UI-facing source labels: pre-deadline/live-data waiting is not an outage.
    $liveDisplayStatus=$liveStatus
    $liveTeamDisplayStatus=if($liveTeamLinked){'CONNECTED'}elseif($connTeamId){'WAITING_OR_DEGRADED'}else{'NEEDS_TEAM_ID'}
    if(-not $deadlinePassed -and $connTeamId){
        if($liveStatus -eq 'DEGRADED' -and $livePrices){$liveDisplayStatus='PARTIAL_PRE_GW'}
        if(-not $liveTeamLinked){$liveTeamDisplayStatus='WAITING_FOR_LIVE_GW'}
    }

    # Current decision alerts must not be polluted by the previous Gameweek's
    # finalized recommendation. Preserve old alerts separately for audit/history.
    $displayAlerts=@()
    $historicalAlerts=@()
    if($decisionGameweek -and $decisionGameweek -lt $gw){
        # Preserve the previous recommendation for History, but never turn an
        # unevaluated Gameweek into an operational blocker. Deep Dive evaluates
        # the current question from live data on demand.
        $historicalAlerts=@($dash.alerts)
    } else {
        foreach($a in @($dash.alerts)){
            $txt=[string]$a
            if($connTeamId -and ($txt -match '(?i)connect your FPL Team ID|connect your FPL Team ID/optional league links')){continue}
            $displayAlerts += $txt
        }
    }
    if($rivalIntel.biggest_cross_league_threat){
        $th=$rivalIntel.biggest_cross_league_threat
        $displayAlerts += ("Rival threat: {0} ({1}) matters across {2} league(s); cross-league threat {3}." -f $th.team,$th.manager,$th.league_count,$th.cross_league_threat_score)
    }
    if($rivalIntel.biggest_riser -and [int]$rivalIntel.biggest_riser.rank_delta -ge 2){
        $rise=$rivalIntel.biggest_riser
        $displayAlerts += ("Biggest riser: {0} climbed {1} place(s) in {2}." -f $rise.team,$rise.rank_delta,$rise.league)
    }
    $miStatus='NOT_SYNCED'
    $miTracked=0;$miElite=0;$miPrivate=0;$miCohorts=0;$miLockedGw=$null;$miClimbers=@();$miSmart=[pscustomobject]@{};$miHitLab=[pscustomobject]@{};$miProfiles=@()
    if($miSummary){
        $miStatus=[string]$miSummary.status
        $miTracked=[int]$miSummary.tracked_managers
        $miElite=[int]$miSummary.elite_overall_count
        $miPrivate=[int]$miSummary.private_top_count
        $miCohorts=[int]$miSummary.cohorts
        $miLockedGw=$miSummary.latest_locked_gw
        $miClimbers=@($miSummary.top_climbers)
        $miSmart=$miSummary.smart_money
        $miHitLab=$miSummary.hit_lab
        $miProfiles=@($miSummary.top_manager_profiles)
    } elseif($connTeamId -and -not $deadlinePassed){
        $miStatus='WAITING_FOR_GW_LOCK'
    }

    # Freshness reflects the actual cached data files, not merely the timestamp
    # of a failed refresh attempt that preserved an older cache.
    $officialFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if(-not $officialFetched){$officialFetched=Get-MetaTimestamp $publicMeta}
    $accountFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\entry.json')
    if(-not $accountFetched){$accountFetched=Get-MetaTimestamp $syncMeta}
    $liveFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\live_team.json')
    if(-not $liveFetched){$liveFetched=Get-MetaTimestamp $liveMeta}
    $managerFetched=Get-MetaTimestamp $miMeta
    $officialLiveFetched=$null
    try{if($officialLive -and $officialLive.fetched_at){$officialLiveFetched=[string]$officialLive.fetched_at}}catch{}
    if(-not $officialLiveFetched){$officialLiveFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\CURRENT\event_live_current.json')}
    $priceFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\prices.json')
    $transferFlowFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\top_transfers.json')
    $currentTeamFetched=$null
    try{if($syncMeta.private_current_team_last_success_at){$currentTeamFetched=[string]$syncMeta.private_current_team_last_success_at}elseif($syncMeta.private_current_team_synced_at){$currentTeamFetched=[string]$syncMeta.private_current_team_synced_at}}catch{}
    if(-not $currentTeamFetched){$currentTeamFetched=Get-FileTimestamp (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\my-team.json')}

    $freshness=[ordered]@{
        official_fpl=[ordered]@{
            fetched_at=$officialFetched
            age_seconds=Get-LocalAgeSeconds $officialFetched
            duration_seconds=if($publicMeta){$publicMeta.duration_seconds}else{$null}
            live_event=if($publicMeta){$publicMeta.current_live_event}else{$null}
            event_live_fetched_at=if($publicMeta){$publicMeta.event_live_fetched_at}else{$null}
        }
        official_live=[ordered]@{
            fetched_at=$officialLiveFetched
            age_seconds=Get-LocalAgeSeconds $officialLiveFetched
            gameweek=if($officialLive){$officialLive.gameweek}else{$null}
            available=if($officialLive){$officialLive.available}else{$false}
        }
        fpl_account=[ordered]@{
            fetched_at=$accountFetched
            age_seconds=Get-LocalAgeSeconds $accountFetched
            duration_seconds=if($syncMeta){$syncMeta.duration_seconds}else{$null}
            mode=if($syncMeta){$syncMeta.mode}else{$null}
        }
        current_team=[ordered]@{
            fetched_at=$currentTeamFetched
            age_seconds=Get-LocalAgeSeconds $currentTeamFetched
            status=if($syncMeta){$syncMeta.private_current_team_status}else{$null}
            auth_mode=if($syncMeta){$syncMeta.private_current_team_auth_mode}else{$null}
            auth_detail=if($syncMeta){$syncMeta.private_current_team_auth_detail}else{$null}
            auth_requires_reconnect=if($syncMeta){$syncMeta.auth_requires_reconnect}else{$null}
            oidc_refresh_present=if($syncMeta){$syncMeta.oidc_refresh_token_present}else{$false}
            oidc_refresh_succeeded=if($syncMeta){$syncMeta.oidc_refresh_succeeded}else{$false}
            cache_available=($my -and $my.picks -and @($my.picks).Count -ge 15)
            gameweek=if($syncMeta){$syncMeta.private_current_team_gameweek}else{$null}
        }
        livefpl=[ordered]@{
            fetched_at=$liveFetched
            age_seconds=Get-LocalAgeSeconds $liveFetched
            duration_seconds=if($liveMeta){$liveMeta.duration_seconds}else{$null}
            mode=if($liveMeta){$liveMeta.mode}else{$null}
        }
        price_market=[ordered]@{
            fetched_at=$priceFetched
            age_seconds=Get-LocalAgeSeconds $priceFetched
        }
        transfer_market=[ordered]@{
            fetched_at=$transferFlowFetched
            age_seconds=Get-LocalAgeSeconds $transferFlowFetched
        }
        manager_intelligence=[ordered]@{
            fetched_at=$managerFetched
            age_seconds=Get-LocalAgeSeconds $managerFetched
            duration_seconds=if($miMeta){$miMeta.duration_seconds}else{$null}
            mode=if($miMeta){$miMeta.mode}else{$null}
            progress_stage=if($miMeta){$miMeta.progress_stage}else{$null}
            progress_current=if($miMeta){$miMeta.progress_current}else{0}
            progress_total=if($miMeta){$miMeta.progress_total}else{0}
            history_refresh_deferred=if($miMeta){$miMeta.history_refresh_deferred}else{$null}
        }
        league_intelligence=[ordered]@{
            fetched_at=if($leagueIntelRun){$leagueIntelRun.completed_at_local}else{$null}
            age_seconds=if($leagueIntelRun){Get-LocalAgeSeconds $leagueIntelRun.completed_at_local}else{$null}
            status=if($leagueIntelRun){$leagueIntelRun.status}else{'NOT_SYNCED'}
            mode=if($leagueIntelRun){$leagueIntelRun.mode}else{$null}
        }
    }

    $resolved=[ordered]@{
        points=[ordered]@{value=if($summary.Contains('points')){$summary['points']}else{$null};source='OFFICIAL_FPL_ENTRY';fetched_at=$accountFetched;confidence='AUTHORITATIVE'}
        official_rank=[ordered]@{value=if($summary.Contains('rank')){$summary['rank']}else{$null};source='OFFICIAL_FPL_ENTRY';fetched_at=$accountFetched;confidence='AUTHORITATIVE'}
        live_rank_estimate=[ordered]@{value=$projectedRank;source='LIVEFPL';fetched_at=$liveFetched;confidence='LIVE_ESTIMATE'}
        event_points=[ordered]@{value=if($summary.Contains('event_points')){$summary['event_points']}else{$null};source='OFFICIAL_FPL_ENTRY';fetched_at=$accountFetched;confidence='AUTHORITATIVE'}
        live_event_points=[ordered]@{value=if($officialLive -and $officialLive.available){$officialLive.points}else{$null};source='OFFICIAL_FPL_EVENT_LIVE';fetched_at=$officialLiveFetched;confidence='AUTHORITATIVE_LIVE_FEED'}
        bank_m=[ordered]@{value=if($summary.Contains('bank_m')){$summary['bank_m']}else{$null};source=if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){'OFFICIAL_FPL_MY_TEAM'}elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){'CACHED_OFFICIAL_FPL_MY_TEAM'}else{'OFFICIAL_FPL_ENTRY'};fetched_at=if($squadSource -in @('PRIVATE_CURRENT_TEAM','LAST_KNOWN_CURRENT_TEAM')){$currentTeamFetched}else{$accountFetched};confidence=if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){'AUTHORITATIVE_CURRENT'}elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){'LAST_KNOWN_CURRENT'}else{'LAST_DEADLINE'}}
        team_value_m=[ordered]@{value=if($summary.Contains('team_value_m')){$summary['team_value_m']}else{$null};source=if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){'OFFICIAL_FPL_CURRENT_SQUAD'}elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){'CACHED_OFFICIAL_FPL_CURRENT_SQUAD'}else{'OFFICIAL_FPL_ENTRY'};fetched_at=if($squadSource -in @('PRIVATE_CURRENT_TEAM','LAST_KNOWN_CURRENT_TEAM')){$currentTeamFetched}else{$accountFetched};confidence=if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){'AUTHORITATIVE_CURRENT'}elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){'LAST_KNOWN_CURRENT'}else{'LAST_DEADLINE'}}
    }

    # V4 Decision Readiness Gate. This is deliberately compact and user-facing:
    # READY = an exact actionable call may be validated; DEGRADED = analysis is usable
    # but one or more inputs are stale/unknown; BLOCKED = do not publish an Exact Call.
    $readinessIssues=New-Object System.Collections.ArrayList
    $readinessWarnings=New-Object System.Collections.ArrayList
    if($displaySquad.Count -ne 15){
        [void]$readinessIssues.Add('No complete 15-player structured squad is available for deterministic validation.')
    }elseif($squadSource -eq 'LAST_KNOWN_CURRENT_TEAM'){
        [void]$readinessIssues.Add('Authenticated Official FPL current team is unavailable. The cached last-known squad is context only and cannot authorize an Exact Call.')
    }elseif($squadSource -ne 'PRIVATE_CURRENT_TEAM'){
        [void]$readinessIssues.Add('Only a deadline-locked/historical squad is available; the editable current squad cannot be validated.')
    }
    if(-not $boot -or @($boot.elements).Count -eq 0){[void]$readinessIssues.Add('Official FPL player/fixture universe is unavailable.')}
    if(-not $allFixtures -or @($allFixtures).Count -eq 0){[void]$readinessIssues.Add('Official FPL fixtures are unavailable.')}
    $officialAge=$freshness.official_fpl.age_seconds
    $teamAge=$freshness.current_team.age_seconds
    try{if($officialAge -eq $null -or [double]$officialAge -gt 1800){[void]$readinessWarnings.Add('Official FPL core data is older than 30 minutes.')}}catch{}
    try{
        if($teamAge -eq $null){
            if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){[void]$readinessWarnings.Add('Current-team freshness timestamp is unavailable; verify the team before applying changes.')}
        }elseif([double]$teamAge -gt 1800){
            if($squadSource -eq 'PRIVATE_CURRENT_TEAM'){[void]$readinessWarnings.Add('Authenticated current-team snapshot is older than 30 minutes. Deep Dive will force-refresh Official FPL current team before any actionable call.')}
        }
    }catch{}
    try{if(([string]$summary['free_transfers']).ToUpperInvariant() -eq 'UNAVAILABLE'){[void]$readinessWarnings.Add('Exact free-transfer count is unknown; transfer routes must remain conditional.')}}catch{}
    $readinessState=if($readinessIssues.Count -gt 0){'BLOCKED'}elseif($readinessWarnings.Count -gt 0){'DEGRADED'}else{'READY'}
    $decisionReadiness=[ordered]@{
        state=$readinessState
        exact_call_allowed=($readinessState -ne 'BLOCKED')
        issues=@($readinessIssues)
        warnings=@($readinessWarnings)
        evaluated_at=(Get-Date).ToString('o')
        rule='Exact Calls require a fresh authenticated Official FPL editable current team plus a valid Official FPL player/fixture universe. Last-known, locked and screenshot-derived squads are context only.'
    }

    $research=$null
    try{if(Get-Command Get-ResearchSummary -ErrorAction SilentlyContinue){$research=Get-ResearchSummary $Root}}catch{}
    $currentTeamResolution=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\current_team_resolution.json')

    return [ordered]@{
        ok=$true; version='4.1.2'; season=$dash.season; gameweek=$gw; deadline_passed=$deadlinePassed; sync_run=$syncRun;close_gameweek_run=$closeGameweekRun;league_refresh_run=$leagueRefreshRun;league_intelligence_run=$leagueIntelRun;connect_run=$connectRun; freshness=$freshness; resolved=$resolved;
        summary=$summary; decision_readiness=$decisionReadiness; current_team_resolution=$currentTeamResolution; official_live=$officialLive; live_tick_run=$liveTickRun; decision=$displayDecision; decision_stale=$decisionStale; decision_match_mode=$decisionMatchMode; decision_gameweek=$decisionGameweek; current_team_connected=($accountMeta -and ([string]$accountMeta.private_current_team_status).ToUpperInvariant() -eq 'SYNCED'); current_team_cache_available=($my -and $my.picks -and @($my.picks).Count -ge 15); current_team_last_success_at=$currentTeamFetched; current_team_auth_status=if($accountMeta){$accountMeta.private_current_team_status}else{'NOT_CONFIGURED'}; copilot=[ordered]@{thread=$copilotThread;pending_count=$copilotPending.Count;ai=$copilotAiState}; rival_intelligence=$rivalIntel; squad=@($displaySquad); squad_source=$squadSource; squad_gameweek=$squadGameweek; squad_confirmed_current=$squadConfirmedCurrent; squad_display_status=$squadDisplayStatus; squad_display_reason=$squadDisplayReason; squad_next_action=$squadNextAction; market=$dash.market; rivals=$displayRivals; rival_leagues=@($rivalLeagues); alerts=@($displayAlerts); historical_alerts=@($historicalAlerts); history=@($dash.history); hunch=$hunch; hunch_review=$hunchReview; hunch_history=@($hunchHistory);
        connection=[ordered]@{
            team_id=$connTeamId
            tracked_league_ids=$trackedLeagueIds
            livefpl_planner_id=$plannerId
            private_current_team_enabled=$privateEnabled
            private_cookie_present=(Test-Path (Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\fpl_cookie.txt'))
            private_auth_token_present=(Test-Path (Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\fpl_x_api_authorization.txt'))
            private_oidc_refresh_token_present=(Test-Path (Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\fpl_oidc_refresh_token.txt'))
            private_current_team_auth_mode=if($accountMeta){$accountMeta.private_current_team_auth_mode}else{$null}
            private_current_team_auth_detail=if($accountMeta){$accountMeta.private_current_team_auth_detail}else{$null}
            private_current_team_auth_requires_reconnect=if($accountMeta){$accountMeta.auth_requires_reconnect}else{$null}
            private_current_team_status=if($accountMeta){$accountMeta.private_current_team_status}else{'NOT_CONFIGURED'}
            private_current_team_synced_at=if($accountMeta){$accountMeta.private_current_team_synced_at}else{$null}
            private_current_team_last_success_at=$currentTeamFetched
            private_current_team_cache_available=($my -and $my.picks -and @($my.picks).Count -ge 15)
            private_current_team_gameweek=if($accountMeta){$accountMeta.private_current_team_gameweek}else{$null}
            discovered_private_leagues=$privateLeagues
            last_account_sync=$lastAccountSync
            last_public_sync=$lastPublicSync
        };
        sources=[ordered]@{
            official_fpl=if($publicMeta -and $publicMeta.success -eq $true){'CONNECTED'}else{'DEGRADED'};
            fpl_account=if($entry){'CONNECTED'}elseif($connTeamId){'CONFIGURED'}else{'NOT_CONNECTED'};
            livefpl=$liveDisplayStatus;
            livefpl_team=$liveTeamDisplayStatus;
            manager_intelligence=$miStatus;
            last_livefpl_sync=$liveLastSync
        };
        livefpl=[ordered]@{
            status=$liveDisplayStatus;raw_status=$liveStatus;team_linked=$liveTeamLinked;last_sync=$liveLastSync;errors=$liveErrors;
            gw_rank=$gwRank;live_overall_rank_estimate=$gwRank;projected_rank=$projectedRank;projected_total=$liveProjectedTotal;captain_points=$liveCaptainPoints;games_played=$liveGamesPlayed;similarity=$similarity;bench_points=$liveBench;bench_points_source=$benchSource;bench_details=@($benchDetails);
            price_risers=$priceRisers;price_fallers=$priceFallers;price_feed_meaningful=$priceFeedMeaningful;top_transfers=$topTransferRows;top_transfers_available=($topTransferRows.Count -gt 0);
            planner_connected=($livePlanner -ne $null);planner_id=$plannerId;elite_available=($liveElite -ne $null)
        };
        manager_intelligence=[ordered]@{
            status=$miStatus;tracked_managers=$miTracked;elite_count=$miElite;private_count=$miPrivate;cohorts=$miCohorts;latest_locked_gw=$miLockedGw;
            top_climbers=$miClimbers;smart_money=$miSmart;hit_lab=$miHitLab;top_profiles=$miProfiles;
            progress_stage=if($miMeta){$miMeta.progress_stage}else{$null};progress_current=if($miMeta){$miMeta.progress_current}else{0};progress_total=if($miMeta){$miMeta.progress_total}else{0};history_refresh_deferred=if($miMeta){$miMeta.history_refresh_deferred}else{$null};
            errors=if($miMeta -and $miMeta.errors){@($miMeta.errors)}else{@()}
        };
        inbox=[ordered]@{ screenshot_count=$shots; incoming_updates=$updates; latest_pack=$latestPackName; latest_review=$latestReviewName };
        research=$research
    }
}
