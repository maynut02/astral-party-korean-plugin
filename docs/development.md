# 개발 환경과 검증

사용자 설치 방법은 [README](../README.md), 배포 절차는 [로컬 빌드와 릴리즈](releases.md), 실행 흐름은 [코드 구조와 리소스 적용](architecture.md)을 참고하세요.

## 준비 사항

- Windows x64, PowerShell 7, Git
- .NET SDK **6.0.428** — `setup.ps1`이 자동 준비
- Astral Party Steam 글로벌판 또는 중국판
- [README의 설치 안내](../README.md#설치)에 따라 설정하고 초기화한 BepInEx 6 Unity IL2CPP Windows x64
- 게임을 한 번 실행해 생성된 `BepInEx/interop` 참조 DLL
- 자동 검사를 실행할 Python과 `pytest` — CI에서는 Python 3.12 사용

두 DLL 프로젝트는 `net6.0`을 대상으로 빌드합니다. BepInEx와 Unity의 특정 빌드 번호를 고정하지 않고, 로컬 게임의 `core`·`interop` DLL을 참조합니다.

## 개발 환경 초기화

저장소 루트의 PowerShell에서 실행합니다.

```powershell
.\scripts\setup.ps1
```

이 명령은 게임에서 빌드에 필요한 참조 DLL을 `.work/refs`로 복사한 뒤 `global.json`의 `sdk.version`에 지정된 SDK(현재 6.0.428)를 [Microsoft 공식 설치기](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script)로 `.work/dotnet`에 설치합니다. 준비된 호환 SDK는 재사용합니다. 첫 SDK 설치에는 인터넷 연결이 필요하며, 시스템 SDK를 설치하거나 PATH를 변경하지 않습니다.

복사 목록과 `Sync-AstralReferences` 함수는 `scripts/reference-files.ps1`, 실제 파일의 버전과 SHA-256 기록은 `.work/refs/versions.json`에 있습니다. SDK 설치·선택은 공통 `scripts/dotnet-sdk.ps1`에서 처리합니다.

기본 게임 폴더는 다음 위치입니다.

```text
C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT
```

다른 Steam 라이브러리나 중국판을 사용하면 게임 실행 파일과 `BepInEx` 폴더가 있는 위치를 지정하세요.

```powershell
.\scripts\setup.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXn6CN'
```

게임이나 BepInEx가 바뀌면 같은 명령으로 참조를 갱신합니다. 필요한 참조가 하나라도 없으면 복사를 시작하기 전에 중단하므로 기존 캐시를 일부만 바꾸지 않습니다.

### 공통 빌드 설정

| 파일 | 역할 |
| --- | --- |
| `global.json` | .NET SDK `6.0.428`과 `latestPatch` 선택 정책 지정 |
| `Directory.Build.props` | 두 프로젝트의 BepInEx 참조 경로 공유 |
| `VERSION` | 플러그인과 패키지의 기본 버전 지정 |

`Directory.Build.props`는 하위 `.csproj`에 자동 적용됩니다. MSBuild의 `AstralRefsRoot`를 명시하면 해당 경로를, 생략하면 로컬 `.work/refs`, 게임의 `BepInEx` 폴더 순으로 참조 루트를 선택합니다.

빌드 스크립트는 지정된 `-RefsRoot`를 우선 사용합니다. 해당 옵션을 생략하면 참조 캐시를 사용하며, `-GameRoot`를 직접 지정하거나 캐시가 없으면 `Sync-AstralReferences`를 직접 호출해 참조를 준비·갱신합니다. 이 과정에서는 SDK를 다시 설치하지 않습니다.

## DLL 빌드

```powershell
.\scripts\build.ps1
```

두 프로젝트를 Release 설정으로 빌드하고 기본 `dist/`에 최신 DLL 두 개와 참조 기록을 생성합니다.

```text
dist/
├─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
├─ AstralPartyKoreanPlugin.dll
└─ build-references.json
```

빌드는 `VERSION`에서 읽거나 `-Version`으로 지정한 값을 `.work/generated/AstralBuildVersion.g.cs`에 기록하여 두 DLL이 같은 플러그인 버전을 사용하게 합니다. 참조 DLL은 빌드 출력에 복사하지 않습니다. 게임에서 확인할 때는 [README의 설치 위치](../README.md#2-한글패치-플러그인-설치)에 생성한 DLL 두 개를 넣으세요.

`-DotNetPath`를 지정하면 해당 경로만 검사합니다. 생략하면 작업 폴더의 `dotnet/dotnet.exe`(기본 `.work/dotnet/dotnet.exe`)와 PATH의 `dotnet` 중 `global.json`이 선택할 수 있는 SDK를 확인합니다. 사용할 SDK가 없으면 `setup.ps1`을 실행하라는 명확한 오류로 중단합니다. 별도 위치의 SDK는 직접 지정할 수 있습니다.

```powershell
.\scripts\build.ps1 -DotNetPath 'D:\Tools\dotnet\dotnet.exe'
```

`build.ps1`과 `package-release.ps1`은 다음 옵션을 공통으로 받습니다.

| 옵션 | 용도 |
| --- | --- |
| `-GameRoot` | 초기화된 게임에서 참조 캐시 준비·갱신 |
| `-RefsRoot` | `core`와 `interop`를 바로 아래에 둔 참조 폴더 사용 |
| `-DotNetPath` | 사용할 .NET SDK의 `dotnet.exe` 지정 |
| `-WorkRoot` | 참조 캐시·SDK·생성 코드의 작업 폴더 지정, 기본 `.work` |
| `-OutputRoot` | `build.ps1` 직접 실행 시 빌드 산출물 폴더(기본 `dist/`); `package-release.ps1`에서는 릴리즈 폴더(기본 `dist/release/vX.Y.Z/`) 지정 |
| `-Version` | 빌드·패키지 버전 지정, 기본 `VERSION`; 기본 릴리즈 폴더의 `vX.Y.Z`에도 적용 |

패키징에서 지정한 `-OutputRoot`는 릴리즈 파일을 보관할 폴더입니다. 내부 빌드의 출력은 항상 기본 `dist/`이며, 여기서 DLL 두 개와 `build-references.json`을 릴리즈 폴더로 복사합니다. 빌드 출력 폴더를 바꾸려면 `build.ps1`을 직접 실행할 때 `-OutputRoot`를 지정하세요.

실제 게임의 BepInEx 폴더를 바로 참조하려면 다음과 같이 실행합니다.

```powershell
.\scripts\build.ps1 -RefsRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT\BepInEx'
```

정식 배포 버전은 `VERSION`에 준비하세요. 업로드는 패키지 태그와 `VERSION`이 같아야 합니다.

## 릴리즈 파일 생성

```powershell
.\scripts\package-release.ps1
```

초기 준비로 `setup.ps1`을 한 번 실행한 뒤 이 명령 하나로 최신 소스의 DLL 두 개와 `build-references.json`을 기본 `dist/`에 생성하고, 세 파일을 기본 `dist/release/vX.Y.Z/`에 복사합니다. 같은 버전 폴더에 ZIP·`SHA256SUMS.txt`·`windows-plugin-build.json`을 생성하므로 릴리즈 파일은 총 여섯 개입니다. 예를 들어 버전이 `2.0.0`이면 `dist/release/v2.0.0/`을 사용합니다. 다른 버전을 패키징해도 기존 버전 폴더의 산출물은 유지됩니다.

내부에서 `build.ps1`을 호출하므로 선행 빌드는 필요 없습니다. 빌드가 실패하면 패키징을 중단합니다. 파일 구성과 업로드 순서는 [릴리즈 문서](releases.md#3-로컬-빌드와-패키징)에 있습니다.

## 검증

저장소 루트에서 CI와 같은 검사를 실행합니다.

```powershell
python -m pip install pytest
python -m pytest tests
.\tests\scripts\ReferenceFilesTests.ps1
.\tests\scripts\DotNetSdkTests.ps1
.\tests\scripts\ProjectVersionTests.ps1
.\tests\scripts\ReleasePreparationTests.ps1
.\tests\scripts\ReleaseUploadTests.ps1
```

Python 검사는 프로젝트 참조·버전 공유·기존 소스 회귀 조건과 실제 ZIP의 파일 구성·CRC·SHA-256, 참조 캐시 기록을 확인합니다. ZIP과 참조 캐시 검사는 로컬 산출물이 없으면 건너뜁니다. `setup.ps1`과 `package-release.ps1`을 실행한 뒤 다시 검사하면 실제 산출물도 확인합니다.

PowerShell 검사는 로컬 참조 복사, SDK 선택·재사용, 버전 형식과 증가, 커밋 기반 릴리즈 준비, GitHub CLI를 대신하는 테스트용 스크립트로 업로드·재시도 동작을 확인합니다. 테스트가 만든 임시 폴더는 종료 시 정리됩니다.

GitHub Actions의 `Checks`는 게임 설치 없이 위 검사를 실행합니다. 실제 DLL 빌드와 게임에서의 확인은 로컬에서 수행합니다.

게임에서는 다음을 확인하세요.

- 글로벌판·중국판의 경로 판별과 최초 리소스 다운로드, 한국어 적용
- 같은 게임의 재실행에서 캐시 재사용, 업데이트 확인 실패 시 검증된 캐시 사용
- 호환되지 않는 리소스나 불완전한 캐시로 시작할 때 원본 리소스 사용
- 진행 창 종료 후 게임 포커스 복구와 상태 오버레이 표시
- 닫기 버튼·Esc 동작과 닫을 때 아래 게임 UI가 함께 눌리지 않는지

참조 DLL·SDK·생성 코드·산출물은 `.work`, `dist`, `bin`, `obj`에 보관하며 Git에서 제외합니다.

## 커밋 메시지

`타입: 한글 메시지` 형식을 사용합니다. 예: `fix: 게임 업데이트 후 캐시 호환성 확인 수정`. 버전 증가에 사용하는 타입은 [릴리즈 문서](releases.md#커밋에-따른-버전-결정)에 정리되어 있습니다.
