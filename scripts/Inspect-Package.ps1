[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$SymbolsPath,

    [string]$ExpectedVersion = '0.1.0',

    [string]$ExpectedRepositoryCommit,

    [string]$ExpectedRepositoryUrl = 'https://github.com/KeelMatrix/BehaviorOracle',

    [string]$ExpectedIconPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$packageId = 'KeelMatrix.BehaviorOracle'
$toolCommand = 'behavior-oracle'
$description = 'Compare two .NET library builds with deterministic scenarios and receive a minimized witness when stable behavior diverges.'
$tags = 'dotnet compatibility semantic-versioning regression-testing differential-testing testing nuget ci dotnet-tool'
$dependencyId = 'KeelMatrix.Telemetry'
$dependencyVersion = '0.1.0'
$targetFramework = 'net8.0'
$packageNamespace = 'http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd'

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-ExpectedCommit {
    param([string]$Commit)

    if (-not [string]::IsNullOrWhiteSpace($Commit)) {
        $normalized = $Commit.Trim().ToLowerInvariant()
        Assert-Contract ($normalized -match '^[0-9a-f]{40}$') "Expected repository commit '$Commit' is not a 40-character Git SHA."
        return $normalized
    }

    $repo = Split-Path -Parent $PSScriptRoot
    $resolved = (& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim()
    Assert-Contract ($LASTEXITCODE -eq 0 -and $resolved -match '^[0-9a-fA-F]{40}$') 'Unable to resolve the expected repository commit.'
    return $resolved.ToLowerInvariant()
}

function Read-ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $matches = @($Archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $Name })
    Assert-Contract ($matches.Count -eq 1) "Archive entry '$Name' must exist exactly once."

    $entry = $matches[0]
    $stream = $entry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return (,([byte[]]$memory.ToArray()))
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Read-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $bytes = Read-ZipEntryBytes -Archive $Archive -Name $Name
    return ([Text.Encoding]::UTF8.GetString($bytes)).TrimStart([char]0xFEFF)
}

function Read-XmlEntry {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.LoadXml((Read-ZipEntryText -Archive $Archive -Name $Name))
    return $document
}

function Get-MetadataText {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][string]$XPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $namespace.AddNamespace('n', $packageNamespace)
    $node = $Document.SelectSingleNode($XPath, $namespace)
    Assert-Contract ($null -ne $node) "Package metadata is missing $Description."
    return $node.InnerText
}

function Get-MetadataNode {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][string]$XPath
    )

    $namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $namespace.AddNamespace('n', $packageNamespace)
    return $Document.SelectSingleNode($XPath, $namespace)
}

function Assert-ArchiveEntries {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string[]]$Allowlist,
        [Parameter(Mandatory = $true)][string]$ArchiveDescription
    )

    $names = @($Archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    $duplicates = @($names | Group-Object -CaseSensitive | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        $duplicateNames = @($duplicates | ForEach-Object Name) -join ', '
        throw "$ArchiveDescription contains duplicate archive entries: $duplicateNames."
    }

    foreach ($name in $names) {
        $allowed = $false
        foreach ($pattern in $Allowlist) {
            if ($name -cmatch $pattern) {
                $allowed = $true
                break
            }
        }

        Assert-Contract $allowed "$ArchiveDescription contains unexpected archive entry '$name'."
    }
}

function Assert-RequiredEntries {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$ArchiveDescription
    )

    foreach ($name in $Names) {
        $entry = @($Archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $name })
        Assert-Contract ($entry.Count -eq 1 -and $entry[0].Length -gt 0) "$ArchiveDescription is missing non-empty required entry '$name'."
    }
}

