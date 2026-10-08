param(
    [ValidateSet('Quick','Full')][string]$Mode='Quick',
    [switch]$Quiet
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$syncStatusPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
$logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$started=Get-Date
$runId=[guid]::NewGuid().ToString('N')
$sourceResults=@()

function Save-Run([string]$Status,[string]$Summary,[string]$CurrentSource=$null){
    $now=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status=$Status
        mode=$Mode.ToUpperInvariant()
        display_mode=if($Mode -eq 'Full'){'DEEP_REFRESH'}else{'LIVE_SYNC'}
        run_id=$runId
        process_id=$PID
        started_at_local=$started.ToString('yyyy-MM-dd HH:mm:ss')
        completed_at_local=if($Status -in @('SUCCESS','PARTIAL','FAILED','CANCELLED')){$now.ToString('yyyy-MM-dd HH:mm:ss')}else{$null}
        heartbeat_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
        duration_seconds=[math]::Round(($now-$started).TotalSeconds,1)
        current_source=$CurrentSource
        sources=@($sourceResults)
        summary=$Summary
    }) $syncStatusPath 50
}
function Add-SourceResult([string]$Name,[bool]$Ok,[bool]$Required,[datetime]$StageStart,[string]$ErrorMessage=$null){
    $script:sourceResults += [pscustomobject]@{
        name=$Name;ok=$Ok;required=$Required
        seconds=[math]::Round(((Get-Date)-$StageStart).TotalSeconds,1)
        error=$ErrorMessage
    }
}
function Get-WorkerExe {
    $candidate=$null
    try{
        if($PSVersionTable.PSEdition -eq 'Core'){$candidate=Join-Path $PSHOME 'pwsh.exe'}
        else{$candidate=Join-Path $PSHOME 'powershell.exe'}
    }catch{}
    if($candidate -and (Test-Path $candidate)){return $candidate}
    return 'powershell.exe'
}
function Test-Meta([string]$Kind,[datetime]$Since){
    $metaPath=$null
    if($Kind -eq 'PUBLIC'){
        $metaPath=Join-Path $Root '02_DATA\CURRENT\_sync_meta.json'
        $m=Read-JsonSafe $metaPath
        if(-not $m -or $m.success -ne $true){throw 'Official FPL core refresh did not produce a successful metadata record.'}
    }elseif($Kind -eq 'ACCOUNT'){
        $metaPath=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json'
        $m=Read-JsonSafe $metaPath
        if(-not $m -or $m.success -ne $true){throw 'FPL account refresh did not return the connected entry.'}
    }elseif($Kind -eq 'LIVEFPL'){
        $metaPath=Join-Path $Root '02_DATA\LIVEFPL\CURRENT\_livefpl_sync_meta.json'
        $m=Read-JsonSafe $metaPath
        if(-not $m -or ([string]$m.status).ToUpperInvariant() -eq 'OFFLINE'){throw 'LiveFPL enrichment is offline; Official FPL data remains usable.'}
    }
    if($metaPath -and (Test-Path $metaPath)){
        $written=(Get-Item -LiteralPath $metaPath).LastWriteTime
        if($Since -and $written -lt $Since.AddSeconds(-2)){
            throw 'Source worker exited without refreshing its metadata in this run.'
        }
    }
}
function Write-CompactSnapshot {
    try{
        $entry=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\entry.json')
        $publicMeta=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\_sync_meta.json')
        $accountMeta=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json')
        $liveMeta=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\_livefpl_sync_meta.json')
        $liveTeam=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\live_team.json')
        $gw=Get-LatestLockedGameweek $Root
        if($gw -le 0){$gw=Get-EngineGameweek $Root}
        $dir=Join-Path $Root ("02_DATA\LIVE_SNAPSHOTS\GW{0:D2}" -f $gw)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        $snap=[ordered]@{
            captured_at=(Get-Date).ToString('o');sync_mode=$Mode
            official_fpl=[ordered]@{
                overall_points=if($entry){$entry.summary_overall_points}else{$null}
                overall_rank=if($entry){$entry.summary_overall_rank}else{$null}
                event_points=if($entry){$entry.summary_event_points}else{$null}
                event_live_gw=if($publicMeta){$publicMeta.current_live_event}else{$null}
                event_live_fetched_at=if($publicMeta){$publicMeta.event_live_fetched_at}else{$null}
                public_sync_completed_at=if($publicMeta){$publicMeta.completed_at_local}else{$null}
                account_sync_completed_at=if($accountMeta){$accountMeta.completed_at_local}else{$null}
            }
            livefpl=[ordered]@{
                sync_completed_at=if($liveMeta){$liveMeta.completed_at_local}else{$null}
                GWrank=if($liveTeam){$liveTeam.GWrank}else{$null}
                GWrank2=if($liveTeam){$liveTeam.GWrank2}else{$null}
                avg_similarity=if($liveTeam){$liveTeam.avg_similarity}else{$null}
                bench=if($liveTeam){$liveTeam.bench}else{$null}
            }
            source_timings=@($sourceResults)
        }
        Write-JsonUtf8 $snap (Join-Path $dir ("snapshot_$stamp.json")) 50
        Write-JsonUtf8 $snap (Join-Path $Root '02_DATA\LIVE_SNAPSHOTS\latest.json') 50
    }catch{}
}

