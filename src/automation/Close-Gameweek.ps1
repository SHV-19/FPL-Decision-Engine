param(
    [int]$Gameweek=0,
    [switch]$NoExplorer,
    [string]$RunId=''
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$closeStatePath=Join-Path $Root '04_OUTPUT\DASHBOARD\last_close_gameweek.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $closeStatePath) | Out-Null
if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
$startedAt=Get-Date
$targetGameweek=$Gameweek
if($targetGameweek -le 0){
    $lockedGameweek=Get-LatestLockedGameweek $Root
    if($lockedGameweek -gt 0){$targetGameweek=$lockedGameweek}else{$targetGameweek=Get-EngineGameweek $Root}
}

function Write-CloseState {
    param(
        [string]$Status,
        [string]$Stage,
        [int]$Current,
        [int]$Total,
        [string]$Message,
        [string]$ReviewPack=$null,
        [string]$ArchivePath=$null,
        [string]$ErrorText=$null,
        [object]$Warnings=$null
    )
    $now=Get-Date
    $duration=[math]::Round(($now-$startedAt).TotalSeconds,1)
    if($duration -lt 0){$duration=0}
    $payload=[ordered]@{
        status=$Status
        run_id=$RunId
        process_id=$PID
        gameweek=$targetGameweek
        stage=$Stage
        progress_current=$Current
        progress_total=$Total
        progress_percent=if($Total -gt 0){[math]::Round(($Current/$Total)*100)}else{0}
        started_at_local=$startedAt.ToString('yyyy-MM-dd HH:mm:ss')
        heartbeat_at_local=$now.ToString('yyyy-MM-dd HH:mm:ss')
        completed_at_local=if($Status -in @('SUCCESS','FAILED')){$now.ToString('yyyy-MM-dd HH:mm:ss')}else{$null}
        duration_seconds=$duration
        message=$Message
        review_pack=$ReviewPack
        archive_path=$ArchivePath
        error=$ErrorText
        warnings=if($Warnings){@($Warnings)}else{@()}
    }
    Write-JsonUtf8 $payload $closeStatePath 50
}

function Get-FileAgeMinutes([string]$Path){
    if(-not (Test-Path $Path)){return $null}
    try{return [math]::Round(((Get-Date)-(Get-Item -LiteralPath $Path).LastWriteTime).TotalMinutes,1)}catch{return $null}
}

function Copy-RelativePath([string]$Relative,[string]$DestinationRoot){
    $src=Join-Path $Root $Relative
    if(-not (Test-Path $src)){return $false}
    $dest=Join-Path $DestinationRoot $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
    return $true
}

$tempArchive=$null
$tempReviewZip=$null
$finalArchive=$null
$finalReviewZip=$null

try {
    # v2.8.6: closing a completed GW is an archival transaction, not another
    # network/Manager-Intelligence rebuild. The user can run Deep Refresh
    # separately. This keeps Close Gameweek fast, deterministic and retryable.
    $totalStages=5
    $gw=('GW{0:D2}' -f $targetGameweek)
    Write-CloseState 'CLOSING' 'VALIDATE' 0 $totalStages ("Closing {0}: validating the cached final-GW snapshot." -f $gw)

    if($targetGameweek -le 0){throw 'No completed/locked gameweek could be identified.'}

    $picksPath=Join-Path $Root ("02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json" -f $targetGameweek)
    $entryPath=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\entry.json'
    $historyPath=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\history.json'
    if(-not (Test-Path $picksPath)){throw ("Locked picks for {0} are missing. Run Live Sync once, then retry Close Gameweek." -f $gw)}
    if(-not (Test-Path $entryPath)){throw 'Official FPL account snapshot is missing. Run Live Sync once, then retry Close Gameweek.'}

    $history=Read-JsonSafe $historyPath
    $historyRow=$null
    if($history -and $history.current){$historyRow=@($history.current | Where-Object {[int]$_.event -eq $targetGameweek} | Select-Object -Last 1)}
    if($historyRow -is [array]){$historyRow=$historyRow | Select-Object -Last 1}

    $warnings=New-Object System.Collections.Generic.List[string]
    $coreAge=Get-FileAgeMinutes $entryPath
    $picksAge=Get-FileAgeMinutes $picksPath
    $liveAge=Get-FileAgeMinutes (Join-Path $Root '02_DATA\LIVEFPL\CURRENT\live_team.json')
    if($null -ne $coreAge -and $coreAge -gt 180){[void]$warnings.Add(("Official account cache is {0} minutes old." -f $coreAge))}
    if($null -ne $picksAge -and $picksAge -gt 180){[void]$warnings.Add(("Locked-picks cache is {0} minutes old." -f $picksAge))}
    if($null -ne $liveAge -and $liveAge -gt 180){[void]$warnings.Add(("LiveFPL cache is {0} minutes old; archived as context only." -f $liveAge))}

    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $archiveRoot=Join-Path $Root "08_ARCHIVE\GAMEWEEKS\$gw"
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    $tempArchive=Join-Path $archiveRoot ("_CLOSING_{0}" -f $RunId)
    $finalArchive=Join-Path $archiveRoot ("CLOSED_{0}" -f $stamp)
    if(Test-Path $tempArchive){Remove-Item -LiteralPath $tempArchive -Recurse -Force}
    New-Item -ItemType Directory -Force -Path $tempArchive | Out-Null

    Write-CloseState 'CLOSING' 'ARCHIVE' 1 $totalStages ("Closing {0}: archiving final cached state. No network refresh is being run." -f $gw) $null $tempArchive $null $warnings

    $archivePaths=@(
        ("01_INPUT\GAMEWEEKS\{0}" -f $gw),
        '06_CONFIG\manager_hunch.json',
        '02_DATA\CURRENT',
        '02_DATA\FPL_ACCOUNT\CURRENT',
        '02_DATA\FPL_ACCOUNT\LEAGUES',
        '02_DATA\FPL_ACCOUNT\RIVALS',
        '02_DATA\LIVEFPL\CURRENT',
        '02_DATA\MANAGER_INTELLIGENCE\CURRENT',
        '02_DATA\MANAGER_INTELLIGENCE\PROCESSED',
        '04_OUTPUT\DASHBOARD',
        '04_OUTPUT\DECISION_PACKS'
    )
    foreach($rel in $archivePaths){[void](Copy-RelativePath $rel $tempArchive)}

    $receipt=[ordered]@{
        status='CLOSED'
        gameweek=$targetGameweek
        closed_at=(Get-Date).ToString('o')
        run_id=$RunId
        close_mode='FAST_ARCHIVE_FROM_CACHE'
        network_refresh_performed=$false
        manager_intelligence_rebuilt=$false
        manager_intelligence_note='Deep Refresh / Deep Dive may rebuild Manager Intelligence separately. It is not allowed to gate gameweek closure.'
        final_history=if($historyRow){$historyRow}else{$null}
        source_age_minutes=[ordered]@{official_account=$coreAge;locked_picks=$picksAge;livefpl=$liveAge}
        warnings=@($warnings)
    }
    Write-JsonUtf8 $receipt (Join-Path $tempArchive 'CLOSE_RECEIPT.json') 50

    Write-CloseState 'CLOSING' 'REVIEW_PACK' 2 $totalStages ("Closing {0}: building the review pack." -f $gw) $null $tempArchive $null $warnings
    $stageDir=Join-Path $env:TEMP ("FPLReview-{0}-{1}" -f $gw,$RunId)
    if(Test-Path $stageDir){Remove-Item -LiteralPath $stageDir -Recurse -Force}
    $pack=Join-Path $stageDir ("FPL_REVIEW_PACK_{0}" -f $gw)
    New-Item -ItemType Directory -Force -Path $pack | Out-Null
    $packPaths=@(
        '06_CONFIG\manager_hunch.json',
        '02_DATA\CURRENT',
        '02_DATA\FPL_ACCOUNT\CURRENT',
        '02_DATA\FPL_ACCOUNT\LEAGUES',
        '02_DATA\FPL_ACCOUNT\RIVALS',
        '02_DATA\LIVEFPL\CURRENT',
        '02_DATA\MANAGER_INTELLIGENCE\CURRENT',
        '02_DATA\MANAGER_INTELLIGENCE\PROCESSED',
        '02_DATA\PROCESSED',
        '04_OUTPUT\CALIBRATION',
        '04_OUTPUT\DASHBOARD',
        '04_OUTPUT\DECISION_PACKS',
        '06_CONFIG\project_state.json',
        '06_CONFIG\manager_intelligence.json',
        '06_CONFIG\model_weights.json',
        '06_CONFIG\decision_thresholds.json',
        '03_MODELS\MANAGER_INTELLIGENCE_SPEC.md',
        '07_HANDOFF\CHATGPT_MASTER_INSTRUCTIONS.txt'
    )
    foreach($rel in $packPaths){[void](Copy-RelativePath $rel $pack)}
    Write-JsonUtf8 $receipt (Join-Path $pack 'CLOSE_RECEIPT.json') 50
@"
CLOSE GAMEWEEK $targetGameweek REVIEW

This gameweek was closed from the latest cached final-GW state. Close Gameweek intentionally does NOT run Manager Intelligence or another network refresh. Calibrate the FPL Decision Engine using actual results vs predictions, distinguish process quality from outcome variance, and review manager/rival strategy from the evidence present in the pack. If heavier Manager Intelligence is needed, rebuild it separately through Deep Refresh / Deep Dive rather than treating it as a prerequisite for closure. Return one local update ZIP.
"@ | Set-Content -Encoding UTF8 (Join-Path $pack 'REVIEW_INSTRUCTION.txt')

    $out=Join-Path $Root '04_OUTPUT\REVIEW_PACKS'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $finalReviewZip=Join-Path $out ("FPL_{0}_REVIEW_TO_CHATGPT_{1}.zip" -f $gw,$stamp)
    $tempReviewZip=Join-Path $env:TEMP ("FPL_{0}_REVIEW_{1}.zip" -f $gw,$RunId)
    if(Test-Path $tempReviewZip){Remove-Item -LiteralPath $tempReviewZip -Force}
    Compress-Archive -Path $pack -DestinationPath $tempReviewZip -CompressionLevel Optimal
    if(-not (Test-Path $tempReviewZip)){throw 'Review-pack ZIP was not created.'}
    Move-Item -LiteralPath $tempReviewZip -Destination $finalReviewZip -Force
    $tempReviewZip=$null
    Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-CloseState 'CLOSING' 'FINALIZE' 3 $totalStages ("Closing {0}: committing the archive receipt." -f $gw) $finalReviewZip $tempArchive $null $warnings
    if(Test-Path $finalArchive){throw ("Final archive path already exists: {0}" -f $finalArchive)}
    Move-Item -LiteralPath $tempArchive -Destination $finalArchive
    $tempArchive=$null
    $receipt.archive_path=$finalArchive
    $receipt.review_pack=$finalReviewZip
    $receipt.completed_at=(Get-Date).ToString('o')
    Write-JsonUtf8 $receipt (Join-Path $finalArchive 'CLOSE_RECEIPT.json') 50
    Write-JsonUtf8 $receipt (Join-Path $archiveRoot 'LATEST_CLOSED_RECEIPT.json') 50

    Write-CloseState 'CLOSING' 'CLEANUP' 4 $totalStages ("Closing {0}: archiving evidence and clearing closed-GW transient state." -f $gw) $finalReviewZip $finalArchive $null $warnings
    $hunchPath=Join-Path $Root '06_CONFIG\manager_hunch.json'
    if(Test-Path $hunchPath){Remove-Item -LiteralPath $hunchPath -Force -ErrorAction SilentlyContinue}
    $dropPath=Join-Path $Root '_DROP_SCREENSHOTS_HERE'
    if(Test-Path $dropPath){
        $evidenceArchive=Join-Path $finalArchive 'RESEARCH_SCREENSHOTS'
        New-Item -ItemType Directory -Force -Path $evidenceArchive | Out-Null
        $closedShots=@(Get-ChildItem -LiteralPath $dropPath -File -ErrorAction SilentlyContinue |
            Where-Object { @('.png','.jpg','.jpeg','.webp','.bmp','.gif') -contains $_.Extension.ToLowerInvariant() })
        foreach($shot in $closedShots){
            try{
                Copy-Item -LiteralPath $shot.FullName -Destination (Join-Path $evidenceArchive $shot.Name) -Force
                Append-ResearchEvent $Root 'SCREENSHOT_ARCHIVED' ([ordered]@{file_name=$shot.Name;archive_path=(Join-Path $evidenceArchive $shot.Name);gameweek=$targetGameweek}) $targetGameweek $null $shot.Name | Out-Null
            }catch{}
        }
        $closedShots | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $finalReviewZip | Set-Content -Encoding UTF8 (Join-Path $Root '04_OUTPUT\_latest_review_pack.txt')

    # V3.0.1 final research reconciliation: the locked Official FPL picks are
    # authoritative for whether an actionable hunch was ultimately reflected.
    # This closes the loop even when the user's final refresh happened before
    # the deadline (when an unmatched hunch must still remain provisional).
    try{
        $lockedResearchPath=Join-Path $Root ('02_DATA\FPL_ACCOUNT\CURRENT\picks_GW{0:D2}.json' -f $targetGameweek)
        $lockedResearchTeam=Read-JsonSafe $lockedResearchPath
        if($lockedResearchTeam -and $lockedResearchTeam.picks -and @($lockedResearchTeam.picks).Count -ge 15){
            Reconcile-ResearchHunchesWithOfficialTeam $Root $lockedResearchTeam $targetGameweek $false $null
        }
    }catch{}

    try{Append-ResearchEvent $Root 'GAMEWEEK_CLOSED' ([ordered]@{gameweek=$targetGameweek;archive_path=$finalArchive;review_pack=$finalReviewZip;warnings=@($warnings);close_mode='FAST_ARCHIVE_FROM_CACHE'}) $targetGameweek $RunId 'GAMEWEEK' | Out-Null}catch{}
    # V3.1.0: preserve an explainable identity-model generation at each closed GW.
    # The snapshot is descriptive and versioned; it never rewrites earlier generations.
    try{if(Get-Command Record-IdentityModelSnapshot -ErrorAction SilentlyContinue){Record-IdentityModelSnapshot $Root $targetGameweek | Out-Null}}catch{}
    # Freeze the competitive ecology used by the observatory so later GWs do not
    # rewrite the historical League DNA / Manager Genome sample. This is local-only
    # status construction; no new network refresh is triggered by Close Gameweek.
    try{
        if(Get-Command Get-ControlCenterStatus -ErrorAction SilentlyContinue){
            $ecoStatus=Get-ControlCenterStatus $Root
            $ecoLeagues=@()
            foreach($li in @($ecoStatus.rival_intelligence.leagues)){
                if($li -and $li.league_dna){$ecoLeagues += [pscustomobject][ordered]@{league_id=$li.id;league_name=$li.name;league_dna=$li.league_dna;sampled_rivals=$li.sampled_rivals}}
            }
            Append-ResearchEvent $Root 'RIVAL_ECOLOGY_SNAPSHOT' ([ordered]@{
                gameweek=$targetGameweek
                comparison_gameweek=$ecoStatus.rival_intelligence.comparison_gameweek
                leagues=@($ecoLeagues)
                manager_genome=@($ecoStatus.rival_intelligence.manager_genome)
                manager_genome_note=$ecoStatus.rival_intelligence.manager_genome_note
                guardrail='Competitive identities are frozen sampled descriptions. They are not permanent manager labels or causal performance scores.'
            }) $targetGameweek $RunId 'COMPETITIVE_ECOLOGY' | Out-Null
        }
    }catch{}
    Write-CloseState 'SUCCESS' 'COMPLETE' 5 $totalStages ("$gw CLOSED. Archive and review pack created successfully. Deep Refresh is optional and separate.") $finalReviewZip $finalArchive $null $warnings
    Write-Host ("{0} archived successfully. Review pack: {1}" -f $gw,$finalReviewZip) -ForegroundColor Green
    if(-not $NoExplorer){try{Start-Process explorer.exe $out}catch{}}
    Write-Output $finalReviewZip
} catch {
    $errText=$_.Exception.Message
    if($tempReviewZip -and (Test-Path $tempReviewZip)){Remove-Item -LiteralPath $tempReviewZip -Force -ErrorAction SilentlyContinue}
    if($tempArchive -and (Test-Path $tempArchive)){
        # A failed transaction must never leave a directory that looks CLOSED.
        try{Remove-Item -LiteralPath $tempArchive -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    }
    try{Write-CloseState 'FAILED' 'FAILED' 0 5 ("GW{0} close failed: {1}" -f $targetGameweek,$errText) $finalReviewZip $finalArchive $errText}catch{}
    throw
}
