<#
.SYNOPSIS
    Assesses a Microsoft Sentinel workspace for Data Lake table optimization.

.DESCRIPTION
    Accepts a workspace name, discovers its subscription and resource group across the
    subscriptions available to the current Azure account, and collects the complete table
    inventory, enabled analytics rules, and workspace functions.

    The script resolves rule-to-table dependencies, queries recent ingestion, combines live
    Tables API eligibility with Microsoft Learn custom-table guidance, and writes a portable
    SWIFT-themed HTML report plus CSV and JSON evidence files directly to the current folder.
    The entry script includes embedded copies of its analyzer, report renderer, and SWIFT logo,
    so the PS1 can be copied and run by itself.

    The default run is non-destructive. Use -Apply to submit Auxiliary / Lake plan changes
    for eligible tables that aren't referenced by enabled analytics rules. PowerShell
    confirmation and WhatIf semantics apply.

.PARAMETER WorkspaceName
    Name of the Microsoft Sentinel Log Analytics workspace. This is the only required input.

.PARAMETER SubscriptionId
    Optional disambiguation when the same workspace name exists in multiple subscriptions.

.PARAMETER ResourceGroupName
    Optional disambiguation when the same workspace name exists in multiple resource groups.

.PARAMETER Apply
    Applies the generated migration plan. Without this switch, the script only assesses and
    writes evidence.

.EXAMPLE
    ./Invoke-SentinelDataLakeTierMigration.ps1 -WorkspaceName 'law-sentinel-prd'

