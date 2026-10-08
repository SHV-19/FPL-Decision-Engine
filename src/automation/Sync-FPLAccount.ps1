param(
    [switch]$Quiet,
    [ValidateSet('Quick','Full')][string]$Mode='Full',
    [switch]$Force
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ControlCenter-Lib.ps1')

$connPath=Join-Path $Root '06_CONFIG\fpl_connection.json'
$conn=Read-JsonSafe $connPath
$current=Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT'
$leagueDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\LEAGUES'
$rivalDir=Join-Path $Root '02_DATA\FPL_ACCOUNT\RIVALS'
$raw=Join-Path $Root '02_DATA\FPL_ACCOUNT\RAW'
New-Item -ItemType Directory -Force -Path $current,$leagueDir,$rivalDir,$raw | Out-Null

$started=Get-Date
$previousMeta=Read-JsonSafe (Join-Path $current '_account_sync_meta.json')
$previousCurrentTeamLastSuccess=$null
$previousCurrentTeamGameweek=$null
try{if($previousMeta.private_current_team_last_success_at){$previousCurrentTeamLastSuccess=[string]$previousMeta.private_current_team_last_success_at}elseif($previousMeta.private_current_team_synced_at){$previousCurrentTeamLastSuccess=[string]$previousMeta.private_current_team_synced_at}}catch{}
try{if($previousMeta.private_current_team_gameweek -ne $null){$previousCurrentTeamGameweek=[int]$previousMeta.private_current_team_gameweek}}catch{}
$meta=[ordered]@{
    synced_at_local=$started.ToString('o')
    completed_at_local=$null
    duration_seconds=$null
    mode=$Mode
    success=$false
    team_id=$null
    errors=@()
    private_current_team=$false
    private_current_team_synced_at=$previousCurrentTeamLastSuccess
    private_current_team_last_success_at=$previousCurrentTeamLastSuccess
    private_current_team_gameweek=$previousCurrentTeamGameweek
    private_current_team_cache_available=$false
    private_current_team_status='NOT_ENABLED'
    private_current_team_auth_detail=$null
    oidc_refresh_token_present=$false
    oidc_refresh_attempted=$false
    oidc_refresh_succeeded=$false
    oidc_refresh_rotated=$false
    oidc_client_id=$null
    auth_requires_reconnect=$false
    rival_picks_synced=0
    rival_picks_reused=0
    leagues_refreshed=0
    league_pages_fetched=0
    quick_skipped_heavy_leagues=($Mode -eq 'Quick')
    full_league_budget_seconds=if($Mode -eq 'Full'){45}else{0}
    full_league_budget_exhausted=$false
    tracked_leagues_considered=0
}

if(-not $conn -or -not $conn.team_id){
    $meta.errors += 'FPL Team ID is not configured.'
    $meta.completed_at_local=(Get-Date).ToString('o')
    $meta.duration_seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,1)
    Write-JsonUtf8 $meta (Join-Path $current '_account_sync_meta.json') 30
    if(-not $Quiet){ Write-Host 'FPL Team ID not configured. Use Connect FPL in the Control Center.' -ForegroundColor Yellow }
return
}

$teamId=[int]$conn.team_id
$meta.team_id=$teamId
$headers=@{'User-Agent'='Mozilla/5.0 FPL-Decision-Engine/2.5';'Accept'='application/json'}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$base='https://fantasy.premierleague.com/api'

function Fetch([string]$Url,[string]$Name,[hashtable]$ExtraHeaders=$null,[int]$TimeoutSec=12){
    try{
        $h=@{}
        foreach($k in $headers.Keys){$h[$k]=$headers[$k]}
        if($ExtraHeaders){foreach($k in $ExtraHeaders.Keys){$h[$k]=$ExtraHeaders[$k]}}
        if(-not $Quiet){ Write-Host "FPL account [$Mode]: $Name" -ForegroundColor Cyan }
        $o=Invoke-RestMethod -Uri $Url -Headers $h -TimeoutSec $TimeoutSec
        $o=Repair-ObjectStrings $o
        Write-JsonUtf8 $o (Join-Path $raw "$Name-$stamp.json") 100
        Write-JsonUtf8 $o (Join-Path $current "$Name.json") 100
        Start-Sleep -Milliseconds 120
        return $o
    } catch {
        $script:meta.errors += "$Name`: $($_.Exception.Message)"
        return $null
    }
}

