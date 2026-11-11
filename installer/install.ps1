#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$GameRoot = '',
    [string]$SteamRoot = '',
    [ValidateSet('INT', 'CN')][string]$Edition,
    [switch]$Yes,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-FullDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\', '/')
}

function Find-Game([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    foreach ($variant in @(
        @{ Edition = 'INT'; Folder = '8vJXnINT'; Exe = 'AstralParty_INT.exe' },
        @{ Edition = 'CN'; Folder = '8vJXn6CN'; Exe = 'AstralParty_CN.exe' }
    )) {
        if ($Edition -and $Edition -ne $variant.Edition) { continue }
        foreach ($folder in @($Root, (Join-Path $Root $variant.Folder))) {
            $exe = Join-Path $folder $variant.Exe
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                [pscustomobject]@{ Root = Get-FullDirectory $folder; Exe = $variant.Exe; Edition = $variant.Edition }
            }
        }
    }
}

function Get-SteamRoot {
    if ($SteamRoot) { return $SteamRoot }
    foreach ($entry in @(
        @{ Key = 'HKCU:\Software\Valve\Steam'; Value = 'SteamPath' },
        @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Value = 'InstallPath' }
    )) {
        $item = Get-ItemProperty -LiteralPath $entry.Key -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $property = $item.PSObject.Properties[$entry.Value]
            if ($null -ne $property -and $property.Value) { return [string]$property.Value }
        }
    }
}

function Get-SteamGames {
    $root = Get-SteamRoot
    if (-not $root) { return }
    $libraries = @((Get-FullDirectory $root))
    $vdf = Join-Path $root 'steamapps/libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf -PathType Leaf) {
        $text = [IO.File]::ReadAllText($vdf)
        # Support both current path entries and the older numeric-key format.
        foreach ($match in [regex]::Matches($text, '"(?:path|[0-9]+)"\s*"((?:\\.|[^"\\])*)"', 'IgnoreCase')) {
            $path = $match.Groups[1].Value.Replace('\\', '\').Replace('\"', '"')
            if ([IO.Path]::IsPathRooted($path)) { $libraries += Get-FullDirectory $path }
        }
    }
    foreach ($library in @($libraries | Select-Object -Unique)) {
        Find-Game (Join-Path $library 'steamapps/common/Astral Party')
    }
}

function Test-SteamReady {
    # Steam records its pid and signed-in account here; a stale entry left by a crash has no matching process.
    $active = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue
    if ($null -eq $active) { return $false }
    $user = $active.PSObject.Properties['ActiveUser']
    $processId = $active.PSObject.Properties['pid']
    if ($null -eq $user -or $null -eq $processId -or [int64]$user.Value -eq 0) { return $false }
    return @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Id -eq [int64]$processId.Value }).Count -gt 0
}

function Wait-SteamReady {
    if (Test-SteamReady) { return $true }
    if (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count -eq 0) {
        # Starting the game without Steam makes it relaunch itself through Steam, so BepInEx runs in two game processes at once.
        $root = Get-SteamRoot
        $steamExe = $null
        if ($root) { $steamExe = Join-Path (Get-FullDirectory $root) 'steam.exe' }
        if (-not $steamExe -or -not (Test-Path -LiteralPath $steamExe -PathType Leaf)) {
            Write-Host 'Steam을 찾지 못해 게임을 실행하지 않았습니다. Steam에 로그인한 뒤 Steam 라이브러리에서 게임을 실행해 주세요.' -ForegroundColor Yellow
            return $false
        }
        Start-Process -FilePath $steamExe -ArgumentList '-silent' | Out-Null
        Write-Host 'Steam을 실행했습니다. Steam 로그인이 끝나면 게임을 실행합니다.'
    } else { Write-Host 'Steam 로그인이 끝나면 게임을 실행합니다.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $nextReport = 15
    while ($watch.Elapsed.TotalSeconds -lt 300) {
        Start-Sleep -Seconds 1
        if (Test-SteamReady) {
            # The account is recorded before the client finishes starting; give it a moment before the game connects.
            Start-Sleep -Seconds 5
            return $true
        }
        if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
            Write-Host ('  Steam 준비 중... {0}초' -f [int]$watch.Elapsed.TotalSeconds)
            $nextReport += 15
        }
    }
    Write-Host '5분이 지나도 Steam 로그인이 확인되지 않아 게임을 실행하지 않았습니다. Steam 라이브러리에서 게임을 실행해 주세요.' -ForegroundColor Yellow
    return $false
}

