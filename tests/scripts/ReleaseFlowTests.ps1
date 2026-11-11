#requires -Version 7.0
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/project-version.ps1')
. (Join-Path $repoRoot 'scripts/package-files.ps1')
$testRoot = Join-Path $repoRoot ('.work/release-flow-tests/' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$passed = 0
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Add-Commit([string]$Root, [string]$Message) {
    [IO.File]::AppendAllText((Join-Path $Root 'source.txt'), "change`n", $utf8)
    Invoke-AstralGit $Root @('add', '.') | Out-Null
    Invoke-AstralGit $Root @('commit', '-m', $Message) | Out-Null
}
function New-Fixture([string]$Name, [string]$Previous = '2.1.1') {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory((Join-Path $root 'scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root '.work')) | Out-Null
    foreach ($name in @('release.ps1', 'project-version.ps1', 'release-notes.ps1', 'package-files.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/$name") -Destination (Join-Path $root "scripts/$name") }
    $key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    try {
        $publicKey = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
        [IO.File]::WriteAllText((Join-Path $root '.work/key.pem'), [string]::new([Security.Cryptography.PemEncoding]::Write('PRIVATE KEY', $key.ExportPkcs8PrivateKey())), $utf8)
    } finally { $key.Dispose() }
    [IO.File]::AppendAllText((Join-Path $root 'scripts/package-files.ps1'), "`nfunction Get-AstralUpdatePublicKey { '$publicKey' }`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".work/`ndist/`n", $utf8)
    $uploadStub = @'
param([string]$Tag, [string]$AssetRoot, [string]$NotesFile, [switch]$Preflight, [switch]$CreateTag)
$root = Join-Path $PSScriptRoot '..'
if (Test-Path (Join-Path $root '.work/fail-auth')) { throw 'Fixture auth failed' }
if ($Preflight) {
    [IO.File]::AppendAllText((Join-Path $root '.work/order.txt'), "preflight`n")
    return
}
if (-not $CreateTag -or -not (Test-Path -LiteralPath $NotesFile)) { throw 'Release did not request annotated-tag publication with frozen notes.' }
[IO.File]::AppendAllText((Join-Path $root '.work/order.txt'), "publish:$Tag`n")
'@
    [IO.File]::WriteAllText((Join-Path $root 'scripts/upload-release.ps1'), $uploadStub, $utf8)
    $checkStub = @'
param([string]$WorkRoot, [string]$DotNetPath, [string]$PythonPath)
[IO.File]::AppendAllText((Join-Path $WorkRoot 'order.txt'), "checks`n")
if (Test-Path (Join-Path $WorkRoot 'fail-checks')) { throw 'Fixture checks failed' }
'@
    [IO.File]::WriteAllText((Join-Path $root 'scripts/check.ps1'), $checkStub, $utf8)
    $packageStub = @'
param([string]$Version, [string]$WorkRoot, [string]$OutputRoot, [string]$RefsRoot, [string]$DotNetPath, [string]$SigningKeyPath, [string]$Repository, [string]$GameRoot)
if ($Version -cne '3.0.0' -or $Repository -cne 'owner/repo' -or -not (Test-Path -LiteralPath $SigningKeyPath)) { throw 'Release lost the exact version/repository/signing key.' }
[IO.File]::AppendAllText((Join-Path $WorkRoot 'order.txt'), "package:$Version`n")
if (Test-Path (Join-Path $WorkRoot 'fail-package')) { throw 'Fixture package failed' }
if (Test-Path (Join-Path $WorkRoot 'mutate-source')) { [IO.File]::AppendAllText((Join-Path $PSScriptRoot '../source.txt'), "dirty`n") }
'@
    [IO.File]::WriteAllText((Join-Path $root 'scripts/package-release.ps1'), $packageStub, $utf8)
    Invoke-AstralGit $root @('init', '--initial-branch=main') | Out-Null
    Invoke-AstralGit $root @('config', 'user.name', 'Release Tests') | Out-Null
    Invoke-AstralGit $root @('config', 'user.email', 'release-tests@example.invalid') | Out-Null
    Invoke-AstralGit $root @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-AstralGit $root @('config', 'tag.gpgsign', 'false') | Out-Null
    Invoke-AstralGit $root @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-AstralGit $root @('config', 'core.hooksPath', '.work/disabled-hooks') | Out-Null
    Invoke-AstralGit $root @('remote', 'add', 'origin', 'https://github.com/owner/repo.git') | Out-Null
    Invoke-AstralGit $root @('config', 'branch.main.remote', 'origin') | Out-Null
    Invoke-AstralGit $root @('config', 'branch.main.merge', 'refs/heads/main') | Out-Null
    Add-Commit $root 'chore: initial source'
    if ($Previous) { Invoke-AstralGit $root @('tag', "v$Previous") | Out-Null }
    return $root
}
function Set-Pushed([string]$Root) { Invoke-AstralGit $Root @('update-ref', 'refs/remotes/origin/main', 'HEAD') | Out-Null }
function Assert-Rejected([scriptblock]$Body, [string]$Message) {
    $failed = $false
    try { & $Body | Out-Null } catch { if (-not $_.Exception.Message.Contains($Message)) { throw }; $failed = $true }
    Assert-True $failed "Expected rejection: $Message"
}
function Test-Case([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Output "PASS release flow: $Name" }
try {
    Test-Case 'breaking-history-from-2.1.1-is-3.0.0-and-dev-build-is-prerelease' {
        $root = New-Fixture 'breaking'
        Add-Commit $root 'feat!: new installation and update contract'
        Add-Commit $root 'docs: installation instructions'
        $plan = Get-AstralVersionPlan -Root $root
        Assert-True ($plan.Version -ceq '3.0.0' -and $plan.CommitCount -eq 2 -and $plan.PreviousTag -ceq 'v2.1.1') 'Breaking release plan differs.'
        Assert-True ((Get-AstralVersionPlan -Root $root -Development).Version -ceq '3.0.0-dev.2') 'Development build is not ahead of the latest tag.'
        Assert-True ((Get-AstralVersionPlan -Root $root).SourceCommit -ceq (Invoke-AstralGit $root @('rev-parse', 'HEAD'))) 'Repeated calculation changed HEAD.'
    }
    foreach ($case in @(
        @{ Name = 'patch'; Message = 'fix: correction'; Expected = '1.2.4' },
        @{ Name = 'perf'; Message = 'perf: faster'; Expected = '1.2.4' },
        @{ Name = 'revert'; Message = 'revert: old behavior'; Expected = '1.2.4' },
        @{ Name = 'minor'; Message = 'Feat(ui): overlay'; Expected = '1.3.0' },
        @{ Name = 'footer'; Message = "refactor: contract`n`nBREAKING CHANGE: incompatible"; Expected = '2.0.0' },
        @{ Name = 'hyphen-footer'; Message = "chore: contract`n`nBREAKING-CHANGE: incompatible"; Expected = '2.0.0' })) {
        Test-Case $case.Name {
            $root = New-Fixture $case.Name '1.2.3'
            Add-Commit $root $case.Message
            Assert-True ((Get-AstralVersionPlan -Root $root).Version -ceq $case.Expected) 'Conventional bump differs.'
        }
    }
    Test-Case 'pre-1.0-breaking-and-explicit-overrides' {
        $root = New-Fixture 'early' '0.2.3'
        Add-Commit $root 'feat!: break'
        Assert-True ((Get-AstralVersionPlan -Root $root).Version -ceq '0.3.0') 'Pre-1.0 breaking must bump minor.'
        Assert-True ((Get-AstralVersionPlan -Root $root -Bump major).Version -ceq '1.0.0') 'Explicit major must promote to stable.'
        Assert-True ((Get-AstralVersionPlan -Root $root -Version '2.0.0').Version -ceq '2.0.0') 'Explicit version lost.'
        Assert-Rejected { Get-AstralVersionPlan -Root $root -Version '0.2.3' } 'newer than'
        Assert-Rejected { Get-AstralVersionPlan -Root $root -Bump major -Version '2.0.0' } 'either -Bump or -Version'
    }
    Test-Case 'docs-only-and-zero-commits-still-get-safe-dev-versions' {
        $root = New-Fixture 'docs'
        Assert-True ((Get-AstralVersionPlan -Root $root -Development).Version -ceq '2.1.2-dev.0') 'Tagged dev build is not prerelease.'
        Add-Commit $root 'docs: instructions'
        Assert-Rejected { Get-AstralVersionPlan -Root $root } 'No release changes'
        Assert-True ((Get-AstralVersionPlan -Root $root -Bump patch).Version -ceq '2.1.2') 'Manual patch failed.'
        Assert-True ((Get-AstralVersionPlan -Root $root -Development).Version -ceq '2.1.2-dev.1') 'Docs dev build differs.'
    }
    Test-Case 'highest-reachable-stable-tag-wins-and-unmerged-target-cannot-be-reused' {
        $root = New-Fixture 'tags' '1.0.9'
        Add-Commit $root 'fix: previous release'
        Invoke-AstralGit $root @('tag', '-a', 'v1.0.10', '-m', 'Previous') | Out-Null
        Invoke-AstralGit $root @('checkout', '-b', 'unmerged') | Out-Null
        Add-Commit $root 'feat: unrelated'
        Invoke-AstralGit $root @('tag', 'v1.0.11') | Out-Null
        Invoke-AstralGit $root @('tag', 'v99.0.0') | Out-Null
        Invoke-AstralGit $root @('checkout', 'main') | Out-Null
        Add-Commit $root 'feat: current'
        Invoke-AstralGit $root @('tag', 'v01.0.99') | Out-Null
        Invoke-AstralGit $root @('tag', 'v9.0.0-rc.1') | Out-Null
        $plan = Get-AstralVersionPlan -Root $root
        Assert-True ($plan.Version -ceq '1.1.0' -and $plan.PreviousTag -ceq 'v1.0.10' -and $plan.CommitCount -eq 1) 'Tag selection included invalid/unreachable history.'
        Assert-Rejected { Get-AstralVersionPlan -Root $root -Version '1.0.11' } 'already exists'
    }
    Test-Case 'merge-subjects-do-not-increase-bump-but-count-toward-dev-number' {
        $root = New-Fixture 'merge' '1.2.3'
        Invoke-AstralGit $root @('checkout', '-b', 'feature') | Out-Null
        Add-Commit $root 'feat: merged functionality'
        Invoke-AstralGit $root @('checkout', 'main') | Out-Null
        Invoke-AstralGit $root @('merge', '--no-ff', 'feature', '-m', 'feat!: ignored merge title') | Out-Null
        $plan = Get-AstralVersionPlan -Root $root -Development
        Assert-True ($plan.Version -ceq '1.3.0-dev.2' -and $plan.Commits.Count -eq 1) 'Merge commits changed bump semantics or dev count.'
    }
    Test-Case 'shallow-history-is-rejected-without-remote-access' {
        $full = New-Fixture 'shallow-source'
        Add-Commit $full 'fix: correction'
        $clone = Join-Path $testRoot 'shallow-clone'
        $url = ([Uri]::new($full + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri
        Invoke-AstralGit $testRoot @('clone', '--depth', '1', $url, $clone) | Out-Null
        Assert-Rejected { Get-AstralVersionPlan -Root $clone } 'full Git history'
    }
    Test-Case 'first-release-has-a-tag-only-bootstrap-and-explicit-version-option' {
        $root = New-Fixture 'bootstrap' ''
        Add-Commit $root 'feat: initial feature'
        Assert-True ((Get-AstralVersionPlan -Root $root).Version -ceq '0.1.0') 'Tagless bootstrap did not use the zero baseline.'
        Assert-True ((Get-AstralVersionPlan -Root $root -Version '1.0.0').Version -ceq '1.0.0') 'Explicit first release failed.'
    }
    Test-Case 'preview-has-no-files-tags-checks-or-github-calls' {
        $root = New-Fixture 'preview'
        Add-Commit $root 'feat!: cutover'
        Set-Pushed $root
        $before = @(Get-ChildItem -LiteralPath (Join-Path $root '.work') -Recurse -File | ForEach-Object { $_.FullName }) -join '|'
        $plan = & (Join-Path $root 'scripts/release.ps1') -Preview
        Assert-True ($plan.Version -ceq '3.0.0' -and $plan.Tag -ceq 'v3.0.0' -and $plan.Assets.Count -eq 5 -and $plan.Checks -and $plan.Preview) 'Preview plan is incomplete.'
        Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $root '.work') -Recurse -File | ForEach-Object { $_.FullName }) -join '|') -ceq $before) 'Preview created outputs.'
        Assert-True ((Invoke-AstralGit $root @('tag', '--list', 'v3.0.0')) -eq '') 'Preview created a tag.'
    }
    foreach ($skip in @($false, $true)) {
        Test-Case "one-command-order-skipchecks-$skip" {
            $root = New-Fixture "order-$skip"
            Add-Commit $root 'feat!: cutover'
            Set-Pushed $root
            & (Join-Path $root 'scripts/release.ps1') -SigningKeyPath (Join-Path $root '.work/key.pem') -SkipChecks:$skip | Out-Null
            $expected = if ($skip) { "preflight`npackage:3.0.0`npublish:v3.0.0`n" } else { "preflight`nchecks`npackage:3.0.0`npublish:v3.0.0`n" }
            Assert-True ([IO.File]::ReadAllText((Join-Path $root '.work/order.txt')) -ceq $expected) 'Release stages ran out of order.'
        }
    }
    foreach ($kind in @('auth', 'checks', 'package', 'mutate-source', 'unpushed', 'dirty')) {
        Test-Case "failure-$kind-stops-before-publish" {
            $root = New-Fixture "failure-$kind"
            Add-Commit $root 'feat!: cutover'
            if ($kind -ne 'unpushed') { Set-Pushed $root }
            $message = switch ($kind) {
                'auth' { [IO.File]::WriteAllText((Join-Path $root '.work/fail-auth'), ''); 'Fixture auth failed' }
                'checks' { [IO.File]::WriteAllText((Join-Path $root '.work/fail-checks'), ''); 'Fixture checks failed' }
                'package' { [IO.File]::WriteAllText((Join-Path $root '.work/fail-package'), ''); 'Fixture package failed' }
                'mutate-source' { [IO.File]::WriteAllText((Join-Path $root '.work/mutate-source'), ''); 'Source changed' }
                'unpushed' { Invoke-AstralGit $root @('update-ref', 'refs/remotes/origin/main', 'HEAD~1') | Out-Null; 'not been pushed' }
                'dirty' { [IO.File]::AppendAllText((Join-Path $root 'source.txt'), 'dirty'); 'clean working tree' }
            }
            Assert-Rejected { & (Join-Path $root 'scripts/release.ps1') -SigningKeyPath (Join-Path $root '.work/key.pem') } $message
            $order = Join-Path $root '.work/order.txt'
            if (Test-Path $order) { Assert-True (-not [IO.File]::ReadAllText($order).Contains('publish')) 'Failed release published.' }
            Assert-True ((Invoke-AstralGit $root @('tag', '--list', 'v3.0.0')) -eq '') 'Failed release created a tag.'
        }
    }
    Write-Output "Release flow tests passed: $passed cases. No external service was used."
    $global:LASTEXITCODE = 0
} finally { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }
