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
        [Parameter(Mandatory = $true)][string]$WorkflowPath
    )

    $validator = Join-Path $PSScriptRoot 'Test-ReleasePublicationContract.ps1'
    $output = (& pwsh -NoProfile -File $validator -WorkflowPath $WorkflowPath 2>&1 | Out-String).Trim()
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "behaviororacle-release-publication-contract-$([Guid]::NewGuid().ToString('N'))"
$legacyWorkflowPath = Join-Path $testRoot 'legacy-release.yml'

try {
    $repositoryWorkflow = Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/release.yml'
    $currentResult = Invoke-PublicationContract -WorkflowPath $repositoryWorkflow
    Assert-Test ($currentResult.ExitCode -eq 0) "The checked-in release workflow failed its publication contract. Output: $($currentResult.Output)"

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
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
