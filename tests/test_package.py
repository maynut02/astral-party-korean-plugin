from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from zipfile import ZipFile

import pytest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = "BepInEx/plugins/AstralPartyKoreanPlugin/"
EXPECTED = {
    f"{PLUGIN_ROOT}AstralPartyKoreanPlugin.dll": b"MZ local plugin fixture",
    f"{PLUGIN_ROOT}astralkorean_fonts.bundle": b"UnityFS local font fixture",
}
RELEASE = "4.5.6"


@pytest.fixture(scope="module")
def package(tmp_path_factory):
    """Exercise production ZIP/manifest helpers, never pre-existing dist artifacts."""
    work = tmp_path_factory.mktemp("release-package")
    for name, data in EXPECTED.items():
        (work / Path(name).name).write_bytes(data)
    (work / "install.ps1").write_text("# offline installer fixture\n", encoding="utf-8")
    (work / "install.bat").write_bytes(b"@echo off\r\n")
    (work / "LICENSE-BepInEx.txt").write_text("fixture license\n", encoding="utf-8")
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        pytest.fail("PowerShell 7 is required to exercise the production package helpers")
    command = r"""
$ErrorActionPreference = 'Stop'
. $env:ASTRAL_PACKAGE_HELPERS
$root = $env:ASTRAL_PACKAGE_FIXTURE
$files = [ordered]@{
    'BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll' = (Join-Path $root 'AstralPartyKoreanPlugin.dll')
    'BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle' = (Join-Path $root 'astralkorean_fonts.bundle')
}
$runtime = New-AstralZipPackage -Files ([ordered]@{ 'winhttp.dll' = [Text.Encoding]::ASCII.GetBytes('pinned runtime fixture') }) -OutputRoot $root -ZipName 'runtime.zip'
New-AstralZipPackage -Files $files -OutputRoot $root -ZipName 'AstralPartyKoreanPlugin-v4.5.6.zip' | Out-Null
$full = [ordered]@{}
foreach ($file in $files.GetEnumerator()) { $full[$file.Key] = $file.Value }
$full['BepInEx/config/BepInEx.cfg'] = [Text.Encoding]::UTF8.GetBytes("[Logging]`r`nUnityLogListening = false`r`n[Logging.Console]`r`nEnabled = false`r`n")
foreach ($name in @('install.ps1', 'install.bat', 'LICENSE-BepInEx.txt')) { $full[$name] = Join-Path $root $name }
New-AstralZipPackage -Files $full -OutputRoot $root -ZipName 'AstralPartyKoreanPlugin-v4.5.6-full.zip' -BaseArchive $runtime.Path | Out-Null
$key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
try {
    $publicKey = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
    $keyPath = Join-Path $root 'throwaway.pem'
    [IO.File]::WriteAllText($keyPath, [string]::new([Security.Cryptography.PemEncoding]::Write('PRIVATE KEY', $key.ExportPkcs8PrivateKey())))
} finally { $key.Dispose() }
New-AstralUpdateManifest -Version '4.5.6' -Repository 'maynut02/astral-party-korean-plugin' -OutputRoot $root -Files $files -SigningKeyPath $keyPath -PublicKey $publicKey
Assert-AstralReleaseAssets -Tag 'v4.5.6' -Repository 'maynut02/astral-party-korean-plugin' -Root $root -PublicKey $publicKey | Out-Null
Remove-Item -LiteralPath $keyPath
"""
    environment = os.environ.copy()
    environment["ASTRAL_PACKAGE_HELPERS"] = str(ROOT / "scripts/package-files.ps1")
    environment["ASTRAL_PACKAGE_FIXTURE"] = str(work)
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-Command", command],
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return work, json.loads((work / "update.json").read_text(encoding="utf-8"))


def test_plugin_zip_contains_exactly_manifest_files(package) -> None:
    work, manifest = package
    with ZipFile(work / manifest["package"]["name"]) as archive:
        assert set(archive.namelist()) == set(EXPECTED)
        assert len(archive.namelist()) == len(EXPECTED)
        assert archive.testzip() is None
        assert {item["path"] for item in manifest["files"]} == set(EXPECTED)
        for item in manifest["files"]:
            data = archive.read(item["path"])
            assert data == EXPECTED[item["path"]]
            assert item["size"] == len(data)
            assert item["sha256"] == hashlib.sha256(data).hexdigest()


def test_signed_manifest_and_three_checksums_describe_actual_bytes(package) -> None:
    work, manifest = package
    name = f"AstralPartyKoreanPlugin-v{RELEASE}.zip"
    assert manifest["schemaVersion"] == 1
    assert manifest["version"] == RELEASE
    assert manifest["minimumBepInEx"] == "6.0.0-be.788"
    assert manifest["package"]["name"] == name
    assert manifest["package"]["url"] == (
        "https://github.com/maynut02/astral-party-korean-plugin/"
        f"releases/download/v{RELEASE}/{name}"
    )
    data = (work / name).read_bytes()
    assert manifest["package"]["size"] == len(data)
    assert manifest["package"]["sha256"] == hashlib.sha256(data).hexdigest()
    assert not (work / "update.json").read_bytes().startswith(b"\xef\xbb\xbf")
    assert len(base64.b64decode((work / "update.json.sig").read_bytes(), validate=True)) == 64
    names = [name, f"AstralPartyKoreanPlugin-v{RELEASE}-full.zip", "update.json"]
    assert (work / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines() == [
        f"{hashlib.sha256((work / item).read_bytes()).hexdigest()}  {item}"
        for item in names
    ]


def test_full_zip_has_runtime_config_and_offline_scripts(package) -> None:
    work, _ = package
    with ZipFile(work / f"AstralPartyKoreanPlugin-v{RELEASE}-full.zip") as archive:
        assert set(archive.namelist()) == set(EXPECTED) | {
            "winhttp.dll",
            "BepInEx/config/BepInEx.cfg",
            "install.ps1",
            "install.bat",
            "LICENSE-BepInEx.txt",
        }
        assert archive.read("winhttp.dll") == b"pinned runtime fixture"
        assert archive.read("BepInEx/config/BepInEx.cfg") == (
            b"[Logging]\r\nUnityLogListening = false\r\n[Logging.Console]\r\nEnabled = false\r\n"
        )
        for name in ("install.ps1", "install.bat", "LICENSE-BepInEx.txt"):
            assert archive.read(name) == (work / name).read_bytes()
        assert archive.testzip() is None
