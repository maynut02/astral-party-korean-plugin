import base64
import gzip
import hashlib
import json

import pytest

from test_plugin import plugin_logic


def encode(data):
    return base64.b64encode(data).decode("ascii")


def make_pack(number, text=None, schema=1, pack_number=None):
    pack = {
        "schemaVersion": schema, "locale": "ko",
        "pack": {"number": number if pack_number is None else pack_number, "version": "3.3.0", "revision": "026", "publishedAt": "2026-10-22T03:44:41Z"},
        "lang": {"hello": text or f"번역 {number}"}, "str": {"STRTest": {"0": "번역"}},
    }
    compressed = gzip.compress(json.dumps(pack, ensure_ascii=False).encode("utf-8"), mtime=0)
    pointer = {
        "schemaVersion": 1, "locale": "ko", "number": number,
        "version": "3.3.0", "revision": "026", "publishedAt": "2026-10-22T03:44:41Z",
        "path": f"packs/{number}.json.gz", "size": len(compressed), "sha256": hashlib.sha256(compressed).hexdigest(),
    }
    return pointer, compressed


def cache(directory, pointer, compressed):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "latest.json").write_text(json.dumps(pointer), encoding="utf-8")
    (directory / f'{pointer["number"]}.json.gz').write_bytes(compressed)


def request(directory, pointer, compressed, **kwargs):
    return {"mode": "pack", "directory": str(directory), "pointer": encode(json.dumps(pointer).encode()), "pack": encode(compressed), **kwargs}


def test_newer_pack_replaces_cache(plugin_logic, tmp_path):
    saved, old = make_pack(7)
    cache(tmp_path, saved, old)
    latest, new = make_pack(8)
    result = plugin_logic(request(tmp_path, latest, new))
    assert (result["initial"], result["candidate"], result["active"]) == (7, 8, 8)
    assert result["activeText"] == "번역 8"
    assert json.loads((tmp_path / "latest.json").read_text())["number"] == 8
    assert sorted(path.name for path in tmp_path.iterdir()) == ["8.json.gz", "latest.json"]
    assert (tmp_path / "8.json.gz").read_bytes() == new
    assert result["requests"][0]["noCache"] is True
    assert result["requests"][1]["url"] == "https://file.maynutlab.com/translation-pack/packs/8.json.gz"
    assert result["status"] == "최신 번역 팩 #8 적용 완료"
    assert result["overlay"]["PackVersion"] == "3.3.0"
    assert result["overlay"]["PackRevision"] == "026"
    assert result["overlay"]["PackNumber"] == "#8"


@pytest.mark.parametrize("remote_number", [6, 7])
def test_equal_or_older_pack_keeps_saved_pack(plugin_logic, tmp_path, remote_number):
    saved, old = make_pack(7, "저장된 번역")
    cache(tmp_path, saved, old)
    pointer_before = (tmp_path / "latest.json").read_bytes()
    latest, new = make_pack(remote_number, "교체하면 안 됨")
    result = plugin_logic(request(tmp_path, latest, new))
    assert result["active"] == 7
    assert result["activeText"] == "저장된 번역"
    assert len(result["requests"]) == 1
    assert (tmp_path / "latest.json").read_bytes() == pointer_before
    assert (tmp_path / "7.json.gz").read_bytes() == old
    if remote_number < 7:
        assert any("Ignoring older translation pack" in line for line in result["logs"])


@pytest.mark.parametrize("mismatch", ["sha", "size", "pack-number", "path", "path-number", "locale", "oversize"])
def test_invalid_download_keeps_cache(plugin_logic, tmp_path, mismatch):
    saved, old = make_pack(7)
    cache(tmp_path, saved, old)
    latest, new = make_pack(8, pack_number=9 if mismatch == "pack-number" else None)
    if mismatch == "sha":
        new = new[:-1] + bytes([new[-1] ^ 1])
    elif mismatch == "size":
        latest["size"] += 1
    elif mismatch == "path":
        latest["path"] = "../packs/8.json.gz"
    elif mismatch == "path-number":
        latest["path"] = "packs/9.json.gz"
    elif mismatch == "locale":
        latest["locale"] = "en"
    elif mismatch == "oversize":
        latest["size"] = 32 * 1024 * 1024 + 1
    result = plugin_logic(request(tmp_path, latest, new))
    assert result["active"] == result["candidate"] == 7
    assert result["Offline"] is True
    assert (tmp_path / "7.json.gz").read_bytes() == old
    assert not (tmp_path / "8.json.gz").exists()


