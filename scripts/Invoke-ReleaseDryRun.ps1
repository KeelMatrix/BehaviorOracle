[CmdletBinding()]
param(
    [string]$Tag = 'v0.1.0',

    [string]$RepositoryPath = (Get-Location).Path
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
        throw "Command '$File $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
Assert-Condition (Test-Path -LiteralPath (Join-Path $repo 'KeelMatrix.BehaviorOracle.sln') -PathType Leaf) "Repository solution was not found under: $repo"

$previousLocation = Get-Location
try {
    Set-Location -LiteralPath $repo
    $env:KEELMATRIX_NO_TELEMETRY = '1'

    # Resolve the version exactly as the tag-driven release workflow does.
    $releaseRefType = 'tag'
    Assert-Condition ($releaseRefType -eq 'tag') "Release workflow requires a tag ref, got '$releaseRefType'."

    $match = [regex]::Match($Tag, '^v(?<version>(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$')
    Assert-Condition $match.Success "Malformed release tag '$Tag'. Expected vX.Y.Z."

    $version = $match.Groups['version'].Value
    Assert-Condition ($version -eq '0.1.0') "Unsupported first-release version '$version'; expected 0.1.0."

    $githubOutput = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-release-output-$([Guid]::NewGuid().ToString('N')).txt"
    "version=$version" | Out-File -FilePath $githubOutput -Encoding utf8
    $resolvedVersion = (Get-Content -LiteralPath $githubOutput -Raw | ForEach-Object { $_ -replace '^version=', '' }).Trim()
    Remove-Item -LiteralPath $githubOutput -Force -ErrorAction SilentlyContinue
    Assert-Condition ($resolvedVersion -eq '0.1.0') "Version handoff produced '$resolvedVersion'; expected 0.1.0."

    $commit = (& git rev-parse HEAD 2>&1 | Out-String).Trim()
    Assert-Condition ($LASTEXITCODE -eq 0 -and $commit -match '^[0-9a-fA-F]{40}$') 'Unable to resolve the repository commit.'

    $packageDirectory = Join-Path $repo 'artifacts\packages'
    if (Test-Path -LiteralPath $packageDirectory) {
        Remove-Item -LiteralPath $packageDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

    Write-Output "Resolved release version: $version"
    Write-Output 'Restoring and building the release candidate without publishing.'

    Invoke-Checked 'dotnet' @('restore', 'KeelMatrix.BehaviorOracle.sln', '--configfile', 'NuGet.config', '--no-cache', '--force', '-p:NuGetAudit=false')
    Invoke-Checked 'dotnet' @(
        'build', 'KeelMatrix.BehaviorOracle.sln',
        '--configuration', 'Release',
        '--no-restore',
        '--warnaserror',
        "-p:Version=$version",
        "-p:PackageVersion=$version",
        "-p:SourceRevisionId=$commit",
        "-p:RepositoryCommit=$commit"
    )
    Invoke-Checked 'dotnet' @(
        'pack', 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj',
        '--configuration', 'Release',
        '--no-build',
        '--no-restore',
        '--include-symbols',
        '-p:SymbolPackageFormat=snupkg',
        "-p:Version=$version",
        "-p:PackageVersion=$version",
        "-p:SourceRevisionId=$commit",
        "-p:RepositoryCommit=$commit",
        '--output', $packageDirectory
    )

    $expectedArtifacts = @(
        "KeelMatrix.BehaviorOracle.$version.nupkg",
        "KeelMatrix.BehaviorOracle.$version.snupkg"
    ) | Sort-Object
    $actualArtifacts = @(Get-ChildItem -LiteralPath $packageDirectory -File | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Condition (@(Compare-Object -ReferenceObject $expectedArtifacts -DifferenceObject $actualArtifacts).Count -eq 0) "Unexpected release artifact set. Expected: $($expectedArtifacts -join ', '). Actual: $($actualArtifacts -join ', ')."

    $packagePath = Join-Path $packageDirectory "KeelMatrix.BehaviorOracle.$version.nupkg"
    $symbolsPath = Join-Path $packageDirectory "KeelMatrix.BehaviorOracle.$version.snupkg"
    Invoke-Checked 'pwsh' @(
        '-NoProfile', '-File', 'scripts/Verify-PackageContract.ps1',
        '-PackagePath', $packagePath,
        '-SymbolsPath', $symbolsPath,
        '-ExpectedVersion', $version,
        '-ExpectedRepositoryCommit', $commit
    )

    $localTags = @(git tag)
    Assert-Condition ($localTags.Count -eq 0) "The dry run must not create a tag, but local tags were found: $($localTags -join ', ')."

    Write-Output "Release dry run passed for $Tag."
    Write-Output "Publication gate skipped: no tag, GitHub Release, or NuGet package was published."
    Write-Output "Validated artifacts: $($expectedArtifacts -join ', ')."
    exit 0
}
catch {
    [Console]::Error.WriteLine("Release dry run failed: $($_.Exception.Message)")
    exit 1
}
finally {
    Set-Location -LiteralPath $previousLocation
}
