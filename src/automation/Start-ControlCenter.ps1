param([int]$Port=8765)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$libPath=Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1'

# v2.8.6 startup gate: parse EVERY automation script before exposing any
# action in the Control Center. A latent syntax error in a maintenance script
# must be discovered at startup, not after the user waits and clicks it.
$automationScripts=@(Get-ChildItem $PSScriptRoot -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object Name)
foreach($automationScript in $automationScripts){
    $preflightTokens=$null
    $preflightErrors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($automationScript.FullName,[ref]$preflightTokens,[ref]$preflightErrors) | Out-Null
    if($preflightErrors -and $preflightErrors.Count -gt 0){
        $firstParseError=$preflightErrors | Select-Object -First 1
        throw ("PowerShell startup preflight failed in {0} at line {1}: {2}" -f $automationScript.Name,$firstParseError.Extent.StartLineNumber,$firstParseError.Message)
    }
}
. $libPath
# V3 migration is idempotent. It creates a local migration backup and initializes
# the research ledger without touching historical/raw data.
& (Join-Path $PSScriptRoot 'Migrate-V3.ps1') -Quiet
$dashboardPath=Join-Path $PSScriptRoot 'control-center.html'
$playbookPath=Join-Path $PSScriptRoot 'playbook.html'

function Find-HeaderEnd([byte[]]$Bytes) {
    for($i=0;$i -le $Bytes.Length-4;$i++){
        if($Bytes[$i]-eq 13 -and $Bytes[$i+1]-eq 10 -and $Bytes[$i+2]-eq 13 -and $Bytes[$i+3]-eq 10){return $i}
    }
    return -1
}
function Read-HttpRequest($Stream) {
    if($Stream.CanTimeout){$Stream.ReadTimeout=5000;$Stream.WriteTimeout=5000}

    # Chrome may create an idle speculative localhost connection before
    # sending the real page request. Never let that idle socket monopolize
    # this intentionally lightweight single-user server.
    $firstByteWait=[Diagnostics.Stopwatch]::StartNew()
    while(-not $Stream.DataAvailable -and $firstByteWait.ElapsedMilliseconds -lt 3000){
        Start-Sleep -Milliseconds 15
    }
    $firstByteWait.Stop()
    if(-not $Stream.DataAvailable){throw '__IDLE_LOCAL_CONNECTION__'}

    $ms=New-Object IO.MemoryStream
    $buf=New-Object byte[] 8192
    $headerEnd=-1
    while($headerEnd -lt 0){
        $n=$Stream.Read($buf,0,$buf.Length);if($n -le 0){break};$ms.Write($buf,0,$n)
        if($ms.Length -gt 131072){throw 'HTTP headers too large.'}
        $headerEnd=Find-HeaderEnd $ms.ToArray()
    }
    $all=$ms.ToArray();if($headerEnd -lt 0){throw 'Malformed local HTTP request.'}
    $head=[Text.Encoding]::ASCII.GetString($all,0,$headerEnd)
    $lines=$head -split "`r`n";$requestLine=$lines[0] -split ' '
    $method=$requestLine[0];$path=$requestLine[1]
    $headers=@{}
    for($i=1;$i -lt $lines.Count;$i++){
        $idx=$lines[$i].IndexOf(':');if($idx -gt 0){$headers[$lines[$i].Substring(0,$idx).Trim().ToLowerInvariant()]=$lines[$i].Substring($idx+1).Trim()}
    }
    $contentLength=0;if($headers.ContainsKey('content-length')){$contentLength=[int]$headers['content-length']}
    $bodyStart=$headerEnd+4;$have=$all.Length-$bodyStart
    while($have -lt $contentLength){$n=$Stream.Read($buf,0,$buf.Length);if($n -le 0){break};$ms.Write($buf,0,$n);$have+=$n}
    $all=$ms.ToArray();$body=''
    if($contentLength -gt 0 -and $all.Length -ge ($bodyStart+$contentLength)){$body=[Text.Encoding]::UTF8.GetString($all,$bodyStart,$contentLength)}
    $ms.Dispose()
    return [pscustomobject]@{Method=$method;Path=$path;Headers=$headers;Body=$body}
}
function Send-Http($Stream,[int]$Code,[string]$Type,[string]$Text){
    $reason='OK';if($Code -eq 404){$reason='Not Found'}elseif($Code -ge 500){$reason='Server Error'}elseif($Code -ge 400){$reason='Bad Request'}
    $body=[Text.Encoding]::UTF8.GetBytes($Text)
    $head="HTTP/1.1 $Code $reason`r`nContent-Type: $Type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head);$Stream.Write($hb,0,$hb.Length);$Stream.Write($body,0,$body.Length);$Stream.Flush()
}
function Send-Json($Stream,$Object,[int]$Code=200){Send-Http $Stream $Code 'application/json; charset=utf-8' ($Object|ConvertTo-Json -Depth 100)}
function Body-Json($R){if([string]::IsNullOrWhiteSpace($R.Body)){return $null};return ($R.Body|ConvertFrom-Json)}
function Get-DeepScreenshotSnapshot([string]$Question='') {
    $dir=Join-Path $Root '_DROP_SCREENSHOTS_HERE'
    $allowed=@('.png','.jpg','.jpeg','.webp','.gif')
    $maxEach=8MB;$maxTotal=20MB
    $all=@(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object {$allowed -contains $_.Extension.ToLowerInvariant()} | Sort-Object LastWriteTime -Descending)
    $q=([string]$Question).ToLowerInvariant()
    $nl=$null;try{$nl=Get-NaturalLanguageResearchClassification $Root $Question}catch{}
    $cats=@();try{$cats=@($nl.categories)}catch{}
    $explicitScreenshot=[regex]::IsMatch($q,'\b(screenshot|screenshots|image|images|these pics|these pictures|attached)\b')
    $broadTeam=(@($cats | Where-Object {$_ -in @('CAPTAINCY','BENCH_LINEUP','CHIP_DECISION')}).Count -gt 0 -or [regex]::IsMatch($q,'\b(whole team|entire team|full squad|what should i do|suggest.*changes|gameweek plan)\b'))
    $focused=(@($nl.mentioned_players).Count -gt 0 -and -not $broadTeam)
    $maxFiles=if($explicitScreenshot){8}elseif($focused){3}elseif($broadTeam){5}else{4}
    $idx=@{};try{foreach($x in @(Get-ScreenshotEvidenceIndex $Root)){$idx[[string]$x.file_name]=$x}}catch{}
    $ranked=@()
    $ordinal=0
    foreach($file in $all){
        $ordinal++;$score=[math]::Max(0,30-$ordinal);$cl=$null
        $ageHours=[math]::Max(0,((Get-Date)-$file.LastWriteTime).TotalHours)
        # Old screenshots remain preserved for research, but should not keep entering
        # current decisions merely because they are still in the inbox.
        if(-not $explicitScreenshot){
            if($ageHours -gt 168){$score-=90}elseif($ageHours -gt 72){$score-=35}elseif($ageHours -gt 24){$score-=10}
        }
        if($idx.ContainsKey($file.Name)){$cl=$idx[$file.Name];$score+=15}
        if($cl){
            foreach($entity in @($cl.entities)){
                $e=([string]$entity).Trim().ToLowerInvariant();if($e.Length -ge 3 -and $q.Contains($e)){$score+=120}
            }
            $typ=([string]$cl.screenshot_type).ToUpperInvariant();$claim=([string]$cl.claim_type).ToUpperInvariant()
            if($focused -and $typ -in @('PLAYER_STATS','FIXTURE','MATCH_TACTICAL','NEWS_REPORT')){$score+=35}
            if($broadTeam -and $typ -eq 'TEAM_SQUAD'){$score+=45}
            if($broadTeam){
                try{if($cl.current_team_candidate -eq $true){$score+=140}}catch{}
                try{if(([string]$cl.owner_scope).ToUpperInvariant() -eq 'SELF'){$score+=55}elseif(([string]$cl.owner_scope).ToUpperInvariant() -eq 'OTHER_MANAGER'){$score-=120}}catch{}
                try{if(([string]$cl.screen_context).ToUpperInvariant() -in @('PICK_TEAM','TRANSFERS')){$score+=70}}catch{}
            }
            if([regex]::IsMatch($q,'\b(says|said|opinion|thinks|likes|member|analyst|hunch|view)\b') -and ($typ -eq 'SOCIAL_OPINION' -or $claim -in @('OPINION','HUNCH','PREDICTION'))){$score+=55}
            if(@($cats) -contains 'RIVAL_CONTEXT' -and $typ -eq 'LEAGUE_STANDINGS'){$score+=45}
        }else{$score+=12}
        $ranked += [pscustomobject]@{file=$file;score=$score;classification=$cl}
    }
    $selected=New-Object System.Collections.ArrayList;$skipped=New-Object System.Collections.ArrayList;[long]$total=0
    foreach($row in @($ranked | Sort-Object -Property @{Expression={$_.score};Descending=$true},@{Expression={$_.file.LastWriteTime};Descending=$true})){
        $file=$row.file
        if($selected.Count -ge $maxFiles){[void]$skipped.Add(($file.Name+' | relevance/file limit'));continue}
        if($file.Length -gt $maxEach){[void]$skipped.Add(($file.Name+' | over 8 MB'));continue}
        if(($total+$file.Length) -gt $maxTotal){[void]$skipped.Add(($file.Name+' | total image budget'));continue}
        [void]$selected.Add($file.Name);$total += $file.Length
    }
    $signature=(@($selected) -join '|')
    return [pscustomobject]@{names=@($selected);selected_count=$selected.Count;available_count=$all.Count;skipped=@($skipped);total_bytes=$total;signature=$signature;selection_mode='RELEVANCE_AWARE';max_files=$maxFiles}
}