@pytest.mark.parametrize("corruption", ["pointer", "gzip", "size", "schema", "locale", "number"])
def test_corrupt_cache_is_ignored(plugin_logic, tmp_path, corruption):
    saved, old = make_pack(7, pack_number=8 if corruption == "number" else None)
    if corruption == "schema":
        saved["schemaVersion"] = 2
    elif corruption == "locale":
        saved["locale"] = "en"
    cache(tmp_path, saved, old)
    if corruption == "pointer":
        (tmp_path / "latest.json").write_text("not json", encoding="utf-8")
    elif corruption == "gzip":
        damaged = old[:-1] + bytes([old[-1] ^ 1])
        (tmp_path / "7.json.gz").write_bytes(damaged)
    elif corruption == "size":
        (tmp_path / "7.json.gz").write_bytes(old[:-1])
    latest, new = make_pack(8)
    result = plugin_logic(request(tmp_path, latest, new, offline=True))
    assert result["initial"] is None
    assert result["active"] is None
    assert result["Frozen"] is True


@pytest.mark.parametrize("where", ["pointer", "pack"])
def test_new_schema_requires_plugin_update_and_retains_cache(plugin_logic, tmp_path, where):
    saved, old = make_pack(7)
    cache(tmp_path, saved, old)
    latest, new = make_pack(8, schema=2 if where == "pack" else 1)
    if where == "pointer":
        latest["schemaVersion"] = 2
    result = plugin_logic(request(tmp_path, latest, new))
    assert result["UpdateRequired"] is True
    assert result["active"] == 7
    assert "플러그인을 업데이트" in result["status"]
    assert json.loads((tmp_path / "latest.json").read_text())["number"] == 7


def test_offline_uses_saved_pack(plugin_logic, tmp_path):
    saved, old = make_pack(7)
    cache(tmp_path, saved, old)
    result = plugin_logic(request(tmp_path, saved, old, offline=True))
    assert result["active"] == 7
    assert result["status"] == "오프라인: 저장된 번역 팩 #7 사용 중"
    assert result["severity"] == "Warning"


def test_no_cache_and_offline_keeps_original_text(plugin_logic, tmp_path):
    latest, new = make_pack(8)
    result = plugin_logic(request(tmp_path, latest, new, offline=True))
    assert result["active"] is None
    assert result["status"] == "번역 팩이 없어 원문을 표시합니다"


@pytest.mark.parametrize("saved_number", [None, 7])
def test_late_pack_is_saved_but_session_stays_frozen(plugin_logic, tmp_path, saved_number):
    if saved_number is not None:
        saved, old = make_pack(saved_number)
        cache(tmp_path, saved, old)
    latest, new = make_pack(8)
    result = plugin_logic(request(tmp_path, latest, new, freezeBefore=True))
    assert result["first"] == result["active"] == saved_number
    assert result["candidate"] == 8
    assert result["status"] == "새 번역 팩 #8은 다음 실행부터 적용됩니다"
    assert json.loads((tmp_path / "latest.json").read_text())["number"] == 8
    assert result["overlay"]["PackVersion"] == ("-" if saved_number is None else "3.3.0")
    assert result["overlay"]["PackRevision"] == ("-" if saved_number is None else "026")
    assert result["overlay"]["PackNumber"] == ("-" if saved_number is None else "#7")


def test_unknown_game_overlay_is_unsupported(plugin_logic, tmp_path):
    latest, new = make_pack(8)
    result = plugin_logic(request(tmp_path, latest, new, unsupported=True))
    assert result["severity"] == "Error"
    assert "지원하지 않는 게임" in result["status"]