# v2.8: independent live sources are launched concurrently. The dashboard can
# keep polling while this worker runs, and no slow optional source blocks the
# other live sources from refreshing their own cache.
Save-Run 'SYNCING' 'Live Sync started. Official FPL, account/current-team and LiveFPL are refreshing in parallel.' 'PARALLEL_FAST_LANE'
$exe=Get-WorkerExe
$lanes=@(
    [pscustomobject]@{name='Official FPL';kind='PUBLIC';required=$true;script='Sync-PublicData.ps1';arguments='-Quiet';started=(Get-Date)},
    [pscustomobject]@{name='FPL Account';kind='ACCOUNT';required=$true;script='Sync-FPLAccount.ps1';arguments='-Quiet -Mode Quick';started=(Get-Date)},
    [pscustomobject]@{name='LiveFPL';kind='LIVEFPL';required=$false;script='Sync-LiveFPL.ps1';arguments='-Quiet -Mode Quick';started=(Get-Date)}
)
$workers=@()
foreach($lane in $lanes){
    $runner=Join-Path $PSScriptRoot $lane.script
    $safeName=($lane.kind.ToLowerInvariant())
    $outLog=Join-Path $logDir ("sync_${safeName}_stdout.log")
    $errLog=Join-Path $logDir ("sync_${safeName}_stderr.log")
    try{Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8;Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8}catch{}
    $workerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" $($lane.arguments)"
    try{
        $workerProcess=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        $workers += [pscustomobject]@{lane=$lane;process=$workerProcess;out_log=$outLog;err_log=$errLog;recorded=$false}
    }catch{
        Add-SourceResult $lane.name $false $lane.required $lane.started ('Could not launch source worker: '+$_.Exception.Message)
    }
}

$parallelDeadline=(Get-Date).AddSeconds(75)
while(@($workers | Where-Object {-not $_.recorded}).Count -gt 0 -and (Get-Date) -lt $parallelDeadline){
    foreach($w in @($workers | Where-Object {-not $_.recorded})){
        $done=$false
        try{$done=$w.process.HasExited}catch{$done=$true}
        if(-not $done){continue}
        $ok=$false;$errText=$null;$exitCode=$null
        try{$w.process.WaitForExit();$exitCode=$w.process.ExitCode}catch{}
        try{
            # Fresh metadata is authoritative. Windows PowerShell child-process
            # exit codes can be noisy even when the source completed and wrote
            # valid current-run metadata, so never downgrade fresh data solely
            # because the wrapper process returned a non-zero code.
            Test-Meta $w.lane.kind $w.lane.started
            $ok=$true
        }catch{$ok=$false;$errText=$_.Exception.Message}
        if(-not $ok){
            $stderrText=$null
            try{$stderrText=(Get-Content $w.err_log -Raw -ErrorAction SilentlyContinue).Trim()}catch{}
            if(-not [string]::IsNullOrWhiteSpace($stderrText)){
                $errText=if([string]::IsNullOrWhiteSpace($errText)){$stderrText}else{($errText+' | '+$stderrText)}
            }
            if([string]::IsNullOrWhiteSpace($errText)){
                $errText=if($exitCode -ne $null){('Source worker did not refresh valid metadata (exit code {0}).' -f $exitCode)}else{'Source worker did not refresh valid metadata.'}
            }
        }
        Add-SourceResult $w.lane.name $ok $w.lane.required $w.lane.started $errText
        $w.recorded=$true
        Save-Run 'SYNCING' ("Parallel live lane: {0}/{1} sources finished." -f $sourceResults.Count,$lanes.Count) 'PARALLEL_FAST_LANE'
    }
    Start-Sleep -Milliseconds 120
}
foreach($w in @($workers | Where-Object {-not $_.recorded})){
    try{if(-not $w.process.HasExited){Stop-Process -Id $w.process.Id -Force -ErrorAction SilentlyContinue}}catch{}
    Add-SourceResult $w.lane.name $false $w.lane.required $w.lane.started 'Source worker exceeded the 75s live-sync safety timeout.'
    $w.recorded=$true
}

