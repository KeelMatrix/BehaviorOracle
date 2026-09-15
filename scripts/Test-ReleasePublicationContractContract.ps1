[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-PublicationContract {
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowPath,
        [string]$CiWorkflowPath
    )

    $validator = Join-Path $PSScriptRoot 'Test-ReleasePublicationContract.ps1'
    $arguments = @('-NoProfile', '-File', $validator, '-WorkflowPath', $WorkflowPath)
    if (-not [string]::IsNullOrWhiteSpace($CiWorkflowPath)) {
        $arguments += @('-CiWorkflowPath', $CiWorkflowPath)
    }

    $output = (& pwsh @arguments 2>&1 | Out-String).Trim()
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-release-publication-contract-$([Guid]::NewGuid().ToString('N'))"
$legacyWorkflowPath = Join-Path $testRoot 'legacy-release.yml'
$benchmarkWithoutSuccessPath = Join-Path $testRoot 'release-without-benchmark-success.yml'
$benchmarkWithFailureSuccessPath = Join-Path $testRoot 'release-with-benchmark-failure-success.yml'
$ciBenchmarkWithoutSuccessPath = Join-Path $testRoot 'ci-without-benchmark-success.yml'
$ciBenchmarkWithFailureSuccessPath = Join-Path $testRoot 'ci-with-benchmark-failure-success.yml'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $repositoryWorkflow = Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/release.yml'
    $currentResult = Invoke-PublicationContract -WorkflowPath $repositoryWorkflow
    Assert-Test ($currentResult.ExitCode -eq 0) "The checked-in release workflow failed its publication contract. Output: $($currentResult.Output)"

    $ciWorkflow = Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/ci.yml'
    $releaseWorkflow = Get-Content -LiteralPath $repositoryWorkflow -Raw
    $ciWorkflowText = Get-Content -LiteralPath $ciWorkflow -Raw
    $successExit = '          exit 0'
    Assert-Test ($releaseWorkflow.Contains($successExit)) 'The checked-in release workflow benchmark step must contain its explicit success exit.'
    Assert-Test ($ciWorkflowText.Contains($successExit)) 'The checked-in CI workflow benchmark step must contain its explicit success exit.'

    $withoutSuccess = $releaseWorkflow.Replace($successExit, '')
    $ciWithoutSuccess = $ciWorkflowText.Replace($successExit, '')
    [IO.File]::WriteAllText($benchmarkWithoutSuccessPath, $withoutSuccess, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ciBenchmarkWithoutSuccessPath, $ciWithoutSuccess, [Text.UTF8Encoding]::new($false))
    $withoutSuccessResult = Invoke-PublicationContract -WorkflowPath $benchmarkWithoutSuccessPath -CiWorkflowPath $ciBenchmarkWithoutSuccessPath
    Assert-Test ($withoutSuccessResult.ExitCode -ne 0 -and $withoutSuccessResult.Output -match 'leaked exit code') 'Removing the benchmark success exit unexpectedly passed the behavioral contract.'

    $withFailureSuccess = $releaseWorkflow.Replace($successExit, '          exit 7')
    $ciWithFailureSuccess = $ciWorkflowText.Replace($successExit, '          exit 7')
    [IO.File]::WriteAllText($benchmarkWithFailureSuccessPath, $withFailureSuccess, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ciBenchmarkWithFailureSuccessPath, $ciWithFailureSuccess, [Text.UTF8Encoding]::new($false))
    $withFailureSuccessResult = Invoke-PublicationContract -WorkflowPath $benchmarkWithFailureSuccessPath -CiWorkflowPath $ciBenchmarkWithFailureSuccessPath
    Assert-Test ($withFailureSuccessResult.ExitCode -ne 0 -and $withFailureSuccessResult.Output -match 'leaked exit code') 'Changing the benchmark success exit unexpectedly passed the behavioral contract.'

    $legacyWorkflow = @'
name: Release

jobs:
  publish:
    permissions:
      id-token: write
    steps:
      - name: Push exact package
        shell: pwsh
        run: |
          dotnet nuget push (Join-Path $packageDirectory "KeelMatrix.BehaviorOracle.$version.nupkg") --source $source --api-key $apiKey
          dotnet nuget push (Join-Path $packageDirectory "KeelMatrix.BehaviorOracle.$version.snupkg") --source $source --api-key $apiKey
'@
    [IO.File]::WriteAllText($legacyWorkflowPath, $legacyWorkflow, [Text.UTF8Encoding]::new($false))
    $legacyResult = Invoke-PublicationContract -WorkflowPath $legacyWorkflowPath
    Assert-Test ($legacyResult.ExitCode -ne 0) "The pre-fix double-publish workflow unexpectedly passed the publication contract. Output: $($legacyResult.Output)"

    Write-Output 'Release publication contract tests passed: checked-in workflow accepted and pre-fix automatic symbol double-publish rejected.'
    exit 0
}
catch {
    Write-Error "Release publication contract tests failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
