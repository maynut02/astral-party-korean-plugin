# 개발 환경과 검증

사용자 설치는 [README](../README.md), 배포는 [로컬 빌드와 릴리즈](releases.md), 런타임 동작은 [코드 구조와 실행 흐름](architecture.md)을 참고하세요.

## 준비 사항

- Windows x64, PowerShell 7.2 이상, Git
- Astral Party Steam 글로벌판 또는 중국판
- [README의 설치 안내](../README.md#설치)에 따라 설정하고 한 번 실행한 BepInEx 6 Unity IL2CPP Windows x64
- 게임 실행으로 생성된 `BepInEx/interop` 참조 DLL
- Python과 `pytest`; CI에서는 Python 3.12 사용

프로젝트는 `net6.0`을 대상으로 빌드합니다. SDK는 `global.json`의 `6.0.428`과 `latestPatch` 정책을 사용합니다. 설치·전체 패키지의 BepInEx는 `6.0.0-be.788+5b766a3`으로 고정하며 빌드 참조는 준비된 게임의 `core`·`interop` DLL을 사용합니다.

환경 준비·빌드·검사·릴리스는 PowerShell 7.2 이상에서 실행합니다. 릴리스 서명은 .NET의 P-256 PKCS#8 가져오기와 IEEE P1363 서명을 사용하므로 Windows PowerShell 5.1에서는 실행하지 않습니다. 사용자용 `installer/install.ps1`은 별도의 오프라인 설치 경로입니다.

## 개발 환경 초기화

저장소 루트에서 실행합니다.

```powershell
.\scripts\setup.ps1
```

`setup.ps1`은 게임의 필수 참조 DLL을 `.work/refs`에 복사하고 `global.json`을 검증한 뒤 로컬 SDK를 `.work/dotnet`에 준비합니다. 호환되는 로컬 SDK는 재사용하며 첫 설치에는 인터넷 연결이 필요합니다. 시스템 SDK와 PATH는 변경하지 않습니다.

기본 게임 경로는 다음과 같습니다. `GameRoot`는 게임 실행 파일과 `BepInEx` 폴더가 있는 위치입니다.

```text
C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT
```

다른 Steam 라이브러리를 사용하면 게임 경로를 지정합니다. 작업 폴더도 `-WorkRoot`로 바꿀 수 있으며 이후 빌드·패키징에 같은 값을 전달하세요. 중국판은 게임 경로의 마지막 폴더를 `8vJXn6CN`으로 지정합니다.

```powershell
.\scripts\setup.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT' -WorkRoot '.\.work'
```

게임이나 BepInEx가 바뀐 뒤 참조만 갱신하려면 다음 명령을 사용합니다. SDK를 다시 설치하지 않습니다.

```powershell
.\scripts\sync-refs.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT' -WorkRoot '.\.work'
```

참조 목록·검증·복사는 `scripts/reference-files.ps1`, SDK 선택·설치는 `scripts/dotnet-sdk.ps1`에서 공유합니다. 필수 참조 전체를 검사한 뒤 복사하며, 실제 버전과 SHA-256은 `.work/refs/versions.json`에 기록합니다.

## DLL 빌드

```powershell
.\scripts\build.ps1
```

Release 설정으로 플러그인 DLL 한 개, 커밋된 폰트 번들의 복사본과 참조 기록을 생성합니다. `src/Plugin/AstralPartyKoreanPlugin.csproj`만 빌드하며 도구 프로젝트는 빌드하지 않습니다.

기본 개발 버전은 Git의 마지막 정식 태그 이후 Conventional Commits로 계산한 `<다음 버전>-dev.<커밋 수>`입니다. 태그 바로 위도 `-dev.0`이며 문서 변경만 있으면 다음 patch를 기준으로 하므로 항상 마지막 릴리스보다 높은 prerelease를 사용합니다. 전체 Git 기록과 태그가 필요합니다.

```text
dist/
├─ AstralPartyKoreanPlugin.dll
├─ astralkorean_fonts.bundle
└─ build-references.json
```
게임에서 확인할 때는 [README의 설치 위치](../README.md#설치)에 DLL과 폰트 번들을 함께 복사하세요.

| 옵션 | 동작 |
| --- | --- |
| `-Version` | 생략하면 이력에서 계산한 개발 prerelease; 명시하면 해당 SemVer 사용 |
| `-GameRoot` | 지정한 게임에서 참조 캐시 준비·갱신 |
| `-RefsRoot` | `core`와 `interop`를 바로 아래에 둔 참조 폴더 사용 |
| `-WorkRoot` | 로컬 SDK와 참조 캐시의 작업 폴더; 기본 `.work` |
| `-OutputRoot` | 빌드 산출물 폴더; 기본 `dist` |
| `-DotNetPath` | 사용할 `dotnet.exe` 지정 |

`-RefsRoot`가 가장 우선합니다. 생략하면 작업 폴더의 참조 캐시를 사용하며, `-GameRoot`를 직접 지정하거나 캐시가 없으면 게임에서 참조를 준비합니다. 실제 게임의 BepInEx 폴더도 직접 참조할 수 있습니다.

```powershell
.\scripts\build.ps1 -RefsRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT\BepInEx'
```

`-DotNetPath`를 지정하면 해당 실행 파일만 검사합니다. 생략하면 작업 폴더의 `dotnet/dotnet.exe`, PATH의 `dotnet` 순으로 `global.json`을 만족하는 SDK를 선택합니다. 호환 SDK가 없다면 `setup.ps1`을 다시 실행하거나 경로를 지정하세요.

```powershell
.\scripts\build.ps1 -WorkRoot '.\.work' -DotNetPath 'D:\Tools\dotnet\dotnet.exe'
```

### 공통 MSBuild 설정

| 파일 | 역할 |
| --- | --- |
| `global.json` | 로컬 개발과 CI의 SDK 선택 기준 |
| `Directory.Build.props` | 명시한 `AstralRefsRoot`, 로컬 `.work/refs`, 게임의 `BepInEx` 순으로 참조 경로 선택 |
| `Directory.Build.targets` | `AstralPluginVersion` 검증, DLL 버전 설정, `obj`에 `AstralBuildVersion.Value`와 `.Core` 생성 |
| Git의 `vX.Y.Z` 태그 | 릴리스 버전의 유일한 기준 |

직접 `dotnet build`할 때는 `-p:AstralPluginVersion=3.0.0-dev.1`처럼 버전을 명시해야 하며 생략하면 명확한 빌드 오류로 중단합니다. `Value`와 InformationalVersion은 prerelease·build metadata를 포함한 전체 SemVer이고, `Core`와 BepInEx 플러그인 메타데이터는 `X.Y.Z`, AssemblyVersion·FileVersion은 `X.Y.Z.0`입니다. C#에 제품 버전을 직접 넣거나 생성된 코드를 수정하지 않습니다. 참조 DLL은 제품 빌드 출력에 복사하지 않습니다.

## 릴리스 생성

최종 소스를 커밋하고 `origin` upstream에 push한 뒤 실행합니다.

```powershell
.\scripts\release.ps1 -Preview | Format-List
.\scripts\release.ps1
```

한 명령으로 검사·빌드·두 ZIP 패키징·업데이트 manifest 서명과 검증·annotated tag 생성과 push·GitHub Release 공개를 수행합니다. 버전을 올리기 위한 파일 수정·커밋은 없습니다. 서명 키는 기본 `%USERPROFILE%\.astral-party\plugin-update-signing.pem` 또는 `ASTRAL_UPDATE_SIGNING_KEY`/`-SigningKeyPath`에서 읽으며 플러그인의 신뢰 공개 키와 반드시 일치해야 합니다.

게시하지 않고 패키지만 만들려면 `.\scripts\package-release.ps1 -Version 3.0.0`을 사용합니다. 서명 키가 필요하고 항상 최신 소스를 빌드합니다. `-GameRoot`·`-RefsRoot`·`-WorkRoot`·`-DotNetPath`를 내부 빌드에 전달하고 `-OutputRoot`는 릴리스 폴더를 선택합니다. 내부 빌드 결과는 `dist/`, 기본 릴리스 결과는 `dist/release/vX.Y.Z/`에 보관합니다.

플러그인 전용 ZIP, 고정 BepInEx·설치 스크립트를 포함한 전체 ZIP, `update.json`·서명·체크섬을 만듭니다. BepInEx 캐시는 `.work/bepinex/`를 사용하고 고정 URL에서 최초 한 번 다운로드한 뒤에도 크기·SHA-256을 검증합니다. 테스트는 작은 로컬 ZIP과 임시 키만 사용하며 다운로드하지 않습니다. 옵션·키 보관·재시도·파일 구성은 [릴리스 문서](releases.md)에 정리되어 있습니다.

## 폰트 번들 수동 재생성

일반 빌드와 CI는 `assets/fonts/astralkorean_fonts.bundle`을 그대로 복사합니다. `tools/FontBundleBuilder`는 Unity 에디터 없이 AssetsTools.NET으로 번들을 만드는 별도 도구이며 입력 파일은 로컬에서 준비합니다. 게임 설치에는 쓰지 않습니다.

| 인수 | 준비할 입력 |
| --- | --- |
| `--template-bundle` | 게임의 원본 TMP 폰트 번들. 한국어 `tmp-font.dat`와 같은 TMP 직렬화 레이아웃을 사용해야 함 |
| `--unity-data` | 게임의 원본 `data.unity3d`; `resources.assets`의 `Afacad-Regular`와 연결된 Material·Font Texture를 읽기 전용으로 사용 |
| `--classdata` | 게임 Unity 버전에 맞는 `classdata.tpk` |
| `--ttf` | 인접 패치 저장소의 `resources/int_steam/legacy-font.ttf` (ONE Mobile POP) |
| `--tmp-data` | 같은 폴더의 한국어 TMP_FontAsset 직렬화 데이터 `tmp-font.dat` |
| `--tmp-atlas` | 같은 폴더의 `tmp-font-atlas.png`; TMP 데이터의 크기와 맞는 8-bit 비인터레이스 PNG |
| `--out` | 생성할 번들 경로 |
| `--tmp-json` | 선택 사항: 번들에 넣은 TMP JSON도 별도 파일로 출력 |

AssetBundle·Material·Texture2D 타입 트리는 TMP 번들에서, Font·TextAsset 타입 트리는 classdata에서 가져옵니다. 뒤의 두 타입은 원본 게임 데이터의 타입 해시와 일치해야 합니다. AssetsTools.NET 3.0.5의 null TypeBlob 변환 문제 때문에 도구가 전용 문자열 테이블과 MD4 타입 해시를 직접 구성합니다.

```powershell
$env:DOTNET_ROOT = "$PWD/.work/dotnet"
& ./.work/dotnet/dotnet.exe build tools/FontBundleBuilder -c Release -o .work/font-bundle/bin
& ./.work/dotnet/dotnet.exe .work/font-bundle/bin/FontBundleBuilder.dll `
    --template-bundle '<게임 TMP 폰트 번들>' `
    --unity-data '<게임 data.unity3d>' `
    --classdata '.work/tools/uabea/classdata.tpk' `
    --ttf '../astral-party-korean-patch/resources/int_steam/legacy-font.ttf' `
    --tmp-data '../astral-party-korean-patch/resources/int_steam/tmp-font.dat' `
    --tmp-atlas '../astral-party-korean-patch/resources/int_steam/tmp-font-atlas.png' `
    --out '.work/font-bundle/astralkorean_fonts.bundle'
```

생성 후 Font의 TTF 바이트, PNG와 번들 아틀라스의 alpha, TMP JSON의 메트릭·글리프·문자 테이블을 입력과 대조하고 실제 게임에서 확인한 뒤 `assets/fonts/astralkorean_fonts.bundle`로 복사합니다. 현재 번들은 Unity 2022.3용 UnityFS/LZ4이며 동적 ONE Mobile POP, Alpha8 2048×2048 아틀라스와 2,867개 글리프·문자를 포함합니다. 게임 스크립트는 포함하지 않으며 셰이더는 Unity 기본 리소스를 참조합니다. 도구의 `bin/obj`는 `.gitignore`의 공통 규칙으로 무시합니다.

TMP 아틀라스는 정적이므로 입력에 없는 문자를 자동 생성하지 않습니다. 현재 아틀라스에는 일부 ASCII 기호(`" # & @ [ ] _ { | }`) 등이 없으며, 보완하려면 TMP 데이터와 아틀라스를 함께 다시 만들어야 합니다. 레거시 동적 폰트와 TMP 화면의 글리프 지원을 구분하여 확인하세요.

## 검증

저장소 루트에서 CI의 `Checks`와 같은 전체 검사를 실행합니다.

```powershell
python -m pip install pytest
.\scripts\check.ps1
```

전체 실행기는 공개 파일, SDK·참조, SemVer·MSBuild 버전, 두 ZIP·서명 manifest, 한 명령 릴리스·안전한 업로드 검사와 `scripts/test.ps1`의 오프라인 설치·런타임 회귀 검사를 실행합니다. 런타임·설치 검사만 필요하면 다음 명령을 사용합니다.

```powershell
.\scripts\test.ps1
```

Python 검사는 게임·Unity 없이 .NET 하네스에서 운영 번역·캐시·경로 판별·구형 설치 정리 로직을 실행합니다. 패키지 검사는 운영 ZIP·manifest helper로 임시 파일을 만들고 검사하므로 기존 `dist/release/` 산출물에 의존하지 않습니다.

검사는 게임이나 운영 서버에 접속하지 않으며 GitHub 업로드는 테스트용 CLI로 대체합니다. CI에는 게임 참조 DLL을 넣지 않습니다. 배포 전에는 초기화된 실제 게임의 참조로 DLL을 빌드하고 다음을 확인하세요.

- 글로벌판·중국판의 경로 판별, 최초 번역 팩 다운로드와 한국어 적용
- 재실행 시 캐시 재사용, 온라인 확인 실패 시 검증된 캐시 사용
- 팩 번호가 작거나 같은 경우 유지, 새 번호 다운로드 실패 시 기존 팩 유지
- 세션 중 팩 고정, 미번역·신규 문자열의 원문 유지
- 레거시·TMP 대상 폰트 적용과 `SHOWG`·`SHOWG_TMP`·`hp02_TMP` 원본 유지
- 상태 오버레이 표시, 닫기·Esc와 오버레이 아래 게임 UI의 입력 차단
- 2.x 업그레이드 시 구형 DLL·캐시 정리와 게임 원본 보존

## 공개 파일과 서식

소스·테스트·스크립트·문서와 폰트 번들·BepInEx 라이선스는 공개 저장소에 포함합니다. 게임·Unity·IL2CPP·BepInEx 참조 DLL과 SDK, 로그·자격 증명·서명 개인 키·개인 개발 기록은 제외합니다. `.work`·`dist`·`bin`·`obj`는 로컬 산출물입니다. `check-public-files.ps1`은 Git의 추적 파일과 무시되지 않은 새 파일을 검사하며 폰트 번들은 허용합니다.

텍스트는 LF와 UTF-8을 사용합니다. C#·PowerShell·Python은 4칸, Markdown·YAML·XML·JSON은 2칸 들여씁니다. 릴리스 도구는 PowerShell 7.2 이상을 사용하며 새 텍스트 파일은 UTF-8 BOM 없이 저장합니다.

## 커밋 메시지

`타입: 한글 메시지` 형식을 사용합니다. 예: `fix: 번역 팩 캐시 검증 실패 처리 수정`. 버전 증가 규칙은 [릴리즈 문서](releases.md#커밋에-따른-버전-결정)에 있습니다.