function Get-EditionLabel([string]$Value) {
    if ($Value -eq 'INT') { return '글로벌 INT' }
    return '중국 CN'
}

function Wait-GameWindow([string]$ProcessName, [bool]$FirstRun) {
    Write-Host '게임을 실행했습니다. 게임 창이 뜰 때까지 이 창에서 기다립니다.'
    if ($FirstRun) { Write-Host '화면이 뜨지 않아도 게임은 준비 중입니다. 게임을 다시 실행하지 말고 기다려 주세요.' }
    # A live console gets a one-line spinner; redirected output (logs, tests) gets occasional plain lines instead of carriage returns.
    $live = -not [Console]::IsOutputRedirected
    $frames = '|', '/', '-', '\'
    $frame = 0
    $statusWidth = 0
    $cursorHidden = $false
    if ($live) { try { [Console]::CursorVisible = $false; $cursorHidden = $true } catch { } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastSeen = -1.0
    $nextProbe = 0.0
    $nextReport = 15
    $result = 'timeout'
    try {
        while ($watch.Elapsed.TotalSeconds -lt 300) {
            $elapsed = $watch.Elapsed.TotalSeconds
            if ($elapsed -ge $nextProbe) {
                $nextProbe = $elapsed + 1
                $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
                if (@($running | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -gt 0) { $result = 'window'; break }
                if ($running.Count -gt 0) { $lastSeen = $elapsed }
                elseif ($elapsed - [Math]::Max($lastSeen, 0) -ge 30) { $result = 'gone'; break }
            }
            if ($live) {
                $status = '  {0} 게임 준비 중... {1}초' -f $frames[$frame % $frames.Count], [int]$elapsed
                $frame++
                # Korean text is double-width, so pad by the widest status written so far.
                $statusWidth = [Math]::Max($statusWidth, [Text.Encoding]::Default.GetByteCount($status))
                Write-Host -NoNewline ("`r" + $status)
                Start-Sleep -Milliseconds 200
            } else {
                if ($elapsed -ge $nextReport) {
                    Write-Host ('  게임 준비 중... {0}초' -f [int]$elapsed)
                    $nextReport += 15
                }
                Start-Sleep -Milliseconds 500
            }
        }
    } finally {
        if ($live -and $statusWidth -gt 0) { Write-Host -NoNewline ("`r" + (' ' * $statusWidth) + "`r") }
        if ($cursorHidden) { try { [Console]::CursorVisible = $true } catch { } }
    }
    switch ($result) {
        'window' { Write-Host ('게임 창이 열렸습니다 ({0}초). 이 창은 닫아도 됩니다.' -f [int]$watch.Elapsed.TotalSeconds) }
        'gone' { Write-Host '게임이 실행되지 않았거나 종료되었습니다. Steam에서 게임을 직접 실행해 주세요.' -ForegroundColor Yellow }
        default { Write-Host '5분이 지나도 게임 창이 뜨지 않았습니다. 작업 관리자에서 AstralParty 프로세스를 확인해 주세요.' -ForegroundColor Yellow }
    }
}

function Select-Game {
    if ($GameRoot) {
        $games = @(Find-Game (Get-FullDirectory $GameRoot))
        if ($games.Count -eq 0) { throw '지정한 폴더에서 게임 실행 파일을 찾을 수 없습니다. AstralParty_INT.exe 또는 AstralParty_CN.exe가 있는 폴더를 지정해 주세요.' }
    } else {
        # Global (INT) is listed before China (CN); path order is only a tiebreaker.
        $games = @(Get-SteamGames | Sort-Object Root, Edition -Unique | Sort-Object -Property @({ if ($_.Edition -eq 'INT') { 0 } else { 1 } }, 'Root'))
    }
    while ($true) {
        if ($games.Count -eq 1) { return $games[0] }
        if ($games.Count -gt 1) {
            Write-Host '설치할 게임을 선택해 주세요.'
            for ($i = 0; $i -lt $games.Count; $i++) {
                Write-Host ('  {0}. [{1}] {2}' -f ($i + 1), (Get-EditionLabel $games[$i].Edition), $games[$i].Root)
            }
            if ($Yes) { throw '게임이 여러 개 발견되었습니다. -GameRoot 또는 -Edition으로 설치 대상을 지정해 주세요.' }
            $answer = Read-Host '번호 입력 (Enter: 취소)'
            if ([string]::IsNullOrWhiteSpace($answer)) { throw '설치를 취소했습니다.' }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $games.Count) { return $games[$number - 1] }
            Write-Host '올바른 번호를 입력해 주세요.'
        } else {
            if ($Yes) { throw 'Steam에서 게임을 찾지 못했습니다. -GameRoot로 게임 실행 파일이 있는 폴더를 지정해 주세요.' }
            $answer = Read-Host '게임 실행 파일이 있는 폴더 경로 입력 (Enter: 취소)'
            if ([string]::IsNullOrWhiteSpace($answer)) { throw '설치를 취소했습니다.' }
            $games = @(Find-Game (Get-FullDirectory $answer))
            if ($games.Count -eq 0) { Write-Host '그 폴더에서는 게임 실행 파일을 찾지 못했습니다.' }
        }
    }
}

function Wait-GameClosed {
    while (@(Get-Process -Name 'AstralParty_INT', 'AstralParty_CN' -ErrorAction SilentlyContinue).Count -gt 0) {
        if ($Yes) { throw '게임이 실행 중입니다. 아스트랄 파티를 완전히 종료한 뒤 다시 설치해 주세요.' }
        $answer = Read-Host '게임을 완전히 종료한 뒤 Enter를 눌러 다시 확인해 주세요 (Q: 취소)'
        if ($answer -match '^(?i:q)$') { throw '설치를 취소했습니다.' }
    }
}

function Copy-PayloadFile([string]$Source, [string]$Destination) {
    if ([string]::Equals([IO.Path]::GetFullPath($Source), [IO.Path]::GetFullPath($Destination), [StringComparison]::OrdinalIgnoreCase)) { return }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

# Each setting is forced to false: Unity log listening breaks Astral Party startup, and the console window is noise for players.
$bepInExSettings = @(
    @{ Section = 'Logging'; Key = 'UnityLogListening' },
    @{ Section = 'Logging.Console'; Key = 'Enabled' }
)

function Get-FreshConfigText([string]$Newline) {
    $text = ''
    foreach ($setting in $bepInExSettings) { $text += '[' + $setting.Section + ']' + $Newline + $setting.Key + ' = false' + $Newline }
    return $text
}

function Set-ConfigFalse([string]$Text, [string]$Newline, [string]$SectionName, [string]$KeyName) {
    $sections = [regex]::Matches($Text, '(?m)^[ \t]*\[(?<name>[^\]\r\n]+)\][^\r\n]*(?:\r\n|\n|\r|$)')
    $found = $false
    for ($i = $sections.Count - 1; $i -ge 0; $i--) {
        $section = $sections[$i]
        if ($section.Groups['name'].Value.Trim() -ine $SectionName) { continue }
        $found = $true
        $end = $Text.Length
        if ($i + 1 -lt $sections.Count) { $end = $sections[$i + 1].Index }
        $body = $Text.Substring($section.Index, $end - $section.Index)
        $key = New-Object Text.RegularExpressions.Regex('(?im)^([ \t]*' + [regex]::Escape($KeyName) + '[ \t]*=[ \t]*)([^;#\r\n]*?)([ \t]*(?:[;#][^\r\n]*)?)\r?$')
        if ($key.IsMatch($body)) {
            # BepInEx does not strip inline comments: "false # note" fails to parse and its default (true) wins.
            # Write a bare value and keep the note on its own "#" line, with the original indentation and endings.
            $body = $key.Replace($body, { param($match)
                $cr = ''
                if ($match.Value.EndsWith("`r")) { $cr = "`r" }
                $line = $match.Groups[1].Value + 'false' + $cr
                $note = $match.Groups[3].Value.Trim()
                if (-not $note) { return $line }
                $ending = $Newline
                if ($cr) { $ending = "`r`n" }
                $indent = [regex]::Match($match.Groups[1].Value, '^[ \t]*').Value
                return $indent + '#' + $note.Substring(1) + $ending + $line
            })
        } else {
            $header = $section.Value
            if (-not ($header.EndsWith("`n") -or $header.EndsWith("`r"))) { $header += $Newline }
            $body = $header + $KeyName + ' = false' + $Newline + $body.Substring($section.Length)
        }
        $Text = $Text.Substring(0, $section.Index) + $body + $Text.Substring($end)
    }
    if (-not $found) {
        if ($Text.Length -gt 0 -and -not ($Text.EndsWith("`n") -or $Text.EndsWith("`r"))) { $Text += $Newline }
        $Text += '[' + $SectionName + ']' + $Newline + $KeyName + ' = false' + $Newline
    }
    return $Text
}

function Set-BepInExConfig([string]$Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [IO.File]::WriteAllText($Path, (Get-FreshConfigText "`r`n"), (New-Object Text.UTF8Encoding($false)))
        return
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = New-Object Text.UTF32Encoding($false, $true); $offset = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255) {
        $encoding = New-Object Text.UTF32Encoding($true, $true); $offset = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $encoding = New-Object Text.UTF8Encoding($true); $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $encoding = [Text.Encoding]::Unicode; $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $encoding = [Text.Encoding]::BigEndianUnicode; $offset = 2
    }
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch [Text.DecoderFallbackException] {
        $encoding = [Text.Encoding]::Default
        $text = $encoding.GetString($bytes)
    }
    $newline = "`r`n"
    $lineMatch = [regex]::Match($text, '\r\n|\n|\r')
    if ($lineMatch.Success) { $newline = $lineMatch.Value }
    foreach ($setting in $bepInExSettings) { $text = Set-ConfigFalse $text $newline $setting.Section $setting.Key }
    [IO.File]::WriteAllText($Path, $text, $encoding)
}

try {
    # Windows PowerShell 5.1 leaves $PSScriptRoot empty in [CmdletBinding()] parameter defaults.
    if (-not $PackageRoot) { $PackageRoot = $PSScriptRoot }
    $PackageRoot = Get-FullDirectory $PackageRoot
    $pluginRelative = 'BepInEx/plugins/AstralPartyKoreanPlugin'
    $pluginFiles = @('AstralPartyKoreanPlugin.dll', 'astralkorean_fonts.bundle')
    foreach ($name in $pluginFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot "$pluginRelative/$name") -PathType Leaf)) {
            throw "설치 패키지에 $name 파일이 없습니다. 전체 설치 ZIP을 모두 압축 해제한 뒤 다시 실행해 주세요."
        }
    }
    $game = Select-Game
    $target = $game.Root
    Wait-GameClosed
    $needsRuntime = -not ((Test-Path -LiteralPath (Join-Path $target 'BepInEx/core/BepInEx.Core.dll') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $target 'winhttp.dll') -PathType Leaf))
    $runtimeRoots = @('BepInEx', 'dotnet', 'winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'changelog.txt', 'LICENSE-BepInEx.txt')
    if ($needsRuntime) {
        foreach ($relative in $runtimeRoots + @('BepInEx/core/BepInEx.Core.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative))) {
                throw "설치 패키지에 BepInEx 파일이 없습니다: $relative. 전체 설치 ZIP을 다시 압축 해제해 주세요."
            }
        }
    }
    Write-Host ('설치 대상: [{0}] {1}' -f (Get-EditionLabel $game.Edition), $target)
    foreach ($relative in @(
        'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll',
        'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll.removed',
        'BepInEx/patchers/AstralParty.DataUnity3dRedirect.dll',
        'BepInEx/patchers/AstralParty.DataUnity3dRedirect.dll.removed',
        'BepInEx/plugins/AstralPartyKoreanPatch', 'BepInEx/AstralPartyKoreanPatch', 'BepInEx/data-redirect.log'
    )) {
        $path = Join-Path $target $relative
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    if ($needsRuntime) {
        foreach ($relative in $runtimeRoots) {
            $source = Join-Path $PackageRoot $relative
            if (Test-Path -LiteralPath $source -PathType Container) {
                foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
                    $child = $file.FullName.Substring($PackageRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
                    if ($child -ieq 'BepInEx/config/BepInEx.cfg' -or
                        $child.StartsWith($pluginRelative + '/', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    Copy-PayloadFile $file.FullName (Join-Path $target $child)
                }
            } else { Copy-PayloadFile $source (Join-Path $target $relative) }
        }
        Write-Host 'BepInEx 설치를 완료했습니다.'
    } else { Write-Host '기존 BepInEx를 유지합니다 (core 및 dotnet을 덮어쓰지 않습니다).' }
    Set-BepInExConfig (Join-Path $target 'BepInEx/config/BepInEx.cfg')
    foreach ($name in $pluginFiles) {
        Copy-PayloadFile (Join-Path $PackageRoot "$pluginRelative/$name") (Join-Path $target "$pluginRelative/$name")
    }
    # A manual install supersedes any pending in-game update; stale staging would otherwise linger.
    foreach ($name in @('AstralPartyKoreanPlugin.dll.new', 'astralkorean_fonts.bundle.new', '.update.json', '.update.json.sig',
            'AstralPartyKoreanPlugin.dll.new.tmp', 'astralkorean_fonts.bundle.new.tmp', '.update.json.tmp', '.update.json.sig.tmp')) {
        $path = Join-Path $target "$pluginRelative/$name"
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host '한글패치 설치가 완료되었습니다. 기존 번역 팩 캐시는 유지됩니다.'
    Write-Host '게임 언어는 글로벌판 English, 중국판 중국어 간체로 설정해 주세요.'
    # BepInEx generates interop assemblies on the first launch, before the game window exists.
    $firstRun = @(Get-ChildItem -LiteralPath (Join-Path $target 'BepInEx/interop') -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count -eq 0
    if ($firstRun) { Write-Host '첫 실행은 BepInEx가 준비되는 동안 1~2분 정도 화면이 뜨지 않습니다.' }
    if (-not $NoLaunch) {
        $launch = $Yes
        if (-not $Yes) { $launch = (Read-Host '지금 게임을 실행할까요? (Y/N)') -match '^(?i:y|yes|예|네)$' }
        if ($launch -and (Wait-SteamReady)) {
            # Steam sets these for its own launches; with them the game starts in place instead of relaunching through Steam.
            $env:SteamAppId = '2622000'
            $env:SteamGameId = '2622000'
            Start-Process -FilePath (Join-Path $target $game.Exe) -WorkingDirectory $target | Out-Null
            Wait-GameWindow ([IO.Path]::GetFileNameWithoutExtension($game.Exe)) $firstRun
        }
    }
    exit 0
} catch {
    Write-Host ('설치 실패: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
