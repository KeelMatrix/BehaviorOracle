[CmdletBinding()]
param(
    [switch]$KeepScratch,
    [string]$ScratchDirectory,
    [switch]$AllowStableEvidenceChanges,
    [string]$ToolPath
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$metadataPath = Join-Path $PSScriptRoot 'targets.json'
$configPath = Join-Path $PSScriptRoot 'config.json'
$rawResultsDirectory = Join-Path $repo 'bench\results\real-targets'
$committedSummaryPath = Join-Path $rawResultsDirectory 'summary.json'
$toolPath = if ([string]::IsNullOrWhiteSpace($ToolPath)) {
    Join-Path $repo 'src\KeelMatrix.BehaviorOracle\bin\Release\net8.0\KeelMatrix.BehaviorOracle.dll'
} else {
    (Resolve-Path -LiteralPath $ToolPath).Path
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
[void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Target metadata is missing: $metadataPath"
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Benchmark configuration is missing: $configPath"
}
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "Build the Release tool before running this recipe: dotnet build KeelMatrix.BehaviorOracle.sln -c Release"
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.version -ne 1 -or $metadata.targets.Count -lt 3) {
    throw 'Target metadata must be version 1 and contain all three real-library targets.'
}

$scratchRoot = if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
    [System.IO.Path]::GetTempPath()
} else {
    (New-Item -ItemType Directory -Path $ScratchDirectory -Force).FullName
}
$scratch = Join-Path $scratchRoot "bo-real-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$packageDirectory = Join-Path $scratch 'packages'
$artifactDirectory = Join-Path $scratch 'artifacts'
$generatedResultsDirectory = Join-Path $scratch 'results'
New-Item -ItemType Directory -Path $packageDirectory, $artifactDirectory, $generatedResultsDirectory -Force | Out-Null

function Get-PackageExtract {
    param(
        [Parameter(Mandatory)]$PackageId,
        [Parameter(Mandatory)]$Version,
        [Parameter(Mandatory)]$Sha512
    )

    $slug = $PackageId.ToLowerInvariant()
    $packagePath = Join-Path $packageDirectory "$slug.$Version.nupkg"
    $extractPath = Join-Path $packageDirectory "$slug.$Version"
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        $url = "https://api.nuget.org/v3-flatcontainer/$slug/$Version/$slug.$Version.nupkg"
        Invoke-WebRequest -Uri $url -OutFile $packagePath -UseBasicParsing
    }

    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA512).Hash
    if (-not [string]::Equals($actualHash, $Sha512, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-512 mismatch for $PackageId $Version. Expected $Sha512, got $actualHash."
    }

    if (-not (Test-Path -LiteralPath $extractPath -PathType Container)) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $extractPath)
    }

    return $extractPath
}

function Add-PackageAsset {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Destination
    )

    $extractPath = Get-PackageExtract -PackageId $Package.packageId -Version $Package.version -Sha512 $Package.sha512
    $assetPath = Join-Path $extractPath ($Package.asset -replace '/', '\')
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Package asset is missing: $($Package.packageId) $($Package.version) $($Package.asset)"
    }

    Copy-Item -LiteralPath $assetPath -Destination (Join-Path $Destination ([IO.Path]::GetFileName($assetPath))) -Force
}