function Assert-CommonMetadata {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][bool]$ToolPackage,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    $id = Get-MetadataText -Document $Document -XPath '/n:package/n:metadata/n:id' -Description 'the package ID'
    $version = Get-MetadataText -Document $Document -XPath '/n:package/n:metadata/n:version' -Description 'the package version'
    Assert-Contract ($id -ceq $packageId) "Package ID '$id' does not equal '$packageId'."
    Assert-Contract ($version -ceq $ExpectedVersion) "Package version '$version' does not equal '$ExpectedVersion'."

    $repository = Get-MetadataNode -Document $Document -XPath '/n:package/n:metadata/n:repository'
    Assert-Contract ($null -ne $repository) 'Package metadata is missing repository information.'
    Assert-Contract ($repository.GetAttribute('type') -ceq 'git') 'Package repository type must be git.'
    Assert-Contract ($repository.GetAttribute('url') -ceq $ExpectedRepositoryUrl) "Package repository URL is not '$ExpectedRepositoryUrl'."
    Assert-Contract ($repository.GetAttribute('commit') -ceq $ExpectedCommit) "Package repository commit does not equal '$ExpectedCommit'."

    $projectUrl = Get-MetadataText -Document $Document -XPath '/n:package/n:metadata/n:projectUrl' -Description 'the project URL'
    Assert-Contract ($projectUrl -ceq "$ExpectedRepositoryUrl#readme") 'Package project URL is incorrect.'

    $actualTags = (Get-MetadataText -Document $Document -XPath '/n:package/n:metadata/n:tags' -Description 'the package tags').Trim()
    Assert-Contract ($actualTags -ceq $tags) 'Package tags are incorrect.'
    $actualDescription = Get-MetadataText -Document $Document -XPath '/n:package/n:metadata/n:description' -Description 'the package description'
    Assert-Contract ($actualDescription -ceq $description) 'Package description is incorrect.'

    $packageTypes = @(Get-MetadataNode -Document $Document -XPath '/n:package/n:metadata/n:packageTypes/n:packageType')
    Assert-Contract ($packageTypes.Count -eq 1) 'Package type metadata must contain exactly one package type.'
    $expectedType = if ($ToolPackage) { 'DotnetTool' } else { 'SymbolsPackage' }
    Assert-Contract ($packageTypes[0].GetAttribute('name') -ceq $expectedType) "Package type must be '$expectedType'."
}

function Assert-DependencyContract {
    param([Parameter(Mandatory = $true)][Xml.XmlDocument]$Document)

    $groups = @(Get-MetadataNode -Document $Document -XPath '/n:package/n:metadata/n:dependencies/n:group')
    Assert-Contract ($groups.Count -eq 1) 'The package must contain exactly one dependency group.'
    Assert-Contract ($groups[0].GetAttribute('targetFramework') -ceq $targetFramework) "Dependency group target framework must be '$targetFramework'."

    $namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $namespace.AddNamespace('n', $packageNamespace)
    $dependencies = @($groups[0].SelectNodes('n:dependency', $namespace))
    Assert-Contract ($dependencies.Count -eq 1) 'The package must contain exactly one runtime dependency.'
    Assert-Contract ($dependencies[0].GetAttribute('id') -ceq $dependencyId) "Runtime dependency must be '$dependencyId'."
    Assert-Contract ($dependencies[0].GetAttribute('version') -ceq $dependencyVersion) "Runtime dependency range must be '$dependencyVersion'."
    Assert-Contract ($dependencies[0].GetAttribute('exclude') -ceq 'Build,Analyzers') 'Runtime dependency exclusions are incorrect.'
}

function Assert-PngContract {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ExpectedIconFile
    )

    Assert-Contract ($Bytes.Length -le 200000) "$Description must be no larger than 200 KB."
    Assert-Contract ($Bytes.Length -ge 24) "$Description is not a complete PNG."
    $signature = @(137, 80, 78, 71, 13, 10, 26, 10)
    for ($index = 0; $index -lt $signature.Count; $index++) {
        Assert-Contract ($Bytes[$index] -eq $signature[$index]) "$Description is not a PNG image."
    }

    $width = ([long]$Bytes[16] * 16777216) + ([long]$Bytes[17] * 65536) + ([long]$Bytes[18] * 256) + $Bytes[19]
    $height = ([long]$Bytes[20] * 16777216) + ([long]$Bytes[21] * 65536) + ([long]$Bytes[22] * 256) + $Bytes[23]
    Assert-Contract ($width -eq 512 -and $height -eq 512) "$Description must be exactly 512x512 (was ${width}x${height})."

    Assert-Contract (Test-Path -LiteralPath $ExpectedIconFile -PathType Leaf) "Expected icon file was not found: $ExpectedIconFile"
    $expectedHash = (Get-FileHash -LiteralPath $ExpectedIconFile -Algorithm SHA256).Hash
    $actualHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes) | ForEach-Object ToString x2) -join ''
    Assert-Contract ($actualHash -ieq $expectedHash) 'The package icon does not match the repository icon.'
}

