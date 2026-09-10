[CmdletBinding()]
param(
    [long]$Seed = 12345,
    [int]$ScenarioBudget = 20,
    [int]$ConfirmationRuns = 2,
    [string]$PackagePath,
    [string]$SymbolsPath,
    [string]$ExpectedRepositoryCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Get-RepositoryCommit {
    param([string]$Commit)
    if (-not [string]::IsNullOrWhiteSpace($Commit)) {
        return $Commit.Trim().ToLowerInvariant()
    }

    $repoCommit = (& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $repoCommit -match '^[0-9a-fA-F]{40}$') 'Unable to resolve the repository commit for package verification.'
    return $repoCommit.ToLowerInvariant()
}

function Invoke-Tool {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = (& $toolPath @Arguments 2>&1 | Out-String).TrimEnd()
    [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Get-ByteHash {
    param([byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-ArchivePayloadHash {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $parts = [Collections.Generic.List[string]]::new()
        $entries = @($archive.Entries |
            Where-Object { $_.FullName.Replace('\', '/') -like 'tools/net8.0/any/*' -and -not $_.FullName.EndsWith('/') } |
            Sort-Object FullName)
        Assert-True ($entries.Count -gt 0) 'The package archive has no runtime payload entries.'
        foreach ($entry in $entries) {
            $stream = $entry.Open()
            $memory = [IO.MemoryStream]::new()
            try {
                $stream.CopyTo($memory)
                $relativeName = $entry.FullName.Replace('\', '/')
                [void]$parts.Add("$relativeName=$((Get-ByteHash -Bytes $memory.ToArray()))")
            }
            finally {
                $memory.Dispose()
                $stream.Dispose()
            }
        }
        return Get-ByteHash -Bytes ([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DirectoryPayloadHash {
    param([Parameter(Mandatory = $true)][string]$PayloadRoot)

    $parts = [Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File | Sort-Object FullName)
    Assert-True ($files.Count -gt 0) "The installed tool payload is empty: $PayloadRoot"
    foreach ($file in $files) {
        $relativeName = $file.FullName.Substring($PayloadRoot.Length).TrimStart('\', '/')
        $relativeName = "tools/net8.0/any/$($relativeName.Replace('\', '/'))"
        [void]$parts.Add("$relativeName=$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)")
    }
    return Get-ByteHash -Bytes ([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
}

function Resolve-InstalledPayloadRoot {
    $knownRoot = Join-Path $installRoot '.store\keelmatrix.behaviororacle\0.1.0\keelmatrix.behaviororacle\0.1.0\tools\net8.0\any'
    if (Test-Path -LiteralPath $knownRoot -PathType Container) {
        return $knownRoot
    }

    $roots = @(Get-ChildItem -LiteralPath $installRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\.store[\\/]keelmatrix\.behaviororacle[\\/]0\.1\.0[\\/].*[\\/]tools[\\/]net8\.0[\\/]any$' })
    Assert-True ($roots.Count -eq 1) 'Unable to resolve the freshly installed tool payload directory.'
    return $roots[0].FullName
}

$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj'
$solution = Join-Path $repo 'KeelMatrix.BehaviorOracle.sln'
$baselineProject = Join-Path $repo 'bench/corpus/baseline/Baseline.csproj'
$candidateProject = Join-Path $repo 'bench/corpus/candidate/Candidate.csproj'
$baselineBuild = Join-Path $repo 'bench/corpus/baseline/bin/Release/net8.0'
$candidateBuild = Join-Path $repo 'bench/corpus/candidate/bin/Release/net8.0'
$inspectionScript = Join-Path $PSScriptRoot 'Inspect-Package.ps1'
$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-package-smoke-$([Guid]::NewGuid().ToString('N'))"
$packageFeed = Join-Path $smokeRoot 'packages'
$installRoot = Join-Path $smokeRoot 'install'
$baselineOutput = Join-Path $smokeRoot 'baseline'
$candidateOutput = Join-Path $smokeRoot 'candidate'
$reportRoot = Join-Path $smokeRoot 'reports'
$config = Join-Path $smokeRoot 'oracle.json'
$nugetConfig = Join-Path $smokeRoot 'NuGet.config'
$nugetPackages = Join-Path $smokeRoot 'nuget-packages'
$httpCache = Join-Path $smokeRoot 'nuget-http-cache'
$pluginsCache = Join-Path $smokeRoot 'nuget-plugins-cache'
$dotnetHome = Join-Path $smokeRoot 'dotnet-home'
$toolPath = $null
$version = '0.1.0'
$nupkgName = "KeelMatrix.BehaviorOracle.$version.nupkg"
$snupkgName = "KeelMatrix.BehaviorOracle.$version.snupkg"
$oldTelemetryOptOut = [Environment]::GetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY', 'Process')
$savedEnvironment = @{}

try {
    New-Item -ItemType Directory -Path $packageFeed, $installRoot, $baselineOutput, $candidateOutput, $reportRoot, $nugetPackages, $httpCache, $pluginsCache, $dotnetHome -Force | Out-Null
    $expectedCommit = Get-RepositoryCommit -Commit $ExpectedRepositoryCommit

    foreach ($name in @('NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'NUGET_PLUGINS_CACHE_PATH', 'DOTNET_CLI_HOME')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    [Environment]::SetEnvironmentVariable('NUGET_PACKAGES', $nugetPackages, 'Process')
    [Environment]::SetEnvironmentVariable('NUGET_HTTP_CACHE_PATH', $httpCache, 'Process')
    [Environment]::SetEnvironmentVariable('NUGET_PLUGINS_CACHE_PATH', $pluginsCache, 'Process')
    [Environment]::SetEnvironmentVariable('DOTNET_CLI_HOME', $dotnetHome, 'Process')
    [Environment]::SetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY', '1', 'Process')

    Invoke-Checked 'dotnet' @('restore', $solution, '--configfile', (Join-Path $repo 'NuGet.config'), '-p:NuGetAudit=false')
    Invoke-Checked 'dotnet' @('build', $baselineProject, '-c', 'Release', '--no-restore')
    Invoke-Checked 'dotnet' @('build', $candidateProject, '-c', 'Release', '--no-restore')

    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        Invoke-Checked 'dotnet' @('build', $project, '-c', 'Release', '--no-restore')
        $packArguments = @('pack', $project, '-c', 'Release', '--no-build', '--no-restore', '--include-symbols', '-p:SymbolPackageFormat=snupkg', '-p:PackageVersion=0.1.0')
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRepositoryCommit)) {
            $packArguments += @("-p:SourceRevisionId=$expectedCommit", "-p:RepositoryCommit=$expectedCommit")
        }
        Invoke-Checked 'dotnet' ($packArguments + @('-o', $packageFeed))
        $PackagePath = Join-Path $packageFeed $nupkgName
        $SymbolsPath = Join-Path $packageFeed $snupkgName
    }
    else {
        Assert-True (Test-Path -LiteralPath $PackagePath -PathType Leaf) "Packed tool package was not found: $PackagePath"
        if ([string]::IsNullOrWhiteSpace($SymbolsPath)) {
            $SymbolsPath = Join-Path (Split-Path -Parent $PackagePath) $snupkgName
        }
        Assert-True (Test-Path -LiteralPath $SymbolsPath -PathType Leaf) "Packed symbol package was not found: $SymbolsPath"
        Copy-Item -LiteralPath $PackagePath -Destination (Join-Path $packageFeed $nupkgName)
        Copy-Item -LiteralPath $SymbolsPath -Destination (Join-Path $packageFeed $snupkgName)
    }

    $nupkg = Join-Path $packageFeed $nupkgName
    $snupkg = Join-Path $packageFeed $snupkgName
    Assert-True (Test-Path -LiteralPath $nupkg -PathType Leaf) "Expected package was not found: $nupkg"
    Assert-True (Test-Path -LiteralPath $snupkg -PathType Leaf) "Expected symbol package was not found: $snupkg"

    $inspectionOutput = (& pwsh -NoProfile -File $inspectionScript -PackagePath $nupkg -SymbolsPath $snupkg -ExpectedRepositoryCommit $expectedCommit 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
        throw "Packed package inspection failed: $inspectionOutput"
    }
    Write-Output $inspectionOutput

    Copy-Item (Join-Path $baselineBuild '*.dll') $baselineOutput -Force
    Copy-Item (Join-Path $candidateBuild '*.dll') $candidateOutput -Force

    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="candidate" value="$([Security.SecurityElement]::Escape(([IO.DirectoryInfo]$packageFeed).FullName))" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="candidate">
      <package pattern="KeelMatrix.BehaviorOracle" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="KeelMatrix.Telemetry" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@ | Set-Content -LiteralPath $nugetConfig -Encoding utf8

    $candidateHash = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
    Invoke-Checked 'dotnet' @('tool', 'install', '--tool-path', $installRoot, 'KeelMatrix.BehaviorOracle', '--version', $version, '--configfile', $nugetConfig, '--no-cache')
    $toolPath = Get-ChildItem -LiteralPath $installRoot -File |
        Where-Object { $_.BaseName -eq 'behavior-oracle' } |
        Select-Object -First 1 -ExpandProperty FullName
    Assert-True (-not [string]::IsNullOrWhiteSpace($toolPath)) "Installed tool was not found in $installRoot"

    $installedPayloadRoot = Resolve-InstalledPayloadRoot
    $installedPackageRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $installedPayloadRoot))
    $installedPackage = Get-ChildItem -LiteralPath $installedPackageRoot -File -Filter 'KeelMatrix.BehaviorOracle.nupkg' |
        Select-Object -First 1
    Assert-True ($null -ne $installedPackage) "The freshly installed tool store did not retain the candidate package: $installedPackageRoot"
    $installedPackageHash = (Get-FileHash -LiteralPath $installedPackage.FullName -Algorithm SHA256).Hash
    Assert-True ($installedPackageHash -ceq $candidateHash) "The installed package bytes did not match the freshly built package hash $candidateHash. Installed hash: $installedPackageHash"
    $archivePayloadHash = Get-ArchivePayloadHash -ArchivePath $nupkg
    $installedPayloadHash = Get-DirectoryPayloadHash -PayloadRoot $installedPayloadRoot
    Assert-True ($installedPayloadHash -ceq $archivePayloadHash) "The installed tool payload hash did not match the candidate archive payload. Archive: $archivePayloadHash; installed: $installedPayloadHash"
    Write-Output "Fresh package hash verified: $candidateHash ($($installedPackage.FullName))"
    Write-Output "Installed tool payload hash verified: $installedPayloadHash ($installedPayloadRoot)"

    @{
        version = 1
        seed = $Seed
        scenarioBudget = $ScenarioBudget
        confirmationRuns = $ConfirmationRuns
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $config -NoNewline

    $equivalent = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $baselineOutput, '--config', $config, '--format', 'console')
    Assert-True ($equivalent.ExitCode -eq 0) "Equivalent package comparison returned $($equivalent.ExitCode). Output: $($equivalent.Output)"
    Assert-True ($equivalent.Output.Contains('EQUIVALENT WITHIN TESTED DOMAIN', [StringComparison]::Ordinal)) 'Equivalent console wording was not found.'

    $firstDivergence = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $candidateOutput, '--config', $config, '--format', 'json')
    $secondDivergence = Invoke-Tool @('compare', '--baseline', $baselineOutput, '--candidate', $candidateOutput, '--config', $config, '--format', 'json')
    Assert-True ($firstDivergence.ExitCode -eq 1) "Divergence package comparison returned $($firstDivergence.ExitCode). Output: $($firstDivergence.Output)"
    Assert-True ($firstDivergence.Output -eq $secondDivergence.Output) 'JSON report was not byte-deterministic for the same package inputs.'
    $report = $firstDivergence.Output | ConvertFrom-Json
    Assert-True ($report.resultState -eq 'BEHAVIORAL_DIVERGENCE') "Unexpected JSON result state: $($report.resultState)"
    Assert-True ($report.divergences.Count -gt 0) 'The planted divergence report has no divergence record.'
    Assert-True ($null -ne $report.divergences[0].minimizedInput) 'The divergence report has no minimized witness.'
    Assert-True ($report.seed -eq $Seed) "The report seed was not preserved: $($report.seed)"
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $reportRoot 'divergence.json')

    Write-Output "Package smoke passed from a fresh cache with source mapping. Equivalent exit: $($equivalent.ExitCode); divergence exit: $($firstDivergence.ExitCode); seed: $Seed"
    exit 0
}
catch {
    [Console]::Error.WriteLine("Package smoke failed: $($_.Exception.Message)")
    exit 1
}
finally {
    [Environment]::SetEnvironmentVariable('KEELMATRIX_NO_TELEMETRY', $oldTelemetryOptOut, 'Process')
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