# Single-instance guard.
# Older builds could leave multiple local servers open on 8765/8766/8767,
# which is confusing and wastes resources. From v2.3.7 onward, only one
# Control Center instance should run for this Windows user.
$runtimeDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
$runtimePath=Join-Path $runtimeDir 'control_center_runtime.json'

$mutex=New-Object System.Threading.Mutex($false,'Local\FPLDecisionEngineControlCenter_v237')
$hasMutex=$false
try{
    try{$hasMutex=$mutex.WaitOne(0,$false)}
    catch [System.Threading.AbandonedMutexException]{$hasMutex=$true}
}catch{$hasMutex=$false}

if(-not $hasMutex){
    $existing=Read-JsonSafe $runtimePath
    if($existing -and $existing.url){
        Write-Host "Control Center is already running at $($existing.url)" -ForegroundColor Yellow
        $existingUrl=[string]$existing.url

        $chromeCandidates=@()
        try{$reg=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop;if($reg.'(default)'){$chromeCandidates += [string]$reg.'(default)'}}catch{}
        try{$reg=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop;if($reg.'(default)'){$chromeCandidates += [string]$reg.'(default)'}}catch{}
        if($env:ProgramFiles){$chromeCandidates += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')}
        if(${env:ProgramFiles(x86)}){$chromeCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')}
        if($env:LOCALAPPDATA){$chromeCandidates += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')}
        $existingChrome=$chromeCandidates | Where-Object {$_ -and (Test-Path $_)} | Select-Object -First 1

        if($existingChrome){Start-Process -FilePath $existingChrome -ArgumentList @('--new-tab',$existingUrl)}
        else{Start-Process $existingUrl}
        exit
    }else{
        Write-Host 'Another Control Center instance appears to be running.' -ForegroundColor Yellow
        Write-Host 'Close old FPL Control Center PowerShell windows, then launch again.' -ForegroundColor Yellow
        exit
    }
}

$listener=$null;$bound=$false
for($p=$Port;$p -lt ($Port+20);$p++){
    try{$listener=New-Object System.Net.Sockets.TcpListener -ArgumentList @([Net.IPAddress]::Loopback,$p);$listener.Start();$Port=$p;$bound=$true;break}catch{if($listener){try{$listener.Stop()}catch{}}}
}
if(-not $bound){throw 'Could not open a local Control Center port.'}
$url="http://127.0.0.1:$Port/"
Write-JsonUtf8 ([ordered]@{
    pid=$PID
    port=$Port
    url=$url
    started_at=(Get-Date).ToString('o')
    version='4.1.2'
}) $runtimePath 20

Write-Host 'FPL Decision Engine v4.1.2 Decision + Research Platform' -ForegroundColor Cyan
Write-Host "Local dashboard: $url" -ForegroundColor Green
Write-Host 'Close this PowerShell window to stop the local dashboard.' -ForegroundColor DarkGray

# v2.5 sync jobs run in a separate background PowerShell process so the
# dashboard remains responsive and can poll progress. Only recover SYNCING when
# the recorded worker process is no longer alive.
$startupSyncPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
$startupSync=Read-JsonSafe $startupSyncPath
if($startupSync -and ([string]$startupSync.status).ToUpperInvariant() -eq 'SYNCING'){
    $workerAlive=$false
    try{
        if($startupSync.process_id){
            $workerAlive=($null -ne (Get-Process -Id ([int]$startupSync.process_id) -ErrorAction SilentlyContinue))
        }
    }catch{$workerAlive=$false}

    if(-not $workerAlive){
        $now=Get-Date
        $syncStarted=$null
        try{
            if($startupSync.started_at_local){$syncStarted=[datetime]::Parse([string]$startupSync.started_at_local)}
        }catch{}
        $duration=$null
        if($syncStarted){
            $duration=[math]::Round(($now-$syncStarted).TotalSeconds,1)
            if($duration -lt 0){$duration=$null}
        }
        Write-JsonUtf8 ([ordered]@{
            status='PARTIAL'
            mode=if($startupSync.mode){$startupSync.mode}else{'UNKNOWN'}
            run_id=$startupSync.run_id
            process_id=$startupSync.process_id
            started_at_local=if($startupSync.started_at_local){[string]$startupSync.started_at_local}else{$null}
            completed_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
            duration_seconds=$duration
            current_source=$null
            sources=@($startupSync.sources)
            recovered_stale_sync=$true
            recovered_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
            summary='Previous background sync worker is no longer running. The stale SYNCING marker was cleared automatically and data already fetched was retained.'
        }) $startupSyncPath 40
        Write-Host 'Recovered stale background sync marker from the previous run.' -ForegroundColor Yellow
    }else{
        Write-Host ("Background sync worker is still active (PID {0}). Dashboard will keep polling progress." -f $startupSync.process_id) -ForegroundColor DarkCyan
    }
}

function Get-PowerShellWorkerExe {
    $candidate=$null
    try{
        if($PSVersionTable.PSEdition -eq 'Core'){$candidate=Join-Path $PSHOME 'pwsh.exe'}
        else{$candidate=Join-Path $PSHOME 'powershell.exe'}
    }catch{}
    if($candidate -and (Test-Path $candidate)){return $candidate}
    return 'powershell.exe'
}

function Test-SyncWorkerAlive($Run){
    if(-not $Run -or ([string]$Run.status).ToUpperInvariant() -ne 'SYNCING'){return $false}
    try{
        if($Run.process_id){
            return ($null -ne (Get-Process -Id ([int]$Run.process_id) -ErrorAction SilentlyContinue))
        }
    }catch{}
    return $false
}

function Test-CloseGameweekWorkerAlive($Run){
    if(-not $Run -or ([string]$Run.status).ToUpperInvariant() -ne 'CLOSING'){return $false}
    try{
        if($Run.process_id){
            return ($null -ne (Get-Process -Id ([int]$Run.process_id) -ErrorAction SilentlyContinue))
        }
    }catch{}
    return $false
}

function Start-CloseGameweekBackground {
    $statePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_close_gameweek.json'
    $existing=Read-JsonSafe $statePath
    if(Test-CloseGameweekWorkerAlive $existing){
        return ("GW{0} is already closing (PID {1})." -f $existing.gameweek,$existing.process_id)
    }

    $syncPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
    $syncRun=Read-JsonSafe $syncPath
    if(Test-SyncWorkerAlive $syncRun){
        return 'A Live Sync / Deep Refresh is still running. Let it finish before closing the gameweek.'
    }

    $runner=Join-Path $PSScriptRoot 'Close-Gameweek.ps1'
    if(-not (Test-Path $runner)){throw 'Close-Gameweek.ps1 is missing.'}
    $targetGameweek=Get-LatestLockedGameweek $Root
    if($targetGameweek -le 0){$targetGameweek=Get-EngineGameweek $Root}
    $runId=[guid]::NewGuid().ToString('N')
    $started=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status='CLOSING'
        run_id=$runId
        process_id=$null
        gameweek=$targetGameweek
        stage='STARTING'
        progress_current=0
        progress_total=5
        progress_percent=0
        started_at_local=$started.ToString('yyyy-MM-dd HH:mm:ss')
        heartbeat_at_local=$started.ToString('yyyy-MM-dd HH:mm:ss')
        completed_at_local=$null
        duration_seconds=0
        message=("Starting fast GW{0} archive worker." -f $targetGameweek)
        review_pack=$null
        archive_path=$null
        error=$null
    }) $statePath 40

    $exe=Get-PowerShellWorkerExe
    $logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog=Join-Path $logDir 'close_gameweek_stdout.log'
    $errLog=Join-Path $logDir 'close_gameweek_stderr.log'
    try{Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8}catch{}
    try{Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8}catch{}
    $workerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Gameweek $targetGameweek -NoExplorer -RunId $runId"
    try{
        $workerProcess=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        Start-Sleep -Milliseconds 80
        $cur=Read-JsonSafe $statePath
        if($cur -and ([string]$cur.run_id) -eq $runId -and -not $cur.process_id){
            $cur.process_id=$workerProcess.Id
            $cur.heartbeat_at_local=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Write-JsonUtf8 $cur $statePath 40
        }
        return ("Closing GW{0} from cached final state. Progress will stay visible here." -f $targetGameweek)
    }catch{
        $now=Get-Date
        Write-JsonUtf8 ([ordered]@{
            status='FAILED';run_id=$runId;process_id=$null;gameweek=$targetGameweek;stage='START_FAILED';progress_current=0;progress_total=5;progress_percent=0;started_at_local=$started.ToString('yyyy-MM-dd HH:mm:ss');heartbeat_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss');completed_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss');duration_seconds=[math]::Round(($now-$started).TotalSeconds,1);message=('Could not launch gameweek close worker: '+$_.Exception.Message);review_pack=$null;archive_path=$null;error=$_.Exception.Message
        }) $statePath 40
        throw
    }
}


