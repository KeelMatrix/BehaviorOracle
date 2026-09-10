[CmdletBinding()]
param(
    [ValidateSet('Ci', 'Required')]
    [string]$Mode = 'Required',

    [string]$Solution = 'KeelMatrix.BehaviorOracle.sln',

    [string]$ReplayOutputPath,

    [int]$ReplayExitCode = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-AuditSummary {
    param([string]$Message)

    Write-Output $Message
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $Message | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}

function Get-UnavailableMatch {
    param([string]$Output)

    $patterns = @(
        '(?im)NU1900',
        '(?im)unable to load the service index',
        '(?im)failed to retrieve',
        '(?im)advisory',
        '(?im)vulnerability data.*unavailable',
        '(?im)network',
        '(?im)timed out',
        '(?im)connection',
        '(?im)SSL',
        '(?im)temporary failure',
        '(?im)name or service not known',
        '(?im)429'
    )

    foreach ($pattern in $patterns) {
        if ($Output -match $pattern) {
            return $pattern
        }
    }

    return $null
}

try {
    $auditOutput = $null
    $auditExitCode = 0
    if ([string]::IsNullOrWhiteSpace($ReplayOutputPath)) {
        $auditOutput = (& dotnet list $Solution package --vulnerable --include-transitive 2>&1 | Out-String).TrimEnd()
        $auditExitCode = $LASTEXITCODE
    }
    else {
        if (-not (Test-Path -LiteralPath $ReplayOutputPath -PathType Leaf)) {
            throw "Dependency audit replay output was not found: $ReplayOutputPath"
        }

        $auditOutput = (Get-Content -LiteralPath $ReplayOutputPath -Raw).TrimEnd()
        $auditExitCode = $ReplayExitCode
    }

    if (-not [string]::IsNullOrWhiteSpace($auditOutput)) {
        Write-Output $auditOutput
    }

    if ($auditOutput -match '(?im)has the following vulnerable package|NU190[1-4]') {
        Write-AuditSummary 'Dependency audit: vulnerable package data was returned.'
        exit 1
    }

    $unavailablePattern = Get-UnavailableMatch -Output $auditOutput
    $clean = $auditExitCode -eq 0 -and
        $auditOutput -match '(?im)(No vulnerable packages found|no vulnerable packages given the current sources)' -and
        $auditOutput -match '(?im)following sources were used'

    if ($clean) {
        Write-AuditSummary 'Dependency audit: clean (direct and transitive dependency graph checked).'
        exit 0
    }

    if ($null -ne $unavailablePattern) {
        if ($Mode -eq 'Required') {
            Write-AuditSummary "Dependency audit: unavailable; required audit failed closed (matching condition: $unavailablePattern)."
            exit 1
        }

        Write-AuditSummary "Dependency audit: unavailable; ordinary CI tolerated the transient advisory-service condition and did not treat it as clean (matching condition: $unavailablePattern)."
        exit 0
    }

    if ($auditExitCode -ne 0) {
        Write-AuditSummary "Dependency audit: command failed with exit code $auditExitCode; vulnerability status was not determined."
    }
    else {
        Write-AuditSummary 'Dependency audit: vulnerability status was not determined from the audit output.'
    }
    exit 1
}
catch {
    Write-AuditSummary "Dependency audit: unavailable; required security status could not be determined. $($_.Exception.Message)"
    exit 1
}
