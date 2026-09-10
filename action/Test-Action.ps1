param()

$ErrorActionPreference = 'Stop'

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'The committed Action validation currently requires Windows PowerShell/.NET evidence.'
}

$repo = Split-Path -Parent $PSScriptRoot
$entrypoint = Join-Path $PSScriptRoot 'entrypoint.ps1'
$validationRoot = Join-Path ([IO.Path]::GetTempPath()) "behavior oracle action validation $PID"
$fixtureRoot = Join-Path $validationRoot 'fixture repository'
$packageFeed = Join-Path $validationRoot 'local package feed'
$packageProject = Join-Path $repo 'src\KeelMatrix.BehaviorOracle\KeelMatrix.BehaviorOracle.csproj'
$solution = Join-Path $repo 'KeelMatrix.BehaviorOracle.sln'
$nugetConfig = Join-Path $repo 'NuGet.config'

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

function Set-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][AllowNull()][string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

function Get-ActionTempDirectories {
    @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'behavior-oracle-action-*' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
}

function Invoke-ActionCase {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineRef,
        [Parameter(Mandatory = $true)][string]$CandidateRef,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $false)][string]$ToolVersion = '0.1.0'
    )

    $names = @(
        'GITHUB_WORKSPACE',
        'BEHAVIOR_ORACLE_BASELINE_REF',
        'BEHAVIOR_ORACLE_CANDIDATE_REF',
        'BEHAVIOR_ORACLE_PROJECT',
        'BEHAVIOR_ORACLE_CONFIG',
        'BEHAVIOR_ORACLE_TOOL_VERSION',
        'BEHAVIOR_ORACLE_PACKAGE_SOURCE'
    )
    $oldValues = @{}
    foreach ($name in $names) {
        $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        Set-EnvironmentValue 'GITHUB_WORKSPACE' $fixtureRoot
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_BASELINE_REF' $BaselineRef
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_CANDIDATE_REF' $CandidateRef
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_PROJECT' $Project
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_CONFIG' $Config
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_TOOL_VERSION' $ToolVersion
        Set-EnvironmentValue 'BEHAVIOR_ORACLE_PACKAGE_SOURCE' $packageFeed

        $before = @(Get-ActionTempDirectories)
        $captured = @(& pwsh -NoProfile -File $entrypoint 2>&1)
        $exitCode = $LASTEXITCODE
        $output = ($captured | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $after = @(Get-ActionTempDirectories)
        $leaked = @($after | Where-Object { $before -notcontains $_ })
        if ($leaked.Count -ne 0) {
            throw "Action temporary directories were not cleaned up: $($leaked -join ', ')"
        }

        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output = $output
        }
    }
    finally {
        foreach ($name in $names) {
            Set-EnvironmentValue $name $oldValues[$name]
        }
    }
}

function Assert-ActionResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [Parameter(Mandatory = $false)][string]$ExpectedText
    )

    if ($Result.ExitCode -ne $ExpectedExitCode) {
        throw "$Name expected exit code $ExpectedExitCode but got $($Result.ExitCode). Output: $($Result.Output)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedText) -and
        -not $Result.Output.Contains($ExpectedText, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name did not contain '$ExpectedText'. Output: $($Result.Output)"
    }

    Write-Output "PASS $Name (exit $($Result.ExitCode))"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot, $packageFeed -Force | Out-Null

    Invoke-Checked 'dotnet' @('restore', $packageProject, '--configfile', $nugetConfig, '-p:NuGetAudit=false')
    Invoke-Checked 'dotnet' @('build', $packageProject, '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('pack', $packageProject, '-c', 'Release', '--no-build', '--no-restore', '-o', $packageFeed, '-p:PackageVersion=0.1.0')

    $fixtureProject = Join-Path $fixtureRoot 'src\Example Library\Example Library.csproj'
    $fixtureConfig = Join-Path $fixtureRoot '.github\Oracle Config.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureProject), (Split-Path -Parent $fixtureConfig) -Force | Out-Null
    @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath $fixtureProject -Encoding utf8
    '{"version":1,"seed":12345,"scenarioBudget":8,"confirmationRuns":2}' | Set-Content -LiteralPath $fixtureConfig -Encoding utf8
    @'
namespace ActionValidation;

public static class Calculator
{
    public static int Value() => 1;
}
'@ | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $fixtureProject) 'Calculator.cs') -Encoding utf8

    Invoke-Checked 'git' @('-C', $fixtureRoot, 'init', '--initial-branch=main')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'config', 'user.email', 'action-validation@example.invalid')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'config', 'user.name', 'Action Validation')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'add', '.')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'commit', '-m', 'baseline fixture')
    $baselineRef = (& git -C $fixtureRoot rev-parse HEAD).Trim()

    @'
namespace ActionValidation;

public static class Calculator
{
    public static int Value() => 2;
}
'@ | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $fixtureProject) 'Calculator.cs') -Encoding utf8
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'add', '.')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'commit', '-m', 'candidate fixture')
    $candidateRef = (& git -C $fixtureRoot rev-parse HEAD).Trim()

    @'
namespace ActionValidation;

public static class Calculator
{
    public static int Value() => ;
}
'@ | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $fixtureProject) 'Calculator.cs') -Encoding utf8
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'add', '.')
    Invoke-Checked 'git' @('-C', $fixtureRoot, 'commit', '-m', 'broken fixture')
    $brokenRef = (& git -C $fixtureRoot rev-parse HEAD).Trim()

    $pathWithSpaces = '.\SRC\EXAMPLE LIBRARY\EXAMPLE LIBRARY.CSPROJ'
    $relativeConfig = '.\.GITHUB\ORACLE CONFIG.JSON'
    $equivalent = Invoke-ActionCase $baselineRef $baselineRef $pathWithSpaces $relativeConfig
    Assert-ActionResult 'equivalent comparison and path handling' $equivalent 0 'EQUIVALENT WITHIN TESTED DOMAIN'

    $divergence = Invoke-ActionCase $baselineRef $candidateRef $pathWithSpaces $relativeConfig
    Assert-ActionResult 'divergence comparison and exit propagation' $divergence 1 'BEHAVIORAL DIVERGENCE'

    $invalidInput = Invoke-ActionCase $baselineRef $candidateRef '..\outside.csproj' $relativeConfig
    Assert-ActionResult 'invalid repository-relative input' $invalidInput 2 'remain within the repository workspace'

    $buildFailure = Invoke-ActionCase $baselineRef $brokenRef $pathWithSpaces $relativeConfig
    Assert-ActionResult 'candidate build failure' $buildFailure 2 'failed with exit code'

    $toolInstallFailure = Invoke-ActionCase $baselineRef $candidateRef $pathWithSpaces $relativeConfig '99.99.99'
    Assert-ActionResult 'tool-install failure' $toolInstallFailure 2

    Write-Output 'Action validation passed on Windows with PowerShell and .NET 8.'
}
finally {
    if (Test-Path -LiteralPath $validationRoot) {
        Remove-Item -LiteralPath $validationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
