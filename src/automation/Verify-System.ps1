$Root=Split-Path -Parent $PSScriptRoot
$required=@('README.md','FPL_CONTROL_CENTER.bat','07_HANDOFF\CHATGPT_MASTER_INSTRUCTIONS.txt','03_MODELS\MODEL_SPEC.md','06_CONFIG\model_weights.json','06_CONFIG\project_state.json','06_CONFIG\fpl_connection.json','05_AUTOMATION\Start-ControlCenter.ps1','05_AUTOMATION\Research-Lib.ps1','05_AUTOMATION\Evidence-Classifier.ps1','05_AUTOMATION\Migrate-V3.ps1','05_AUTOMATION\Sync-FPLAccount.ps1','05_AUTOMATION\Resolve-CurrentTeam.ps1','05_AUTOMATION\Sync-PublicData.ps1','05_AUTOMATION\Sync-LiveFPL.ps1','05_AUTOMATION\Sync-ManagerIntelligence.ps1','06_CONFIG\manager_intelligence.json','03_MODELS\MANAGER_INTELLIGENCE_SPEC.md','05_AUTOMATION\Prepare-WeeklyPack.ps1','05_AUTOMATION\Close-Gameweek.ps1','04_OUTPUT\DASHBOARD\dashboard_state.json')
$ok=$true
foreach($r in $required){$p=Join-Path $Root $r;if(Test-Path $p){Write-Host "OK   $r" -ForegroundColor Green}else{Write-Host "MISS $r" -ForegroundColor Red;$ok=$false}}

$scriptSyntaxOk=$true
$scriptFiles=@(Get-ChildItem (Join-Path $Root '05_AUTOMATION') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
foreach($scriptFile in $scriptFiles){
    $tokens=$null
    $parseErrors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if($parseErrors -and $parseErrors.Count -gt 0){
        $firstError=$parseErrors | Select-Object -First 1
        Write-Host ("PARSE {0}:{1} {2}" -f $scriptFile.Name,$firstError.Extent.StartLineNumber,$firstError.Message) -ForegroundColor Red
        $scriptSyntaxOk=$false
        $ok=$false
    }
    $scriptText=[IO.File]::ReadAllText($scriptFile.FullName,[Text.Encoding]::UTF8)
    $ambiguousMatches=[regex]::Matches($scriptText,'\$([A-Za-z_][A-Za-z0-9_]*):')
    foreach($ambiguousMatch in $ambiguousMatches){
        $prefix=$ambiguousMatch.Groups[1].Value.ToLowerInvariant()
        if($prefix -notin @('env','script','global','local','private','using','variable','function','alias')){
            Write-Host ("LINT  {0}: ambiguous variable-colon reference" -f $scriptFile.Name) -ForegroundColor Red
            $scriptSyntaxOk=$false
            $ok=$false
        }
    }
    if($scriptFile.Name -in @('Run-Sync.ps1','Sync-LeagueIntelligence.ps1') -and [regex]::IsMatch($scriptText,'(?im)^\s*exit\b')){
        Write-Host ("LINT  {0}: top-level exit is unsafe because this script can be invoked by an orchestrator" -f $scriptFile.Name) -ForegroundColor Red
        $scriptSyntaxOk=$false
        $ok=$false
    }
}
if($scriptSyntaxOk){Write-Host 'OK   PowerShell syntax preflight' -ForegroundColor Green}

if(Test-Path (Join-Path $Root '06_CONFIG\_LOCAL_SECRETS\fpl_cookie.txt')){Write-Host 'INFO optional private FPL cookie is present locally; never upload it.' -ForegroundColor Yellow}
if($ok){Write-Host 'System structure and PowerShell syntax verified for V4.1.2.' -ForegroundColor Green;exit 0}else{Write-Host 'System has missing required files.' -ForegroundColor Red;exit 1}
