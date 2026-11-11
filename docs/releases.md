# 한 명령으로 빌드·서명·릴리스

소스 변경을 커밋하고 `origin`에 push한 뒤 한 명령으로 빌드, 두 ZIP 생성, 자동 업데이트 서명, 태그 push와 GitHub Release 공개까지 처리합니다. 버전만 올리는 파일이나 커밋은 만들지 않습니다. GitHub Actions는 검사만 실행합니다.

## 준비

- PowerShell **7.2 이상**, Git, [GitHub CLI](https://cli.github.com/), Python과 `pytest`
- [개발 환경](development.md)에 따라 준비한 .NET SDK, 게임·BepInEx 참조 DLL
- `gh auth login`으로 로그인한 저장소 쓰기 권한 계정
- 아래의 플러그인 업데이트 서명 개인 키
- 전체 Git 기록과 릴리스 태그; shallow clone에서는 릴리스 버전을 계산하지 않습니다.

```powershell
git fetch origin --tags
# 변경을 커밋한 뒤 현재 브랜치의 upstream을 origin으로 설정하고 push
# 예: git push -u origin main
.\scripts\release.ps1 -Preview | Format-List
.\scripts\release.ps1
```

`-Preview`는 버전·태그·이전 태그·소스 SHA·커밋 수·대상 저장소·서명 키 경로·검사 여부·첨부 파일·릴리스 본문·실행 순서를 표시합니다. GitHub나 다운로드 서버에 접속하지 않고 파일, 태그, 커밋을 만들지 않습니다. 따라서 원격 인증·권한·태그 충돌은 실제 실행의 사전 검사에서 확인합니다. Preview도 깨끗한 작업 트리와 `origin` upstream에 포함된 HEAD를 요구합니다.

실제 실행 순서:

1. 깨끗한 작업 트리, 전체 기록, `origin` upstream에 HEAD 포함 여부를 검사하고 버전을 계산합니다.
2. GitHub 인증·저장소 쓰기 권한·push된 소스 SHA·기존 태그·Release를 읽기 전용으로 검사합니다. 이 단계의 실패는 출력 파일 생성·다운로드·태그 생성 전에 중단합니다.
3. 신뢰하는 공개 키와 개인 키가 일치하는지 확인하고 `scripts/check.ps1`을 실행합니다.
4. 정확한 릴리스 버전으로 최신 소스를 빌드하고 두 ZIP, 서명한 `update.json`, `update.json.sig`, 체크섬을 만듭니다.
5. 서명·크기·해시·패키지 경로와 기존 원격 첨부 파일의 digest를 다시 확인합니다. 소스가 바뀌면 중단합니다.
6. HEAD에 annotated tag `vX.Y.Z`를 만들고 `origin`에 push합니다.
7. GitHub Release를 draft로 만들고 다섯 첨부 파일을 업로드한 뒤 공개합니다.

검사를 이미 수행한 경우에만 `-SkipChecks`를 사용하세요. 이 옵션은 빌드, 서명 검증, 작업 트리·원격·digest 안전 검사를 생략하지 않습니다. `-GameRoot`, `-RefsRoot`, `-WorkRoot`, `-OutputRoot`, `-DotNetPath`, `-PythonPath`도 지정할 수 있습니다. 사용자 지정 출력·작업 경로는 Git에서 무시되는 위치를 사용하세요.

## 커밋에 따른 버전 결정

Git의 정식 `vX.Y.Z` 태그가 버전의 유일한 기준입니다. HEAD에서 도달 가능한 태그 중 숫자로 가장 높은 버전 이후의 커밋을 분석해 가장 큰 증가를 한 번 적용합니다. 병합 커밋은 제외하고 squash 커밋과 scope는 지원합니다. prerelease·비정규 태그·다른 브랜치에서만 도달하는 태그는 기준으로 사용하지 않습니다.

| 커밋 | 자동 증가 |
| --- | --- |
| `fix:`·`perf:`·`revert:` | patch |
| `feat:` | minor |
| 타입 뒤 `!`, 본문의 `BREAKING CHANGE:`·`BREAKING-CHANGE:` | `0.x`는 minor, `1.x` 이상은 major |
| `docs:`·`chore:`·`ci:`·`test:`·`refactor:` 등 | 증가 없음 |

`fix:` 세 개와 `feat:` 한 개는 minor를 한 번 증가시킵니다. `v2.1.1` 이후 `feat!:`가 있으면 다음 릴리스는 `v3.0.0`입니다. 태그가 없는 첫 저장소는 `0.0.0`을 계산 기준으로 사용합니다. 배포할 변경이 없으면 자동 릴리스를 거부합니다.

의도적으로 문서만 배포하거나 버전을 직접 고르려면 다음 중 하나를 사용합니다. 두 override는 함께 사용할 수 없습니다.

```powershell
.\scripts\release.ps1 -Bump patch
.\scripts\release.ps1 -Bump minor
.\scripts\release.ps1 -Bump major
.\scripts\release.ps1 -Version 3.0.0
```

`0.x`에서 명시한 `-Bump major`는 `1.0.0`으로 전환합니다. 릴리스 버전은 정식 `X.Y.Z`이며 이전 버전 이하, 기존 태그 재사용, .NET 메타데이터 범위(각 숫자 0~65534) 초과를 거부합니다. 기존 공개 파일을 변경하려면 새 버전을 사용하세요.

로컬 개발 빌드 `scripts/build.ps1`은 `<다음 버전>-dev.<마지막 태그 이후 커밋 수>`를 사용합니다. 릴리스 대상 커밋이 없어도 다음 patch의 dev 버전으로 빌드하며, 태그 바로 위도 `-dev.0`으로 구분합니다. 명시한 `build.ps1 -Version`은 SemVer prerelease·build metadata를 허용합니다. `AstralBuildVersion.Value`와 InformationalVersion은 전체 값, `.Core`와 BepInEx 플러그인 메타데이터는 `X.Y.Z`, AssemblyVersion·FileVersion은 `X.Y.Z.0`입니다.

## 서명 키 보관과 교체

기본 개인 키는 `%USERPROFILE%\.astral-party\plugin-update-signing.pem`입니다. **암호화하지 않은 ECDSA P-256 PKCS#8 PEM**(`BEGIN PRIVATE KEY`)을 사용합니다. 다음 우선순위로 위치를 선택합니다.

1. `-SigningKeyPath 'D:\private\plugin-update-signing.pem'`
2. 환경 변수 `ASTRAL_UPDATE_SIGNING_KEY`
3. 기본 사용자 프로필 경로

개인 키를 저장소, ZIP, 릴리스, 로그, 공유 작업 폴더에 넣지 마세요. 파일 접근 권한을 배포 담당 계정으로 제한하고 암호화한 오프라인 백업을 별도로 보관하세요. `.pem` 등 비밀 파일은 Git에서 무시하지만 이것만 보안 경계로 삼지 마세요. 키를 잃으면 기존 플러그인이 신뢰하는 자동 업데이트를 서명할 수 없습니다.

플러그인에 내장된 신뢰 공개 키(SubjectPublicKeyInfo base64):

```text
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEylLFkAOyq5ioR6NxNYMWG5R6d1tocK4EeRzPIf6r6Ia4U5mn9lKCi9nwkm8g6LoAfulbxhT8954C9+/Lrj4UJA==
```

배포 스크립트는 개인 키의 공개 키가 이 값과 일치하는지 먼저 검사하고, 생성한 서명도 이 공개 키로 다시 검증합니다. 다른 개인 키를 임의 생성해 현재 키 대신 사용하면 릴리스가 실패합니다. 테스트만 임시 키를 생성하며 운영 키를 사용하지 않습니다.

키 회전은 배포·플러그인의 신뢰 키를 함께 바꾸는 보안 변경입니다. 현재 플러그인은 하나의 공개 키를 신뢰하므로 새 키로만 서명한 릴리스는 이전 설치가 자동으로 받지 못합니다. 키 교체 시 검토된 신뢰 전환을 먼저 설계하거나 사용자에게 전체 패키지를 통한 수동 재설치를 안내하세요. 키 유출 시 자동 업데이트 신뢰를 복구할 방법과 수동 설치 경로를 공지해야 합니다.

## 생성 파일과 패키지

기본 릴리스 디렉터리는 `dist/release/vX.Y.Z/`입니다. 게시하지 않고 로컬 패키지만 만들 때도 같은 서명 키가 필요합니다.

```powershell
.\scripts\package-release.ps1 -Version 3.0.0
```

기본 패키징은 버전을 이력에서 계산하고 항상 최신 소스를 빌드합니다. `-Version` 또는 `-Tag`를 지정할 수 있으며 둘 다 지정하면 일치해야 합니다. DLL 이름·제품 버전·필수 소스와 출력 디렉터리를 검사하고, 임시 디렉터리에서 모든 패키지·서명 검증을 완료한 뒤 결과를 복사합니다. 빌드·ZIP·서명 생성 실패는 기존 릴리스 산출물을 교체하지 않습니다. 다른 버전의 폴더는 유지합니다.

GitHub에 게시하는 다섯 파일:

| 파일 | 내용 |
| --- | --- |
| `AstralPartyKoreanPlugin-vX.Y.Z.zip` | DLL과 폰트 번들만 포함한 플러그인 업데이트 ZIP |
| `AstralPartyKoreanPlugin-vX.Y.Z-full.zip` | 고정 BepInEx·설정·플러그인·라이선스·오프라인 설치 스크립트 |
| `update.json` | 플러그인 ZIP과 두 파일의 크기·SHA-256, 버전, 최소 BepInEx 버전 |
| `update.json.sig` | 정확한 JSON 바이트의 ECDSA P-256 / SHA-256 서명; IEEE P1363 64바이트를 ASCII base64로 저장 |
| `SHA256SUMS.txt` | 플러그인 ZIP, 전체 ZIP, `update.json`의 소문자 SHA-256 세 줄 |

플러그인 ZIP에는 아래 두 파일만 있습니다.

```text
BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll
BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle
```

전체 ZIP은 게임 실행 파일이 있는 폴더 구조입니다. 고정 BepInEx ZIP의 모든 항목에 위 두 파일과 아래 항목을 추가합니다. 설치 EXE는 만들지 않습니다.

```text
BepInEx/config/BepInEx.cfg       # [Logging] UnityLogListening = false, [Logging.Console] Enabled = false
LICENSE-BepInEx.txt
install.bat
install.ps1
```

BepInEx는 `6.0.0-be.788+5b766a3` Unity IL2CPP Windows x64로 고정합니다. `.work/bepinex/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788+5b766a3.zip` 캐시를 사용하고 없을 때만 [고정 URL](https://builds.bepinex.dev/projects/bepinex_be/788/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788%2B5b766a3.zip)에서 받습니다. 캐시와 다운로드 모두 **34,336,405바이트**, SHA-256 `f4cc496bd098a0df4164b81e3737297707f13a47c2478dba2f60eefab784817a`를 검사합니다. 손상된 캐시는 자동으로 신뢰하거나 교체하지 않고 중단합니다. 설치 스크립트는 네트워크 없이 패키지 내용만 사용합니다.

`update.json`은 UTF-8 BOM 없이 저장하고 `schemaVersion: 1`, `minimumBepInEx: "6.0.0-be.788"`을 사용합니다. URL은 해당 태그의 플러그인 ZIP을 가리킵니다. 플러그인은 최신 Release의 `/releases/latest/download/update.json`과 `.sig`를 받아 내장 공개 키로 검증한 뒤 ZIP과 각 파일을 검증합니다. 플러그인 버전과 번역 팩의 번호·게시 주기는 별개입니다.

DLL·폰트 번들·`build-references.json`·`windows-plugin-build.json`은 로컬 확인용으로 함께 남지만 업로드하지 않습니다. ZIP의 timestamp를 고정해 같은 입력은 같은 ZIP digest를 만들지만 ECDSA 서명은 다시 생성할 때 달라질 수 있습니다. 이미 업로드를 시작했다면 패키지를 다시 만들지 마세요.

## 실패 후 안전하게 다시 업로드

인증·저장소·태그 오류는 모든 원격 쓰기를 막습니다. 기존 Release의 설명은 바꾸지 않고 누락된 첨부 파일만 추가합니다. 같은 이름의 원격 파일은 digest가 같을 때만 건너뜁니다. digest가 없으면 내려받아 SHA-256을 비교합니다. 다르면 중단하며 공개된 파일을 교체하는 `--clobber`는 사용하지 않습니다. 기존 태그가 다른 커밋을 가리키는 경우도 중단합니다.

태그 push 또는 업로드 도중 실패했다면 **같은 HEAD와 이미 서명한 로컬 파일**을 유지하고 다음 명령으로 재시도하세요. 새 버전을 자동 계산하는 `release.ps1`을 다시 실행해 다음 버전을 만드는 대신 정확한 태그를 지정합니다.

```powershell
.\scripts\upload-release.ps1 -Tag v3.0.0 -CreateTag
# 사용자 지정 패키지 경로를 썼다면 -AssetRoot도 지정
```

`-CreateTag`는 일치하는 annotated local tag를 재사용하고 아직 없을 때만 만듭니다. `-Draft`는 draft를 공개하지 않고 유지합니다. `-Preview`는 이미 생성된 로컬 파일을 검증하고 업로드 계획·본문만 표시합니다. 본문은 `-NotesFile`, `.work/releases/<태그>/release-notes.md`, Git 이력 순으로 선택합니다. 생성 본문에는 이전 릴리스 이후 커밋 제목·7자리 SHA와 설치·업데이트 안내가 포함됩니다. 업로드할 파일과 본문은 임시 스냅샷으로 고정하며 기존 파일을 덮어쓰지 않습니다.
