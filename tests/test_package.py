from __future__ import annotations

import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    "BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll": "preloader",
    "BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll": "plugin",
}


@pytest.fixture
def package():
    metadata_path = ROOT / "dist/windows-plugin-build.json"
    if not metadata_path.is_file():
        pytest.skip("Run scripts/package-release.ps1 to verify the built release")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    return metadata, ROOT / "dist" / metadata["package"]["file"]


def test_zip_contains_exactly_plugin_files(package) -> None:
    metadata, path = package
    assert metadata["includesBepInExRuntime"] is False
    with ZipFile(path) as archive:
        assert set(archive.namelist()) == set(EXPECTED)
        assert archive.testzip() is None
        for name, component in EXPECTED.items():
            data = archive.read(name)
            assert data
            assert data[:2] == b"MZ"
            assert hashlib.sha256(data).hexdigest() == metadata[component]["sha256"]
            assert metadata[component]["version"] == metadata["packageVersion"]


def test_package_metadata_and_checksum_match_actual_zip(package) -> None:
    metadata, path = package
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest == metadata["package"]["sha256"]
    assert path.stat().st_size == metadata["package"]["size"]
    assert (ROOT / "dist/SHA256SUMS.txt").read_text(encoding="utf-8").strip() == f"{digest}  {path.name}"


def test_build_cache_contains_only_compile_references() -> None:
    deps = ROOT / ".work/deps"
    if not deps.exists():
        pytest.skip("Run scripts/setup.ps1 to verify extracted references")
    assert {path.relative_to(deps).as_posix() for path in deps.rglob("*") if path.is_file()} == {
        "bepinex/BepInEx/core/BepInEx.Core.dll",
        "bepinex/BepInEx/core/BepInEx.Preloader.Core.dll",
        "bepinex/BepInEx/core/BepInEx.Unity.IL2CPP.dll",
        "bepinex/BepInEx/core/0Harmony.dll",
        "bepinex/BepInEx/core/Il2CppInterop.Runtime.dll",
        "unity/UnityEngine.CoreModule.dll",
        "unity/UnityEngine.TextRenderingModule.dll",
        "unity/UnityEngine.AssetBundleModule.dll",
        "unity/UnityEngine.UIModule.dll",
        "unity/UnityEngine.InputLegacyModule.dll",
    }
