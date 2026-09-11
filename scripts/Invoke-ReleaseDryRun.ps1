[CmdletBinding()]
param(
    [string]$Tag = 'v0.1.0',
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ScratchDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

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

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    $output = (& $File @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$File' failed with exit code $LASTEXITCODE. Output: $output"
    }

    return $output
}

$repository = (Resolve-Path -LiteralPath $RepositoryPath).Path
$workflowPath = Join-Path $repository '.github/workflows/release.yml'
$workflow = Get-Content -LiteralPath $workflowPath -Raw
$resolveSectionMatch = [regex]::Match($workflow, '(?ms)^  resolve-version:\r?\n(?<section>.*?)(?=^  platform:)')
$publishSectionMatch = [regex]::Match($workflow, '(?ms)^  publish:\r?\n(?<section>.*)$')
Assert-Condition $resolveSectionMatch.Success 'Release workflow is missing the resolve-version job.'
Assert-Condition $publishSectionMatch.Success 'Release workflow is missing the publish job.'
$resolveSection = $resolveSectionMatch.Groups['section'].Value
$publishSection = $publishSectionMatch.Groups['section'].Value
Assert-Condition ($resolveSection.Contains('outputs:', [StringComparison]::Ordinal)) 'resolve-version does not declare job outputs.'
Assert-Condition ($resolveSection.Contains('version: ${{ steps.release-version.outputs.version }}', [StringComparison]::Ordinal)) 'resolve-version does not expose the resolver step output as version.'
Assert-Condition (([regex]::Matches($workflow, '\$\{\{ needs\.resolve-version\.outputs\.version \}\}')).Count -ge 3) 'Downstream release jobs do not consume the resolved version output.'
Assert-Condition (([regex]::Matches($workflow, '(?m)^\s*id-token:\s*write\s*$')).Count -eq 1) 'The release workflow has an unexpected number of id-token write permissions.'
Assert-Condition ($publishSection.Contains('id-token: write', [StringComparison]::Ordinal)) 'The publish job is missing id-token write permission.'
Assert-Condition ($publishSection.Contains('uses: NuGet/login@v1', [StringComparison]::Ordinal)) 'The publish job is missing NuGet Trusted Publishing login.'
Assert-Condition ($publishSection.Contains('user: dmitriyzen', [StringComparison]::Ordinal)) 'The publish job does not use the required NuGet account.'
Assert-Condition ($workflow.Contains("tags:`r`n      - 'v*'", [StringComparison]::Ordinal) -or $workflow.Contains("tags:`n      - 'v*'", [StringComparison]::Ordinal)) 'The release workflow is not tag-triggered by v*.'
Assert-Condition (-not [regex]::IsMatch($workflow, '(?m)^\s*workflow_dispatch:\s*$')) 'The release workflow unexpectedly enables manual dispatch.'

$oldTelemetry = $env:KEELMATRIX_NO_TELEMETRY
$env:KEELMATRIX_NO_TELEMETRY = '1'
$env:RELEASE_TAG = $Tag
$env:RELEASE_REF_TYPE = 'tag'

$scratchRoot = if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
    [IO.Path]::GetTempPath()
} else {
    (New-Item -ItemType Directory -Path $ScratchDirectory -Force).FullName
}
$workRoot = Join-Path $scratchRoot "behaviororacle-release-dry-run-$([Guid]::NewGuid().ToString('N'))"

