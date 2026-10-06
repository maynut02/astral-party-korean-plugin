#requires -Version 7.0
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixtureParent = Join-Path $repoRoot ('.work/upload-tests/' + [Guid]::NewGuid().ToString('N'))
$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$utf8 = [Text.UTF8Encoding]::new($false)
$tag = 'v0.0.1'
$zipName = "AstralPartyKoreanPlugin-$tag.zip"
$assetNames = @($zipName, 'SHA256SUMS.txt')
$dllEntry = @(
    'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll'
    'BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll'
)
$otherSha = '1' * 40
$script:passed = 0
Add-Type -AssemblyName System.IO.Compression.FileSystem

# This external script is the only gh command the upload may resolve. Every call
# is recorded before handling it; state survives calls and failed-upload retries.
# Never use exit here: the mock runs in the test's PowerShell process.
$ghStub = @'
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 1
$arguments = @($args | ForEach-Object { [string]$_ })
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$statePath = Join-Path $root '.work/gh/state.json'
$callsPath = Join-Path $root '.work/gh/calls.jsonl'
$encoding = [Text.UTF8Encoding]::new($false)
$state = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) -AsHashtable

function Get-MockOption([string]$Name) {
    $index = [Array]::IndexOf($arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $arguments.Count) { return $null }
    return $arguments[$index + 1]
}
function Save-MockState {
    [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state -Depth 50), $encoding)
}
function Write-MockFailure([string]$Message) {
    $global:LASTEXITCODE = 1
    Write-Output $Message
}
function Write-MockJson($Value) {
    $global:LASTEXITCODE = 0
    ConvertTo-Json -InputObject $Value -Depth 50 -Compress
}

