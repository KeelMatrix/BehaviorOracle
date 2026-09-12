[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('ExpectedTagVersion')]
    [string]$ExpectedVersion,

    [string]$ChangelogPath = 'CHANGELOG.md',

    [Alias('PackageVersion')]
    [string]$ExpectedPackageVersion,

    [Alias('ExpectedCommit')]
    [string]$ExpectedRepositoryCommit,

    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stableVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = (& git -C $Repository @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git -C $Repository $($Arguments -join ' '). Output: $output"
    }

    return $output
}

function Resolve-VersionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][hashtable]$KnownVersions,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $normalized = $Value.Trim()
    if ($normalized -match $stableVersionPattern) {
        return $normalized
    }

    $propertyReference = [regex]::Match($normalized, '^\$\((?<name>Version|VersionPrefix|PackageVersion)\)$')
    if ($propertyReference.Success) {
        $name = $propertyReference.Groups['name'].Value
        if ($KnownVersions.ContainsKey($name)) {
            return $KnownVersions[$name]
        }
    }

    throw "Unable to resolve package version declaration '$normalized' in $Source."
}

function Normalize-InstallVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim()
    if ($normalized.Length -ge 2) {
        $openingQuote = $normalized[0]
        $closingQuote = $normalized[$normalized.Length - 1]
        if ($openingQuote -in @([char]34, [char]39, [char]96) -and $closingQuote -eq $openingQuote) {
            $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
        }
    }

    return $normalized
}

function Get-ProjectMetadataFiles {
    param([Parameter(Mandatory = $true)][string]$Repository)

    return @(Get-ChildItem -LiteralPath $Repository -Recurse -File -Force -ErrorAction Stop |
        Where-Object {
            $_.Name -match '^(Directory\.Build\.(props|targets)|Directory\.Packages\.props|.*\.csproj)$' -and
            $_.FullName -notmatch '[\\/](?:\.git|bin|obj|artifacts)[\\/]'
        })
}

function Get-XmlDocument {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$File)

    try {
        return [xml](Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop)
    }
    catch {
        throw "Unable to parse project metadata file '$($File.FullName)': $($_.Exception.Message)"
    }
}

