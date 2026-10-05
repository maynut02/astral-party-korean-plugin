# Astral Party Korean Plugin

Astral Party Windows Steam 글로벌판/중국판용 한국어 패치 플러그인입니다. `astral-party-auto-patcher/windows-plugin`에서 분리했으며, BepInEx가 설치된 게임에 추가하는 두 DLL만 빌드·배포합니다.

## 설치

1. 게임 폴더(`8vJXnINT` 또는 `8vJXn6CN`)에 **BepInEx 6 Unity IL2CPP Windows x64** 계열을 먼저 설치합니다. 특정 빌드 번호는 요구하지 않습니다. 런타임과 `BepInEx/core/dobby.dll`은 이 플러그인 ZIP에 포함되지 않습니다.
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

새 DLL 이름은 `AstralPartyKoreanPlugin.dataUnity3dRedirect.dll`과 `AstralPartyKoreanPlugin.dll`입니다. 제거할 때는 한글패치 DLL 두 개와 `BepInEx/AstralPartyKoreanPatch` 캐시만 삭제하세요.

## 구성

- `src/Preloader/` — 실행 전 릴리스 확인·다운로드·검증과 `data.unity3d` 접근 전환
- `src/Plugin/` — 같은 실행에서 Addressables payload 연결과 상태 오버레이 표시
- `scripts/` — 참조 준비, DLL 빌드, 플러그인 ZIP 생성
- `tests/` — 소스 회귀 확인과 실제 ZIP 구성·체크섬 검사
- `.github/workflows/` — 소스 구조와 버전·릴리스 스크립트 검사 CI

## 빌드

.NET **6.0.428 SDK**, PowerShell 7이 필요합니다. BepInEx 6 Unity IL2CPP Windows x64 계열이 설치된 실제 게임을 한 번 실행해 `BepInEx/core`와 `BepInEx/interop`를 준비합니다.

```powershell
./scripts/setup.ps1           # 로컬 게임에서 빌드 참조 복사
./scripts/build.ps1           # 두 플러그인 DLL 생성
./scripts/package-release.ps1 # 소스 빌드 후 ZIP·메타데이터·체크섬 생성
```

기본 게임 경로는 `C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT`입니다. 중국판이나 다른 설치 위치는 `setup.ps1 -GameRoot <게임 경로>`로 지정합니다. `setup.ps1`은 초기화된 게임의 `BepInEx/core`와 `BepInEx/interop`에서 필요한 참조 DLL만 `.work/refs`로 복사합니다. UnityEngine.UI도 실제 interop 참조를 사용합니다.

`build.ps1`과 `package-release.ps1`은 캐시 참조를 자동 사용하며, `-GameRoot` 또는 `-RefsRoot`를 받습니다. `-GameRoot`를 직접 지정하면 해당 게임에서 참조를 갱신합니다. `-RefsRoot`에는 `core/`와 `interop/`가 바로 아래에 있는 BepInEx 폴더 또는 참조 캐시를 지정합니다. 게임이나 BepInEx가 바뀌면 `setup.ps1 -GameRoot <게임 경로>`로 캐시를 갱신합니다. 참조는 배포에 포함되지 않습니다.

`Directory.Build.props`는 두 DLL 프로젝트에 자동 적용되는 공통 MSBuild 설정입니다. 명시한 `AstralRefsRoot`, 로컬 `.work/refs`, 게임의 `BepInEx` 폴더 순으로 참조 경로를 선택합니다. BepInEx 버전을 고정하거나 런타임을 패키지에 넣는 설정은 아닙니다.

버전은 `VERSION`을 기준으로 하며 `-Version 2.0.1`로 지정할 수도 있습니다. 별도 SDK를 사용하려면 `-DotNetPath /path/to/dotnet`을 지정합니다.

```text
dist/
├─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
├─ AstralPartyKoreanPlugin.dll
├─ AstralPartyKoreanPlugin-v2.0.0.zip
├─ windows-plugin-build.json
├─ build-references.json
└─ SHA256SUMS.txt
```

ZIP에는 `BepInEx/` 아래의 DLL 두 개만 포함합니다.

```text
BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll
```

## 검증과 로컬 릴리스

```powershell
python -m pip install pytest
python -m pytest tests
./tests/scripts/ProjectVersionTests.ps1
./tests/scripts/ReferenceFilesTests.ps1
./tests/scripts/ReleasePreparationTests.ps1
./tests/scripts/ReleaseUploadTests.ps1
```

배포 패키지와 실제 DLL 빌드 검증은 로컬에서 수행합니다. GitHub Actions는 게임 설치 없이 소스 구조와 버전·릴리스 스크립트만 검사합니다.

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
