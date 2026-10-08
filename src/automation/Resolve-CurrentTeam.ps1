param(
    [switch]$Quiet,
    [switch]$ForceRefresh,
    [int]$MaxAgeSeconds=120
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$current=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT'
$outDir=Join-Path $Root '04_OUTPUT\DASHBOARD'
New-Item -ItemType Directory -Force -Path $current,$outDir | Out-Null
$resultPath=Join-Path $outDir 'current_team_resolution.json'
$snapshotPath=Join-Path $current 'current-team-snapshot.json'
$metaPath=Join-Path $current '_account_sync_meta.json'
$myTeamPath=Join-Path $current 'my-team.json'
$bootPath=Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json'

function Get-AgeSeconds([string]$Path){
    if(-not (Test-Path -LiteralPath $Path)){return $null}
    try{return [math]::Max(0,[math]::Round(((Get-Date)-(Get-Item -LiteralPath $Path).LastWriteTime).TotalSeconds,1))}catch{return $null}
}
function Get-Sha256Text([string]$Text){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
}
function Get-LastAuthError($Meta){
    if(-not $Meta){return 'Current-team authentication metadata is unavailable.'}
    try{
        $errs=@($Meta.errors)
        $private=@($errs | Where-Object {([string]$_) -match '(?i)OIDC refresh|private my-team|credential|authorization|token'})
        if($private.Count -gt 0){return [string]$private[-1]}
        if($errs.Count -gt 0){return [string]$errs[-1]}
    }catch{}
    try{if($Meta.auth_requires_reconnect -eq $true){return 'The saved Official FPL authentication can no longer renew the private current-team session.'}}catch{}
    return 'Official FPL did not return an authenticated editable current team.'
}
function Validate-AndWriteSnapshot($Meta,$My,$Boot){
    $issues=New-Object System.Collections.ArrayList
    if(-not $Meta -or $Meta.private_current_team -ne $true -or ([string]$Meta.private_current_team_status).ToUpperInvariant() -ne 'SYNCED'){
        [void]$issues.Add('Authenticated current-team status is not SYNCED.')
    }
    $picks=@();try{$picks=@($My.picks)}catch{}
    if($picks.Count -ne 15){[void]$issues.Add(('Official FPL current team must contain exactly 15 picks; found {0}.' -f $picks.Count))}
    if(-not $Boot -or -not $Boot.elements){[void]$issues.Add('Official FPL player universe is unavailable.')}
    if($issues.Count -gt 0){return [pscustomobject]@{ok=$false;issues=@($issues)}}

    $emap=@{};foreach($e in @($Boot.elements)){$emap[[int]$e.id]=$e}
    $posCounts=@{1=0;2=0;3=0;4=0};$clubCounts=@{};$normalized=@()
    foreach($pk in @($picks | Sort-Object {[int]$_.position})){
        $id=[int]$pk.element
        if(-not $emap.ContainsKey($id)){[void]$issues.Add("Unknown Official FPL element id $id in current team.");continue}
        $e=$emap[$id];$posId=[int]$e.element_type;$clubId=[int]$e.team
        if(-not $posCounts.ContainsKey($posId)){[void]$issues.Add("Invalid position id $posId for element $id.");continue}
        $posCounts[$posId]++
        if(-not $clubCounts.ContainsKey($clubId)){$clubCounts[$clubId]=0};$clubCounts[$clubId]++
        $purchasePrice=$null;$sellingPrice=$null
        try{$purchasePrice=[int]$pk.purchase_price}catch{}
        try{$sellingPrice=[int]$pk.selling_price}catch{}
        $normalized += [ordered]@{
            element=$id
            position=[int]$pk.position
            is_captain=[bool]$pk.is_captain
            is_vice_captain=[bool]$pk.is_vice_captain
            multiplier=[int]$pk.multiplier
            purchase_price=$purchasePrice
            selling_price=$sellingPrice
            element_type=$posId
            club_id=$clubId
            web_name=[string]$e.web_name
        }
    }
    if($posCounts[1] -ne 2 -or $posCounts[2] -ne 5 -or $posCounts[3] -ne 5 -or $posCounts[4] -ne 3){
        [void]$issues.Add(('Illegal squad position counts: GKP={0}, DEF={1}, MID={2}, FWD={3}.' -f $posCounts[1],$posCounts[2],$posCounts[3],$posCounts[4]))
    }
    foreach($clubId in @($clubCounts.Keys)){if([int]$clubCounts[$clubId] -gt 3){[void]$issues.Add("More than three players from club id $clubId.")}}
    $starterCount=@($normalized | Where-Object {[int]$_.position -le 11}).Count
    $benchCount=@($normalized | Where-Object {[int]$_.position -gt 11}).Count
    $captains=@($normalized | Where-Object {$_.is_captain -eq $true})
    $vices=@($normalized | Where-Object {$_.is_vice_captain -eq $true})
    if($starterCount -ne 11){[void]$issues.Add("Current team has $starterCount starters instead of 11.")}
    if($benchCount -ne 4){[void]$issues.Add("Current team has $benchCount bench players instead of 4.")}
    if($captains.Count -ne 1){[void]$issues.Add("Current team must have exactly one captain; found $($captains.Count).")}
    if($vices.Count -ne 1){[void]$issues.Add("Current team must have exactly one vice-captain; found $($vices.Count).")}
    if($issues.Count -gt 0){return [pscustomobject]@{ok=$false;issues=@($issues)}}

    $bank=$null;$value=$null;$limit=$null;$made=$null
    try{$bank=[int]$My.transfers.bank}catch{}
    try{$value=[int]$My.transfers.value}catch{}
    try{$limit=[int]$My.transfers.limit}catch{}
    try{$made=[int]$My.transfers.made}catch{}
    $freeTransfers=$null
    $madeForCalc=0;if($made -ne $null){$madeForCalc=[int]$made}
    if($limit -ne $null){$freeTransfers=[math]::Max(0,([int]$limit-$madeForCalc))}
    $activeChip=$null;try{$activeChip=[string]$My.active_chip}catch{}
    $chips=@();try{$chips=@($My.chips)}catch{}
    $gw=Get-EngineGameweek $Root
    $resolvedTeamId=$null;try{$resolvedTeamId=[int]$Meta.team_id}catch{}
    $signature=[ordered]@{
        team_id=$resolvedTeamId
        gameweek=$gw
        picks=@($normalized | ForEach-Object {[ordered]@{element=$_.element;position=$_.position;captain=$_.is_captain;vice=$_.is_vice_captain;selling_price=$_.selling_price}})
        bank=$bank
        value=$value
        transfer_limit=$limit
        transfers_made=$made
        active_chip=$activeChip
    }
    $signatureJson=$signature | ConvertTo-Json -Depth 8 -Compress
    $snapshotId=Get-Sha256Text $signatureJson
    $now=(Get-Date).ToString('o')
    $snap=[ordered]@{
        schema_version=1
        snapshot_id=$snapshotId
        source='OFFICIAL_FPL_MY_TEAM'
        authority='AUTHENTICATED_EDITABLE_CURRENT_TEAM'
        captured_at=$now
        source_synced_at=if($Meta.private_current_team_last_success_at){[string]$Meta.private_current_team_last_success_at}else{$now}
        team_id=$signature.team_id
        gameweek=$gw
        picks=@($normalized)
        starters=@($normalized | Where-Object {[int]$_.position -le 11})
        bench=@($normalized | Where-Object {[int]$_.position -gt 11})
        captain=if($captains.Count){[int]$captains[0].element}else{$null}
        vice_captain=if($vices.Count){[int]$vices[0].element}else{$null}
        active_chip=$activeChip
        chips=@($chips)
        bank_tenths=$bank
        value_tenths=$value
        free_transfers=$freeTransfers
        transfer_limit=$limit
        transfers_made=$made
    }
    Write-JsonUtf8 $snap $snapshotPath 30
    return [pscustomobject]@{ok=$true;snapshot=$snap;issues=@()}
}

$started=Get-Date
$age=Get-AgeSeconds $myTeamPath
$meta=Read-JsonSafe $metaPath
$my=Read-JsonSafe $myTeamPath
$boot=Read-JsonSafe $bootPath
$needsRefresh=$ForceRefresh -or -not $meta -or $meta.private_current_team -ne $true -or ([string]$meta.private_current_team_status).ToUpperInvariant() -ne 'SYNCED' -or $age -eq $null -or [double]$age -gt $MaxAgeSeconds

if($needsRefresh){
    try{& (Join-Path $PSScriptRoot 'Sync-FPLAccount.ps1') -Quiet -Mode Quick -Force}catch{}
    $meta=Read-JsonSafe $metaPath
    $my=Read-JsonSafe $myTeamPath
    $boot=Read-JsonSafe $bootPath
    $age=Get-AgeSeconds $myTeamPath
}

$validated=Validate-AndWriteSnapshot $meta $my $boot
if($validated.ok){
    $result=[ordered]@{
        status='READY'
        ok=$true
        exact_call_allowed=$true
        snapshot_id=[string]$validated.snapshot.snapshot_id
        source='OFFICIAL_FPL_MY_TEAM'
        captured_at=[string]$validated.snapshot.captured_at
        team_age_seconds=$age
        team_id=$validated.snapshot.team_id
        gameweek=$validated.snapshot.gameweek
        message='Authenticated Official FPL current team resolved and validated.'
        auth_mode=if($meta){$meta.private_current_team_auth_mode}else{$null}
        auth_requires_reconnect=$false
        elapsed_seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2)
    }
}else{
    $reason=Get-LastAuthError $meta
    $extra=@($validated.issues)
    $result=[ordered]@{
        status='AUTH_REQUIRED'
        ok=$false
        exact_call_allowed=$false
        snapshot_id=$null
        source='NONE'
        captured_at=(Get-Date).ToString('o')
        team_age_seconds=$age
        team_id=if($meta){$meta.team_id}else{$null}
        gameweek=Get-EngineGameweek $Root
        message=$reason
        validation_issues=@($extra)
        auth_mode=if($meta){$meta.private_current_team_auth_mode}else{$null}
        auth_requires_reconnect=$true
        elapsed_seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2)
    }
}
Write-JsonUtf8 $result $resultPath 30
if(-not $Quiet){$result | ConvertTo-Json -Depth 8}
return
