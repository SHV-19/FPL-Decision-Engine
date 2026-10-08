# FPL Decision Engine V3 research foundation.
# Dependency-free, local-first, append-only event storage for Windows PowerShell 5.1+.

function Get-ResearchRoot([string]$Root) {
    return (Join-Path $Root '02_DATA\RESEARCH')
}

function Get-ResearchModelVersion([string]$Root) {
    try {
        $manifest=Read-JsonSafe (Join-Path $Root '00_SYSTEM\release_manifest.json')
        if($manifest -and $manifest.version){return [string]$manifest.version}
    } catch {}
    return '4.1.2'
}

function Initialize-ResearchStore([string]$Root) {
    $researchRoot=Get-ResearchRoot $Root
    $exports=Join-Path $researchRoot 'EXPORTS'
    $snapshots=Join-Path $researchRoot 'PROFILE_SNAPSHOTS'
    New-Item -ItemType Directory -Force -Path $researchRoot,$exports,$snapshots | Out-Null

    $metaPath=Join-Path $researchRoot 'research_meta.json'
    $meta=Read-JsonSafe $metaPath
    if(-not $meta){
        $meta=[ordered]@{
            schema_version=5
            storage='LOCAL_APPEND_ONLY_JSONL'
            participant_id='P001'
            created_at=(Get-Date).ToString('o')
            last_migration='V4.1.2'
            note='Portable V3 research foundation with automatic Deep Dive behavior capture, deadline-aware temporal attribution and population-integrity controls. JSONL is append-only and dependency-free; the in-app Research Observatory is the primary dashboard and CSV/JSON remain open exports.'
        }
        Write-JsonUtf8 $meta $metaPath 30
    }

    $profilePath=Join-Path $researchRoot 'participant_profile.json'
    $profile=Read-JsonSafe $profilePath
    if(-not $profile){
        $profile=[ordered]@{
            participant_id='P001'
            revision=1
            updated_at=(Get-Date).ToString('o')
            fpl_background=''
            football_statistics_beliefs=''
            hunch_behavior=''
            risk_preference='BALANCED'
            club_allegiance=''
            source_trust=''
            ai_trust_percent=$null
            objectives=''
            notes=''
        }
        Write-JsonUtf8 $profile $profilePath 50
        $snapshot=Join-Path $snapshots ('P001_rev_0001.json')
        Write-JsonUtf8 $profile $snapshot 50
        Append-ResearchEvent $Root 'PROFILE_CREATED' ([ordered]@{participant_id='P001';revision=1;profile=$profile}) 0 $null 'P001'
    }
    return $researchRoot
}

function ConvertTo-ResearchPayloadJson($Payload) {
    if($null -eq $Payload){return '{}'}
    try{return ($Payload | ConvertTo-Json -Depth 80 -Compress)}catch{return '{}'}
}

function Append-ResearchJsonLine([string]$Path,$Object) {
    $parent=Split-Path -Parent $Path
    if($parent){New-Item -ItemType Directory -Force -Path $parent | Out-Null}
    $line=$Object | ConvertTo-Json -Depth 80 -Compress
    if(-not (Test-Path $Path)){
        # Windows PowerShell 5.1 writes UTF-8 with BOM here, which is safe for our reader.
        Set-Content -LiteralPath $Path -Value $line -Encoding UTF8
    } else {
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
}

function Get-ResearchTemporalAttribution {
    param(
        [string]$Root,
        [string]$EventType,
        [string]$ObservedAt,
        [int]$RecordedGameweek=0
    )
    $out=[ordered]@{
        applicable=$false
        recorded_gameweek=$RecordedGameweek
        effective_gameweek=$null
        next_actionable_gameweek=$null
        deadline_time=$null
        deadline_relation='UNKNOWN'
        attribution_status='UNKNOWN'
        attribution_basis='OFFICIAL_FPL_DEADLINE_WINDOW'
    }
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if(-not $boot -or -not $boot.events){return [pscustomobject]$out}
    $obs=$null
    try{$obs=[DateTimeOffset]::Parse([string]$ObservedAt).ToUniversalTime()}catch{$obs=[DateTimeOffset]::UtcNow}
    $events=@($boot.events | Where-Object {$_.deadline_time} | Sort-Object {[int]$_.id})
    $recorded=$events | Where-Object {[int]$_.id -eq $RecordedGameweek} | Select-Object -First 1
    if($recorded){
        try{
            $rd=[DateTimeOffset]::Parse([string]$recorded.deadline_time).ToUniversalTime()
            $out.deadline_time=$rd.ToString('o')
            $out.deadline_relation=if($obs -lt $rd){'BEFORE_RECORDED_GW_DEADLINE'}else{'AT_OR_AFTER_RECORDED_GW_DEADLINE'}
        }catch{}
    }
    $actionable=$null
    foreach($candidate in $events){
        try{
            $cd=[DateTimeOffset]::Parse([string]$candidate.deadline_time).ToUniversalTime()
            if($obs -lt $cd){$actionable=$candidate;break}
        }catch{}
    }
    if($actionable){$out.next_actionable_gameweek=[int]$actionable.id}
    $decisionLike=([string]$EventType).ToUpperInvariant() -match 'DEEP_DIVE|USER_INPUT|USER_STATEMENT|PRE_ANALYSIS|HUNCH|MODEL_RECOMMENDATION|USER_FINAL_DECISION|USER_ACCEPTED_MODEL|USER_OVERRULED_MODEL|USER_CHANGED_MIND|OFFICIAL_TEAM_CHANGED|BEHAVIORAL_SIGNAL|EVIDENCE_LINKED_TO_DECISION'
    if($decisionLike){
        $out.applicable=$true
        if($actionable){
            $out.effective_gameweek=[int]$actionable.id
            if($RecordedGameweek -le 0 -or [int]$actionable.id -eq $RecordedGameweek){$out.attribution_status='CONSISTENT'}
            else{$out.attribution_status='RECORDED_GW_DIFFERS_FROM_ACTION_WINDOW'}
        } else {$out.attribution_status='NO_FUTURE_DEADLINE_IN_BOOTSTRAP'}
    } else {
        $out.attribution_status='NOT_APPLICABLE'
    }
    return [pscustomobject]$out
}

function Append-ResearchEvent {
    param(
        [string]$Root,
        [string]$EventType,
        $Payload,
        [int]$Gameweek=0,
        [string]$DecisionId=$null,
        [string]$SubjectId=$null
    )
    if([string]::IsNullOrWhiteSpace($EventType)){return $null}
    $researchRoot=Get-ResearchRoot $Root
    New-Item -ItemType Directory -Force -Path $researchRoot | Out-Null
    if($Gameweek -le 0){
        try{$Gameweek=Get-EngineGameweek $Root}catch{$Gameweek=0}
    }
    $observedAt=(Get-Date).ToString('o')
    $temporal=Get-ResearchTemporalAttribution $Root $EventType $observedAt $Gameweek
    $researchEvent=[ordered]@{
        event_id=[guid]::NewGuid().ToString('N')
        event_type=$EventType.ToUpperInvariant()
        observed_at=$observedAt
        gameweek=$Gameweek
        effective_gameweek=$temporal.effective_gameweek
        deadline_time=$temporal.deadline_time
        deadline_relation=$temporal.deadline_relation
        temporal_attribution=$temporal.attribution_status
        temporal_basis=$temporal.attribution_basis
        participant_id='P001'
        decision_id=$DecisionId
        subject_id=$SubjectId
        model_version=Get-ResearchModelVersion $Root
        payload=$Payload
    }
    Append-ResearchJsonLine (Join-Path $researchRoot 'events.jsonl') $researchEvent
    return [pscustomobject]$researchEvent
}

function Read-ResearchJsonLines([string]$Path,[int]$Limit=0) {
    if(-not (Test-Path $Path)){return @()}
    $lines=@(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)})
    if($Limit -gt 0 -and $lines.Count -gt $Limit){$lines=@($lines | Select-Object -Last $Limit)}
    $out=@()
    foreach($line in $lines){
        try{$out += ($line | ConvertFrom-Json)}catch{}
    }
    return @($out)
}

function Save-ResearchProfile([string]$Root,$IncomingProfile,[string]$Source='CONTROL_CENTER') {
    Initialize-ResearchStore $Root | Out-Null
    $researchRoot=Get-ResearchRoot $Root
    $profilePath=Join-Path $researchRoot 'participant_profile.json'
    $current=Read-JsonSafe $profilePath
    if(-not $current){throw 'Research profile could not be initialized.'}

    $fields=@('fpl_background','football_statistics_beliefs','hunch_behavior','risk_preference','club_allegiance','source_trust','ai_trust_percent','objectives','notes')
    $changes=@()
    $next=[ordered]@{}
    foreach($prop in $current.PSObject.Properties){$next[$prop.Name]=$prop.Value}
    foreach($field in $fields){
        if(-not ($IncomingProfile.PSObject.Properties.Name -contains $field)){continue}
        $before=$current.$field
        $after=$IncomingProfile.$field
        if($field -eq 'ai_trust_percent'){
            if($after -eq '' -or $null -eq $after){$after=$null}
            else{
                try{$after=[math]::Max(0,[math]::Min(100,[int]$after))}catch{throw 'AI trust must be a number from 0 to 100.'}
            }
        } else {$after=[string]$after}
        if(([string]$before) -ne ([string]$after)){
            $changes += [ordered]@{field=$field;before=$before;after=$after}
            $next[$field]=$after
        }
    }
    if($changes.Count -eq 0){return [pscustomobject]@{changed=$false;profile=$current;change_count=0}}

    $revision=1
    try{$revision=[int]$current.revision+1}catch{}
    $next['participant_id']='P001'
    $next['revision']=$revision
    $next['updated_at']=(Get-Date).ToString('o')
    Write-JsonUtf8 $next $profilePath 50
    $snapshot=Join-Path (Join-Path $researchRoot 'PROFILE_SNAPSHOTS') ('P001_rev_{0:D4}.json' -f $revision)
    Write-JsonUtf8 $next $snapshot 50

    foreach($change in $changes){
        Append-ResearchEvent $Root 'PROFILE_FIELD_CHANGED' ([ordered]@{
            participant_id='P001';revision=$revision;field=$change.field;before=$change.before;after=$change.after;source=$Source
        }) 0 $null 'P001' | Out-Null
    }
    return [pscustomobject]@{changed=$true;profile=[pscustomobject]$next;change_count=$changes.Count}
}

function Record-PreAnalysisBelief([string]$Root,$Belief) {
    Initialize-ResearchStore $Root | Out-Null
    $action=([string]$Belief.preferred_action).Trim()
    if([string]::IsNullOrWhiteSpace($action)){throw 'Preferred action is required for a pre-analysis belief.'}
    $confidence=$null
    if($Belief.confidence_percent -ne $null -and [string]$Belief.confidence_percent -ne ''){
        try{$confidence=[math]::Max(0,[math]::Min(100,[int]$Belief.confidence_percent))}catch{throw 'Confidence must be 0-100.'}
    }
    $decisionId=[string]$Belief.decision_id
    if([string]::IsNullOrWhiteSpace($decisionId)){$decisionId=[guid]::NewGuid().ToString('N')}
    $payload=[ordered]@{
        preferred_action=$action
        confidence_percent=$confidence
        reason=([string]$Belief.reason).Trim()
        evidence_type=([string]$Belief.evidence_type).Trim()
        hunch_category=([string]$Belief.hunch_category).Trim()
        question=([string]$Belief.question).Trim()
        recorded_before_model=$true
    }
    $researchEvent=Append-ResearchEvent $Root 'PRE_ANALYSIS_BELIEF_RECORDED' $payload 0 $decisionId 'P001'
    if(-not [string]::IsNullOrWhiteSpace([string]$payload.hunch_category)){
        Append-ResearchEvent $Root 'HUNCH_RECORDED' ([ordered]@{
            claim=$action;confidence_percent=$confidence;category=$payload.hunch_category;reason=$payload.reason;origin='PRE_ANALYSIS_BELIEF'
        }) 0 $decisionId 'P001' | Out-Null
    }
    return $researchEvent
}

