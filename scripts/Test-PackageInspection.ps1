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

function Set-NuspecDescription {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

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

            $updatedNuspec = [regex]::Replace(
                $nuspec,
                '<description>.*?</description>',
                '<description>Wrong package description.</description>',
                [Text.RegularExpressions.RegexOptions]::Singleline)
            Assert-Test ($updatedNuspec -cne $nuspec) 'The synthetic package nuspec did not contain a description element.'
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

function Set-PackageReadmeLink {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$CurrentLink,
        [Parameter(Mandatory = $true)][string]$ReplacementLink
    )

    $stream = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Update, $false)
        try {
            $entry = $archive.GetEntry('README.md')
            Assert-Test ($null -ne $entry) 'The synthetic package is missing its README.'
            $reader = [IO.StreamReader]::new($entry.Open())
            try {
                $readme = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            Assert-Test ($readme.Contains($CurrentLink, [StringComparison]::Ordinal)) 'The synthetic package README does not contain the expected canonical schema checklist link.'
            $updatedReadme = $readme.Replace($CurrentLink, $ReplacementLink, [StringComparison]::Ordinal)
            $entry.Delete()
            $newEntry = $archive.CreateEntry('README.md')
            $writer = [IO.StreamWriter]::new($newEntry.Open(), [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($updatedReadme)
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

function Set-PackageReadmeContent {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $stream = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Update, $false)
        try {
            $entry = $archive.GetEntry('README.md')
            Assert-Test ($null -ne $entry) 'The synthetic package is missing its README.'
            $entry.Delete()
            $newEntry = $archive.CreateEntry('README.md')
            $writer = [IO.StreamWriter]::new($newEntry.Open(), [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($Content)
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

function Invoke-DescriptionNegativeInspection {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$SymbolsPath,
        [Parameter(Mandatory = $true)][string]$InspectorPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    Set-NuspecDescription -PackagePath $PackagePath
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
    Assert-Test ($exitCode -ne 0) 'The package inspector accepted a mismatched package description.'
    Assert-Test ($output.Contains('Package description is incorrect.', [StringComparison]::Ordinal)) "The mismatched package description was rejected without the expected diagnostic. Output: $output"
}

function Invoke-ReadmeLinkNegativeInspection {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$SymbolsPath,
        [Parameter(Mandatory = $true)][string]$InspectorPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    Set-PackageReadmeLink -PackagePath $PackagePath `
        -CurrentLink 'https://github.com/KeelMatrix/BehaviorOracle/blob/main/docs/SCHEMA_CHANGE_CHECKLIST.md' `
        -ReplacementLink 'docs/SCHEMA_CHANGE_CHECKLIST.md'
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
    Assert-Test ($exitCode -ne 0) 'The package inspector accepted a relative README link to an unpacked path.'
    Assert-Test ($output.Contains("relative link to an unpacked path 'docs/SCHEMA_CHANGE_CHECKLIST.md'.", [StringComparison]::Ordinal)) "The unpacked relative README link was rejected without the expected diagnostic. Output: $output"
}

function Invoke-ReadmeSourceNegativeInspection {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$SymbolsPath,
        [Parameter(Mandatory = $true)][string]$InspectorPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    $rootReadme = Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw
    Set-PackageReadmeContent -PackagePath $PackagePath -Content $rootReadme
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
    Assert-Test ($exitCode -ne 0) 'The package inspector accepted the repository-root README as the package README.'
    Assert-Test ($output.Contains('Packed README is missing the project-local package README marker.', [StringComparison]::Ordinal)) "The wrong README source was rejected without the expected diagnostic. Output: $output"
}

function Invoke-MissingReadmeContentNegativeInspection {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$SymbolsPath,
        [Parameter(Mandatory = $true)][string]$InspectorPath,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    $projectReadmePath = Join-Path $repo 'src/KeelMatrix.BehaviorOracle/README.md'
    $projectReadme = Get-Content -LiteralPath $projectReadmePath -Raw
    $missingContent = $projectReadme.Replace('## Important limitations', '## Limitations', [StringComparison]::Ordinal)
    Set-PackageReadmeContent -PackagePath $PackagePath -Content $missingContent
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
    Assert-Test ($exitCode -ne 0) 'The package inspector accepted a README missing the required limitations section.'
    Assert-Test ($output.Contains("Packed README is missing required content '## Important limitations'.", [StringComparison]::Ordinal)) "Missing README content was rejected without the expected diagnostic. Output: $output"
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
$wrongDescriptionPackage = Join-Path $testRoot 'wrong-description\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$relativeReadmePackage = Join-Path $testRoot 'relative-readme\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$wrongReadmeSourcePackage = Join-Path $testRoot 'wrong-readme-source\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
$missingReadmeContentPackage = Join-Path $testRoot 'missing-readme-content\KeelMatrix.BehaviorOracle.0.1.0.nupkg'
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
    New-Item -ItemType Directory -Path (Split-Path -Parent $wrongCopyrightPackage), (Split-Path -Parent $missingCopyrightPackage), (Split-Path -Parent $wrongDescriptionPackage), (Split-Path -Parent $relativeReadmePackage), (Split-Path -Parent $wrongReadmeSourcePackage), (Split-Path -Parent $missingReadmeContentPackage) -Force | Out-Null
    Copy-Item -LiteralPath $PackagePath -Destination $wrongCopyrightPackage
    Invoke-NegativeInspection -Mutation Wrong -PackagePath $wrongCopyrightPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $missingCopyrightPackage
    Invoke-NegativeInspection -Mutation Missing -PackagePath $missingCopyrightPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $wrongDescriptionPackage
    Invoke-DescriptionNegativeInspection -PackagePath $wrongDescriptionPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $relativeReadmePackage
    Invoke-ReadmeLinkNegativeInspection -PackagePath $relativeReadmePackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $wrongReadmeSourcePackage
    Invoke-ReadmeSourceNegativeInspection -PackagePath $wrongReadmeSourcePackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Copy-Item -LiteralPath $PackagePath -Destination $missingReadmeContentPackage
    Invoke-MissingReadmeContentNegativeInspection -PackagePath $missingReadmeContentPackage -SymbolsPath $SymbolsPath -InspectorPath $InspectorPath -ExpectedRepositoryCommit $ExpectedRepositoryCommit
    Write-Output 'Negative package inspection passed: unexpected entry, wrong/missing copyright metadata, mismatched description metadata, relative unpacked README links, wrong README source, and missing README content were rejected.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("Negative package inspection failed: $($_.Exception.Message)")
    exit 1
}
finally {
    Remove-TemporaryDirectory -Path $testRoot
}