.EXAMPLE
    ./Invoke-SentinelDataLakeTierMigration.ps1 `
        -WorkspaceName 'law-sentinel-prd' `
        -Apply `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceName,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [string]$ResourceGroupName,

    [ValidateRange(1, 365)]
    [int]$LookbackDays = 30,

    [switch]$SkipUsageQuery,

    [switch]$Apply,

    [switch]$AcknowledgeIncompleteAnalysis,

    [ValidateRange(0, 4383)]
    [int]$TotalRetentionInDays = 0,

    [scriptblock]$TierChangeAdapter,

    [switch]$OpenReport,

    [switch]$NoConsoleBanner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SentinelEmbeddedModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CompressedBase64
    )

    try {
        $compressedBytes = [Convert]::FromBase64String($CompressedBase64)
    }
    catch {
        throw "The embedded $Name payload is invalid. Copy a fresh version of this script. $($_.Exception.Message)"
    }

    $inputStream = [System.IO.MemoryStream]::new($compressedBytes, $false)
    $gzipStream = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = [System.IO.StreamReader]::new($gzipStream, [System.Text.Encoding]::UTF8)
    try {
        $moduleSource = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $gzipStream.Dispose()
        $inputStream.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($moduleSource)) {
        throw "The embedded $Name payload is empty. Copy a fresh version of this script."
    }
    return New-Module -Name $Name -ScriptBlock ([scriptblock]::Create($moduleSource))
}

# BEGIN EMBEDDED ANALYZER MODULE
$embeddedAnalyzerModulePayload = @'
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
'@
# END EMBEDDED ANALYZER MODULE

# BEGIN EMBEDDED REPORT MODULE
$embeddedReportModulePayload = @'
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
'@
# END EMBEDDED REPORT MODULE

# BEGIN EMBEDDED SWIFT LOGO
$embeddedSwiftLogoPayload = @'
PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA3NjYgMjYxIiByb2xlPSJpbWciIGFyaWEtbGFiZWxsZWRieT0i
dGl0bGUgZGVzY3JpcHRpb24iPg0KICA8dGl0bGUgaWQ9InRpdGxlIj5Td2lmdDwvdGl0bGU+DQogIDxkZXNjIGlkPSJkZXNjcmlwdGlvbiI+U3dpZnQgd29y
ZG1hcmsgYmVzaWRlIGEgZ2xvYmUuPC9kZXNjPg0KICA8cmVjdCB3aWR0aD0iNzY2IiBoZWlnaHQ9IjI2MSIgZmlsbD0iI2FjZjllOSIvPg0KICA8ZyBmaWxs
PSJub25lIiBzdHJva2U9IiMzMzNkM2UiIHN0cm9rZS13aWR0aD0iOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4N
CiAgICA8Y2lyY2xlIGN4PSIxMzEiIGN5PSIxMzAuNSIgcj0iMTI1Ii8+DQogICAgPHBhdGggZD0iTTI0IDY2LjVoMjE0TTYgMTMwLjVoMjUwTTI0IDE5NC41
aDIxNCIvPg0KICAgIDxwYXRoIGQ9Ik0xMzEgNS41djI1ME0xMzEgNS41QzkxIDIzIDY5IDcwIDY5IDEzMC41UzkxIDIzOCAxMzEgMjU1LjVNMTMxIDUuNWM0
MCAxNy41IDYyIDY0LjUgNjIgMTI1cy0yMiAxMDcuNS02MiAxMjUiLz4NCiAgPC9nPg0KICA8dGV4dCB4PSIzMDYiIHk9IjIxMSIgZmlsbD0iIzMzM2QzZSIg
Zm9udC1mYW1pbHk9IkFyaWFsLCBIZWx2ZXRpY2EsIHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjE4IiBmb250LXdlaWdodD0iNDAwIiB0ZXh0TGVuZ3RoPSI0
NTUiIGxlbmd0aEFkanVzdD0ic3BhY2luZ0FuZEdseXBocyI+U3dpZnQ8L3RleHQ+DQo8L3N2Zz4=
'@
# END EMBEDDED SWIFT LOGO

$analyzerModulePath = Join-Path $PSScriptRoot 'src\SentinelTableAnalyzer.psm1'
if (Test-Path -LiteralPath $analyzerModulePath -PathType Leaf) {
    Import-Module $analyzerModulePath -Force
}
else {
    Import-Module (New-SentinelEmbeddedModule -Name 'SentinelTableAnalyzer.Embedded' -CompressedBase64 $embeddedAnalyzerModulePayload) -Force
}

$reportModulePath = Join-Path $PSScriptRoot 'src\SentinelReport.psm1'
if (Test-Path -LiteralPath $reportModulePath -PathType Leaf) {
    Import-Module $reportModulePath -Force
}
else {
    Import-Module (New-SentinelEmbeddedModule -Name 'SentinelReport.Embedded' -CompressedBase64 $embeddedReportModulePayload) -Force
}
$reportLogoDataUri = "data:image/svg+xml;base64,$($embeddedSwiftLogoPayload -replace '\s', '')"

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-BooleanValue {
    param([AllowNull()][object]$Value)

    if ($Value -is [bool]) {
        return $Value
    }
    $parsed = $false
    if ([bool]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $false
}

function Write-JsonArtifact {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    ConvertTo-Json -InputObject $Value -Depth 100 |
        Set-Content -LiteralPath $Path -Encoding utf8 -WhatIf:$false
}

function Select-WorkspaceMatch {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Match
    )

    if ($Match.Count -eq 0) {
        return $null
    }
    if ($Match.Count -eq 1) {
        return $Match[0]
    }

    Write-Warning "Multiple accessible workspaces are named '$WorkspaceName'."
    for ($index = 0; $index -lt $Match.Count; $index++) {
        $item = $Match[$index]
        Write-Host "[$($index + 1)] $($item.SubscriptionId) / $($item.ResourceGroupName) / $($item.WorkspaceName)"
    }

    while ($true) {
        $selectionText = Read-Host -Prompt "Select workspace [1-$($Match.Count)]"
        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and
            $selection -ge 1 -and
            $selection -le $Match.Count) {
            return $Match[$selection - 1]
        }
        Write-Warning "Enter a number from 1 to $($Match.Count)."
    }
}

function Set-SentinelDataLakeTablePlan {
    param(
        [Parameter(Mandatory)]
        [object]$Request
    )

    $resourceId = "/subscriptions/$($Request.SubscriptionId)/resourceGroups/$($Request.ResourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($Request.WorkspaceName)"
    $path = "$resourceId/tables/$($Request.TableName)?api-version=2025-07-01"
    $body = @{
        properties = @{
            plan                 = 'Auxiliary'
            totalRetentionInDays = [int]$Request.TotalRetentionInDays
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-AzRestMethod -Method PATCH -Path $path -Payload $body
    $statusCode = [int](Get-PropertyValue -InputObject $response -Name 'StatusCode' -Default 0)
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        $responseContent = [string](Get-PropertyValue -InputObject $response -Name 'Content')
        throw "Table update failed with HTTP $statusCode`: $responseContent"
    }

    return [pscustomobject]@{
        Succeeded = $true
        Status    = if ($statusCode -eq 202) { 'Submitted' } else { 'Applied' }
        Message   = "HTTP $statusCode`: Auxiliary / Lake plan accepted with $($Request.TotalRetentionInDays) days total retention."
    }
}

