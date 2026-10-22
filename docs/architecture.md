# 코드 구조와 실행 흐름

게임 원본 파일을 바꾸지 않고, 읽는 텍스트와 사용하는 폰트를 런타임에서 교체합니다. 게임 버전별 교체 번들이나 파일 접근 후킹은 사용하지 않습니다.

## 구성

- `src/Plugin/`: BepInEx 6 IL2CPP 플러그인, Harmony 후킹, 번역 팩 클라이언트, 폰트 적용, 상태 오버레이
- `assets/fonts/astralkorean_fonts.bundle`: 배포하는 폰트 번들의 원본
- `tools/FontBundleBuilder/`: 폰트 번들을 수동 재생성하는 도구. 일반 빌드·CI에서는 실행하지 않음
- `Directory.Build.props`, `Directory.Build.targets`: 참조 경로 선택, `VERSION` 검증, `AstralBuildVersion.Value` 생성
- `scripts/`: 참조 준비, 플러그인 빌드, 두 파일 패키징과 릴리즈 처리

## 시작과 번역 팩

1. 실행 파일·데이터 폴더로 글로벌판(INT) 또는 중국판(CN)을 판별합니다.
2. 구형 설치를 정리합니다. 새 설치 위치는 `BepInEx/plugins/AstralPartyKoreanPlugin/`입니다. 업그레이드 시 이전 플러그인 폴더는 재귀 삭제하고 로드 중인 DLL은 가능하면 `.removed`로 바꿔 다음 실행에서 지웁니다. 실행 중인 DLL이 구형 폴더 안에 있으면(디렉터리 링크로 접근한 경우 포함) 그 폴더는 보존하고 알려진 구형 캐시만 정리합니다. 실패 시 로그와 상태창을 확인하고 [업데이트 안내](../README.md#2x에서-업데이트하는-경우)에 따라 게임 종료 후 직접 삭제하세요.
3. `https://file.maynutlab.com/translation-pack/latest.json`에서 최신 번역 팩 포인터를 확인합니다. `schemaVersion: 1`, `locale: ko`를 사용합니다.
4. 캐시보다 큰 `number`만 새 팩으로 취급합니다. `version`·`revision`·`publishedAt`은 표시·기록용이며 게임 버전과 비교하지 않습니다. 작은 번호로 되돌아가지 않습니다.
5. 포인터의 `path`에 있는 gzip 팩을 검증하고 캐시에 저장합니다. 캐시는 설치 폴더명이 아니라 실행 중인 DLL의 디렉터리에서 구한 `translation-pack/`입니다. `latest.json`과 `{number}.json.gz`를 저장하고 이전 팩을 정리합니다. 팩 파일을 먼저 쓰고 포인터를 마지막에 교체하여 중단된 갱신이 기존 캐시를 깨뜨리지 않게 합니다.
6. 준비한 팩을 이번 세션 동안 고정합니다. 실행 중 팩이 배포되어도 이미 읽은 에셋과 다른 세대의 번역을 섞지 않으며 다음 게임 실행에서 갱신합니다.

네트워크 확인·다운로드에 실패하면 검증된 캐시를 사용합니다. 유효한 팩이 없으면 원문을 표시합니다. 플러그인 자체 업데이트는 `https://api.github.com/repos/maynut02/astral-party-korean-plugin/releases/latest`에서 별도로 확인합니다.

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

## 폰트

플러그인 DLL 옆의 `astralkorean_fonts.bundle`을 읽습니다. 게임의 폰트 번들을 변경하거나 게임 원본 파일에 쓰지 않습니다.

- 레거시 `SystemConfig.GetFontAsset`: `Afacad-Regular`, `Impact`, `SIMHEI`, `VonwaonBitmap`을 번들의 동적 폰트로 교체
- TMP: `Afacad-Regular_TMP`, `Impact_TMP`, `dgo_TMP`의 기존 에셋을 번들의 아틀라스·글리프 데이터로 갱신
- `SHOWG`, `SHOWG_TMP`, `hp02_TMP`는 원본 유지

TMP 에셋 객체를 유지하므로 이미 그 객체를 참조하는 UI에도 적용됩니다. 번들은 Unity 기본 타입만 포함하며 게임 스크립트나 Addressables 번들에 의존하지 않습니다.

번들에는 동적 `Font`(`assets/astralkorean/onemobilepop.ttf`), Alpha8 SDF `Texture2D`(`assets/astralkorean/tmp-atlas.asset`), TMP 메트릭·글리프·문자 테이블을 담은 JSON `TextAsset`(`assets/astralkorean/tmp-data.json`)이 있습니다. TMP 에셋 자체는 넣지 않고 기존 객체를 다시 채웁니다. 재생성 방법과 입력은 [개발 문서](development.md#폰트-번들-수동-재생성)에 있습니다.

## 오버레이와 HybridCLR 제약

상태 오버레이는 uGUI Canvas가 아니라 게임의 `FairyGUI.GRoot`에 붙이는 최상위 `GComponent`입니다. `AstralParty.Runtime`의 HybridCLR 타입에는 interop 래퍼가 없으므로 `FairyGui`가 IL2CPP 메타데이터에서 **정확한 매개변수 타입**으로 메서드를 찾아 호출합니다. `FguiNode`는 플러그인이 만든 객체의 GC 핸들과 `Dispose`를 관리하며, 게임 소유의 GRoot는 현재 프레임에서만 빌려 씁니다.

메인 스레드의 `EventSystem.Update` Harmony prefix에서 프레임마다 한 번 처리하며, GRoot를 처음 얻은 프레임에 패널을 만듭니다. GRoot 기준 520×400 크기, 오른쪽·아래 32 여백, `sortingOrder=890000`을 사용하여 채팅 플러그인 창(`900000`)보다 아래에 표시합니다. 게임이 패널을 제거하거나 파괴하면 다시 만듭니다. 어두운 둥근 패널, 분홍색 테두리·닫기 버튼, 한글 제목을 유지하며 번들의 `FontAssets.KoreanFont`를 전용 FairyGUI 폰트 별칭으로 등록합니다. 번들 또는 폰트 등록이 실패하면 게임 기본 폰트를 사용합니다.

게임은 로그인 화면에서 게임을 시작할 때 `UIManager.AsyncLoadFonts`에서 `FontManager.Clear()`를 호출하여 등록된 FairyGUI 폰트를 모두 `Dispose`합니다. 해제된 `DynamicFont`는 `Font.textureRebuilt`를 더 이상 받지 않아, 이후 글리프 아틀라스가 재생성되면 그 폰트를 쓰는 텍스트가 깨집니다. 그래서 오버레이는 매 틱 `FontManager.sFontFactory`의 `_version`을 등록 시점 값과 비교하고, 바뀌면 폰트를 다시 등록하고 패널을 새로 만듭니다.

정보는 `게임`(버전·리비전), `번역 팩`(버전·리비전·번호), `플러그인`(설치·최신), `상태`의 행으로 구분합니다. 각 값 위의 작은 캡션과 값 열을 맞추며 상태는 중요도별 색으로 표시하고 길면 줄바꿈합니다. 세션 번역 팩이 고정되면 그 팩의 메타데이터를 표시하고, 새로 받은 팩은 기존 상태 메시지로 다음 실행부터 적용됨을 알립니다. 스냅샷이 바뀔 때만 텍스트를 갱신합니다.

게임 정보는 첫 UI 프레임부터 약 120프레임마다 `App.WebServerConfig._hotUpdateConfigData`를 읽고, JSON을 해석했거나 실제 시간 약 60초가 지나면 중단합니다. 버전은 JSON의 `version`을 우선하고 없으면 `Application.version`을 유지합니다. 리비전은 `sourceUrl`의 `{route}/{version}/{revision}`에서 숫자 문자열 그대로 가져와 `026` 같은 앞자리 0을 보존합니다. 빌더와 같이 CDN 접두 경로·끝의 한 경로 및 짧은 숫자 URL을 허용하되, JSON과 URL 버전이 다르면 리비전은 `-`입니다. 확인 전에는 `확인 중`, 파싱 불가·시간 초과에는 `-`를 표시합니다.

패널과 닫기 버튼은 FairyGUI의 opaque 히트 테스트로 뒤쪽 게임 UI 클릭을 차단합니다. 표시 중에만 Esc를 읽고, 마우스 버튼을 놓은 프레임에는 GRoot의 `touchTarget` 부모를 따라 닫기 버튼인지 확인합니다. X나 Esc로 닫으면 소유 UI와 폰트 등록(폰트의 `NTexture` 머티리얼 포함)을 해제하며, 이번 세션에는 다시 열지 않습니다. 닫거나 폰트 재등록으로 다시 만들 때는 패널을 먼저 숨기고 다음 프레임에 해제합니다. FairyGUI는 프레임마다 히트 대상을 캐시하고 게임 코드가 그 프레임에 `GRoot.touchTarget`을 읽기 때문입니다. 번역·폰트 패치는 계속 작동합니다. UI 실패는 한 번 기록하고 오버레이만 중단하여 게임 프레임과 번역을 방해하지 않습니다.

HybridCLR 환경에서는 Il2CppInterop 클래스 주입, 플러그인 MonoBehaviour의 `AddComponent`, 관리 UnityEvent/FairyGUI EventCallback 델리게이트를 사용하지 않습니다. 텍스트·폰트·UI 처리 모두 원래 게임 로드 경로를 유지하며 게임 원본을 수정하지 않습니다.
