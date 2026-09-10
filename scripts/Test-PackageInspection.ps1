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

$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InspectorPath)) {
    $InspectorPath = Join-Path $PSScriptRoot 'Inspect-Package.ps1'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-package-inspection-$([Guid]::NewGuid().ToString('N'))"
$mutatedPackage = Join-Path $testRoot 'KeelMatrix.BehaviorOracle.0.1.0.nupkg'
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
    Write-Output 'Negative package inspection passed: unexpected archive entry was rejected.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("Negative package inspection failed: $($_.Exception.Message)")
    exit 1
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
