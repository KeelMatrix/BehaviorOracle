[CmdletBinding()]
param(
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/release.yml')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw -ErrorAction Stop
$publishSectionMatch = [regex]::Match($workflow, '(?ms)^  publish:\r?\n(?<section>.*)$')
Assert-Contract $publishSectionMatch.Success 'Release workflow is missing the publish job.'

$publishSection = $publishSectionMatch.Groups['section'].Value
$pushLines = @([regex]::Matches($publishSection, '(?m)^\s*dotnet\s+nuget\s+push\s+.+$') | ForEach-Object Value)
Assert-Contract ($pushLines.Count -eq 2) "Release publication must contain exactly two explicit dotnet nuget push commands; found $($pushLines.Count)."

$packagePushLines = @($pushLines | Where-Object {
        $_ -match '(?i)\.nupkg(?:\"|\x27|\))' -and $_ -notmatch '(?i)\.snupkg'
    })
$symbolPushLines = @($pushLines | Where-Object { $_ -match '(?i)\.snupkg(?:\"|\x27|\))' })

Assert-Contract ($packagePushLines.Count -eq 1) "Release publication must contain exactly one explicit .nupkg push; found $($packagePushLines.Count)."
Assert-Contract ($symbolPushLines.Count -eq 1) "Release publication must contain exactly one explicit .snupkg push; found $($symbolPushLines.Count)."
Assert-Contract ($packagePushLines[0] -match '(?i)(^|\s)--no-symbols(?=\s|$)') 'The primary .nupkg push must use --no-symbols so the sibling .snupkg is not published automatically.'

Write-Output 'Release publication contract passed: one --no-symbols .nupkg push and one explicit .snupkg push.'
exit 0