function New-ArtifactDirectory {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][ValidateSet('baseline', 'candidate')]$Side
    )

    $destination = Join-Path $artifactDirectory "$($Target.id)-$Side"
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $selectedPackage = $Target.PSObject.Properties[$Side].Value
    $package = [pscustomobject]@{
        packageId = $Target.packageId
        version = $selectedPackage.version
        sha512 = $selectedPackage.sha512
        asset = $selectedPackage.asset
    }
    Add-PackageAsset -Package $package -Destination $destination
    foreach ($dependency in @($Target.dependencies)) {
        Add-PackageAsset -Package $dependency -Destination $destination
    }
    return $destination
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Argument)
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Invoke-Oracle {
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw 'Could not start dotnet for the real-library comparison.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            try { $process.Kill($true) } catch { }
            throw 'The real-library comparison exceeded the 300000 ms recipe bound.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $stopwatch.Stop()
        $stdout = $stdout.TrimEnd([char[]]"`r`n")
        $stderr = $stderr.TrimEnd([char[]]"`r`n")
        if ($stdout.Length -gt 4MB -or $stderr.Length -gt 4MB) {
            throw 'The real-library comparison exceeded the bounded recipe capture size.'
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
            ElapsedMilliseconds = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-ConsoleMetric {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )

    $escaped = [Regex]::Escape($Label)
    $match = [Regex]::Match($Text, "(?m)^${escaped}: ([0-9]+(?:\.[0-9]+)?)(?: ms)?\r?$")
    if (-not $match.Success) {
        throw "Console output did not contain metric '$Label'."
    }
    return [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ReportMetric {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Property
    )
    return [int]$Report.$Property
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    return [Math]::Round($ordered[[int]($ordered.Count / 2)], 4)
}

function Get-DivergenceStats {
    param([Parameter(Mandatory)]$Report)
    $divergences = @($Report.divergences)
    if ($divergences.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            WithMinimizedWitness = 0
            MedianInputSize = $null
            MedianMinimizedWitnessSize = $null
            MedianReduction = $null
            ReproducibleWitnesses = 0
            HumanReadable = 'not-applicable-no-stable-divergences'
        }
    }

    $inputSizes = @($divergences | ForEach-Object { [double]$_.input.arguments.Count })
    $minimizedSizes = @($divergences | ForEach-Object { [double]$_.minimizedInput.arguments.Count })
    $reductions = @($divergences | ForEach-Object { [double]$_.input.arguments.Count - [double]$_.minimizedInput.arguments.Count })
    return [pscustomobject]@{
        Count = $divergences.Count
        WithMinimizedWitness = @($divergences | Where-Object { $_.minimizedInput }).Count
        MedianInputSize = Get-Median $inputSizes
        MedianMinimizedWitnessSize = Get-Median $minimizedSizes
        MedianReduction = Get-Median $reductions
        ReproducibleWitnesses = $divergences.Count
        HumanReadable = 'not-assessed'
    }
}

function Get-StableConsoleText {
    param([Parameter(Mandatory)][string]$Text)

    $stableLines = @(
        ($Text.TrimEnd([char[]]"`r`n") -split "`r?`n") |
            Where-Object { $_ -notmatch '^(Median comparison time|Median witness-minimization time): ' }
    )
    return $stableLines -join "`n"
}

function Get-StableSummary {
    param([Parameter(Mandatory)]$Summary)

    return [ordered]@{
        schemaVersion = $Summary.schemaVersion
        generatedFor = $Summary.generatedFor
        configuration = $Summary.configuration
        groundTruthNote = $Summary.groundTruthNote
        targets = @($Summary.targets | ForEach-Object {
            [ordered]@{
                id = $_.id
                role = $_.role
                packageId = $_.packageId
                baseline = $_.baseline
                candidate = $_.candidate
                dependencies = @($_.dependencies)
                reportPath = $_.reportPath
                consolePath = $_.consolePath
                reportSha512 = $_.reportSha512
                report = $_.report
                groundTruth = $_.groundTruth
                precision = $_.precision
                recall = $_.recall
                reproducibility = $_.reproducibility
                minimization = $_.minimization
                customFactoriesOrGenerators = $_.customFactoriesOrGenerators
            }
        })
    }
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)]$Value)

    return $Value | ConvertTo-Json -Depth 30 -Compress
}

function Assert-VolatileTiming {
    param(
        [Parameter(Mandatory)][double]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-Condition (-not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value) -and $Value -ge 0) "$Name must be a finite non-negative timing value."
}

