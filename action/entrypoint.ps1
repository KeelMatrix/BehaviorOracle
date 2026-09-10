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
    $archive = Join-Path (Split-Path -Parent $Destination) ("$([IO.Path]::GetFileName($Destination)).tar")
    try {
        Invoke-Checked 'git' @('-C', $Workspace, 'archive', '--format=tar', "--output=$archive", '--worktree-attributes', $Revision)
        Invoke-Checked 'tar' @('-xf', $archive, '-C', $Destination)
    }
    finally {
        if (Test-Path -LiteralPath $archive) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-RepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Description must be repository-relative."
    }

    $workspaceRoot = [IO.Path]::GetFullPath($Workspace).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolved = [IO.Path]::GetFullPath((Join-Path $workspaceRoot $RelativePath))
    $relativeToWorkspace = [IO.Path]::GetRelativePath($workspaceRoot, $resolved)
    if ([IO.Path]::IsPathRooted($relativeToWorkspace) -or
        $relativeToWorkspace -eq '..' -or
        $relativeToWorkspace.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
        throw "$Description must remain within the repository workspace."
    }

    return $resolved
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

$workspace = if ($env:GITHUB_WORKSPACE) { [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE) } else { (Get-Location).Path }
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

$root = Join-Path ([System.IO.Path]::GetTempPath()) "behavior-oracle-action-$PID-$([Guid]::NewGuid().ToString('N'))"
$baselineRoot = Join-Path $root 'baseline-source'
$candidateRoot = Join-Path $root 'candidate-source'
$baselineOutput = Join-Path $root 'baseline-output'
$candidateOutput = Join-Path $root 'candidate-output'
$baselineIntermediate = Join-Path $root 'baseline-intermediate'
$candidateIntermediate = Join-Path $root 'candidate-intermediate'
$toolDirectory = Join-Path $root 'tool'

try {
    New-Item -ItemType Directory -Path $baselineRoot, $candidateRoot, $baselineOutput, $candidateOutput, $baselineIntermediate, $candidateIntermediate, $toolDirectory -Force | Out-Null
    Export-Revision $workspace $baselineRef $baselineRoot
    Export-Revision $workspace $candidateRef $candidateRoot

    $baselineProject = Resolve-RepositoryRelativePath $baselineRoot $project 'project'
    $candidateProject = Resolve-RepositoryRelativePath $candidateRoot $project 'project'
    if (-not (Test-Path -LiteralPath $baselineProject -PathType Leaf) -or
        -not (Test-Path -LiteralPath $candidateProject -PathType Leaf)) {
        throw "Project '$project' was not found in both revisions."
    }

    $baselineIntermediateArgument = "$baselineIntermediate$([IO.Path]::DirectorySeparatorChar)"
    $candidateIntermediateArgument = "$candidateIntermediate$([IO.Path]::DirectorySeparatorChar)"
    Invoke-Checked 'dotnet' @('restore', $baselineProject, "-p:BaseIntermediateOutputPath=$baselineIntermediateArgument")
    Invoke-Checked 'dotnet' @('restore', $candidateProject, "-p:BaseIntermediateOutputPath=$candidateIntermediateArgument")
    Invoke-Checked 'dotnet' @('build', $baselineProject, '-c', 'Release', '--no-restore', '-o', $baselineOutput, "-p:BaseIntermediateOutputPath=$baselineIntermediateArgument", '-p:UseSharedCompilation=false')
    Invoke-Checked 'dotnet' @('build', $candidateProject, '-c', 'Release', '--no-restore', '-o', $candidateOutput, "-p:BaseIntermediateOutputPath=$candidateIntermediateArgument", '-p:UseSharedCompilation=false')

    $toolArguments = @('tool', 'install', '--tool-path', $toolDirectory, 'KeelMatrix.BehaviorOracle', '--version', $toolVersion, '--add-source', $packageSource, '--ignore-failed-sources')
    Invoke-Checked 'dotnet' $toolArguments
    $tool = Resolve-ToolPath $toolDirectory

    $configPath = Resolve-RepositoryRelativePath $workspace $config 'config'
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
    [Console]::Error.WriteLine("BehaviorOracle Action failed: $($_.Exception.Message)")
    exit 2
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
