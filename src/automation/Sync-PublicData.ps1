param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')
$Raw = Join-Path $Root '02_DATA\PUBLIC_RAW'
$Current = Join-Path $Root '02_DATA\CURRENT'
New-Item -ItemType Directory -Force -Path $Raw,$Current | Out-Null

$headers = @{ 'User-Agent' = 'Mozilla/5.0 FPL-Decision-Engine/4.1.2'; 'Accept'='application/json' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$started=Get-Date
$meta = [ordered]@{
  synced_at_local=$started.ToString('o')
  synced_at_utc=$started.ToUniversalTime().ToString('o')
  completed_at_local=$null
  completed_at_utc=$null
  duration_seconds=$null
  success=$false
  errors=@()
  current_live_event=$null
  event_live_fetched_at=$null
}

function Fetch-Json([string]$Url,[string]$Name,[int]$TimeoutSec=10) {
  try {
    if(-not $Quiet){ Write-Host "Fetching $Name..." -ForegroundColor Cyan }
    $obj = Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec
    $obj = Repair-ObjectStrings $obj
    $obj | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 (Join-Path $Raw "$Name-$stamp.json")
    $obj | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 (Join-Path $Current "$Name.json")
    return $obj
  } catch {
    $script:meta.errors += "${Name}: $($_.Exception.Message)"
    if(-not $Quiet){ Write-Warning "Could not fetch $Name. Existing cache will be preserved." }
    return $null
  }
}

$boot = Fetch-Json 'https://fantasy.premierleague.com/api/bootstrap-static/' 'bootstrap-static'
$fixtures = Fetch-Json 'https://fantasy.premierleague.com/api/fixtures/' 'fixtures'
$status = Fetch-Json 'https://fantasy.premierleague.com/api/event-status/' 'event-status'

if($boot){
  # Keep the most recently locked/current Gameweek's live FPL event stats for
  # live points + post-GW calibration. This is the direct Official FPL timeline.
  try {
    $now=[DateTime]::UtcNow
    $liveEv=$boot.events | Where-Object { $_.is_current -eq $true } | Select-Object -First 1
    if(-not $liveEv){
      $liveEv=$boot.events |
        Where-Object { $_.deadline_time -and $now -ge [DateTime]::Parse($_.deadline_time).ToUniversalTime() } |
        Sort-Object id -Descending |
        Select-Object -First 1
    }
    if($liveEv){
      $meta.current_live_event=[int]$liveEv.id
      $live=Fetch-Json ("https://fantasy.premierleague.com/api/event/$([int]$liveEv.id)/live/") ("event-live-GW{0:D2}" -f [int]$liveEv.id)
      if($live){
        $live | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 (Join-Path $Current 'event_live_current.json')
        $meta.event_live_fetched_at=(Get-Date).ToString('o')
      }
    }
  } catch {
    $meta.errors += "event-live: $($_.Exception.Message)"
  }

  $teamMap=@{}; foreach($t in $boot.teams){ $teamMap[[int]$t.id]=$t.name }
  $posMap=@{}; foreach($p in $boot.element_types){ $posMap[[int]$p.id]=$p.singular_name_short }
  $boot.elements | Select-Object *,@{n='team_name';e={$teamMap[[int]$_.team]}},@{n='position_name';e={$posMap[[int]$_.element_type]}},@{n='price_m';e={[double]$_.now_cost/10.0}} | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Current 'players_current.csv')
  $boot.teams | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Current 'teams_current.csv')
  $boot.events | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Current 'events_current.csv')
  $boot.element_types | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Current 'positions_current.csv')
}

if($fixtures){
  if(-not $teamMap){ $teamMap=@{} }
  $fixtures | Select-Object *,@{n='home_team_name';e={$teamMap[[int]$_.team_h]}},@{n='away_team_name';e={$teamMap[[int]$_.team_a]}} | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $Current 'fixtures_current.csv')
}

if($boot -or $fixtures){ $meta.success=$true }
$completed=Get-Date
$meta.completed_at_local=$completed.ToString('o')
$meta.completed_at_utc=$completed.ToUniversalTime().ToString('o')
$meta.duration_seconds=[math]::Round(($completed-$started).TotalSeconds,1)
$meta | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 (Join-Path $Current '_sync_meta.json')

if(-not $Quiet){
  if($meta.success){ Write-Host "Official FPL sync complete in $($meta.duration_seconds)s." -ForegroundColor Green }
  if($meta.errors.Count -gt 0){ Write-Host 'Some endpoints failed; cached data remains usable.' -ForegroundColor Yellow }
}
return