function Get-PageNumberForRank([int]$Rank){
    if($Rank -le 0){return 1}
    return [math]::Max(1,[math]::Ceiling($Rank/50.0))
}

function Fetch-LeaguePage([int]$LeagueId,[int]$Page){
    try{
        $obj=Invoke-RestMethod -Uri "$base/leagues-classic/$LeagueId/standings/?page_standings=$Page" -Headers $headers -TimeoutSec 10
        $obj=Repair-ObjectStrings $obj
        $script:meta.league_pages_fetched++
        Start-Sleep -Milliseconds 150
        return $obj
    }catch{
        $script:meta.errors += "league $LeagueId page $Page`: $($_.Exception.Message)"
        return $null
    }
}

$entry=Fetch "$base/entry/$teamId/" 'entry'

# A quick live refresh needs the current official account state and exact team,
# not a complete crawl of every league/history endpoint.
$history=$null
$transfers=$null
if($Mode -eq 'Full'){
    $history=Fetch "$base/entry/$teamId/history/" 'history'
    $transfers=Fetch "$base/entry/$teamId/transfers/" 'transfers'
}else{
    $history=Read-JsonSafe (Join-Path $current 'history.json')
    $transfers=Read-JsonSafe (Join-Path $current 'transfers.json')
}

# Picks are immutable once the deadline has passed. During a quick sync, only
# refresh the latest locked GW. Full sync may also probe the decision GW/previous GW.
$gw=Get-EngineGameweek $Root
$lockedGw=Get-LatestLockedGameweek $Root
$pickGws=@()
if($Mode -eq 'Quick'){
    if($lockedGw -gt 0){$pickGws=@($lockedGw)}
}else{
    $pickGws=@($gw,$lockedGw,($gw-1)) | Where-Object { $_ -ge 1 } | Select-Object -Unique
}
foreach($g in $pickGws){
    $pickPath=Join-Path $current ("picks_GW{0:D2}.json" -f $g)
    # Historical locked lineups are immutable, but the CURRENT locked picks
    # response can still gain automatic_subs / entry_history updates after the
    # deadline. Always refresh the latest locked GW so the Live cockpit can
    # reconcile final FPL processing; reuse only older Gameweeks.
    if($g -lt $lockedGw -and (Test-Path $pickPath) -and -not $Force){
        continue
    }
    try{
        $p=Invoke-RestMethod -Uri "$base/entry/$teamId/event/$g/picks/" -Headers $headers -TimeoutSec 10
        $p=Repair-ObjectStrings $p
        Write-JsonUtf8 $p $pickPath 100
        Write-JsonUtf8 $p (Join-Path $raw ("picks_GW{0:D2}-$stamp.json" -f $g)) 100
        Start-Sleep -Milliseconds 100
    } catch { }
}

# Authenticated read-only current team.
# V3.0.3: FPL now uses PingOne/OIDC. A pasted x-api access token is intentionally
# short-lived, so the durable local credential is the browser OIDC refresh token.
# The refresh token is exchanged locally for a fresh access token on every sync,
# and any rotated refresh token is stored back into _LOCAL_SECRETS.
$secretDir=Join-Path $Root '06_CONFIG\_LOCAL_SECRETS'
$tokenPath=Join-Path $secretDir 'fpl_x_api_authorization.txt'
$refreshTokenPath=Join-Path $secretDir 'fpl_oidc_refresh_token.txt'
$oidcClientIdPath=Join-Path $secretDir 'fpl_oidc_client_id.txt'
$cookiePath=Join-Path $secretDir 'fpl_cookie.txt'
$myTeamPath=Join-Path $current 'my-team.json'
$cachedMyTeam=Read-JsonSafe $myTeamPath
$cachedMyTeamComplete=($cachedMyTeam -and $cachedMyTeam.picks -and @($cachedMyTeam.picks).Count -ge 15)
if($cachedMyTeamComplete){
    $meta.private_current_team_cache_available=$true
    if(-not $meta.private_current_team_last_success_at){
        try{$meta.private_current_team_last_success_at=(Get-Item $myTeamPath).LastWriteTime.ToString('o')}catch{}
        $meta.private_current_team_synced_at=$meta.private_current_team_last_success_at
    }
}

