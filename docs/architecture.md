# 코드 구조와 리소스 적용

한글패치는 프리로더와 런타임 플러그인으로 나뉩니다. 설치·빌드는 [README](../README.md), DLL 배포는 [릴리즈 문서](releases.md)를 참고하세요.

## 주요 구성

| 파일 | 역할 |
| --- | --- |
| `src/Preloader/DataUnity3dRedirect.cs` | 리소스 릴리즈 확인, 다운로드·검증, 캐시와 session 기록, `data.unity3d` 접근 전환, 시작 진행 창 |
| `src/Plugin/AddressablesInProcessPatch.cs` | 현재 프로세스의 캐시 준비, Addressables 로드 경로 전환, 상태 오버레이와 입력 처리 |
| `Directory.Build.props` | 두 프로젝트의 BepInEx 참조 경로 선택 |
| `scripts/setup.ps1` | 실제 게임의 참조 DLL 복사 후 `global.json`의 SDK를 `.work/dotnet`에 준비 |
| `scripts/reference-files.ps1` | `Sync-AstralReferences`로 필수 참조 DLL 확인·복사와 버전 기록 |
| `scripts/dotnet-sdk.ps1` | 호환 SDK 재사용, Microsoft 공식 설치기를 통한 로컬 SDK 설치, 빌드용 SDK 선택 |
| `scripts/build.ps1` | 호환 SDK 확인, 공통 버전 소스 생성, 기본 `dist/`에 최신 DLL 두 개와 `build-references.json` 생성 |
| `scripts/package-release.ps1` | `build.ps1` 호출 후 DLL 두 개와 참조 기록을 기본 `dist/release/vX.Y.Z/`에 복사하고, 같은 폴더에 DLL 두 개만 담은 ZIP·빌드 메타데이터·체크섬 생성 |
| `VERSION`, `scripts/project-version.ps1` | 공통 버전과 버전 해석·증가 규칙 |
| `scripts/prepare-release.ps1`, `scripts/upload-release.ps1` | 버전·설명 초안 준비, `VERSION`에서 정한 기본 `dist/release/vX.Y.Z/`의 ZIP과 체크섬을 플러그인 Release에 업로드 |
| `tests/test_plugin.py`, `tests/test_package.py`, `tests/scripts/` | 소스 회귀, ZIP 구성·체크섬, 참조·SDK·버전·릴리즈 스크립트 검사 |

