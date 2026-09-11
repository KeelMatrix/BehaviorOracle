[CmdletBinding()]
param(
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string]$Commit,
    [string]$ScratchDirectory,
    [string]$CloneRoot,
    [string]$BuildRoot,
    [switch]$KeepScratch
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
$repositoryStatus = Invoke-Captured -File 'git' -Arguments @('-C', $repository, 'status', '--porcelain')
Assert-Condition ([string]::IsNullOrWhiteSpace($repositoryStatus)) 'The repository must be clean before proving a committed ref reproducible.'
$resolvedCommit = if ([string]::IsNullOrWhiteSpace($Commit)) {
    Invoke-Captured -File 'git' -Arguments @('-C', $repository, 'rev-parse', 'HEAD')
} else {
    $Commit.Trim()
}
Assert-Condition ($resolvedCommit -match '^[0-9a-fA-F]{40}$') "Commit '$resolvedCommit' is not a full Git SHA."

$remoteUrl = Invoke-Captured -File 'git' -Arguments @('-C', $repository, 'remote', 'get-url', 'origin')
if ($remoteUrl -notmatch '^https://github\.com/KeelMatrix/BehaviorOracle(?:\.git)?$') {
    $remoteUrl = 'https://github.com/KeelMatrix/BehaviorOracle.git'
}

$runToken = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$scratchRoot = if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
    [IO.Path]::GetTempPath()
} else {
    (New-Item -ItemType Directory -Path $ScratchDirectory -Force).FullName
}
$cloneParent = if ([string]::IsNullOrWhiteSpace($CloneRoot)) { $scratchRoot } else { (New-Item -ItemType Directory -Path $CloneRoot -Force).FullName }
$buildParent = if ([string]::IsNullOrWhiteSpace($BuildRoot)) { $null } else { (New-Item -ItemType Directory -Path $BuildRoot -Force).FullName }
$cloneWorkRoot = Join-Path $cloneParent "bo-clones-$runToken"
$buildWorkRoot = if ($null -eq $buildParent) { $null } else { Join-Path $buildParent "bo-builds-$runToken" }
$hashes = [Collections.Generic.List[string]]::new()
$engines = [Collections.Generic.List[string]]::new()

try {
    New-Item -ItemType Directory -Path $cloneWorkRoot -Force | Out-Null
    if ($null -ne $buildWorkRoot) {
        New-Item -ItemType Directory -Path $buildWorkRoot -Force | Out-Null
    }

    foreach ($name in @('clone-a', 'clone-b')) {
        $clone = Join-Path $cloneWorkRoot $name
        $build = if ($null -eq $buildWorkRoot) { $null } else { Join-Path $buildWorkRoot $name }
        $intermediateOutput = if ($null -eq $build) { $null } else { Join-Path $build 'obj' }
        $output = if ($null -eq $build) { $null } else { Join-Path $build 'bin' }
        Invoke-Checked -File 'git' -Arguments @(
            '-c', 'core.autocrlf=false',
            '-c', 'core.eol=lf',
            'clone', '--no-local', '--no-checkout', $repository, $clone
        )
        Invoke-Checked -File 'git' -Arguments @('-C', $clone, 'config', 'core.autocrlf', 'false')
        Invoke-Checked -File 'git' -Arguments @('-C', $clone, 'config', 'core.eol', 'lf')
        Invoke-Checked -File 'git' -Arguments @('-C', $clone, 'remote', 'set-url', 'origin', $remoteUrl)
        Invoke-Checked -File 'git' -Arguments @('-C', $clone, 'checkout', '--detach', $resolvedCommit)

        $status = Invoke-Captured -File 'git' -Arguments @('-C', $clone, 'status', '--porcelain')
        Assert-Condition ([string]::IsNullOrWhiteSpace($status)) "Clone '$name' is not clean."

        $project = Join-Path $clone 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj'
        $config = Join-Path $clone 'NuGet.config'
        $buildProperties = @(
            '-p:Version=0.1.0',
            '-p:PackageVersion=0.1.0',
            "-p:SourceRevisionId=$resolvedCommit",
            "-p:RepositoryCommit=$resolvedCommit",
            '-p:ContinuousIntegrationBuild=true',
            '-p:Deterministic=true',
            '-p:DeterministicSourcePaths=true',
            '-p:IncludeSourceRevisionInInformationalVersion=false',
            '-p:DebugType=none',
            '-p:DebugSymbols=false',
            '-p:AssemblyVersion=0.1.0.0',
            '-p:FileVersion=0.1.0.0'
        )
        if ($null -eq $build) {
            $buildProperties += '-p:PathMap=$(MSBuildProjectDirectory)=/_/'
        } else {
            $buildProperties += ('-p:PathMap=$(MSBuildProjectDirectory)=/_/;' + $build + '=/_build/')
            $buildProperties += "-p:BaseIntermediateOutputPath=$intermediateOutput\"
            $buildProperties += "-p:BaseOutputPath=$output\"
        }

        Invoke-Checked -File 'dotnet' -Arguments (@(
            'restore', $project, '--configfile', $config,
            '-p:NuGetAudit=false'
        ) + $buildProperties)
        Invoke-Checked -File 'dotnet' -Arguments (@(
            'build', $project,
            '--configuration', 'Release',
            '--no-restore',
            '--disable-build-servers',
            '--warnaserror'
        ) + $buildProperties)

        $engine = if ($null -eq $build) {
            Join-Path $clone 'src/KeelMatrix.BehaviorOracle/bin/Release/net8.0/KeelMatrix.BehaviorOracle.dll'
        } else {
            Join-Path $output 'Release/net8.0/KeelMatrix.BehaviorOracle.dll'
        }
        Assert-Condition (Test-Path -LiteralPath $engine -PathType Leaf) "Release engine was not produced for '$name'."
        $hashes.Add((Get-FileHash -LiteralPath $engine -Algorithm SHA512).Hash.ToUpperInvariant())
        $engines.Add($engine)
    }

    Assert-Condition ($hashes.Count -eq 2) 'Expected two clean clone engine hashes.'
    Assert-Condition ($hashes[0] -ceq $hashes[1]) "Path-separated Release engine hashes differ: $($hashes[0]) and $($hashes[1])."
    Write-Output "Reproducible engine build passed for $resolvedCommit. SHA-512: $($hashes[0])"
    if ($KeepScratch) {
        Write-Output "Clean clone engine A: $($engines[0])"
        Write-Output "Clean clone engine B: $($engines[1])"
    }
}
finally {
    if (-not $KeepScratch) {
        foreach ($root in @($cloneWorkRoot, $buildWorkRoot) | Where-Object { $null -ne $_ }) {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }
}
