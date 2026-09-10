[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$SymbolsPath,

    [string]$ExpectedRepositoryCommit,

    [string]$ExpectedVersion = '0.1.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
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

function Get-CanonicalArchiveHash {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $parts = [Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in @($archive.Entries | Sort-Object FullName)) {
            $name = $entry.FullName.Replace('\\', '/')
            $canonicalName = [regex]::Replace($name, '(?i)(?<=core-properties/)[0-9a-f]{32}(?=\.psmdcp$)', '{core-properties-id}')
            $memory = [IO.MemoryStream]::new()
            $stream = $entry.Open()
            try {
                $stream.CopyTo($memory)
                $bytes = $memory.ToArray()
            }
            finally {
                $stream.Dispose()
                $memory.Dispose()
            }

            if ($name -eq '_rels/.rels') {
                $relationships = [Text.Encoding]::UTF8.GetString($bytes)
                $relationships = [regex]::Replace($relationships, '(?i)(?<=Target="/package/services/metadata/core-properties/)[0-9a-f]{32}(?=\.psmdcp")', '{core-properties-id}')
                $relationships = [regex]::Replace($relationships, '(?i)(?<=Id=")R[0-9A-F]+(?=")', '{relationship-id}')
                $bytes = [Text.Encoding]::UTF8.GetBytes($relationships)
            }

            $entryHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object ToString x2) -join ''
            $parts.Add("$canonicalName=$entryHash")
        }

        $payload = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
        return ([Security.Cryptography.SHA256]::Create().ComputeHash($payload) | ForEach-Object ToString x2) -join ''
    }
    finally {
        $archive.Dispose()
    }
}

$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj'
$verificationRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-package-contract-$([Guid]::NewGuid().ToString('N'))"
$firstPack = Join-Path $verificationRoot 'first'
$secondPack = Join-Path $verificationRoot 'second'
$inspector = Join-Path $PSScriptRoot 'Inspect-Package.ps1'
$negativeTest = Join-Path $PSScriptRoot 'Test-PackageInspection.ps1'

try {
    Assert-Contract (Test-Path -LiteralPath $PackagePath -PathType Leaf) "Tool package was not found: $PackagePath"
    Assert-Contract (Test-Path -LiteralPath $SymbolsPath -PathType Leaf) "Symbol package was not found: $SymbolsPath"
    New-Item -ItemType Directory -Path $firstPack, $secondPack -Force | Out-Null

    $packArguments = @(
        'pack', $project,
        '--configuration', 'Release',
        '--no-build',
        '--no-restore',
        '--include-symbols',
        '-p:SymbolPackageFormat=snupkg',
        "-p:PackageVersion=$ExpectedVersion"
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        $packArguments += @(
            "-p:SourceRevisionId=$ExpectedRepositoryCommit",
            "-p:RepositoryCommit=$ExpectedRepositoryCommit"
        )
    }
    Invoke-Checked 'dotnet' ($packArguments + @('--output', $firstPack))
    Invoke-Checked 'dotnet' ($packArguments + @('--output', $secondPack))

    $expectedNames = @(
        "KeelMatrix.BehaviorOracle.$ExpectedVersion.nupkg",
        "KeelMatrix.BehaviorOracle.$ExpectedVersion.snupkg"
    ) | Sort-Object
    $firstNames = @(Get-ChildItem -LiteralPath $firstPack -File | Select-Object -ExpandProperty Name | Sort-Object)
    $secondNames = @(Get-ChildItem -LiteralPath $secondPack -File | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Contract (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $firstNames).Count -eq 0) "First repeat pack produced an unexpected file set: $($firstNames -join ', ')."
    Assert-Contract (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $secondNames).Count -eq 0) "Second repeat pack produced an unexpected file set: $($secondNames -join ', ')."

    foreach ($name in $expectedNames) {
        $firstHash = Get-CanonicalArchiveHash -ArchivePath (Join-Path $firstPack $name)
        $secondHash = Get-CanonicalArchiveHash -ArchivePath (Join-Path $secondPack $name)
        Assert-Contract ($firstHash -ceq $secondHash) "Repeat pack was not deterministic for '$name' after canonicalizing only NuGet-generated core-properties identifiers."
    }

    $candidateHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    $candidateCanonicalHash = Get-CanonicalArchiveHash -ArchivePath $PackagePath
    $repeatHash = Get-CanonicalArchiveHash -ArchivePath (Join-Path $firstPack "KeelMatrix.BehaviorOracle.$ExpectedVersion.nupkg")
    $candidateSymbolsHash = (Get-FileHash -LiteralPath $SymbolsPath -Algorithm SHA256).Hash
    $candidateSymbolsCanonicalHash = Get-CanonicalArchiveHash -ArchivePath $SymbolsPath
    $repeatSymbolsHash = Get-CanonicalArchiveHash -ArchivePath (Join-Path $firstPack "KeelMatrix.BehaviorOracle.$ExpectedVersion.snupkg")
    Assert-Contract ($candidateCanonicalHash -ceq $repeatHash) 'The candidate tool package differs from the deterministic repeat pack after canonicalizing only NuGet-generated core-properties identifiers.'
    Assert-Contract ($candidateSymbolsCanonicalHash -ceq $repeatSymbolsHash) 'The candidate symbol package differs from the deterministic repeat pack after canonicalizing only NuGet-generated core-properties identifiers.'

    $inspectionArguments = @(
        '-NoProfile',
        '-File', $inspector,
        '-PackagePath', $PackagePath,
        '-SymbolsPath', $SymbolsPath,
        '-ExpectedVersion', $ExpectedVersion
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        $inspectionArguments += @('-ExpectedRepositoryCommit', $ExpectedRepositoryCommit)
    }
    Invoke-Checked 'pwsh' $inspectionArguments

    $negativeArguments = @(
        '-NoProfile',
        '-File', $negativeTest,
        '-PackagePath', $PackagePath,
        '-SymbolsPath', $SymbolsPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        $negativeArguments += @('-ExpectedRepositoryCommit', $ExpectedRepositoryCommit)
    }
    Invoke-Checked 'pwsh' $negativeArguments

    Write-Output "Repeat-pack determinism passed for version $ExpectedVersion."
    Write-Output "Tool package SHA256: $candidateHash"
    Write-Output "Tool package canonical repeat hash: $candidateCanonicalHash"
    Write-Output "Symbol package SHA256: $candidateSymbolsHash"
    Write-Output "Symbol package canonical repeat hash: $candidateSymbolsCanonicalHash"
    exit 0
}
catch {
    [Console]::Error.WriteLine("Package contract verification failed: $($_.Exception.Message)")
    exit 1
}
finally {
    if (Test-Path -LiteralPath $verificationRoot) {
        Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