if (-not $NoConsoleBanner) {
    Show-SentinelConsoleBanner -WorkspaceName $WorkspaceName -Title 'Sentinel Data Lake Optimization'
}

$requiredCommands = @(
    @{ Name = 'Connect-AzAccount'; Module = 'Az.Accounts' },
    @{ Name = 'Get-AzContext'; Module = 'Az.Accounts' },
    @{ Name = 'Get-AzSubscription'; Module = 'Az.Accounts' },
    @{ Name = 'Set-AzContext'; Module = 'Az.Accounts' },
    @{ Name = 'Invoke-AzRestMethod'; Module = 'Az.Accounts' },
    @{ Name = 'Get-AzOperationalInsightsWorkspace'; Module = 'Az.OperationalInsights' }
)
if (-not $SkipUsageQuery) {
    $requiredCommands += @{ Name = 'Invoke-AzOperationalInsightsQuery'; Module = 'Az.OperationalInsights' }
}
foreach ($requirement in $requiredCommands) {
    if (-not (Get-Command $requirement.Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$($requirement.Name)' is unavailable. Install-PSResource $($requirement.Module) -Scope CurrentUser"
    }
}

$context = Get-AzContext -ErrorAction SilentlyContinue
$activeAccount = Get-PropertyValue -InputObject $context -Name 'Account'
$activeTenant = Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $context -Name 'Tenant') -Name 'Id'
if ($null -eq $activeAccount -or
    (-not [string]::IsNullOrWhiteSpace($TenantId) -and [string]$activeTenant -ne $TenantId)) {
    $connectParameters = @{ ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParameters.Tenant = $TenantId
    }
    Write-Host 'Connecting to Azure...'
    Connect-AzAccount @connectParameters | Out-Null
}

Write-Host "Discovering workspace '$WorkspaceName' across accessible subscriptions..."
$discovery = Find-SentinelWorkspace `
    -WorkspaceName $WorkspaceName `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName

foreach ($failure in @($discovery.Failures)) {
    Write-Warning "Workspace lookup failed in subscription '$($failure.SubscriptionId)': $($failure.Message)"
}

$workspaceMatch = Select-WorkspaceMatch -Match @($discovery.Matches)
if ($null -eq $workspaceMatch) {
    $scopeDescription = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        'the subscriptions available to the current Azure account'
    }
    else {
        "subscription '$SubscriptionId'"
    }
    throw "Log Analytics workspace '$WorkspaceName' wasn't found in $scopeDescription."
}

$SubscriptionId = [string]$workspaceMatch.SubscriptionId
$ResourceGroupName = [string]$workspaceMatch.ResourceGroupName
$workspace = $workspaceMatch.Workspace
$workspaceId = Get-PropertyValue -InputObject $workspace -Name 'CustomerId'
if ($null -eq $workspaceId -or [string]::IsNullOrWhiteSpace([string]$workspaceId)) {
    throw "Workspace '$WorkspaceName' did not expose a CustomerId required for the usage query."
}

$contextParameters = @{
    SubscriptionId = $SubscriptionId
    Scope          = 'Process'
    ErrorAction    = 'Stop'
}
if (-not [string]::IsNullOrWhiteSpace([string]$workspaceMatch.TenantId)) {
    $contextParameters.Tenant = [string]$workspaceMatch.TenantId
}
Set-AzContext @contextParameters | Out-Null
Write-Host "Workspace: $SubscriptionId / $ResourceGroupName / $WorkspaceName"

