# AstralPartyKoreanPlugin

아스트랄 파티 Steam 글로벌판·중국판에 한국어 리소스를 적용하는 BepInEx 플러그인입니다. 게임을 실행하면 최신 한글패치 리소스를 확인하고, 설치된 게임과 호환되는 파일을 준비합니다.

- 게임 실행 시 한글패치 리소스 확인과 자동 다운로드
- 게임 버전과 파일 해시를 확인한 뒤 패치 적용
- 내려받은 파일을 캐시에 보관하고 다음 실행에서 재사용
- 시작 시 진행 상황 표시와 게임 내 패치 상태 오버레이

## 설치

Windows x64의 Steam판을 대상으로 합니다. 게임에 **BepInEx 6 Unity IL2CPP Windows x64**가 먼저 설치되어 있어야 합니다. 플러그인 ZIP에는 한글패치 DLL 두 개만 들어 있습니다.

### 1. BepInEx 설치와 게임용 설정

1. 게임을 종료하고, Steam 라이브러리에서 아스트랄 파티를 우클릭해 **관리 → 로컬 파일 보기**를 선택합니다.
2. 실행하는 판에 맞는 폴더로 들어갑니다. 아래 실행 파일이 있는 위치에 BepInEx와 플러그인을 설치합니다.

   | Steam판 | 폴더 | 실행 파일 |
   | --- | --- | --- |
   | 글로벌판 | `8vJXnINT` | `AstralParty_INT.exe` |
   | 중국판 | `8vJXn6CN` | `AstralParty_CN.exe` |

