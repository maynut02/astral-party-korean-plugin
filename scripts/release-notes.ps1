# Shared commit parsing and Markdown for the release command and upload retries.
function ConvertFrom-AstralCommitLog {
    param([string]$Log)

    if (-not $Log) { return }
    $fields = $Log.Split([char]0)
    for ($index = 0; $index + 1 -lt $fields.Length; $index += 2) {
        $message = $fields[$index + 1].TrimEnd()
        $subject = ($message -split "`n", 2)[0].TrimEnd("`r")
        $match = [regex]::Match($subject, '\A(?<type>[a-z]+)(?:\([^()\r\n]+\))?(?<breaking>!)?: .+', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $type = if ($match.Success) { $match.Groups['type'].Value.ToLowerInvariant() } else { '' }
        $breaking = ($match.Success -and $match.Groups['breaking'].Success) -or
            [regex]::IsMatch($message, '(?m)^BREAKING(?: CHANGE|-CHANGE):\s*\S')
        [pscustomobject]@{ Sha = $fields[$index]; Subject = $subject; Type = $type; Breaking = $breaking }
    }
}

function New-AstralReleaseNotes {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [object[]]$Commits = @()
    )

    $baseUrl = 'https://github.com/maynut02/astral-party-korean-plugin'
    $notes = [Collections.Generic.List[string]]::new()
    $notes.Add('## 변경 사항')
    $notes.Add('')
    foreach ($commit in $Commits) {
        $notes.Add("- $($commit.Subject) ($($commit.Sha.Substring(0, 7)))")
    }
    if ($Commits.Count -eq 0) { $notes.Add('- 버전 및 배포 준비') }
    $notes.Add('')
    $installation = @'
## 설치

1. 게임을 종료하고 [AstralPartyKoreanPlugin-{{tag}}-full.zip]({{repo}}/releases/download/{{tag}}/AstralPartyKoreanPlugin-{{tag}}-full.zip)을 내려받아 별도 폴더에 압축을 풉니다.
2. **install.bat**를 실행합니다. 인터넷 없이 게임을 찾아 **BepInEx 6 Unity IL2CPP Windows x64 (be.788)**, `BepInEx/config/BepInEx.cfg` 설정과 플러그인을 설치하고 게임을 시작합니다. 설치 EXE는 사용하지 않습니다.
3. 이미 BepInEx가 준비되어 있고 수동으로 업데이트하려면 [AstralPartyKoreanPlugin-{{tag}}.zip]({{repo}}/releases/download/{{tag}}/AstralPartyKoreanPlugin-{{tag}}.zip)의 `BepInEx` 폴더를 **게임 실행 파일이 있는 폴더**에 복사합니다.
4. 게임 언어를 글로벌판 `English`, 중국판 `简体中文`로 설정합니다. 자세한 내용은 [설치 안내]({{repo}}#설치)를 참고하세요.

| Steam판 | 설치 폴더 | 실행 파일 |
| --- | --- | --- |
| 글로벌판 | `8vJXnINT` | `AstralParty_INT.exe` |
| 중국판 | `8vJXn6CN` | `AstralParty_CN.exe` |

설치 후 DLL과 폰트 번들이 함께 있어야 합니다. 플러그인 전용 ZIP에는 아래 두 파일만 포함되며 전체 ZIP에는 BepInEx와 오프라인 설치 스크립트도 들어 있습니다.

```text
BepInEx/
└─ plugins/
   └─ AstralPartyKoreanPlugin/
      ├─ AstralPartyKoreanPlugin.dll
      └─ astralkorean_fonts.bundle
```

Steam에서 게임을 실행하면 `https://file.maynutlab.com/translation-pack/latest.json`에서 번역 팩을 확인합니다. 플러그인도 서명된 최신 업데이트를 검증해 자동으로 설치합니다. 게임 내 오버레이에 재시작 안내가 나오면 **지금 다시 시작**을 누르거나 게임을 다시 실행하세요.

### 기존 버전에서 업데이트

게임을 종료한 뒤 DLL과 폰트 번들을 함께 새 폴더 `BepInEx/plugins/AstralPartyKoreanPlugin/`에 설치하세요. **2.x 사용자는 이전 `BepInEx/plugins/AstralPartyKoreanPatch/` 폴더와 `BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll`을 삭제해야 합니다.** 두 플러그인의 GUID가 달라 이전 DLL이 남으면 함께 로드될 수 있습니다. 새 플러그인도 구형 폴더와 DLL의 자동 삭제를 시도하며, 로드 중인 DLL은 가능하면 `.removed`로 바꿔 다음 실행에서 삭제합니다. 권한이나 파일 사용 상태에 따라 실패하면 게임 종료 후 직접 삭제하세요.

더 오래된 `AstralParty.DataUnity3dRedirect.dll`과 `AstralParty.AddressablesInProcessPatch.dll`도 남기지 마세요.

번역 캐시는 `BepInEx/plugins/AstralPartyKoreanPlugin/translation-pack/`에 보관하므로, 플러그인 폴더를 지우면 캐시까지 함께 제거됩니다. 팩 번호가 커질 때만 갱신하며 세션 중에는 고정합니다. 플러그인 버전과 번역 팩은 별도로 관리합니다. 다운로드 실패 시 검증된 캐시를 사용하고, 캐시도 없거나 번역이 없는 문자열은 원문을 표시합니다.

[전체 변경 내역]({{repo}}/commits/{{tag}}) · [설치 및 문제 해결]({{repo}}#설치) · [문제 제보]({{repo}}/issues)
'@
    $notes.Add($installation.Replace('{{repo}}', $baseUrl).Replace('{{tag}}', $Tag))
    return ($notes -join "`n").Replace("`r`n", "`n") + "`n"
}
