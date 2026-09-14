[CmdletBinding()]
param(
    [string]$BenchmarkPath,
    [string]$MetadataPath,
    [string]$ConfigPath,
    [string]$ToolPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BenchmarkPath = if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) {
    Join-Path $PSScriptRoot 'Invoke-RealLibraryBenchmark.ps1'
} else {
    (Resolve-Path -LiteralPath $BenchmarkPath).Path
}
$MetadataPath = if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
    Join-Path $PSScriptRoot 'targets.json'
} else {
    (Resolve-Path -LiteralPath $MetadataPath).Path
}
$ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $PSScriptRoot 'config.json'
} else {
    (Resolve-Path -LiteralPath $ConfigPath).Path
}
$ToolPath = if ([string]::IsNullOrWhiteSpace($ToolPath)) {
    Join-Path $repo 'src\KeelMatrix.BehaviorOracle\bin\Release\net8.0\KeelMatrix.BehaviorOracle.dll'
} else {
    (Resolve-Path -LiteralPath $ToolPath).Path
}

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-Condition (Test-Path -LiteralPath $BenchmarkPath -PathType Leaf) "Benchmark script is missing: $BenchmarkPath"
Assert-Condition (Test-Path -LiteralPath $MetadataPath -PathType Leaf) "Target metadata is missing: $MetadataPath"
Assert-Condition (Test-Path -LiteralPath $ConfigPath -PathType Leaf) "Benchmark configuration is missing: $ConfigPath"
Assert-Condition (Test-Path -LiteralPath $ToolPath -PathType Leaf) "Build the Release tool before testing the real-library benchmark contract: $ToolPath"

$metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-Condition ($metadata.version -eq 1 -and @($metadata.targets).Count -eq 3) 'Real-library metadata must contain exactly the three pinned targets.'
Assert-Condition ($config.version -eq 1 -and [int]$config.scenarioBudget -ge 1 -and [int]$config.scenarioBudget -le 32) 'Real-library scenario budget must remain bounded from 1 through 32.'
Assert-Condition ([int]$config.confirmationRuns -ge 1 -and [int]$config.confirmationRuns -le 3) 'Real-library confirmation runs must remain bounded from 1 through 3.'

foreach ($target in @($metadata.targets)) {
    foreach ($side in @('baseline', 'candidate')) {
        $package = $target.PSObject.Properties[$side].Value
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($package.version)) "$($target.id) $side package version is missing."
        Assert-Condition ($package.sha512 -match '^[0-9A-Fa-f]{128}$') "$($target.id) $side package SHA-512 is not pinned."
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($package.asset)) "$($target.id) $side package asset is missing."
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-real-target-contract-$([Guid]::NewGuid().ToString('N'))"
$invalidConfigPath = Join-Path $testRoot 'invalid-config.json'
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        $invalidConfigPath,
        (@{
            version = 1
            seed = 12345
            scenarioBudget = 33
            confirmationRuns = 3
        } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false))

    $output = (& pwsh -NoProfile -File $BenchmarkPath -ToolPath $ToolPath -MetadataPath $MetadataPath -ConfigPath $invalidConfigPath 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    Assert-Condition ($exitCode -ne 0) 'The real-library benchmark accepted a scenario budget above its configured bound.'
    Assert-Condition ($output.Contains('scenario budget from 1 through 32', [StringComparison]::Ordinal)) "The fail-closed budget rejection had an unexpected diagnostic: $output"

    Write-Output 'Real-library benchmark contract passed: target versions and SHA-512 values are pinned, budgets are bounded, and an invalid budget fails closed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