3. [BepInEx 다운로드](https://builds.bepinex.dev/projects/bepinex_be)에서 **Unity IL2CPP Windows x64** 배포물을 내려받아 압축 내용 전체를 이 위치에 복사합니다. 특정 BepInEx 빌드 번호를 고정하지 않습니다.
4. **게임을 처음 실행하기 전에** `BepInEx/config/BepInEx.cfg`를 열고 아래 설정을 적용합니다. 폴더나 파일이 없다면 직접 만드세요. 파일 이름이 `BepInEx.cfg.txt`로 저장되지 않도록 확인하세요.

```ini
[Logging]
UnityLogListening = false

[Logging.Console]
Enabled = false

[Logging.Disk]
WriteUnityLog = false
```

기존 설정 파일이 있다면 해당 항목 세 개의 값만 바꾸고 다른 설정은 유지하세요. 같은 섹션과 항목을 중복으로 추가할 필요는 없습니다. 이 설정은 아스트랄 파티의 BepInEx 초기화 문제를 피하기 위한 것입니다.

설정을 저장한 뒤 Steam에서 게임을 한 번 실행하고 종료합니다. 최초 실행은 BepInEx의 참조 파일 생성 때문에 시간이 걸릴 수 있습니다.

### 2. 한글패치 플러그인 설치

1. 게임을 종료합니다.
2. [Releases](https://github.com/maynut02/astral-party-korean-plugin/releases)에서 `AstralPartyKoreanPlugin-v버전.zip`을 내려받아 압축을 풉니다.
3. 압축에서 꺼낸 `BepInEx` 폴더를 위의 게임 실행 파일이 있는 위치에 복사하고, 기존 폴더와 합칩니다.

글로벌판의 설치 후 파일 위치는 다음과 같습니다. 중국판은 같은 구조를 `8vJXn6CN`에 설치합니다.

```text
Astral Party/
└─ 8vJXnINT/
   ├─ AstralParty_INT.exe
   └─ BepInEx/
      ├─ config/
      │  └─ BepInEx.cfg
      ├─ patchers/
      │  └─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
      └─ plugins/
         └─ AstralPartyKoreanPatch/
            └─ AstralPartyKoreanPlugin.dll
```

수동 설치할 때도 위 위치에 DLL 두 개를 모두 넣으세요. Release에 함께 첨부된 `SHA256SUMS.txt`는 ZIP의 무결성 확인용이며 게임 폴더에 복사할 필요는 없습니다.

## 사용 방법

Steam에서 게임을 실행하면 한글패치 확인과 다운로드 진행 창이 표시됩니다. 준비가 끝나면 게임이 시작되고, 게임 내 오버레이에서 게임 버전·리비전과 설치된 패치·최신 패치의 버전, 적용 상태를 확인할 수 있습니다.

오버레이는 닫기 버튼이나 Esc로 닫습니다. 창을 닫아도 한글패치는 계속 적용되며, 다음 게임 실행에서 다시 표시됩니다.

번역 리소스는 [한글패치 리소스 저장소](https://github.com/maynut02/astral-party-korean-patch/releases)에서 자동으로 가져옵니다. 오버레이의 패치 버전은 번역 리소스의 버전이며, 플러그인 자체의 버전과 별도로 관리합니다. 업데이트 확인에 실패하면 현재 게임과 호환되는 검증된 캐시를 사용합니다. 유효한 캐시도 없으면 원본 리소스로 실행합니다.

## 업데이트와 제거

플러그인을 업데이트할 때는 게임을 종료한 뒤 새 ZIP의 DLL 두 개를 같은 위치에 교체하세요. 기존에 아래 이름의 DLL을 설치했다면 먼저 삭제합니다.

- `BepInEx/patchers/AstralParty.DataUnity3dRedirect.dll`
- `BepInEx/plugins/AstralPartyKoreanPatch/AstralParty.AddressablesInProcessPatch.dll`

최신 이름의 DLL은 각각 한 개만 유지하세요. 업데이트 시 `BepInEx/AstralPartyKoreanPatch`의 리소스 캐시는 그대로 사용할 수 있습니다.

플러그인을 제거하려면 게임을 종료하고 설치한 DLL 두 개를 삭제하세요. 내려받은 리소스까지 제거하려면 `BepInEx/AstralPartyKoreanPatch` 폴더도 삭제합니다. 게임 원본 파일은 플러그인이 덮어쓰지 않으므로 제거를 위해 다시 복원할 필요가 없습니다.

## 문제가 생겼을 때

- **한국어가 적용되지 않음:** DLL 두 개의 설치 위치와 BepInEx 초기 설정을 확인하세요. 처음 준비할 때는 인터넷 연결이 필요합니다.
- **시작에 시간이 오래 걸림:** 최초 BepInEx 초기화나 패치 다운로드 중일 수 있습니다. 진행 창과 로그에서 현재 상태를 확인하세요.
- **원본 리소스 사용으로 표시됨:** 설치된 게임과 패치의 호환 정보가 맞지 않거나 준비에 실패했을 수 있습니다. 게임 버전과 로그를 확인하세요.
- **`dobby.dll` 관련 오류:** `BepInEx/core/dobby.dll`이 있는지 확인하고, BepInEx의 Unity IL2CPP Windows x64 배포물이 정상적으로 설치됐는지 확인하세요.

해결되지 않으면 [Issues](https://github.com/maynut02/astral-party-korean-plugin/issues)에 플러그인 버전, 글로벌판·중국판 여부, 게임 버전, 재현 방법과 아래 로그의 관련 내용을 알려주세요. 공개 전에 개인 경로는 가려주세요.

- `BepInEx/data-redirect.log` — 시작 시 리소스 확인·다운로드·검증
- `BepInEx/AstralPartyKoreanPatch/addressables-patch.jsonl` — 게임 내 리소스 연결과 적용 상태
- `BepInEx/LogOutput.txt` — BepInEx와 플러그인 로딩

## 빌드

Windows에서 PowerShell 7, .NET SDK 6.0.428, Git과 BepInEx가 초기화된 게임을 준비합니다. 저장소 루트에서 참조 DLL을 복사합니다.

```powershell
.\scripts\setup.ps1
```

DLL만 만들려면 `build.ps1`, DLL·ZIP·체크섬을 함께 만들려면 `package-release.ps1`을 실행합니다. 필요한 명령 하나를 선택하세요.

```powershell
.\scripts\build.ps1             # DLL 두 개 생성
.\scripts\package-release.ps1   # 소스 빌드 후 릴리즈 파일 생성
```

결과는 `dist/`에 생성됩니다. 버전은 `VERSION` 파일을 기준으로 합니다. 참조 경로와 SDK 설정, 검사 명령은 [개발 환경과 검증](docs/development.md)에 있습니다.

소스와 `VERSION`을 커밋하여 `origin`에 push하고, GitHub CLI 설치와 최초 `gh auth login`을 마친 뒤 로컬 패키지를 업로드합니다.

```powershell
.\scripts\upload-release.ps1 -Preview  # GitHub 호출 없이 로컬 계획 확인
.\scripts\upload-release.ps1           # 기존 ZIP과 체크섬 업로드 및 공개
```

업로드 명령은 `dist/`의 ZIP과 `SHA256SUMS.txt`만 첨부합니다. 버전 준비와 옵션, 재시도 절차는 [릴리즈 문서](docs/releases.md#4-github-release에-업로드)를 참고하세요.

- [개발 환경과 검증](docs/development.md)
- [로컬 빌드와 릴리즈](docs/releases.md)
- [코드 구조와 리소스 적용](docs/architecture.md)

## 라이선스

소스 코드와 문서는 [MIT 라이선스](LICENSE)로 배포합니다. 게임과 외부 의존성에는 각각의 라이선스가 적용됩니다.