$currentLocation = Get-Location
if ($currentLocation.Provider.Name -ne 'FileSystem') {
    throw 'Run the script from a filesystem location so evidence files can be written beside the invocation.'
}
$outputDirectory = [System.IO.Path]::GetFullPath($currentLocation.ProviderPath)
$safeWorkspaceName = [regex]::Replace($WorkspaceName, '[^A-Za-z0-9_.-]', '_')
$artifactStem = "SWIFT-Sentinel-$safeWorkspaceName"
$artifactPaths = [ordered]@{
    TablesRaw          = Join-Path $outputDirectory "$artifactStem-Tables.raw.json"
    EnabledRulesRaw    = Join-Path $outputDirectory "$artifactStem-EnabledAnalyticsRules.raw.json"
    AllRulesRaw        = Join-Path $outputDirectory "$artifactStem-AllAnalyticsRules.raw.json"
    FunctionsRaw       = Join-Path $outputDirectory "$artifactStem-WorkspaceFunctions.raw.json"
    TablesCsv          = Join-Path $outputDirectory "$artifactStem-Tables.csv"
    EnabledRulesCsv    = Join-Path $outputDirectory "$artifactStem-EnabledAnalyticsRules.csv"
    FunctionsCsv       = Join-Path $outputDirectory "$artifactStem-WorkspaceFunctions.csv"
    UsageCsv           = Join-Path $outputDirectory "$artifactStem-TableUsage.csv"
    ReferencesCsv      = Join-Path $outputDirectory "$artifactStem-RuleTableReferences.csv"
    AnalysisCsv        = Join-Path $outputDirectory "$artifactStem-TableTierAnalysis.csv"
    MigrationPlanCsv   = Join-Path $outputDirectory "$artifactStem-MigrationPlan.csv"
    SummaryJson        = Join-Path $outputDirectory "$artifactStem-ReportSummary.json"
    ReportHtml         = Join-Path $outputDirectory "$artifactStem-Assessment.html"
}
Write-Host "Output folder: $outputDirectory"

Write-Host 'Collecting tables, enabled analytics rules, and workspace functions...'
$inventory = Get-SentinelWorkspaceInventory `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceName $WorkspaceName

$tables = @($inventory.Tables | ConvertTo-SentinelTableRecord)
$enabledRules = @($inventory.EnabledRules | ConvertTo-SentinelRuleRecord)
$workspaceFunctions = @($inventory.WorkspaceFunctions | ConvertTo-SentinelFunctionRecord)

if ($tables.Count -eq 0) {
    throw "The Tables API returned no tables for workspace '$WorkspaceName'."
}
if ($tables.Count -ne @($inventory.Tables).Count) {
    throw "Table normalization count mismatch: collected $(@($inventory.Tables).Count), normalized $($tables.Count)."
}
if ($enabledRules.Count -ne @($inventory.EnabledRules).Count) {
    throw "Enabled-rule normalization count mismatch: collected $(@($inventory.EnabledRules).Count), normalized $($enabledRules.Count)."
}
$duplicateTables = @($tables | Group-Object TableName | Where-Object Count -gt 1)
if ($duplicateTables.Count -gt 0) {
    throw "The Tables API returned duplicate names: $(@($duplicateTables.Name) -join ', ')."
}

Write-Host "Coverage-checking all $($tables.Count) table names through the KQL resolver..."
$coverageMisses = [System.Collections.Generic.List[string]]::new()
foreach ($table in $tables) {
    $escapedName = $table.TableName.Replace("'", "''")
    $probe = Get-KqlReferenceSet -Query "['$escapedName'] | take 0" -TableName @($table.TableName)
    if (@($probe.Tables).Count -ne 1 -or $probe.Tables[0] -cne $table.TableName) {
        $coverageMisses.Add($table.TableName)
    }
}
if ($coverageMisses.Count -gt 0) {
    throw "The resolver coverage probe missed table name(s): $($coverageMisses -join ', ')."
}

$usageAvailable = $false
$usage = @()
if (-not $SkipUsageQuery) {
    try {
        Write-Host "Querying $LookbackDays-day table ingestion usage..."
        $usage = @(Get-SentinelTableUsage -WorkspaceId ([guid]$workspaceId) -LookbackDays $LookbackDays)
        $usageAvailable = $true
    }
    catch {
        Write-Warning "Usage query failed; the assessment will retain lake eligibility but won't prioritize recently ingesting tables. $($_.Exception.Message)"
    }
}

$analysis = New-SentinelTableAnalysis `
    -Table $tables `
    -EnabledRule $enabledRules `
    -WorkspaceFunction $workspaceFunctions `
    -Usage $usage `
    -LookbackDays $LookbackDays

$queryRuleCount = @($enabledRules | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.Query)
}).Count
if (@($analysis.RuleResolutions).Count -ne $queryRuleCount) {
    throw "Rule-resolution count mismatch: $queryRuleCount query rules, $(@($analysis.RuleResolutions).Count) resolution records."
}

$tableNameLookup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$tables | ForEach-Object { [void]$tableNameLookup.Add($_.TableName) }
$orphanReferences = @($analysis.References | Where-Object {
    -not $tableNameLookup.Contains([string]$_.TableName)
})
if ($orphanReferences.Count -gt 0) {
    throw "Dependency analysis produced references outside the workspace inventory: $(@($orphanReferences.TableName) -join ', ')."
}

