$ErrorActionPreference = 'Stop'

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

function Export-Revision {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Invoke-Checked 'git' @('-C', $Workspace, 'rev-parse', '--verify', "$Revision^{commit}") | Out-Null
    & git -C $Workspace archive --format=tar --worktree-attributes $Revision | tar -xf - -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "Could not export revision '$Revision'."
    }
}

function Resolve-ToolPath {
    param([Parameter(Mandatory = $true)][string]$ToolDirectory)

    $candidate = Get-ChildItem -LiteralPath $ToolDirectory -File |
        Where-Object { $_.BaseName -eq 'behavior-oracle' } |
        Select-Object -First 1
    if ($null -eq $candidate) {
        throw 'The installed behavior-oracle command was not found.'
    }

    return $candidate.FullName
}

$workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$baselineRef = $env:BEHAVIOR_ORACLE_BASELINE_REF
$candidateRef = $env:BEHAVIOR_ORACLE_CANDIDATE_REF
$project = $env:BEHAVIOR_ORACLE_PROJECT
$config = $env:BEHAVIOR_ORACLE_CONFIG
$toolVersion = if ($env:BEHAVIOR_ORACLE_TOOL_VERSION) { $env:BEHAVIOR_ORACLE_TOOL_VERSION } else { '0.1.0' }
$packageSource = $env:BEHAVIOR_ORACLE_PACKAGE_SOURCE

if ([string]::IsNullOrWhiteSpace($baselineRef) -or
    [string]::IsNullOrWhiteSpace($candidateRef) -or
    [string]::IsNullOrWhiteSpace($project) -or
    [string]::IsNullOrWhiteSpace($config)) {
    throw 'baseline-ref, candidate-ref, project, and config are required.'
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "behavior-oracle-action-$PID"
$baselineRoot = Join-Path $root 'baseline-source'
$candidateRoot = Join-Path $root 'candidate-source'
$baselineOutput = Join-Path $root 'baseline-output'
$candidateOutput = Join-Path $root 'candidate-output'
$toolDirectory = Join-Path $root 'tool'

try {
    New-Item -ItemType Directory -Path $baselineRoot, $candidateRoot, $baselineOutput, $candidateOutput, $toolDirectory -Force | Out-Null
    Export-Revision $workspace $baselineRef $baselineRoot
    Export-Revision $workspace $candidateRef $candidateRoot

    $baselineProject = Join-Path $baselineRoot $project
    $candidateProject = Join-Path $candidateRoot $project
    if (-not (Test-Path -LiteralPath $baselineProject -PathType Leaf) -or
        -not (Test-Path -LiteralPath $candidateProject -PathType Leaf)) {
        throw "Project '$project' was not found in both revisions."
    }

    Invoke-Checked 'dotnet' @('restore', $baselineProject)
    Invoke-Checked 'dotnet' @('restore', $candidateProject)
    Invoke-Checked 'dotnet' @('build', $baselineProject, '-c', 'Release', '--no-restore', '-o', $baselineOutput)
    Invoke-Checked 'dotnet' @('build', $candidateProject, '-c', 'Release', '--no-restore', '-o', $candidateOutput)

    $toolArguments = @('tool', 'install', '--tool-path', $toolDirectory, 'KeelMatrix.BehaviorOracle', '--version', $toolVersion, '--add-source', $packageSource, '--ignore-failed-sources')
    Invoke-Checked 'dotnet' $toolArguments
    $tool = Resolve-ToolPath $toolDirectory

    $configPath = if ([System.IO.Path]::IsPathRooted($config)) { $config } else { Join-Path $workspace $config }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration file '$config' was not found."
    }

    & $tool compare --baseline $baselineOutput --candidate $candidateOutput --config $configPath --format console
    $comparisonExitCode = $LASTEXITCODE
    if ($comparisonExitCode -notin @(0, 1)) {
        throw "BehaviorOracle comparison failed with exit code $comparisonExitCode."
    }

    exit $comparisonExitCode
}
catch {
    Write-Error $_
    exit 2
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
