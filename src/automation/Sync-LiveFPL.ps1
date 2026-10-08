param(
    [switch]$Quiet,
    [ValidateSet('Quick','Full')][string]$Mode='Full'
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$connPath=Join-Path $Root '06_CONFIG\fpl_connection.json'
$conn=Read-JsonSafe $connPath
$current=Join-Path $Root '02_DATA\LIVEFPL\CURRENT'
$raw=Join-Path $Root '02_DATA\LIVEFPL\RAW'
New-Item -ItemType Directory -Force -Path $current,$raw | Out-Null

$started=Get-Date
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$previousMeta=Read-JsonSafe (Join-Path $current '_livefpl_sync_meta.json')
$meta=[ordered]@{
    synced_at_local=$started.ToString('o')
    synced_at_utc=$started.ToUniversalTime().ToString('o')
    completed_at_local=$null
    completed_at_utc=$null
    duration_seconds=$null
    mode=$Mode
    status='OFFLINE'
    team_id=$null
    planner_id=$null
    endpoints=[ordered]@{}
    errors=@()
    market_ok=$false
    team_ok=$false
    games_ok=$false
    planner_ok=$false
}

$headers=@{
    'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36'
    'Accept'='application/json,text/plain,*/*'
    'Accept-Language'='en-US,en;q=0.9'
    'Referer'='https://www.livefpl.net/'
}

function Fetch-Live([string]$Url,[string]$Name,[int]$TimeoutSec=12) {
    try {
        if(-not $Quiet){ Write-Host "LiveFPL [$Mode]: $Name" -ForegroundColor Cyan }
        $obj=Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -Method Get
        if($obj -is [string]){
            $trim=$obj.Trim()
            if($trim.StartsWith('<!DOCTYPE') -or $trim.StartsWith('<html') -or $trim.StartsWith('<')){
                throw 'Endpoint returned HTML instead of JSON.'
            }
            try{$obj=$trim | ConvertFrom-Json}catch{throw 'Endpoint returned non-JSON text.'}
        }
        $obj=Repair-ObjectStrings $obj
        Write-JsonUtf8 $obj (Join-Path $raw "$Name-$stamp.json") 100
        Write-JsonUtf8 $obj (Join-Path $current "$Name.json") 100
        $script:meta.endpoints[$Name]=[ordered]@{ok=$true;url=$Url;error=$null;fetched_at=(Get-Date).ToString('o')}
        Start-Sleep -Milliseconds 120
        return $obj
    } catch {
        $msg=$_.Exception.Message
        $script:meta.endpoints[$Name]=[ordered]@{ok=$false;url=$Url;error=$msg;fetched_at=(Get-Date).ToString('o')}
        $script:meta.errors += "$Name`: $msg"
        if(-not $Quiet){ Write-Host "LiveFPL $Name unavailable; cached copy preserved." -ForegroundColor Yellow }
        return $null
    }
}

# QUICK mode is designed for live-match freshness. It fetches only the personal
# live-rank/team endpoint plus the live-games feed. Market/elite/planner data
# remains cached from the last Full sync.
if($Mode -eq 'Full'){
    $version=Fetch-Live 'https://livefpl.us/version.json' 'version'
    $prices=Fetch-Live 'https://livefpl.us/api/prices.json' 'prices'
    $transfers=Fetch-Live 'https://livefpl.us/top_transfers.json' 'top_transfers'
    $elite=Fetch-Live 'https://livefpl.us/elite.json' 'elite'
    $games=Fetch-Live ('https://livefpl.us/api/games.json?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'games'
    if($games){$meta.games_ok=$true}

    $generalOk=@(@($version,$prices,$transfers,$elite) | Where-Object { $_ -ne $null }).Count
    if($generalOk -gt 0){$meta.market_ok=$true}
}else{
    $games=Fetch-Live ('https://livefpl.us/api/games.json?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'games'
    if($games){$meta.games_ok=$true}
    if($previousMeta -and $previousMeta.market_ok -eq $true){$meta.market_ok=$true}
}

if($conn -and $conn.team_id){
    $teamId=[int]$conn.team_id
    $meta.team_id=$teamId
    $live=Fetch-Live "https://www.livefpl.net/livefplapi/$teamId" 'live_team'
    if($live){$meta.team_ok=$true}
}

if($Mode -eq 'Full' -and $conn -and $conn.livefpl_planner_id){
    $plannerId=[int]$conn.livefpl_planner_id
    $meta.planner_id=$plannerId
    $planner=Fetch-Live "https://livefpl-api-489391001748.europe-west4.run.app/LH_api2/planner/snapshot?id=$plannerId" 'planner_snapshot'
    if($planner){$meta.planner_ok=$true}
}elseif($previousMeta -and $previousMeta.planner_id){
    $meta.planner_id=$previousMeta.planner_id
    if($previousMeta.planner_ok -eq $true){$meta.planner_ok=$true}
}

if($meta.team_ok){
    $meta.status='CONNECTED'
} elseif($meta.market_ok -or $meta.games_ok -or $meta.planner_ok){
    if($meta.team_id -eq $null -and $meta.market_ok){$meta.status='MARKET_ONLY'}else{$meta.status='DEGRADED'}
} else {
    $meta.status='OFFLINE'
}

$completed=Get-Date
$meta.completed_at_local=$completed.ToString('o')
$meta.completed_at_utc=$completed.ToUniversalTime().ToString('o')
$meta.duration_seconds=[math]::Round(($completed-$started).TotalSeconds,1)

Write-JsonUtf8 $meta (Join-Path $current '_livefpl_sync_meta.json') 30
if(-not $Quiet){
    switch($meta.status){
        'CONNECTED' {Write-Host "LiveFPL $Mode sync complete in $($meta.duration_seconds)s." -ForegroundColor Green}
        'MARKET_ONLY' {Write-Host 'LiveFPL market feeds synced. Connect your FPL Team ID for personal live-rank/EO intelligence.' -ForegroundColor Green}
        'DEGRADED' {Write-Host 'LiveFPL partially synced. Official FPL remains fully usable.' -ForegroundColor Yellow}
        default {Write-Host 'LiveFPL is currently unavailable. Official FPL remains fully usable.' -ForegroundColor Yellow}
    }
}
return