function Get-FplOidcAccessToken {
    if(-not (Test-Path $refreshTokenPath)){return $null}
    $refreshToken=$null
    try{$refreshToken=(Get-Content $refreshTokenPath -Raw -Encoding UTF8).Trim()}catch{}
    if([string]::IsNullOrWhiteSpace($refreshToken)){return $null}

    $script:meta.oidc_refresh_token_present=$true
    $script:meta.oidc_refresh_attempted=$true

    # Current production FPL web SPA client, kept in a local override file so
    # future client changes do not require another architecture rewrite.
    $clientId='bfcbaf69-aade-4c1b-8f00-c1cb8a193030'
    try{
        if(Test-Path $oidcClientIdPath){
            $configured=(Get-Content $oidcClientIdPath -Raw -Encoding UTF8).Trim()
            if(-not [string]::IsNullOrWhiteSpace($configured)){$clientId=$configured}
        }
    }catch{}
    $script:meta.oidc_client_id=$clientId

    try{
        $body=@{
            grant_type='refresh_token'
            refresh_token=$refreshToken
            client_id=$clientId
        }
        $tokenResp=Invoke-RestMethod -Method Post -Uri 'https://account.premierleague.com/as/token' -ContentType 'application/x-www-form-urlencoded' -Body $body -Headers @{'Accept'='application/json'} -TimeoutSec 15
        if(-not $tokenResp -or [string]::IsNullOrWhiteSpace([string]$tokenResp.access_token)){
            throw 'OIDC token endpoint returned no access_token.'
        }

        $newAccess=([string]$tokenResp.access_token).Trim()
        $newRefresh=$null
        try{$newRefresh=([string]$tokenResp.refresh_token).Trim()}catch{}
        if(-not [string]::IsNullOrWhiteSpace($newRefresh)){
            if($newRefresh -ne $refreshToken){$script:meta.oidc_refresh_rotated=$true}
            $newRefresh | Set-Content -LiteralPath $refreshTokenPath -Encoding UTF8
        }
        ('Bearer '+$newAccess) | Set-Content -LiteralPath $tokenPath -Encoding UTF8
        $script:meta.oidc_refresh_succeeded=$true
        $script:meta.auth_requires_reconnect=$false
        return ('Bearer '+$newAccess)
    }catch{
        $script:meta.oidc_refresh_succeeded=$false
        $script:meta.auth_requires_reconnect=$true
        $script:meta.errors += "OIDC refresh: $($_.Exception.Message)"
        return $null
    }
}