function Set-ObjectNoteProperty($Object,[string]$Name,$Value){
    if($null -eq $Object){return}
    $prop=$Object.PSObject.Properties[$Name]
    if($null -ne $prop){
        $Object.$Name=$Value
    }else{
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Start-CopilotAiWorker {
    $workerStatusPath=Join-Path $Root '04_OUTPUT\DASHBOARD\copilot_ai_worker.json'
    $existing=Read-JsonSafe $workerStatusPath
    if($existing -and $existing.process_id){
        try{
            $p=Get-Process -Id ([int]$existing.process_id) -ErrorAction SilentlyContinue
            if($p){return $existing.process_id}
        }catch{}
    }

    $runner=Join-Path $PSScriptRoot 'Run-CopilotAI.ps1'
    if(-not (Test-Path $runner)){throw 'Run-CopilotAI.ps1 is missing.'}
    $exe=Get-PowerShellWorkerExe
    $logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog=Join-Path $logDir 'copilot_ai_stdout.log'
    $errLog=Join-Path $logDir 'copilot_ai_stderr.log'
    try{Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8}catch{}
    try{Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8}catch{}

    $workerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Root `"$Root`""
    $proc=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    Write-JsonUtf8 ([ordered]@{
        status='STARTING';process_id=$proc.Id;started_at=(Get-Date).ToString('o');heartbeat=(Get-Date).ToString('o')
    }) $workerStatusPath 30
    return $proc.Id
}


function Start-EvidenceClassifierWorker {
    $statusPath=Join-Path $Root '04_OUTPUT\DASHBOARD\evidence_classifier_worker.json'
    $existing=Read-JsonSafe $statusPath
    if($existing -and $existing.process_id){try{$p=Get-Process -Id ([int]$existing.process_id) -ErrorAction SilentlyContinue;if($p){return $existing.process_id}}catch{}}
    $runner=Join-Path $PSScriptRoot 'Evidence-Classifier.ps1';if(-not (Test-Path $runner)){return $null}
    $exe=Get-PowerShellWorkerExe;$logDir=Join-Path $Root '04_OUTPUT\DASHBOARD';New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $workerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Root `"$Root`""
    $proc=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logDir 'evidence_classifier_stdout.log') -RedirectStandardError (Join-Path $logDir 'evidence_classifier_stderr.log')
    Write-JsonUtf8 ([ordered]@{status='STARTING';process_id=$proc.Id;started_at=(Get-Date).ToString('o')}) $statusPath 30
    return $proc.Id
}

function Start-LeagueRefreshBackground([int]$LeagueId){
    if($LeagueId -le 0){throw 'Select a valid league first.'}
    $runner=Join-Path $PSScriptRoot 'Sync-SelectedLeague.ps1'
    if(-not (Test-Path $runner)){throw 'Sync-SelectedLeague.ps1 is missing.'}

    $statePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_league_refresh.json'
    $existing=Read-JsonSafe $statePath
    if($existing -and ([string]$existing.status).ToUpperInvariant() -eq 'SYNCING' -and $existing.process_id){
        try{
            $existingProcess=Get-Process -Id ([int]$existing.process_id) -ErrorAction SilentlyContinue
            if($existingProcess){return "League $($existing.league_id) is already refreshing."}
        }catch{}
    }

    $exe=Get-PowerShellWorkerExe
    $logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog=Join-Path $logDir 'league_refresh_stdout.log'
    $errLog=Join-Path $logDir 'league_refresh_stderr.log'
    try{Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8}catch{}
    try{Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8}catch{}

    $leagueWorkerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -LeagueId $LeagueId -Quiet"
    $workerProcess=Start-Process -FilePath $exe -ArgumentList $leagueWorkerArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    Write-JsonUtf8 ([ordered]@{status='SYNCING';league_id=$LeagueId;process_id=$workerProcess.Id;started_at_local=(Get-Date).ToString('o');heartbeat_at_local=(Get-Date).ToString('o');message='Selected league refresh worker starting.'}) $statePath 30
    return "Refreshing selected league $LeagueId directly."
}


function Start-LiveTickBackground {
    $statePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_live_tick.json'
    $existing=Read-JsonSafe $statePath
    if($existing -and ([string]$existing.status).ToUpperInvariant() -eq 'SYNCING' -and $existing.process_id){
        try{
            $p=Get-Process -Id ([int]$existing.process_id) -ErrorAction SilentlyContinue
            if($p){return 'Matchday live refresh is already running.'}
        }catch{}
    }
    $syncPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
    $syncRun=Read-JsonSafe $syncPath
    if(Test-SyncWorkerAlive $syncRun){return 'Full Live Sync is already refreshing the same live feeds.'}
    $runner=Join-Path $PSScriptRoot 'Sync-MatchdayLive.ps1'
    if(-not (Test-Path $runner)){throw 'Sync-MatchdayLive.ps1 is missing.'}
    $exe=Get-PowerShellWorkerExe
    $logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog=Join-Path $logDir 'live_tick_stdout.log';$errLog=Join-Path $logDir 'live_tick_stderr.log'
    try{Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8;Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8}catch{}
    $runId=[guid]::NewGuid().ToString('N');$now=Get-Date
    Write-JsonUtf8 ([ordered]@{status='SYNCING';run_id=$runId;process_id=$null;started_at_local=$now.ToString('o');heartbeat_at_local=$now.ToString('o');completed_at_local=$null;message='Refreshing Official event-live + LiveFPL matchday feeds.'}) $statePath 30
    $workerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Quiet -RunId $runId"
    $proc=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    Start-Sleep -Milliseconds 60
    $cur=Read-JsonSafe $statePath
    if($cur -and ([string]$cur.run_id) -eq $runId -and -not $cur.process_id){$cur.process_id=$proc.Id;$cur.heartbeat_at_local=(Get-Date).ToString('o');Write-JsonUtf8 $cur $statePath 30}
    return 'Matchday live refresh started.'
}

function Start-SyncBackground([ValidateSet('Quick','Full')][string]$Mode){
    $closeState=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_close_gameweek.json')
    if(Test-CloseGameweekWorkerAlive $closeState){
        return ("GW{0} close is running. Live Sync / Deep Refresh is temporarily locked until it finishes." -f $closeState.gameweek)
    }
    $syncPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
    $existing=Read-JsonSafe $syncPath
    if(Test-SyncWorkerAlive $existing){
        return ("A {0} sync is already running (PID {1})." -f $existing.mode,$existing.process_id)
    }

    $runner=Join-Path $PSScriptRoot 'Run-Sync.ps1'
    if(-not (Test-Path $runner)){throw 'Run-Sync.ps1 is missing.'}

    # Write STARTING before launching. The worker owns subsequent status writes.
    # This removes the v2.5.0 race where parent + worker could overwrite
    # last_sync.json at almost the same instant.
    $seedRunId=[guid]::NewGuid().ToString('N')
    $seedStarted=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status='SYNCING'
        mode=$Mode.ToUpperInvariant()
        run_id=$seedRunId
        process_id=$null
        started_at_local=$seedStarted.ToString('yyyy-MM-dd HH:mm:ss')
        completed_at_local=$null
        heartbeat_at_local=$seedStarted.ToString('yyyy-MM-dd HH:mm:ss')
        duration_seconds=0
        current_source='STARTING'
        sources=@()
        summary=if($Mode -eq 'Quick'){'Live Sync worker is starting.'}else{'Deep Refresh worker is starting.'}
    }) $syncPath 40

    $exe=Get-PowerShellWorkerExe
    $syncWorkerArgs="-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode $Mode -Quiet"

    $logDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog=Join-Path $logDir 'sync_worker_stdout.log'
    $errLog=Join-Path $logDir 'sync_worker_stderr.log'
    try{
        # Clear only diagnostic logs, never sync/state data.
        Set-Content -LiteralPath $outLog -Value '' -Encoding UTF8
        Set-Content -LiteralPath $errLog -Value '' -Encoding UTF8

        $proc=Start-Process -FilePath $exe -ArgumentList $syncWorkerArgs -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog

        # If the worker has not yet written its own status, attach its PID to
        # the provisional STARTING record. Never overwrite real worker progress.
        Start-Sleep -Milliseconds 80
        $cur=Read-JsonSafe $syncPath
        if($cur -and ([string]$cur.run_id) -eq $seedRunId -and ([string]$cur.current_source) -eq 'STARTING'){
            $cur.process_id=$proc.Id
            $cur.heartbeat_at_local=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Write-JsonUtf8 $cur $syncPath 40
        }

        $syncLabel=if($Mode -eq 'Quick'){'Live Sync'}else{'Deep Refresh'}
        return ("{0} started in background (PID {1}). Dashboard remains responsive." -f $syncLabel,$proc.Id)
    }catch{
        $now=Get-Date
        Write-JsonUtf8 ([ordered]@{
            status='FAILED'
            mode=$Mode.ToUpperInvariant()
            run_id=$seedRunId
            process_id=$null
            started_at_local=$seedStarted.ToString('yyyy-MM-dd HH:mm:ss')
            completed_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
            heartbeat_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
            duration_seconds=[math]::Round(($now-$seedStarted).TotalSeconds,1)
            current_source=$null
            sources=@()
            summary=('Could not launch sync worker: ' + $_.Exception.Message)
            worker_stderr_log=$errLog
        }) $syncPath 40
        throw
    }
}