$call = @{ Arguments = $arguments; Files = @(); Notes = $null }
if ($arguments.Count -ge 2 -and $arguments[0] -ceq 'release') {
    if ($arguments[1] -ceq 'create' -and ($notes = Get-MockOption '--notes-file')) {
        $call.Notes = [IO.File]::ReadAllText($notes)
    }
    if ($arguments[1] -ceq 'upload') {
        # The script's upload contract has exactly one option pair after the tag.
        $call.Files = @(foreach ($path in $arguments[5..($arguments.Count - 1)]) {
            @{ Path = $path; Name = [IO.Path]::GetFileName($path); Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    }
}
[IO.File]::AppendAllText($callsPath, (ConvertTo-Json -InputObject $call -Depth 50 -Compress) + "`n", $encoding)

if ($arguments[0] -ceq 'auth') {
    if (($arguments -join '|') -cne 'auth|status|--hostname|github.com') {
        Write-MockFailure 'Mock rejected unexpected auth arguments.'; return
    }
    if ($state.Errors.Auth) { Write-MockFailure $state.Errors.Auth; return }
    $global:LASTEXITCODE = 0
    'Mock authenticated on github.com.'
    return
}
if ($arguments[0] -ceq 'api') {
    if ((Get-MockOption '--hostname') -cne 'github.com' -or (Get-MockOption '--method') -cne 'GET') {
        Write-MockFailure 'Mock rejected API host or method.'; return
    }
    $endpoint = $arguments[1]
    $prefix = "repos/$($state.Repository)"
    if ($endpoint -ceq $prefix) {
        if ($state.Errors.Repository) { Write-MockFailure $state.Errors.Repository; return }
        Write-MockJson @{ full_name = $state.FullName; permissions = @{ push = $state.PushPermission } }
        return
    }
    if ($endpoint -ceq "$prefix/commits/$($state.Head)") {
        if ($state.Errors.Commit) { Write-MockFailure $state.Errors.Commit; return }
        Write-MockJson @{ sha = $state.RemoteCommitSha }
        return
    }
    if ($endpoint -ceq "$prefix/git/ref/tags/$($state.TagName)") {
        if ($state.Errors.Tag) { Write-MockFailure $state.Errors.Tag; return }
        if ($null -eq $state.Tag) { Write-MockFailure 'gh: Not Found (HTTP 404)'; return }
        Write-MockJson $state.Tag
        return
    }
    if ($endpoint.StartsWith("$prefix/git/tags/", [StringComparison]::Ordinal)) {
        if ($state.Errors.TagObject) { Write-MockFailure $state.Errors.TagObject; return }
        $sha = $endpoint.Substring("$prefix/git/tags/".Length)
        if (-not $state.AnnotatedTags.ContainsKey($sha)) { Write-MockFailure 'gh: Not Found (HTTP 404)'; return }
        Write-MockJson $state.AnnotatedTags[$sha]
        return
    }
    if ($endpoint -ceq "$prefix/releases?per_page=100") {
        if (-not ($arguments -ccontains '--paginate') -or -not ($arguments -ccontains '--slurp')) {
            Write-MockFailure 'Mock requires paginated, slurped release listing.'; return
        }
        if ($state.Errors.Releases) { Write-MockFailure $state.Errors.Releases; return }
        if ($state.MutateSourceOnReleaseList) {
            [IO.File]::AppendAllText((Join-Path $root 'source.txt'), "changed during API preflight`n", $encoding)
            $state.MutateSourceOnReleaseList = $false
            Save-MockState
        }
        if ($state.MutateNotesOnReleaseList) {
            $notesPath = [IO.Path]::GetFullPath($state.MutateNotesOnReleaseList)
            $notesParent = [IO.Path]::GetFullPath((Join-Path $root '.work')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $notesPath.StartsWith($notesParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Mock notes mutation must stay inside the ignored fixture directory.' }
            [IO.File]::WriteAllText($notesPath, $state.ReplacementNotes, $encoding)
            $state.MutateNotesOnReleaseList = ''
            Save-MockState
        }
        # Put matches on the second page, including drafts. Preserve nested arrays
        # even when that page is empty or has only one release.
        $pages = [object[]]::new(2)
        $pages[0] = @(@{ tag_name = 'v9.9.9'; draft = $false; assets = @(); target_commitish = 'unrelated' })
        $pages[1] = @($state.Releases)
        Write-MockJson $pages
        return
    }
    Write-MockFailure "Mock rejected unknown API endpoint: $endpoint"
    return
}
if ($arguments[0] -ceq 'release' -and $arguments[2] -ceq $state.TagName) {
    if ((Get-MockOption '--repo') -cne "github.com/$($state.Repository)") {
        Write-MockFailure 'Mock rejected release repository selector.'; return
    }
    switch -CaseSensitive ($arguments[1]) {
        'create' {
            if ($state.Errors.Create) { Write-MockFailure $state.Errors.Create; return }
            if ($state.Releases.Count) { Write-MockFailure 'Mock release already exists.'; return }
            $state.Releases = @(@{
                tag_name = $arguments[2]; draft = ($arguments -ccontains '--draft')
                target_commitish = (Get-MockOption '--target'); name = (Get-MockOption '--title'); assets = @(); body = $call.Notes
            })
            Save-MockState
            $global:LASTEXITCODE = 0
            'https://github.com/owner/repo/releases/mock'
            return
        }
        'upload' {
            if (-not $state.Releases.Count) { Write-MockFailure 'Mock requires a release before upload.'; return }
            $release = $state.Releases[0]
            foreach ($file in $call.Files) {
                if (@($release.assets | Where-Object { $_.name -ceq $file.Name }).Count) {
                    Write-MockFailure 'Mock refuses to overwrite an asset.'; return
                }
                $release.assets = @($release.assets) + @(@{ name = $file.Name; digest = "sha256:$($file.Hash)"; state = 'uploaded' })
                if ($state.PartialUploadFailure) {
                    $state.PartialUploadFailure = $false
                    Save-MockState
                    Write-MockFailure 'Mock partial upload failure.'
                    return
                }
            }
            Save-MockState
            $global:LASTEXITCODE = 0
            'Mock uploaded.'
            return
        }
        'edit' {
            if ($state.Errors.Edit) { Write-MockFailure $state.Errors.Edit; return }
            if (-not $state.Releases.Count -or -not ($arguments -ccontains '--draft=false')) {
                Write-MockFailure 'Mock rejected release edit.'; return
            }
            $state.Releases[0].draft = $false
            if ($null -eq $state.Tag) { $state.Tag = @{ object = @{ type = 'commit'; sha = $state.Head } } }
            Save-MockState
            $global:LASTEXITCODE = 0
            'Mock published.'
            return
        }
        'download' {
            if ($state.Errors.Download) { Write-MockFailure $state.Errors.Download; return }
            $name = Get-MockOption '--pattern'
            if ($name -cnotin @($state.ZipName, 'SHA256SUMS.txt')) { Write-MockFailure 'Mock rejected download pattern.'; return }
            $destination = Get-MockOption '--dir'
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            $path = Join-Path $destination $name
            if ($state.DownloadDifferent -ccontains $name) {
                [IO.File]::WriteAllText($path, 'different remote bytes', $encoding)
            } else {
                Copy-Item -LiteralPath (Join-Path $state.AssetRoot $name) -Destination $path
            }
            $global:LASTEXITCODE = 0
            'Mock downloaded.'
            return
        }
    }
}
Write-MockFailure "Mock rejected unknown gh command: $($arguments -join ' ')"
return
'@

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Sequence($Actual, $Expected, [string]$Message) {
    Assert-True ((@($Actual) -join "`0") -ceq (@($Expected) -join "`0")) $Message
}
function Assert-InstallationNotes([string]$Notes, [string]$Tag = 'v0.0.1') {
    Assert-True ($Notes.StartsWith('## 변경 사항') -and $Notes.Contains('## 설치')) 'Notes are missing the Korean change/install headings.'
    foreach ($token in @(
        'BepInEx 6', 'Unity IL2CPP Windows x64', "AstralPartyKoreanPlugin-$Tag.zip",
        'BepInEx/config/BepInEx.cfg', '### 기존 버전에서 업데이트',
        'AstralParty.DataUnity3dRedirect.dll', 'AstralParty.AddressablesInProcessPatch.dll'
    )) {
        Assert-True ($Notes.Contains($token)) "Installation notes are missing: $token"
    }
    Assert-True ($Notes -match '(?m)^\s*\|[^\r\n]*글로벌판[^\r\n]*8vJXnINT[^\r\n]*AstralParty_INT\.exe[^\r\n]*\|') 'Global installation table row is missing.'
    Assert-True ($Notes -match '(?m)^\s*\|[^\r\n]*중국판[^\r\n]*8vJXn6CN[^\r\n]*AstralParty_CN\.exe[^\r\n]*\|') 'Chinese installation table row is missing.'
    # Installation paths may be shown as full paths or as a fenced directory tree.
    Assert-True ($Notes.Contains($dllEntry[0]) -or $Notes -match '(?m)^BepInEx/\r?\n(?:[^\r\n]*\r?\n)*?[^\r\n]*patchers/\r?\n[^\r\n]*AstralPartyKoreanPlugin\.dataUnity3dRedirect\.dll') 'Patcher DLL installation path is missing.'
    Assert-True ($Notes.Contains($dllEntry[1]) -or $Notes -match '(?m)^BepInEx/\r?\n(?:[^\r\n]*\r?\n)*?[^\r\n]*plugins/\r?\n[^\r\n]*AstralPartyKoreanPatch/\r?\n[^\r\n]*AstralPartyKoreanPlugin\.dll') 'Plugin DLL installation path is missing.'
    Assert-True ($Notes -match '\[[^\]\r\n]*README[^\]\r\n]*\]\([^)]+\)|\[[^\]\r\n]+\]\([^)]*README[^)]*\)|\[[^\]\r\n]+\]\(https://github\.com/maynut02/astral-party-korean-plugin#설치\)') 'Installation notes are missing a README link.'
    Assert-True (-not $Notes.Contains("`r") -and $Notes.EndsWith("`n")) 'Generated notes are not LF Markdown.'
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
function Invoke-TestGit([string]$Root, [string[]]$Arguments) {
    $output = @(& $git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join "`n")" }
    return ($output -join "`n")
}
function Write-Checksum($Fixture) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $Fixture.Assets $zipName) -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $Fixture.Assets 'SHA256SUMS.txt'), "$hash  $zipName`n", $utf8)
}
function Write-TestZip($Fixture, [string[]]$Entries = $dllEntry) {
    $path = Join-Path $Fixture.Assets $zipName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $entry = $archive.CreateEntry($name)
            $writer = [IO.StreamWriter]::new($entry.Open(), $utf8)
            try { $writer.Write('fixture DLL contents; upload never inspects assembly metadata') } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
    Write-Checksum $Fixture
}
function Save-State($Fixture, [hashtable]$State) {
    [IO.File]::WriteAllText($Fixture.StatePath, (ConvertTo-Json -InputObject $State -Depth 50), $utf8)
}
function Get-State($Fixture) {
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Fixture.StatePath)) -AsHashtable
}
function New-Fixture {
    $root = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
    $scripts = Join-Path $root 'scripts'
    $bin = Join-Path $root '.work/fixturebin'
    $stateRoot = Join-Path $root '.work/gh'
    $assets = Join-Path $root "dist/release/$tag"
    foreach ($path in @($scripts, $bin, $stateRoot, $assets)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/upload-release.ps1'), (Join-Path $repoRoot 'scripts/project-version.ps1'), (Join-Path $repoRoot 'scripts/release-notes.ps1'), (Join-Path $repoRoot 'scripts/prepare-release.ps1') -Destination $scripts
    [IO.File]::WriteAllText((Join-Path $scripts 'build.ps1'), "throw 'Upload must never invoke build.ps1.'", $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "0.0.1`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'source.txt'), "committed fixture source`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".work/`ndist/`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $bin 'gh.ps1'), $ghStub, $utf8)
    Invoke-TestGit $root @('init', '--initial-branch=main') | Out-Null
    Invoke-TestGit $root @('config', 'user.name', 'Release Upload Tests') | Out-Null
    Invoke-TestGit $root @('config', 'user.email', 'upload-tests@example.invalid') | Out-Null
    Invoke-TestGit $root @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-TestGit $root @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-TestGit $root @('config', 'core.hooksPath', '.work/disabled-hooks') | Out-Null
    Invoke-TestGit $root @('add', '--', 'VERSION', 'source.txt', '.gitignore', 'scripts') | Out-Null
    Invoke-TestGit $root @('commit', '-m', 'Fixture source and release scripts') | Out-Null
    Invoke-TestGit $root @('remote', 'add', 'origin', 'https://github.com/owner/repo.git') | Out-Null
    $fixture = [pscustomobject]@{
        Root = $root; Script = (Join-Path $scripts 'upload-release.ps1'); Bin = $bin
        Mock = (Join-Path $bin 'gh.ps1'); Assets = $assets
        StatePath = (Join-Path $stateRoot 'state.json'); CallsPath = (Join-Path $stateRoot 'calls.jsonl')
        Head = (Invoke-TestGit $root @('rev-parse', '--verify', 'HEAD^{commit}'))
    }
    Write-TestZip $fixture
    # Packaging may leave a standalone DLL locally. It must never be uploaded.
    [IO.File]::WriteAllText((Join-Path $assets 'AstralPartyKoreanPlugin.dll'), 'standalone DLL must stay local', $utf8)
    [IO.File]::WriteAllText($fixture.CallsPath, '', $utf8)
    Save-State $fixture @{
        Repository = 'owner/repo'; FullName = 'owner/repo'; PushPermission = $true
        Head = $fixture.Head; RemoteCommitSha = $fixture.Head; TagName = $tag; ZipName = $zipName
        AssetRoot = $assets; Tag = $null; AnnotatedTags = @{}; Releases = @()
        Errors = @{}; DownloadDifferent = @(); PartialUploadFailure = $false; MutateSourceOnReleaseList = $false
        MutateNotesOnReleaseList = ''; ReplacementNotes = ''
    }
    Assert-True ((Invoke-TestGit $root @('status', '--porcelain=v1', '--untracked-files=normal')) -eq '') 'Fixture must start clean.'
    return $fixture
}
function Sync-FixtureHead($Fixture) {
    $Fixture.Head = Invoke-TestGit $Fixture.Root @('rev-parse', '--verify', 'HEAD^{commit}')
    $state = Get-State $Fixture
    $state.Head = $Fixture.Head
    $state.RemoteCommitSha = $Fixture.Head
    Save-State $Fixture $state
}
function Add-FixtureCommit($Fixture, [string]$Message) {
    [IO.File]::AppendAllText((Join-Path $Fixture.Root 'source.txt'), ([Guid]::NewGuid().ToString('N') + "`n"), $utf8)
    Invoke-TestGit $Fixture.Root @('add', '--', 'source.txt', 'VERSION') | Out-Null
    Invoke-TestGit $Fixture.Root @('commit', '-m', $Message) | Out-Null
    Sync-FixtureHead $Fixture
    return [pscustomobject]@{ Subject = ($Message -split "`r?`n", 2)[0]; Sha = $Fixture.Head }
}
function New-ShallowFixture {
    $full = New-Fixture
    Add-FixtureCommit $full 'fix: shallow 이전 커밋' | Out-Null
    $root = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
    $url = ([Uri]::new($full.Root + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri
    Invoke-TestGit $fixtureParent @('clone', '--depth', '1', $url, $root) | Out-Null
    Invoke-TestGit $root @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
    # Restore only ignored mock state/assets; the production scripts are committed
    # in the local clone. No remote Git or GitHub command is executed.
    foreach ($name in @('.work', 'dist')) {
        Copy-Item -LiteralPath (Join-Path $full.Root $name) -Destination (Join-Path $root $name) -Recurse
    }
    $fixture = [pscustomobject]@{
        Root = $root; Script = (Join-Path $root 'scripts/upload-release.ps1')
        Bin = (Join-Path $root '.work/fixturebin'); Mock = (Join-Path $root '.work/fixturebin/gh.ps1')
        Assets = (Join-Path $root "dist/release/$tag")
        StatePath = (Join-Path $root '.work/gh/state.json'); CallsPath = (Join-Path $root '.work/gh/calls.jsonl')
        Head = $full.Head
    }
    $state = Get-State $fixture
    $state.AssetRoot = $fixture.Assets
    Save-State $fixture $state
    Assert-True ((Invoke-TestGit $root @('rev-parse', '--is-shallow-repository')) -ceq 'true') 'Fixture is not a real shallow Git clone.'
    Assert-True ((Invoke-TestGit $root @('status', '--porcelain=v1', '--untracked-files=normal')) -eq '') 'Shallow fixture must start clean.'
    return $fixture
}
function Invoke-FixtureUpload($Fixture, [hashtable]$Arguments = @{}) {
    $savedPath = $env:PATH
    try {
        $env:PATH = $Fixture.Bin + [IO.Path]::PathSeparator + $savedPath
        # Fail before invoking production code if command lookup could call real gh.
        $resolved = Get-Command gh -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
        Assert-True ($resolved.CommandType -eq 'ExternalScript' -and $resolved.Source -ieq $Fixture.Mock) 'Unsafe gh lookup: fixture gh.ps1 must precede any actual GitHub CLI.'
        & $Fixture.Script @Arguments
    } finally { $env:PATH = $savedPath }
}
function Get-Calls($Fixture) {
    foreach ($line in [IO.File]::ReadAllLines($Fixture.CallsPath)) {
        if ($line) { ConvertFrom-Json -InputObject $line -AsHashtable }
    }
}
function Get-ReleaseCalls($Fixture, [string]$Verb) {
    Get-Calls $Fixture | Where-Object { $_.Arguments[0] -ceq 'release' -and $_.Arguments[1] -ceq $Verb }
}
function Get-CallOption($Call, [string]$Name) {
    $index = [Array]::IndexOf([string[]]$Call.Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Call.Arguments.Count) { return $null }
    return $Call.Arguments[$index + 1]
}
function Assert-NoRemoteWrites($Fixture) {
    $writes = @(Get-Calls $Fixture | Where-Object { $_.Arguments[0] -ceq 'release' -and $_.Arguments[1] -cin @('create', 'upload', 'edit') })
    Assert-True ($writes.Count -eq 0) 'Rejected preflight attempted a release create/upload/edit.'
}
function Assert-NoCalls($Fixture) {
    Assert-True (@(Get-Calls $Fixture).Count -eq 0) 'Local validation or preview called gh.'
}
function Assert-SnapshotsCleaned($Fixture) {
    $parent = Join-Path $Fixture.Root '.work/upload-release'
    if (Test-Path -LiteralPath $parent) {
        Assert-True (@(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) 'Upload left its temporary snapshot behind.'
    }
}
function Get-AssetFingerprint($Fixture) {
    return (@(Get-ChildItem -LiteralPath $Fixture.Assets -File | Sort-Object Name | ForEach-Object {
        "$($_.Name)|$((Get-FileHash -LiteralPath $_.FullName).Hash)"
    }) -join "`n")
}
function Get-FixtureFingerprint($Fixture) {
    # Include content, timestamps and directories, excluding Git's internal index
    # housekeeping. State/calls, sources, scripts and dist are all included.
    $items = @(foreach ($child in Get-ChildItem -LiteralPath $Fixture.Root -Force) {
        if ($child.Name -ceq '.git') { continue }
        $child
        if ($child.PSIsContainer) { Get-ChildItem -LiteralPath $child.FullName -Force -Recurse }
    })
    return (@($items | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Fixture.Root, $_.FullName)
        if ($_.PSIsContainer) { "directory|$relative" }
        else { "file|$relative|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    }) -join "`n")
}
function Assert-Rejected($Fixture, [string]$Message, [hashtable]$Arguments = @{}) {
    $before = Get-AssetFingerprint $Fixture
    $failed = $false
    try { Invoke-FixtureUpload $Fixture $Arguments | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $failed = $true
    }
    Assert-True $failed "Expected upload rejection containing: $Message"
    Assert-NoRemoteWrites $Fixture
    Assert-True ((Get-AssetFingerprint $Fixture) -ceq $before) 'Rejected upload changed local release assets.'
    Assert-SnapshotsCleaned $Fixture
}
function New-RemoteAsset($Fixture, [string]$Name, [string]$Digest = 'matching', [string]$State = 'uploaded') {
    if ($Digest -ceq 'matching') { $Digest = 'sha256:' + (Get-FileHash -LiteralPath (Join-Path $Fixture.Assets $Name)).Hash.ToLowerInvariant() }
    return @{ name = $Name; digest = $Digest; state = $State }
}
function Set-ExistingRelease($Fixture, [bool]$Draft = $true, [string[]]$Names = @(), [switch]$WithTag) {
    $state = Get-State $Fixture
    $state.Releases = @(@{
        tag_name = $tag; draft = $Draft; target_commitish = $Fixture.Head
        assets = @(foreach ($name in $Names) { New-RemoteAsset $Fixture $name }); body = "기존 사용자 작성 본문 🎉`n"
    })
    if ($WithTag) { $state.Tag = @{ object = @{ type = 'commit'; sha = $Fixture.Head } } }
    Save-State $Fixture $state
}
function Assert-UploadFiles($Fixture, $Call, [string[]]$Expected) {
    Assert-Sequence @($Call.Files | ForEach-Object { $_.Name }) $Expected 'Upload did not include exactly the missing ZIP/checksum files.'
    Assert-Sequence $Call.Arguments[0..4] @('release', 'upload', $tag, '--repo', 'github.com/owner/repo') 'Unexpected upload arguments.'
    Assert-True ($Call.Arguments.Count -eq 5 + $Expected.Count -and -not ($Call.Arguments -ccontains '--clobber')) 'Upload added overwrite options or extra arguments.'
    $snapshotParent = [IO.Path]::GetFullPath((Join-Path $Fixture.Root '.work/upload-release')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($file in $Call.Files) {
        Assert-True ([IO.Path]::GetFullPath($file.Path).StartsWith($snapshotParent, [StringComparison]::OrdinalIgnoreCase)) 'Upload did not use the validated snapshot.'
        Assert-True ($file.Hash -ceq (Get-FileHash -LiteralPath (Join-Path $Fixture.Assets $file.Name)).Hash.ToLowerInvariant()) 'Uploaded snapshot differs from the local package.'
    }
}
function Assert-NotesSnapshot($Fixture, $Call, [string]$Expected) {
    $copy = Get-CallOption $Call '--notes-file'
    Assert-True (-not [string]::IsNullOrEmpty($copy) -and -not ($Call.Arguments -ccontains '--generate-notes')) 'New release must use --notes-file without --generate-notes.'
    $snapshotParent = [IO.Path]::GetFullPath((Join-Path $Fixture.Root '.work/upload-release')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    Assert-True ([IO.Path]::GetFullPath($copy).StartsWith($snapshotParent, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($copy) -ceq 'release-notes.md') 'Release notes did not come from the upload snapshot.'
    Assert-True ($Call.Notes -is [string] -and $Call.Notes -ceq $Expected) 'Notes snapshot did not preserve the complete UTF-8 body.'
}
function Test-Case([string]$CaseName, [scriptblock]$Body) {
    try { & $Body } catch { throw "Release upload test '$CaseName' failed: $($_.Exception.Message)" }
    $script:passed++
    Write-Output "PASS release upload: $CaseName"
}

try {
    Test-Case 'relative-assets-and-notes-resolve-from-the-caller-directory' {
        $f = New-Fixture
        $notesPath = Join-Path $f.Root '.work/relative-notes.md'
        $notes = "## Relative notes`nCaller directory regression`n"
        [IO.File]::WriteAllText($notesPath, $notes, $utf8)
        $before = Get-FixtureFingerprint $f
        Push-Location -LiteralPath $f.Root
        try {
            $result = Invoke-FixtureUpload $f @{ Preview = $true; AssetRoot = "dist/release/$tag"; NotesFile = '.work/relative-notes.md' }
        } finally { Pop-Location }
        Assert-True ($result.AssetRoot -ieq $f.Assets -and $result.Notes -ieq $notesPath -and $result.NotesContent -ceq $notes) 'Relative release paths used the process working directory.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Relative path preview changed fixture files.'
    }

    Test-Case 'fresh-release-is-draft-first-with-only-zip-checksum-and-git-notes-snapshot' {
        $f = New-Fixture
        $before = Get-AssetFingerprint $f
        Invoke-FixtureUpload $f | Out-Null
        $creates = @(Get-ReleaseCalls $f 'create')
        $uploads = @(Get-ReleaseCalls $f 'upload')
        $edits = @(Get-ReleaseCalls $f 'edit')
        Assert-True ($creates.Count -eq 1 -and $uploads.Count -eq 1 -and $edits.Count -eq 1) 'Fresh upload must create, upload, then publish once.'
        $notesCopy = Get-CallOption $creates[0] '--notes-file'
        Assert-Sequence $creates[0].Arguments @('release', 'create', $tag, '--repo', 'github.com/owner/repo', '--target', $f.Head, '--title', $tag, '--draft', '--notes-file', $notesCopy) 'Fresh create tag/title/target/draft/notes arguments differ.'
        Assert-NotesSnapshot $f $creates[0] $creates[0].Notes
        Assert-InstallationNotes $creates[0].Notes
        Assert-CommitNotes $creates[0].Notes @([pscustomobject]@{ Subject = 'Fixture source and release scripts'; Sha = $f.Head })
        Assert-UploadFiles $f $uploads[0] $assetNames
        Assert-Sequence $edits[0].Arguments @('release', 'edit', $tag, '--repo', 'github.com/owner/repo', '--draft=false') 'Unexpected publish arguments.'
        $calls = @(Get-Calls $f)
        Assert-Sequence @($calls | ForEach-Object { ($_.Arguments[0..1] -join ' ') }) @(
            'auth status', 'api repos/owner/repo', "api repos/owner/repo/commits/$($f.Head)",
            "api repos/owner/repo/git/ref/tags/$tag", 'api repos/owner/repo/releases?per_page=100',
            'release create', 'release upload', 'release edit'
        ) 'Preflight/write order differs.'
        foreach ($call in $calls | Where-Object { $_.Arguments[0] -ceq 'api' }) {
            Assert-True ((Get-CallOption $call '--hostname') -ceq 'github.com' -and (Get-CallOption $call '--method') -ceq 'GET') 'API must use fixed GitHub host and GET.'
        }
        $list = @($calls | Where-Object { $_.Arguments[1] -ceq 'repos/owner/repo/releases?per_page=100' })[0]
        Assert-True ($list.Arguments -ccontains '--paginate' -and $list.Arguments -ccontains '--slurp') 'Release listing did not request nested pages.'
        $state = Get-State $f
        Assert-True (-not $state.Releases[0].draft -and $state.Releases[0].assets.Count -eq 2) 'Fresh release was not published with exactly two assets.'
        Assert-True ((Get-AssetFingerprint $f) -ceq $before) 'Successful upload changed local release assets.'
        Assert-True ((Invoke-TestGit $f.Root @('status', '--porcelain')) -eq '') 'Upload changed source.'
        Assert-SnapshotsCleaned $f
    }

    foreach ($kind in @('prepared', 'explicit')) {
        Test-Case "$kind-utf8-korean-notes-are-snapshotted" {
            $f = New-Fixture
            $prepared = Join-Path $f.Root ".work/releases/$tag/release-notes.md"
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($prepared)) | Out-Null
            [IO.File]::WriteAllText($prepared, "# 준비된 릴리즈`n한글 채팅 수정`n", $utf8)
            $arguments = @{}
            $expected = [IO.File]::ReadAllText($prepared)
            $original = $prepared
            if ($kind -ceq 'explicit') {
                $original = Join-Path $f.Root '.work/custom notes 한글.md'
                $expected = "# 사용자 지정 노트`n메시지 입력 개선 🎉`n"
                [IO.File]::WriteAllText($original, $expected, $utf8)
                $arguments.NotesFile = $original
            }
            Invoke-FixtureUpload $f $arguments | Out-Null
            $create = @(Get-ReleaseCalls $f 'create')[0]
            $copy = Get-CallOption $create '--notes-file'
            Assert-True ($create.Notes -ceq $expected -and $copy -ine $original) 'Release notes were not copied verbatim as UTF-8.'
            Assert-NotesSnapshot $f $create $expected
            Assert-True ($copy.StartsWith((Join-Path $f.Root '.work/upload-release'), [StringComparison]::OrdinalIgnoreCase)) 'Notes did not come from the upload snapshot.'
            Assert-True (-not ($create.Arguments -ccontains '--generate-notes')) 'Explicit/prepared notes also requested generated notes.'
            Assert-True ([IO.File]::ReadAllText($original) -ceq $expected) 'Upload changed original release notes.'
            Assert-SnapshotsCleaned $f
        }
    }

    Test-Case 'draft-switch-never-publishes' {
        $f = New-Fixture
        Invoke-FixtureUpload $f @{ Draft = $true } | Out-Null
        Assert-True (@(Get-ReleaseCalls $f 'create').Count -eq 1 -and @(Get-ReleaseCalls $f 'upload').Count -eq 1) 'Draft upload skipped creation or assets.'
        Assert-True (@(Get-ReleaseCalls $f 'edit').Count -eq 0 -and (Get-State $f).Releases[0].draft) 'Draft upload published the release.'
        Assert-SnapshotsCleaned $f
    }

    Test-Case 'preview-has-no-gh-calls-or-filesystem-writes' {
        $f = New-Fixture
        $state = Get-State $f
        $state.Errors.Auth = 'Preview must not authenticate.'
        Save-State $f $state
        $before = Get-FixtureFingerprint $f
        $result = Invoke-FixtureUpload $f @{ Preview = $true; Draft = $true }
        Assert-True ($result.Preview -and $result.Draft -and $result.Repository -ceq 'owner/repo' -and $result.Tag -ceq $tag -and $result.Title -ceq $tag) 'Preview returned wrong release identity.'
        Assert-True ($result.SourceCommit -ceq $f.Head -and $result.AssetRoot -ieq $f.Assets -and $result.Notes -ceq 'Git commit history') 'Preview returned wrong source/assets/notes.'
        Assert-True ($result.NotesContent -is [string]) 'Preview did not return the full Markdown body as a string.'
        Assert-InstallationNotes $result.NotesContent
        Assert-CommitNotes $result.NotesContent @([pscustomobject]@{ Subject = 'Fixture source and release scripts'; Sha = $f.Head })
        Assert-Sequence $result.Assets $assetNames 'Preview exposed standalone DLL or other assets.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Preview wrote or changed fixture files.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Root '.work/upload-release'))) 'Preview created a snapshot directory.'
    }

    Test-Case 'fallback-lists-every-subject-and-short-sha-and-snapshots-preview-body' {
        $f = New-Fixture
        $expected = @([pscustomobject]@{ Subject = 'Fixture source and release scripts'; Sha = $f.Head })
        foreach ($message in @(
            "feat(chat): 한글 입력 🎉`n`nfix: 커밋 본문은 별도 항목이 아님",
            'docs: 중국판 설치 안내',
            '일반 커밋: 릴리즈 대상 기록',
            'fix: 글로벌판 입력 오류'
        )) {
            $expected += Add-FixtureCommit $f $message
        }
        $before = Get-FixtureFingerprint $f
        $preview = Invoke-FixtureUpload $f @{ Preview = $true }
        Assert-CommitNotes $preview.NotesContent $expected
        Assert-InstallationNotes $preview.NotesContent
        Assert-True (-not $preview.NotesContent.Contains('커밋 본문은 별도 항목이 아님')) 'Fallback included commit body lines as subjects.'
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Fallback preview changed fixture files.'
        Assert-NoCalls $f
        Invoke-FixtureUpload $f | Out-Null
        $creates = @(Get-ReleaseCalls $f 'create')
        Assert-True ($creates.Count -eq 1) 'Fallback did not create exactly one release.'
        Assert-NotesSnapshot $f $creates[0] $preview.NotesContent
        Assert-SnapshotsCleaned $f
    }

    Test-Case 'fallback-uses-highest-lower-reachable-canonical-tag-and-excludes-current-tag' {
        $f = New-Fixture
        [IO.File]::WriteAllText((Join-Path $f.Root 'VERSION'), "1.0.9`n", $utf8)
        Add-FixtureCommit $f 'chore: 1.0.9 릴리즈 준비' | Out-Null
        Invoke-TestGit $f.Root @('tag', 'v1.0.9') | Out-Null
        Add-FixtureCommit $f 'feat: 이전 릴리즈에 포함된 변경' | Out-Null
        Invoke-TestGit $f.Root @('tag', '-a', 'v1.0.10', '-m', 'Previous release') | Out-Null
        # Fork before the previous release so selecting this unreachable tag
        # incorrectly would also include that release's feature commit.
        Invoke-TestGit $f.Root @('checkout', '-b', 'unmerged', 'v1.0.9') | Out-Null
        Add-FixtureCommit $f 'feat: 미병합 브랜치 변경' | Out-Null
        Invoke-TestGit $f.Root @('tag', 'v1.0.19') | Out-Null
        Invoke-TestGit $f.Root @('checkout', 'main') | Out-Null
        $expected = @(Add-FixtureCommit $f 'docs: 새 설치 안내')
        [IO.File]::WriteAllText((Join-Path $f.Root 'VERSION'), "1.0.20`n", $utf8)
        $expected += Add-FixtureCommit $f 'fix: 이번 릴리즈 수정'
        Invoke-TestGit $f.Root @('tag', 'v1.0.20') | Out-Null
        # Put ignored tags on HEAD: selecting one would empty the notes range.
        foreach ($ignored in @('v01.0.19', 'v1.0.19-rc.1', 'v9.0.0')) {
            Invoke-TestGit $f.Root @('tag', $ignored) | Out-Null
        }
        $assets = Join-Path $f.Root '.work/range-assets'
        [IO.Directory]::CreateDirectory($assets) | Out-Null
        $name = 'AstralPartyKoreanPlugin-v1.0.20.zip'
        Copy-Item -LiteralPath (Join-Path $f.Assets $zipName) -Destination (Join-Path $assets $name)
        $hash = (Get-FileHash -LiteralPath (Join-Path $assets $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $assets 'SHA256SUMS.txt'), "$hash  $name`n", $utf8)
        $before = Get-FixtureFingerprint $f
        $result = Invoke-FixtureUpload $f @{ Preview = $true; AssetRoot = $assets }
        Assert-True ($result.Tag -ceq 'v1.0.20' -and $result.SourceCommit -ceq $f.Head -and $result.Notes -ceq 'Git commit history') 'Fallback preview lost its fixed source/version.'
        Assert-CommitNotes $result.NotesContent $expected
        Assert-InstallationNotes $result.NotesContent 'v1.0.20'
        Assert-True (-not $result.NotesContent.Contains('이전 릴리즈에 포함된 변경') -and -not $result.NotesContent.Contains('미병합 브랜치 변경')) 'Fallback included a previous release or an unreachable branch.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Tag-range preview changed fixture files.'
    }

    Test-Case 'fallback-excludes-merge-subject-and-keeps-merged-branch-commit' {
        $f = New-Fixture
        Invoke-TestGit $f.Root @('tag', 'v0.0.0') | Out-Null
        Invoke-TestGit $f.Root @('checkout', '-b', 'feature') | Out-Null
        $commit = Add-FixtureCommit $f 'feat: 병합된 브랜치 기능'
        Invoke-TestGit $f.Root @('checkout', 'main') | Out-Null
        Invoke-TestGit $f.Root @('merge', '--no-ff', 'feature', '-m', 'feat!: 릴리즈에 포함하면 안 되는 병합 제목') | Out-Null
        Sync-FixtureHead $f
        $before = Get-FixtureFingerprint $f
        $result = Invoke-FixtureUpload $f @{ Preview = $true }
        Assert-CommitNotes $result.NotesContent @($commit)
        Assert-True (-not $result.NotesContent.Contains('포함하면 안 되는 병합 제목')) 'Fallback included a merge commit subject.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Merged-history preview changed fixture files.'
    }

    Test-Case 'prepare-and-upload-fallback-produce-identical-complete-markdown' {
        $f = New-Fixture
        Add-FixtureCommit $f 'feat: 같은 한글 릴리즈 본문 🎉' | Out-Null
        Add-FixtureCommit $f 'docs: 설치 정보 보강' | Out-Null
        $result = & (Join-Path $f.Root 'scripts/prepare-release.ps1') -RepositoryRoot $f.Root
        $expected = [IO.File]::ReadAllText($result.NotesPath, $utf8)
        Assert-InstallationNotes $expected
        # Remove only ignored fixture output to force the independent Git fallback.
        Remove-Item -LiteralPath $result.NotesPath
        $before = Get-FixtureFingerprint $f
        $preview = Invoke-FixtureUpload $f @{ Preview = $true }
        Assert-True ($preview.Notes -ceq 'Git commit history' -and $preview.NotesContent -ceq $expected) 'Preparation and upload fallback produced different complete bodies.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Parity preview changed fixture files.'
        Invoke-FixtureUpload $f | Out-Null
        Assert-NotesSnapshot $f @(Get-ReleaseCalls $f 'create')[0] $expected
        Assert-True ((Invoke-TestGit $f.Root @('rev-parse', 'HEAD')) -ceq $f.Head -and (Invoke-TestGit $f.Root @('status', '--porcelain')) -eq '') 'Parity test changed committed source.'
        Assert-SnapshotsCleaned $f
    }

    foreach ($kind in @('prepared', 'explicit')) {
        Test-Case "preview-$kind-notes-preserve-priority-full-body-and-files" {
            $f = New-Fixture
            $prepared = Join-Path $f.Root ".work/releases/$tag/release-notes.md"
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($prepared)) | Out-Null
            [IO.File]::WriteAllText($prepared, "## 준비된 본문`n한글 입력 수정 🎉`n", $utf8)
            $path = $prepared
            $arguments = @{ Preview = $true }
            if ($kind -ceq 'explicit') {
                $path = Join-Path $f.Root '.work/explicit notes 한글.md'
                [IO.File]::WriteAllText($path, "## 직접 작성한 본문`n준비 파일보다 먼저 선택 🎉`n", $utf8)
                $arguments.NotesFile = $path
            }
            $expected = [IO.File]::ReadAllText($path, $utf8)
            $before = Get-FixtureFingerprint $f
            $result = Invoke-FixtureUpload $f $arguments
            Assert-True ($result.Notes -ieq $path -and $result.NotesContent -is [string] -and $result.NotesContent -ceq $expected) 'Preview lost notes file priority, path or complete UTF-8 body.'
            Assert-NoCalls $f
            Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Notes-file preview changed fixture files.'
        }
    }

    Test-Case 'prepared-notes-for-another-tag-do-not-suppress-git-fallback' {
        $f = New-Fixture
        $oldNotes = Join-Path $f.Root '.work/releases/v0.0.0/release-notes.md'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($oldNotes)) | Out-Null
        [IO.File]::WriteAllText($oldNotes, '이전 태그의 준비된 노트', $utf8)
        $before = Get-FixtureFingerprint $f
        $result = Invoke-FixtureUpload $f @{ Preview = $true }
        Assert-True ($result.Notes -ceq 'Git commit history' -and -not $result.NotesContent.Contains('이전 태그의 준비된 노트')) 'Upload used prepared notes from another tag.'
        Assert-CommitNotes $result.NotesContent @([pscustomobject]@{ Subject = 'Fixture source and release scripts'; Sha = $f.Head })
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Stale-notes preview changed fixture files.'
    }

    foreach ($kind in @('prepared', 'explicit')) {
        Test-Case "$kind-notes-are-frozen-before-mock-api-mutates-original" {
            $f = New-Fixture
            $path = if ($kind -ceq 'prepared') { Join-Path $f.Root ".work/releases/$tag/release-notes.md" } else { Join-Path $f.Root '.work/frozen notes 한글.md' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            $expected = "## 원래 한글 본문`n파일을 읽은 시점의 내용 🎉`n"
            [IO.File]::WriteAllText($path, $expected, $utf8)
            $arguments = @{}
            if ($kind -ceq 'explicit') { $arguments.NotesFile = $path }
            $state = Get-State $f
            $state.MutateNotesOnReleaseList = $path
            $state.ReplacementNotes = "API 검사 중 바뀐 내용`n"
            Save-State $f $state
            Invoke-FixtureUpload $f $arguments | Out-Null
            Assert-True ([IO.File]::ReadAllText($path, $utf8) -ceq $state.ReplacementNotes) 'Mock did not mutate the original notes during preflight.'
            Assert-NotesSnapshot $f @(Get-ReleaseCalls $f 'create')[0] $expected
            Assert-SnapshotsCleaned $f
        }
    }

    foreach ($draft in @($true, $false)) {
        Test-Case "existing-release-draft-$draft-keeps-user-body-despite-new-notes" {
            $f = New-Fixture
            Set-ExistingRelease $f -Draft $draft -Names $assetNames -WithTag
            $expected = (Get-State $f).Releases[0].body
            $path = Join-Path $f.Root '.work/replacement-notes.md'
            [IO.File]::WriteAllText($path, "업로더가 덮어쓰면 안 되는 새 본문`n", $utf8)
            Invoke-FixtureUpload $f @{ NotesFile = $path } | Out-Null
            Assert-True ((Get-State $f).Releases[0].body -ceq $expected) 'Upload overwrote the existing release body.'
            Assert-True (@(Get-ReleaseCalls $f 'create').Count -eq 0) 'Upload recreated an existing release.'
            $edits = @(Get-ReleaseCalls $f 'edit')
            if ($draft) {
                Assert-True ($edits.Count -eq 1) 'Existing draft did not publish once.'
                Assert-Sequence $edits[0].Arguments @('release', 'edit', $tag, '--repo', 'github.com/owner/repo', '--draft=false') 'Existing draft publication included a body rewrite.'
            } else { Assert-NoRemoteWrites $f }
            Assert-SnapshotsCleaned $f
        }
    }

    foreach ($preview in @($true, $false)) {
        Test-Case "shallow-git-fallback-preview-$preview-is-rejected-before-gh" {
            $f = New-ShallowFixture
            $before = Get-FixtureFingerprint $f
            Assert-Rejected $f 'full Git history' @{ Preview = $preview }
            Assert-NoCalls $f
            Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Shallow rejection changed fixture files.'
        }
    }

    foreach ($kind in @('prepared', 'explicit')) {
        Test-Case "shallow-$kind-notes-preview-bypasses-unneeded-history" {
            $f = New-ShallowFixture
            $path = if ($kind -ceq 'prepared') { Join-Path $f.Root ".work/releases/$tag/release-notes.md" } else { Join-Path $f.Root '.work/shallow-notes.md' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            $expected = "한글 파일 기반 릴리즈 본문 🎉`n"
            [IO.File]::WriteAllText($path, $expected, $utf8)
            $arguments = @{ Preview = $true }
            if ($kind -ceq 'explicit') { $arguments.NotesFile = $path }
            $before = Get-FixtureFingerprint $f
            $result = Invoke-FixtureUpload $f $arguments
            Assert-True ($result.Notes -ieq $path -and $result.NotesContent -ceq $expected) 'Shallow clone rejected valid notes or generated history instead.'
            Assert-NoCalls $f
            Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Shallow notes preview changed fixture files.'
        }
    }

    Test-Case 'missing-version-folder-does-not-use-old-dist-assets' {
        $f = New-Fixture
        foreach ($name in $assetNames) {
            $path = Join-Path $f.Assets $name
            Copy-Item -LiteralPath $path -Destination (Join-Path $f.Root "dist/$name")
            Remove-Item -LiteralPath $path
        }
        Assert-Rejected $f 'Missing release asset'
        Assert-NoCalls $f
    }

    Test-Case 'explicit-asset-root-overrides-version-folder' {
        $f = New-Fixture
        $customRoot = Join-Path $f.Root '.work/custom-assets'
        [IO.Directory]::CreateDirectory($customRoot) | Out-Null
        foreach ($name in $assetNames) {
            Copy-Item -LiteralPath (Join-Path $f.Assets $name) -Destination (Join-Path $customRoot $name)
        }
        $before = Get-FixtureFingerprint $f
        $result = Invoke-FixtureUpload $f @{ Preview = $true; AssetRoot = $customRoot }
        Assert-True ($result.AssetRoot -ieq $customRoot) 'Explicit asset directory was ignored.'
        Assert-Sequence $result.Assets $assetNames 'Custom directory preview exposed extra assets.'
        Assert-NoCalls $f
        Assert-True ((Get-FixtureFingerprint $f) -ceq $before) 'Custom directory preview changed fixture files.'
    }

    foreach ($probe in @('Auth', 'Repository', 'Commit', 'Tag', 'Releases')) {
        Test-Case "$probe-failure-blocks-all-release-writes" {
            $f = New-Fixture
            $state = Get-State $f
            $state.Errors[$probe] = "Mock $probe network/auth failure (HTTP 503)"
            Save-State $f $state
            Assert-Rejected $f "Mock $probe network/auth failure"
            Assert-True ((Get-State $f).Releases.Count -eq 0) 'Failed remote preflight created a release.'
        }
    }

    foreach ($kind in @('404', 'different-sha')) {
        Test-Case "remote-commit-$kind-blocks-publishing" {
            $f = New-Fixture
            $state = Get-State $f
            if ($kind -ceq '404') { $state.Errors.Commit = 'gh: Not Found (HTTP 404)' }
            else { $state.RemoteCommitSha = $otherSha }
            Save-State $f $state
            Assert-Rejected $f 'Source commit is not on GitHub'
        }
    }

    foreach ($kind in @('wrong-repository', 'no-push-permission')) {
        Test-Case "$kind-blocks-publishing" {
            $f = New-Fixture
            $state = Get-State $f
            if ($kind -ceq 'wrong-repository') { $state.FullName = 'someone/else' }
            else { $state.PushPermission = $false }
            Save-State $f $state
            Assert-Rejected $f 'does not match origin or lacks write permission'
        }
    }

    Test-Case 'tag-pointing-at-different-commit-is-rejected' {
        $f = New-Fixture
        $state = Get-State $f
        $state.Tag = @{ object = @{ type = 'commit'; sha = $otherSha } }
        Save-State $f $state
        Assert-Rejected $f 'Existing GitHub tag points to a different source commit'
    }

    Test-Case 'nested-annotated-tag-is-peeled-to-matching-commit' {
        $f = New-Fixture
        $state = Get-State $f
        $outer = '2' * 40
        $inner = '3' * 40
        $state.Tag = @{ object = @{ type = 'tag'; sha = $outer } }
        $state.AnnotatedTags[$outer] = @{ object = @{ type = 'tag'; sha = $inner } }
        $state.AnnotatedTags[$inner] = @{ object = @{ type = 'commit'; sha = $f.Head } }
        Save-State $f $state
        Invoke-FixtureUpload $f | Out-Null
        $peels = @(Get-Calls $f | Where-Object { $_.Arguments[0] -ceq 'api' -and $_.Arguments[1] -like 'repos/owner/repo/git/tags/*' })
        Assert-Sequence @($peels | ForEach-Object { $_.Arguments[1] }) @("repos/owner/repo/git/tags/$outer", "repos/owner/repo/git/tags/$inner") 'Annotated tag was not recursively peeled.'
        Assert-True (@(Get-ReleaseCalls $f 'edit').Count -eq 1) 'Matching annotated tag blocked publishing.'
    }

    Test-Case 'annotated-tag-api-failure-is-not-treated-as-missing-tag' {
        $f = New-Fixture
        $state = Get-State $f
        $state.Tag = @{ object = @{ type = 'tag'; sha = ('2' * 40) } }
        $state.Errors.TagObject = 'Mock annotated tag lookup failure (HTTP 503)'
        Save-State $f $state
        Assert-Rejected $f 'Mock annotated tag lookup failure'
    }

    foreach ($target in @('main', $otherSha)) {
        Test-Case "existing-draft-with-missing-tag-rejects-target-$target" {
            $f = New-Fixture
            Set-ExistingRelease $f
            $state = Get-State $f
            $state.Releases[0].target_commitish = $target
            Save-State $f $state
            Assert-Rejected $f 'Existing release does not identify the built source commit'
        }
    }

    Test-Case 'published-release-with-missing-tag-is-rejected' {
        $f = New-Fixture
        Set-ExistingRelease $f -Draft $false -Names $assetNames
        Assert-Rejected $f 'Existing release does not identify the built source commit'
    }

    Test-Case 'existing-published-matching-assets-need-no-upload-or-edit' {
        $f = New-Fixture
        Set-ExistingRelease $f -Draft $false -Names $assetNames -WithTag
        $before = Get-AssetFingerprint $f
        Invoke-FixtureUpload $f | Out-Null
        Assert-NoRemoteWrites $f
        Assert-True (@(Get-ReleaseCalls $f 'download').Count -eq 0) 'Matching digest unnecessarily downloaded an asset.'
        Assert-True ((Get-AssetFingerprint $f) -ceq $before) 'Idempotent upload changed local assets.'
        Assert-SnapshotsCleaned $f
    }

    Test-Case 'existing-draft-with-all-assets-remains-draft-when-requested' {
        $f = New-Fixture
        Set-ExistingRelease $f -Names $assetNames
        Invoke-FixtureUpload $f @{ Draft = $true } | Out-Null
        Assert-NoRemoteWrites $f
        Assert-True ((Get-State $f).Releases[0].draft) 'Existing draft was published despite Draft.'
    }

    foreach ($missing in $assetNames) {
        Test-Case "existing-draft-uploads-only-missing-$missing-then-publishes" {
            $f = New-Fixture
            $present = @($assetNames | Where-Object { $_ -cne $missing })
            Set-ExistingRelease $f -Names $present
            Invoke-FixtureUpload $f | Out-Null
            Assert-True (@(Get-ReleaseCalls $f 'create').Count -eq 0) 'Draft on second API page was not recognized.'
            $uploads = @(Get-ReleaseCalls $f 'upload')
            Assert-True ($uploads.Count -eq 1) 'Missing asset was not uploaded once.'
            Assert-UploadFiles $f $uploads[0] @($missing)
            Assert-True (@(Get-ReleaseCalls $f 'edit').Count -eq 1 -and -not (Get-State $f).Releases[0].draft) 'Completed draft was not published.'
            Assert-SnapshotsCleaned $f
        }
    }

    foreach ($kind in @('different-digest', 'not-uploaded', 'duplicate-name')) {
        Test-Case "existing-asset-$kind-is-rejected-without-overwrite" {
            $f = New-Fixture
            Set-ExistingRelease $f -Names @($zipName)
            $state = Get-State $f
            $asset = $state.Releases[0].assets[0]
            if ($kind -ceq 'different-digest') { $asset.digest = 'sha256:' + ('0' * 64) }
            elseif ($kind -ceq 'not-uploaded') { $asset.state = 'starter' }
            else { $state.Releases[0].assets = @($asset, $asset.Clone()) }
            Save-State $f $state
            $message = if ($kind -ceq 'duplicate-name') { 'Duplicate release asset' } else { 'Existing release asset differs' }
            Assert-Rejected $f $message
        }
    }

    Test-Case 'duplicate-releases-on-paginated-api-are-rejected' {
        $f = New-Fixture
        Set-ExistingRelease $f
        $state = Get-State $f
        $state.Releases = @($state.Releases[0], $state.Releases[0].Clone())
        Save-State $f $state
        Assert-Rejected $f 'Multiple releases use this tag'
    }

    foreach ($name in $assetNames) {
        foreach ($kind in @('same', 'different')) {
            Test-Case "missing-digest-download-$name-$kind" {
                $f = New-Fixture
                Set-ExistingRelease $f -Draft $false -Names $assetNames -WithTag
                $state = Get-State $f
                $asset = @($state.Releases[0].assets | Where-Object { $_.name -ceq $name })[0]
                $asset.Remove('digest')
                if ($kind -ceq 'different') { $state.DownloadDifferent = @($name) }
                Save-State $f $state
                if ($kind -ceq 'same') { Invoke-FixtureUpload $f | Out-Null; Assert-NoRemoteWrites $f }
                else { Assert-Rejected $f 'Existing release asset differs' }
                $downloads = @(Get-ReleaseCalls $f 'download')
                Assert-True ($downloads.Count -eq 1 -and (Get-CallOption $downloads[0] '--pattern') -ceq $name) 'Digest fallback downloaded wrong assets.'
                Assert-SnapshotsCleaned $f
            }
        }
    }

    Test-Case 'malformed-digest-falls-back-to-file-hash' {
        $f = New-Fixture
        Set-ExistingRelease $f -Draft $false -Names $assetNames -WithTag
        $state = Get-State $f
        $state.Releases[0].assets[0].digest = 'sha256:bad'
        Save-State $f $state
        Invoke-FixtureUpload $f | Out-Null
        Assert-True (@(Get-ReleaseCalls $f 'download').Count -eq 1) 'Malformed digest bypassed download/hash validation.'
        Assert-NoRemoteWrites $f
    }

    Test-Case 'digest-fallback-download-failure-blocks-publishing' {
        $f = New-Fixture
        Set-ExistingRelease $f -Names @($zipName)
        $state = Get-State $f
        $state.Releases[0].assets[0].digest = $null
        $state.Errors.Download = 'Mock download failed (HTTP 503)'
        Save-State $f $state
        Assert-Rejected $f 'Mock download failed'
    }

    Test-Case 'partial-upload-retains-draft-and-local-assets-and-retries-missing-only' {
        $f = New-Fixture
        $state = Get-State $f
        $state.PartialUploadFailure = $true
        Save-State $f $state
        $before = Get-AssetFingerprint $f
        $failed = $false
        try { Invoke-FixtureUpload $f | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*Mock partial upload failure*') { throw }
            $failed = $true
        }
        Assert-True $failed 'Partial upload did not fail.'
        $state = Get-State $f
        Assert-True ($state.Releases.Count -eq 1 -and $state.Releases[0].draft -and $null -eq $state.Tag) 'Partial failure did not preserve an unpublished draft.'
        Assert-True ($state.Releases[0].target_commitish -ceq $f.Head) 'Draft lost its exact source target.'
        Assert-Sequence @($state.Releases[0].assets | ForEach-Object { $_.name }) @($zipName) 'Partial failure did not persist exactly the first uploaded asset.'
        Assert-True (@(Get-ReleaseCalls $f 'edit').Count -eq 0) 'Failed upload published the draft.'
        Assert-True ((Get-AssetFingerprint $f) -ceq $before) 'Partial upload failure changed local assets.'
        Assert-SnapshotsCleaned $f
        $firstUploads = @(Get-ReleaseCalls $f 'upload')
        Assert-UploadFiles $f $firstUploads[0] $assetNames
        Invoke-FixtureUpload $f | Out-Null
        $uploads = @(Get-ReleaseCalls $f 'upload')
        Assert-True ($uploads.Count -eq 2 -and @(Get-ReleaseCalls $f 'create').Count -eq 1) 'Retry recreated the release or repeated the wrong uploads.'
        Assert-UploadFiles $f $uploads[1] @('SHA256SUMS.txt')
        Assert-True (@(Get-ReleaseCalls $f 'edit').Count -eq 1 -and -not (Get-State $f).Releases[0].draft) 'Retry did not publish the completed draft once.'
        Assert-True ((Get-AssetFingerprint $f) -ceq $before) 'Retry changed local assets.'
        Assert-SnapshotsCleaned $f
    }

    foreach ($missing in $assetNames) {
        Test-Case "missing-local-$missing-is-rejected-before-gh" {
            $f = New-Fixture
            Remove-Item -LiteralPath (Join-Path $f.Assets $missing)
            Assert-Rejected $f "Missing release asset: $missing"
            Assert-NoCalls $f
        }
    }

    foreach ($kind in @('wrong-hash', 'extra-dll-line', 'wrong-case-name')) {
        Test-Case "checksum-$kind-is-rejected-before-gh" {
            $f = New-Fixture
            $manifestPath = Join-Path $f.Assets 'SHA256SUMS.txt'
            $manifest = [IO.File]::ReadAllText($manifestPath)
            if ($kind -ceq 'wrong-hash') { $manifest = ('0' * 64) + "  $zipName`n" }
            elseif ($kind -ceq 'extra-dll-line') { $manifest += ('0' * 64) + "  AstralPartyKoreanPlugin.dll`n" }
            else { $manifest = $manifest.Replace($zipName, $zipName.ToLowerInvariant()) }
            [IO.File]::WriteAllText($manifestPath, $manifest, $utf8)
            Assert-Rejected $f 'Release checksum must match the ZIP and contain only that ZIP'
            Assert-NoCalls $f
        }
    }

    foreach ($kind in @('extra-entry', 'wrong-installation-path', 'extra-license', 'extra-installation-instructions', 'missing-patcher-dll', 'missing-plugin-dll')) {
        Test-Case "zip-$kind-is-rejected-before-gh" {
            $f = New-Fixture
            $entries = switch -CaseSensitive ($kind) {
                'extra-entry' { $dllEntry + @('README.txt') }
                'wrong-installation-path' { @($dllEntry[0], 'AstralPartyKoreanPlugin.dll') }
                'extra-license' { $dllEntry + @('LICENSE') }
                'extra-installation-instructions' { $dllEntry + @('적용방법.txt') }
                'missing-patcher-dll' { @($dllEntry[1]) }
                'missing-plugin-dll' { @($dllEntry[0]) }
            }
            Write-TestZip $f $entries
            Assert-Rejected $f 'Release ZIP must contain only the two plugin DLLs at their installation paths.'
            Assert-NoCalls $f
        }
    }

    Test-Case 'missing-explicit-notes-is-rejected-before-gh' {
        $f = New-Fixture
        $prepared = Join-Path $f.Root ".work/releases/$tag/release-notes.md"
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($prepared)) | Out-Null
        [IO.File]::WriteAllText($prepared, '준비 파일이 있어도 없는 명시 파일은 거부', $utf8)
        Assert-Rejected $f 'Missing release notes file' @{ NotesFile = (Join-Path $f.Root '.work/missing-notes.md') }
        Assert-NoCalls $f
    }

    Test-Case 'tag-must-match-version-before-gh' {
        $f = New-Fixture
        Assert-Rejected $f 'Upload tag must match VERSION' @{ Tag = 'v0.0.2' }
        Assert-NoCalls $f
    }

    foreach ($kind in @('tracked', 'staged', 'untracked')) {
        Test-Case "dirty-$kind-source-is-rejected-before-gh" {
            $f = New-Fixture
            $leaf = if ($kind -ceq 'untracked') { 'new-source.txt' } else { 'source.txt' }
            [IO.File]::AppendAllText((Join-Path $f.Root $leaf), "dirty source`n", $utf8)
            if ($kind -ceq 'staged') { Invoke-TestGit $f.Root @('add', '--', $leaf) | Out-Null }
            Assert-Rejected $f 'Commit source changes before uploading'
            Assert-NoCalls $f
        }
    }

    Test-Case 'source-mutation-during-api-preflight-blocks-first-write' {
        $f = New-Fixture
        $state = Get-State $f
        $state.MutateSourceOnReleaseList = $true
        Save-State $f $state
        Assert-Rejected $f 'Source changed during upload preparation'
        Assert-True ([IO.File]::ReadAllText((Join-Path $f.Root 'source.txt')).Contains('changed during API preflight')) 'Mock never exercised the source recheck.'
    }

    foreach ($origin in @('https://github.com/owner/repo.git', 'https://github.com/owner/repo/', 'git@github.com:owner/repo.git', 'ssh://git@github.com/owner/repo.git')) {
        Test-Case "github-origin-$origin-is-accepted" {
            $f = New-Fixture
            Invoke-TestGit $f.Root @('remote', 'set-url', 'origin', $origin) | Out-Null
            Invoke-FixtureUpload $f | Out-Null
            Assert-True (@(Get-ReleaseCalls $f 'create').Count -eq 1 -and @(Get-ReleaseCalls $f 'edit').Count -eq 1) 'Valid GitHub HTTPS/SSH origin was rejected.'
        }
    }

    foreach ($origin in @('https://gitlab.com/owner/repo.git', 'git@example.com:owner/repo.git', 'https://github.com.evil.invalid/owner/repo.git', 'http://github.com/owner/repo.git')) {
        Test-Case "invalid-origin-$origin-is-rejected-before-gh" {
            $f = New-Fixture
            Invoke-TestGit $f.Root @('remote', 'set-url', 'origin', $origin) | Out-Null
            Assert-Rejected $f 'origin must identify a github.com repository using HTTPS or SSH'
            Assert-NoCalls $f
        }
    }

    Write-Output "Release upload tests passed: $script:passed cases (fixture gh.ps1 only; no GitHub calls)."
    # Expected failures set native/stub exit codes. A successful suite must exit 0.
    $global:LASTEXITCODE = 0
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureParent)
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work/upload-tests')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test fixture location.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
