param(
    [long]$Seed = 12345,
    [int]$ScenarioBudget = 20,
    [int]$ConfirmationRuns = 2
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$smokeRoot = Join-Path $repo 'artifacts\package-smoke'
$packageFeed = Join-Path $smokeRoot 'packages'
$installRoot = Join-Path $smokeRoot 'install'
$baselineOutput = Join-Path $smokeRoot 'baseline'
$candidateOutput = Join-Path $smokeRoot 'candidate'
$reportRoot = Join-Path $smokeRoot 'reports'
$config = Join-Path $smokeRoot 'oracle.json'
$project = Join-Path $repo 'src\KeelMatrix.BehaviorOracle\KeelMatrix.BehaviorOracle.csproj'
$tool = Join-Path $installRoot 'behavior-oracle.exe'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$File' failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Tool {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = (& $tool @Arguments 2>&1 | Out-String).TrimEnd()
    [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

if (Test-Path -LiteralPath $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageFeed, $installRoot, $baselineOutput, $candidateOutput, $reportRoot -Force | Out-Null

$oldTelemetryOptOut = [Environment]::GetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY')
try {
    [Environment]::SetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY', '1')

    Invoke-Checked 'dotnet' @('restore', (Join-Path $repo 'KeelMatrix.BehaviorOracle.sln'), '--configfile', (Join-Path $repo 'NuGet.config'))
    Invoke-Checked 'dotnet' @('build', (Join-Path $repo 'bench\corpus\baseline\Baseline.csproj'), '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('build', (Join-Path $repo 'bench\corpus\candidate\Candidate.csproj'), '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('build', $project, '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('pack', $project, '-c', 'Release', '--no-build', '-o', $packageFeed, '-p:PackageVersion=0.1.0')

    Copy-Item (Join-Path $repo 'bench\corpus\baseline\bin\Release\net8.0\*.dll') $baselineOutput -Force
    Copy-Item (Join-Path $repo 'bench\corpus\candidate\bin\Release\net8.0\*.dll') $candidateOutput -Force
    $nupkg = Join-Path $packageFeed 'KeelMatrix.BehaviorOracle.0.1.0.nupkg'
    Assert-True (Test-Path -LiteralPath $nupkg -PathType Leaf) "Expected package was not created: $nupkg"

    @{
        version = 1
        seed = $Seed
        scenarioBudget = $ScenarioBudget
        confirmationRuns = $ConfirmationRuns
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $config -NoNewline

    Invoke-Checked 'dotnet' @('tool', 'install', '--tool-path', $installRoot, 'KeelMatrix.BehaviorOracle', '--version', '0.1.0', '--add-source', $packageFeed, '--add-source', 'https://api.nuget.org/v3/index.json', '--ignore-failed-sources')
    Assert-True (Test-Path -LiteralPath $tool -PathType Leaf) "Installed tool was not found: $tool"

    $equivalent = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $baselineOutput, '--config', $config, '--format', 'console')
    Assert-True ($equivalent.ExitCode -eq 0) "Equivalent package comparison returned $($equivalent.ExitCode). Output: $($equivalent.Output)"
    Assert-True ($equivalent.Output.Contains('EQUIVALENT WITHIN TESTED DOMAIN', [StringComparison]::Ordinal)) 'Equivalent console wording was not found.'

    $firstDivergence = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $candidateOutput, '--config', $config, '--format', 'json')
    $secondDivergence = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $candidateOutput, '--config', $config, '--format', 'json')
    Assert-True ($firstDivergence.ExitCode -eq 1) "Divergence package comparison returned $($firstDivergence.ExitCode). Output: $($firstDivergence.Output)"
    Assert-True ($firstDivergence.Output -eq $secondDivergence.Output) 'JSON report was not byte-deterministic for the same package inputs.'
    $report = $firstDivergence.Output | ConvertFrom-Json
    Assert-True ($report.resultState -eq 'BEHAVIORAL_DIVERGENCE') "Unexpected JSON result state: $($report.resultState)"
    Assert-True ($report.divergences.Count -gt 0) 'The planted divergence report has no divergence record.'
    Assert-True ($report.divergences[0].minimizedInput -ne $null) 'The divergence report has no minimized witness.'
    Assert-True ($report.seed -eq $Seed) "The report seed was not preserved: $($report.seed)"
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $reportRoot 'divergence.json')

    Write-Output "Package smoke passed. Nupkg: $nupkg"
    Write-Output "Equivalent exit: $($equivalent.ExitCode); divergence exit: $($firstDivergence.ExitCode); seed: $Seed"
}
finally {
    [Environment]::SetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY', $oldTelemetryOptOut)
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
