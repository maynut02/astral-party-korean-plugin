# 로컬 빌드와 릴리즈

여러 커밋을 모아 버전을 한 번 결정하고, 로컬에서 빌드한 ZIP과 체크섬을 `upload-release.ps1`로 GitHub Release에 등록합니다. GitHub Actions는 `Checks`를 수행합니다. 환경 준비와 검사 명령은 [개발 문서](development.md)에 있습니다.

## 버전의 기준

루트의 `VERSION` 파일이 플러그인 배포 버전의 기준입니다. 빌드 스크립트가 공통 버전 상수를 생성하고, 두 DLL의 BepInEx 플러그인 정보와 ZIP 이름에 같은 값을 사용합니다. 빌드와 패키징은 버전을 올리지 않습니다.

플러그인 배포 버전과 게임에서 내려받는 번역 리소스의 버전은 별도로 관리합니다. 이 문서는 [플러그인 Releases](https://github.com/maynut02/astral-party-korean-plugin/releases)의 배포 절차입니다. 번역 리소스는 플러그인이 [리소스 저장소](https://github.com/maynut02/astral-party-korean-patch/releases)에서 확인합니다.

## 커밋에 따른 버전 결정

`prepare-release.ps1`은 HEAD에서 도달할 수 있는 가장 높은 `vX.Y.Z` 태그 이후의 커밋을 분석합니다. 여러 변경 중 가장 큰 증가 종류를 한 번 적용합니다.

| 커밋 | 자동 증가 |
| --- | --- |
| `fix:`·`perf:`·`revert:` | patch |
| `feat:` | minor |
| `feat!:` 같은 타입 뒤 `!`, 또는 본문의 `BREAKING CHANGE:`·`BREAKING-CHANGE:` | `0.x`는 minor, `1.x` 이상은 major |
| `docs:`·`chore:`·`ci:`·`test:`·`refactor:` 등 | 증가 없음 |

예를 들어 마지막 태그가 `v2.0.0`이고 `fix:` 세 개와 `feat:` 한 개가 있으면 `2.1.0`으로 한 번 증가합니다. 이전 릴리즈 태그가 없는 첫 배포는 현재 `VERSION`을 그대로 사용합니다.

`feat(patch): 중국판 리소스 지원` 같은 scope도 지원합니다. 병합 커밋은 제외하고 실제 브랜치 커밋을 분석합니다.

## 1. 버전 준비

소스 변경을 먼저 커밋하고 이전 릴리즈 태그를 가져옵니다. 저장소 루트에서 실행합니다.

```powershell
git fetch origin --tags
.\scripts\prepare-release.ps1 -Preview
.\scripts\prepare-release.ps1
```

`-Preview`는 파일을 바꾸지 않고 버전·태그·소스 커밋·커밋 수를 보여줍니다. 실제 실행은 필요한 경우 `VERSION`을 갱신하고, 공통 `scripts/release-notes.ps1` 생성기로 `.work/releases/vX.Y.Z/release-notes.md`에 커밋 목록과 설치 안내를 준비합니다. 업로더의 자동 생성도 같은 본문 형식을 사용합니다.

이미 준비한 버전으로 다시 실행하면 버전을 추가로 올리지 않습니다. 준비 이후 더 큰 변경이 추가되어 버전이 부족해지면 재계획을 요구합니다. 증가 종류나 버전을 직접 지정하려면 다음 중 필요한 명령을 사용하세요.

```powershell
.\scripts\prepare-release.ps1 -Bump patch
.\scripts\prepare-release.ps1 -Bump minor
.\scripts\prepare-release.ps1 -Bump major
.\scripts\prepare-release.ps1 -Version 2.1.0
```

이전 릴리즈가 있는 상태에서 문서 변경만 새 버전으로 배포하려면 `-Bump patch`처럼 증가 종류를 지정합니다. 준비 명령은 `VERSION` 이외의 미커밋 변경, shallow clone, 이전 태그와 커밋된 `VERSION`의 불일치, 버전 감소와 기존 태그 재사용을 거부합니다.

## 2. 검증과 버전 커밋

[개발 문서의 검사와 게임 확인](development.md#검증)을 수행합니다. `VERSION`이 바뀌었다면 커밋하고 최종 소스 커밋을 `origin`에 push합니다.

```powershell
git add VERSION
git commit -m "chore: 릴리즈 버전 준비"
git push origin main
```

버전 값이 그대로라면 버전만을 위한 커밋은 생략합니다. 업로드에 사용할 최종 HEAD는 먼저 push해야 합니다. 준비 명령을 다시 실행하면 같은 버전으로 최종 커밋까지 설명 초안을 갱신합니다.

```powershell
.\scripts\prepare-release.ps1
git status --short
git rev-parse HEAD
```

미커밋 변경이 없는 상태에서 빌드하고 업로드까지 같은 HEAD를 유지하세요. 소스 커밋이 바뀌면 해당 커밋을 push하고 패키지를 다시 생성합니다.

## 3. 로컬 빌드와 패키징

```powershell
.\scripts\package-release.ps1
```

이 명령 하나로 최신 소스를 빌드하고 릴리즈 파일을 생성합니다. 내부 빌드는 기본 `dist/`에 최신 DLL 두 개와 `build-references.json`을 생성합니다. 패키징은 이 세 파일을 기본 `dist/release/vX.Y.Z/`에 복사한 뒤 같은 버전 폴더에 ZIP·체크섬·빌드 메타데이터를 생성합니다. 빌드가 실패하면 패키징을 중단합니다. `VERSION`이 `2.0.0`인 경우 결과는 다음과 같습니다.

```text
dist/
├─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
├─ AstralPartyKoreanPlugin.dll
├─ build-references.json
└─ release/
   └─ v2.0.0/
      ├─ AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
      ├─ AstralPartyKoreanPlugin.dll
      ├─ build-references.json
      ├─ AstralPartyKoreanPlugin-v2.0.0.zip
      ├─ SHA256SUMS.txt
      └─ windows-plugin-build.json
```

`dist/` 루트의 세 파일은 빌드할 때 최신 결과로 갱신됩니다. 버전 폴더의 여섯 파일은 해당 버전의 릴리즈 산출물이며, 다른 버전을 패키징해도 기존 버전 폴더의 산출물은 유지됩니다. 예를 들어 `2.1.0`을 패키징하면 `dist/release/v2.1.0/`을 사용하고 `dist/release/v2.0.0/`은 그대로 남습니다.

버전은 기본적으로 `VERSION`을 사용하며, `-Version` 옵션으로 직접 지정할 수 있습니다. `-OutputRoot`를 지정하면 그 경로에 릴리즈 파일을 생성하고, 최신 빌드 출력은 `dist/`에 보관합니다. 사용자 지정 릴리즈 폴더에서 업로드하려면 같은 경로를 업로더의 `-AssetRoot`에 지정하세요. 정식 업로드 버전은 `VERSION`과 같아야 합니다.

ZIP의 최상위는 `BepInEx/`이며 아래 DLL 두 개만 포함합니다.

```text
BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll
```

별도 DLL은 로컬 교체용 산출물입니다. `build-references.json`은 빌드 참조의 실제 버전·해시를, `windows-plugin-build.json`은 패키지 버전·크기·해시와 구성 정보를 기록합니다. `SHA256SUMS.txt`에는 ZIP 한 개의 SHA-256을 기록하며, Release에는 ZIP과 체크섬 파일만 첨부합니다.

DLL만 필요할 때는 `build.ps1`을 실행합니다. 두 명령의 게임 경로·참조·SDK·출력 폴더 옵션은 [개발 문서](development.md#dll-빌드)에 있습니다.

## 4. GitHub Release에 업로드

### 최초 한 번: GitHub CLI 로그인

[GitHub CLI](https://cli.github.com/)를 설치하고, 릴리즈를 게시할 저장소에 쓰기 권한이 있는 계정으로 로그인합니다. [공식 로그인 안내](https://cli.github.com/manual/gh_auth_login)

```powershell
gh auth login
```

게시 대상 저장소는 Git의 `origin`에 설정된 GitHub URL에서 읽습니다. 소스와 `VERSION`을 커밋하고 해당 HEAD를 push한 상태에서 실행합니다.

### 계획 확인과 게시

```powershell
.\scripts\upload-release.ps1 -Preview | Format-List
.\scripts\upload-release.ps1
```

`-Preview`는 저장소·태그·소스 커밋·첨부 파일·설명의 로컬 계획과 `NotesContent`에 담긴 전체 본문을 출력합니다. GitHub CLI를 호출하거나 파일을 변경하지 않으므로 원격 Release 상태는 실제 업로드 시 확인합니다.

업로드 명령은 이미 생성한 `dist/release/vX.Y.Z/`의 ZIP과 `SHA256SUMS.txt`를 사용합니다. 기본 `-AssetRoot`와 태그·제목의 버전은 `VERSION`에서 읽으며, `VERSION`이 `2.0.0`이면 `dist/release/v2.0.0/`을 사용합니다. 설명은 다음 우선순위로 선택합니다.

1. 명시한 `-NotesFile`의 내용. 지정한 파일이 없으면 중단합니다.
2. 기존 `.work/releases/vX.Y.Z/release-notes.md`의 내용.
3. 두 파일을 사용하지 않으면 Git 커밋 이력에서 자동 생성한 본문.

업로더가 이력에서 자동 생성할 때는 실행 시작에 고정한 HEAD에서 도달할 수 있는 태그 중 현재 `VERSION` 태그를 제외하고, 현재 버전보다 낮은 가장 높은 `vX.Y.Z`를 기준으로 `이전 태그..고정 HEAD`를 사용합니다. 이전 릴리즈 태그가 없는 첫 배포는 고정 HEAD까지의 전체 이력을 사용합니다. 병합 커밋은 `--no-merges`로 제외합니다. 이 자동 생성 경로는 준비 명령과 마찬가지로 전체 Git 이력을 요구하며 shallow clone에서는 중단합니다. 전체 이력과 릴리즈 태그를 먼저 가져오세요.

공통 생성기의 첫 헤딩은 `## 변경 사항`이며 실제 커밋 제목과 짧은 SHA를 목록으로 담습니다. 이어지는 `## 설치`에는 글로벌판·중국판의 폴더와 실행 파일 위치표, DLL 두 개의 설치 경로와 기존 DLL 업데이트 안내가 포함됩니다. 준비된 설명 파일이 없어도 이 본문을 생성하며, GitHub의 `--generate-notes`로 대체하지 않습니다. 게시 전에 `NotesContent`를 검토하세요.

새 Release는 draft로 생성하고 두 파일의 업로드가 완료되면 공개합니다. draft로 유지하려면 다음과 같이 실행합니다.

```powershell
.\scripts\upload-release.ps1 -Draft
```

| 옵션 | 기본값과 동작 |
| --- | --- |
| `-Tag` | `VERSION`의 `vX.Y.Z`; 지정할 때도 같은 버전이어야 함 |
| `-AssetRoot` | `VERSION`에서 정한 `dist/release/vX.Y.Z/`; 업로드할 ZIP과 체크섬이 있는 폴더 |
| `-NotesFile` | 명시한 파일을 우선 사용; 생략 시 `.work/releases/vX.Y.Z/release-notes.md`, 없으면 Git 이력에서 자동 생성 |
| `-Draft` | 새 Release와 기존 draft를 공개하지 않음 |
| `-Preview` | GitHub CLI 호출·파일 변경 없이 로컬 계획과 전체 `NotesContent` 출력 |

### 기존 Release와 재시도

Release가 이미 있으면 누락된 첨부 파일만 추가하며, 재실행하거나 `-NotesFile`을 지정해도 기존 설명은 자동으로 덮어쓰지 않습니다. 같은 이름의 파일은 원격과 로컬의 SHA-256이 같을 때 건너뛰고, 다르면 중단합니다. 기존 태그가 다른 소스 커밋을 가리킬 때도 중단합니다. 파일을 교체하려면 새 버전을 준비하세요.

중간에 업로드가 실패하면 같은 HEAD와 로컬 파일을 유지한 채 같은 명령을 다시 실행합니다. 이미 올라간 동일 파일은 건너뛰고 나머지를 올린 뒤 draft를 공개합니다. 계속 draft로 유지하려면 재시도에도 `-Draft`를 지정하세요. 이미 공개된 Release의 공개 상태는 유지됩니다.

### 수동 업로드

[새 Release 작성 화면](https://github.com/maynut02/astral-party-korean-plugin/releases/new)에서도 게시할 수 있습니다. 태그와 제목은 `vX.Y.Z`, 태그 대상은 먼저 push한 빌드 소스 커밋으로 지정합니다. 준비한 설명과 ZIP·`SHA256SUMS.txt`를 등록하고 확인한 뒤 공개하세요.

다음 릴리즈를 준비할 때는 `git fetch origin --tags`로 이전 태그를 다시 가져옵니다.