$migrationPlan = [System.Collections.Generic.List[object]]::new()
foreach ($table in @($analysis.Tables)) {
    $targetRetention = if ($TotalRetentionInDays -gt 0) {
        $TotalRetentionInDays
    }
    else {
        [int](Get-PropertyValue -InputObject $table -Name 'TotalRetentionDays' -Default 0)
    }
    $status = 'NotCandidate'
    $message = [string]$table.Reason

    if ($table.UsedByAnalyticsRules) {
        $status = 'KeepInAnalytics'
    }
    elseif ($table.Plan -eq 'Auxiliary') {
        $status = 'AlreadyDataLake'
    }
    elseif (-not $table.IsMoveCandidate) {
        $status = 'Blocked'
    }
    elseif (-not $analysis.Quality.IsComplete -and -not $AcknowledgeIncompleteAnalysis) {
        $status = 'BlockedDependencyReview'
        $message = 'Dependency analysis is incomplete. Review the quality findings before using -AcknowledgeIncompleteAnalysis.'
    }
    elseif ($targetRetention -lt 4) {
        $status = 'Blocked'
        $message = 'Current total retention is missing or invalid; provide -TotalRetentionInDays.'
    }
    else {
        $status = 'Ready'
    }

    if ($Apply -and $status -eq 'Ready') {
        $target = "$WorkspaceName/$($table.TableName)"
        if ($PSCmdlet.ShouldProcess($target, "Move to Auxiliary / Lake with $targetRetention days total retention")) {
            $request = [pscustomobject]@{
                SubscriptionId       = $SubscriptionId
                ResourceGroupName    = $ResourceGroupName
                WorkspaceName        = $WorkspaceName
                TableName            = $table.TableName
                TotalRetentionInDays = $targetRetention
            }
            try {
                $adapterResult = if ($null -ne $TierChangeAdapter) {
                    & $TierChangeAdapter $request
                }
                else {
                    Set-SentinelDataLakeTablePlan -Request $request
                }
                $succeeded = $adapterResult -eq $true -or
                    (ConvertTo-BooleanValue (Get-PropertyValue -InputObject $adapterResult -Name 'Succeeded'))
                if (-not $succeeded) {
                    throw 'Tier-change adapter did not return a successful result.'
                }
                $status = [string](Get-PropertyValue -InputObject $adapterResult -Name 'Status' -Default 'Applied')
                $message = [string](Get-PropertyValue -InputObject $adapterResult -Name 'Message' -Default $message)
            }
            catch {
                $status = 'Failed'
                $message = $_.Exception.Message
            }
        }
        else {
            $status = if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
        }
    }

    $migrationPlan.Add([pscustomobject]@{
        TimestampUtc         = [datetime]::UtcNow.ToString('o')
        WorkspaceName        = $WorkspaceName
        TableName            = $table.TableName
        CurrentPlan          = $table.Plan
        Status               = $status
        TotalRetentionInDays = $targetRetention
        RuleCount            = $table.RuleCount
        DataLakeSupport      = $table.DataLakeSupport
        Message              = $message
    })
}

$generatedAt = Get-Date
$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
Write-Host "Writing assessment artifacts to $outputDirectory..."
Write-JsonArtifact -Value @($inventory.Tables) -Path $artifactPaths.TablesRaw
Write-JsonArtifact -Value @($inventory.EnabledRules) -Path $artifactPaths.EnabledRulesRaw
Write-JsonArtifact -Value @($inventory.AllAnalyticsRules) -Path $artifactPaths.AllRulesRaw
Write-JsonArtifact -Value @($inventory.WorkspaceFunctions) -Path $artifactPaths.FunctionsRaw

