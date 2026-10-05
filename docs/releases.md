# 로컬 빌드와 GitHub Release

소스 빌드와 ZIP 생성은 로컬에서 수행합니다. `upload-release.ps1`은 이미 만든 ZIP과 체크섬을 GitHub Release에 등록합니다. GitHub Actions는 게임 설치 없이 소스 구조와 버전·릴리스 스크립트만 검사하며, 실제 DLL 빌드 검증은 로컬에서 수행합니다.

## 최초 설정

PowerShell 7, .NET SDK 6.0.428, Git, GitHub CLI가 필요합니다. GitHub에 만든 이 플러그인 저장소를 `origin`으로 연결하고 로그인합니다. 원격 주소는 실제 사용할 저장소 주소로 지정합니다.

```powershell
git remote add origin <GitHub-저장소-주소>
gh auth login
```

BepInEx 6 Unity IL2CPP Windows x64 계열을 설치한 실제 게임을 한 번 실행해 `BepInEx/core`와 `BepInEx/interop`를 준비합니다. 특정 BepInEx 빌드 번호는 요구하지 않습니다. 기본 게임 경로는 `C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT`이며, 중국판이나 다른 설치 위치는 `-GameRoot`로 지정합니다.

```powershell
./scripts/setup.ps1
# 다른 설치 위치의 참조 준비·갱신
./scripts/setup.ps1 -GameRoot 'D:\SteamLibrary\steamapps\common\Astral Party\8vJXn6CN'
```

`setup.ps1 -GameRoot <게임 경로>`는 게임에서 필요한 참조 DLL만 `.work/refs`로 복사합니다. 게임이나 BepInEx가 바뀌면 같은 명령으로 캐시를 갱신합니다.

소스와 `VERSION`을 커밋한 뒤 `origin`에 push합니다. 빌드에 사용한 커밋과 업로드에 사용하는 HEAD가 같아야 합니다. 업로드 스크립트는 자동으로 소스를 커밋하거나 push하지 않습니다.

## 버전 준비

소스 변경을 커밋한 상태에서 원격 태그를 가져오고 릴리스를 준비합니다.

```powershell
git fetch origin --tags
./scripts/prepare-release.ps1 -Bump patch
```

`-Bump minor`·`-Bump major` 또는 `-Version 2.1.0`도 사용할 수 있습니다. 첫 릴리스는 현재 `VERSION`인 2.0.0을 사용합니다. 이후에는 도달 가능한 `vX.Y.Z` 태그에서 다음 버전을 계산합니다. 옵션을 생략하면 커밋 메시지의 `fix`·`perf`·`revert`는 patch, `feat`는 minor, breaking change는 major로 계산합니다. 이미 준비한 버전은 유지합니다. `-Preview`는 파일을 쓰지 않고 계획만 출력합니다.

`VERSION`이 바뀌었다면 해당 변경을 커밋한 뒤 최종 HEAD를 push합니다. 준비 명령을 다시 실행하면 같은 버전으로 설명 초안을 갱신합니다.

```powershell
git add VERSION
git commit -m "chore: release version"
git push origin main
./scripts/prepare-release.ps1
```

변경이 없다면 `VERSION` 커밋 단계는 생략합니다. 설명 초안은 `.work/releases/vX.Y.Z/release-notes.md`에 저장합니다. 새 버전을 직접 `VERSION`에 작성하여 커밋하고 빌드하는 방식도 사용할 수 있습니다.

## 로컬 빌드와 업로드

미커밋 변경이 없는 상태에서 패키지를 빌드합니다.

```powershell
./scripts/package-release.ps1
./scripts/upload-release.ps1 -Preview
./scripts/upload-release.ps1
```

`build.ps1`과 `package-release.ps1`은 캐시 참조를 자동 사용하며 `-GameRoot` 또는 `-RefsRoot`를 받습니다. `-RefsRoot`에는 `BepInEx/core`와 `BepInEx/interop`를 담은 참조 루트를 지정합니다. 별도 SDK는 `-DotNetPath /path/to/dotnet`으로 지정합니다.

ZIP에는 아래 두 파일만 포함합니다. 최상위는 `BepInEx/`이며 문서·라이선스·BepInEx 런타임·참조 DLL은 넣지 않습니다. 설치 안내와 라이선스는 저장소에서 확인합니다.

```text
BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll
BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll
```

`dist/`에는 ZIP, `SHA256SUMS.txt`, 로컬 교체용 DLL 두 개와 `windows-plugin-build.json`이 생성됩니다. Release에는 ZIP과 `SHA256SUMS.txt` 두 개만 첨부합니다. 태그와 제목은 `VERSION`의 `vX.Y.Z`를 사용합니다.

업로드 전에 ZIP 내용과 체크섬, Git 상태, 원격 저장소, push된 소스 커밋을 확인합니다. 새 Release를 draft로 만들고 첨부를 모두 올린 뒤 공개합니다. 이미 같은 태그의 Release가 있다면 누락된 첨부만 추가하고, 같은 이름의 원격 파일은 SHA-256이 일치할 때만 건너뜁니다. 다른 파일로 덮어쓰지는 않습니다.

## 옵션과 재시도

- `-Preview` — GitHub 호출 없이 로컬 계획 확인
- `-Draft` — 새 Release나 기존 draft를 공개하지 않음
- `-Tag v2.0.0` — `VERSION`과 같은 버전의 태그 지정
- `-AssetRoot ./dist` — ZIP과 체크섬이 있는 폴더 지정
- `-NotesFile ./release-notes.md` — 설명 파일 지정

설명 파일을 생략하면 준비된 초안을 사용하고, 초안도 없으면 GitHub가 변경 설명을 생성합니다. 중간 업로드가 실패하면 같은 HEAD와 로컬 파일을 유지한 채 다시 실행하세요. 같은 파일은 건너뛰고 나머지만 올립니다.