try {
    if ($env:RELEASE_REF_TYPE -ne 'tag') {
        throw "Release workflow requires a tag ref, got '$($env:RELEASE_REF_TYPE)'."
    }

    $match = [regex]::Match($env:RELEASE_TAG, '^v(?<version>(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$')
    if (-not $match.Success) {
        throw "Malformed release tag '$($env:RELEASE_TAG)'. Expected vX.Y.Z."
    }

    $version = $match.Groups['version'].Value
    if ($version -ne '0.1.0') {
        throw "Unsupported first-release version '$version'; expected 0.1.0."
    }
    $env:RELEASE_VERSION = $version

    $status = Invoke-Captured -File 'git' -Arguments @('-C', $repository, 'status', '--porcelain', '--untracked-files=no')
    Assert-Condition ([string]::IsNullOrWhiteSpace($status)) 'Release dry-run requires a clean tracked worktree.'
    $commit = Invoke-Captured -File 'git' -Arguments @('-C', $repository, 'rev-parse', 'HEAD')
    Assert-Condition ($commit -match '^[0-9a-fA-F]{40}$') "Commit '$commit' is not a full Git SHA."

    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $packageDirectory = Join-Path $workRoot 'packages'
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null
    $solution = Join-Path $repository 'KeelMatrix.BehaviorOracle.sln'
    $project = Join-Path $repository 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj'
    $config = Join-Path $repository 'NuGet.config'

    Invoke-Checked -File 'dotnet' -Arguments @(
        'restore', $solution,
        '--configfile', $config,
        '--no-cache', '--force',
        '-p:NuGetAudit=false'
    )
    Invoke-Checked -File 'dotnet' -Arguments @(
        'build', $solution,
        '--configuration', 'Release',
        '--no-restore',
        '--warnaserror',
        "-p:Version=$env:RELEASE_VERSION",
        "-p:PackageVersion=$env:RELEASE_VERSION",
        "-p:SourceRevisionId=$commit",
        "-p:RepositoryCommit=$commit"
    )
    Invoke-Checked -File 'dotnet' -Arguments @(
        'pack', $project,
        '--configuration', 'Release',
        '--no-build', '--no-restore',
        '--include-symbols',
        '-p:SymbolPackageFormat=snupkg',
        "-p:Version=$env:RELEASE_VERSION",
        "-p:PackageVersion=$env:RELEASE_VERSION",
        "-p:SourceRevisionId=$commit",
        "-p:RepositoryCommit=$commit",
        '--output', $packageDirectory
    )

    $expectedNames = @(
        "KeelMatrix.BehaviorOracle.$version.nupkg",
        "KeelMatrix.BehaviorOracle.$version.snupkg"
    ) | Sort-Object
    $actualNames = @(Get-ChildItem -LiteralPath $packageDirectory -File | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Condition (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames).Count -eq 0) "Release dry-run produced an unexpected artifact set. Expected: $($expectedNames -join ', '). Actual: $($actualNames -join ', ')."

    $packagePath = Join-Path $packageDirectory $expectedNames[0]
    $symbolsPath = Join-Path $packageDirectory $expectedNames[1]
    $inspector = Join-Path $repository 'scripts/Verify-PackageContract.ps1'
    Invoke-Checked -File 'pwsh' -Arguments @(
        '-NoProfile', '-File', $inspector,
        '-PackagePath', $packagePath,
        '-SymbolsPath', $symbolsPath,
        '-ExpectedVersion', $env:RELEASE_VERSION,
        '-ExpectedRepositoryCommit', $commit
    )

    $smoke = Join-Path $repository 'scripts/Invoke-PackageSmoke.ps1'
    Invoke-Checked -File 'pwsh' -Arguments @(
        '-NoProfile', '-File', $smoke,
        '-PackagePath', $packagePath,
        '-SymbolsPath', $symbolsPath,
        '-ExpectedRepositoryCommit', $commit,
        '-Seed', '12345',
        '-ScenarioBudget', '20',
        '-ConfirmationRuns', '2'
    )

    Write-Output "Release dry-run passed: $env:RELEASE_TAG -> $env:RELEASE_VERSION -> Release build -> package/symbol inspection -> isolated consumer smoke."
    Write-Output 'Publication gate: SKIPPED (non-publishing local validation).'
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    $env:KEELMATRIX_NO_TELEMETRY = $oldTelemetry
    Remove-Item Env:RELEASE_TAG -ErrorAction SilentlyContinue
    Remove-Item Env:RELEASE_REF_TYPE -ErrorAction SilentlyContinue
    Remove-Item Env:RELEASE_VERSION -ErrorAction SilentlyContinue
}