# Reliability fallback: if a detached/parallel worker failed, retry that exact
# source directly in this already-background sync process. Normal successful
# runs stay parallel; only failures pay the serial fallback cost.
$failedNames=@($sourceResults | Where-Object {-not $_.ok} | ForEach-Object {$_.name})
foreach($lane in @($lanes | Where-Object {$failedNames -contains $_.name})){
    $result=$sourceResults | Where-Object {$_.name -eq $lane.name} | Select-Object -First 1
    if(-not $result){continue}
    $retryStart=Get-Date
    Save-Run 'SYNCING' ("Retrying {0} directly after the parallel worker did not validate." -f $lane.name) ("{0} fallback" -f $lane.name)
    try{
        $runner=Join-Path $PSScriptRoot $lane.script
        switch($lane.kind){
            'PUBLIC' { & $runner -Quiet }
            'ACCOUNT' { & $runner -Quiet -Mode Quick }
            'LIVEFPL' { & $runner -Quiet -Mode Quick }
        }
        Test-Meta $lane.kind $retryStart
        $result.ok=$true
        $result.error=$null
        $result.seconds=[math]::Round(((Get-Date)-$lane.started).TotalSeconds,1)
        $result | Add-Member -NotePropertyName fallback_recovered -NotePropertyValue $true -Force
    }catch{
        $result.error=("Parallel and direct fallback failed: {0}" -f $_.Exception.Message)
        $result.seconds=[math]::Round(((Get-Date)-$lane.started).TotalSeconds,1)
    }
}