function Assert-SourceLinkContract {
    param(
        [Parameter(Mandatory = $true)][byte[]]$PdbBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedRepositoryCommit
    )

    $pdbText = [Text.Encoding]::UTF8.GetString($PdbBytes)
    $sourceLinkPrefix = "https://raw.githubusercontent.com/KeelMatrix/BehaviorOracle/$ExpectedRepositoryCommit/"
    Assert-Contract ($pdbText.Contains($sourceLinkPrefix, [StringComparison]::Ordinal)) "Portable PDB does not contain SourceLink data for commit '$ExpectedRepositoryCommit'."
}

function Assert-NuspecContract {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][bool]$ToolPackage,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $nuspec = Read-XmlEntry -Archive $archive -Name "$packageId.nuspec"
        Assert-CommonMetadata -Document $nuspec -ToolPackage $ToolPackage -ExpectedCommit $ExpectedCommit

        if ($ToolPackage) {
            $authors = Get-MetadataText -Document $nuspec -XPath '/n:package/n:metadata/n:authors' -Description 'the authors'
            Assert-Contract ($authors -ceq 'KeelMatrix') 'Package authors are incorrect.'
            $license = Get-MetadataNode -Document $nuspec -XPath '/n:package/n:metadata/n:license'
            Assert-Contract ($null -ne $license -and $license.GetAttribute('type') -ceq 'file' -and $license.InnerText -ceq 'LICENSE') 'Package license metadata must reference LICENSE.'
            Assert-Contract ((Get-MetadataText -Document $nuspec -XPath '/n:package/n:metadata/n:readme' -Description 'the README') -ceq 'README.md') 'Package README metadata must reference README.md.'
            Assert-Contract ((Get-MetadataText -Document $nuspec -XPath '/n:package/n:metadata/n:icon' -Description 'the icon') -ceq 'icon.png') 'Package icon metadata must reference icon.png.'
            Assert-DependencyContract -Document $nuspec
        }
        else {
            Assert-Contract ((Get-MetadataText -Document $nuspec -XPath '/n:package/n:metadata/n:description' -Description 'the symbol description') -ceq $Description) 'Symbol package description is incorrect.'
            Assert-DependencyContract -Document $nuspec
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Inspect-Nupkg {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$IconPath
    )

    Assert-Contract ([IO.Path]::GetFileName($ArchivePath) -ceq "$packageId.$ExpectedVersion.nupkg") 'The tool package filename is incorrect.'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        Assert-ArchiveEntries -Archive $archive -ArchiveDescription 'The tool package' -Allowlist @(
            '^_rels/\.rels$',
            '^\[Content_Types\]\.xml$',
            "^$packageId\.nuspec$",
            '^README\.md$',
            '^LICENSE$',
            '^icon\.png$',
            '^tools/net8\.0/any/DotnetToolSettings\.xml$',
            "^tools/net8\.0/any/$packageId\.dll$",
            "^tools/net8\.0/any/$packageId\.runtimeconfig\.json$",
            "^tools/net8\.0/any/$packageId\.pdb$",
            '^tools/net8\.0/any/KeelMatrix\.Telemetry\.dll$',
            "^tools/net8\.0/any/$packageId\.deps\.json$",
            '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$',
            '^\.signature\.p7s$'
        )
        Assert-RequiredEntries -Archive $archive -ArchiveDescription 'The tool package' -Names @(
            '_rels/.rels',
            '[Content_Types].xml',
            "$packageId.nuspec",
            'README.md',
            'LICENSE',
            'icon.png',
            'tools/net8.0/any/DotnetToolSettings.xml',
            "tools/net8.0/any/$packageId.dll",
            "tools/net8.0/any/$packageId.runtimeconfig.json",
            "tools/net8.0/any/$packageId.pdb",
            'tools/net8.0/any/KeelMatrix.Telemetry.dll',
            "tools/net8.0/any/$packageId.deps.json"
        )

        $metadataEntries = @($archive.Entries | Where-Object { $_.FullName -match '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$' })
        Assert-Contract ($metadataEntries.Count -eq 1) 'The tool package must contain exactly one NuGet core-properties metadata entry.'

        $nuspec = Read-XmlEntry -Archive $archive -Name "$packageId.nuspec"
        Assert-CommonMetadata -Document $nuspec -ToolPackage $true -ExpectedCommit $ExpectedCommit
        Assert-DependencyContract -Document $nuspec

        $toolSettings = Read-XmlEntry -Archive $archive -Name 'tools/net8.0/any/DotnetToolSettings.xml'
        $command = $toolSettings.SelectSingleNode('/DotNetCliTool/Commands/Command[@Name="behavior-oracle"]')
        Assert-Contract ($null -ne $command) "Tool command '$toolCommand' is missing from DotnetToolSettings.xml."
        Assert-Contract ($command.GetAttribute('EntryPoint') -ceq "$packageId.dll" -and $command.GetAttribute('Runner') -ceq 'dotnet') 'DotnetToolSettings.xml has an incorrect command entry point.'

        $icon = Read-ZipEntryBytes -Archive $archive -Name 'icon.png'
        Assert-PngContract -Bytes $icon -Description 'Package icon' -ExpectedIconFile $IconPath
        return Read-ZipEntryBytes -Archive $archive -Name "tools/net8.0/any/$packageId.pdb"
    }
    finally {
        $archive.Dispose()
    }
}