function Record-PostDecision([string]$Root,$Decision) {
    Initialize-ResearchStore $Root | Out-Null
    $decisionId=[string]$Decision.decision_id
    if([string]::IsNullOrWhiteSpace($decisionId)){$decisionId=[guid]::NewGuid().ToString('N')}
    $finalAction=([string]$Decision.final_action).Trim()
    if([string]::IsNullOrWhiteSpace($finalAction)){throw 'Final action is required.'}
    $payload=[ordered]@{
        final_action=$finalAction
        changed_mind=($Decision.changed_mind -eq $true)
        model_response=([string]$Decision.model_response).Trim()
        model_followed=([string]$Decision.model_followed).Trim().ToUpperInvariant()
        evidence_that_changed_mind=([string]$Decision.evidence_that_changed_mind).Trim()
        notes=([string]$Decision.notes).Trim()
    }
    $researchEvent=Append-ResearchEvent $Root 'USER_FINAL_DECISION_RECORDED' $payload 0 $decisionId 'P001'
    if($payload.changed_mind){Append-ResearchEvent $Root 'USER_CHANGED_MIND' $payload 0 $decisionId 'P001' | Out-Null}
    if($payload.model_followed -eq 'ACCEPTED'){Append-ResearchEvent $Root 'USER_ACCEPTED_MODEL' $payload 0 $decisionId 'P001' | Out-Null}
    if($payload.model_followed -eq 'OVERRULED'){Append-ResearchEvent $Root 'USER_OVERRULED_MODEL' $payload 0 $decisionId 'P001' | Out-Null}
    return $researchEvent
}

function Record-Evidence([string]$Root,$Evidence) {
    Initialize-ResearchStore $Root | Out-Null
    $claim=([string]$Evidence.claim).Trim()
    if([string]::IsNullOrWhiteSpace($claim)){throw 'Evidence claim is required.'}
    $evidenceId=[string]$Evidence.evidence_id
    if([string]::IsNullOrWhiteSpace($evidenceId)){$evidenceId=[guid]::NewGuid().ToString('N')}
    $reliability=$null
    if($Evidence.pre_resolution_reliability_percent -ne $null -and [string]$Evidence.pre_resolution_reliability_percent -ne ''){
        try{$reliability=[math]::Max(0,[math]::Min(100,[int]$Evidence.pre_resolution_reliability_percent))}catch{}
    }
    $payload=[ordered]@{
        evidence_id=$evidenceId
        source_type=([string]$Evidence.source_type).Trim().ToUpperInvariant()
        source_identity=([string]$Evidence.source_identity).Trim()
        entity=([string]$Evidence.entity).Trim()
        claim=$claim
        claim_category=([string]$Evidence.claim_category).Trim()
        classification=([string]$Evidence.classification).Trim().ToUpperInvariant()
        pre_resolution_reliability_percent=$reliability
        freshness=([string]$Evidence.freshness).Trim()
        corroboration_status=([string]$Evidence.corroboration_status).Trim().ToUpperInvariant()
        contradiction_status=([string]$Evidence.contradiction_status).Trim().ToUpperInvariant()
        decision_id=([string]$Evidence.decision_id).Trim()
        research_tags=([string]$Evidence.research_tags).Trim()
    }
    return Append-ResearchEvent $Root 'EVIDENCE_ADDED' $payload 0 $payload.decision_id $evidenceId
}

function Record-ScreenshotEvidence([string]$Root,[string]$FileName,[long]$SizeBytes=0,[string]$DecisionId=$null,[string]$Status='NEW') {
    if([string]::IsNullOrWhiteSpace($FileName)){return $null}
    $payload=[ordered]@{
        screenshot_id=[guid]::NewGuid().ToString('N')
        file_name=$FileName
        size_bytes=$SizeBytes
        status=$Status
        provenance='LOCAL_SCREENSHOT_INBOX'
    }
    return Append-ResearchEvent $Root 'SCREENSHOT_ADDED' $payload 0 $DecisionId $payload.screenshot_id
}



function Get-ScreenshotEvidenceIndexPath([string]$Root) {
    return (Join-Path (Get-ResearchRoot $Root) 'screenshot_evidence_index.json')
}

function Get-ScreenshotEvidenceIndex([string]$Root) {
    $path=Get-ScreenshotEvidenceIndexPath $Root
    $idx=Read-JsonSafe $path
    if(-not $idx){return @()}
    if($idx -is [array]){return @($idx)}
    if($idx.items){return @($idx.items)}
    return @($idx)
}

function Save-ScreenshotEvidenceIndex([string]$Root,[object[]]$Items) {
    $path=Get-ScreenshotEvidenceIndexPath $Root
    Write-JsonUtf8 ([ordered]@{version=1;updated_at=(Get-Date).ToString('o');items=@($Items)}) $path 80
}

function Queue-ScreenshotClassification([string]$Root,[string]$FileName,[string]$ScreenshotId=$null,[long]$SizeBytes=0) {
    if([string]::IsNullOrWhiteSpace($FileName)){return $null}
    Initialize-ResearchStore $Root | Out-Null
    $queueDir=Join-Path (Get-ResearchRoot $Root) 'EVIDENCE_QUEUE'
    New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
    if([string]::IsNullOrWhiteSpace($ScreenshotId)){$ScreenshotId=[guid]::NewGuid().ToString('N')}
    $jobId=[guid]::NewGuid().ToString('N')
    $job=[ordered]@{
        job_id=$jobId;screenshot_id=$ScreenshotId;file_name=[IO.Path]::GetFileName($FileName);size_bytes=$SizeBytes
        status='QUEUED';created_at=(Get-Date).ToString('o');attempts=0
    }
    $path=Join-Path $queueDir ($jobId+'.json')
    Write-JsonUtf8 $job $path 30
    Append-ResearchEvent $Root 'SCREENSHOT_CLASSIFICATION_QUEUED' ([ordered]@{job_id=$jobId;screenshot_id=$ScreenshotId;file_name=$job.file_name;size_bytes=$SizeBytes}) 0 $null $ScreenshotId | Out-Null
    return [pscustomobject]$job
}

function Upsert-ScreenshotClassification([string]$Root,$Classification) {
    if(-not $Classification){return}
    $items=@(Get-ScreenshotEvidenceIndex $Root)
    $name=[string]$Classification.file_name
    $sid=[string]$Classification.screenshot_id
    $next=@($items | Where-Object {([string]$_.file_name -ne $name) -and ([string]$_.screenshot_id -ne $sid)})
    $next += [pscustomobject]$Classification
    if($next.Count -gt 1000){$next=@($next | Sort-Object classified_at -Descending | Select-Object -First 1000)}
    Save-ScreenshotEvidenceIndex $Root $next
}

function Get-ResearchPlayerLookup([string]$Root) {
    $boot=Read-JsonSafe (Join-Path $Root '02_DATA\CURRENT\bootstrap-static.json')
    if(-not $boot){return @()}
    $teams=@{}
    foreach($t in @($boot.teams)){try{$teams[[int]$t.id]=[string]$t.name}catch{}}
    $rows=@()
    foreach($p in @($boot.elements)){
        try{
            $rows += [pscustomobject][ordered]@{
                id=[int]$p.id
                web_name=[string]$p.web_name
                full_name=(([string]$p.first_name+' '+[string]$p.second_name).Trim())
                team=if($teams.ContainsKey([int]$p.team)){$teams[[int]$p.team]}else{''}
            }
        }catch{}
    }
    return @($rows)
}

function Get-ResearchCurrentTeamSnapshot([string]$Root) {
    $my=Read-JsonSafe (Join-Path $Root '02_DATA\FPL_ACCOUNT\CURRENT\my-team.json')
    if(-not $my -or -not $my.picks -or @($my.picks).Count -lt 15){return $null}
    $lookup=@{};foreach($p in @(Get-ResearchPlayerLookup $Root)){$lookup[[int]$p.id]=$p}
    $picks=@()
    foreach($pick in @($my.picks)){
        $id=0;try{$id=[int]$pick.element}catch{}
        $name=if($lookup.ContainsKey($id)){[string]$lookup[$id].web_name}else{[string]$id}
        $picks += [pscustomobject][ordered]@{
            id=$id;name=$name;position=[int]$pick.position;captain=($pick.is_captain -eq $true);vice=($pick.is_vice_captain -eq $true)
        }
    }
    $sig=@($picks | Sort-Object position | ForEach-Object {('{0}|{1}|{2}|{3}' -f $_.id,$_.position,$_.captain,$_.vice)}) -join ';'
    $cap=$picks | Where-Object {$_.captain} | Select-Object -First 1
    $vice=$picks | Where-Object {$_.vice} | Select-Object -First 1
    return [pscustomobject][ordered]@{
        signature=$sig
        player_ids=@($picks.id)
        player_names=@($picks.name)
        captain_id=if($cap){$cap.id}else{$null}
        captain=if($cap){$cap.name}else{$null}
        vice_id=if($vice){$vice.id}else{$null}
        vice=if($vice){$vice.name}else{$null}
        captured_at=(Get-Date).ToString('o')
    }
}

