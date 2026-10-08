param([switch]$Quiet,[string]$RunId='')
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$statePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_live_tick.json'
$current=Join-Path $Root '02_DATA\CURRENT'
$raw=Join-Path $Root '02_DATA\PUBLIC_RAW'
New-Item -ItemType Directory -Force -Path $current,$raw | Out-Null
$started=Get-Date
$runId=if([string]::IsNullOrWhiteSpace($RunId)){[guid]::NewGuid().ToString('N')}else{$RunId}

function Save-LiveTick([string]$Status,[string]$Message,[int]$Gameweek=0,[string]$ErrorMessage=$null){
    $now=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status=$Status;run_id=$runId;process_id=$PID;gameweek=if($Gameweek -gt 0){$Gameweek}else{$null};started_at_local=$started.ToString('o');completed_at_local=if($Status -in @('SUCCESS','PARTIAL','FAILED')){$now.ToString('o')}else{$null};heartbeat_at_local=$now.ToString('o');duration_seconds=[math]::Round(($now-$started).TotalSeconds,1);message=$Message;error=$ErrorMessage
    }) $statePath 30
}

Save-LiveTick 'SYNCING' 'Refreshing Official FPL event-live + LiveFPL matchday feeds.'
$gw=0;$officialOk=$false;$liveFplOk=$false;$errors=@()
try{
    $boot=Read-JsonSafe (Join-Path $current 'bootstrap-static.json')
    if(-not $boot -or -not $boot.events){throw 'bootstrap-static cache is missing; run Refresh now once.'}
    $nowUtc=[datetime]::UtcNow
    $ev=$boot.events | Where-Object {$_.is_current -eq $true} | Select-Object -First 1
    if(-not $ev){
        $ev=$boot.events | Where-Object {$_.deadline_time -and $nowUtc -ge [datetime]::Parse([string]$_.deadline_time).ToUniversalTime()} | Sort-Object id -Descending | Select-Object -First 1
    }
    if(-not $ev){throw 'No locked/current Gameweek exists yet.'}
    $gw=[int]$ev.id

    $headers=@{'User-Agent'='Mozilla/5.0 FPL-Decision-Engine/4.1.2';'Accept'='application/json'}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $fixtures=Invoke-RestMethod -Uri 'https://fantasy.premierleague.com/api/fixtures/' -Headers $headers -TimeoutSec 10
    $live=Invoke-RestMethod -Uri ("https://fantasy.premierleague.com/api/event/{0}/live/" -f $gw) -Headers $headers -TimeoutSec 10
    $fixtures=Repair-ObjectStrings $fixtures;$live=Repair-ObjectStrings $live
    $conn=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
    if($conn -and $conn.team_id){
        try{
            $teamId=[int]$conn.team_id
            $locked=Invoke-RestMethod -Uri ("https://fantasy.premierleague.com/api/entry/{0}/event/{1}/picks/" -f $teamId,$gw) -Headers $headers -TimeoutSec 10
            $locked=Repair-ObjectStrings $locked
            $acctCurrent=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT'
            New-Item -ItemType Directory -Force -Path $acctCurrent | Out-Null
            Write-JsonUtf8 $locked (Join-Path $acctCurrent ("picks_GW{0:D2}.json" -f $gw)) 100
        }catch{$errors += ('Locked picks: '+$_.Exception.Message)}
    }
    Write-JsonUtf8 $fixtures (Join-Path $current 'fixtures.json') 100
    Write-JsonUtf8 $live (Join-Path $current 'event_live_current.json') 100
    Write-JsonUtf8 $live (Join-Path $raw ("event-live-GW{0:D2}-{1}.json" -f $gw,$stamp)) 100

    $metaPath=Join-Path $current '_sync_meta.json'
    $meta=Read-JsonSafe $metaPath
    if(-not $meta){$meta=[pscustomobject]@{success=$true}}
    if(-not ($meta.PSObject.Properties.Name -contains 'current_live_event')){$meta | Add-Member -NotePropertyName current_live_event -NotePropertyValue $gw -Force}else{$meta.current_live_event=$gw}
    $liveStamp=(Get-Date).ToString('o')
    if(-not ($meta.PSObject.Properties.Name -contains 'event_live_fetched_at')){$meta | Add-Member -NotePropertyName event_live_fetched_at -NotePropertyValue $liveStamp -Force}else{$meta.event_live_fetched_at=$liveStamp}
    if(-not ($meta.PSObject.Properties.Name -contains 'matchday_live_completed_at')){$meta | Add-Member -NotePropertyName matchday_live_completed_at -NotePropertyValue $liveStamp -Force}else{$meta.matchday_live_completed_at=$liveStamp}
    Write-JsonUtf8 $meta $metaPath 30
    $officialOk=$true
}catch{
    $errors += ('Official live: '+$_.Exception.Message)
}

try{
    & (Join-Path $PSScriptRoot 'Sync-LiveFPL.ps1') -Quiet -Mode Quick
    $lm=Read-JsonSafe (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\_livefpl_sync_meta.json')
    $liveFplOk=($lm -and ([string]$lm.status).ToUpperInvariant() -ne 'OFFLINE')
    if(-not $liveFplOk){$errors += 'LiveFPL matchday enrichment is currently offline.'}
}catch{
    $errors += ('LiveFPL: '+$_.Exception.Message)
}

if($officialOk -and $liveFplOk){Save-LiveTick 'SUCCESS' 'Matchday live feeds refreshed.' $gw}
elseif($officialOk){Save-LiveTick 'PARTIAL' 'Official FPL live feed refreshed; LiveFPL enrichment kept its previous cache.' $gw ($errors -join ' | ')}
else{Save-LiveTick 'FAILED' 'Official live refresh failed; previous cache was preserved.' $gw ($errors -join ' | ')}
if(-not $Quiet){$label=if($errors.Count -eq 0){'SUCCESS'}else{'PARTIAL'};Write-Host ('Matchday live tick: '+$label)}
return
