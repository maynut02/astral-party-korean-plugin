# 코드 구조와 실행 흐름

게임 원본 파일을 바꾸지 않고, 읽는 텍스트와 사용하는 폰트를 런타임에서 교체합니다. 게임 버전별 교체 번들이나 파일 접근 후킹은 사용하지 않습니다.

## 구성

- `src/Plugin/`: BepInEx 6 IL2CPP 플러그인, Harmony 후킹, 번역 팩 클라이언트, 서명 검증·플러그인 자동 업데이트, 폰트 적용, 상태 오버레이
- `assets/fonts/astralkorean_fonts.bundle`: 배포하는 폰트 번들의 원본
- `tools/FontBundleBuilder/`: 폰트 번들을 수동 재생성하는 도구. 일반 빌드·CI에서는 실행하지 않음
- `Directory.Build.props`, `Directory.Build.targets`: 참조 경로 선택, 태그에서 결정한 `AstralPluginVersion` 검증, `AstralBuildVersion.Value`(전체 SemVer)·`Core`(`X.Y.Z`) 생성
- `scripts/`: 참조 준비, 플러그인 빌드, 두 파일 패키징과 릴리즈 처리

## 시작과 번역 팩

1. 실행 파일·데이터 폴더로 글로벌판(INT) 또는 중국판(CN)을 판별합니다.
2. 구형 설치를 정리합니다. 새 설치 위치는 `BepInEx/plugins/AstralPartyKoreanPlugin/`입니다. 업그레이드 시 이전 플러그인 폴더는 재귀 삭제하고 로드 중인 DLL은 가능하면 `.removed`로 바꿔 다음 실행에서 지웁니다. 실행 중인 DLL이 구형 폴더 안에 있으면(디렉터리 링크로 접근한 경우 포함) 그 폴더는 보존하고 알려진 구형 캐시만 정리합니다. 실패 시 로그와 상태창을 확인하고 [업데이트 안내](../README.md#2x에서-업데이트하는-경우)에 따라 게임 종료 후 직접 삭제하세요.
   플러그인 폴더의 검증된 `*.new` 업데이트도 이때 적용하고 이전 `*.old`를 정리합니다. `FontAssets`를 호출하거나 폰트 후킹을 설치하기 전이므로 전 실행에서 Unity가 잡고 있던 번들을 바꿀 수 있습니다. 개발·프리릴리스 빌드는 예약된 파일도 자동 적용하지 않습니다.
3. `https://file.maynutlab.com/translation-pack/latest.json`에서 최신 번역 팩 포인터를 확인합니다. `schemaVersion: 1`, `locale: ko`를 사용합니다.
4. 캐시보다 큰 `number`만 새 팩으로 취급합니다. `version`·`revision`·`publishedAt`은 표시·기록용이며 게임 버전과 비교하지 않습니다. 작은 번호로 되돌아가지 않습니다.
5. 포인터의 `path`에 있는 gzip 팩을 검증하고 캐시에 저장합니다. 캐시는 설치 폴더명이 아니라 실행 중인 DLL의 디렉터리에서 구한 `translation-pack/`입니다. `latest.json`과 `{number}.json.gz`를 저장하고 이전 팩을 정리합니다. 팩 파일을 먼저 쓰고 포인터를 마지막에 교체하여 중단된 갱신이 기존 캐시를 깨뜨리지 않게 합니다.
6. 준비한 팩을 이번 세션 동안 고정합니다. 실행 중 팩이 배포되어도 이미 읽은 에셋과 다른 세대의 번역을 섞지 않으며 다음 게임 실행에서 갱신합니다.

네트워크 확인·다운로드에 실패하면 검증된 번역 캐시를 사용합니다. 유효한 팩이 없으면 원문을 표시합니다. 플러그인 자체 업데이트는 아래 서명된 GitHub Release 매니페스트로 별도로 확인하며 번역 팩과 수명·버전 체계를 공유하지 않습니다.

### 번역 팩 형식과 검증

사이트 관리자 페이지의 `번역 팩 배포`가 승인된 한국어 번역 전체를 하나의 팩으로 게시합니다. 생성 코드는 사이트 저장소의 `server/utils/translation-pack.ts`, 운영 절차는 그 저장소의 `deploy/README.md`에 있습니다.

| URL (`https://file.maynutlab.com/` 기준) | 내용 | 배포 헤더 |
| --- | --- | --- |
| `translation-pack/latest.json` | 최신 포인터 | `Cache-Control: no-cache` |
| `translation-pack/packs/{number}.json.gz` | gzip JSON 팩 | `Cache-Control: public, max-age=31536000, immutable`; `Content-Encoding` 없음 |

포인터:

```json
{
  "schemaVersion": 1,
  "locale": "ko",
  "number": 57,
  "version": "3.3.0",
  "revision": "026",
  "publishedAt": "2026-10-22T03:10:00Z",
  "path": "packs/57.json.gz",
  "size": 208550,
  "sha256": "<gzip 바이트의 SHA-256: 64자리 16진수>"
}
```

팩(gzip 해제 후):

```json
{
  "schemaVersion": 1,
  "locale": "ko",
  "pack": {
    "number": 57,
    "version": "3.3.0",
    "revision": "026",
    "publishedAt": "2026-10-22T03:10:00Z"
  },
  "lang": { "<key>": "<text>" },
  "str": { "<STR 에셋 이름>": { "<uint32 id>": "<text>" } }
}
```

- `number`는 양의 64비트 정수이며 배포마다 증가하고 재사용하지 않습니다. `path`는 정확히 `packs/{number}.json.gz`여야 하며 외부 URL·상대 경로 이동을 허용하지 않습니다.
- 포인터는 최대 64 KiB, gzip 파일은 최대 32 MiB, 압축 해제 JSON은 최대 128 MiB입니다. gzip 바이트의 실제 크기와 SHA-256, 양쪽 `schemaVersion`·`locale`, 팩 내부 `pack.number`를 검증합니다. 캐시를 읽을 때도 같은 검증을 합니다.
- `version`·`revision`은 팩 게시 시점의 INT_STEAM 처리 정보입니다. `publishedAt`도 기록용이며 게임 호환성·갱신 순서 판단에 쓰지 않습니다. 번역은 원문 버전과 대조하지 않으며 INT/CN이 같은 팩을 사용합니다.
- 번역값은 null이 아닌 문자열, STR id는 uint32로 읽을 수 있는 10진수입니다. 번역 맵의 중복 키·id와 잘못된 JSON/형식은 팩 전체를 거부합니다. 게시 시 줄바꿈은 `\n`으로 정규화합니다.
- 지원하지 않는 스키마는 기존 세션 팩을 유지하면서 플러그인 업데이트를 안내합니다. 최초 번역 읽기는 플러그인 시작부터 최대 10초까지 준비를 기다린 뒤 팩을 고정합니다. 이후 받은 새 팩은 다음 실행부터 사용합니다.

## 텍스트 후킹

Harmony로 `TextAsset` 읽기를 후킹하고 에셋 이름으로 대상을 고릅니다. STR은 팩의 `str[에셋 이름][id]`, lang XML은 `lang[key]`를 사용합니다. 원문 문자열이나 게임 버전을 대조하지 않습니다. 팩에 없는 새 에셋·id·키는 원문을 유지합니다.

| 판 | lang TextAsset | STR protobuf 언어 필드 |
| --- | --- | --- |
| INT (`AstralParty_INT.exe` / `AstralParty_INT_Data`) | `English` | 3 |
| CN (`AstralParty_CN.exe` / `AstralParty_CN_Data`) | `Simplified Chinese` | 2 |

두 판은 같은 번역 팩과 폰트를 사용합니다. STR의 다른 언어·구조는 보존하며 lang도 기존 키만 바꿉니다. 읽기·변환 실패는 원본 읽기로 돌아갑니다. 번역 결과를 캐시해 같은 원본을 반복 변환하지 않습니다.

원본 바이트는 `TextAsset.GetDataPtr`·`GetDataSize`로 읽어 getter 재호출을 피하고, 에셋 이름·길이·FNV-64로 변환 결과를 구분합니다. STR wrapper의 field 1 direct 항목과 field 2 mirror 내부의 field 2 항목을 모두 처리합니다. Id는 field 1 fixed32이며 proto3에서 생략된 Id는 0입니다. lang XML은 기존 `<string name="key">`만 바꾸고 공백·줄바꿈을 보존합니다.

## 플러그인 자동 업데이트

`[BepInPlugin]`에는 `AstralBuildVersion.Core`만 전달합니다. 로그·오버레이·HTTP User-Agent는 `Value`를 사용하므로 `3.1.0-dev.2` 같은 개발 빌드를 구별합니다.

### 서명과 다운로드

게임을 시작할 때 `PluginUpdateClient`는 GitHub API 대신 아래 고정 URL에서 `update.json`과 `update.json.sig`를 받습니다.

```text
https://github.com/maynut02/astral-party-korean-plugin/releases/latest/download/update.json
https://github.com/maynut02/astral-party-korean-plugin/releases/latest/download/update.json.sig
```

- 매니페스트 원본 UTF-8 바이트를 **JSON 파싱 전** 내장 SPKI 공개 키로 검증합니다. 서명은 ECDSA P-256 / SHA-256, 64바이트 IEEE P1363이며 `.sig`에는 ASCII base64로 저장합니다. 개인 키는 플러그인에 포함하지 않습니다.
- `schemaVersion: 1`, 정식 SemVer, `minimumBepInEx`, 패키지 이름·URL·크기·SHA-256 및 두 파일의 경로·크기·SHA-256을 필수로 검사합니다. 중복·누락·알 수 없는 속성과 파일 경로는 거부합니다. 패키지는 정확히 `AstralPartyKoreanPlugin-vX.Y.Z.zip`, URL은 이 저장소의 `https://github.com/maynut02/astral-party-korean-plugin/releases/download/vX.Y.Z/` 아래 동일 파일이어야 합니다.
- 매니페스트는 최대 64 KiB, 서명 텍스트는 256바이트, ZIP과 개별 파일은 각각 64 MiB입니다. 네트워크 응답은 스트리밍으로 상한을 지키고, 실제 ZIP 크기·SHA-256을 대조한 뒤 메모리에서 풉니다. ZIP에는 명시한 DLL과 폰트 번들 두 정규 파일만 허용하며 중복·추가·누락·디렉터리·심볼릭 링크·상대 경로 이동은 거부합니다. 해제한 모든 파일의 실제 크기·해시가 맞아야 설치 단계로 넘어갑니다.
- 설치된 버전보다 높은 정식 릴리스만 설치합니다. 설치된 버전이 프리릴리스이면 최신 버전은 표시하되 설치하지 않습니다. `Paths.BepInExVersion`의 실행 중 버전을 `minimumBepInEx`와 SemVer로 비교합니다. 이 API의 외부 반환 타입을 새 참조로 요구하지 않도록 정확한 공개 속성을 리플렉션으로 읽으며, 읽기 실패·최소 버전 미달 시 자동 설치를 중단하고 수동 업데이트를 안내합니다.
- BepInEx 플러그인 설정 `BepInEx/config/astral-party.korean-patch.cfg`의 `[Update] AutoUpdate = true`가 기본값입니다. `false`이면 최신 버전만 확인하고 자동 설치하지 않습니다. DLL까지 이미 교체된 업데이트의 남은 폰트 번들만 다음 시작 때 마저 적용합니다.
- 매니페스트를 받지 못하거나 검증하지 못하면(오프라인, GitHub 장애) 최신 버전만 `확인 실패`로 표시하고 상태 문구는 바꾸지 않아 번역 팩 상태가 그대로 보입니다. 검증된 매니페스트 이후 단계의 실패만 수동 업데이트를 안내합니다. 큰 응답은 최소 64 KiB/s 기준의 전체 제한 시간(최소 15초)과 5초 무응답 제한을 함께 적용합니다.

### 파일 교체와 복구

설치 위치는 고정된 `BepInEx/plugins/...`가 아니라 **실행 중인 플러그인 DLL의 디렉터리**입니다. ZIP의 두 경로는 그 디렉터리의 파일명에만 대응시키므로 게임 원본·다른 플러그인·번역 캐시는 건드리지 않습니다.

1. 서명된 매니페스트·서명은 `.update.json`·`.update.json.sig`에 보관합니다. 새 파일은 먼저 같은 디렉터리의 임시 파일에 끝까지 쓰고 `Flush(true)`한 후 `*.new`로 이름을 바꿉니다. 불완전한 쓰기는 설치 파일이 되지 않습니다.
2. DLL을 먼저 교체하고 성공한 뒤에만 폰트 번들을 교체합니다. DLL 교체가 실패하면 설치된 두 파일은 그대로이며 예약 파일은 다음 시작 때 지워지므로, 새 번들이 이전 DLL과 섞여 남지 않습니다. 기존 파일은 삭제하지 않고 `File.Replace`의 백업 이름 `*.old`로 보존합니다. Windows의 [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew)가 이름 교체와 백업을 처리하므로 실행 중 이미지 매핑된 DLL을 삭제할 필요가 없습니다. 실패 후 원래 이름이 사라졌다면 백업을 즉시 복원합니다.
3. Unity가 폰트 번들을 열어 교체가 거부되면 기존 번들은 그대로 두고 검증된 `astralkorean_fonts.bundle.new`를 유지합니다. DLL 교체 성공 시 설치 완료·재시작 필요 상태를 표시합니다.
4. 다음 시작 때 `UpdateInstaller.PrepareStartup`은 **실행 중인 플러그인이 예약 매니페스트와 같은 버전일 때만**(DLL 교체가 이미 끝난 경우) 서명과 남은 `astralkorean_fonts.bundle.new`의 크기·해시를 다시 확인해 폰트를 읽기 전에 적용합니다. 그 밖의 예약 상태(교체되지 않은 `*.dll.new`, 일부만 쓴 예약, 서명 없는·오래된·프리릴리스 대상 예약, `*.tmp`)는 적용하지 않고 모두 지웁니다. 아직 새 릴리스가 필요하면 온라인 확인이 일반 설치 조건(`AutoUpdate`, `minimumBepInEx`)으로 다시 받습니다. 번들 검증 실패는 이번 세션에만 경고하고, 적용 I/O 실패는 예약을 남겨 다음 시작에 재시도합니다. 유효한 현재 파일이 있으면 알려진 두 `*.old`만 지우고, 현재 파일이 없으면 남아 있는 백업을 복원합니다. 설치 프로그램(`install.ps1`)으로 수동 설치하면 남은 예약 파일도 지웁니다.

DLL 교체 도중 프로세스가 강제 종료되어 `AstralPartyKoreanPlugin.dll` 없이 `.old`만 남는 경우는 DLL 자체가 로드되지 않으므로 자동 복구할 수 없습니다(`File.Replace`의 이름 바꾸기 사이 짧은 구간). 이때는 `install.bat`이나 플러그인 ZIP으로 다시 설치합니다.

확인·검증·예약·교체·복구·정리·실패를 BepInEx 로그에 남깁니다. 다운로드나 검증 실패는 기존 DLL을 유지하고 상태창에 짧은 수동 업데이트 안내를 표시합니다. 구형 파일 정리 실패는 업데이트 성공·실패 메시지보다 우선하는 오류로 유지합니다.

### 게임 다시 시작

설치가 끝나면 상태창이 `플러그인 vX.Y.Z 설치 완료 · 다시 시작하면 적용됩니다`와 **지금 다시 시작** 버튼을 표시합니다. 사용자가 창을 닫아 두었어도 이 알림을 위해 한 번만 다시 엽니다. 다시 닫으면 같은 설치 알림으로 반복해 열지 않습니다.

버튼은 현재 프로세스의 실행 파일(`Paths.ExecutablePath`, 대체 경로 `MainModule.FileName`)과 PID를 얻고 숨겨진 시스템 `cmd.exe /d /v:off /c`를 시작한 뒤 Unity 메인 스레드에서 `Application.Quit()`를 호출합니다. 도우미는 시스템 `tasklist.exe`로 그 PID가 사라질 때까지 대기하고, 시스템 `ping.exe`로 대기 간격을 둔 뒤 원래 디렉터리에서 같은 실행 파일을 `start`합니다. 경로는 환경 변수로 전달하고 지연 확장은 끄므로 공백·`&`·`%`·`!`가 포함된 경로도 명령문에 끼워 넣지 않습니다. PowerShell, 다운로드한 EXE, 별도 실행 파일은 사용하지 않습니다.

Doorstop은 주입한 게임 프로세스에 `DOORSTOP_DISABLE=TRUE` 등을 설정합니다. 이 값을 물려받은 게임은 BepInEx를 건너뛰므로(실제 게임에서 확인) 도우미 환경에서 `DOORSTOP_*` 변수를 모두 지웁니다. `SteamAppId` 등 Steam 변수는 유지하므로 다시 시작한 게임은 Steam 재실행 없이 바로 뜹니다.

실제 게임(INT 3.3.0)에서 로컬 서명 피드로 2.9.0 → 3.0.0 자동 설치, 설치 알림 재표시, 버튼 클릭 후 종료·재실행을 확인했습니다.

## 폰트

플러그인 DLL 옆의 `astralkorean_fonts.bundle`을 읽습니다. 게임의 폰트 번들을 변경하거나 게임 원본 파일에 쓰지 않습니다.

- 레거시 `SystemConfig.GetFontAsset`: `Afacad-Regular`, `Impact`, `SIMHEI`, `VonwaonBitmap`을 번들의 동적 폰트로 교체
- TMP: `Afacad-Regular_TMP`, `Impact_TMP`, `dgo_TMP`의 기존 에셋을 번들의 아틀라스·글리프 데이터로 갱신
- `SHOWG`, `SHOWG_TMP`, `hp02_TMP`는 원본 유지

TMP 에셋 객체를 유지하므로 이미 그 객체를 참조하는 UI에도 적용됩니다. 번들은 Unity 기본 타입만 포함하며 게임 스크립트나 Addressables 번들에 의존하지 않습니다.

번들에는 동적 `Font`(`assets/astralkorean/onemobilepop.ttf`), Alpha8 SDF `Texture2D`(`assets/astralkorean/tmp-atlas.asset`), TMP 메트릭·글리프·문자 테이블을 담은 JSON `TextAsset`(`assets/astralkorean/tmp-data.json`)이 있습니다. TMP 에셋 자체는 넣지 않고 기존 객체를 다시 채웁니다. 재생성 방법과 입력은 [개발 문서](development.md#폰트-번들-수동-재생성)에 있습니다.

## 오버레이와 HybridCLR 제약

상태 오버레이는 uGUI Canvas가 아니라 게임의 `FairyGUI.GRoot`에 붙이는 최상위 `GComponent`입니다. `AstralParty.Runtime`의 HybridCLR 타입에는 interop 래퍼가 없으므로 `FairyGui`가 IL2CPP 메타데이터에서 **정확한 매개변수 타입**으로 메서드를 찾아 호출합니다. `FguiNode`는 플러그인이 만든 객체의 GC 핸들과 `Dispose`를 관리하며, 게임 소유의 GRoot는 현재 프레임에서만 빌려 씁니다.

메인 스레드의 `EventSystem.Update` Harmony prefix에서 프레임마다 한 번 처리하며, GRoot를 처음 얻은 프레임에 패널을 만듭니다. GRoot 기준 520×400 크기(재시작 버튼이 있으면 높이만 460), 오른쪽·아래 32 여백, `sortingOrder=890000`을 사용하여 채팅 플러그인 창(`900000`)보다 아래에 표시합니다. 게임이 패널을 제거하거나 파괴하면 다시 만듭니다. 어두운 둥근 패널, 분홍색 테두리·닫기 버튼, 한글 제목을 유지하며 번들의 `FontAssets.KoreanFont`를 전용 FairyGUI 폰트 별칭으로 등록합니다. 번들 또는 폰트 등록이 실패하면 게임 기본 폰트를 사용합니다.

게임은 로그인 화면에서 게임을 시작할 때 `UIManager.AsyncLoadFonts`에서 `FontManager.Clear()`를 호출하여 등록된 FairyGUI 폰트를 모두 `Dispose`합니다. 해제된 `DynamicFont`는 `Font.textureRebuilt`를 더 이상 받지 않아, 이후 글리프 아틀라스가 재생성되면 그 폰트를 쓰는 텍스트가 깨집니다. 그래서 오버레이는 매 틱 `FontManager.sFontFactory`의 `_version`을 등록 시점 값과 비교하고, 바뀌면 폰트를 다시 등록하고 패널을 새로 만듭니다.

정보는 `게임`(버전·리비전), `번역 팩`(버전·리비전·번호), `플러그인`(설치·최신), `상태`의 행으로 구분합니다. 각 값 위의 작은 캡션과 값 열을 맞추며 상태는 중요도별 색으로 표시하고 길면 줄바꿈합니다. 세션 번역 팩이 고정되면 그 팩의 메타데이터를 표시하고, 새로 받은 팩은 기존 상태 메시지로 다음 실행부터 적용됨을 알립니다. 스냅샷이 바뀔 때만 텍스트를 갱신합니다.

게임 정보는 첫 UI 프레임부터 약 120프레임마다 `App.WebServerConfig._hotUpdateConfigData`를 읽고, JSON을 해석했거나 실제 시간 약 60초가 지나면 중단합니다. 버전은 JSON의 `version`을 우선하고 없으면 `Application.version`을 유지합니다. 리비전은 `sourceUrl`의 `{route}/{version}/{revision}`에서 숫자 문자열 그대로 가져와 `026` 같은 앞자리 0을 보존합니다. 빌더와 같이 CDN 접두 경로·끝의 한 경로 및 짧은 숫자 URL을 허용하되, JSON과 URL 버전이 다르면 리비전은 `-`입니다. 확인 전에는 `확인 중`, 파싱 불가·시간 초과에는 `-`를 표시합니다.

패널과 닫기·재시작 버튼은 FairyGUI의 opaque 히트 테스트로 뒤쪽 게임 UI 클릭을 차단합니다. 표시 중에만 Esc를 읽고, 마우스 버튼을 놓은 프레임에는 GRoot의 `touchTarget` 부모를 따라 어느 버튼인지 확인합니다. X나 Esc로 닫으면 소유 UI와 폰트 등록(폰트의 `NTexture` 머티리얼 포함)을 해제하며, 플러그인 설치 완료 알림 한 번을 제외하면 이번 세션에는 다시 열지 않습니다. 닫거나 폰트 재등록으로 다시 만들 때는 패널을 먼저 숨기고 다음 프레임에 해제합니다. FairyGUI는 프레임마다 히트 대상을 캐시하고 게임 코드가 그 프레임에 `GRoot.touchTarget`을 읽기 때문입니다. 번역·폰트 패치는 계속 작동합니다. UI 실패는 한 번 기록하고 오버레이만 중단하여 게임 프레임과 번역을 방해하지 않습니다.

HybridCLR 환경에서는 Il2CppInterop 클래스 주입, 플러그인 MonoBehaviour의 `AddComponent`, 관리 UnityEvent/FairyGUI EventCallback 델리게이트를 사용하지 않습니다. 텍스트·폰트·UI 처리 모두 원래 게임 로드 경로를 유지하며 게임 원본을 수정하지 않습니다.
