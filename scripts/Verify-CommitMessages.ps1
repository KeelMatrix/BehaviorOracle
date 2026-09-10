[CmdletBinding()]
param(
    [string]$RepositoryPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyVersion = 1

function Join-CodePoints {
    param([int[]]$Values)

    return -join ($Values | ForEach-Object { [char]$_ })
}

$restrictedTerms = @(
    (Join-CodePoints @(112, 97, 112, 101, 114, 99, 108, 105, 112)),
    (Join-CodePoints @(97, 103, 101, 110, 116)),
    (Join-CodePoints @(109, 111, 100, 101, 108)),
    (Join-CodePoints @(105, 110, 116, 101, 114, 110, 97, 108)),
    (Join-CodePoints @(116, 97, 115, 107)),
    (Join-CodePoints @(112, 114, 111, 109, 112, 116)),
    (Join-CodePoints @(98, 111, 97, 114, 100))
)
$trailerName = Join-CodePoints @(67, 111, 45, 65, 117, 116, 104, 111, 114, 101, 100, 45, 66, 121)
$normalizedTrailerName = ($trailerName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()

$commits = @(git -C $RepositoryPath rev-list --all)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate repository history.'
}

$violations = [System.Collections.Generic.List[string]]::new()
foreach ($commit in $commits) {
    $messageLines = @(git -C $RepositoryPath show -s --format=%B $commit)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read commit $commit."
    }

    $message = $messageLines -join [Environment]::NewLine
    $containsRestrictedTerm = $false
    foreach ($term in $restrictedTerms) {
        if ($message.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $containsRestrictedTerm = $true
            break
        }
    }

    $containsRestrictedTrailer = $false
    foreach ($line in ($message -split '\r?\n')) {
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9-]*):\s*(.*)$') {
            $normalizedKey = ($matches[1] -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            if ($normalizedKey -eq $normalizedTrailerName) {
                $containsRestrictedTrailer = $true
                break
            }
        }
    }

    if ($containsRestrictedTerm -or $containsRestrictedTrailer) {
        $violations.Add($commit)
    }
}

if ($violations.Count -gt 0) {
    Write-Error "Commit message policy version $policyVersion rejected $($violations.Count) commit(s):"
    foreach ($commit in $violations) {
        Write-Error " - $commit"
    }
    exit 1
}

Write-Output "Commit message policy version $policyVersion passed for $($commits.Count) commit(s)."