try {
    Assert-Contract ($ExpectedVersion -match $stableVersionPattern) "Expected release version '$ExpectedVersion' is not a stable X.Y.Z version."

    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageVersion)) {
        Assert-Contract ($ExpectedPackageVersion -match $stableVersionPattern) "Expected package version '$ExpectedPackageVersion' is not a stable X.Y.Z version."
        Assert-Contract ($ExpectedPackageVersion -ceq $ExpectedVersion) "Release/tag version '$ExpectedVersion' does not match expected package version '$ExpectedPackageVersion'."
    }

    $repository = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
    Assert-Contract (Test-Path -LiteralPath $repository -PathType Container) "Repository path is not a directory: $repository"

    $head = Invoke-Git -Repository $repository -Arguments @('rev-parse', '--verify', 'HEAD')
    Assert-Contract ($head -match '^[0-9a-fA-F]{40}$') "Repository HEAD '$head' is not a full Git SHA."
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
        Assert-Contract ($ExpectedRepositoryCommit -match '^[0-9a-fA-F]{40}$') "Expected repository commit '$ExpectedRepositoryCommit' is not a full Git SHA."
        Assert-Contract ($head -ceq $ExpectedRepositoryCommit) "The checked-out commit '$head' does not match expected release commit '$ExpectedRepositoryCommit'."
        $status = Invoke-Git -Repository $repository -Arguments @('status', '--porcelain')
        Assert-Contract ([string]::IsNullOrWhiteSpace($status)) 'The repository worktree is not clean; refusing to validate a different changelog than the exact commit being released.'
    }

    $changelogCandidate = if ([IO.Path]::IsPathRooted($ChangelogPath)) {
        $ChangelogPath
    }
    else {
        Join-Path $repository $ChangelogPath
    }
    $changelog = (Resolve-Path -LiteralPath $changelogCandidate -ErrorAction Stop).Path
    Assert-Contract (Test-Path -LiteralPath $changelog -PathType Leaf) "Changelog file was not found: $changelog"

    $relativeChangelog = [IO.Path]::GetRelativePath($repository, $changelog).Replace('\', '/')
    Assert-Contract ($relativeChangelog -ne '..' -and -not $relativeChangelog.StartsWith('../', [StringComparison]::Ordinal)) "Changelog '$ChangelogPath' is outside repository '$repository'."
    [void](Invoke-Git -Repository $repository -Arguments @('ls-files', '--error-unmatch', '--', $relativeChangelog))

    $changelogText = Get-Content -LiteralPath $changelog -Raw -ErrorAction Stop
    $headingMatches = [regex]::Matches($changelogText, '(?m)^(?<hash>#{1,6})[ \t]+(?<title>[^\r\n]+?)[ \t]*\r?$')
    $headings = [Collections.Generic.List[object]]::new()
    foreach ($headingMatch in $headingMatches) {
        $headings.Add([pscustomobject]@{
                Index = $headingMatch.Index
                Level = $headingMatch.Groups['hash'].Value.Length
                Title = $headingMatch.Groups['title'].Value.Trim()
            })
    }

    $escapedVersion = [regex]::Escape($ExpectedVersion)
    $targetHeadings = @($headings | Where-Object {
            [regex]::IsMatch($_.Title, "^\[$escapedVersion\](?:[ \t]*-[ \t]*(?<date>.*))?$", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        })
    Assert-Contract ($targetHeadings.Count -eq 1) "Expected exactly one changelog entry for release version '$ExpectedVersion'; found $($targetHeadings.Count)."
    $targetHeading = $targetHeadings[0]

    $targetHeadingMatch = [regex]::Match($targetHeading.Title, "^\[$escapedVersion\](?:[ \t]*-[ \t]*(?<date>.*))?$", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $dateText = if ($targetHeadingMatch.Groups['date'].Success) { $targetHeadingMatch.Groups['date'].Value.Trim() } else { '' }
    $preReleasePattern = '(?i)\b(planned|unreleased|not[ \t]+yet[ \t]+published|not[ \t]+published|tbd|to[ \t]+be[ \t]+determined|forthcoming|draft|pre[ -]?release)\b'
    Assert-Contract (-not [regex]::IsMatch($targetHeading.Title, $preReleasePattern)) "Changelog entry '$ExpectedVersion' is still marked as planned, unreleased, or otherwise pre-release."

    $parentHeading = @($headings | Where-Object { $_.Index -lt $targetHeading.Index -and $_.Level -lt $targetHeading.Level } | Select-Object -Last 1)
    if ($parentHeading.Count -eq 1) {
        Assert-Contract (-not [regex]::IsMatch($parentHeading[0].Title, '(?i)^\[?unreleased\]?')) "Changelog entry '$ExpectedVersion' is nested inside an Unreleased section."
    }

    $dateMatch = [regex]::Match($dateText, '(?<![0-9])(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9])')
    Assert-Contract ($dateMatch.Success) "Changelog entry '$ExpectedVersion' must contain a release date in yyyy-MM-dd form; found '$dateText'."
    [DateTime]$releaseDate = [DateTime]::MinValue
    $parsedDate = [DateTime]::TryParseExact(
        $dateMatch.Groups['date'].Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$releaseDate)
    Assert-Contract $parsedDate "Changelog entry '$ExpectedVersion' has an invalid release date '$($dateMatch.Groups['date'].Value)'."
    Assert-Contract ($releaseDate.Date -le [DateTime]::UtcNow.Date) "Changelog entry '$ExpectedVersion' is dated later than the current UTC date."
    Assert-Contract (-not [regex]::IsMatch($dateText, '(?i)\b(yyyy|mm|dd|tbd|unknown|placeholder)\b')) "Changelog entry '$ExpectedVersion' uses a placeholder release date '$dateText'."

    $metadataFiles = @(Get-ProjectMetadataFiles -Repository $repository)
    $metadataNodes = [Collections.Generic.List[object]]::new()
    foreach ($metadataFile in $metadataFiles) {
        $xml = Get-XmlDocument -File $metadataFile
        foreach ($node in @($xml.SelectNodes('//*[local-name()="Version" or local-name()="PackageVersion" or local-name()="VersionPrefix"]'))) {
            if ($null -ne $node.Attributes['Include']) {
                continue
            }

            $metadataNodes.Add([pscustomobject]@{
                    File = $metadataFile.FullName
                    Name = $node.LocalName
                    Value = ([string]$node.InnerText).Trim()
                })
        }
    }

    $knownVersions = @{}
    foreach ($node in $metadataNodes | Where-Object { $_.Value -match $stableVersionPattern }) {
        if (-not $knownVersions.ContainsKey($node.Name)) {
            $knownVersions[$node.Name] = $node.Value
        }
        elseif ($knownVersions[$node.Name] -cne $node.Value) {
            throw "Repository declares conflicting $($node.Name) values '$($knownVersions[$node.Name])' and '$($node.Value)'."
        }
    }

    $declaredPackageVersions = [Collections.Generic.List[object]]::new()
    foreach ($node in $metadataNodes) {
        $resolved = Resolve-VersionValue -Value $node.Value -KnownVersions $knownVersions -Source "$($node.File) <$($node.Name)>"
        $declaredPackageVersions.Add([pscustomobject]@{ Version = $resolved; Source = $node.File; Name = $node.Name })
    }
    $uniquePackageVersions = @($declaredPackageVersions | Select-Object -ExpandProperty Version -Unique)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageVersion)) {
        Assert-Contract ($uniquePackageVersions.Count -gt 0) 'An expected package version was supplied, but no repository-declared package version was found.'
    }
    foreach ($declared in $declaredPackageVersions) {
        Assert-Contract ($declared.Version -ceq $ExpectedVersion) "Repository package version '$($declared.Version)' in '$($declared.Source)' does not match release/tag version '$ExpectedVersion'."
    }

    $centralDependencyVersions = @{}
    foreach ($metadataFile in $metadataFiles) {
        $xml = Get-XmlDocument -File $metadataFile
        foreach ($node in @($xml.SelectNodes('//*[local-name()="PackageVersion"]'))) {
            $include = if ($null -ne $node.Attributes['Include']) { $node.Attributes['Include'].Value } else { '' }
            $version = if ($null -ne $node.Attributes['Version']) { $node.Attributes['Version'].Value.Trim() } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($include) -and -not [string]::IsNullOrWhiteSpace($version)) {
                $centralDependencyVersions[$include] = $version
            }
        }
    }

    $checkedDependencies = @{}
    foreach ($metadataFile in $metadataFiles) {
        $xml = Get-XmlDocument -File $metadataFile
        foreach ($node in @($xml.SelectNodes('//*[local-name()="PackageVersion" or local-name()="PackageReference"]'))) {
            $include = if ($null -ne $node.Attributes['Include']) { $node.Attributes['Include'].Value } else { '' }
            if ($include -notmatch '^KeelMatrix\.') {
                continue
            }

            $version = if ($null -ne $node.Attributes['Version']) { $node.Attributes['Version'].Value.Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($version) -and $centralDependencyVersions.ContainsKey($include)) {
                $version = $centralDependencyVersions[$include]
            }
            Assert-Contract ($version -match $stableVersionPattern) "Unable to resolve KeelMatrix dependency version for '$include' in '$($metadataFile.FullName)'."
            if (-not $checkedDependencies.ContainsKey($include)) {
                $checkedDependencies[$include] = $version
            }
            else {
                Assert-Contract ($checkedDependencies[$include] -ceq $version) "Repository declares conflicting versions for KeelMatrix dependency '$include'."
            }
        }
    }
    foreach ($dependency in $checkedDependencies.GetEnumerator()) {
        Assert-Contract ($dependency.Value -ceq $ExpectedVersion) "KeelMatrix dependency '$($dependency.Key)' uses version '$($dependency.Value)' instead of release/tag version '$ExpectedVersion'."
    }

    $documentationFiles = @(Get-ChildItem -LiteralPath $repository -Recurse -File -Force -ErrorAction Stop |
        Where-Object {
            $_.Extension -ieq '.md' -and
            $_.FullName -notmatch '[\\/](?:\.git|bin|obj|artifacts)[\\/]'
        })
    $installVersionPatterns = @(
        '(?im)\bdotnet\s+(?:tool\s+install|add\s+package)\b[^\r\n]*?--version(?:\s+|=)(?<version>"[^"\r\n]*"|''[^''\r\n]*''|`[^`\r\n]*`|[^\s"''`<>]+)',
        '(?im)\bdotnet\s+(?:tool\s+install|add\s+package)\b[^\r\n]*(?:(?:\\|`)[ \t]*)?\r?\n[ \t]*--version(?:\s+|=)(?<version>"[^"\r\n]*"|''[^''\r\n]*''|`[^`\r\n]*`|[^\s"''`<>]+)'
    )
    foreach ($documentationFile in $documentationFiles) {
        $documentationText = [IO.File]::ReadAllText($documentationFile.FullName)
        foreach ($installVersionPattern in $installVersionPatterns) {
            foreach ($match in [Text.RegularExpressions.Regex]::Matches($documentationText, $installVersionPattern)) {
                $installVersion = Normalize-InstallVersion $match.Groups['version'].Value
                Assert-Contract ($installVersion -ceq $ExpectedVersion) "Install example in '$($documentationFile.FullName)' uses version '$installVersion' instead of release/tag version '$ExpectedVersion'."
            }
        }
    }

    Write-Output "Changelog/version contract passed for $ExpectedVersion at commit $head."
    exit 0
}
catch {
    Write-Error "Changelog/version contract failed: $($_.Exception.Message)"
    exit 1
}