if($conn.private_current_team_enabled -eq $true){
    $privateHeaders=@{
        'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36'
        'Accept'='application/json, text/plain, */*'
        'Referer'='https://fantasy.premierleague.com/'
        'Origin'='https://fantasy.premierleague.com'
    }
    $authMode=$null

    # Preferred durable path: rotate a stored OIDC refresh token into a fresh
    # access token each time. This removes the old "works for a few hours then
    # silently falls back to a 3-day-old team" behavior.
    $refreshedBearer=Get-FplOidcAccessToken
    if(-not [string]::IsNullOrWhiteSpace([string]$refreshedBearer)){
        $privateHeaders['x-api-authorization']=$refreshedBearer
        $authMode='OIDC_REFRESH_TOKEN'
    }

    # Legacy fallback: still accept a manually pasted Bearer access token. It is
    # intentionally labelled temporary because FPL access tokens expire.
    if(-not $authMode -and (Test-Path $tokenPath)){
        $token=(Get-Content $tokenPath -Raw -Encoding UTF8).Trim()
        if($token){
            if(-not $token.StartsWith('Bearer ',[StringComparison]::OrdinalIgnoreCase)){
                $token='Bearer ' + $token
            }
            $privateHeaders['x-api-authorization']=$token
            $authMode='X_API_AUTHORIZATION_TEMPORARY'
        }
    }

    if(-not $authMode -and (Test-Path $cookiePath)){
        $cookie=(Get-Content $cookiePath -Raw -Encoding UTF8).Trim()
        if($cookie){
            $privateHeaders['Cookie']=$cookie
            $authMode='COOKIE_FALLBACK'
        }
    }

    if($authMode){
        try{
            # Verify identity when /me is available. Never let an auth credential
            # for another FPL account populate this project's current squad.
            try{
                $meObj=Invoke-RestMethod -Uri "$base/me/" -Headers $privateHeaders -TimeoutSec 10
                $authEntryId=$null
                try{if($meObj.player -and $meObj.player.entry -ne $null){$authEntryId=[int]$meObj.player.entry}}catch{}
                if($authEntryId -and $authEntryId -ne $teamId){
                    throw ("Authenticated FPL account belongs to Team ID {0}, but this engine is configured for Team ID {1}." -f $authEntryId,$teamId)
                }
            }catch{
                if($_.Exception.Message -match 'belongs to Team ID'){throw}
            }

            $my=Invoke-RestMethod -Uri "$base/my-team/$teamId/" -Headers $privateHeaders -TimeoutSec 12
            $my=Repair-ObjectStrings $my
            if(-not $my -or -not $my.picks -or @($my.picks).Count -lt 15){
                throw 'Authenticated endpoint returned no complete 15-player current team.'
            }

            $teamChanged=$false
            if($cachedMyTeamComplete){
                try{
                    $oldSig=@($cachedMyTeam.picks | ForEach-Object {('{0}|{1}|{2}|{3}' -f [int]$_.element,[int]$_.position,[bool]$_.is_captain,[bool]$_.is_vice_captain)}) -join ';'
                    $newSig=@($my.picks | ForEach-Object {('{0}|{1}|{2}|{3}' -f [int]$_.element,[int]$_.position,[bool]$_.is_captain,[bool]$_.is_vice_captain)}) -join ';'
                    $teamChanged=($oldSig -ne $newSig)
                }catch{$teamChanged=$false}
            }

            Write-JsonUtf8 $my $myTeamPath 100
            Write-JsonUtf8 $my (Join-Path $raw ("my-team-$stamp.json")) 100
            $meta.private_current_team=$true
            $meta.private_current_team_cache_available=$true
            $meta.private_current_team_status='SYNCED'
            $meta.private_current_team_auth_mode=$authMode
            $meta.private_current_team_auth_detail=if($authMode -eq 'OIDC_REFRESH_TOKEN'){'DURABLE_OIDC_REFRESH'}else{'TEMPORARY_OR_FALLBACK'}
            $meta.private_current_team_synced_at=(Get-Date).ToString('o')
            $meta.private_current_team_last_success_at=$meta.private_current_team_synced_at
            $meta.private_current_team_gameweek=$gw
            $meta.auth_requires_reconnect=$false
            if($teamChanged){
                try{
                    $actionSummary=Get-ResearchActionSummary $Root $cachedMyTeam $my
                    Append-ResearchEvent $Root 'OFFICIAL_TEAM_CHANGED' ([ordered]@{source='OFFICIAL_FPL_MY_TEAM';before=@($cachedMyTeam.picks);after=@($my.picks);action_summary=$actionSummary;bank=if($my.transfers){$my.transfers.bank}else{$null};value=if($my.transfers){$my.transfers.value}else{$null}}) $gw $null ([string]$teamId) | Out-Null
                }catch{}
            }
            try{Reconcile-ResearchHunchesWithOfficialTeam $Root $my $gw $teamChanged $cachedMyTeam}catch{}
        } catch {
            $meta.private_current_team=$false
            $meta.private_current_team_cache_available=$cachedMyTeamComplete
            $meta.private_current_team_status=if($cachedMyTeamComplete){'AUTH_EXPIRED_USING_CACHE'}else{'AUTH_FAILED_OR_EXPIRED'}
            $meta.private_current_team_auth_mode=$authMode
            if($authMode -ne 'COOKIE_FALLBACK'){$meta.auth_requires_reconnect=$true}
            $meta.errors += "private my-team: $($_.Exception.Message)"
        }
    } else {
        $meta.private_current_team=$false
        $meta.private_current_team_cache_available=$cachedMyTeamComplete
        $meta.private_current_team_status=if($cachedMyTeamComplete){'AUTH_MISSING_USING_CACHE'}else{'AUTH_MISSING'}
        $meta.private_current_team_auth_mode=$null
        $meta.auth_requires_reconnect=$true
    }
}