# Deep Refresh is maintenance, not the live path. League intelligence and
# Manager Intelligence only run here (or when a Deep Dive question needs them).
if($Mode -eq 'Full'){
    $leagueStart=Get-Date
    Save-Run 'SYNCING' 'Fast live lane complete. Building automatic league intelligence.' 'League Intelligence (deep)'
    try{
        & (Join-Path $PSScriptRoot 'Sync-LeagueIntelligence.ps1') -Mode Deep -BudgetSeconds 60 -Quiet
        $lm=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_league_intelligence.json')
        if($lm -and ([string]$lm.status).ToUpperInvariant() -eq 'FAILED'){throw 'League intelligence failed; previous cache remains usable.'}
        Add-SourceResult 'League Intelligence (deep)' $true $false $leagueStart
    }catch{Add-SourceResult 'League Intelligence (deep)' $false $false $leagueStart $_.Exception.Message}

    $managerStart=Get-Date
    Save-Run 'SYNCING' 'League intelligence complete. Running incremental Manager Intelligence maintenance.' 'Manager Intelligence (incremental)'
    try{
        & (Join-Path $PSScriptRoot 'Sync-ManagerIntelligence.ps1') -Quiet -Mode Incremental
        $mm=Read-JsonSafe (Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE\CURRENT\_manager_intelligence_sync_meta.json')
        if($mm -and ([string]$mm.status).ToUpperInvariant() -eq 'FAILED'){throw 'Manager Intelligence reported failure; previous cache remains usable.'}
        Add-SourceResult 'Manager Intelligence (incremental)' $true $false $managerStart
    }catch{Add-SourceResult 'Manager Intelligence (incremental)' $false $false $managerStart $_.Exception.Message}
}else{
    # Automatic leagues are detached from the fast lane. Start a small worker and
    # return without waiting, so the cockpit is usable as soon as live data lands.
    try{
        $leagueRunner=Join-Path $PSScriptRoot 'Sync-LeagueIntelligence.ps1'
        $leagueOut=Join-Path $logDir 'league_auto_stdout.log'
        $leagueErr=Join-Path $logDir 'league_auto_stderr.log'
        $leagueArgs="-NoProfile -ExecutionPolicy Bypass -File `"$leagueRunner`" -Mode Light -BudgetSeconds 24 -Quiet"
        $leagueProcess=Start-Process -FilePath $exe -ArgumentList $leagueArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $leagueOut -RedirectStandardError $leagueErr
        $sourceResults += [pscustomobject]@{name='League Intelligence (background)';ok=$true;required=$false;seconds=0;error=$null;detached=$true;process_id=$leagueProcess.Id}
    }catch{
        $sourceResults += [pscustomobject]@{name='League Intelligence (background)';ok=$false;required=$false;seconds=0;error=$_.Exception.Message;detached=$true}
    }
}

# V3.0.3: account/public metadata can refresh successfully while the private
# editable-team credential has expired. Surface that as its own source result
# so the top-level Live Sync cannot look fully green while Team is days stale.
try{
    $connState=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
    $accountState=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json')
    if($connState -and $connState.private_current_team_enabled -eq $true){
        $ctOk=($accountState -and ([string]$accountState.private_current_team_status).ToUpperInvariant() -eq 'SYNCED')
        $ctErr=$null
        if(-not $ctOk){
            $ctErr='Editable current team is not authenticated. Reconnect with the FPL OIDC refresh token; cached LAST KNOWN team is preserved but exact team calls are blocked.'
        }
        $sourceResults += [pscustomobject]@{name='Current Team Auth';ok=$ctOk;required=$false;seconds=0;error=$ctErr}
    }
}catch{}

Write-CompactSnapshot
$requiredFailures=@($sourceResults | Where-Object {$_.required -and -not $_.ok})
$optionalFailures=@($sourceResults | Where-Object {-not $_.required -and -not $_.ok -and $_.name -ne 'League Intelligence (background)'})
if($requiredFailures.Count -gt 0){
    $syncState='FAILED'
    $syncSummary='A required live refresh source did not validate after retry. Existing cached data was preserved; source details are available under Advanced.'
}elseif($optionalFailures.Count -gt 0){
    $syncState='PARTIAL'
    $currentTeamAuthFailed=(@($optionalFailures | Where-Object {$_.name -eq 'Current Team Auth'}).Count -gt 0)
    if($currentTeamAuthFailed){
        $syncSummary='Public Official FPL/account/live data refreshed, but the editable current team is not authenticated. LAST KNOWN cache is preserved; exact team calls are blocked until current-team auth is repaired.'
    }else{
        $syncSummary=if($Mode -eq 'Full'){'Deep Refresh completed core live data; one optional intelligence source failed and its previous cache was preserved.'}else{'Core Official FPL/account data refreshed; one optional enrichment source is temporarily unavailable.'}
    }
}else{
    $syncState='SUCCESS'
    $syncSummary=if($Mode -eq 'Full'){'Deep Refresh completed: parallel live data + automatic leagues + incremental Manager Intelligence.'}else{'Live Sync completed. Automatic league intelligence continues independently in the background.'}
}
Save-Run $syncState $syncSummary $null
if(-not $Quiet){
    $tone=if($syncState -eq 'SUCCESS'){'Green'}elseif($syncState -eq 'PARTIAL'){'Yellow'}else{'Red'}
    $label=if($Mode -eq 'Full'){'Deep Refresh'}else{'Live Sync'}
    Write-Host ("{0} {1} in {2}s." -f $label,$syncState,[math]::Round(((Get-Date)-$started).TotalSeconds,1)) -ForegroundColor $tone
}
return