function Inspect-Snupkg {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    Assert-Contract ([IO.Path]::GetFileName($ArchivePath) -ceq "$packageId.$ExpectedVersion.snupkg") 'The symbol package filename is incorrect.'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        Assert-ArchiveEntries -Archive $archive -ArchiveDescription 'The symbol package' -Allowlist @(
            '^_rels/\.rels$',
            '^\[Content_Types\]\.xml$',
            "^$packageId\.nuspec$",
            "^tools/net8\.0/any/$packageId\.pdb$",
            '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$',
            '^\.signature\.p7s$'
        )
        Assert-RequiredEntries -Archive $archive -ArchiveDescription 'The symbol package' -Names @(
            '_rels/.rels',
            '[Content_Types].xml',
            "$packageId.nuspec",
            "tools/net8.0/any/$packageId.pdb"
        )

        $metadataEntries = @($archive.Entries | Where-Object { $_.FullName -match '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$' })
        Assert-Contract ($metadataEntries.Count -eq 1) 'The symbol package must contain exactly one NuGet core-properties metadata entry.'
        Assert-NuspecContract -ArchivePath $ArchivePath -ToolPackage $false -ExpectedCommit $ExpectedCommit -Description $description
        return Read-ZipEntryBytes -Archive $archive -Name "tools/net8.0/any/$packageId.pdb"
    }
    finally {
        $archive.Dispose()
    }
}

try {
    $expectedCommit = Get-ExpectedCommit -Commit $ExpectedRepositoryCommit
    $repo = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($ExpectedIconPath)) {
        $ExpectedIconPath = Join-Path $repo 'icon.png'
    }

    Assert-Contract (Test-Path -LiteralPath $PackagePath -PathType Leaf) "Tool package was not found: $PackagePath"
    Assert-Contract (Test-Path -LiteralPath $SymbolsPath -PathType Leaf) "Symbol package was not found: $SymbolsPath"

    $nupkgPdb = Inspect-Nupkg -ArchivePath $PackagePath -ExpectedCommit $expectedCommit -IconPath $ExpectedIconPath
    $snupkgPdb = Inspect-Snupkg -ArchivePath $SymbolsPath -ExpectedCommit $expectedCommit
    $nupkgPdbHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($nupkgPdb) | ForEach-Object ToString x2) -join ''
    $snupkgPdbHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($snupkgPdb) | ForEach-Object ToString x2) -join ''
    Assert-Contract ($nupkgPdbHash -ceq $snupkgPdbHash) 'The symbol package PDB does not match the tool package PDB.'
    Assert-SourceLinkContract -PdbBytes $nupkgPdb -ExpectedRepositoryCommit $expectedCommit

    $packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    $symbolsHash = (Get-FileHash -LiteralPath $SymbolsPath -Algorithm SHA256).Hash
    Write-Output "Package inspection passed: $([IO.Path]::GetFileName($PackagePath)) SHA256=$packageHash"
    Write-Output "Symbol inspection passed: $([IO.Path]::GetFileName($SymbolsPath)) SHA256=$symbolsHash"
    Write-Output "SourceLink commit verified: $expectedCommit"
    exit 0
}
catch {
    [Console]::Error.WriteLine("Package inspection failed: $($_.Exception.Message)")
    exit 1
}