# Discover private classic mini-leagues from the lightweight entry response.
$private=@()
if($entry -and $entry.leagues -and $entry.leagues.classic){
    $private=@($entry.leagues.classic | Where-Object { $_.league_type -eq 'x' } | Select-Object id,name,entry_rank,entry_last_rank,start_event,entry_can_leave,entry_can_admin)
    Write-JsonUtf8 $private (Join-Path $current 'discovered_private_leagues.json') 30
}

# Heavy league/rival work is deliberately excluded from Quick mode.
if($Mode -eq 'Full'){
    $privateIdSet=@{}
    foreach($pl in $private){$privateIdSet[[int]$pl.id]=$pl}

    # Full sync is bounded. Prioritize the user's highest-ranked private leagues,
    # then only a small number of explicitly added public leagues.
    $privateTrack=@()
    if($conn.auto_track_private_classic_leagues -eq $true){
        $privateTrack=@($private | Sort-Object entry_rank | Select-Object -First 8 | ForEach-Object {[int]$_.id})
    }
    $extraTrack=@()
    if($conn.tracked_league_ids){
        $extraTrack=@($conn.tracked_league_ids |
            ForEach-Object {[int]$_} |
            Where-Object {$privateTrack -notcontains $_} |
            Select-Object -Unique |
            Select-Object -First 3)
    }
    $track=@($privateTrack+$extraTrack | Select-Object -Unique)
    $meta.tracked_leagues_considered=$track.Count
    $leagueWorkStarted=Get-Date
    $leagueBudgetSeconds=45

    foreach($lid in $track){
        if(((Get-Date)-$leagueWorkStarted).TotalSeconds -ge $leagueBudgetSeconds){
            $meta.full_league_budget_exhausted=$true
            $meta.errors += "Full account league refresh stopped at the ${leagueBudgetSeconds}s safety budget. Remaining leagues keep their previous cache."
            break
        }
        try{
            # Page 1 gives the leaders. For a league the user belongs to, fetch the
            # page containing the user's rank and adjacent pages so nearby rivals
            # are available without crawling up to 20 pages.
            $pages=New-Object System.Collections.ArrayList
            [void]$pages.Add(1)
            $rankHint=0
            if($privateIdSet.ContainsKey([int]$lid)){
                try{$rankHint=[int]$privateIdSet[[int]$lid].entry_rank}catch{}
            }
            $userPage=Get-PageNumberForRank $rankHint
            $candidatePages=[int[]]@(($userPage - 1),$userPage,($userPage + 1))
            foreach($pageCandidate in $candidatePages){
                if($pageCandidate -ge 1 -and -not $pages.Contains([int]$pageCandidate)){[void]$pages.Add([int]$pageCandidate)}
            }

            $all=@()
            $leagueInfo=$null
            foreach($page in @($pages | Sort-Object)){
                if(((Get-Date)-$leagueWorkStarted).TotalSeconds -ge $leagueBudgetSeconds){$meta.full_league_budget_exhausted=$true;break}
                $obj=Fetch-LeaguePage $lid $page
                if(-not $obj){continue}
                if(-not $leagueInfo){$leagueInfo=$obj.league}
                $all += @($obj.standings.results)
            }
            $all=@($all | Sort-Object entry -Unique | Sort-Object rank)
            if($leagueInfo){
                $leagueOut=[ordered]@{league=$leagueInfo;standings=$all;synced_at=(Get-Date).ToString('o');partial_window=$true;pages_fetched=@($pages | Sort-Object)}
                Write-JsonUtf8 $leagueOut (Join-Path $leagueDir ("league_$lid.json")) 100
                $meta.leagues_refreshed++
            }

            # Locked rival picks only matter for private leagues. They are immutable,
            # so fetch a small relevant sample once per GW and then reuse it.
            if($privateIdSet.ContainsKey([int]$lid) -and $conn.sync_rival_picks_after_deadline -eq $true -and $lockedGw -gt 0 -and $leagueInfo){
                $topN=5
                $nearN=5
                try{if($conn.max_rivals_per_league){$topN=[math]::Min(8,[int]$conn.max_rivals_per_league)}}catch{}
                $top=@($all | Where-Object {[int]$_.entry -ne $teamId} | Sort-Object rank | Select-Object -First $topN)
                $me=$all | Where-Object {[int]$_.entry -eq $teamId} | Select-Object -First 1
                $near=@()
                if($me){
                    $near=@($all | Where-Object {[int]$_.entry -ne $teamId} | Sort-Object @{Expression={[math]::Abs([int]$_.rank-[int]$me.rank)}} | Select-Object -First $nearN)
                }
                $rivals=@($top+$near | Sort-Object entry -Unique)

                foreach($r in $rivals){
                    if(((Get-Date)-$leagueWorkStarted).TotalSeconds -ge $leagueBudgetSeconds){$meta.full_league_budget_exhausted=$true;break}
                    $rid=[int]$r.entry
                    $rivalPath=Join-Path $rivalDir ("league_${lid}_entry_${rid}_GW{0:D2}.json" -f $lockedGw)
                    if((Test-Path $rivalPath) -and -not $Force){
                        $meta.rival_picks_reused++
                        continue
                    }
                    try{
                        $rp=Invoke-RestMethod -Uri "$base/entry/$rid/event/$lockedGw/picks/" -Headers $headers -TimeoutSec 10
                        $rp=Repair-ObjectStrings $rp
                        $ro=[ordered]@{league_id=$lid;league_name=$leagueInfo.name;entry=$rid;entry_name=$r.entry_name;player_name=$r.player_name;rank=$r.rank;total=$r.total;event_total=$r.event_total;picks=$rp;synced_at=(Get-Date).ToString('o')}
                        Write-JsonUtf8 $ro $rivalPath 100
                        $meta.rival_picks_synced++
                        Start-Sleep -Milliseconds 250
                    } catch {
                        $meta.errors += "rival $rid GW$lockedGw`: $($_.Exception.Message)"
                    }
                }
            }
        } catch {
            $meta.errors += "league $lid`: $($_.Exception.Message)"
        }
    }
}

if($entry){$meta.success=$true}
$meta.completed_at_local=(Get-Date).ToString('o')
$meta.duration_seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,1)
Write-JsonUtf8 $meta (Join-Path $current '_account_sync_meta.json') 30

if(-not $Quiet){
    if($meta.success){Write-Host "FPL account $Mode sync complete for Team ID $teamId in $($meta.duration_seconds)s." -ForegroundColor Green}
    if($Mode -eq 'Quick'){Write-Host 'Heavy league/rival crawling skipped. Automatic league intelligence runs independently; use Deep Refresh only for maintenance.' -ForegroundColor DarkGray}
    if($meta.errors.Count -gt 0){Write-Host 'Some optional account endpoints were unavailable; cached data was preserved.' -ForegroundColor Yellow}
}
return
