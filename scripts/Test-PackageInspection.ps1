[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$SymbolsPath,

    [string]$ExpectedRepositoryCommit,

    [string]$InspectorPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Set-NuspecCopyright {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][ValidateSet('Wrong', 'Missing')][string]$Mutation
    )

    $stream = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Update, $false)
        try {
            $entry = $archive.GetEntry('KeelMatrix.BehaviorOracle.nuspec')
            Assert-Test ($null -ne $entry) 'The synthetic package is missing its nuspec.'
            $reader = [IO.StreamReader]::new($entry.Open())
            try {
                $nuspec = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            $copyright = '<copyright>KeelMatrix</copyright>'
            $replacement = if ($Mutation -eq 'Wrong') { '<copyright>Other</copyright>' } else { '' }
            Assert-Test ($nuspec.Contains($copyright, [StringComparison]::Ordinal)) 'The synthetic package nuspec does not contain the expected copyright element.'
            $updatedNuspec = $nuspec.Replace($copyright, $replacement, [StringComparison]::Ordinal)
            $entry.Delete()
            $newEntry = $archive.CreateEntry('KeelMatrix.BehaviorOracle.nuspec')
            $writer = [IO.StreamWriter]::new($newEntry.Open(), [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($updatedNuspec)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-NegativeInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Mutation,
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$SymbolsPath,
        [Parameter(Mandatory = $true)][string]$InspectorPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    Set-NuspecCopyright -PackagePath $PackagePath -Mutation $Mutation
    $arguments = @(
        '-NoProfile',
        '-File', $InspectorPath,
        '-PackagePath', $PackagePath,
        '-SymbolsPath', $SymbolsPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        $arguments += @('-ExpectedRepositoryCommit', $ExpectedRepositoryCommit)
    }

    $output = (& pwsh @arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE
    Assert-Test ($exitCode -ne 0) "The package inspector accepted a synthetic $Mutation copyright value."
    if ($Mutation -eq 'Wrong') {
        Assert-Test ($output.Contains("Package copyright must be 'KeelMatrix'.", [StringComparison]::Ordinal)) "The wrong copyright was rejected without the expected diagnostic. Output: $output"
    }
    else {
        Assert-Test ($output.Contains('Package metadata is missing the copyright.', [StringComparison]::Ordinal)) "The missing copyright was rejected without the expected diagnostic. Output: $output"
    }
}

function Remove-TemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) {
        throw "Temporary package inspection directory was not removed: $Path"
    }
}

$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InspectorPath)) {
    $InspectorPath = Join-Path $PSScriptRoot 'Inspect-Package.ps1'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-package-inspection-$([Guid]::NewGuid().ToString('N'))"
$mutatedPackage = Join-Path $testRoot 'KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$wrongCopyrightPackage = Join-Path $testRoot 'wrong-copyright\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$missingCopyrightPackage = Join-Path $testRoot 'missing-copyright\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$output = $null
$exitCode = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Copy-Item -LiteralPath $PackagePath -Destination $mutatedPackage

    $stream = [IO.File]::Open($mutatedPackage, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Update, $false)
        try {
            $entry = $archive.CreateEntry('tools/net8.0/any/diagnostics.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try {
                $writer.Write('diagnostic output')
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    $arguments = @(
        '-NoProfile',
        '-File', $InspectorPath,
        '-PackagePath', $mutatedPackage,
        '-SymbolsPath', $SymbolsPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        $arguments += @('-ExpectedRepositoryCommit', $ExpectedRepositoryCommit)
    }

    $output = (& pwsh @arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE
    Assert-Test ($exitCode -ne 0) 'The package inspector accepted an unexpected benign-looking archive entry.'
    Assert-Test ($output.Contains("unexpected archive entry 'tools/net8.0/any/diagnostics.txt'", [StringComparison]::Ordinal)) "The negative package inspection did not report the unexpected entry. Output: $output"
    New-Item -ItemType Directory -Path (Split-Path -Parent $wrongCopyrightPackage), (Split-Path -Parent $missingCopyrightPackage) -Force | Out-Null
    Copy-Item -LiteralPath $PackagePath -Destination $wrongCopyrightPackage
    Invoke-NegativeInspection -Mutation Wrong -PackagePath $wrongCopyrightPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $missingCopyrightPackage
    Invoke-NegativeInspection -Mutation Missing -PackagePath $missingCopyrightPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Write-Output 'Negative package inspection passed: unexpected entry and wrong/missing copyright metadata were rejected.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("Negative package inspection failed: $($_.Exception.Message)")
    exit 1
}
finally {
    Remove-TemporaryDirectory -Path $testRoot
}
