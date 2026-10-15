# 코드 구조와 실행 흐름

한글패치는 프리로더와 런타임 플러그인으로 나뉩니다. 설치는 [README](../README.md), 빌드·검증은 [개발 문서](development.md), 배포는 [릴리즈 문서](releases.md)를 참고하세요.

## 주요 구성

| 파일 | 역할 |
| --- | --- |
| `src/Preloader/DataUnity3dRedirect.cs` | 리소스 릴리즈 확인, 다운로드·검증, 캐시와 session 기록, `data.unity3d` 접근 전환, 시작 진행 창 |
| `src/Plugin/AddressablesInProcessPatch.cs` | 현재 프로세스의 캐시 준비, Addressables 로드 경로 전환, 상태 오버레이와 입력 처리 |
| `Directory.Build.props`, `Directory.Build.targets` | 참조 경로 선택, `VERSION` 검증과 `obj`의 버전 상수 생성 |
| `scripts/reference-files.ps1`, `scripts/dotnet-sdk.ps1` | 환경 준비와 빌드가 공유하는 참조·SDK 처리 |
| `scripts/build.ps1`, `scripts/package-release.ps1`, `scripts/package-files.ps1` | DLL 빌드, 공통 ZIP·체크섬 처리와 버전별 패키징 |
| `scripts/project-version.ps1`, `scripts/release-notes.ps1` | 버전 정책과 릴리즈 설명 생성 |
| `scripts/check.ps1`, `scripts/test.ps1`, `tests/` | 전체 검사와 런타임 회귀 검사 |

DLL 이름과 BepInEx 식별자는 별개입니다. 두 DLL은 아래 GUID와 공통 `AstralBuildVersion.Value`를 사용합니다.

| DLL | GUID |
| --- | --- |
| `AstralPartyKoreanPlugin.dataUnity3dRedirect.dll` | `astral-party.korean-patch.data-redirect` |
| `AstralPartyKoreanPlugin.dll` | `astral-party.korean-patch.addressables-in-process` |

## 실행 흐름

1. 프리로더는 게임 폴더 `8vJXnINT`·`8vJXn6CN` 또는 프로세스 이름 `AstralParty_INT`·`AstralParty_CN`으로 route를 판별하고 이전 세션 기록을 삭제합니다.
2. 최신 리소스 릴리즈를 확인합니다. ETag·릴리즈 태그·manifest 해시를 이용해 캐시를 재사용하거나 새 manifest와 payload를 준비합니다.
3. 설치된 원본 `data.unity3d`가 manifest의 원본 크기·SHA-256과 일치하고, 교체용 `data.unity3d`와 모든 Addressables payload가 준비된 뒤에만 `data-unity3d-state.json`을 원자적으로 갱신합니다. 새 릴리즈 준비 실패로 활성 상태를 먼저 바꾸지 않습니다.
4. PID·프로세스 시작 시각과 활성 리소스 정보를 `preloader-session.json`에 기록하고 `BepInEx/core/dobby.dll`로 `CreateFileW`를 후킹합니다. 후킹 실패 시 세션 기록을 삭제합니다.
5. 런타임은 같은 프로세스의 세션·상태·manifest를 확인하고 로컬 payload 목록을 준비합니다. 첫 `GetLoadInfo` 호출은 준비 작업을 최대 45초 기다립니다.
6. 대상 번들 요청에서 `AssetBundleResource.GetLoadInfo`의 로드 종류를 `Local`, 경로를 캐시 payload로 바꿉니다. 비동기 로드와 의존성 관리는 원래 Addressables provider가 수행합니다.

`CreateFileW`는 원본 `data.unity3d`의 정확한 경로를 교체 캐시 경로로 전환합니다. 게임 원본 파일이나 Addressables의 `__data`·catalog 파일을 덮어쓰지 않습니다. 런타임은 리소스를 직접 다운로드하지 않습니다.

런타임은 실제 요청의 번들 이름과 해시를 함께 비교합니다. IL2CPP에서 번들 옵션이 아직 없으면 `PrimaryKey`·`InternalId`·변환된 InternalId의 정확한 번들 해시로 찾습니다. 이미 알려진 옵션과 충돌하는 요청은 파일명으로 우회하지 않습니다. CDN 위치가 route·게임 버전·revision을 노출하면 준비된 패치와 모두 일치해야 합니다. `012/TmvW1l` 같은 추가 경로도 허용합니다.

오버레이는 Addressables 콜백에서 Unity 기본 UI로 만들고 갱신합니다. `EventSystem.Update`에서 닫기 입력을 처리하고, 패널 위의 왼쪽 마우스 입력이 게임 컨트롤에 전달되지 않도록 처리합니다.

## 외부 연동과 검증

