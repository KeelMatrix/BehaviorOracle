param(
    [long]$Seed = 12345,
    [int]$ScenarioBudget = 20,
    [int]$ConfirmationRuns = 2,
    [string]$PackagePath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$smokeRoot = [IO.Path]::Combine($repo, 'artifacts', 'package-smoke')
$packageFeed = Join-Path $smokeRoot 'packages'
$installRoot = Join-Path $smokeRoot 'install'
$baselineOutput = Join-Path $smokeRoot 'baseline'
$candidateOutput = Join-Path $smokeRoot 'candidate'
$reportRoot = Join-Path $smokeRoot 'reports'
$config = Join-Path $smokeRoot 'oracle.json'
$project = [IO.Path]::Combine($repo, 'src', 'KeelMatrix.BehaviorOracle', 'KeelMatrix.BehaviorOracle.csproj')

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

    $output = (& $toolPath @Arguments 2>&1 | Out-String).TrimEnd()
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

    $solution = [IO.Path]::Combine($repo, 'KeelMatrix.BehaviorOracle.sln')
    $nugetConfig = [IO.Path]::Combine($repo, 'NuGet.config')
    $baselineProject = [IO.Path]::Combine($repo, 'bench', 'corpus', 'baseline', 'Baseline.csproj')
    $candidateProject = [IO.Path]::Combine($repo, 'bench', 'corpus', 'candidate', 'Candidate.csproj')
    $baselineBuild = [IO.Path]::Combine($repo, 'bench', 'corpus', 'baseline', 'bin', 'Release', 'net8.0')
    $candidateBuild = [IO.Path]::Combine($repo, 'bench', 'corpus', 'candidate', 'bin', 'Release', 'net8.0')

    Invoke-Checked 'dotnet' @('restore', $solution, '--configfile', $nugetConfig, '-p:NuGetAudit=false')
    Invoke-Checked 'dotnet' @('build', $baselineProject, '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('build', $candidateProject, '-c', 'Release', '--no-restore')

    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        Invoke-Checked 'dotnet' @('build', $project, '-c', 'Release', '--no-restore')
        Invoke-Checked 'dotnet' @('pack', $project, '-c', 'Release', '--no-build', '-o', $packageFeed, '-p:PackageVersion=0.1.0')
    }
    else {
        if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
            throw "Packed tool package was not found: $PackagePath"
        }

        Copy-Item -LiteralPath $PackagePath -Destination $packageFeed -Force
    }

    Copy-Item (Join-Path $baselineBuild '*.dll') $baselineOutput -Force
    Copy-Item (Join-Path $candidateBuild '*.dll') $candidateOutput -Force
    $nupkg = Join-Path $packageFeed 'KeelMatrix.BehaviorOracle.0.1.0.nupkg'
    Assert-True (Test-Path -LiteralPath $nupkg -PathType Leaf) "Expected package was not created: $nupkg"

    @{
        version = 1
        seed = $Seed
        scenarioBudget = $ScenarioBudget
        confirmationRuns = $ConfirmationRuns
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $config -NoNewline

    Invoke-Checked 'dotnet' @('tool', 'install', '--tool-path', $installRoot, 'KeelMatrix.BehaviorOracle', '--version', '0.1.0', '--add-source', $packageFeed, '--add-source', 'https://api.nuget.org/v3/index.json', '--ignore-failed-sources')
    $toolPath = Get-ChildItem -LiteralPath $installRoot -File |
        Where-Object { $_.BaseName -eq 'behavior-oracle' } |
        Select-Object -First 1 -ExpandProperty FullName
    Assert-True (-not [string]::IsNullOrWhiteSpace($toolPath)) "Installed tool was not found in $installRoot"

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
