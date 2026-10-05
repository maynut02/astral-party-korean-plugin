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


@pytest.fixture(
    params=sorted((ROOT / "dist/release").glob("v*/windows-plugin-build.json")) or [None],
    ids=lambda path: path.parent.name if path else "not-built",
)
def package(request):
    metadata_path = request.param
    if metadata_path is None:
        pytest.skip("Run scripts/package-release.ps1 to verify the built release")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    return metadata, metadata_path.parent / metadata["package"]["file"]


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
    assert path.parent.name == f"v{metadata['packageVersion']}"
    assert path.name == f"AstralPartyKoreanPlugin-v{metadata['packageVersion']}.zip"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest == metadata["package"]["sha256"]
    assert path.stat().st_size == metadata["package"]["size"]
    assert (path.parent / "SHA256SUMS.txt").read_text(encoding="utf-8").strip() == f"{digest}  {path.name}"


def test_build_cache_contains_only_local_compile_references() -> None:
    refs = ROOT / ".work/refs"
    if not refs.exists():
        pytest.skip("Run scripts/setup.ps1 to verify copied references")
    versions = json.loads((refs / "versions.json").read_text(encoding="utf-8"))["references"]
    copied = {path.relative_to(refs).as_posix() for path in refs.rglob("*.dll")}
    assert copied == {entry["file"] for entry in versions}
    assert all(name.startswith(("core/", "interop/")) for name in copied)
    assert "core/dobby.dll" not in copied
    assert "winhttp.dll" not in copied
    for entry in versions:
        assert hashlib.sha256((refs / entry["file"]).read_bytes()).hexdigest() == entry["sha256"]
        assert entry["assemblyVersion"]
