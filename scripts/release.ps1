#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$Preview,
    [ValidateSet('auto', 'patch', 'minor', 'major')][string]$Bump = 'auto',
    [string]$Version = '',
    [switch]$SkipChecks,
    [string]$SigningKeyPath = '',
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$RefsRoot = '',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [string]$DotNetPath = '',
    [string]$PythonPath = 'python'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'project-version.ps1')
. (Join-Path $PSScriptRoot 'package-files.ps1')
. (Join-Path $PSScriptRoot 'release-notes.ps1')
$top = Invoke-AstralGit $root @('rev-parse', '--show-toplevel')
if ([IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ine $root.TrimEnd('\', '/')) { throw 'Release must run from this Git repository.' }
if (Invoke-AstralGit $root @('status', '--porcelain=v1', '--untracked-files=normal')) { throw 'Commit source changes before releasing; a clean working tree is required.' }
$plan = Get-AstralVersionPlan -Root $root -Bump $Bump -Version $Version
$upstream = Invoke-AstralGit $root @('rev-parse', '--symbolic-full-name', '@{upstream}')
if (-not $upstream.StartsWith('refs/remotes/origin/', [StringComparison]::Ordinal)) { throw 'The current branch must track a branch on origin. Push HEAD with git push -u origin first.' }
try { Invoke-AstralGit $root @('merge-base', '--is-ancestor', $plan.SourceCommit, $upstream) | Out-Null }
catch { throw 'HEAD has not been pushed to the origin upstream. Push the source commit before releasing.' }
$origin = Invoke-AstralGit $root @('remote', 'get-url', 'origin')
$match = [regex]::Match($origin, '\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<repository>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?\z', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (-not $match.Success) { throw 'origin must identify a github.com repository using HTTPS or SSH.' }
$repository = $match.Groups['repository'].Value
if (-not $WorkRoot) { $WorkRoot = Join-Path $root '.work' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $root "dist/release/$($plan.Tag)" }
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkRoot)
$assets = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$keyPath = Get-AstralSigningKeyPath $SigningKeyPath
$notes = New-AstralReleaseNotes -Tag $plan.Tag -Commits $plan.Commits
if ($Preview) {
    [pscustomobject]@{
        Version = $plan.Version
        Tag = $plan.Tag
        PreviousTag = $plan.PreviousTag
        DetectedBump = $plan.DetectedBump
        CommitCount = $plan.CommitCount
        SourceCommit = $plan.SourceCommit
        Repository = $repository
        Upstream = $upstream
        Checks = -not [bool]$SkipChecks
        Assets = @(Get-AstralReleaseAssetNames $plan.Tag)
        AssetRoot = $assets
        SigningKeyPath = $keyPath
        NotesContent = $notes
        Steps = @('GitHub auth/repository/tag preflight', 'Checks (unless skipped)', 'Build and package both ZIPs', 'Sign and verify update.json; write checksums', 'Create annotated tag on HEAD', 'Push tag to origin', 'Create draft, upload verified assets, publish GitHub Release')
        Preview = $true
    }
    return
}
# Read-only remote validation precedes checks, downloads and any output files.
& (Join-Path $PSScriptRoot 'upload-release.ps1') -Tag $plan.Tag -Preflight | Out-Null
$key = Get-AstralSigningKey -Path $keyPath
$key.Dispose()
if (-not $SkipChecks) { & (Join-Path $PSScriptRoot 'check.ps1') -WorkRoot $work -DotNetPath $DotNetPath -PythonPath $PythonPath }
$packageArguments = @{ Version = $plan.Version; WorkRoot = $work; OutputRoot = $assets; RefsRoot = $RefsRoot; DotNetPath = $DotNetPath; SigningKeyPath = $keyPath; Repository = $repository }
if ($PSBoundParameters.ContainsKey('GameRoot')) { $packageArguments.GameRoot = $GameRoot }
& (Join-Path $PSScriptRoot 'package-release.ps1') @packageArguments
if ((Invoke-AstralGit $root @('rev-parse', '--verify', 'HEAD^{commit}')) -cne $plan.SourceCommit -or (Invoke-AstralGit $root @('status', '--porcelain=v1', '--untracked-files=normal'))) { throw 'Source changed during release preparation. No tag was created.' }
$notesPath = Join-Path $work "releases/$($plan.Tag)/release-notes.md"
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($notesPath)) | Out-Null
[IO.File]::WriteAllText($notesPath, $notes, [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'upload-release.ps1') -Tag $plan.Tag -AssetRoot $assets -NotesFile $notesPath -CreateTag