function Cancel-SyncBackground {
    $syncPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_sync.json'
    $run=Read-JsonSafe $syncPath
    if(-not $run -or ([string]$run.status).ToUpperInvariant() -ne 'SYNCING'){
        return 'No active sync is running.'
    }

    $stopped=$false
    try{
        if($run.process_id){
            $p=Get-Process -Id ([int]$run.process_id) -ErrorAction SilentlyContinue
            if($p){Stop-Process -Id $p.Id -Force -ErrorAction Stop;$stopped=$true}
        }
    }catch{}

    $now=Get-Date
    Write-JsonUtf8 ([ordered]@{
        status='PARTIAL'
        mode=$run.mode
        run_id=$run.run_id
        process_id=$run.process_id
        started_at_local=$run.started_at_local
        completed_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
        duration_seconds=$run.duration_seconds
        current_source=$null
        sources=@($run.sources)
        cancelled=$true
        summary='Sync cancelled by user. Completed source data was retained; unfinished sources were left on their previous cache.'
    }) $syncPath 40

    if($stopped){return 'Active sync cancelled. Completed source data was retained.'}
    return 'Sync worker was already gone; stale state was cleared.'
}

# v2.6.2 Copilot queue recovery.
# The v2.6.1 launcher could save a question and then fail while assigning its
# worker process to $pid (which collides with PowerShell's read-only $PID).
# Recover already-saved questions automatically and do not pay twice for
# accidental duplicates.
try{
    $copilotThreadPath=Join-Path $Root '06_CONFIG\copilot_thread.json'
    $copilotThreadStartup=Read-JsonSafe $copilotThreadPath
    if($copilotThreadStartup -and $copilotThreadStartup.messages){
        $startupMessages=@($copilotThreadStartup.messages)

        $workerStatePath=Join-Path $Root '04_OUTPUT\DASHBOARD\copilot_ai_worker.json'
        $workerState=Read-JsonSafe $workerStatePath
        $copilotWorkerAlive=$false
        if($workerState -and $workerState.process_id){
            try{
                $copilotWorkerAlive=($null -ne (Get-Process -Id ([int]$workerState.process_id) -ErrorAction SilentlyContinue))
            }catch{$copilotWorkerAlive=$false}
        }

        # If the old worker vanished while a request was marked RUNNING,
        # safely return it to QUEUED for one retry.
        if(-not $copilotWorkerAlive){
            foreach($m in $startupMessages){
                if(([string]$m.role).ToUpperInvariant() -eq 'USER' -and
                   ([string]$m.mode).ToUpperInvariant() -in @('API','API_DEEP') -and
                   ([string]$m.status).ToUpperInvariant() -eq 'RUNNING'){
                    Set-ObjectNoteProperty $m 'status' 'QUEUED'
                    try{$m.PSObject.Properties.Remove('started_at')}catch{}
                }
            }
        }

        # Deduplicate unresolved paid questions. Keep the oldest item; mark
        # later identical ones CANCELLED_DUPLICATE so the worker ignores them.
        $seen=@{}
        foreach($m in @($startupMessages | Where-Object {
            ([string]$_.role).ToUpperInvariant() -eq 'USER' -and
            ([string]$_.mode).ToUpperInvariant() -in @('API','API_DEEP') -and
            ([string]$_.status).ToUpperInvariant() -in @('QUEUED','RUNNING')
        } | Sort-Object created_at)){
            $key=(
                ([string]$m.mode).ToUpperInvariant()+'|'+
                ([string]$m.text).Trim().ToLowerInvariant()+'|'+
                ([string][bool]$m.use_web).ToLowerInvariant()+'|'+
                ([string]$m.league_id)
            )
            if($seen.ContainsKey($key)){
                Set-ObjectNoteProperty $m 'status' 'CANCELLED_DUPLICATE'
                Set-ObjectNoteProperty $m 'completed_at' (Get-Date).ToString('o')
                Set-ObjectNoteProperty $m 'error' 'Duplicate unresolved AI question collapsed automatically; no API request was made.'
            }else{
                $seen[$key]=$true
            }
        }

        $copilotThreadStartup.messages=@($startupMessages)
        $copilotThreadStartup.updated_at=(Get-Date).ToString('o')
        Write-JsonUtf8 $copilotThreadStartup $copilotThreadPath 100

        $queuedCount=@($startupMessages | Where-Object {
            ([string]$_.role).ToUpperInvariant() -eq 'USER' -and
            ([string]$_.mode).ToUpperInvariant() -in @('API','API_DEEP') -and
            ([string]$_.status).ToUpperInvariant() -eq 'QUEUED'
        }).Count

        $apiKeyPath=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
        if($queuedCount -gt 0 -and (Test-Path $apiKeyPath) -and -not $copilotWorkerAlive){
            $startupWorkerProcessId=Start-CopilotAiWorker
            Write-Host ("Recovered {0} queued Copilot AI question(s); worker started automatically (PID {1})." -f $queuedCount,$startupWorkerProcessId) -ForegroundColor DarkCyan
        }
    }
}catch{
    Write-Host ("Copilot queue recovery warning: "+$_.Exception.Message) -ForegroundColor Yellow
}

# /api/status used to rebuild every rival comparison on every browser poll.
# Keep a short in-process cache while idle, but collapse the TTL during sync so
# progress remains responsive. Any POST invalidates the cache immediately.
$script:statusCache=$null
$script:statusCacheAt=[datetime]::MinValue
function Get-ControlCenterStatusCached {
    $now=Get-Date
    $ttlSeconds=6.0
    if($script:statusCache -and ([string]$script:statusCache.sync_run.status).ToUpperInvariant() -eq 'SYNCING'){$ttlSeconds=0.75}
    if($script:statusCache -and ([string]$script:statusCache.close_gameweek_run.status).ToUpperInvariant() -eq 'CLOSING'){$ttlSeconds=0.75}
    if($script:statusCache -and ($now-$script:statusCacheAt).TotalSeconds -lt $ttlSeconds){return $script:statusCache}
    $freshStatus=Get-ControlCenterStatus $Root
    $script:statusCache=$freshStatus
    $script:statusCacheAt=$now
    return $freshStatus
}
function Invalidate-ControlCenterStatusCache {
    $script:statusCacheAt=[datetime]::MinValue
}

# v2.8 startup freshness gate. Opening the cockpit should normally be enough:
# if core data is absent/stale, launch the fast sync in the background without
# blocking page load. Automatic league intelligence is detached by Run-Sync.
try{
    $startupConn=Read-JsonSafe (Join-Path $Root '06_CONFIG\fpl_connection.json')
    if($startupConn -and $startupConn.team_id){
        $startupStatus=Get-ControlCenterStatus $Root
        $coreStale=$false
        if($startupStatus.freshness.official_fpl.age_seconds -eq $null -or [double]$startupStatus.freshness.official_fpl.age_seconds -gt 120){$coreStale=$true}
        if($startupStatus.freshness.fpl_account.age_seconds -eq $null -or [double]$startupStatus.freshness.fpl_account.age_seconds -gt 180){$coreStale=$true}
        if($startupStatus.freshness.livefpl.age_seconds -eq $null -or [double]$startupStatus.freshness.livefpl.age_seconds -gt 120){$coreStale=$true}
        if($coreStale -and -not (Test-SyncWorkerAlive $startupStatus.sync_run)){
            $null=Start-SyncBackground 'Quick'
            Write-Host 'Startup Live Sync launched automatically because cached live data is stale.' -ForegroundColor DarkCyan
        }
    }
}catch{
    Write-Host ('Startup freshness check was skipped: '+$_.Exception.Message) -ForegroundColor DarkGray
}

