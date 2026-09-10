param(
    [int64]$Seed = 12345,
    [int]$ScenarioBudget = 80,
    [int]$ConfirmationRuns = 3
)

$ErrorActionPreference = 'Stop'
if ($Seed -ne 12345 -or $ScenarioBudget -ne 80 -or $ConfirmationRuns -ne 3) {
    throw 'The committed synthetic benchmark manifest is bound to -Seed 12345 -ScenarioBudget 80 -ConfirmationRuns 3.'
}
$repo = Split-Path -Parent $PSScriptRoot
$corpus = Join-Path $PSScriptRoot 'corpus'
$baselineProject = [IO.Path]::Combine($corpus, 'baseline', 'Baseline.csproj')
$candidateProject = [IO.Path]::Combine($corpus, 'candidate', 'Candidate.csproj')
$baselineOutput = Join-Path $corpus '_baseline'
$candidateOutput = Join-Path $corpus '_candidate'
$baselineBuild = [IO.Path]::Combine($corpus, 'baseline', 'bin', 'Release', 'net8.0')
$candidateBuild = [IO.Path]::Combine($corpus, 'candidate', 'bin', 'Release', 'net8.0')
$tool = [IO.Path]::Combine($repo, 'src', 'KeelMatrix.BehaviorOracle', 'bin', 'Release', 'net8.0', 'KeelMatrix.BehaviorOracle.dll')

try {
    # Remove all generated inputs before building or copying so a failed or
    # incremental build cannot leave a stale assembly in the comparison.
    foreach ($directory in @($baselineOutput, $candidateOutput, $baselineBuild, $candidateBuild)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }

    dotnet build $baselineProject -c Release
    $baselineBuildExitCode = $LASTEXITCODE
    if ($baselineBuildExitCode -ne 0) {
        throw "Baseline benchmark build failed with dotnet exit code $baselineBuildExitCode."
    }

    dotnet build $candidateProject -c Release
    $candidateBuildExitCode = $LASTEXITCODE
    if ($candidateBuildExitCode -ne 0) {
        throw "Candidate benchmark build failed with dotnet exit code $candidateBuildExitCode."
    }

    $requiredAssemblies = @(
        (Join-Path $baselineBuild 'BehaviorOracleCorpus.Baseline.dll'),
        (Join-Path $candidateBuild 'BehaviorOracleCorpus.Candidate.dll'),
        $tool
    )
    foreach ($assembly in $requiredAssemblies) {
        if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) {
            throw "Required benchmark assembly is missing after build: $assembly"
        }
    }

    New-Item -ItemType Directory -Path $baselineOutput, $candidateOutput -Force | Out-Null
    Copy-Item -Path (Join-Path $baselineBuild '*') -Destination $baselineOutput -Force
    Copy-Item -Path (Join-Path $candidateBuild '*') -Destination $candidateOutput -Force

    $reportDirectory = Join-Path $PSScriptRoot 'results'
    $report = Join-Path $reportDirectory 'synthetic-benchmark.json'
    $consoleReport = Join-Path $reportDirectory 'synthetic-benchmark.console.txt'
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $previousBenchmarkSwitch = $env:BEHAVIOR_ORACLE_ENABLE_BENCHMARK
    $env:BEHAVIOR_ORACLE_ENABLE_BENCHMARK = '1'
    try {
        dotnet $tool benchmark --manifest (Join-Path $corpus 'manifest.json') --seed $Seed --scenario-budget $ScenarioBudget --confirmation-runs $ConfirmationRuns --format json --output $report
        $benchmarkExitCode = $LASTEXITCODE
        $consoleOutput = (& dotnet $tool benchmark --manifest (Join-Path $corpus 'manifest.json') --seed $Seed --scenario-budget $ScenarioBudget --confirmation-runs $ConfirmationRuns --format console 2>&1 | Out-String).TrimEnd()
        $consoleExitCode = $LASTEXITCODE
        [IO.File]::WriteAllText($consoleReport, $consoleOutput, [Text.UTF8Encoding]::new($false))
        if ($consoleExitCode -ne $benchmarkExitCode) {
            throw "JSON and console benchmark exit codes differed: json=$benchmarkExitCode, console=$consoleExitCode."
        }
    }
    finally {
        if ($null -eq $previousBenchmarkSwitch) {
            Remove-Item Env:BEHAVIOR_ORACLE_ENABLE_BENCHMARK -ErrorAction SilentlyContinue
        }
        else {
            $env:BEHAVIOR_ORACLE_ENABLE_BENCHMARK = $previousBenchmarkSwitch
        }
    }
    switch ($benchmarkExitCode) {
        0 {
            Write-Output "Benchmark completed with no behavioral divergence. Report: $report"
            exit 0
        }
        1 {
            Write-Output "Benchmark completed with the expected planted divergence result. Report: $report"
            exit 1
        }
        default {
            throw "Benchmark execution failed with tool exit code $benchmarkExitCode."
        }
    }
}
catch {
    [Console]::Error.WriteLine("Benchmark failed closed: $($_.Exception.Message)")
    exit 2
}