function Assert-StableEvidence {
    param([Parameter(Mandatory)]$Summary)

    if ($AllowStableEvidenceChanges -or -not (Test-Path -LiteralPath $committedSummaryPath -PathType Leaf)) {
        return
    }

    $committed = Get-Content -LiteralPath $committedSummaryPath -Raw | ConvertFrom-Json
    $expectedStable = ConvertTo-CanonicalJson (Get-StableSummary -Summary $Summary)
    $committedStable = ConvertTo-CanonicalJson (Get-StableSummary -Summary $committed)
    if ($expectedStable -cne $committedStable) {
        throw "Stable real-target evidence changed. Review counts, classifications, report hashes, signatures, and witnesses; use -AllowStableEvidenceChanges only for an intentional approved evidence update."
    }
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$toolHash = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA512).Hash
$environment = [ordered]@{
    osDescription = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    runtimeIdentifier = [Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
    sdkVersion = (& dotnet --version).Trim()
    runtimes = @(& dotnet --list-runtimes)
    culture = [Globalization.CultureInfo]::CurrentCulture.Name
    uiCulture = [Globalization.CultureInfo]::CurrentUICulture.Name
}

$targetResults = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($target in $metadata.targets) {
        $baseline = New-ArtifactDirectory -Target $target -Side baseline
        $candidate = New-ArtifactDirectory -Target $target -Side candidate
        $commonArguments = @(
            $toolPath,
            'compare',
            '--baseline', $baseline,
            '--candidate', $candidate,
            '--config', $configPath
        )

        $consoleRun = Invoke-Oracle -Arguments ($commonArguments + @('--format', 'console'))
        $consolePath = Join-Path $generatedResultsDirectory "$($target.id).console.txt"
        [IO.File]::WriteAllText($consolePath, $consoleRun.Stdout, $utf8)
        if ($consoleRun.ExitCode -notin @(0, 1)) {
            throw "$($target.id) console comparison failed with exit code $($consoleRun.ExitCode): $($consoleRun.Stderr.Trim())"
        }

        $jsonRun = Invoke-Oracle -Arguments ($commonArguments + @('--format', 'json'))
        $jsonPath = Join-Path $generatedResultsDirectory "$($target.id).json"
        [IO.File]::WriteAllText($jsonPath, $jsonRun.Stdout, $utf8)
        if ($jsonRun.ExitCode -notin @(0, 1)) {
            throw "$($target.id) JSON comparison failed with exit code $($jsonRun.ExitCode): $($jsonRun.Stderr.Trim())"
        }

        $repeatRun = Invoke-Oracle -Arguments ($commonArguments + @('--format', 'json'))
        if ($repeatRun.ExitCode -ne $jsonRun.ExitCode -or $repeatRun.Stdout -cne $jsonRun.Stdout) {
            throw "$($target.id) did not reproduce byte-identical JSON output on the repeated command."
        }

        $report = $jsonRun.Stdout | ConvertFrom-Json
        if (-not $report.trustworthy -or $report.executionFailureCount -ne 0) {
            throw "$($target.id) did not produce a trustworthy report."
        }

        $consoleMetrics = [ordered]@{
            matchedCallableApis = Get-ConsoleMetric $consoleRun.Stdout 'Matched callable APIs'
            eligibleSupportedApiPairs = Get-ConsoleMetric $consoleRun.Stdout 'Eligible supported API pairs'
            exercisedApiCount = Get-ConsoleMetric $consoleRun.Stdout 'APIs actually exercised'
            unsupportedApiCount = Get-ConsoleMetric $consoleRun.Stdout 'Unsupported APIs'
            generatedScenarios = Get-ConsoleMetric $consoleRun.Stdout 'Generated scenarios'
            stableScenarios = Get-ConsoleMetric $consoleRun.Stdout 'Stable scenarios'
            divergenceCount = Get-ConsoleMetric $consoleRun.Stdout 'Behavioral divergences'
            unsupportedOrInconclusiveScenarios = Get-ConsoleMetric $consoleRun.Stdout 'Unsupported/inconclusive scenarios'
            medianComparisonMilliseconds = Get-ConsoleMetric $consoleRun.Stdout 'Median comparison time'
            medianMinimizationMilliseconds = if ($report.divergenceCount -eq 0) { $null } else { Get-ConsoleMetric $consoleRun.Stdout 'Median witness-minimization time' }
        }
        Assert-VolatileTiming -Value $consoleMetrics.medianComparisonMilliseconds -Name "$($target.id) median comparison time"
        if ($null -ne $consoleMetrics.medianMinimizationMilliseconds) {
            Assert-VolatileTiming -Value $consoleMetrics.medianMinimizationMilliseconds -Name "$($target.id) median witness-minimization time"
        }
        Assert-VolatileTiming -Value $jsonRun.ElapsedMilliseconds -Name "$($target.id) JSON process wall-clock time"
        Assert-VolatileTiming -Value $repeatRun.ElapsedMilliseconds -Name "$($target.id) repeated JSON process wall-clock time"
        if (-not $AllowStableEvidenceChanges -and (Test-Path -LiteralPath (Join-Path $rawResultsDirectory "$($target.id).console.txt") -PathType Leaf)) {
            $committedConsole = Get-Content -LiteralPath (Join-Path $rawResultsDirectory "$($target.id).console.txt") -Raw
            if ((Get-StableConsoleText -Text $consoleRun.Stdout) -cne (Get-StableConsoleText -Text $committedConsole)) {
                throw "$($target.id) stable console evidence changed. Review counts and classifications; use -AllowStableEvidenceChanges only for an intentional approved evidence update."
            }
        }
        foreach ($metric in @('matchedCallableApis', 'eligibleSupportedApiPairs', 'exercisedApiCount', 'unsupportedApiCount', 'generatedScenarios', 'stableScenarios', 'divergenceCount')) {
            if ([int]$report.$metric -ne [int]$consoleMetrics[$metric]) {
                throw "$($target.id) console/JSON metric mismatch for $metric."
            }
        }

        $witness = Get-DivergenceStats -Report $report
        $targetResults.Add([ordered]@{
            id = $target.id
            role = $target.role
            packageId = $target.packageId
            baseline = $target.baseline
            candidate = $target.candidate
            dependencies = @($target.dependencies)
            reportPath = "bench/results/real-targets/$($target.id).json"
            consolePath = "bench/results/real-targets/$($target.id).console.txt"
            reportSha512 = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA512).Hash
            report = [ordered]@{
                resultState = $report.resultState
                trustworthy = $report.trustworthy
                discoveredBaselineApis = $report.discoveredBaselineApis
                discoveredCandidateApis = $report.discoveredCandidateApis
                matchedCallableApis = $report.matchedCallableApis
                eligibleSupportedApiPairs = $report.eligibleSupportedApiPairs
                supportedApiPercentage = $report.supportedApiPercentage
                exercisedApiCount = $report.exercisedApiCount
                generatedScenarios = $report.generatedScenarios
                stableScenarios = $report.stableScenarios
                divergenceCount = $report.divergenceCount
                inconclusiveCount = $report.inconclusiveCount
                unsupportedCount = $report.unsupportedCount
                unsupportedApiCount = $report.unsupportedApiCount
                unsupportedOrInconclusiveRate = $report.unsupportedOrInconclusiveRate
                executionFailureCount = $report.executionFailureCount
            }
            groundTruth = 'not-available-for-published-version-pair'
            precision = $null
            recall = $null
            timings = [ordered]@{
                consoleMedianComparisonMilliseconds = $consoleMetrics.medianComparisonMilliseconds
                consoleMedianMinimizationMilliseconds = $consoleMetrics.medianMinimizationMilliseconds
                jsonProcessWallClockMilliseconds = $jsonRun.ElapsedMilliseconds
                repeatJsonProcessWallClockMilliseconds = $repeatRun.ElapsedMilliseconds
            }
            reproducibility = [ordered]@{
                repeatedJsonExitCode = $repeatRun.ExitCode
                repeatedJsonByteIdentical = $true
            }
            minimization = $witness
            customFactoriesOrGenerators = $false
        })
    }

    $summary = [ordered]@{
        schemaVersion = 1
        generatedFor = 'real-library-feasibility'
        configuration = $config
        engineAssemblySha512 = $toolHash
        engineBuildContract = [ordered]@{
            configuration = 'Release'
            targetFramework = 'net8.0'
            version = '0.1.0'
            packageVersion = '0.1.0'
            deterministic = $true
            continuousIntegrationBuild = $true
            deterministicSourcePaths = $true
            pathMap = '$(MSBuildProjectDirectory)=/_/'
            includeSourceRevisionInInformationalVersion = $false
            debugType = 'none'
            debugSymbols = $false
            sourceRevisionId = 'empty for the hash-only DLL build'
            repositoryCommit = 'empty for the hash-only DLL build'
            refSelection = 'exact full SHA passed to Test-EngineReproducibility.ps1 -Commit'
        }
        timingContract = [ordered]@{
            version = 1
            classification = 'environment-specific-volatile'
            acceptedVariability = 'Timing values may vary between runs, machines, SDK patch versions, and host load. No exact equality or numeric tolerance is required.'
            stableEquality = 'Committed equality covers report JSON bytes and hashes, counts, classifications, API signatures, observations, witnesses, package identities, and reproducibility outcomes.'
            volatileFields = @(
                'targets[].timings.consoleMedianComparisonMilliseconds'
                'targets[].timings.consoleMedianMinimizationMilliseconds'
                'targets[].timings.jsonProcessWallClockMilliseconds'
                'targets[].timings.repeatJsonProcessWallClockMilliseconds'
                'environment'
                'console timing lines'
            )
        }
        environment = $environment
        groundTruthNote = 'Published-version comparisons have no planted oracle. Precision and recall are reported by the committed synthetic benchmark; real-target fields are null rather than inferred.'
        targets = $targetResults
    }
    Assert-StableEvidence -Summary $summary

    New-Item -ItemType Directory -Path $rawResultsDirectory -Force | Out-Null
    foreach ($target in $metadata.targets) {
        Copy-Item -LiteralPath (Join-Path $generatedResultsDirectory "$($target.id).json") -Destination (Join-Path $rawResultsDirectory "$($target.id).json") -Force
        Copy-Item -LiteralPath (Join-Path $generatedResultsDirectory "$($target.id).console.txt") -Destination (Join-Path $rawResultsDirectory "$($target.id).console.txt") -Force
    }
    [IO.File]::WriteAllText($committedSummaryPath, ($summary | ConvertTo-Json -Depth 30), $utf8)
    Write-Output "Real-library benchmark completed. Raw results: $rawResultsDirectory"
}
finally {
    if (-not $KeepScratch -and (Test-Path -LiteralPath $scratch)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    } else {
        Write-Output "Scratch retained: $scratch"
    }
}
