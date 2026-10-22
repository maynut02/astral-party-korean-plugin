import base64
import struct

import pytest

from test_plugin import plugin_logic


def varint(value):
    output = bytearray()
    while value >= 128:
        output.append((value & 127) | 128)
        value >>= 7
    output.append(value)
    return bytes(output)


def field(number, payload):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    return varint(number << 3 | 2) + varint(len(payload)) + payload


def entry(identifier, *fields):
    return (b"" if identifier == 0 else b"\x0d" + struct.pack("<I", identifier)) + b"".join(fields)


def patch(plugin_logic, data, translations, target):
    response = plugin_logic({"mode": "str", "data": base64.b64encode(data).decode(),
                             "translations": {str(key): value for key, value in translations.items()}, "field": target})
    return base64.b64decode(response["data"]), response["unchanged"]


@pytest.mark.parametrize("target", [2, 3])
def test_str_replaces_only_route_field_and_preserves_unknown_bytes_and_mirrors(plugin_logic, target):
    unknown = field(19, b"\xff\x00\x10") + varint(20 << 3) + b"\x81\x00"
    unknown += varint(21 << 3 | 1) + b"12345678" + varint(22 << 3 | 5) + b"abcd"
    unknown += varint(23 << 3 | 3) + field(1, b"group") + varint(23 << 3 | 4)
    original_fields = {2: "简体", 3: "English", 4: "日本語", 5: "繁體", 6: "한국어 원본"}
    before = entry(42, *(field(key, value) for key, value in original_fields.items()), unknown)
    after = entry(42, *(field(key, "새 번역" if key == target else value) for key, value in original_fields.items()), unknown)
    untranslated = entry(99, field(2, "원본 CN"), field(3, "original EN"), unknown)
    mirror_unknown = field(7, b"mirror metadata")
    mirror_before = b"\x08\x91\x00" + field(2, before) + field(2, untranslated) + mirror_unknown
    mirror_after = b"\x08\x91\x00" + field(2, after) + field(2, untranslated) + mirror_unknown
    wrapper_unknown = varint(10 << 3) + b"\x81\x00" + field(11, b"unchanged wrapper bytes")
    data = field(1, before) + field(1, untranslated) + field(2, mirror_before) + wrapper_unknown
    expected = field(1, after) + field(1, untranslated) + field(2, mirror_after) + wrapper_unknown
    actual, unchanged = patch(plugin_logic, data, {42: "새 번역"}, target)
    assert actual == expected
    assert unchanged is False


@pytest.mark.parametrize("target", [2, 3])
@pytest.mark.parametrize("identifier", [0, 42])
def test_str_inserts_missing_route_field_before_higher_fields(plugin_logic, target, identifier):
    before = entry(identifier, field(4, "日本語"), field(8, b"\x00\xff"))
    after = entry(identifier, field(target, "삽입"), field(4, "日本語"), field(8, b"\x00\xff"))
    actual, _ = patch(plugin_logic, field(1, before), {identifier: "삽입"}, target)
    assert actual == field(1, after)


@pytest.mark.parametrize("target", [2, 3])
def test_str_appends_missing_route_field_at_end(plugin_logic, target):
    before = entry(42)
    after = before + field(target, "마지막에 추가")
    actual, _ = patch(plugin_logic, field(1, before), {42: "마지막에 추가"}, target)
    assert actual == field(1, after)


def test_str_unlisted_ids_are_returned_byte_exact_without_copy(plugin_logic):
    data = field(1, entry(42, field(2, "原文"), field(3, "original")))
    actual, unchanged = patch(plugin_logic, data, {99: "없는 ID"}, 3)
    assert actual == data
    assert unchanged is True


@pytest.mark.parametrize("newline", ["\n", "\r\n"])
def test_lang_replaces_listed_keys_keeps_unlisted_values_and_whitespace(plugin_logic, newline):
    xml = '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n  <!--keep this comment-->\n  <string name="hello">Original</string>\n\t<string name="untouched">  keep this value  </string>\n  <string name="new">New original</string>\n</resources>\n'.replace("\n", newline)
    result = plugin_logic({"mode": "lang", "text": xml, "translations": {"hello": "번역 & <태그>\n다음 줄", "absent": "추가하면 안 됨"}})
    expected = xml.replace(">Original</string>", ">번역 &amp; &lt;태그&gt;\n다음 줄</string>")
    assert result["text"] == expected


def test_lang_without_matching_keys_is_returned_exactly(plugin_logic):
    xml = "<resources>\n    <string name='unlisted'>Original &amp; unchanged</string>\n</resources>\n"
    assert plugin_logic({"mode": "lang", "text": xml, "translations": {"other": "번역"}})["text"] == xml