번역 리소스는 [한글패치 리소스 Releases](https://github.com/maynut02/astral-party-korean-patch/releases)에서 가져옵니다. DLL 배포 저장소와 별개이며 리소스 릴리즈 태그와 제품 버전도 별개입니다.

프리로더의 조회 주소는 `https://api.github.com/repos/maynut02/astral-party-korean-patch/releases/latest`입니다. manifest와 payload의 다운로드 URL은 해당 저장소의 HTTPS `releases/download/` 경로로 제한합니다.

| route | 리소스 manifest | 원본 경로: 게임 폴더 기준 |
| --- | --- | --- |
| `INT_STEAM` | `INT_STEAM_manifest.json` | `AstralParty_INT_Data/data.unity3d` |
| `CN_STEAM` | `CN_STEAM_manifest.json` | `AstralParty_CN_Data/data.unity3d` |

| 항목 | 확인 내용 |
| --- | --- |
| manifest | `schemaVersion = 2`, 같은 route, `channel = release`, `patch.version`과 리소스 릴리즈 태그 일치 |
| manifest 해시 | GitHub asset digest가 있으면 다운로드 SHA-256과 비교; 캐시에서는 상태에 기록한 SHA-256과 비교 |
| 게임 호환성 | 설치된 원본 파일로 교체 데이터의 호환성을 확인하고, 실행 중 버전과 실제 번들 요청의 식별 정보로 Addressables 적용 여부 판단 |
| 설치 원본 | 원본 `data.unity3d`의 크기·SHA-256이 manifest의 `sourceSize`·`sourceSha256`과 일치하는지 매 실행 확인 |
| 다운로드 | gzip의 크기·`downloadSha256`, 압축 해제한 payload의 `size`·`sha256`, `UnityFS` 헤더 확인 |
| Addressables 항목 | `target = addressables`, `번들/해시/__data` 경로, `compression = gzip`, `operation = replace` |
| 런타임 인계 | 상태의 `AddressablesReady`, 세션의 `Ready`·PID·시작 시각·route·태그·manifest 해시·게임 버전·catalog 해시 일치 |
| 런타임 재확인 | manifest 해시와 로컬 번들의 크기·UnityFS 확인; 리디렉션 전에 `Application.version`과 실제 요청의 번들 이름·해시 및 노출된 CDN route·버전·revision 확인 |

원본 `data.unity3d`는 존재하고 읽을 수 있어야 하며 `sourceSize`·`sourceSha256`이 모두 일치해야 합니다. 불일치는 `rejected-mismatch`로 기록하고 해당 패치의 적용을 거부합니다. 이 검사는 신규 다운로드와 캐시 재사용, 오프라인 이전 패치 재사용에 모두 적용합니다. 교체 payload에도 별도의 크기·해시 검증을 적용합니다.

Steam 업데이트 직후 LocalLow의 카탈로그는 이전 버전이거나 없을 수 있습니다. 카탈로그 파일을 시작 조건으로 삼지 않으므로 설치 원본과 대응하는 최신 패치가 배포돼 있으면 첫 실행부터 준비합니다. 실행 중에는 게임이 실제 요청한 번들과 일치하는 패치만 연결합니다. manifest의 catalog 해시는 패치와 프리로더 세션의 식별 정보로 유지하며, 이전 실행의 파일을 현재 로드된 카탈로그로 간주하지 않습니다. 게임 카탈로그와 원본 파일은 덮어쓰지 않습니다.

최신 패치가 설치 원본과 다르면 이전 캐시도 같은 원본 검사를 통과해야 사용할 수 있습니다. 유효한 패치가 없으면 세션 기록과 파일 접근 후킹 없이 원본으로 실행합니다. 호환되는 패치가 배포된 다음 실행에는 다시 최신 릴리스를 확인합니다.

기존 `data.unity3d` 교체 캐시는 크기와 저장된 수정 시각이 같으면 전체 해시 검사를 생략합니다. 설치 원본은 수정 시각이 같아도 항상 크기·SHA-256을 검사하며, 이전 플러그인이 불일치 상태에서 저장한 시각도 신뢰하지 않습니다. Addressables 캐시는 프리로더에서 크기·UnityFS·SHA-256을 확인하며 런타임은 현재 세션으로 검증 결과를 인계받습니다.

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
| `BepInEx/data-redirect.log` | 프리로더의 갱신·검증·캐시 선택·세션·파일 접근 전환 |
| `BepInEx/AstralPartyKoreanPatch/addressables-patch.jsonl` | 런타임 준비·리디렉션·실패 이벤트, UTC 시각과 PID |

게임의 catalog 캐시는 `%USERPROFILE%/AppData/LocalLow/feimo/` 아래의 `AstralParty_INT/com.unity.addressables/` 또는 `AstralParty_CN/com.unity.addressables/`에 있습니다. 플러그인은 이 캐시의 생성·갱신 시점에 의존하지 않으며 카탈로그 갱신은 게임에 맡깁니다.

## 실패 시 적용 범위

온라인 확인·갱신에 실패하면 기존 활성 상태를 다운로드 없이 다시 확인합니다. 오프라인에서도 manifest·설치 원본·교체 데이터·모든 Addressables payload가 유효한 캐시는 사용할 수 있습니다. 실행 중 번들 연결에는 같은 버전·번들 식별 정보 검사를 적용합니다.

| 실패 지점 | 동작 |
| --- | --- |
| 프리로더 캐시 없음, 원본 파일 없음·읽기 실패, 후킹 실패 | 이번 실행의 준비 세션을 제공하지 않고 원래 로드 경로 유지 |
| 런타임 세션·manifest·payload 준비 실패 | Addressables의 원래 `GetLoadInfo` 실행 |
| 런타임 게임 버전 불일치 또는 확인 실패 | 이번 프로세스의 이후 Addressables 리디렉션 중단 |
| 대상 번들 불일치·payload 누락·개별 리디렉션 예외 | 해당 요청에서 원래 `GetLoadInfo` 실행 |

런타임이 원래 Addressables 로드 경로를 사용해도 프리로더가 설치한 `data.unity3d` 후킹은 유지됩니다.

## 변경 시 확인할 범위

manifest·catalog·캐시·세션 변경은 신규 다운로드·캐시 재사용과 오프라인·불완전 캐시에서의 동작을 확인하세요. 후킹·번들 식별·오버레이·입력 변경은 글로벌판·중국판의 실제 게임 검사를 포함한 [개발 문서의 검증](development.md#검증)을 따릅니다.
