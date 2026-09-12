[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & git -C $Repository @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git -C $Repository $($Arguments -join ' ')"
    }
}

function Invoke-Contract {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [string]$ExpectedPackageVersion = $ExpectedVersion
    )

    $validator = Join-Path $PSScriptRoot 'Test-ChangelogContract.ps1'
    $arguments = @(
        '-NoProfile', '-File', $validator,
        '-RepositoryPath', $Repository,
        '-ChangelogPath', (Join-Path $Repository 'CHANGELOG.md'),
        '-ExpectedVersion', $ExpectedVersion,
        '-ExpectedPackageVersion', $ExpectedPackageVersion,
        '-ExpectedRepositoryCommit', $ExpectedCommit
    )
    $output = (& pwsh @arguments 2>&1 | Out-String).Trim()
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function New-SyntheticRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Changelog,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [string]$InstallExample = '',
        [switch]$CrLfChangelog
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-GitChecked -Repository $Root -Arguments @('init', '--quiet')
    Invoke-GitChecked -Repository $Root -Arguments @('config', 'user.name', 'KeelMatrix')
    Invoke-GitChecked -Repository $Root -Arguments @('config', 'user.email', 'dev@keelmatrix.example')
    $changelogText = if ($CrLfChangelog) {
        $Changelog.Replace("`r`n", "`n").Replace("`n", "`r`n")
    }
    else {
        $Changelog
    }
    [IO.File]::WriteAllText((Join-Path $Root 'CHANGELOG.md'), $changelogText, [Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $Root 'Directory.Build.props') -Value @"
<Project>
  <PropertyGroup>
    <PackageVersion>`$(Version)</PackageVersion>
  </PropertyGroup>
</Project>
"@ -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Root 'Synthetic.Package.csproj') -Value @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Version>$PackageVersion</Version>
    <IsPackable>true</IsPackable>
  </PropertyGroup>
</Project>
"@ -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Root 'Directory.Packages.props') -Value @"
<Project>
  <ItemGroup>
    <PackageVersion Include="KeelMatrix.Telemetry" Version="$PackageVersion" />
  </ItemGroup>
</Project>
"@ -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($InstallExample)) {
        $InstallExample = "dotnet tool install --global KeelMatrix.BehaviorOracle --version $PackageVersion"
    }
    Set-Content -LiteralPath (Join-Path $Root 'README.md') -Value $InstallExample -Encoding utf8
    Invoke-GitChecked -Repository $Root -Arguments @('add', '--', '.')
    Invoke-GitChecked -Repository $Root -Arguments @('commit', '--quiet', '-m', 'Create synthetic release fixture')
    return ((& git -C $Root rev-parse HEAD).Trim())
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-changelog-contract-$([Guid]::NewGuid().ToString('N'))"
$releaseDate = [DateTime]::UtcNow.Date.AddDays(-1).ToString('yyyy-MM-dd')

try {
    $plannedRoot = Join-Path $testRoot 'planned'
    $plannedCommit = New-SyntheticRepository -Root $plannedRoot -PackageVersion '0.1.0' -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - Planned (not yet published)

### Added

- Planned release.
"@
    $plannedResult = Invoke-Contract -Repository $plannedRoot -ExpectedCommit $plannedCommit -ExpectedVersion '0.1.0'
    Assert-Test ($plannedResult.ExitCode -ne 0) "A planned changelog entry unexpectedly passed the publication gate. Output: $($plannedResult.Output)"

    $nestedRoot = Join-Path $testRoot 'nested-unreleased'
    $nestedCommit = New-SyntheticRepository -Root $nestedRoot -PackageVersion '0.1.0' -Changelog @"
# Changelog

# [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Nested release.
"@
    $nestedResult = Invoke-Contract -Repository $nestedRoot -ExpectedCommit $nestedCommit -ExpectedVersion '0.1.0'
    Assert-Test ($nestedResult.ExitCode -ne 0) "A release entry nested under Unreleased unexpectedly passed the publication gate. Output: $($nestedResult.Output)"

    $finalizedRoot = Join-Path $testRoot 'finalized'
    $consistentInstallExample = @'
dotnet tool install --global KeelMatrix.BehaviorOracle `
  --version 0.1.0
'@
    $finalizedCommit = New-SyntheticRepository -Root $finalizedRoot -PackageVersion '0.1.0' -InstallExample $consistentInstallExample -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Finalized release.
"@
    $finalizedResult = Invoke-Contract -Repository $finalizedRoot -ExpectedCommit $finalizedCommit -ExpectedVersion '0.1.0'
    Assert-Test ($finalizedResult.ExitCode -eq 0) "A finalized, consistent multiline install example did not pass. Output: $($finalizedResult.Output)"

    $equalsInstallRoot = Join-Path $testRoot 'equals-install'
    $equalsInstallExample = 'dotnet tool install --global KeelMatrix.BehaviorOracle --version=0.1.0'
    $equalsInstallCommit = New-SyntheticRepository -Root $equalsInstallRoot -PackageVersion '0.1.0' -InstallExample $equalsInstallExample -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Equals-form install example.
"@
    $equalsInstallResult = Invoke-Contract -Repository $equalsInstallRoot -ExpectedCommit $equalsInstallCommit -ExpectedVersion '0.1.0'
    Assert-Test ($equalsInstallResult.ExitCode -eq 0) "An equals-form install example with the release version did not pass. Output: $($equalsInstallResult.Output)"

    foreach ($quote in @([char]34, [char]39, [char]96)) {
        $quotedVersion = [string]$quote + '0.2.0' + [string]$quote
        $quotedMismatchRoot = Join-Path $testRoot ("quoted-install-mismatch-" + [int]$quote)
        $quotedMismatchExample = "dotnet tool install --global KeelMatrix.BehaviorOracle --version $quotedVersion"
        $quotedMismatchCommit = New-SyntheticRepository -Root $quotedMismatchRoot -PackageVersion '0.1.0' -InstallExample $quotedMismatchExample -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Quoted mismatched install example.
"@
        $quotedMismatchResult = Invoke-Contract -Repository $quotedMismatchRoot -ExpectedCommit $quotedMismatchCommit -ExpectedVersion '0.1.0'
        Assert-Test ($quotedMismatchResult.ExitCode -ne 0) "A quoted install-example/version mismatch passed the publication gate."
    }

    $crlfFinalizedRoot = Join-Path $testRoot 'crlf-finalized'
    $crlfFinalizedCommit = New-SyntheticRepository -Root $crlfFinalizedRoot -PackageVersion '0.1.0' -CrLfChangelog -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Finalized CRLF release.
"@
    $crlfFinalizedResult = Invoke-Contract -Repository $crlfFinalizedRoot -ExpectedCommit $crlfFinalizedCommit -ExpectedVersion '0.1.0'
    Assert-Test ($crlfFinalizedResult.ExitCode -eq 0) "A finalized CRLF changelog was rejected. Output: $($crlfFinalizedResult.Output)"

    $crlfPlannedRoot = Join-Path $testRoot 'crlf-planned'
    $crlfPlannedCommit = New-SyntheticRepository -Root $crlfPlannedRoot -PackageVersion '0.1.0' -CrLfChangelog -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - Planned (not yet published)

### Added

- Planned CRLF release.
"@
    $crlfPlannedResult = Invoke-Contract -Repository $crlfPlannedRoot -ExpectedCommit $crlfPlannedCommit -ExpectedVersion '0.1.0'
    Assert-Test ($crlfPlannedResult.ExitCode -ne 0) "A planned CRLF changelog passed the publication gate."

    $multilineMismatchRoot = Join-Path $testRoot 'multiline-install-mismatch'
    $mismatchedInstallExample = @'
dotnet tool install --global KeelMatrix.BehaviorOracle \
  --version 0.2.0
'@
    $multilineMismatchCommit = New-SyntheticRepository -Root $multilineMismatchRoot -PackageVersion '0.1.0' -InstallExample $mismatchedInstallExample -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Mismatched multiline install example.
"@
    $multilineMismatchResult = Invoke-Contract -Repository $multilineMismatchRoot -ExpectedCommit $multilineMismatchCommit -ExpectedVersion '0.1.0'
    Assert-Test ($multilineMismatchResult.ExitCode -ne 0) "A multiline install-example/version mismatch unexpectedly passed. Output: $($multilineMismatchResult.Output)"

    $mismatchRoot = Join-Path $testRoot 'mismatch'
    $mismatchCommit = New-SyntheticRepository -Root $mismatchRoot -PackageVersion '0.2.0' -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Mismatched release.
"@
    $mismatchResult = Invoke-Contract -Repository $mismatchRoot -ExpectedCommit $mismatchCommit -ExpectedVersion '0.1.0' -ExpectedPackageVersion '0.2.0'
    Assert-Test ($mismatchResult.ExitCode -ne 0) "A changelog/tag/package version mismatch unexpectedly passed. Output: $($mismatchResult.Output)"

    $exactCommitRoot = Join-Path $testRoot 'exact-commit'
    $exactCommit = New-SyntheticRepository -Root $exactCommitRoot -PackageVersion '0.1.0' -Changelog @"
# Changelog

## [Unreleased]

## [0.1.0] - $releaseDate

### Added

- Exact commit release.
"@
    Add-Content -LiteralPath (Join-Path $exactCommitRoot 'CHANGELOG.md') -Value "`nAdditional committed context."
    Invoke-GitChecked -Repository $exactCommitRoot -Arguments @('add', '--', 'CHANGELOG.md')
    Invoke-GitChecked -Repository $exactCommitRoot -Arguments @('commit', '--quiet', '-m', 'Change release commit')
    $currentCommit = ((& git -C $exactCommitRoot rev-parse HEAD).Trim())
    $staleCommitResult = Invoke-Contract -Repository $exactCommitRoot -ExpectedCommit $exactCommit -ExpectedVersion '0.1.0'
    Assert-Test ($staleCommitResult.ExitCode -ne 0) "Validation unexpectedly accepted a changelog from a different checked-out commit ($currentCommit versus $exactCommit). Output: $($staleCommitResult.Output)"

    Write-Output 'Changelog contract tests passed: planned/nested releases rejected, finalized release accepted, version mismatch rejected, and exact commit binding enforced.'
    exit 0
}
catch {
    Write-Error "Changelog contract tests failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