$tables | Export-Csv -LiteralPath $artifactPaths.TablesCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$enabledRules | Export-Csv -LiteralPath $artifactPaths.EnabledRulesCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$workspaceFunctions | Export-Csv -LiteralPath $artifactPaths.FunctionsCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$usage | Select-Object TableName,
    @{ Name = 'IngestedGB'; Expression = { ([double]$_.IngestedGB).ToString('0.####', $invariantCulture) } },
    @{ Name = 'BillableGB'; Expression = { ([double]$_.BillableGB).ToString('0.####', $invariantCulture) } },
    LastUsage |
    Export-Csv -LiteralPath $artifactPaths.UsageCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$analysis.References |
    Export-Csv -LiteralPath $artifactPaths.ReferencesCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$analysis.Tables | Select-Object TableName, DisplayName, Plan, TableType, TableSubType, Solutions,
    RetentionDays, TotalRetentionDays, ColumnCount, DataLakeSupport, DataLakeSupportSource,
    LiveIsLakeAllowed, IsLakeAllowed, IsDcrBasedCustomTable, RequiresSupportReview,
    MicrosoftLearnSupport, MicrosoftLearnUrl, UsedByAnalyticsRules, RuleCount, RuleNames,
    @{ Name = 'IngestedGB'; Expression = { ([double]$_.IngestedGB).ToString('0.####', $invariantCulture) } },
    @{ Name = 'BillableGB'; Expression = { ([double]$_.BillableGB).ToString('0.####', $invariantCulture) } },
    LastUsage, IsMoveCandidate, Recommendation, Reason |
    Export-Csv -LiteralPath $artifactPaths.AnalysisCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false
$migrationPlan |
    Export-Csv -LiteralPath $artifactPaths.MigrationPlanCsv -NoTypeInformation -Encoding utf8 -WhatIf:$false

[void](New-SentinelHtmlReport `
    -WorkspaceName $WorkspaceName `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -GeneratedAt $generatedAt `
    -LookbackDays $LookbackDays `
    -TableAnalysis @($analysis.Tables) `
    -EnabledRule $enabledRules `
    -RuleResolution @($analysis.RuleResolutions) `
    -Quality $analysis.Quality `
    -LogoDataUri $reportLogoDataUri `
    -OutputPath $artifactPaths.ReportHtml)

$summary = [pscustomobject]@{
    GeneratedAtUtc             = $generatedAt.ToUniversalTime().ToString('o')
    TenantId                   = [string]$workspaceMatch.TenantId
    SubscriptionId             = $SubscriptionId
    ResourceGroupName          = $ResourceGroupName
    WorkspaceName              = $WorkspaceName
    WorkspaceId                = [string]$workspaceId
    OutputDirectory            = $outputDirectory
    ReportPath                 = $artifactPaths.ReportHtml
    LookbackDays               = $LookbackDays
    UsageAvailable             = $usageAvailable
    TableCount                 = $tables.Count
    EnabledRuleCount           = $enabledRules.Count
    QueryRuleCount             = $analysis.Quality.QueryRuleCount
    NonQueryRuleCount          = $analysis.Quality.NonQueryRuleCount
    WorkspaceFunctionCount     = $workspaceFunctions.Count
    LakeSupportedCount         = @($analysis.Tables | Where-Object IsLakeAllowed -eq $true).Count
    LakeUnsupportedCount       = @($analysis.Tables | Where-Object IsLakeAllowed -eq $false).Count
    UsedByEnabledRulesCount    = @($analysis.Tables | Where-Object UsedByAnalyticsRules).Count
    MigrationCandidateCount    = @($analysis.Tables | Where-Object IsMoveCandidate).Count
    PriorityCandidateCount     = @($analysis.Tables | Where-Object Recommendation -eq 'Candidate for Data Lake').Count
    DependencyAnalysisComplete = $analysis.Quality.IsComplete
    QualityIssues              = @($analysis.Quality.Issues)
    SubmittedOrAppliedCount    = @($migrationPlan | Where-Object Status -in 'Submitted', 'Applied').Count
    FailedCount                = @($migrationPlan | Where-Object Status -eq 'Failed').Count
    Artifacts                  = $artifactPaths
}
Write-JsonArtifact -Value $summary -Path $artifactPaths.SummaryJson

Write-Host "Report: $($artifactPaths.ReportHtml)"
Write-Host "Tables: $($summary.TableCount); enabled rules: $($summary.EnabledRuleCount); tables used by rules: $($summary.UsedByEnabledRulesCount); migration candidates: $($summary.MigrationCandidateCount)."

if (-not $analysis.Quality.IsComplete) {
    Write-Warning "Dependency analysis requires manual review for $(@($analysis.Quality.Issues).Count) rule(s). See the HTML report and migration plan."
}
if ($summary.FailedCount -gt 0) {
    Write-Warning "$($summary.FailedCount) table update(s) failed. Review $($artifactPaths.MigrationPlanCsv)."
}
if ($OpenReport) {
    Invoke-Item -LiteralPath $artifactPaths.ReportHtml
}

return $summary
