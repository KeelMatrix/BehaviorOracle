[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Remove-TemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) {
        throw "Temporary dependency audit directory was not removed: $Path"
    }
}

$scriptPath = Join-Path $PSScriptRoot 'Invoke-DependencyAudit.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-dependency-audit-$([Guid]::NewGuid().ToString('N'))"
$replayPath = Join-Path $testRoot 'unavailable-audit.txt'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    @'
No vulnerable packages found given the current sources.
The following sources were used:
  https://api.nuget.org/v3/index.json
error NU1900: Error occurred while retrieving package vulnerability data: unable to load the service index for source https://api.nuget.org/v3/index.json.
'@ | Set-Content -LiteralPath $replayPath -NoNewline

    $requiredOutput = (& pwsh -NoProfile -File $scriptPath -Mode Required -ReplayOutputPath $replayPath -ReplayExitCode 1 2>&1 | Out-String).TrimEnd()
    $requiredExitCode = $LASTEXITCODE
    Assert-Test ($requiredExitCode -ne 0) 'The required dependency audit accepted unavailable advisory data.'
    Assert-Test ($requiredOutput.Contains('unavailable', [StringComparison]::OrdinalIgnoreCase)) "The required dependency audit did not report unavailable status. Output: $requiredOutput"
    Assert-Test ($requiredOutput.Contains('failed closed', [StringComparison]::OrdinalIgnoreCase)) "The required dependency audit did not report a fail-closed result. Output: $requiredOutput"

    $ciOutput = (& pwsh -NoProfile -File $scriptPath -Mode Ci -ReplayOutputPath $replayPath -ReplayExitCode 1 2>&1 | Out-String).TrimEnd()
    $ciExitCode = $LASTEXITCODE
    Assert-Test ($ciExitCode -eq 0) 'Ordinary CI did not tolerate the forced transient advisory-service condition.'
    Assert-Test ($ciOutput.Contains('unavailable', [StringComparison]::OrdinalIgnoreCase)) "Ordinary CI did not report unavailable status. Output: $ciOutput"
    Assert-Test (-not $ciOutput.Contains('Dependency audit: clean', [StringComparison]::OrdinalIgnoreCase)) "Ordinary CI mislabeled unavailable advisory data as clean. Output: $ciOutput"

    Write-Output 'Dependency audit distinction passed: required mode failed closed while ordinary CI reported unavailable and remained tolerant.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("Dependency audit distinction failed: $($_.Exception.Message)")
    exit 1
}
finally {
    Remove-TemporaryDirectory -Path $testRoot
}