# Prefer Google Chrome for this local app without changing the Windows-wide default browser.
$chromeCandidates=@()
try{$reg=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop;if($reg.'(default)'){$chromeCandidates += [string]$reg.'(default)'}}catch{}
try{$reg=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop;if($reg.'(default)'){$chromeCandidates += [string]$reg.'(default)'}}catch{}
if($env:ProgramFiles){$chromeCandidates += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')}
if(${env:ProgramFiles(x86)}){$chromeCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')}
if($env:LOCALAPPDATA){$chromeCandidates += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')}
$chrome=$chromeCandidates | Where-Object {$_ -and (Test-Path $_)} | Select-Object -First 1
if($chrome){
    Write-Host 'Opening Control Center in Google Chrome.' -ForegroundColor Green
Write-Host 'Server is READY. If Chrome ever spins for more than ~3 seconds, refresh once.' -ForegroundColor DarkGray
    Start-Process -FilePath $chrome -ArgumentList @('--new-tab',$url)
}else{
    Write-Host 'Google Chrome was not found. Falling back to the Windows default browser.' -ForegroundColor Yellow
    Start-Process $url
}
while($true){
    $client=$listener.AcceptTcpClient();$stream=$client.GetStream()
    try{
        $r=Read-HttpRequest $stream;$path=($r.Path -split '\?')[0].ToLowerInvariant()
        if($r.Method -eq 'POST'){Invalidate-ControlCenterStatusCache}
        if($r.Method -eq 'GET' -and $path -eq '/'){
            Send-Http $stream 200 'text/html; charset=utf-8' (Get-Content $dashboardPath -Raw -Encoding UTF8)
        }
        elseif($r.Method -eq 'GET' -and $path -eq '/playbook'){Send-Http $stream 200 'text/html; charset=utf-8' (Get-Content $playbookPath -Raw -Encoding UTF8)}
        elseif($r.Method -eq 'GET' -and $path -eq '/api/status'){Send-Json $stream (Get-ControlCenterStatusCached)}
        elseif($r.Method -eq 'POST' -and $path -eq '/api/connect'){
            $b=Body-Json $r
            $teamRaw=([string]$b.team_id).Trim()
            $m=[regex]::Match($teamRaw,'(?i)(?:/entry/)?(\d+)')
            if(-not $m.Success){throw 'Enter a numeric FPL Team ID or paste an FPL /entry/ URL.'}

            $cp=Join-Path $Root '06_CONFIG\fpl_connection.json'
            $c=Read-JsonSafe $cp
            if(-not $c){
                $c=[pscustomobject]@{
                    team_id=$null
                    tracked_league_ids=@()
                    private_current_team_enabled=$false
                    livefpl_enabled=$true
                    livefpl_planner_id=$null
                    livefpl_auto_sync=$true
                }
            }

            foreach($prop in @('team_id','tracked_league_ids','private_current_team_enabled','livefpl_enabled','livefpl_planner_id','livefpl_auto_sync')){
                if(-not ($c.PSObject.Properties.Name -contains $prop)){
                    $default=$null
                    if($prop -eq 'tracked_league_ids'){$default=@()}
                    if($prop -eq 'private_current_team_enabled'){$default=$false}
                    if($prop -eq 'livefpl_enabled' -or $prop -eq 'livefpl_auto_sync'){$default=$true}
                    $c | Add-Member -NotePropertyName $prop -NotePropertyValue $default
                }
            }

            $c.team_id=[int]$m.Groups[1].Value
            $c.private_current_team_enabled=($b.private_enabled -eq $true)

            $plannerRaw=([string]$b.livefpl_planner_id).Trim()
            if([string]::IsNullOrWhiteSpace($plannerRaw)){
                $c.livefpl_planner_id=$null
            }else{
                $pm=[regex]::Match($plannerRaw,'(?i)(?:[?&]id=|\bID\s*[:#]?\s*|planner/)?(\d+)')
                if(-not $pm.Success){throw 'LiveFPL Planner ID must be numeric, or paste a planner URL containing id=...'}
                $c.livefpl_planner_id=[int]$pm.Groups[1].Value
            }

            $c.livefpl_enabled=$true
            $c.livefpl_auto_sync=$true

            $leagueIds=@()
            $invalidLeagueLines=@()
            $rawLinks=[string]$b.league_links
            if(-not [string]::IsNullOrWhiteSpace($rawLinks)){
                foreach($rawLine in ($rawLinks -split '[\r\n,;]+')){
                    $line=$rawLine.Trim()
                    if([string]::IsNullOrWhiteSpace($line)){continue}
                    $id=$null
                    if($line -match '^\d+$'){
                        $id=[int]$line
                    }else{
                        $lm=[regex]::Match($line,'(?i)/leagues/(?:classic/)?(\d+)(?:/|$)')
                        if(-not $lm.Success){$lm=[regex]::Match($line,'(?i)leagues-classic/(\d+)')}
                        if($lm.Success){$id=[int]$lm.Groups[1].Value}
                    }
                    if($id){$leagueIds += $id}else{$invalidLeagueLines += $line}
                }
            }
            $c.tracked_league_ids=@($leagueIds | Select-Object -Unique)

            Write-JsonUtf8 $c $cp 20

            $now=Get-Date
            $connectPath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_connect.json'
            Write-JsonUtf8 ([ordered]@{
                status='SAVED_READY_TO_SYNC'
                team_id=$c.team_id
                league_ids=@($c.tracked_league_ids)
                invalid_league_lines=@($invalidLeagueLines)
                planner_id=$c.livefpl_planner_id
                saved_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
                duration_seconds=0
                sources=@()
            }) $connectPath 30

            $parts=@("Saved Team ID $($c.team_id)")
            $parts += "saved $($c.tracked_league_ids.Count) extra league ID(s)"
            if($invalidLeagueLines.Count -gt 0){$parts += "ignored $($invalidLeagueLines.Count) invalid league line(s)"}
            $parts += 'live data will refresh automatically; Live Sync remains available on demand'

            Send-Json $stream @{
                ok=$true
                connection_saved=$true
                status='SAVED_READY_TO_SYNC'
                message=($parts -join ' | ')
                invalid_league_lines=@($invalidLeagueLines)
            }
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/hunch'){
            $b=Body-Json $r;$player=([string]$b.player).Trim();if([string]::IsNullOrWhiteSpace($player)){throw 'Player or idea was empty.'}
            $stance=([string]$b.stance).Trim();if([string]::IsNullOrWhiteSpace($stance)){$stance='WANT'}
            $conv=3;try{$conv=[int]$b.conviction}catch{};if($conv -lt 1){$conv=1};if($conv -gt 5){$conv=5}
            $note=([string]$b.note).Trim()
            $hp=Join-Path $Root '06_CONFIG\manager_hunch.json'
            $rp=Join-Path $Root '06_CONFIG\hunch_review.json'
            $histPath=Join-Path $Root '02_DATA\PROCESSED\hunch_history.json'
            $old=Read-JsonSafe $hp
            $oldReview=Read-JsonSafe $rp
            $isDifferent=$true
            if($old){
                $isDifferent=(([string]$old.player).Trim().ToLower() -ne $player.ToLower()) -or
                             (([string]$old.stance).Trim().ToUpper() -ne $stance.ToUpper()) -or
                             (([string]$old.note).Trim() -ne $note)
            }
            if($old -and $isDifferent){
                $hist=Read-JsonSafe $histPath;if(-not $hist){$hist=@()}
                $entry=[ordered]@{
                    archived_at=(Get-Date).ToString('o')
                    hunch=$old
                    review=if($oldReview){$oldReview}else{$null}
                }
                $hist=@($entry)+@($hist)
                if($hist.Count -gt 100){$hist=@($hist | Select-Object -First 100)}
                Write-JsonUtf8 $hist $histPath 50
                if(Test-Path $rp){Remove-Item $rp -Force}
            }
            $hunchId=$null
            if($old -and -not $isDifferent -and $old.hunch_id){$hunchId=[string]$old.hunch_id}
            if([string]::IsNullOrWhiteSpace($hunchId)){$hunchId=[guid]::NewGuid().ToString('N')}
            $h=[ordered]@{
                hunch_id=$hunchId
                player=$player
                stance=$stance
                conviction=$conv
                note=$note
                updated_at=(Get-Date).ToString('o')
                status='ACTIVE'
                instruction='Challenge this hunch against the full model. Research it specifically. Return AGREE, DISAGREE, or COIN-FLIP with evidence and quantify the decision impact where possible. Preserve hunch_id and updated_at in the returned hunch review.'
            }
            Write-JsonUtf8 $h $hp 20
            Send-Json $stream @{ok=$true;message=if($old -and $isDifferent){'New hunch saved. Previous hunch moved to Hunch History.'}else{'Manager hunch saved.'}}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/hunch-clear'){
            $hp=Join-Path $Root '06_CONFIG\manager_hunch.json'
            $rp=Join-Path $Root '06_CONFIG\hunch_review.json'
            $histPath=Join-Path $Root '02_DATA\PROCESSED\hunch_history.json'
            $old=Read-JsonSafe $hp
            $oldReview=Read-JsonSafe $rp
            if($old){
                $hist=Read-JsonSafe $histPath;if(-not $hist){$hist=@()}
                $entry=[ordered]@{archived_at=(Get-Date).ToString('o');hunch=$old;review=if($oldReview){$oldReview}else{$null}}
                $hist=@($entry)+@($hist)
                if($hist.Count -gt 100){$hist=@($hist | Select-Object -First 100)}
                Write-JsonUtf8 $hist $histPath 50
            }
            if(Test-Path $hp){Remove-Item $hp -Force}
            if(Test-Path $rp){Remove-Item $rp -Force}
            Send-Json $stream @{ok=$true;message='Current hunch archived to Hunch History and cleared.'}
        }

        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot'){
            $b=Body-Json $r
            $question=([string]$b.question).Trim()
            if([string]::IsNullOrWhiteSpace($question)){throw 'Copilot question was empty.'}
            if($question.Length -gt 4000){throw 'Copilot question is too long.'}

            $mode=([string]$b.mode).Trim().ToUpperInvariant()
            if($mode -notin @('LOCAL','DEEP')){$mode='DEEP'}
            $localReply=([string]$b.local_reply).Trim()

            $cp=Join-Path $Root '06_CONFIG\copilot_thread.json'
            $thread=Read-JsonSafe $cp
            if(-not $thread){$thread=[pscustomobject]@{version=1;updated_at=$null;messages=@()}}

            $messages=@($thread.messages)
            $qid=[guid]::NewGuid().ToString('N')
            $now=(Get-Date).ToString('o')

            $messages += [pscustomobject][ordered]@{
                message_id=$qid
                role='USER'
                text=$question
                mode=$mode
                status=if($mode -eq 'DEEP'){'PENDING'}else{'RESOLVED'}
                created_at=$now
            }

            if($mode -eq 'LOCAL'){
                if([string]::IsNullOrWhiteSpace($localReply)){
                    $localReply='Local structured data does not contain enough information for that question. Use Deep Ask for a researched answer.'
                }
                $messages += [pscustomobject][ordered]@{
                    message_id=[guid]::NewGuid().ToString('N')
                    role='ASSISTANT_LOCAL'
                    reply_to=$qid
                    text=$localReply
                    status='RESOLVED'
                    created_at=(Get-Date).ToString('o')
                    source='LOCAL_RIVAL_RADAR'
                }
            }

            if($messages.Count -gt 120){$messages=@($messages | Select-Object -Last 120)}
            Write-JsonUtf8 ([ordered]@{version=1;updated_at=(Get-Date).ToString('o');messages=@($messages)}) $cp 80

            Send-Json $stream @{
                ok=$true
                message=if($mode -eq 'DEEP'){'Deep Copilot question queued. Build a ChatGPT Pack to get the researched answer.'}else{'Copilot answered from current local structured data.'}
                question_id=$qid
                mode=$mode
            }
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-clear'){
            $cp=Join-Path $Root '06_CONFIG\copilot_thread.json'
            $histPath=Join-Path $Root '02_DATA\PROCESSED\copilot_history.json'
            $old=Read-JsonSafe $cp

            if($old -and @($old.messages).Count -gt 0){
                $hist=Read-JsonSafe $histPath
                if(-not $hist){$hist=@()}
                $hist=@([pscustomobject][ordered]@{archived_at=(Get-Date).ToString('o');thread=$old})+@($hist)
                if($hist.Count -gt 30){$hist=@($hist | Select-Object -First 30)}
                Write-JsonUtf8 $hist $histPath 100
            }

            if(Test-Path $cp){Remove-Item $cp -Force}
            Send-Json $stream @{ok=$true;message='Copilot conversation archived and cleared.'}
        }


        elseif($r.Method -eq 'POST' -and $path -eq '/api/league-refresh'){
            $b=Body-Json $r
            $leagueId=0
            try{$leagueId=[int]$b.league_id}catch{}
            if($leagueId -le 0){throw 'Select a valid league first.'}
            $msg=Start-LeagueRefreshBackground $leagueId
            Send-Json $stream @{ok=$true;message=$msg;league_id=$leagueId}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-api-key'){
            $b=Body-Json $r
            $key=([string]$b.api_key).Trim()
            if([string]::IsNullOrWhiteSpace($key) -or -not $key.StartsWith('sk-')){
                throw 'Paste a valid OpenAI API key beginning with sk-.'
            }
            $secretDir=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS'
            New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
            $secure=ConvertTo-SecureString $key -AsPlainText -Force
            $cipher=ConvertFrom-SecureString $secure
            Set-Content -LiteralPath (Join-Path $secretDir 'openai_api_key.dpapi') -Value $cipher -Encoding UTF8
            Send-Json $stream @{ok=$true;message='OpenAI API key encrypted locally with Windows DPAPI. It is never returned to the browser or included in ChatGPT packs.'}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-api-key-remove'){
            $keyPath=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
            if(Test-Path $keyPath){Remove-Item $keyPath -Force}
            Send-Json $stream @{ok=$true;message='Local OpenAI API key removed.'}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-api-config'){
            $b=Body-Json $r
            $budget=0.25
            try{$budget=[double]$b.monthly_budget_usd}catch{}
            if($budget -lt 0.05){$budget=0.05}
            if($budget -gt 25){$budget=25}
            $maxOut=700
            try{$maxOut=[int]$b.max_output_tokens}catch{}
            if($maxOut -lt 128){$maxOut=128}
            if($maxOut -gt 1200){$maxOut=1200}

            $cfg=[ordered]@{
                model='gpt-5.4-nano'
                web_model='gpt-5.6-luna'
                deep_model='gpt-5.6-luna'
                monthly_budget_usd=[math]::Round($budget,2)
                max_output_tokens=$maxOut
                deep_max_output_tokens=2600
                allow_web_search=$false
                input_price_per_million=0.20
                output_price_per_million=1.25
                web_input_price_per_million=0.50
                web_output_price_per_million=3.00
                web_search_price_per_call=0.01
                pricing_checked='2026-08-25'
            }
            Write-JsonUtf8 $cfg (Join-Path $Root '06_CONFIG\copilot_api_config.json') 30
            Send-Json $stream @{ok=$true;message=("Low-cost AI settings saved. App-local monthly guard: ${0:N2}." -f $budget)}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-ai-test'){
            $keyPath=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
            if(-not (Test-Path $keyPath)){throw 'Set your OpenAI API key first.'}
            $cp=Join-Path $Root '06_CONFIG\copilot_thread.json'
            $thread=Read-JsonSafe $cp
            if(-not $thread){$thread=[pscustomobject]@{version=1;updated_at=$null;messages=@()}}
            $messages=@($thread.messages)
            # Avoid stacking connection tests.
            $existing=$messages | Where-Object {([string]$_.mode) -eq 'API_TEST' -and ([string]$_.status) -in @('QUEUED','RUNNING')} | Select-Object -First 1
            if(-not $existing){
                $qid=[guid]::NewGuid().ToString('N')
                $messages += [pscustomobject][ordered]@{message_id=$qid;role='USER';text='API connection test';mode='API_TEST';status='QUEUED';use_web=$false;created_at=(Get-Date).ToString('o')}
                Write-JsonUtf8 ([ordered]@{version=1;updated_at=(Get-Date).ToString('o');messages=@($messages)}) $cp 90
            }
            $workerProcessId=Start-CopilotAiWorker
            Send-Json $stream @{ok=$true;message='Tiny GPT-5.4 nano connection test queued.';worker_pid=$workerProcessId}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-ai-retry'){
            $b=Body-Json $r
            # Retry is deliberately always low-cost/no-web. Fresh web
            # research requires a deliberate new Ask AI action.
            $useWeb=$false
            $cp=Join-Path $Root '06_CONFIG\copilot_thread.json'
            $thread=Read-JsonSafe $cp
            if(-not $thread){throw 'No Copilot conversation exists.'}
            $messages=@($thread.messages)
            $failed=@($messages | Where-Object {
                ([string]$_.role).ToUpperInvariant() -eq 'USER' -and
                ([string]$_.mode).ToUpperInvariant() -in @('API','API_DEEP') -and
                ([string]$_.status).ToUpperInvariant() -eq 'FAILED'
            } | Sort-Object created_at -Descending)
            $target=$failed | Select-Object -First 1
            if(-not $target){throw 'No failed AI question is available to retry.'}

            Set-ObjectNoteProperty $target 'status' 'QUEUED'
            Set-ObjectNoteProperty $target 'use_web' $useWeb
            try{$target.PSObject.Properties.Remove('error')}catch{}
            try{$target.PSObject.Properties.Remove('completed_at')}catch{}
            try{$target.PSObject.Properties.Remove('started_at')}catch{}
            $thread.updated_at=(Get-Date).ToString('o')
            Write-JsonUtf8 $thread $cp 90
            $workerProcessId=Start-CopilotAiWorker
            $targetMode=([string]$target.mode).ToUpperInvariant()
            $retryMessage=if($targetMode -eq 'API_DEEP'){'Deep Dive retry queued using GPT-5.6 Luna without web search.'}else{'Quick AI retry queued using GPT-5.4 nano without web search.'}
            Send-Json $stream @{ok=$true;message=$retryMessage;question_id=$target.message_id;worker_pid=$workerProcessId;mode=$targetMode}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/copilot-ai'){
            $b=Body-Json $r
            $question=([string]$b.question).Trim()
            if([string]::IsNullOrWhiteSpace($question)){throw 'Copilot question was empty.'}
            if($question.Length -gt 4000){throw 'Copilot question is too long.'}
            $analysisMode=([string]$b.analysis_mode).Trim().ToUpperInvariant()
            if($analysisMode -notin @('QUICK','DEEP')){$analysisMode='QUICK'}
            $messageMode=if($analysisMode -eq 'DEEP'){'API_DEEP'}else{'API'}

            $keyPath=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
            if(-not (Test-Path $keyPath)){throw 'Set your OpenAI API key once under Copilot AI Settings first.'}

            $useWeb=$false
            try{$useWeb=[bool]$b.use_web}catch{}
            $leagueId=([string]$b.league_id).Trim()
            $shotSnapshot=[pscustomobject]@{names=@();selected_count=0;available_count=0;skipped=@();total_bytes=0;signature=''}
            if($analysisMode -eq 'DEEP'){
                # Classification is asynchronous and never blocks the decision. If
                # queued evidence exists, resume the classifier opportunistically.
                try{
                    $eq=Join-Path (Get-ResearchRoot $Root) 'EVIDENCE_QUEUE'
                    $ek=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\openai_api_key.dpapi'
                    if((Test-Path $ek) -and (Test-Path $eq) -and @(Get-ChildItem -LiteralPath $eq -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0){Start-EvidenceClassifierWorker | Out-Null}
                }catch{}
                $shotSnapshot=Get-DeepScreenshotSnapshot $question
            }
            $shotSignature=[string]$shotSnapshot.signature

            $cp=Join-Path $Root '06_CONFIG\copilot_thread.json'
            $thread=Read-JsonSafe $cp
            if(-not $thread){$thread=[pscustomobject]@{version=1;updated_at=$null;messages=@()}}
            $messages=@($thread.messages)

            # Do not charge twice because of a double click / retry. Treat the
            # same unresolved question + web mode + league as one queue item.
            $duplicate=$messages | Where-Object {
                ([string]$_.role).ToUpperInvariant() -eq 'USER' -and
                ([string]$_.mode).ToUpperInvariant() -eq $messageMode -and
                ([string]$_.status).ToUpperInvariant() -in @('QUEUED','RUNNING') -and
                ([string]$_.text).Trim().ToLowerInvariant() -eq $question.ToLowerInvariant() -and
                ([bool]$_.use_web) -eq $useWeb -and
                ([string]$_.league_id) -eq $leagueId -and
                ([string]$_.screenshot_signature) -eq $shotSignature
            } | Select-Object -First 1

            if($duplicate){
                $workerProcessId=Start-CopilotAiWorker
                Send-Json $stream @{
                    ok=$true
                    message='That exact AI question is already queued/running, so no duplicate paid request was added.'
                    question_id=$duplicate.message_id
                    worker_pid=$workerProcessId
                    duplicate_prevented=$true
                }
            }else{
                $qid=[guid]::NewGuid().ToString('N')
                try{
                    $requestedDecisionId=([string]$b.research_decision_id).Trim()
                    if($analysisMode -eq 'DEEP' -and $requestedDecisionId -match '^[a-fA-F0-9]{32}$'){$qid=$requestedDecisionId.ToLowerInvariant()}
                }catch{}
                $messages += [pscustomobject][ordered]@{
                    message_id=$qid
                    role='USER'
                    text=$question
                    mode=$messageMode
                    analysis_mode=$analysisMode
                    status='QUEUED'
                    use_web=$useWeb
                    league_id=$leagueId
                    screenshot_count=[int]$shotSnapshot.selected_count
                    screenshot_available_count=[int]$shotSnapshot.available_count
                    screenshot_names=@($shotSnapshot.names)
                    screenshot_signature=$shotSignature
                    screenshot_skipped=@($shotSnapshot.skipped)
                    created_at=(Get-Date).ToString('o')
                }
                if($messages.Count -gt 120){$messages=@($messages | Select-Object -Last 120)}
                Write-JsonUtf8 ([ordered]@{version=1;updated_at=(Get-Date).ToString('o');messages=@($messages)}) $cp 100
                if($analysisMode -eq 'DEEP'){
                    try{
                        # V3.1.2: the user's natural Deep Dive language IS the research input.
                        # Capture/classify it before the model worker starts so hunches, eye-test
                        # statements, ownership language, captaincy views, etc. are timestamped
                        # pre-analysis without requiring a second manual form.
                        Record-NaturalLanguageResearchSignals $Root $question $qid $analysisMode | Out-Null
                        Append-ResearchEvent $Root 'DEEP_DIVE_STARTED' ([ordered]@{question=$question;use_web=$useWeb;league_id=$leagueId;screenshot_count=[int]$shotSnapshot.selected_count;screenshot_names=@($shotSnapshot.names)}) 0 $qid 'P001' | Out-Null
                        foreach($shotName in @($shotSnapshot.names)){
                            Append-ResearchEvent $Root 'EVIDENCE_LINKED_TO_DECISION' ([ordered]@{evidence_type='SCREENSHOT';file_name=$shotName;decision_id=$qid}) 0 $qid $shotName | Out-Null
                        }
                    }catch{}
                }

                $workerProcessId=Start-CopilotAiWorker
                $deepWebSuffix=if($useWeb){' + at most one web search'}else{''}
                $queueMessage=if($analysisMode -eq 'DEEP'){
                    if([int]$shotSnapshot.selected_count -gt 0){'Deep Dive queued with rich local evidence + {0} screenshot(s){1}.' -f [int]$shotSnapshot.selected_count,$deepWebSuffix}
                    elseif($useWeb){'Deep Dive queued with rich local evidence plus at most one web search.'}
                    else{'Deep Dive queued with rich local evidence. No web-search fee.'}
                }else{
                    if($useWeb){'AI question queued with ONE web-search call allowed.'}else{'AI question queued using synced local data only.'}
                }
                Send-Json $stream @{
                    ok=$true
                    message=$queueMessage
                    question_id=$qid
                    worker_pid=$workerProcessId
                    stored_mode=$messageMode
                    analysis_mode=$analysisMode
                    screenshot_count=[int]$shotSnapshot.selected_count
                    screenshot_available_count=[int]$shotSnapshot.available_count
                    screenshot_skipped=@($shotSnapshot.skipped)
                }
            }
        }

        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/interaction'){
            $b=Body-Json $r
            $kind=([string]$b.interaction_type).Trim().ToUpperInvariant()
            if([string]::IsNullOrWhiteSpace($kind)){throw 'interaction_type is required.'}
            # Interaction telemetry is deliberately event-level, not keystroke surveillance.
            # Preserve meaningful UI actions while avoiding raw typing, mouse coordinates,
            # token/auth data or screenshot contents.
            $payload=[ordered]@{
                interaction_type=$kind
                page=([string]$b.page).Trim().ToUpperInvariant()
                target=([string]$b.target).Trim()
                value=([string]$b.value).Trim()
                context=([string]$b.context).Trim()
                capture_policy='MEANINGFUL_UI_EVENTS_NO_KEYSTROKES'
            }
            $researchEvent=Append-ResearchEvent $Root 'INTERACTION_OBSERVED' $payload 0 $null 'P001'
            Send-Json $stream @{ok=$true;event_id=$researchEvent.event_id}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/profile'){
            $b=Body-Json $r
            $result=Save-ResearchProfile $Root $b 'CONTROL_CENTER'
            Send-Json $stream @{ok=$true;changed=$result.changed;change_count=$result.change_count;profile=$result.profile;message=if($result.changed){"Research profile saved as revision $($result.profile.revision)."}else{'No profile fields changed.'}}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/prebelief'){
            $b=Body-Json $r
            $researchEvent=Record-PreAnalysisBelief $Root $b
            Send-Json $stream @{ok=$true;decision_id=$researchEvent.decision_id;event_id=$researchEvent.event_id;message='Pre-analysis belief recorded before model advice.'}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/postdecision'){
            $b=Body-Json $r
            $researchEvent=Record-PostDecision $Root $b
            Send-Json $stream @{ok=$true;decision_id=$researchEvent.decision_id;event_id=$researchEvent.event_id;message='Final human decision recorded.'}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/evidence'){
            $b=Body-Json $r
            $researchEvent=Record-Evidence $Root $b
            Send-Json $stream @{ok=$true;evidence_id=$researchEvent.subject_id;event_id=$researchEvent.event_id;message='Evidence added to the local ledger.'}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/research/export'){
            $zip=Export-ResearchData $Root
            try{Start-Process explorer.exe (Split-Path -Parent $zip)}catch{}
            Send-Json $stream @{ok=$true;path=$zip;file_name=[IO.Path]::GetFileName($zip);message=('Research export created: '+[IO.Path]::GetFileName($zip))}
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/private-auth'){
            $b=Body-Json $r
            $credential=([string]$b.token).Trim()
            if([string]::IsNullOrWhiteSpace($credential)){throw 'FPL authentication credential was empty.'}

            $refreshToken=$null
            $accessToken=$null
            $clientId=$null

            # V3.1.2 credential intake is deliberately tolerant. Chrome DevTools can
            # copy localStorage either as raw JSON or as an expanded inspector view
            # such as `refresh_token: "eyJ..."`. We extract only the credential
            # fields locally and never persist the pasted inspector blob itself.
            $normalizedCredential=$credential.Replace('\_','_').Trim()
            $parsedStructured=$false

            # First try strict JSON, but a JSON parse failure is NOT fatal because an
            # expanded DevTools object begins with `{` while not actually being JSON.
            $jsonCandidates=@()
            if($normalizedCredential.TrimStart().StartsWith('{')){$jsonCandidates += $normalizedCredential}
            if($normalizedCredential -match '(?s)(\{.*\})'){$jsonCandidates += $matches[1]}
            foreach($jsonText in @($jsonCandidates | Select-Object -Unique)){
                if([string]::IsNullOrWhiteSpace([string]$jsonText)){continue}
                try{
                    $oidc=$jsonText | ConvertFrom-Json -ErrorAction Stop
                    try{$refreshToken=([string]$oidc.refresh_token).Trim()}catch{}
                    try{$accessToken=([string]$oidc.access_token).Trim()}catch{}
                    try{$clientId=([string]$oidc.client_id).Trim()}catch{}
                    if(-not [string]::IsNullOrWhiteSpace($refreshToken) -or -not [string]::IsNullOrWhiteSpace($accessToken)){
                        $parsedStructured=$true
                        break
                    }
                }catch{}
            }

            # Then accept Chrome's expanded Local Storage / object-inspector text.
            # Handles quoted/unquoted field names, markdown-escaped underscores and
            # arbitrary numbering/whitespace copied around the object.
            if(-not $parsedStructured){
                if($normalizedCredential -match '(?is)"?refresh_token"?\s*:\s*"([^"\r\n]+)"'){
                    $refreshToken=([string]$matches[1]).Trim()
                    $parsedStructured=$true
                }
                if($normalizedCredential -match '(?is)"?access_token"?\s*:\s*"([^"\r\n]+)"'){
                    $accessToken=([string]$matches[1]).Trim()
                    $parsedStructured=$true
                }
                if($normalizedCredential -match '(?is)"?client_id"?\s*:\s*"([^"\r\n]+)"'){
                    $clientId=([string]$matches[1]).Trim()
                }
            }

            if(-not $parsedStructured -and $normalizedCredential.StartsWith('Bearer ',[StringComparison]::OrdinalIgnoreCase)){
                $accessToken=$normalizedCredential.Substring(7).Trim()
            }elseif(-not $parsedStructured){
                # A single plain value is treated as the OIDC refresh token.
                $refreshToken=$normalizedCredential.Trim('"').Trim("'").Trim()
            }

            if([string]::IsNullOrWhiteSpace($refreshToken) -and [string]::IsNullOrWhiteSpace($accessToken)){
                throw 'No refresh_token or access_token was found in the pasted credential.'
            }

            $secretDir=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS'
            New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
            if(-not [string]::IsNullOrWhiteSpace($refreshToken)){
                $refreshToken | Set-Content -LiteralPath (Join-Path $secretDir 'fpl_oidc_refresh_token.txt') -Encoding UTF8
            }
            if(-not [string]::IsNullOrWhiteSpace($accessToken)){
                ('Bearer '+$accessToken) | Set-Content -LiteralPath (Join-Path $secretDir 'fpl_x_api_authorization.txt') -Encoding UTF8
            }
            if(-not [string]::IsNullOrWhiteSpace($clientId)){
                $clientId | Set-Content -LiteralPath (Join-Path $secretDir 'fpl_oidc_client_id.txt') -Encoding UTF8
            }

            $cp=Join-Path $Root '06_CONFIG\fpl_connection.json'
            $c=Read-JsonSafe $cp
            if(-not $c){throw 'Save your FPL Team ID first.'}
            $c.private_current_team_enabled=$true
            Write-JsonUtf8 $c $cp 20

            & (Join-Path $PSScriptRoot 'Sync-FPLAccount.ps1') -Quiet -Mode Quick -Force
            # Immediately build/validate the canonical current-team snapshot used
            # by all actionable Deep Dive requests. This verifies the connection
            # end-to-end instead of treating token storage alone as success.
            try{& (Join-Path $PSScriptRoot 'Resolve-CurrentTeam.ps1') -Quiet -MaxAgeSeconds 120}catch{}
            $meta=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\_account_sync_meta.json')
            $resolved=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\current_team_resolution.json')

            if($meta -and $meta.private_current_team -eq $true -and $resolved -and $resolved.ok -eq $true){
                $durable=(([string]$meta.private_current_team_auth_mode).ToUpperInvariant() -eq 'OIDC_REFRESH_TOKEN')
                $msg=if($durable){
                    'CURRENT TEAM CONNECTED WITH OIDC REFRESH. Future Live Sync runs will renew the short-lived access token automatically.'
                }else{
                    'CURRENT TEAM CONNECTED, but only with a temporary/fallback credential. Add the OIDC refresh token for durable automatic renewal.'
                }
                Send-Json $stream @{ok=$true;verified=$true;durable=$durable;auth_mode=$meta.private_current_team_auth_mode;message=$msg}
            }else{
                $err='FPL rejected the saved credential or the returned current team failed validation.'
                if($resolved -and $resolved.message){$err=[string]$resolved.message}
                elseif($meta -and $meta.errors -and @($meta.errors).Count -gt 0){$err=[string](@($meta.errors)[-1])}
                Send-Json $stream @{ok=$false;verified=$false;error=("Credential saved locally, but current-team verification failed: " + $err)} 400
            }
        }
        elseif($r.Method -eq 'POST' -and $path -eq '/api/upload'){
            $b=Body-Json $r
            $kind=[string]$b.kind
            $name=Sanitize-FileName ([string]$b.name)
            $bytes=[Convert]::FromBase64String([string]$b.data)

            if($bytes.Length -gt 40MB){throw 'File is too large for dashboard upload (40 MB max per file).'}

            if($kind -eq 'update'){
                if([IO.Path]::GetExtension($name).ToLower() -ne '.zip'){throw 'Returned ChatGPT update must be a ZIP.'}

                if($name -match '(?i)FPL_GW\d+_UPLOAD_TO_CHATGPT_'){
                    throw 'Wrong file: this is an OUTGOING ChatGPT pack from 04_OUTPUT\UPLOAD_PACKS. Upload it to ChatGPT in the conversation. Import Returned ChatGPT Update is only for a returned FPL_UPDATE_*.zip.'
                }

                if($name -notmatch '(?i)^FPL_UPDATE_.*\.zip$'){
                    throw 'Wrong file type. Import only the returned FPL_UPDATE_*.zip from ChatGPT.'
                }
                $canonical=$name
                $destDir=Join-Path $Root '_INCOMING_RELEASES'
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null

                # Re-importing the same update should replace the pending copy instead
                # of creating an unreadable timestamp-prefixed duplicate.
                $dest=Join-Path $destDir $canonical
                [IO.File]::WriteAllBytes($dest,$bytes)

                Send-Json $stream @{
                    ok=$true
                    kind='update'
                    saved_name=$canonical
                    message=("ChatGPT update imported: " + $canonical)
                }
            } else {
                if(@('.png','.jpg','.jpeg','.webp','.gif') -notcontains [IO.Path]::GetExtension($name).ToLower()){
                    throw 'Deep Dive screenshots must be PNG, JPG/JPEG, WEBP, or GIF.'
                }
                $destDir=Join-Path $Root '_DROP_SCREENSHOTS_HERE'
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
                $dest=Join-Path $destDir ((Get-Date -Format 'yyyyMMdd-HHmmssfff')+'_'+$name)
                [IO.File]::WriteAllBytes($dest,$bytes)
                try{
                    $shotEvent=Record-ScreenshotEvidence $Root ([IO.Path]::GetFileName($dest)) $bytes.Length $null 'NEW'
                    $sid=$null;try{$sid=[string]$shotEvent.payload.screenshot_id}catch{}
                    Queue-ScreenshotClassification $Root ([IO.Path]::GetFileName($dest)) $sid $bytes.Length | Out-Null
                    Start-EvidenceClassifierWorker | Out-Null
                }catch{}

                Send-Json $stream @{
                    ok=$true
                    kind='screenshot'
                    saved_name=[IO.Path]::GetFileName($dest)
                    message=("Screenshot added + evidence classification queued: " + $name)
                }
            }
        }
        elseif($r.Method -eq 'POST' -and $path.StartsWith('/api/action/')){
            $a=$path.Substring('/api/action/'.Length);$msg='Done.'
            switch($a){
                'livetick' {$msg=Start-LiveTickBackground}
                'sync' {$msg=Start-SyncBackground 'Quick'}
                'syncquick' {$msg=Start-SyncBackground 'Quick'}
                'syncfull' {$msg=Start-SyncBackground 'Full'}
                'cancelsync' {$msg=Cancel-SyncBackground}
                'prepare' {
                    $z=& (Join-Path $PSScriptRoot 'Prepare-WeeklyPack.ps1') -NoExplorer | Select-Object -Last 1
                    $z=[string]$z
                    if([string]::IsNullOrWhiteSpace($z) -or -not (Test-Path $z)){
                        throw 'Pack builder finished without producing a readable ZIP.'
                    }
                    $receipt=Read-JsonSafe (Join-Path $Root '04_OUTPUT\DASHBOARD\last_pack_build.json')
                    $shotCount=if($receipt){$receipt.screenshot_count}else{'?'}
                    $hunchCount=if($receipt){$receipt.pending_hunch_count}else{'?'}
                    $msg="ChatGPT pack READY: $([IO.Path]::GetFileName($z)) | screenshots $shotCount | pending hunches $hunchCount"
                }
                'apply' {$z=& (Join-Path $PSScriptRoot 'Apply-LatestRelease.ps1') -NoExplorer | Select-Object -Last 1;if($z){$msg='Latest ChatGPT update applied.'}else{$msg='No update ZIP found.'}}
                'closegw' {$msg=Start-CloseGameweekBackground}
                'openoutput' {Start-Process explorer.exe (Join-Path $Root '04_OUTPUT');$msg='Opened output folder.'}
                'openpack' {Start-Process explorer.exe (Join-Path $Root '04_OUTPUT\UPLOAD_PACKS');$msg='Opened ChatGPT pack folder.'}
                default {throw 'Unknown action.'}
            }
            Send-Json $stream @{ok=$true;message=$msg}
        }
        else{Send-Json $stream @{ok=$false;error='Not found'} 404}
    } catch {
        $requestError=[string]$_.Exception.Message
        $clientDisconnected=($requestError -match '(?i)(unable to write data to the transport connection|connection was aborted|forcibly closed|broken pipe|connection reset by peer|existing connection was aborted)')
        if($requestError -ne '__IDLE_LOCAL_CONNECTION__' -and -not $clientDisconnected){
            Write-Host ("Local request error: " + $requestError) -ForegroundColor Red
            try{Send-Json $stream @{ok=$false;error=$requestError} 500}catch{}
        }
    } finally {
        try{$stream.Close()}catch{};try{$client.Close()}catch{}
    }
}
