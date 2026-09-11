[CmdletBinding()]
param(
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),
    [string]$Commit,
    [string]$ScratchDirectory
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

$scratchRoot = if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
    [IO.Path]::GetTempPath()
} else {
    (New-Item -ItemType Directory -Path $ScratchDirectory -Force).FullName
}
$workRoot = Join-Path $scratchRoot "behaviororacle-repro-$([Guid]::NewGuid().ToString('N'))"
$hashes = [Collections.Generic.List[string]]::new()

try {
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    foreach ($name in @('clone-a', 'clone-b')) {
        $clone = Join-Path $workRoot $name
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

        $solution = Join-Path $clone 'KeelMatrix.BehaviorOracle.sln'
        $project = Join-Path $clone 'src/KeelMatrix.BehaviorOracle/KeelMatrix.BehaviorOracle.csproj'
        $config = Join-Path $clone 'NuGet.config'
        Invoke-Checked -File 'dotnet' -Arguments @(
            'restore', $solution, '--configfile', $config, '-p:NuGetAudit=false'
        )
        Invoke-Checked -File 'dotnet' -Arguments @(
            'build', $project,
            '--configuration', 'Release',
            '--no-restore',
            '--warnaserror',
            '-p:Version=0.1.0',
            '-p:PackageVersion=0.1.0',
            "-p:SourceRevisionId=$resolvedCommit",
            "-p:RepositoryCommit=$resolvedCommit",
            '-p:ContinuousIntegrationBuild=true',
            '-p:Deterministic=true'
        )

        $engine = Join-Path $clone 'src/KeelMatrix.BehaviorOracle/bin/Release/net8.0/KeelMatrix.BehaviorOracle.dll'
        Assert-Condition (Test-Path -LiteralPath $engine -PathType Leaf) "Release engine was not produced for '$name'."
        $hashes.Add((Get-FileHash -LiteralPath $engine -Algorithm SHA512).Hash.ToUpperInvariant())
    }

    Assert-Condition ($hashes[0] -ceq $hashes[1]) "Path-separated Release engine hashes differ: $($hashes[0]) and $($hashes[1])."
    Write-Output "Reproducible engine build passed for $resolvedCommit. SHA-512: $($hashes[0])"
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
