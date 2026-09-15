[CmdletBinding()]
param(
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/release.yml'),
    [string]$CiWorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/ci.yml')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-WorkflowStepBody {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StepName
    )

    $workflow = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $pattern = "(?ms)^      - name: $([regex]::Escape($StepName))\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<body>.*?)(?=^      - name:|\z)"
    $match = [regex]::Match($workflow, $pattern)
    Assert-Contract $match.Success "Workflow '$Path' is missing the '$StepName' PowerShell step."

    return (($match.Groups['body'].Value -replace '(?m)^ {10}', '').TrimEnd())
}

function Get-BenchmarkStepContractText {
    param(
        [Parameter(Mandatory = $true)][string]$Body
    )

    $lines = $Body -split '\r?\n' | ForEach-Object {
        if ($_ -match '^(?<indent>\s*)throw\s+') {
            "$($Matches.indent)throw <diagnostic>"
        }
        else {
            $_
        }
    }

    return [string]::Join("`n", $lines)
}

function Invoke-BenchmarkStepWrapper {
    param(
        [Parameter(Mandatory = $true)][string]$StepBody
    )

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-release-benchmark-contract-$([Guid]::NewGuid().ToString('N'))"
    $benchmarkDirectory = Join-Path $testRoot 'bench'
    $resultsDirectory = Join-Path $benchmarkDirectory 'results'
    $stubPath = Join-Path $benchmarkDirectory 'Run-Benchmark.ps1'
    $bodyPath = Join-Path $testRoot 'step-body.ps1'
    $wrapperPath = Join-Path $testRoot 'github-actions-wrapper.ps1'

    try {
        New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

        $stub = @'
[CmdletBinding()]
param(
    [int]$Seed,
    [int]$ScenarioBudget,
    [int]$ConfirmationRuns
)

$report = [ordered]@{
    resultState = 'BEHAVIORAL_DIVERGENCE'
    seed = 12345
    scenarioBudget = 80
    confirmationRuns = 3
    generatedScenarios = 80
    divergenceCount = 35
    trustworthy = $true
    benchmark = [ordered]@{
        plantedDivergences = 35
        trueDetectedDivergences = 35
        falseDivergences = 0
        precision = 1
        recall = 1
        scenarioOutcomeMismatches = 0
    }
}

$reportPath = [IO.Path]::Combine($PSScriptRoot, 'results', 'synthetic-benchmark.json')
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8
exit 1
'@
        [IO.File]::WriteAllText($stubPath, $stub, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($bodyPath, $StepBody + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

        $wrapper = @'
$ErrorActionPreference = 'stop'
& (Join-Path $PSScriptRoot 'step-body.ps1')
if (Test-Path -LiteralPath variable:\LASTEXITCODE) { exit $LASTEXITCODE }
exit 0
'@
        [IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))

        Push-Location $testRoot
        try {
            $output = & pwsh -NoProfile -File $wrapperPath 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output | Out-String).Trim()
        }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw -ErrorAction Stop
$publishSectionMatch = [regex]::Match($workflow, '(?ms)^  publish:\r?\n(?<section>.*)$')
Assert-Contract $publishSectionMatch.Success 'Release workflow is missing the publish job.'

$publishSection = $publishSectionMatch.Groups['section'].Value
$pushLines = @([regex]::Matches($publishSection, '(?m)^\s*dotnet\s+nuget\s+push\s+.+$') | ForEach-Object Value)
Assert-Contract ($pushLines.Count -eq 2) "Release publication must contain exactly two explicit dotnet nuget push commands; found $($pushLines.Count)."

$packagePushLines = @($pushLines | Where-Object {
        $_ -match '(?i)\.nupkg(?:\"|\x27|\))' -and $_ -notmatch '(?i)\.snupkg'
    })
$symbolPushLines = @($pushLines | Where-Object { $_ -match '(?i)\.snupkg(?:\"|\x27|\))' })

Assert-Contract ($packagePushLines.Count -eq 1) "Release publication must contain exactly one explicit .nupkg push; found $($packagePushLines.Count)."
Assert-Contract ($symbolPushLines.Count -eq 1) "Release publication must contain exactly one explicit .snupkg push; found $($symbolPushLines.Count)."
Assert-Contract ($packagePushLines[0] -match '(?i)(^|\s)--no-symbols(?=\s|$)') 'The primary .nupkg push must use --no-symbols so the sibling .snupkg is not published automatically.'

$releaseBenchmarkBody = Get-WorkflowStepBody -Path $WorkflowPath -StepName 'Run deterministic synthetic benchmark gate'
$ciBenchmarkBody = Get-WorkflowStepBody -Path $CiWorkflowPath -StepName 'Run deterministic synthetic benchmark'
Assert-Contract ((Get-BenchmarkStepContractText -Body $releaseBenchmarkBody) -ceq (Get-BenchmarkStepContractText -Body $ciBenchmarkBody)) 'The CI and release benchmark steps must share the same executable contract apart from diagnostic wording.'

foreach ($benchmarkStep in @(
        [pscustomobject]@{ Name = 'release'; Body = $releaseBenchmarkBody },
        [pscustomobject]@{ Name = 'CI'; Body = $ciBenchmarkBody }
    )) {
    $benchmarkResult = Invoke-BenchmarkStepWrapper -StepBody $benchmarkStep.Body
    Assert-Contract ($benchmarkResult.ExitCode -eq 0) "The $($benchmarkStep.Name) benchmark step leaked exit code $($benchmarkResult.ExitCode) under the GitHub Actions PowerShell wrapper. Output: $($benchmarkResult.Output)"
}

Write-Output 'Release publication contract passed: one --no-symbols .nupkg push and one explicit .snupkg push.'
exit 0
