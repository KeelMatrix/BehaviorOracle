[CmdletBinding()]
param(
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

    $output = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $summary = ($output | Out-String).Trim()
        throw "Command '$File $($Arguments -join ' ')' failed with exit code $LASTEXITCODE. $summary"
    }
}

$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
Assert-Condition (Test-Path -LiteralPath (Join-Path $repo 'KeelMatrix.BehaviorOracle.sln') -PathType Leaf) "Repository solution was not found under: $repo"

$head = (& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and $head -match '^[0-9a-fA-F]{40}$') 'Unable to resolve the repository HEAD commit.'

$originUrl = (& git -C $repo remote get-url origin 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) 'Unable to resolve the repository origin URL.'

$solution = 'KeelMatrix.BehaviorOracle.sln'
$engine = 'src/KeelMatrix.BehaviorOracle/bin/Release/net8.0/KeelMatrix.BehaviorOracle.dll'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-engine-repro-$([Guid]::NewGuid().ToString('N'))"
$cloneA = Join-Path $scratch 'clone-a'
$cloneB = Join-Path $scratch 'clone-b'

function Get-EngineSha512 {
    param([Parameter(Mandatory = $true)][string]$Clone)

    git clone --no-local $repo $Clone *> $null
    Assert-Condition ($LASTEXITCODE -eq 0) "Failed to clone the repository into: $Clone"
    git -C $Clone remote set-url origin $originUrl
    git -C $Clone checkout $head *> $null
    Assert-Condition ($LASTEXITCODE -eq 0) "Failed to check out $head in: $Clone"

    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $Clone
        $env:KEELMATRIX_NO_TELEMETRY = '1'
        Invoke-Checked 'dotnet' @('restore', $solution, '--configfile', 'NuGet.config', '-p:NuGetAudit=false')
        Invoke-Checked 'dotnet' @('build', $solution, '--configuration', 'Release', '--no-restore', '--warnaserror')
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }

    $enginePath = Join-Path $Clone $engine
    Assert-Condition (Test-Path -LiteralPath $enginePath -PathType Leaf) "The engine assembly was not produced: $enginePath"
    return (Get-FileHash -LiteralPath $enginePath -Algorithm SHA512).Hash
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $hashA = Get-EngineSha512 -Clone $cloneA
    $hashB = Get-EngineSha512 -Clone $cloneB

    Write-Output "HEAD: $head"
    Write-Output "Clone A: $cloneA"
    Write-Output "Clone A engine SHA-512: $hashA"
    Write-Output "Clone B: $cloneB"
    Write-Output "Clone B engine SHA-512: $hashB"

    Assert-Condition ([string]::Equals($hashA, $hashB, [StringComparison]::OrdinalIgnoreCase)) 'The engine assembly hash differed across two clean clone paths; the build is not path-independent.'
    Write-Output 'Engine reproducibility passed: two clean clones at different paths produced identical engine SHA-512.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("Engine reproducibility check failed: $($_.Exception.Message)")
    exit 1
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
