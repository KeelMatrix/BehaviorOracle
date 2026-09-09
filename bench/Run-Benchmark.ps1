param(
    [int64]$Seed = 12345,
    [int]$ScenarioBudget = 500,
    [int]$ConfirmationRuns = 3
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$corpus = Join-Path $PSScriptRoot 'corpus'
$baselineProject = Join-Path $corpus 'Baseline\Baseline.csproj'
$candidateProject = Join-Path $corpus 'Candidate\Candidate.csproj'
$baselineOutput = Join-Path $corpus '_baseline'
$candidateOutput = Join-Path $corpus '_candidate'

dotnet build $baselineProject -c Release
dotnet build $candidateProject -c Release

$baselineBuild = Join-Path $corpus 'Baseline\bin\Release\net8.0'
$candidateBuild = Join-Path $corpus 'Candidate\bin\Release\net8.0'
New-Item -ItemType Directory -Path $baselineOutput,$candidateOutput -Force | Out-Null
Copy-Item -Path (Join-Path $baselineBuild '*') -Destination $baselineOutput -Force
Copy-Item -Path (Join-Path $candidateBuild '*') -Destination $candidateOutput -Force

$tool = Join-Path $repo 'src\KeelMatrix.BehaviorOracle\bin\Release\net8.0\KeelMatrix.BehaviorOracle.dll'
$report = Join-Path $repo 'artifacts\synthetic-benchmark.json'
dotnet $tool benchmark --manifest (Join-Path $corpus 'manifest.json') --seed $Seed --scenario-budget $ScenarioBudget --confirmation-runs $ConfirmationRuns --format json --output $report
Write-Output "Benchmark report: $report"
