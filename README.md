# Astral Party Korean Plugin

Astral Party Windows Steam 글로벌판/중국판용 한국어 패치 플러그인입니다. `astral-party-auto-patcher/windows-plugin`에서 분리했으며, BepInEx가 설치된 게임에 추가하는 두 DLL만 빌드·배포합니다.

## 설치

1. 게임 폴더(`8vJXnINT` 또는 `8vJXn6CN`)에 BepInEx **6.0.0-be.788+5b766a3, Unity IL2CPP Windows x64**를 먼저 설치합니다. 런타임과 `BepInEx/core/dobby.dll`은 이 플러그인 ZIP에 포함되지 않습니다.
2. `BepInEx/config/BepInEx.cfg`에 아래 설정을 적용합니다. 기존 파일의 해당 항목만 수정하세요. Astral Party의 HybridCLR 시작 문제를 피하기 위한 설정입니다.

   ```ini
   [Logging]
   UnityLogListening = false

   [Logging.Console]
   Enabled = false

   [Logging.Disk]
   WriteUnityLog = false
   ```

3. 플러그인 ZIP을 게임 폴더에 풀고 Steam에서 실행합니다. INT/CN 경로를 자동 판별하고 `maynut02/astral-party-korean-patch`의 최신 호환 리소스를 확인합니다.

기존 이름으로 설치된 패키지를 업데이트할 때는 아래 DLL 두 개를 먼저 삭제한 뒤 새 DLL을 설치합니다. BepInEx와 한글패치 캐시는 유지합니다.

- `BepInEx/patchers/AstralParty.DataUnity3dRedirect.dll`
- `BepInEx/plugins/AstralPartyKoreanPatch/AstralParty.AddressablesInProcessPatch.dll`

새 DLL 이름은 `AstralPartyKoreanPlugin.dataUnity3dRedirect.dll`과 `AstralPartyKoreanPlugin.dll`입니다. 제거할 때는 한글패치 DLL 두 개와 `BepInEx/AstralPartyKoreanPatch` 캐시만 삭제하세요. 자세한 안내는 [적용방법.txt](packaging/적용방법.txt)에 있습니다.

## 구성

- `src/Preloader/` — 실행 전 릴리스 확인·다운로드·검증과 `data.unity3d` 접근 전환
- `src/Plugin/` — 같은 실행에서 Addressables payload 연결과 상태 오버레이 표시
- `src/UnityEngine.UI.Reference/` — 컴파일 전용 uGUI 참조 프로젝트(배포 제외)
- `scripts/` — 참조 준비, DLL 빌드, 플러그인 ZIP 생성
- `tests/` — 소스 회귀 확인과 실제 ZIP 구성·체크섬 검사
- `.github/workflows/` — 소스 빌드와 회귀 검사 CI

## 빌드

.NET **6.0.428 SDK**, PowerShell 7이 필요합니다. 실제 게임 설치본이나 생성된 `BepInEx/interop`는 필요하지 않으며 Windows와 Linux에서 빌드할 수 있습니다.

```powershell
./scripts/setup.ps1           # 빌드 참조 준비(최초 다운로드에 인터넷 필요)
./scripts/build.ps1           # 두 플러그인 DLL 생성
./scripts/package-release.ps1 # 소스 빌드 후 ZIP·메타데이터·체크섬 생성
```

`build.ps1`과 `package-release.ps1`은 참조 준비를 자동으로 수행합니다. `build-package.ps1`도 같은 패키징을 실행하는 호환 명령입니다. 버전은 `VERSION`을 기준으로 하며 `-Version 2.0.1`로 지정할 수도 있습니다. 별도 SDK를 사용하려면 `-DotNetPath /path/to/dotnet`을 지정합니다.

BepInEx와 Unity 2022.3.62의 고정 아카이브를 내려받아 SHA-256을 확인하고, 필요한 참조 DLL만 `.work/deps`에 추출합니다. 다운로드와 참조는 로컬 캐시이며 배포에 포함되지 않습니다.

```text
dist/
├─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
├─ AstralPartyKoreanPlugin.dll
├─ AstralPartyKoreanPlugin-v2.0.0.zip
├─ windows-plugin-build.json
└─ SHA256SUMS.txt
```

ZIP에는 `BepInEx/` 아래의 DLL 두 개만 포함합니다.

```text
BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll
```

## 검증과 로컬 릴리스

```powershell
python -m pip install pytest pyyaml
python -m pytest tests
./tests/scripts/ProjectVersionTests.ps1
./tests/scripts/ReleasePreparationTests.ps1
./tests/scripts/ReleaseUploadTests.ps1
```

배포 패키지는 로컬에서 빌드합니다. GitHub Actions는 소스 빌드와 테스트만 실행합니다.

소스와 `VERSION`을 커밋하여 `origin`에 push한 뒤, 로컬에서 아래 명령을 실행합니다. 최초 한 번 GitHub 원격 저장소를 `origin`에 연결하고 `gh auth login`을 마쳐야 합니다.

```powershell
./scripts/package-release.ps1         # 로컬 빌드와 ZIP 생성
./scripts/upload-release.ps1 -Preview # 업로드 계획 확인(GitHub 호출 없음)
./scripts/upload-release.ps1          # 기존 ZIP과 체크섬을 Release에 등록
```

`upload-release.ps1`은 빌드하지 않으며 `dist/`의 ZIP과 `SHA256SUMS.txt`만 첨부합니다. 버전과 태그는 `VERSION`의 `vX.Y.Z`를 사용합니다. 새 Release를 draft로 만든 뒤 첨부가 완료되면 공개하며, `-Draft`로 draft를 유지할 수 있습니다. 같은 파일로 재시도하면 이미 올라간 파일은 건너뜁니다.

버전 증가와 릴리스 설명 초안은 `prepare-release.ps1 -Bump patch`로 준비할 수 있습니다. 첫 릴리스는 현재 `VERSION`인 2.0.0을 사용합니다. 자세한 순서와 옵션은 [로컬 릴리스 안내](docs/releases.md)에 있습니다.

## 라이선스

[MIT License](LICENSE)
