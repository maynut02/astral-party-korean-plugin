#requires -Version 7.0
# Shared tag history and SemVer handling for builds and releases.
function ConvertTo-AstralVersion {
    param([string]$Value, [switch]$Tag, [switch]$Release)

    $prefix = if ($Tag) { 'v' } else { '' }
    $suffix = if ($Tag -or $Release) { '' } else { '(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?' }
    $match = [regex]::Match($Value, '\A' + $prefix + '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' + $suffix + '\z')
    if (-not $match.Success) { throw "Version must contain canonical ${prefix}X.Y.Z$(if (-not ($Tag -or $Release)) { ' SemVer (optional prerelease/build metadata)' })." }
    for ($index = 1; $index -le 3; $index++) {
        $parsed = 0
        if (-not [int]::TryParse($match.Groups[$index].Value, [ref]$parsed) -or $parsed -gt 65534) {
            throw 'Version components must be between 0 and 65534 for .NET assembly metadata.'
        }
    }
    if ($Tag) { return $Value.Substring(1) }
    return $Value
}

function Get-AstralNextVersion {
    param([string]$Version, [ValidateSet('patch', 'minor', 'major')][string]$Bump)

    $numeric = [Version](ConvertTo-AstralVersion $Version -Release)
    $major = $numeric.Major
    $minor = $numeric.Minor
    $patch = $numeric.Build
    switch ($Bump) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        'patch' { $patch++ }
    }
    return ConvertTo-AstralVersion ('{0}.{1}.{2}' -f $major, $minor, $patch) -Release
}

function Invoke-AstralGit {
    param([string]$Root, [string[]]$Arguments)

    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
    $savedEncoding = [Console]::OutputEncoding
    $savedPreference = $ErrorActionPreference
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $ErrorActionPreference = 'Continue'
        $output = @(& $git -c i18n.logOutputEncoding=utf-8 -C $Root @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $savedEncoding
        $ErrorActionPreference = $savedPreference
    }
    if ($code -ne 0) { throw "Git failed ($($Arguments[0])): $($output -join "`n")" }
    return ($output -join "`n")
}

# Every ZIP entry carries the release commit's time: one commit always yields the same archive digest,
# and installed files show when the release was made instead of a placeholder date.
function Get-AstralSourceTimestamp([string]$Root) {
    $seconds = [long](Invoke-AstralGit $Root @('log', '-1', '--format=%ct', 'HEAD'))
    # ZIP stores wall-clock time without a zone and extractors read it as local time; players are on KST.
    return [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToOffset([TimeSpan]::FromHours(9))
}

function Get-AstralVersionPlan {
    param([Parameter(Mandatory)][string]$Root, [ValidateSet('auto', 'patch', 'minor', 'major')][string]$Bump = 'auto', [string]$Version = '', [switch]$Development)

    . (Join-Path $PSScriptRoot 'release-notes.ps1')
    if ($Version -and $Bump -ne 'auto') { throw 'Choose either -Bump or -Version, not both.' }
    if ((Invoke-AstralGit $Root @('rev-parse', '--is-shallow-repository')) -eq 'true') {
        throw 'Version calculation requires full Git history. Fetch the complete history and release tags first.'
    }
    $head = Invoke-AstralGit $Root @('rev-parse', '--verify', 'HEAD^{commit}')
    $tags = Invoke-AstralGit $Root @('tag', '--merged', $head, '--list', 'v*')
    $eligible = @($tags -split "`n" | ForEach-Object {
        try {
            $number = ConvertTo-AstralVersion $_ -Tag
            [pscustomobject]@{ Tag = $_; Number = [Version]$number }
        } catch { } # Ignore unrelated or out-of-range tag names.
    } | Sort-Object Number -Descending)
    $previousTag = if ($eligible.Count) { $eligible[0].Tag } else { '' }
    $previous = if ($eligible.Count) { $eligible[0].Number.ToString() } else { '0.0.0' }
    $range = if ($previousTag) { "$previousTag..$head" } else { $head }
    $log = Invoke-AstralGit $Root @('log', '--no-merges', '--reverse', '-z', '--format=%H%x00%B', $range, '--')
    $commits = @(ConvertFrom-AstralCommitLog -Log $log)
    $count = [int](Invoke-AstralGit $Root @('rev-list', '--count', $range, '--'))
    $detected = 'none'
    foreach ($commit in $commits) {
        if ($commit.Breaking) { $detected = 'major'; break }
        if ($commit.Type -eq 'feat') { $detected = 'minor' }
        elseif ($detected -eq 'none' -and $commit.Type -in @('fix', 'perf', 'revert')) { $detected = 'patch' }
    }
    $automatic = $detected
    if ($automatic -eq 'major' -and ([Version]$previous).Major -eq 0) { $automatic = 'minor' }
    $selected = if ($Bump -eq 'auto') { $automatic } else { $Bump }
    if ($Version) {
        $target = ConvertTo-AstralVersion $Version -Release
        if ([Version]$target -le [Version]$previous) { throw 'An explicit version must be newer than the previous release.' }
    } else {
        if ($selected -eq 'none') {
            if (-not $Development) { throw 'No release changes found. Use -Bump patch/minor/major for an intentional release.' }
            $selected = 'patch'
        }
        $target = Get-AstralNextVersion -Version $previous -Bump $selected
    }
    $tag = "v$target"
    if (-not $Development -and (Invoke-AstralGit $Root @('tag', '--list', $tag))) { throw 'The target release tag already exists. Select a newer version or retry upload-release.ps1 with the existing assets.' }
    [pscustomobject]@{
        Version = if ($Development) { "$target-dev.$count" } else { $target }
        Tag = $tag
        PreviousTag = $previousTag
        DetectedBump = $detected
        CommitCount = $count
        SourceCommit = $head
        Commits = $commits
    }
}
