#requires -Version 7.0
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$prepare = Join-Path $repoRoot 'scripts/prepare-release.ps1'
$releaseNotes = Join-Path $repoRoot 'scripts/release-notes.ps1'
$testRoot = Join-Path $repoRoot ('.work/release-preparation-tests/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0

function Invoke-TestGit([string]$Root, [string[]]$Arguments) {
    $output = @(& $git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join "`n")" }
    return ($output -join "`n")
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-InstallationNotes([string]$Notes, [string]$Tag) {
    Assert-True ($Notes.StartsWith('## 변경 사항') -and $Notes.Contains('## 설치')) 'Notes are missing the Korean change/install headings.'
    foreach ($token in @(
        'BepInEx 6', 'Unity IL2CPP Windows x64', "AstralPartyKoreanPlugin-$Tag.zip",
        'BepInEx/config/BepInEx.cfg',
        '### 기존 버전에서 업데이트', 'AstralParty.DataUnity3dRedirect.dll',
        'AstralParty.AddressablesInProcessPatch.dll'
    )) {
        Assert-True ($Notes.Contains($token)) "Installation notes are missing: $token"
    }
    Assert-True ($Notes -match '(?m)^\s*\|[^\r\n]*글로벌판[^\r\n]*8vJXnINT[^\r\n]*AstralParty_INT\.exe[^\r\n]*\|') 'Global installation table row is missing.'
    Assert-True ($Notes -match '(?m)^\s*\|[^\r\n]*중국판[^\r\n]*8vJXn6CN[^\r\n]*AstralParty_CN\.exe[^\r\n]*\|') 'Chinese installation table row is missing.'
    # Installation paths may be shown as full paths or as a fenced directory tree.
    Assert-True ($Notes.Contains('BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll') -or $Notes -match '(?m)^BepInEx/\r?\n(?:[^\r\n]*\r?\n)*?[^\r\n]*patchers/\r?\n[^\r\n]*AstralPartyKoreanPlugin\.dataUnity3dRedirect\.dll') 'Patcher DLL installation path is missing.'
    Assert-True ($Notes.Contains('BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll') -or $Notes -match '(?m)^BepInEx/\r?\n(?:[^\r\n]*\r?\n)*?[^\r\n]*plugins/\r?\n[^\r\n]*AstralPartyKoreanPatch/\r?\n[^\r\n]*AstralPartyKoreanPlugin\.dll') 'Plugin DLL installation path is missing.'
    Assert-True ($Notes -match '\[[^\]\r\n]*README[^\]\r\n]*\]\([^)]+\)|\[[^\]\r\n]+\]\([^)]*README[^)]*\)|\[[^\]\r\n]+\]\(https://github\.com/maynut02/astral-party-korean-plugin#설치\)') 'Installation notes are missing a README link.'
}
function Assert-CommitNotes([string]$Notes, [object[]]$Commits) {
    $changes = ($Notes -split '(?m)^## 설치', 2)[0]
    $lines = @($changes -split "`n" | Where-Object { $_ -match '^\s*- ' })
    Assert-True ($lines.Count -eq $Commits.Count) 'Notes did not list exactly the commits in the release range.'
    for ($index = 0; $index -lt $Commits.Count; $index++) {
        $commit = $Commits[$index]
        Assert-True ($lines[$index].Contains($commit.Subject) -and $lines[$index] -match "(?<![0-9a-f])$($commit.Sha.Substring(0, 7))(?![0-9a-f])") 'Notes lost a commit subject, seven-character SHA or history order.'
    }
}
function Add-TestCommit([string]$Root, [string]$Message) {
    [IO.File]::AppendAllText((Join-Path $Root 'source.txt'), ([Guid]::NewGuid().ToString('N') + "`n"), $utf8)
    Invoke-TestGit $Root @('add', '.') | Out-Null
    Invoke-TestGit $Root @('commit', '-m', $Message) | Out-Null
}
function New-TestRepository([string]$Name, [string]$Version = '0.0.1', [switch]$Released) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Invoke-TestGit $root @('init', '--initial-branch=main') | Out-Null
    Invoke-TestGit $root @('config', 'user.name', 'Release Tests') | Out-Null
    Invoke-TestGit $root @('config', 'user.email', 'release-tests@example.invalid') | Out-Null
    Invoke-TestGit $root @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-TestGit $root @('config', 'commit.gpgsign', 'false') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".work/`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`n", $utf8)
    Add-TestCommit $root 'chore: 초기 소스'
    if ($Released) { Invoke-TestGit $root @('tag', "v$Version") | Out-Null }
    return $root
}
function Assert-Rejected([string]$Root, [string]$Message, [hashtable]$Arguments = @{}) {
    $before = [IO.File]::ReadAllText((Join-Path $Root 'VERSION'))
    $failed = $false
    try { & $prepare -RepositoryRoot $Root @Arguments | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $failed = $true
    }
    Assert-True $failed 'Expected release preparation to fail.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $Root 'VERSION')) -ceq $before) 'Rejected preparation changed VERSION.'
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS release preparation: $Name"
}

