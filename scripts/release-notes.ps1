# Shared commit parsing and Markdown for release preparation and upload.
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

1. 게임을 종료합니다.
2. **BepInEx 6 Unity IL2CPP Windows x64**를 먼저 설치하고, [설치 안내]({{repo}}#설치)에 따라 `BepInEx/config/BepInEx.cfg`를 설정합니다.
3. [AstralPartyKoreanPlugin-{{tag}}.zip]({{repo}}/releases/download/{{tag}}/AstralPartyKoreanPlugin-{{tag}}.zip)을 내려받아 압축을 풉니다.
4. 압축에서 꺼낸 `BepInEx` 폴더를 **게임 실행 파일이 있는 폴더**에 복사하고 기존 폴더와 합칩니다.

| Steam판 | 설치 폴더 | 실행 파일 |
| --- | --- | --- |
| 글로벌판 | `8vJXnINT` | `AstralParty_INT.exe` |
| 중국판 | `8vJXn6CN` | `AstralParty_CN.exe` |

설치 후 아래 DLL 두 개가 있어야 합니다. ZIP에는 플러그인 DLL 두 개만 포함됩니다.

```text
BepInEx/
├─ patchers/
│  └─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
└─ plugins/
   └─ AstralPartyKoreanPatch/
      └─ AstralPartyKoreanPlugin.dll
```

Steam에서 게임을 실행하면 한글패치 리소스 확인과 다운로드가 진행됩니다. 게임 내 오버레이에서 적용 상태를 확인할 수 있습니다.

### 기존 버전에서 업데이트

게임을 종료한 뒤 새 DLL 두 개로 교체하세요. 아래 이름의 이전 DLL이 남아 있다면 삭제합니다.

- `BepInEx/patchers/AstralParty.DataUnity3dRedirect.dll`
- `BepInEx/plugins/AstralPartyKoreanPatch/AstralParty.AddressablesInProcessPatch.dll`

`BepInEx/AstralPartyKoreanPatch`의 리소스 캐시는 계속 사용할 수 있습니다. 플러그인 버전과 자동으로 내려받는 번역 리소스의 버전은 별도로 관리됩니다.

[전체 변경 내역]({{repo}}/commits/{{tag}}) · [설치 및 문제 해결]({{repo}}#설치) · [문제 제보]({{repo}}/issues)
'@
    $notes.Add($installation.Replace('{{repo}}', $baseUrl).Replace('{{tag}}', $Tag))
    return ($notes -join "`n").Replace("`r`n", "`n") + "`n"
}