릴리즈 파일은 버전별 폴더에 보관하므로 다른 버전을 패키징해도 이전 산출물은 유지됩니다. 전체 [산출물 구성](releases.md#3-로컬-빌드와-패키징)을 참고하세요.

DLL 이름과 BepInEx 식별자는 별개입니다. 두 DLL은 아래 기존 GUID를 사용하며, 버전은 빌드에서 생성한 `AstralBuildVersion.Value`를 공유합니다.

| DLL | GUID |
| --- | --- |
| `AstralPartyKoreanPlugin.dataUnity3dRedirect.dll` | `astral-party.korean-patch.data-redirect` |
| `AstralPartyKoreanPlugin.dll` | `astral-party.korean-patch.addressables-in-process` |

## 실행 흐름

1. 프리로더는 게임 폴더 `8vJXnINT`·`8vJXn6CN` 또는 프로세스 이름 `AstralParty_INT`·`AstralParty_CN`으로 route를 판별하고 이전 session을 삭제합니다.
2. 최신 리소스 릴리즈를 확인합니다. ETag·릴리즈 태그·manifest digest를 이용해 캐시를 재사용하거나 새 manifest와 payload를 준비합니다.
3. 게임 catalog 호환성, 교체용 `data.unity3d`, 모든 Addressables payload가 준비된 뒤에만 `data-unity3d-state.json`을 원자적으로 갱신합니다. 새 릴리즈 준비 실패로 활성 상태를 먼저 바꾸지 않습니다.
4. PID·프로세스 시작 시각과 활성 리소스 정보를 `preloader-session.json`에 기록하고 `BepInEx/core/dobby.dll`로 `CreateFileW`를 후킹합니다. 후킹 실패 시 session을 삭제합니다.
5. 런타임은 같은 프로세스의 session·상태·manifest를 확인하고 로컬 payload 목록을 준비합니다. 첫 `GetLoadInfo` 호출은 준비 작업을 최대 45초 기다립니다.
6. 대상 번들 요청에서 `AssetBundleResource.GetLoadInfo`의 로드 종류를 `Local`, 경로를 캐시 payload로 바꿉니다. 비동기 로드와 의존성 관리는 원래 Addressables provider가 수행합니다.

`CreateFileW`는 원본 `data.unity3d`의 정확한 경로를 교체 캐시 경로로 전환합니다. 게임 원본 파일이나 Addressables의 `__data`·catalog 파일을 덮어쓰지 않습니다. 런타임은 리소스를 직접 다운로드하지 않습니다.

런타임은 번들 이름과 해시를 함께 비교합니다. 직접 일치하지 않으면 `PrimaryKey`·`InternalId`·변환된 InternalId에 포함된 manifest의 번들 해시로 찾습니다. 위치에 준비된 게임 버전이 포함되면 `/버전/revision/`도 확인합니다.

오버레이는 Addressables 콜백에서 Unity 기본 UI로 만들고 갱신합니다. `EventSystem.Update`에서 닫기 입력을 처리하고, 패널 위의 왼쪽 마우스 입력이 게임 컨트롤에 전달되지 않도록 처리합니다.

## 리소스 저장소와 검증

번역 리소스는 [리소스 저장소](https://github.com/maynut02/astral-party-korean-patch/releases)의 Releases에서 가져옵니다. 이 플러그인 저장소의 DLL ZIP을 배포하는 Releases와 별개이며, 리소스 릴리즈 태그와 DLL 버전도 별개입니다.

프리로더의 조회 주소는 `https://api.github.com/repos/maynut02/astral-party-korean-patch/releases/latest`입니다. manifest와 payload의 다운로드 URL은 해당 저장소의 HTTPS `releases/download/` 경로로 제한합니다.

| route | 리소스 manifest | 원본 경로: 게임 폴더 기준 |
| --- | --- | --- |
| `INT_STEAM` | `INT_STEAM_manifest.json` | `AstralParty_INT_Data/data.unity3d` |
| `CN_STEAM` | `CN_STEAM_manifest.json` | `AstralParty_CN_Data/data.unity3d` |

| 항목 | 확인 내용 |
| --- | --- |
| manifest | `schemaVersion = 2`, 같은 route, `channel = release`, `patch.version`과 리소스 릴리즈 태그 일치 |
| manifest 해시 | GitHub asset digest가 있으면 다운로드 SHA-256과 비교; 캐시에서는 상태에 기록한 SHA-256과 비교 |
| 게임 호환성 | 유효한 `catalog_*.hash` 중 가장 높은 버전의 파일명·내용을 `game.version`·`game.catalogHash`와 비교 |
| 다운로드 | gzip의 크기·`downloadSha256`, 압축 해제한 payload의 `size`·`sha256`, `UnityFS` 헤더 확인 |
| Addressables 항목 | `target = addressables`, `번들/해시/__data` 경로, `compression = gzip`, `operation = replace` |
| 런타임 인계 | 상태의 `AddressablesReady`, session의 `Ready`·PID·시작 시각·route·태그·manifest 해시·게임 버전·catalog 해시 일치 |
| 런타임 재확인 | manifest 해시와 로컬 번들의 크기·UnityFS 확인; 리디렉션 전에 `Application.version`과 해당 catalog 해시 확인 |

원본 `data.unity3d`는 존재하고 읽을 수 있어야 합니다. `sourceSize`·`sourceSha256` 불일치는 `ignored-mismatch`로 기록하며 적용을 거부하지 않습니다. 교체 payload에는 별도의 크기·해시 검증을 적용합니다.

기존 `data.unity3d` 교체 캐시는 크기와 저장된 수정 시각이 같으면 전체 해시 검사를 생략합니다. Addressables 캐시는 프리로더에서 크기·UnityFS·SHA-256을 확인하며, 런타임은 이 검증 결과를 현재 session으로 인계받습니다.

## 캐시와 로그

캐시 루트는 게임 폴더의 `BepInEx/AstralPartyKoreanPatch/`입니다. 상태가 가리키는 manifest·payload를 사용하므로 다른 릴리즈의 파일이 남아 있어도 임의로 선택하지 않습니다.

| 캐시 루트 아래 경로 | 내용 |
| --- | --- |
| `data-unity3d-state.json` | 활성 리소스 태그·manifest·payload 해시, 게임 식별 정보, ETag와 수정 시각 |
| `preloader-session.json` | 이번 프로세스에서 준비한 리소스와 준비 완료 여부 |
| `releases/<manifest-sha256>/manifest.json` | 해시별 manifest |
| `game-data/<payload-sha256>.unity3d` | 교체용 `data.unity3d` |
| `payloads/<payload-sha256>.bundle` | Addressables 번들 |

구형 `BepInEx/plugins/AstralPartyKoreanPatch/`의 캐시·상태·로그는 새 위치에 대응 항목이 없을 때 옮깁니다. 이전 `patched-data.unity3d`와 `cache/<route>-manifest.json`은 검증 후 현재 캐시 형식으로 복사할 수 있습니다.

| 실제 로그 경로: 게임 폴더 기준 | 용도 |
| --- | --- |
| `BepInEx/data-redirect.log` | 프리로더의 갱신·검증·캐시 선택·session·파일 접근 전환 |
| `BepInEx/AstralPartyKoreanPatch/addressables-patch.jsonl` | 런타임 준비·리디렉션·실패 이벤트, UTC 시각과 PID |

catalog는 `%USERPROFILE%/AppData/LocalLow/feimo/` 아래의 `AstralParty_INT/com.unity.addressables/` 또는 `AstralParty_CN/com.unity.addressables/`에서 읽습니다. 런타임은 이 위치의 `catalog_<Application.version>.hash`를 확인합니다.

## 실패 시 적용 범위

온라인 확인·갱신에 실패하면 기존 활성 상태를 다운로드 없이 다시 확인합니다. 오프라인에서도 manifest·게임 catalog·교체 데이터·모든 Addressables payload가 유효한 캐시는 사용할 수 있습니다.

| 실패 지점 | 동작 |
| --- | --- |
| 프리로더에 사용 가능한 캐시가 없거나 원본이 없거나 읽을 수 없음, 후킹 실패 | 이번 실행의 준비 session을 제공하지 않고 원래 로드 경로 유지 |
| 런타임 session·manifest·payload 준비 실패 | Addressables의 원래 `GetLoadInfo` 실행 |
| 런타임 게임 버전·catalog 변경 또는 확인 실패 | 이번 프로세스의 이후 Addressables 리디렉션 중단 |
| 대상 번들 불일치·payload 누락·개별 리디렉션 예외 | 해당 요청에서 원래 `GetLoadInfo` 실행 |

런타임이 원래 Addressables 로드 경로를 사용해도 프리로더가 설치한 `data.unity3d` 후킹은 유지됩니다.

## 변경 시 확인할 범위

manifest·catalog·캐시·session 변경은 신규 다운로드와 캐시 재사용, 오프라인·불완전 캐시에서의 동작을 확인하세요. 후킹·번들 식별·오버레이·입력 변경은 INT/CN 실제 게임 검사를 포함한 [개발 문서의 검증](development.md#검증)을 따릅니다. 버전·패키징·업로드 변경은 같은 검증과 [릴리즈 문서](releases.md)를 함께 확인하세요.