function Get-NaturalLanguageResearchClassification([string]$Root,[string]$Text) {
    $raw=([string]$Text).Trim()
    $lower=$raw.ToLowerInvariant()
    $rules=@(
        [pscustomobject]@{category='HUNCH';group='BELIEF';confidence=0.96;pattern='\b(hunch|gut feeling|gut says|instinct|instinctively|i fancy|fancying|something tells me|i have a feeling|my feeling|i reckon|tempted by|i am tempted|i\x27m tempted)\b'},
        [pscustomobject]@{category='USER_OPINION';group='BELIEF';confidence=0.88;pattern='\b(i think|i believe|i prefer|my view is|my take is|i would rather|i\x27d rather|for me .* is better|i like .* more)\b'},
        [pscustomobject]@{category='EYE_TEST';group='EVIDENCE';confidence=0.94;pattern='\b(eye test|watched him|watched her|watched the game|watching the game|when i watched|looked dangerous|looked sharp|looked good|looked great|looked poor|looked bad|on the eye|visually|from watching|match observation)\b'},
        [pscustomobject]@{category='TACTICAL_OBSERVATION';group='EVIDENCE';confidence=0.91;pattern='\b(tactical|tactically|playing wider|playing wide|playing centrally|central role|number 9|false 9|inverted|overlap|underlap|positioning|role change|new role|advanced role|deeper role|heatmap|heat map)\b'},
        [pscustomobject]@{category='SOCIAL_EXTERNAL_OPINION';group='EVIDENCE';confidence=0.91;pattern='\b(twitter|\bx\b|reddit|youtube|podcast|analyst|content creator|journalist|people are saying|everyone is saying|community thinks|consensus)\b|\b(member|manager|someone|friend|analyst|creator|journalist).{0,40}(says|said|thinks|believes|likes|fancies|reckons|expects)\b|\b(he|she|they).{0,25}(says|said|thinks|believes|likes|fancies|reckons|expects)\b'},
        [pscustomobject]@{category='STATISTICAL_EVIDENCE';group='EVIDENCE';confidence=0.96;pattern='\b(xg|xa|xgi|expected goals|expected assists|underlying stats|underlying numbers|statistics|statistical|data says|numbers say|shots in the box|big chances|touches in the box|chance creation)\b'},
        [pscustomobject]@{category='OWNERSHIP_EO';group='BEHAVIOR_SIGNAL';confidence=0.97;pattern='\b(ownership|effective ownership|\beo\b|everyone owns|highly owned|template|scared not to own|afraid not to own|cover ownership|ownership fear)\b'},
        [pscustomobject]@{category='DIFFERENTIAL_PREFERENCE';group='BEHAVIOR_SIGNAL';confidence=0.97;pattern='\b(differential|low owned|low-owned|punt|unique pick|against the template|go different|need upside|chasing upside)\b'},
        [pscustomobject]@{category='CAPTAINCY';group='DECISION_CONTEXT';confidence=0.99;pattern='\b(captain|captaincy|armband|vice captain|vice-captain|\(c\))\b'},
        [pscustomobject]@{category='TRANSFER_IN_CONSIDERATION';group='DECISION_CONTEXT';confidence=0.94;pattern='\b(bring in|buy|transfer in|bring him in|bring her in|get him in|get her in|move to|swap .* for)\b'},
        [pscustomobject]@{category='TRANSFER_OUT_CONSIDERATION';group='DECISION_CONTEXT';confidence=0.95;pattern='\b(sell|transfer out|get rid of|move on from|take out|ship out|ditch)\b'},
        [pscustomobject]@{category='HOLD_ROLL';group='DECISION_CONTEXT';confidence=0.96;pattern='\b(hold|keep him|keep her|roll transfer|roll the transfer|save transfer|save the transfer|bank the transfer|do nothing)\b'},
        [pscustomobject]@{category='BENCH_LINEUP';group='DECISION_CONTEXT';confidence=0.98;pattern='\b(bench|benching|start him|start her|starting xi|lineup|line-up|first sub|second sub|third sub)\b'},
        [pscustomobject]@{category='MINUTES_ROTATION';group='PREDICTION';confidence=0.95;pattern='\b(minutes|rotation|rotated|benched|start probability|starts? this week|will start|might start|may start|rested|subbed early)\b'},
        [pscustomobject]@{category='PERFORMANCE_PREDICTION';group='PREDICTION';confidence=0.92;pattern='\b(outscore|outscores|outscoring|haul|hauls|return this week|returns this week|score more|better pick than|better than .* this week|blank|will score|will assist|will return)\b'},
        [pscustomobject]@{category='PRICE_SIGNAL';group='EVIDENCE';confidence=0.97;pattern='\b(price rise|price fall|price drop|rising tonight|falling tonight|price change|team value|lose value|gain value)\b'},
        [pscustomobject]@{category='AVAILABILITY';group='EVIDENCE';confidence=0.97;pattern='\b(injury|injured|fitness|fit to play|doubt|flagged|illness|suspended|suspension|press conference|presser)\b'},
        [pscustomobject]@{category='FIXTURE_MATCHUP';group='EVIDENCE';confidence=0.95;pattern='\b(fixture|fixtures|opponent|matchup|match-up|home game|away game|defence|defense|attack matchup)\b'},
        [pscustomobject]@{category='RIVAL_CONTEXT';group='BEHAVIOR_SIGNAL';confidence=0.96;pattern='\b(rival|mini league|mini-league|league rival|chasing me|catching me|ahead of me|behind me)\b'},
        [pscustomobject]@{category='MODEL_CHALLENGE';group='BEHAVIOR_SIGNAL';confidence=0.98;pattern='\b(challenge it|challenge this|prove me wrong|disagree with me|test my view|test this|argue against|devil\x27s advocate)\b'},
        [pscustomobject]@{category='TEAM_SENTIMENT';group='BEHAVIOR_SIGNAL';confidence=0.88;pattern='\b(i support|my club|i hate|i dislike|don\x27t trust .* players|do not trust .* players|never own .* players|won\x27t own .* players)\b'},
        [pscustomobject]@{category='CHIP_DECISION';group='DECISION_CONTEXT';confidence=0.99;pattern='\b(wildcard|free hit|bench boost|triple captain|assistant manager|chip)\b'},
        [pscustomobject]@{category='LOSS_AVERSION_LANGUAGE';group='BEHAVIOR_SIGNAL';confidence=0.90;pattern='\b(scared to|afraid to|can\x27t risk|cannot risk|protect rank|don\x27t want to lose|do not want to lose)\b'},
        [pscustomobject]@{category='RECENCY_SIGNAL';group='BEHAVIOR_SIGNAL';confidence=0.86;pattern='\b(after that blank|after that haul|last game changed my mind|because he blanked|because he hauled|just scored|just blanked)\b'}
    )
    $signals=@()
    foreach($rule in $rules){
        $ruleMatches=[regex]::Matches($lower,[string]$rule.pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if($ruleMatches.Count -gt 0){
            $terms=@();foreach($m in $ruleMatches){if(-not [string]::IsNullOrWhiteSpace([string]$m.Value)){$terms += [string]$m.Value}}
            $signals += [pscustomobject][ordered]@{category=$rule.category;group=$rule.group;inference_confidence=$rule.confidence;matched_terms=@($terms | Select-Object -Unique)}
        }
    }

    # Preserve subjective probability only when the user actually states a number.
    $explicitConfidence=$null
    $cm=[regex]::Match($lower,'(?<!\d)(\d{1,3})\s*(?:%|percent)\b')
    if($cm.Success){
        try{$explicitConfidence=[math]::Max(0,[math]::Min(100,[int]$cm.Groups[1].Value))}catch{$explicitConfidence=$null}
    }

    $players=@();$teams=@()
    foreach($p in @(Get-ResearchPlayerLookup $Root)){
        $web=([string]$p.web_name).Trim();$full=([string]$p.full_name).Trim()
        $hit=$false
        if($web.Length -ge 3 -and [regex]::IsMatch($raw,'(?i)(?<![A-Za-z])'+[regex]::Escape($web)+'(?![A-Za-z])')){$hit=$true}
        elseif($full.Length -ge 5 -and [regex]::IsMatch($raw,'(?i)(?<![A-Za-z])'+[regex]::Escape($full)+'(?![A-Za-z])')){$hit=$true}
        if($hit){$players += [pscustomobject][ordered]@{id=$p.id;name=$web;team=$p.team};if($p.team){$teams += $p.team}}
        if($players.Count -ge 12){break}
    }

    # Extract directional player intent only when wording is explicit enough.
    # This lets Official FPL reconciliation distinguish e.g. 'Mbeumo over Haaland
    # for captain' without guessing intent from mere co-mentions.
    $preferredPlayer=$null;$transferInTarget=$null;$transferOutTarget=$null
    foreach($p in @($players)){
        $nm=[regex]::Escape([string]$p.name)
        if(-not $preferredPlayer -and [regex]::IsMatch($raw,'(?i)(?:captain\s+)?'+$nm+'\s+(?:over|rather than|instead of|ahead of)\s+')){$preferredPlayer=$p}
        if(-not $preferredPlayer -and [regex]::IsMatch($raw,'(?i)\bcaptain(?:cy)?\s+(?:on\s+)?'+$nm+'\b')){$preferredPlayer=$p}
        if(-not $transferInTarget -and [regex]::IsMatch($raw,'(?i)\b(?:bring in|buy|get|transfer in)\s+'+$nm+'\b')){$transferInTarget=$p}
        if(-not $transferOutTarget -and [regex]::IsMatch($raw,'(?i)\b(?:sell|ditch|ship out|transfer out|get rid of|move on from)\s+'+$nm+'\b')){$transferOutTarget=$p}
    }
    if(-not $preferredPlayer -and $players.Count -eq 1 -and @($signals.category) -contains 'CAPTAINCY'){$preferredPlayer=$players[0]}
    if(-not $transferInTarget -and $players.Count -eq 1 -and @($signals.category) -contains 'TRANSFER_IN_CONSIDERATION'){$transferInTarget=$players[0]}
    if(-not $transferOutTarget -and $players.Count -eq 1 -and @($signals.category) -contains 'TRANSFER_OUT_CONSIDERATION'){$transferOutTarget=$players[0]}

    # V3.1.0: separate self-expression from observations about rivals/other managers.
    # Identity Lab only treats SELF scope as direct evidence about the participant.
    # Raw text is always preserved, and ambiguous/general statements stay GENERAL.
    $subjectScope='GENERAL'
    $selfMarkers=[regex]::IsMatch($lower,'(?i)\b(i|i\x27m|i am|i think|i believe|i prefer|i want|i would|i\x27d|my|me|mine|for me)\b')
    $otherMarkers=[regex]::IsMatch($lower,'(?i)\b(rival|rivals|manager|managers|they|their|them|he|she|people in (?:this|my|the) league|other players|other managers)\b')
    if($selfMarkers){$subjectScope='SELF'}elseif($otherMarkers){$subjectScope='OTHER_MANAGER'}

    $externalOpinionReference=([regex]::IsMatch($lower,'(?i)\b(member|manager|someone|friend|analyst|creator|journalist|he|she|they|people).{0,60}(says|said|thinks|believes|likes|fancies|reckons|expects|opinion|view)\b') -or (@($signals.category) -contains 'SOCIAL_EXTERNAL_OPINION'))
    $teamSnapshot=Get-ResearchCurrentTeamSnapshot $Root
    return [pscustomobject][ordered]@{
        classifier_version='HYBRID_V3_2_0'
        raw_text=$raw
        subject_scope=$subjectScope
        explicit_confidence_percent=$explicitConfidence
        signals=@($signals)
        categories=@($signals.category | Select-Object -Unique)
        mentioned_players=@($players)
        mentioned_teams=@($teams | Select-Object -Unique)
        preferred_player=$preferredPlayer
        transfer_in_target=$transferInTarget
        transfer_out_target=$transferOutTarget
        external_opinion_reference=$externalOpinionReference
        team_state_at_recording=$teamSnapshot
    }
}

function Record-NaturalLanguageResearchSignals([string]$Root,[string]$Text,[string]$DecisionId,[string]$AnalysisMode='DEEP') {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    Initialize-ResearchStore $Root | Out-Null
    $classification=Get-NaturalLanguageResearchClassification $Root $Text
    $capture=Append-ResearchEvent $Root 'USER_STATEMENT_CAPTURED' ([ordered]@{
        raw_text=$classification.raw_text;analysis_mode=$AnalysisMode;classifier_version=$classification.classifier_version;subject_scope=$classification.subject_scope
    }) 0 $DecisionId 'P001'
    Append-ResearchEvent $Root 'USER_INPUT_CLASSIFIED' ([ordered]@{
        raw_text=$classification.raw_text
        classifier_version=$classification.classifier_version
        subject_scope=$classification.subject_scope
        explicit_confidence_percent=$classification.explicit_confidence_percent
        signals=@($classification.signals)
        categories=@($classification.categories)
        mentioned_players=@($classification.mentioned_players)
        mentioned_teams=@($classification.mentioned_teams)
        preferred_player=$classification.preferred_player
        transfer_in_target=$classification.transfer_in_target
        transfer_out_target=$classification.transfer_out_target
        external_opinion_reference=$classification.external_opinion_reference
        team_state_at_recording=$classification.team_state_at_recording
        research_guardrail='Signals are observations, not diagnoses of bias or skill.'
    }) 0 $DecisionId 'P001' | Out-Null

    if($classification.external_opinion_reference){
        Append-ResearchEvent $Root 'EXTERNAL_OPINION_MENTIONED' ([ordered]@{
            raw_text=$classification.raw_text;mentioned_players=@($classification.mentioned_players);mentioned_teams=@($classification.mentioned_teams)
            source_type='NATURAL_LANGUAGE_REFERENCE';claim_status='EXTERNAL_NOT_PARTICIPANT_BELIEF';classifier_version=$classification.classifier_version
            research_guardrail='An external opinion mentioned by the participant is evidence provenance, not the participant own hunch.'
        }) 0 $DecisionId 'EXTERNAL_SOURCE' | Out-Null
    }
    foreach($sig in @($classification.signals)){
        if(([string]$sig.group) -eq 'BEHAVIOR_SIGNAL'){
            Append-ResearchEvent $Root 'BEHAVIORAL_SIGNAL_DETECTED' ([ordered]@{
                signal=[string]$sig.category;raw_text=$classification.raw_text;subject_scope=$classification.subject_scope;inference_confidence=$sig.inference_confidence;matched_terms=@($sig.matched_terms);classifier_version=$classification.classifier_version
            }) 0 $DecisionId 'P001' | Out-Null
        }
    }

    if(@($classification.categories) -contains 'HUNCH'){
        $hunchId=[guid]::NewGuid().ToString('N')
        Append-ResearchEvent $Root 'HUNCH_RECORDED' ([ordered]@{
            hunch_id=$hunchId
            claim=$classification.raw_text
            subject_scope=$classification.subject_scope
            confidence_percent=$classification.explicit_confidence_percent
            category='NATURAL_LANGUAGE_DEEP_DIVE'
            categories=@($classification.categories)
            mentioned_players=@($classification.mentioned_players)
            preferred_player=$classification.preferred_player
            transfer_in_target=$classification.transfer_in_target
            transfer_out_target=$classification.transfer_out_target
            external_opinion_reference=$classification.external_opinion_reference
        team_state_at_recording=$classification.team_state_at_recording
            origin='DEEP_DIVE_AUTO_CAPTURE'
            classifier_version=$classification.classifier_version
        }) 0 $DecisionId $hunchId | Out-Null
    }
    if(@($classification.signals | Where-Object {$_.group -eq 'PREDICTION'}).Count -gt 0){
        Append-ResearchEvent $Root 'PREDICTION_RECORDED' ([ordered]@{
            raw_text=$classification.raw_text;subject_scope=$classification.subject_scope;confidence_percent=$classification.explicit_confidence_percent;categories=@($classification.categories);mentioned_players=@($classification.mentioned_players);origin='DEEP_DIVE_AUTO_CAPTURE'
        }) 0 $DecisionId 'P001' | Out-Null
    }
    return $capture
}

function Get-ResearchActionSummary([string]$Root,$BeforeTeam,$AfterTeam) {
    $lookup=@{};foreach($p in @(Get-ResearchPlayerLookup $Root)){$lookup[[int]$p.id]=$p}
    function Name-For([int]$Id){if($lookup.ContainsKey($Id)){return [string]$lookup[$Id].web_name};return [string]$Id}
    $beforeIds=@($BeforeTeam.picks | ForEach-Object {[int]$_.element})
    $afterIds=@($AfterTeam.picks | ForEach-Object {[int]$_.element})
    $added=@($afterIds | Where-Object {$beforeIds -notcontains $_})
    $removed=@($beforeIds | Where-Object {$afterIds -notcontains $_})
    $beforeCap=$BeforeTeam.picks | Where-Object {$_.is_captain -eq $true} | Select-Object -First 1
    $afterCap=$AfterTeam.picks | Where-Object {$_.is_captain -eq $true} | Select-Object -First 1
    $beforeVice=$BeforeTeam.picks | Where-Object {$_.is_vice_captain -eq $true} | Select-Object -First 1
    $afterVice=$AfterTeam.picks | Where-Object {$_.is_vice_captain -eq $true} | Select-Object -First 1
    return [pscustomobject][ordered]@{
        added_ids=@($added);added=@($added | ForEach-Object {Name-For $_})
        removed_ids=@($removed);removed=@($removed | ForEach-Object {Name-For $_})
        captain_before=if($beforeCap){Name-For ([int]$beforeCap.element)}else{$null}
        captain_after=if($afterCap){Name-For ([int]$afterCap.element)}else{$null}
        captain_changed=([int]$beforeCap.element -ne [int]$afterCap.element)
        vice_before=if($beforeVice){Name-For ([int]$beforeVice.element)}else{$null}
        vice_after=if($afterVice){Name-For ([int]$afterVice.element)}else{$null}
        vice_changed=([int]$beforeVice.element -ne [int]$afterVice.element)
        lineup_changed=$true
    }
}

function Reconcile-ResearchHunchesWithOfficialTeam([string]$Root,$CurrentTeam,[int]$Gameweek=0,[bool]$TeamChanged=$false,$BeforeTeam=$null) {
    if(-not $CurrentTeam -or -not $CurrentTeam.picks -or @($CurrentTeam.picks).Count -lt 15){return}
    if($Gameweek -le 0){try{$Gameweek=Get-EngineGameweek $Root}catch{$Gameweek=0}}
    $researchRoot=Get-ResearchRoot $Root
    $events=Read-ResearchJsonLines (Join-Path $researchRoot 'events.jsonl') 1200
    $hunches=@($events | Where-Object {$_.event_type -eq 'HUNCH_RECORDED' -and [int]$_.gameweek -eq $Gameweek})
    if($hunches.Count -eq 0){return}
    $statusEvents=@($events | Where-Object {$_.event_type -eq 'HUNCH_ACTION_RECONCILED'})
    $lookup=@{};foreach($p in @(Get-ResearchPlayerLookup $Root)){$lookup[[int]$p.id]=$p}
    $currentIds=@($CurrentTeam.picks | ForEach-Object {[int]$_.element})
    $cap=$CurrentTeam.picks | Where-Object {$_.is_captain -eq $true} | Select-Object -First 1
    $capId=if($cap){[int]$cap.element}else{0}
    $latestLocked=0;try{$latestLocked=Get-LatestLockedGameweek $Root}catch{}
    $isFinal=($latestLocked -ge $Gameweek)

    foreach($h in $hunches){
        $hp=$h.payload;$hunchId=[string]$hp.hunch_id;if([string]::IsNullOrWhiteSpace($hunchId)){$hunchId=[string]$h.subject_id}
        $cats=@($hp.categories | ForEach-Object {[string]$_})
        $mentioned=@($hp.mentioned_players)
        $state='OPEN_NO_OBSERVABLE_ACTION_YET';$reason='No unambiguous Official FPL action matching this hunch is visible yet.'
        $baseline=$hp.team_state_at_recording
        $baselineSig=if($baseline){[string]$baseline.signature}else{''}
        $curSig=@($CurrentTeam.picks | Sort-Object position | ForEach-Object {('{0}|{1}|{2}|{3}' -f [int]$_.element,[int]$_.position,[bool]$_.is_captain,[bool]$_.is_vice_captain)}) -join ';'
        $changedSinceRecording=(-not [string]::IsNullOrWhiteSpace($baselineSig) -and $baselineSig -ne $curSig)
        $target=$null;$targetContext=''
        if(($cats -contains 'CAPTAINCY') -and $hp.preferred_player){$target=$hp.preferred_player;$targetContext='CAPTAINCY'}
        elseif(($cats -contains 'TRANSFER_IN_CONSIDERATION') -and $hp.transfer_in_target){$target=$hp.transfer_in_target;$targetContext='TRANSFER_IN'}
        elseif(($cats -contains 'TRANSFER_OUT_CONSIDERATION') -and $hp.transfer_out_target){$target=$hp.transfer_out_target;$targetContext='TRANSFER_OUT'}
        elseif($mentioned.Count -eq 1){$target=$mentioned[0];if($cats -contains 'CAPTAINCY'){$targetContext='CAPTAINCY'}elseif($cats -contains 'TRANSFER_IN_CONSIDERATION'){$targetContext='TRANSFER_IN'}elseif($cats -contains 'TRANSFER_OUT_CONSIDERATION'){$targetContext='TRANSFER_OUT'}}
        if($target){
            $playerId=0;try{$playerId=[int]$target.id}catch{}
            $pname=[string]$target.name
            if($targetContext -eq 'CAPTAINCY'){
                $baseCap=0;try{$baseCap=[int]$baseline.captain_id}catch{}
                if($capId -eq $playerId -and $baseCap -ne $playerId){$state='ACTED_ON';$reason="$pname is now the Official FPL captain and was not captain when the hunch was recorded."}
                elseif($capId -eq $playerId -and $baseCap -eq $playerId){$state='ALREADY_TRUE_AT_RECORDING';$reason="$pname was already captain when this hunch was recorded and remains captain."}
                elseif($isFinal){$state='FINAL_NOT_ACTED_ON';$reason="$pname was the explicit captaincy preference but is not the locked captain."}
            }elseif($targetContext -eq 'TRANSFER_IN'){
                $wasOwned=$false;try{$wasOwned=@($baseline.player_ids) -contains $playerId}catch{}
                if((-not $wasOwned) -and ($currentIds -contains $playerId)){$state='ACTED_ON';$reason="$pname was not owned at recording and is now in the Official FPL squad."}
                elseif($isFinal -and -not ($currentIds -contains $playerId)){$state='FINAL_NOT_ACTED_ON';$reason="$pname was the explicit transfer-in target but is not in the locked squad."}
            }elseif($targetContext -eq 'TRANSFER_OUT'){
                $wasOwned=$false;try{$wasOwned=@($baseline.player_ids) -contains $playerId}catch{}
                if($wasOwned -and -not ($currentIds -contains $playerId)){$state='ACTED_ON';$reason="$pname was owned at recording and has been removed from the Official FPL squad."}
                elseif($isFinal -and ($currentIds -contains $playerId)){$state='FINAL_NOT_ACTED_ON';$reason="$pname was the explicit sale target but remains in the locked squad."}
            }
        }elseif(($cats -contains 'HOLD_ROLL') -and -not $changedSinceRecording){
            $state=if($isFinal){'ACTED_ON'}else{'CURRENTLY_ALIGNED'};$reason='The Official FPL team state still matches the state captured when the hold/roll view was recorded.'
        }
        if($state -eq 'OPEN_NO_OBSERVABLE_ACTION_YET' -and $isFinal){$state='FINAL_UNRESOLVED_OR_NOT_ACTED';$reason='The deadline is locked, but the language was not specific enough to infer a clean action relationship.'}

        $prev=@($statusEvents | Where-Object {[string]$_.payload.hunch_id -eq $hunchId} | Sort-Object observed_at -Descending | Select-Object -First 1)
        if($prev.Count -gt 0 -and [string]$prev[0].payload.status -eq $state -and [bool]$prev[0].payload.final -eq $isFinal){continue}
        Append-ResearchEvent $Root 'HUNCH_ACTION_RECONCILED' ([ordered]@{
            hunch_id=$hunchId;hunch_event_id=[string]$h.event_id;status=$state;final=$isFinal;reason=$reason;team_changed_on_this_sync=$TeamChanged;official_captain_id=$capId;official_player_ids=@($currentIds)
        }) $Gameweek ([string]$h.decision_id) $hunchId | Out-Null
    }
}

function Get-ResearchMaturity([int]$EvidenceCount,[int]$Opportunities,[int]$ClosedGameweeks) {
    $status='EMERGING'
    if($ClosedGameweeks -ge 10 -and $EvidenceCount -ge 20){$status='STABLE'}
    elseif($ClosedGameweeks -ge 5 -and $EvidenceCount -ge 10){$status='SUPPORTED'}
    elseif($ClosedGameweeks -ge 2 -and $EvidenceCount -ge 4){$status='TENTATIVE'}
    $coverage=0
    if($Opportunities -gt 0){$coverage=[math]::Min(100,[math]::Round(($EvidenceCount/[double]$Opportunities)*100))}
    $confidence=0
    if($EvidenceCount -gt 0){$confidence=[math]::Min(95,[math]::Round(12 + ([math]::Min(1,$EvidenceCount/20.0)*48) + ([math]::Min(1,$ClosedGameweeks/10.0)*35)))}
    return [pscustomobject][ordered]@{status=$status;confidence_percent=$confidence;coverage_percent=$coverage;evidence_count=$EvidenceCount;opportunities=$Opportunities}
}

function Get-IdentityModelForEvents([object[]]$Events,[int]$ClosedGameweeks=0,[string]$Scope='ALL') {
    $classified=@($Events | Where-Object {$_.event_type -eq 'USER_INPUT_CLASSIFIED'})
    if($Scope -eq 'SELF'){
        # Pre-3.1.0 records have no subject_scope. Treat them as SELF only when the
        # raw wording contains first-person markers; otherwise leave them out of
        # direct participant-identity inference but keep them in the evidence ledger.
        $classified=@($classified | Where-Object {
            $scope='';try{$scope=[string]$_.payload.subject_scope}catch{}
            if($scope -eq 'SELF'){return $true}
            if($scope -and $scope -ne 'SELF'){return $false}
            $raw='';try{$raw=[string]$_.payload.raw_text}catch{}
            return [regex]::IsMatch($raw,'(?i)\b(i|i\x27m|i am|i think|i believe|i prefer|i want|i would|i\x27d|my|me|mine|for me)\b')
        })
    }
    $statementCount=$classified.Count
    function Count-WithAny([object[]]$Rows,[string[]]$Names){
        $count=0
        foreach($row in @($Rows)){
            $cats=@();try{$cats=@($row.payload.categories)}catch{}
            foreach($name in @($Names)){if($cats -contains $name){$count++;break}}
        }
        return $count
    }
    function Make-Trait([string]$Key,[string]$Label,[int]$Numerator,[int]$Denominator,[string]$Basis,[string]$Meaning,[int]$GwCount){
        $score=$null
        if($Denominator -gt 0){$score=[math]::Round(($Numerator/[double]$Denominator)*100)}
        $maturity=Get-ResearchMaturity $Numerator $Denominator $GwCount
        return [pscustomobject][ordered]@{key=$Key;label=$Label;score=$score;evidence_count=$Numerator;opportunities=$Denominator;maturity=$maturity.status;confidence_percent=$maturity.confidence_percent;basis=$Basis;meaning=$Meaning}
    }

    $evidenceCats=@('EYE_TEST','TACTICAL_OBSERVATION','SOCIAL_EXTERNAL_OPINION','STATISTICAL_EVIDENCE','PRICE_SIGNAL','AVAILABILITY','FIXTURE_MATCHUP')
    $decisionCats=@('CAPTAINCY','TRANSFER_IN_CONSIDERATION','TRANSFER_OUT_CONSIDERATION','HOLD_ROLL','BENCH_LINEUP','CHIP_DECISION')
    $evidenceStatements=Count-WithAny $classified $evidenceCats
    $decisionStatements=Count-WithAny $classified $decisionCats
    $transferStatements=Count-WithAny $classified @('TRANSFER_IN_CONSIDERATION','TRANSFER_OUT_CONSIDERATION','HOLD_ROLL')
    $traits=@(
        (Make-Trait 'EVIDENCE_ORIENTATION' 'Evidence orientation' (Count-WithAny $classified $evidenceCats) $statementCount 'Share of your self-scoped Deep Dive statements containing explicit evidence language.' 'How often you explicitly ground a view in evidence; not a measure of whether the evidence was correct.' $ClosedGameweeks),
        (Make-Trait 'STATISTICAL_ORIENTATION' 'Statistical orientation' (Count-WithAny $classified @('STATISTICAL_EVIDENCE')) $evidenceStatements 'Share of evidence-bearing statements that explicitly reference statistical/underlying data.' 'Observed use of statistical evidence relative to other explicit evidence.' $ClosedGameweeks),
        (Make-Trait 'FOOTBALL_OBSERVATION' 'Football observation' (Count-WithAny $classified @('EYE_TEST','TACTICAL_OBSERVATION')) $evidenceStatements 'Share of evidence-bearing statements using eye-test or tactical observations.' 'Observed football-viewing/tactical input; value is evaluated separately from frequency.' $ClosedGameweeks),
        (Make-Trait 'INTUITION_EXPRESSION' 'Intuition expression' (Count-WithAny $classified @('HUNCH','USER_OPINION')) $statementCount 'Share of self-scoped statements containing explicit hunch/opinion language.' 'How often intuition is expressed, not hunch skill.' $ClosedGameweeks),
        (Make-Trait 'DIFFERENTIAL_APPETITE' 'Differential appetite' (Count-WithAny $classified @('DIFFERENTIAL_PREFERENCE')) $decisionStatements 'Share of decision-context statements explicitly mentioning differential/anti-template intent.' 'Observed appetite for differentiation when discussing decisions.' $ClosedGameweeks),
        (Make-Trait 'OWNERSHIP_SENSITIVITY' 'Ownership sensitivity' (Count-WithAny $classified @('OWNERSHIP_EO')) $decisionStatements 'Share of decision-context statements explicitly mentioning ownership or EO.' 'Observed awareness/sensitivity to ownership; not automatically herding.' $ClosedGameweeks),
        (Make-Trait 'TRANSFER_PATIENCE' 'Transfer patience' (Count-WithAny $classified @('HOLD_ROLL')) $transferStatements 'Hold/roll language as a share of transfer-decision statements.' 'Observed willingness to keep/roll within explicit transfer discussions.' $ClosedGameweeks),
        (Make-Trait 'MODEL_CHALLENGE' 'Model challenge' (Count-WithAny $classified @('MODEL_CHALLENGE')) $statementCount 'Share of self-scoped statements explicitly asking the model to challenge a view.' 'Observed tendency to seek adversarial analysis rather than simple confirmation.' $ClosedGameweeks),
        (Make-Trait 'RIVAL_AWARENESS' 'Rival awareness' (Count-WithAny $classified @('RIVAL_CONTEXT')) $decisionStatements 'Share of decision-context statements explicitly referencing rivals/mini-leagues.' 'Observed competitive-context attention.' $ClosedGameweeks),
        (Make-Trait 'LOSS_AVERSION_LANGUAGE' 'Loss-aversion language' (Count-WithAny $classified @('LOSS_AVERSION_LANGUAGE')) $decisionStatements 'Share of decision-context statements using explicit fear/protection language.' 'Descriptive language signal only; this is not a diagnosis of loss aversion.' $ClosedGameweeks),
        (Make-Trait 'RECENCY_LANGUAGE' 'Recency language' (Count-WithAny $classified @('RECENCY_SIGNAL')) $statementCount 'Share of self-scoped statements explicitly tying a decision to the most recent result.' 'Descriptive recency signal only; outcome dependence is tested separately.' $ClosedGameweeks),
        (Make-Trait 'CLUB_SENTIMENT_SIGNAL' 'Club sentiment signal' (Count-WithAny $classified @('TEAM_SENTIMENT')) $statementCount 'Share of self-scoped statements containing explicit club-affinity/avoidance language.' 'Descriptive allegiance signal only; it does not imply selection bias.' $ClosedGameweeks)
    )

    $componentDefs=@(
        [pscustomobject]@{key='EVIDENCE_LED';label='Evidence-led';count=$evidenceStatements},
        [pscustomobject]@{key='INTUITION_EXPRESSIVE';label='Intuition expressive';count=(Count-WithAny $classified @('HUNCH','USER_OPINION'))},
        [pscustomobject]@{key='DIFFERENTIAL_SEEKING';label='Differential seeking';count=(Count-WithAny $classified @('DIFFERENTIAL_PREFERENCE'))},
        [pscustomobject]@{key='OWNERSHIP_AWARE';label='Ownership aware';count=(Count-WithAny $classified @('OWNERSHIP_EO'))},
        [pscustomobject]@{key='RIVAL_AWARE';label='Rival aware';count=(Count-WithAny $classified @('RIVAL_CONTEXT'))},
        [pscustomobject]@{key='MODEL_CHALLENGING';label='Model challenging';count=(Count-WithAny $classified @('MODEL_CHALLENGE'))}
    )
    $componentTotal=0;foreach($c in $componentDefs){$componentTotal += [int]$c.count}
    $components=@();foreach($c in $componentDefs){$share=0;if($componentTotal -gt 0){$share=[math]::Round(([int]$c.count/[double]$componentTotal)*100)};$components += [pscustomobject][ordered]@{key=$c.key;label=$c.label;count=[int]$c.count;share_percent=$share}}
    $top=@($components | Sort-Object count -Descending | Where-Object {$_.count -gt 0} | Select-Object -First 2)
    $identityLabel='Identity forming'
    if($top.Count -eq 1){$identityLabel=[string]$top[0].label}
    elseif($top.Count -ge 2){$identityLabel=([string]$top[0].label+' · '+[string]$top[1].label)}
    $overallMaturity=Get-ResearchMaturity $statementCount $statementCount $ClosedGameweeks
    return [pscustomobject][ordered]@{
        model_version='IDENTITY_V0_1'
        scope=$Scope
        statement_count=$statementCount
        closed_gameweeks=$ClosedGameweeks
        label=$identityLabel
        maturity=$overallMaturity.status
        confidence_percent=$overallMaturity.confidence_percent
        traits=@($traits)
        components=@($components | Sort-Object count -Descending)
        guardrail='Trait indexes describe observed language/decision signals. They are not skill, bias or causal-effect scores.'
    }
}

function Get-IdentityEvolution([object[]]$Events,[int]$ClosedGameweeks=0) {
    $gws=@($Events | Where-Object {$_.event_type -eq 'USER_INPUT_CLASSIFIED'} | ForEach-Object {try{[int]$_.gameweek}catch{0}} | Where-Object {$_ -gt 0} | Sort-Object -Unique)
    $rows=@()
    foreach($gw in $gws){
        $subset=@($Events | Where-Object {try{[int]$_.gameweek -eq $gw}catch{$false}})
        $m=Get-IdentityModelForEvents $subset $ClosedGameweeks 'SELF'
        $traitMap=[ordered]@{};foreach($t in @($m.traits)){$traitMap[[string]$t.key]=$t.score}
        $rows += [pscustomobject][ordered]@{gameweek=$gw;statement_count=$m.statement_count;label=$m.label;traits=[pscustomobject]$traitMap}
    }
    return @($rows)
}

function Get-ContextualLeagueIdentities([object[]]$Events,[int]$ClosedGameweeks=0) {
    $decisionLeague=@{}
    foreach($e in @($Events | Where-Object {$_.event_type -eq 'DEEP_DIVE_STARTED'})){
        $did=[string]$e.decision_id;if([string]::IsNullOrWhiteSpace($did)){continue}
        $lid=0;try{$lid=[int]$e.payload.league_id}catch{}
        if($lid -gt 0){$decisionLeague[$did]=$lid}
    }
    $leagueIds=@($decisionLeague.Values | Sort-Object -Unique)
    $out=@()
    foreach($lid in $leagueIds){
        $ids=@($decisionLeague.Keys | Where-Object {[int]$decisionLeague[$_] -eq [int]$lid})
        $subset=@($Events | Where-Object {$ids -contains [string]$_.decision_id})
        $m=Get-IdentityModelForEvents $subset $ClosedGameweeks 'SELF'
        $out += [pscustomobject][ordered]@{league_id=[int]$lid;decision_count=$ids.Count;statement_count=$m.statement_count;identity=$m}
    }
    return @($out | Sort-Object statement_count -Descending)
}

function Record-IdentityModelSnapshot([string]$Root,[int]$Gameweek=0) {
    Initialize-ResearchStore $Root | Out-Null
    $events=Read-ResearchJsonLines (Join-Path (Get-ResearchRoot $Root) 'events.jsonl')
    $closed=@($events | Where-Object {$_.event_type -eq 'GAMEWEEK_CLOSED'} | ForEach-Object {try{[int]$_.gameweek}catch{0}} | Where-Object {$_ -gt 0} | Sort-Object -Unique)
    $model=Get-IdentityModelForEvents $events $closed.Count 'SELF'
    $payload=[ordered]@{identity_model_version=$model.model_version;label=$model.label;maturity=$model.maturity;confidence_percent=$model.confidence_percent;statement_count=$model.statement_count;traits=@($model.traits);components=@($model.components);guardrail=$model.guardrail}
    return Append-ResearchEvent $Root 'IDENTITY_MODEL_SNAPSHOT' $payload $Gameweek $null 'P001'
}

function Get-ResearchAnalytics([string]$Root,[object[]]$Events) {
    $signalCounts=@{};$gwMap=@{};$hunchLatest=@{};$decisionMap=@{}
    foreach($e in @($Events)){
        $gw=0;try{$gw=[int]$e.gameweek}catch{}
        if(-not $gwMap.ContainsKey($gw)){$gwMap[$gw]=[ordered]@{gameweek=$gw;events=0;statements=0;hunches=0;model_calls=0;official_changes=0;reconciled=0}}
        $gwMap[$gw].events++
        $et=[string]$e.event_type
        if($et -eq 'USER_STATEMENT_CAPTURED'){$gwMap[$gw].statements++}
        if($et -eq 'HUNCH_RECORDED'){$gwMap[$gw].hunches++}
        if($et -eq 'MODEL_RECOMMENDATION_CREATED'){$gwMap[$gw].model_calls++}
        if($et -eq 'OFFICIAL_TEAM_CHANGED'){$gwMap[$gw].official_changes++}
        if($et -eq 'HUNCH_ACTION_RECONCILED'){$gwMap[$gw].reconciled++}

        if($et -eq 'USER_INPUT_CLASSIFIED'){
            foreach($sig in @($e.payload.signals)){
                $k=[string]$sig.category;if([string]::IsNullOrWhiteSpace($k)){continue}
                if(-not $signalCounts.ContainsKey($k)){$signalCounts[$k]=0};$signalCounts[$k]++
            }
        }
        if($et -eq 'HUNCH_ACTION_RECONCILED'){
            $hid=[string]$e.payload.hunch_id
            if(-not [string]::IsNullOrWhiteSpace($hid)){$hunchLatest[$hid]=$e}
        }
        $did=[string]$e.decision_id
        if(-not [string]::IsNullOrWhiteSpace($did)){
            if(-not $decisionMap.ContainsKey($did)){$decisionMap[$did]=[ordered]@{decision_id=$did;gameweek=$gw;started_at=$null;question=$null;signals=@();subject_scope=$null;model=$null;hunch_status=@();last_at=$e.observed_at}}
            $d=$decisionMap[$did];$d.last_at=$e.observed_at
            if($et -eq 'DEEP_DIVE_STARTED'){$d.started_at=$e.observed_at;$d.question=[string]$e.payload.question}
            if($et -eq 'USER_INPUT_CLASSIFIED'){$d.signals=@($e.payload.categories);try{$d.subject_scope=[string]$e.payload.subject_scope}catch{}}
            if($et -eq 'MODEL_RECOMMENDATION_CREATED'){$d.model=[ordered]@{transfers=@($e.payload.transfers);captain=[string]$e.payload.captain;vice=[string]$e.payload.vice;chip=[string]$e.payload.chip;confidence=$e.payload.confidence;summary=[string]$e.payload.summary}}
            if($et -eq 'HUNCH_ACTION_RECONCILED'){$d.hunch_status += [ordered]@{status=[string]$e.payload.status;final=[bool]$e.payload.final;reason=[string]$e.payload.reason}}
        }
    }
    $signals=@();foreach($k in @($signalCounts.Keys | Sort-Object)){$signals += [pscustomobject][ordered]@{signal=$k;count=[int]$signalCounts[$k]}}
    $gwActivity=@();foreach($k in @($gwMap.Keys | Sort-Object)){$gwActivity += [pscustomobject]$gwMap[$k]}
    $hstatus=@{};foreach($hid in $hunchLatest.Keys){$st=[string]$hunchLatest[$hid].payload.status;if(-not $hstatus.ContainsKey($st)){$hstatus[$st]=0};$hstatus[$st]++}
    $hstatRows=@();foreach($k in @($hstatus.Keys | Sort-Object)){$hstatRows += [pscustomobject][ordered]@{status=$k;count=[int]$hstatus[$k]}}
    $decisions=@($decisionMap.Values | Sort-Object last_at -Descending | Select-Object -First 40)
    $closed=@($Events | Where-Object {$_.event_type -eq 'GAMEWEEK_CLOSED'} | ForEach-Object {try{[int]$_.gameweek}catch{0}} | Where-Object {$_ -gt 0} | Sort-Object -Unique)
    $identity=Get-IdentityModelForEvents $Events $closed.Count 'SELF'
    $evolution=@(Get-IdentityEvolution $Events $closed.Count)
    $contexts=@(Get-ContextualLeagueIdentities $Events $closed.Count)
    $snapshots=@($Events | Where-Object {$_.event_type -eq 'IDENTITY_MODEL_SNAPSHOT'} | Sort-Object observed_at | ForEach-Object {[pscustomobject][ordered]@{gameweek=$_.gameweek;observed_at=$_.observed_at;model_version=$_.payload.identity_model_version;label=$_.payload.label;maturity=$_.payload.maturity;confidence_percent=$_.payload.confidence_percent;statement_count=$_.payload.statement_count;traits=@($_.payload.traits)}})
    $ecologySnapshots=@($Events | Where-Object {$_.event_type -eq 'RIVAL_ECOLOGY_SNAPSHOT'} | Sort-Object observed_at | ForEach-Object {[pscustomobject][ordered]@{gameweek=$_.gameweek;observed_at=$_.observed_at;league_count=@($_.payload.leagues).Count;manager_count=@($_.payload.manager_genome).Count;leagues=@($_.payload.leagues);manager_genome=@($_.payload.manager_genome)}})
    $screenshotClassifications=@($Events | Where-Object {$_.event_type -eq 'SCREENSHOT_CLASSIFIED'} | Sort-Object observed_at -Descending | Select-Object -First 40)
    $interactions=@($Events | Where-Object {$_.event_type -eq 'INTERACTION_OBSERVED'} | Sort-Object observed_at -Descending | Select-Object -First 40)
    $resolved=@($Events | Where-Object {$_.event_type -match 'PREDICTION_RESOLVED|OUTCOME_RESOLVED'}).Count
    $modelCalls=@($Events | Where-Object {$_.event_type -eq 'MODEL_RECOMMENDATION_CREATED'}).Count
    $optimalStatus=if($closed.Count -ge 5 -and $modelCalls -ge 20 -and $resolved -ge 15){'ELIGIBLE_FOR_FIT'}else{'COLLECTING_EVIDENCE'}
    $optimalNote=if($optimalStatus -eq 'ELIGIBLE_FOR_FIT'){'Evidence threshold reached for a first outcome-aware optimal-identity fit. Do not publish coefficients until the outcome-quality model is validated.'}else{"Optimal Identity remains intentionally unfitted: $($closed.Count)/5 closed GWs, $modelCalls/20 model calls, $resolved/15 resolved outcomes."}
    return [ordered]@{
        signal_counts=@($signals | Sort-Object count -Descending)
        gameweek_activity=$gwActivity
        hunch_status_counts=$hstatRows
        recent_decisions=$decisions
        identity=$identity
        identity_evolution=$evolution
        contextual_league_identities=$contexts
        identity_model_snapshots=$snapshots
        rival_ecology_snapshots=$ecologySnapshots
        recent_screenshot_classifications=@($screenshotClassifications | ForEach-Object {[pscustomobject][ordered]@{observed_at=$_.observed_at;file_name=$_.payload.file_name;screenshot_type=$_.payload.screenshot_type;claim_type=$_.payload.claim_type;source_class=$_.payload.source_class;source_identity=$_.payload.source_identity;claim_summary=$_.payload.claim_summary;evidence_tags=@($_.payload.evidence_tags);entities=@($_.payload.entities);confidence_percent=$_.payload.confidence_percent}})
        recent_interactions=@($interactions | ForEach-Object {[pscustomobject][ordered]@{observed_at=$_.observed_at;interaction_type=$_.payload.interaction_type;page=$_.payload.page;target=$_.payload.target;value=$_.payload.value;context=$_.payload.context}})
        optimal_identity=[ordered]@{status=$optimalStatus;closed_gameweeks=$closed.Count;model_calls=$modelCalls;resolved_outcomes=$resolved;note=$optimalNote;guardrail='Optimal Identity is never inferred from rank alone or a handful of lucky outcomes.'}
        readiness=[ordered]@{closed_gameweeks=$closed.Count;target_gameweeks=5;progress_percent=[math]::Min(100,[math]::Round(($closed.Count/5.0)*100));stage=if($closed.Count -ge 5){'ANALYTICS_READY'}else{'COLLECTING_EVIDENCE'};note=if($closed.Count -ge 5){'Five completed Gameweeks are available. Advanced analysis may now be meaningful with sample-size warnings.'}else{"Collecting longitudinal evidence: $($closed.Count)/5 completed Gameweeks. Signals below are descriptive, not bias diagnoses."}}
    }
}

function Get-ResearchSummary([string]$Root) {
    Initialize-ResearchStore $Root | Out-Null
    $researchRoot=Get-ResearchRoot $Root
    $events=Read-ResearchJsonLines (Join-Path $researchRoot 'events.jsonl') 3000
    $profile=Read-JsonSafe (Join-Path $researchRoot 'participant_profile.json')
    $counts=@{}
    foreach($event in $events){
        $k=([string]$event.event_type).ToUpperInvariant()
        if(-not $counts.ContainsKey($k)){$counts[$k]=0}
        $counts[$k]++
    }
    function C([string]$Key){if($counts.ContainsKey($Key)){return [int]$counts[$Key]};return 0}
    $analytics=Get-ResearchAnalytics $Root $events
    return [ordered]@{
        storage='LOCAL_APPEND_ONLY_JSONL'
        participant_id='P001'
        profile=$profile
        profile_revision=if($profile){$profile.revision}else{0}
        auto_capture=[ordered]@{enabled=$true;classifier_version='HYBRID_V3_2_0';note='Deep Dive language is captured automatically before model advice and screenshots are classified asynchronously as typed evidence. Original wording/files are preserved alongside normalized research signals.'}
        counts=[ordered]@{
            total_events=$events.Count
            profile_changes=(C 'PROFILE_FIELD_CHANGED')
            statements=(C 'USER_STATEMENT_CAPTURED')
            classified_inputs=(C 'USER_INPUT_CLASSIFIED')
            behavioral_signals=(C 'BEHAVIORAL_SIGNAL_DETECTED')
            pre_analysis_beliefs=(C 'PRE_ANALYSIS_BELIEF_RECORDED')
            hunches=(C 'HUNCH_RECORDED')
            evidence_items=(C 'EVIDENCE_ADDED')
            screenshots_classified=(C 'SCREENSHOT_CLASSIFIED')
            external_opinions_mentioned=(C 'EXTERNAL_OPINION_MENTIONED')
            interactions=(C 'INTERACTION_OBSERVED')
            model_recommendations=(C 'MODEL_RECOMMENDATION_CREATED')
            official_team_changes=(C 'OFFICIAL_TEAM_CHANGED')
            hunch_reconciliations=(C 'HUNCH_ACTION_RECONCILED')
            gameweeks_closed=(C 'GAMEWEEK_CLOSED')
            identity_generations=(C 'IDENTITY_MODEL_SNAPSHOT')
            rival_ecology_snapshots=(C 'RIVAL_ECOLOGY_SNAPSHOT')
        }
        analytics=$analytics
        preliminary_note='Automatic capture is active. V4.1.2 preserves explainable Identity Lab indexes, evolution and contextual league identities while preserving descriptive signals, timelines and action reconciliation; it does not label a bias or skill from a tiny sample.'
        recent_events=@($events | Select-Object -Last 60 | Sort-Object observed_at -Descending)
    }
}

function Export-ResearchData([string]$Root) {
    Initialize-ResearchStore $Root | Out-Null
    $researchRoot=Get-ResearchRoot $Root
    $events=Read-ResearchJsonLines (Join-Path $researchRoot 'events.jsonl')
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage=Join-Path $env:TEMP ('FPLResearchExport-'+[guid]::NewGuid().ToString('N'))
    $folder=Join-Path $stage 'RESEARCH_EXPORT_2026_27'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    function Csv-Safe($Value){if($null -eq $Value){return ''};if($Value -is [string]){return $Value};try{return ($Value|ConvertTo-Json -Depth 30 -Compress)}catch{return [string]$Value}}
    function Export-EventRows([object[]]$Rows,[string]$Path){
        $flat=@($Rows | ForEach-Object {
            [pscustomobject]@{
                event_id=$_.event_id;observed_at=$_.observed_at;gameweek=$_.gameweek;effective_gameweek=$_.effective_gameweek;deadline_time=$_.deadline_time;deadline_relation=$_.deadline_relation;temporal_attribution=$_.temporal_attribution;temporal_basis=$_.temporal_basis;participant_id=$_.participant_id;decision_id=$_.decision_id;subject_id=$_.subject_id;model_version=$_.model_version;event_type=$_.event_type;payload_json=(Csv-Safe $_.payload)
            }
        })
        if($flat.Count -gt 0){$flat | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8}
        else{'event_id,observed_at,gameweek,effective_gameweek,deadline_time,deadline_relation,temporal_attribution,temporal_basis,participant_id,decision_id,subject_id,model_version,event_type,payload_json' | Set-Content -LiteralPath $Path -Encoding UTF8}
    }

    Export-EventRows $events (Join-Path $folder 'events.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -in @('PRE_ANALYSIS_BELIEF_RECORDED','MODEL_RECOMMENDATION_CREATED','MODEL_RECOMMENDATION_REPAIRED','MODEL_RECOMMENDATION_BLOCKED','USER_FINAL_DECISION_RECORDED','USER_ACCEPTED_MODEL','USER_OVERRULED_MODEL','USER_CHANGED_MIND','OFFICIAL_TEAM_CHANGED','USER_STATEMENT_CAPTURED','USER_INPUT_CLASSIFIED','HUNCH_ACTION_RECONCILED')}) (Join-Path $folder 'decisions.csv')
    Export-EventRows @($events | Where-Object {$_.temporal_attribution -and $_.temporal_attribution -ne 'NOT_APPLICABLE'}) (Join-Path $folder 'temporal_attribution.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match '^PREDICTION_'}) (Join-Path $folder 'predictions.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match 'OUTCOME|RESOLVED$'}) (Join-Path $folder 'outcomes.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -in @('EVIDENCE_ADDED','EVIDENCE_LINKED_TO_DECISION','EVIDENCE_RESOLVED','SOURCE_RELIABILITY_UPDATED')}) (Join-Path $folder 'evidence.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match 'HUNCH'}) (Join-Path $folder 'hunches.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -in @('USER_INPUT_CLASSIFIED','BEHAVIORAL_SIGNAL_DETECTED')}) (Join-Path $folder 'behavioral_signals.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'HUNCH_ACTION_RECONCILED'}) (Join-Path $folder 'hunch_action_reconciliation.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match 'SCREENSHOT'}) (Join-Path $folder 'screenshots_index.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'PROFILE_FIELD_CHANGED'}) (Join-Path $folder 'profile_change_log.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'MODEL_VERSION_CHANGED'}) (Join-Path $folder 'model_versions.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'IDENTITY_MODEL_SNAPSHOT'}) (Join-Path $folder 'identity_model_snapshots.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'RIVAL_ECOLOGY_SNAPSHOT'}) (Join-Path $folder 'rival_ecology_snapshots.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -in @('USER_INPUT_CLASSIFIED','BEHAVIORAL_SIGNAL_DETECTED')}) (Join-Path $folder 'behavior_signals.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match 'DATA_QUALITY|RECOMMENDATION_BLOCKED'}) (Join-Path $folder 'data_quality.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -in @('EVIDENCE_ADDED','EVIDENCE_RESOLVED')}) (Join-Path $folder 'evidence_claims.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -eq 'SOURCE_RELIABILITY_UPDATED'}) (Join-Path $folder 'source_reliability.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match '^EXPERIMENT_'}) (Join-Path $folder 'experiments.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match '^PLAYER_OBSERVATION_'}) (Join-Path $folder 'player_observations.csv')
    Export-EventRows @($events | Where-Object {$_.event_type -match '^RIVAL_OBSERVATION_'}) (Join-Path $folder 'rival_observations.csv')

    $miProcessed=Join-Path $Root '02_DATA\MANAGER_INTELLIGENCE\PROCESSED'
    foreach($miName in @('manager_population_integrity.csv','manager_transfer_events.csv','population_skew_summary.json')){
        $miSrc=Join-Path $miProcessed $miName
        if(Test-Path $miSrc){Copy-Item -LiteralPath $miSrc -Destination (Join-Path $folder $miName) -Force}
    }

    $profile=Read-JsonSafe (Join-Path $researchRoot 'participant_profile.json')
    if($profile){
        $row=[ordered]@{}
        foreach($p in $profile.PSObject.Properties){$row[$p.Name]=Csv-Safe $p.Value}
        @([pscustomobject]$row) | Export-Csv -LiteralPath (Join-Path $folder 'participant_profile.csv') -NoTypeInformation -Encoding UTF8
    }else{'participant_id,revision,updated_at' | Set-Content -LiteralPath (Join-Path $folder 'participant_profile.csv') -Encoding UTF8}

    $summary=Get-ResearchSummary $Root
    $snapshot=[ordered]@{exported_at=(Get-Date).ToString('o');schema_version=5;summary=$summary;events=@($events)}
    Write-JsonUtf8 $snapshot (Join-Path $folder 'research_snapshot.json') 100

    # Portable, dependency-free interactive dashboard. This is a convenience
    # view over the same raw snapshot; events.csv remains the canonical ledger.
    $dashJson=($snapshot | ConvertTo-Json -Depth 100 -Compress)
    $dashJson=$dashJson.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026')
    $dashHtml=@'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FPL Research Observatory Export</title><style>
:root{--bg:#07111c;--panel:#0b1725;--card:#0f1e2f;--line:#263b55;--text:#eff6ff;--muted:#91a6c0;--a:#5cc8ff;--b:#7f8cff;--good:#6cdda0;--warn:#f0c65c;--bad:#f18d8d}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 14% 0,#17334f 0,#091421 32%,#060d16 70%);color:var(--text);font:14px/1.45 Inter,Segoe UI,Arial,sans-serif}.wrap{max-width:1380px;margin:0 auto;padding:22px}.hero,.panel{border:1px solid var(--line);border-radius:16px;background:linear-gradient(180deg,rgba(16,31,48,.96),rgba(8,19,31,.98))}.hero{padding:18px;background:linear-gradient(135deg,#153652,#172442 65%,#111a2b)}h1,h2,h3{margin:0}.hero h1{font-size:26px;letter-spacing:-.025em}.muted{color:var(--muted)}.small{font-size:11px}.chips,.nav{display:flex;gap:6px;flex-wrap:wrap}.chip{border:1px solid var(--line);border-radius:99px;padding:4px 8px;font-size:10px;font-weight:800;background:#122239}.nav{margin:12px 0;padding:5px;border:1px solid var(--line);border-radius:12px;background:#091522}.nav button{border:0;border-radius:8px;padding:8px 11px;background:transparent;color:var(--muted);font-weight:850;cursor:pointer}.nav button.active{background:#172b43;color:var(--text)}.view{display:none}.view.active{display:block}.grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:10px}.s12{grid-column:span 12}.s8{grid-column:span 8}.s7{grid-column:span 7}.s6{grid-column:span 6}.s5{grid-column:span 5}.s4{grid-column:span 4}.panel{padding:14px}.metrics{display:grid;grid-template-columns:repeat(6,minmax(105px,1fr));gap:8px;margin-top:14px}.metric{border:1px solid var(--line);border-radius:11px;padding:10px;background:#0a1725}.metric .k{font-size:9px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}.metric .v{font-size:22px;font-weight:950;margin-top:3px}.progress{height:8px;background:#08131f;border:1px solid var(--line);border-radius:99px;overflow:hidden;margin-top:10px}.progress>div,.track>div{height:100%;background:linear-gradient(90deg,var(--a),var(--b));border-radius:99px}.barrow{display:grid;grid-template-columns:minmax(150px,1fr) 3fr 42px;gap:8px;align-items:center;margin:8px 0}.track{height:8px;border-radius:99px;background:#17283c;overflow:hidden}.identityTop{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap}.identityName{font-size:23px;font-weight:950;letter-spacing:-.025em}.traitGrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.trait{border:1px solid var(--line);border-radius:11px;background:#0a1725;padding:10px;cursor:pointer;color:var(--text);text-align:left}.trait.active{border-color:#6a92bd;background:#102238}.traitHead{display:flex;justify-content:space-between;gap:8px}.traitScore{font-size:18px;font-weight:950}.maturity{font-size:9px;font-weight:900;letter-spacing:.06em}.radar{width:min(100%,450px);height:auto;display:block;margin:auto}.rgrid{fill:none;stroke:#2a3d54;stroke-width:1}.raxis{stroke:#334961;stroke-width:1}.rshape{fill:rgba(92,200,255,.14);stroke:#6bd0f7;stroke-width:2}.rdot{fill:#d6f3ff}.rlabel{fill:#a9bbcf;font-size:9px;font-weight:700}.evo{width:100%;height:auto;display:block}.egrid{stroke:#26384e;stroke-width:1}.eline{fill:none;stroke:#69c8f2;stroke-width:3}.edot{fill:#e1f5ff;stroke:#69c8f2;stroke-width:2}.event{border-left:3px solid #567fae;border-radius:8px;background:#0a1725;padding:9px 10px;margin:7px 0}.event button{all:unset;cursor:pointer;display:block;width:100%}.list{max-height:520px;overflow:auto}.detail{white-space:pre-wrap;word-break:break-word;background:#08131f;border:1px solid var(--line);border-radius:10px;padding:11px;min-height:200px}.callout{border:1px solid #355979;border-radius:12px;background:linear-gradient(135deg,#0b2335,#111d31);padding:12px}.gate{border:1px dashed #6f613e;border-radius:12px;background:#131a22;padding:12px}.generation{border-left:3px solid #667fa8;background:#0a1725;border-radius:9px;padding:10px;margin:8px 0}select{background:#08131f;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:7px}.empty{color:var(--muted);padding:18px;text-align:center;border:1px dashed #344b66;border-radius:10px}.footer{margin-top:14px;color:var(--muted);font-size:10px;text-align:center}@media(max-width:900px){.s8,.s7,.s6,.s5,.s4{grid-column:span 12}.metrics{grid-template-columns:repeat(2,1fr)}.traitGrid{grid-template-columns:1fr}.barrow{grid-template-columns:120px 2fr 34px}}@media(max-width:600px){.wrap{padding:11px}.metrics{grid-template-columns:1fr 1fr}}
</style></head><body><div class="wrap"><section class="hero"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h1>Research Observatory</h1><div class="muted">Portable V3.1 identity export · evidence first, conclusions later</div></div><div class="chips"><span class="chip">P001</span><span class="chip" id="identityVersion">IDENTITY</span><span class="chip" id="stage">collecting</span></div></div><div class="metrics" id="metrics"></div><div class="progress"><div id="progress"></div></div><div class="small muted" id="readiness" style="margin-top:6px"></div></section><nav class="nav" aria-label="Research views"><button class="active" data-view="overview">Overview</button><button data-view="identity">Identity Lab</button><button data-view="evolution">Model Evolution</button><button data-view="data">Event Explorer</button></nav>
<section class="view active" data-panel="overview"><div class="grid"><div class="panel s7"><div style="display:flex;justify-content:space-between;gap:8px"><b>Behavior & decision signals</b><span class="chip">normalized language</span></div><div id="signals" style="margin-top:8px"></div></div><div class="panel s5"><b>Hunch → Official action</b><div id="hunch" style="margin-top:8px"></div></div><div class="panel s12"><div class="callout"><b>Research contract</b><div class="small muted" style="margin-top:5px">Observed behavior is not automatically skill or bias. Outcome luck is separated from pre-deadline decision quality. Small samples remain explicitly immature.</div></div></div></div></section>
<section class="view" data-panel="identity"><div class="grid"><div class="panel s12"><div class="identityTop"><div><div class="small muted">CURRENT DESCRIPTIVE IDENTITY</div><div class="identityName" id="identityName">Identity forming</div><div class="chips" style="margin-top:6px"><span class="chip" id="identityMaturity">EMERGING</span><span class="chip" id="identityConfidence">0% confidence</span><span class="chip" id="identityN">n=0</span></div></div><div class="small muted" id="identityGuard" style="max-width:520px"></div></div></div><div class="panel s5"><div id="radar"></div></div><div class="panel s7"><b>Live trait scales</b><div class="small muted">Click a scale to inspect its definition and evidence basis.</div><div class="traitGrid" id="traits" style="margin-top:9px"></div><div class="callout" id="traitExplain" style="margin-top:9px"></div></div><div class="panel s12"><div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap"><div><b>Identity evolution by Gameweek</b><div class="small muted">Per-GW observed indexes; not a skill trajectory.</div></div><select id="traitSelect"></select></div><div id="evolutionChart" style="margin-top:8px"></div></div></div></section>
<section class="view" data-panel="evolution"><div class="grid"><div class="panel s6"><div class="small muted">CURRENT YOU</div><div class="identityName" id="modelCurrent">Identity forming</div><div class="small muted" id="modelCurrentMeta" style="margin-top:5px"></div></div><div class="panel s6"><div class="small muted">OPTIMAL IDENTITY</div><div class="identityName" id="optimalState">Collecting evidence</div><div class="gate" id="optimalNote" style="margin-top:8px"></div></div><div class="panel s12"><b>Identity generations</b><div class="small muted">Immutable snapshots created when a Gameweek closes.</div><div id="generations" style="margin-top:8px"></div></div></div></section>
<section class="view" data-panel="data"><div class="grid"><div class="panel s12"><div style="display:flex;justify-content:space-between;gap:8px;align-items:center;flex-wrap:wrap"><div><b>Event Explorer</b><div class="small muted">Canonical append-only research ledger.</div></div><select id="gw"><option value="ALL">All GWs</option></select></div></div><div class="panel s5 list" id="events"></div><div class="panel s7"><div class="detail" id="detail">Select an event.</div></div></div></section><div class="footer">Generated by FPL Decision Engine V4.1.2 · research_snapshot.json and events.csv remain the portable source data.</div></div><script>
const DATA=__RESEARCH_JSON__,S=DATA.summary||{},A=S.analytics||{},C=S.counts||{},I=A.identity||{},O=A.optimal_identity||{};let selectedTrait='EVIDENCE_ORIENTATION';const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),fmt=s=>String(s||'').replaceAll('_',' ').toLowerCase().replace(/\b\w/g,m=>m.toUpperCase()),pct=v=>{v=Number(v);return Number.isFinite(v)?Math.max(0,Math.min(100,v)):0};
const metric=(k,v,n)=>`<div class="metric"><div class="k">${esc(k)}</div><div class="v">${esc(v??0)}</div><div class="small muted">${esc(n||'')}</div></div>`;document.getElementById('metrics').innerHTML=metric('Self statements',I.statement_count??0,'identity input')+metric('Hunches',C.hunches??0,'captured')+metric('Model calls',C.model_recommendations??0,'Deep Dive')+metric('Official changes',C.official_team_changes??0,'ground truth')+metric('Reconciliations',C.hunch_reconciliations??0,'hunch ↔ action')+metric('Closed GWs',C.gameweeks_closed??0,'generations');let R=A.readiness||{};document.getElementById('stage').textContent=fmt(R.stage||'collecting');document.getElementById('progress').style.width=pct(R.progress_percent)+'%';document.getElementById('readiness').textContent=R.note||'';document.getElementById('identityVersion').textContent=I.model_version||'IDENTITY_V0_1';
let sig=A.signal_counts||[],mx=Math.max(1,...sig.map(x=>Number(x.count||0)));document.getElementById('signals').innerHTML=sig.length?sig.slice(0,20).map(x=>`<div class="barrow"><div>${esc(fmt(x.signal))}</div><div class="track"><div style="width:${Math.max(4,Number(x.count||0)/mx*100)}%"></div></div><div class="muted">${esc(x.count)}</div></div>`).join(''):'<div class="empty">No normalized signals yet.</div>';let hs=A.hunch_status_counts||[];document.getElementById('hunch').innerHTML=hs.length?hs.map(x=>`<div class="event"><b>${esc(fmt(x.status))}</b><div class="small muted">${esc(x.count)} hunch(es)</div></div>`).join(''):'<div class="empty">No reconciliations yet.</div>';
function radar(items){if(!items.length)return '<div class="empty">Not enough identity evidence yet.</div>';let W=420,c=W/2,r=142,n=items.length,pt=(i,f)=>{let a=-Math.PI/2+i*2*Math.PI/n;return[c+Math.cos(a)*r*f,c+Math.sin(a)*r*f]},poly=f=>items.map((_,i)=>pt(i,f).join(',')).join(' '),shape=items.map((x,i)=>pt(i,pct(x.score)/100).join(',')).join(' ');return `<svg class="radar" viewBox="0 0 ${W} ${W}" role="img" aria-label="Identity radar">${[.25,.5,.75,1].map(f=>`<polygon class="rgrid" points="${poly(f)}"/>`).join('')}${items.map((x,i)=>{let [ax,ay]=pt(i,1),[lx,ly]=pt(i,1.18),anchor=lx<c-10?'end':lx>c+10?'start':'middle';return `<line class="raxis" x1="${c}" y1="${c}" x2="${ax}" y2="${ay}"/><text class="rlabel" x="${lx}" y="${ly}" text-anchor="${anchor}">${esc((x.label||x.key).replace(' orientation','').replace(' expression',''))}</text>`}).join('')}<polygon class="rshape" points="${shape}"/>${items.map((x,i)=>{let [dx,dy]=pt(i,pct(x.score)/100);return `<circle class="rdot" cx="${dx}" cy="${dy}" r="3"><title>${esc(x.label)}: ${x.score??'—'}</title></circle>`}).join('')}</svg>`}
function renderIdentity(){let traits=I.traits||[];document.getElementById('identityName').textContent=I.label||'Identity forming';document.getElementById('identityMaturity').textContent=I.maturity||'EMERGING';document.getElementById('identityConfidence').textContent=(I.confidence_percent??0)+'% confidence';document.getElementById('identityN').textContent='n='+(I.statement_count??0);document.getElementById('identityGuard').textContent=I.guardrail||'';document.getElementById('radar').innerHTML=radar(traits.slice(0,8));document.getElementById('traits').innerHTML=traits.length?traits.map(t=>`<button class="trait ${t.key===selectedTrait?'active':''}" data-trait="${esc(t.key)}"><div class="traitHead"><b>${esc(t.label)}</b><span class="traitScore">${t.score==null?'—':Math.round(t.score)}</span></div><div class="track" style="margin:7px 0"><div style="width:${pct(t.score)}%"></div></div><div class="small muted">n=${esc(t.evidence_count??0)}/${esc(t.opportunities??0)} · <span class="maturity">${esc(t.maturity||'EMERGING')}</span> · ${esc(t.confidence_percent??0)}%</div></button>`).join(''):'<div class="empty">Identity is still forming.</div>';document.querySelectorAll('[data-trait]').forEach(b=>b.addEventListener('click',()=>{selectedTrait=b.dataset.trait;renderIdentity()}));let t=traits.find(x=>x.key===selectedTrait)||traits[0];document.getElementById('traitExplain').innerHTML=t?`<b>${esc(t.label)}</b><div class="small muted" style="margin-top:4px">${esc(t.meaning||'')}</div><div class="small" style="margin-top:6px">Basis: ${esc(t.basis||'')}</div>`:'Select a trait.';let sel=document.getElementById('traitSelect');sel.innerHTML=traits.map(x=>`<option value="${esc(x.key)}">${esc(x.label)}</option>`).join('');if(t){selectedTrait=t.key;sel.value=t.key}sel.onchange=()=>{selectedTrait=sel.value;renderIdentity()};document.getElementById('evolutionChart').innerHTML=evolutionSvg(A.identity_evolution||[],selectedTrait,t?.label||selectedTrait)}
function evolutionSvg(rows,key,label){let pts=(rows||[]).map(r=>({gw:Number(r.gameweek),v:r.traits?.[key],n:Number(r.statement_count||0)})).filter(x=>x.v!=null&&Number.isFinite(Number(x.v)));if(!pts.length)return '<div class="empty">No Gameweek series for this trait yet.</div>';let W=1040,H=260,l=48,t=20,rr=20,b=38,x=i=>pts.length===1?W/2:l+i*(W-l-rr)/(pts.length-1),y=v=>t+(100-pct(v))*(H-t-b)/100,path=pts.map((p,i)=>(i?'L':'M')+x(i)+' '+y(p.v)).join(' ');return `<div class="small muted">${esc(label)} · per-GW observed index</div><svg class="evo" viewBox="0 0 ${W} ${H}">${[0,25,50,75,100].map(v=>`<line class="egrid" x1="${l}" y1="${y(v)}" x2="${W-rr}" y2="${y(v)}"/><text x="10" y="${y(v)+4}" fill="#7f94ad" font-size="10">${v}</text>`).join('')}<path class="eline" d="${path}"/>${pts.map((p,i)=>`<circle class="edot" cx="${x(i)}" cy="${y(p.v)}" r="5"><title>GW${p.gw}: ${Math.round(p.v)} · n=${p.n}</title></circle><text x="${x(i)}" y="${H-12}" fill="#91a3ba" font-size="10" text-anchor="middle">GW${p.gw}</text>`).join('')}</svg>`}
function renderModel(){document.getElementById('modelCurrent').textContent=I.label||'Identity forming';document.getElementById('modelCurrentMeta').textContent=`${I.maturity||'EMERGING'} · ${I.confidence_percent??0}% confidence · ${I.statement_count??0} self statements`;document.getElementById('optimalState').textContent=fmt(O.status||'COLLECTING_EVIDENCE');document.getElementById('optimalNote').innerHTML=`<div>${esc(O.note||'')}</div><div class="small muted" style="margin-top:6px">${esc(O.guardrail||'')}</div>`;let snaps=A.identity_model_snapshots||[];document.getElementById('generations').innerHTML=snaps.length?snaps.slice().reverse().map((x,i)=>`<div class="generation"><b>GW${esc(x.gameweek||'—')} · ${esc(x.label||'Identity')}</b><div class="small muted">${esc(x.model_version||'')} · ${esc(x.maturity||'')} · ${esc(x.confidence_percent??0)}% confidence · n=${esc(x.statement_count??0)}</div></div>`).join(''):'<div class="empty">The first immutable identity generation is created when a Gameweek closes.</div>'}
let events=DATA.events||[],gws=[...new Set(events.map(x=>Number(x.gameweek||0)).filter(x=>x>0))].sort((a,b)=>a-b),gw=document.getElementById('gw');gws.forEach(g=>{let o=document.createElement('option');o.value=String(g);o.textContent='GW'+g;gw.appendChild(o)});function drawEvents(){let f=gw.value==='ALL'?events:events.filter(x=>String(x.gameweek)===gw.value);f=f.slice().reverse().slice(0,160);document.getElementById('events').innerHTML=f.length?f.map((x,i)=>`<div class="event"><button data-i="${i}"><b>${esc(fmt(x.event_type))}</b><div class="small muted">GW${esc(x.gameweek||'—')} · ${esc(x.observed_at||'')}</div></button></div>`).join(''):'<div class="empty">No events.</div>';document.querySelectorAll('#events button').forEach((b,i)=>b.addEventListener('click',()=>document.getElementById('detail').textContent=JSON.stringify(f[i],null,2)))}gw.addEventListener('change',drawEvents);document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>{document.querySelectorAll('[data-view]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('[data-panel]').forEach(x=>x.classList.toggle('active',x.dataset.panel===b.dataset.view))}));renderIdentity();renderModel();drawEvents();
</script></body></html>
'@
    $dashHtml=$dashHtml.Replace('__RESEARCH_JSON__',$dashJson)
    Set-Content -LiteralPath (Join-Path $folder 'research_observatory.html') -Value $dashHtml -Encoding UTF8

    @"
FPL Decision Engine V3 Research Export

This package contains local research data in open CSV/JSON formats. The FPL Decision Engine Research Observatory is the primary interactive dashboard; these files are the portable raw research layer. V4.1.2 automatically captures natural-language Deep Dive statements and typed screenshot evidence, adds Official-FPL-deadline-aware temporal attribution, and exports population-integrity controls for manager research.

Use events.csv as the canonical append-only event table. Domain CSV files are filtered convenience views. Behavioral signals are descriptive observations, not automatic diagnoses of bias or skill.
"@ | Set-Content -LiteralPath (Join-Path $folder 'README.txt') -Encoding UTF8

    $outDir=Join-Path $researchRoot 'EXPORTS'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $zip=Join-Path $outDir ('FPL_RESEARCH_EXPORT_'+$stamp+'.zip')
    if(Test-Path $zip){Remove-Item -LiteralPath $zip -Force}
    Compress-Archive -Path $folder -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Append-ResearchEvent $Root 'RESEARCH_EXPORT_CREATED' ([ordered]@{path=$zip;file_name=[IO.Path]::GetFileName($zip)}) 0 $null 'P001' | Out-Null
    return $zip
}