try {
    Test-Case 'relative-repository-root-resolves-from-the-caller-directory' {
        $root = New-TestRepository 'relative-root' -Released
        Add-TestCommit $root 'fix: relative path regression'
        Push-Location -LiteralPath $testRoot
        try {
            $result = & $prepare -RepositoryRoot './relative-root' -Preview
            Assert-True ($result.Version -ceq '0.0.2' -and $result.SourceCommit -ceq (Invoke-TestGit $root @('rev-parse', 'HEAD'))) 'Relative repository root used the process working directory.'
        } finally { Pop-Location }
    }

    Test-Case 'first-release-keeps-0.0.1-and-generates-korean-notes' {
        $root = New-TestRepository 'first'
        Add-TestCommit $root 'feat: 채팅 기능 추가'
        Add-TestCommit $root 'fix: 입력 처리 수정'
        $result = & $prepare -RepositoryRoot $root
        Assert-True ($result.Version -ceq '0.0.1' -and $result.Tag -ceq 'v0.0.1' -and $result.Title -ceq 'v0.0.1') 'First release version changed.'
        Assert-True ($result.CommitCount -eq 3 -and -not $result.VersionChanged) 'First release did not aggregate history.'
        $notes = [IO.File]::ReadAllText($result.NotesPath)
        Assert-True ($notes.Contains('채팅 기능 추가') -and $notes.Contains('입력 처리 수정') -and $notes.Contains('BepInEx')) 'Korean release notes were corrupted.'
        Assert-InstallationNotes $notes $result.Tag
        Assert-True ((Invoke-TestGit $root @('tag', '--list')) -eq '') 'Preparation created a tag.'
        Assert-True ((Invoke-TestGit $root @('status', '--porcelain')) -eq '') 'Preparation changed source files.'
        $again = & $prepare -RepositoryRoot $root
        Assert-True ($again.Version -ceq '0.0.1') 'Repeated first release increased version.'
    }
    Test-Case 'many-fixes-bump-patch-once-and-repeat-after-version-commit' {
        $root = New-TestRepository 'patch' -Released
        1..3 | ForEach-Object { Add-TestCommit $root "fix: 수정 $_" }
        $head = Invoke-TestGit $root @('rev-parse', 'HEAD')
        $result = & $prepare -RepositoryRoot $root
        Assert-True ($result.Version -ceq '0.0.2' -and $result.CommitCount -eq 3 -and $result.VersionChanged) 'Batch did not produce one patch bump.'
        $again = & $prepare -RepositoryRoot $root
        Assert-True ($again.Version -ceq '0.0.2' -and -not $again.VersionChanged) 'Repeated preparation bumped twice.'
        Assert-True ((Invoke-TestGit $root @('rev-parse', 'HEAD')) -ceq $head) 'Preparation committed automatically.'
        Invoke-TestGit $root @('add', 'VERSION') | Out-Null
        Invoke-TestGit $root @('commit', '-m', 'chore: 릴리즈 버전 준비') | Out-Null
        $again = & $prepare -RepositoryRoot $root
        Assert-True ($again.Version -ceq '0.0.2' -and $again.CommitCount -eq 4) 'A version commit triggered another bump.'
    }
    Test-Case 'features-win-over-fixes-with-scopes-and-case' {
        $root = New-TestRepository 'minor' -Version '1.2.3' -Released
        Add-TestCommit $root 'fix: 버그 수정'
        Add-TestCommit $root 'Feat(chat): 메시지 알림 추가'
        Add-TestCommit $root 'docs: 사용법 수정'
        $result = & $prepare -RepositoryRoot $root
        Assert-True ($result.Version -ceq '1.3.0' -and $result.DetectedBump -ceq 'minor') 'Feature did not win over patch.'
    }
    foreach ($message in @('feat!: 서버 규약 변경', "refactor: 서버 규약 변경`n`nBREAKING CHANGE: 이전 서버와 호환되지 않음", "chore: 변경`n`nBREAKING-CHANGE: 이전 설정 제거")) {
        Test-Case "stable-breaking-$($script:passed)" {
            $root = New-TestRepository "breaking-$script:passed" -Version '1.2.3' -Released
            Add-TestCommit $root $message
            Assert-True ((& $prepare -RepositoryRoot $root).Version -ceq '2.0.0') 'Breaking change did not increase major.'
        }
    }
    Test-Case 'pre-1.0-breaking-is-minor-and-major-is-explicit' {
        $root = New-TestRepository 'early-breaking' -Released
        Add-TestCommit $root 'feat!: 이전 설정 제거'
        Assert-True ((& $prepare -RepositoryRoot $root).Version -ceq '0.1.0') 'Early breaking change did not increase minor.'
        Assert-True ((& $prepare -RepositoryRoot $root -Bump major).Version -ceq '1.0.0') 'Explicit stable promotion failed.'
    }
    Test-Case 'preview-has-no-writes' {
        $root = New-TestRepository 'preview' -Released
        Add-TestCommit $root 'fix: 입력 수정'
        $result = & $prepare -RepositoryRoot $root -Preview
        Assert-True ($result.Version -ceq '0.0.2' -and $result.Preview -and $result.NotesPath -eq '') 'Preview did not resolve version.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim() -ceq '0.0.1') 'Preview wrote VERSION.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.work'))) 'Preview wrote notes.'
    }
    Test-Case 'docs-only-do-not-trigger-release-and-override-is-available' {
        $root = New-TestRepository 'docs' -Released
        Add-TestCommit $root 'docs: 사용법 수정'
        Add-TestCommit $root 'chore: 검사 설정 수정'
        Assert-Rejected $root 'No release changes'
        Assert-True ((& $prepare -RepositoryRoot $root -Bump patch).Version -ceq '0.0.2') 'Manual patch override failed.'
    }
    foreach ($type in @('perf', 'revert')) {
        Test-Case "$type-is-patch" {
            $root = New-TestRepository $type -Released
            Add-TestCommit $root "${type}: 동작 변경"
            Assert-True ((& $prepare -RepositoryRoot $root).Version -ceq '0.0.2') 'Patch type not recognized.'
        }
    }
    Test-Case 'no-new-commits-do-not-release' {
        $root = New-TestRepository 'no-changes' -Released
        Assert-Rejected $root 'No release changes'
    }
    Test-Case 'next-release-analyzes-only-commits-after-manual-tag' {
        $root = New-TestRepository 'next' -Released
        Add-TestCommit $root 'feat: 기능 추가'
        $first = & $prepare -RepositoryRoot $root
        Invoke-TestGit $root @('add', 'VERSION') | Out-Null
        Invoke-TestGit $root @('commit', '-m', 'chore: 0.1.0 릴리즈 준비') | Out-Null
        Invoke-TestGit $root @('tag', '-a', 'v0.1.0', '-m', 'Manual release') | Out-Null
        Add-TestCommit $root 'fix: 새 버그 수정'
        $next = & $prepare -RepositoryRoot $root
        Assert-True ($next.Version -ceq '0.1.1' -and $next.PreviousTag -ceq 'v0.1.0' -and $next.CommitCount -eq 1) 'Next release included previous feature commits.'
        Assert-True (-not [IO.File]::ReadAllText($next.NotesPath).Contains('기능 추가')) 'Notes included old release changes.'
    }
    Test-Case 'numeric-tags-and-unrelated-branches' {
        $root = New-TestRepository 'tag-order' -Version '1.0.9' -Released
        Invoke-TestGit $root @('checkout', '-b', 'other') | Out-Null
        Add-TestCommit $root 'feat: 다른 브랜치 변경'
        Invoke-TestGit $root @('tag', 'v99.0.0') | Out-Null
        Invoke-TestGit $root @('checkout', 'main') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "1.0.10`n", $utf8)
        Add-TestCommit $root 'chore: 이전 릴리즈 준비'
        Invoke-TestGit $root @('tag', 'v1.0.10') | Out-Null
        Invoke-TestGit $root @('tag', 'v999.0.0-rc.1') | Out-Null
        Invoke-TestGit $root @('tag', 'v01.0.0') | Out-Null
        Add-TestCommit $root 'fix: 버그 수정'
        $result = & $prepare -RepositoryRoot $root
        Assert-True ($result.Version -ceq '1.0.11' -and $result.PreviousTag -ceq 'v1.0.10') 'Tag selection was not numeric/reachable.'
    }
    Test-Case 'merge-commit-is-excluded-but-branch-commits-are-analyzed' {
        $root = New-TestRepository 'merge' -Released
        Invoke-TestGit $root @('checkout', '-b', 'feature') | Out-Null
        Add-TestCommit $root 'feat: 브랜치 기능'
        $branchSha = Invoke-TestGit $root @('rev-parse', 'HEAD')
        Invoke-TestGit $root @('checkout', 'main') | Out-Null
        Invoke-TestGit $root @('merge', '--no-ff', 'feature', '-m', 'feat!: misleading merge message') | Out-Null
        $result = & $prepare -RepositoryRoot $root
        Assert-True ($result.Version -ceq '0.1.0' -and $result.CommitCount -eq 1 -and $result.DetectedBump -ceq 'minor') 'Merge analysis lost branch changes or included merge messages.'
        Assert-CommitNotes ([IO.File]::ReadAllText($result.NotesPath)) @([pscustomobject]@{ Subject = 'feat: 브랜치 기능'; Sha = $branchSha })
    }
    Test-Case 'new-feature-after-patch-preparation-needs-explicit-replan' {
        $root = New-TestRepository 'new-feature' -Released
        Add-TestCommit $root 'fix: 수정'
        & $prepare -RepositoryRoot $root | Out-Null
        Invoke-TestGit $root @('add', 'VERSION') | Out-Null
        Invoke-TestGit $root @('commit', '-m', 'chore: 버전 준비') | Out-Null
        Add-TestCommit $root 'feat: 새 기능'
        Assert-Rejected $root 'Prepared VERSION is too low'
        Assert-True ((& $prepare -RepositoryRoot $root -Bump minor).Version -ceq '0.1.0') 'Explicit replan failed.'
    }
    Test-Case 'explicit-version-and-repeat-keep-same-value' {
        $root = New-TestRepository 'explicit' -Released
        Add-TestCommit $root 'fix: 수정'
        $result = & $prepare -RepositoryRoot $root -Version '0.5.0'
        Assert-True ($result.Version -ceq '0.5.0') 'Explicit version was not used.'
        Assert-True ((& $prepare -RepositoryRoot $root).Version -ceq '0.5.0') 'Repeat overwrote explicit version.'
        Assert-Rejected $root 'must not decrease' @{ Version = '0.2.0' }
        Assert-Rejected $root 'would decrease' @{ Bump = 'patch' }
        Assert-Rejected $root 'canonical X.Y.Z' @{ Version = '0.05.0' }
        Assert-Rejected $root 'between 0 and 65534' @{ Version = '65535.0.0' }
    }
    Test-Case 'dirty-tracked-staged-and-untracked-source-are-blocked' {
        foreach ($kind in @('tracked', 'staged', 'untracked')) {
            $root = New-TestRepository "dirty-$kind" -Released
            Add-TestCommit $root 'fix: 수정'
            $leaf = if ($kind -eq 'untracked') { 'new.txt' } else { 'source.txt' }
            [IO.File]::AppendAllText((Join-Path $root $leaf), 'dirty', $utf8)
            if ($kind -eq 'staged') { Invoke-TestGit $root @('add', $leaf) | Out-Null }
            Assert-Rejected $root 'Commit source changes'
        }
    }
    Test-Case 'published-tag-version-mismatch-is-blocked' {
        $root = New-TestRepository 'tag-mismatch'
        Invoke-TestGit $root @('tag', 'v0.1.0') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "0.1.0`n", $utf8)
        Add-TestCommit $root 'fix: 수정'
        Assert-Rejected $root 'does not match its committed VERSION'
    }
    Test-Case 'older-version-file-is-blocked' {
        $root = New-TestRepository 'older' -Version '0.1.0' -Released
        [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "0.0.1`n", $utf8)
        Assert-Rejected $root 'older than the latest'
    }
    Test-Case 'target-tag-on-unmerged-branch-cannot-be-reused' {
        $root = New-TestRepository 'tag-collision' -Released
        Invoke-TestGit $root @('checkout', '-b', 'other') | Out-Null
        Add-TestCommit $root 'fix: 다른 수정'
        Invoke-TestGit $root @('tag', 'v0.0.2') | Out-Null
        Invoke-TestGit $root @('checkout', 'main') | Out-Null
        Add-TestCommit $root 'fix: 수정'
        Assert-Rejected $root 'target release tag already exists'
    }
    Test-Case 'shallow-history-is-blocked' {
        $original = New-TestRepository 'full' -Released
        Add-TestCommit $original 'fix: 수정'
        $shallow = Join-Path $testRoot 'shallow'
        $url = ([Uri]::new($original + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri
        Invoke-TestGit $testRoot @('clone', '--depth', '1', $url, $shallow) | Out-Null
        Assert-Rejected $shallow 'full Git history'
    }

    Test-Case 'all-subjects-and-short-shas-appear-once-in-reverse-git-order' {
        $root = New-TestRepository 'complete-notes' -Version '1.2.3' -Released
        $expected = @(foreach ($message in @(
            "Feat(chat): 한글 입력 개선 🎉`n`nfix: 본문은 별도 변경 항목이 아님`n`nBREAKING CHANGE: 이전 설정 형식 제거",
            'docs: 설치 안내 추가',
            '일반 커밋: 구분자 없이 기록한 변경',
            'fix: 두 번째 입력 오류 수정'
        )) {
            Add-TestCommit $root $message
            [pscustomobject]@{ Subject = ($message -split "`n", 2)[0]; Sha = (Invoke-TestGit $root @('rev-parse', 'HEAD')) }
        })
        $result = & $prepare -RepositoryRoot $root
        $notes = [IO.File]::ReadAllText($result.NotesPath, $utf8)
        Assert-True ($result.Version -ceq '2.0.0' -and $result.DetectedBump -ceq 'major' -and $result.CommitCount -eq 4) 'Shared parsing changed version selection or dropped non-release commits.'
        Assert-CommitNotes $notes $expected
        Assert-InstallationNotes $notes $result.Tag
        Assert-True (-not $notes.Contains('본문은 별도 변경 항목이 아님') -and -not $notes.Contains('chore: 초기 소스')) 'Notes included commit bodies or the previous release.'
    }

    Test-Case 'nul-log-parser-preserves-shas-types-and-breaking-markers' {
        . $releaseNotes
        $messages = @(
            "FeAt(chat): 한글 기능 🎉`n`n본문에 $([char]30)와 $([char]31) 구분자를 포함",
            'fix(input)!: 입력 형식 변경',
            "refactor: 규약 변경`r`n`r`nBREAKING CHANGE: 기존 규약 제거",
            "chore: 설정 변경`n`nBREAKING-CHANGE: 기존 설정 제거",
            '일반 한글 커밋'
        )
        $shas = @(('a' * 40), ('b' * 40), ('c' * 40), ('d' * 40), ('e' * 40))
        $log = (@(for ($index = 0; $index -lt $messages.Count; $index++) {
            "$($shas[$index])`0$($messages[$index])`n`0"
        }) -join '')
        $commits = @(ConvertFrom-AstralCommitLog -Log $log)
        Assert-True ($commits.Count -eq 5) 'NUL parsing split a multiline message or dropped a commit.'
        $types = @('feat', 'fix', 'refactor', 'chore', '')
        $breaking = @($false, $true, $true, $true, $false)
        for ($index = 0; $index -lt $messages.Count; $index++) {
            Assert-True ($commits[$index].Sha -ceq $shas[$index]) 'NUL parser changed a full commit SHA.'
            Assert-True ($commits[$index].Subject -ceq ($messages[$index] -split "`r?`n", 2)[0]) 'NUL parser changed a Korean subject or included its body.'
            Assert-True ($commits[$index].Type -ceq $types[$index] -and $commits[$index].Breaking -eq $breaking[$index]) 'NUL parser changed Conventional Commit type/breaking semantics.'
        }
    }

    Test-Case 'empty-commit-log-renders-a-markdown-string-with-installation-guide' {
        . $releaseNotes
        $commits = @(ConvertFrom-AstralCommitLog -Log '')
        Assert-True ($commits.Count -eq 0) 'Empty Git log produced a phantom commit.'
        $notes = New-AstralReleaseNotes -Tag 'v0.0.1' -Commits $commits
        Assert-True ($notes -is [string]) 'Release notes helper did not return one Markdown string.'
        Assert-True (-not $notes.Contains("`r") -and $notes.EndsWith("`n")) 'Release notes helper did not return LF Markdown.'
        Assert-InstallationNotes $notes 'v0.0.1'
    }

    Test-Case 'windows-powershell-5.1-preserves-korean-release-notes' {
        $root = New-TestRepository 'windows-powershell'
        Add-TestCommit $root 'feat: 한글 메시지 입력'
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $output = @(& $windowsPowerShell -NoProfile -File $prepare -RepositoryRoot $root 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell preparation failed: $($output -join "`n")" }
        $notes = [IO.File]::ReadAllText((Join-Path $root '.work/releases/v0.0.1/release-notes.md'))
        Assert-True ($notes.Contains('## 변경 사항') -and $notes.Contains('한글 메시지 입력')) 'Windows PowerShell corrupted UTF-8 text.'
    }

    Write-Output "Release preparation tests passed: $script:passed cases."
    # Failed Git probes in rejection tests must not become the pwsh process exit code.
    $global:LASTEXITCODE = 0
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work/release-preparation-tests')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test fixture location.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
