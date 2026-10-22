"""Run Unity-free production plugin logic in a managed .NET harness; no game or network."""

import json
import os
import shutil
import subprocess
import sys
from html import escape
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using AstralParty.KoreanPatch;

internal static class Program
{
    private static string Text(JsonElement root, string name) => root.GetProperty(name).GetString()!;
    // Image sections block deletion but allow renaming, like an assembly loaded by the game.
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32")]
    private static extern bool FreeLibrary(IntPtr module);
    private static bool Flag(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.GetBoolean();
    public static async Task Main(string[] args)
    {
        using var input = JsonDocument.Parse(File.ReadAllBytes(args[0]));
        var request = input.RootElement;
        object result;
        switch (Text(request, "mode"))
        {
            case "route":
                result = GameRoute.Detect(Text(request, "process"), Text(request, "data"));
                break;
            case "game-info":
                var parsed = GameInfo.TryParse(request.GetProperty("json").GetString(), out var info);
                result = new { parsed, info };
                break;
            case "overlay":
                result = OverlayState.Create(Text(request, "gameVersion"), Text(request, "gameRevision"),
                    Text(request, "installed"), Text(request, "latest"), !Flag(request, "unsupported"),
                    request.TryGetProperty("cleanupFailure", out var cleanup) ? cleanup.GetString() : null,
                    new PackState(null, null, Flag(request, "frozen"), Flag(request, "checking"),
                        Flag(request, "offline"), Flag(request, "updateRequired")));
                break;
            case "semver":
                result = new { comparison = SemanticVersion.Parse(Text(request, "left")).CompareTo(SemanticVersion.Parse(Text(request, "right"))) };
                break;
            case "str":
                var translations = new Dictionary<uint, string>();
                foreach (var entry in request.GetProperty("translations").EnumerateObject())
                    translations.Add(uint.Parse(entry.Name), entry.Value.GetString()!);
                var original = Convert.FromBase64String(Text(request, "data"));
                var patched = StrPatcher.Patch(original, translations, request.GetProperty("field").GetInt32());
                result = new { data = Convert.ToBase64String(patched), unchanged = ReferenceEquals(original, patched) };
                break;
            case "lang":
                var lang = new Dictionary<string, string>();
                foreach (var entry in request.GetProperty("translations").EnumerateObject())
                    lang.Add(entry.Name, entry.Value.GetString()!);
                result = new { text = LangPatcher.Patch(Text(request, "text"), lang) };
                break;
            case "cleanup":
            {
                var cleanupLogs = new List<string>();
                var loadedDll = request.TryGetProperty("lockedDll", out var lockedDll)
                    ? LoadLibraryExW(lockedDll.GetString()!, IntPtr.Zero, 0x20) // LOAD_LIBRARY_AS_IMAGE_RESOURCE
                    : IntPtr.Zero;
                if (lockedDll.ValueKind == JsonValueKind.String && loadedDll == IntPtr.Zero)
                    throw new IOException("Could not map test DLL: " + Marshal.GetLastWin32Error());
                var bepinex = Text(request, "bepinex");
                var pluginDirectory = request.TryGetProperty("pluginDirectory", out var directory)
                    ? directory.GetString()!
                    : Path.Combine(bepinex, "plugins", "AstralPartyKoreanPlugin");
                var failed = LegacyCleanup.Run(bepinex, pluginDirectory, cleanupLogs.Add);
                if (loadedDll != IntPtr.Zero) FreeLibrary(loadedDll);
                result = new { failed, logs = cleanupLogs };
                break;
            }
            case "pack":
                var logs = new List<string>();
                var requests = new List<object>();
                var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                if (!Flag(request, "freezeBefore")) gate.SetResult(true);
                async Task<byte[]> Download(Uri uri, int limit, bool noCache)
                {
                    await gate.Task;
                    requests.Add(new { url = uri.AbsoluteUri, limit, noCache });
                    if (Flag(request, "offline")) throw new IOException("test offline");
                    return Convert.FromBase64String(Text(request, uri.AbsoluteUri.EndsWith("latest.json") ? "pointer" : "pack"));
                }
                var client = new PackClient(Text(request, "directory"), Download, logs.Add, deadline: TimeSpan.Zero);
                var initial = client.Snapshot().Candidate?.Number;
                TranslationPack? first = null;
                if (Flag(request, "freezeBefore"))
                {
                    first = client.Freeze();
                    gate.SetResult(true);
                }
                await client.RefreshTask;
                var active = client.Freeze();
                var state = client.Snapshot();
                var overlay = OverlayState.Create("3.3.0", "026", "3.0.0", "v3.0.0", !Flag(request, "unsupported"), null, state);
                result = new { initial, candidate = state.Candidate?.Number, active = active?.Number,
                    state.Checking, state.Offline, state.UpdateRequired, state.Frozen,
                    first = first?.Number, activeText = active != null && active.Lang.TryGetValue("hello", out var text) ? text : null,
                    status = overlay.Status, severity = overlay.Severity.ToString(), overlay, logs, requests };
                break;
            default: throw new InvalidOperationException("Unknown test mode");
        }
        Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions { IncludeFields = true }));
    }
}
'''


@pytest.fixture(scope="module")
def plugin_logic(tmp_path_factory):
    build_root = tmp_path_factory.mktemp("plugin-logic")
    candidates = [ROOT / ".work/dotnet/dotnet.exe", ROOT / ".work/dotnet/dotnet"]
    local_dotnet = next((path for path in candidates if path.is_file()), None)
    dotnet = os.environ.get("ASTRAL_TEST_DOTNET") or (str(local_dotnet) if local_dotnet else shutil.which("dotnet"))
    if not dotnet:
        pytest.skip(".NET 6 SDK is required for plugin behavior tests")
    dotnet = str(Path(dotnet).resolve())
    env = dict(os.environ, DOTNET_ROOT=str(Path(dotnet).parent), DOTNET_MULTILEVEL_LOOKUP="0",
               DOTNET_CLI_HOME=str(build_root / "cli-home"), DOTNET_CLI_TELEMETRY_OPTOUT="1",
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false",
               NUGET_PACKAGES=str(build_root / "nuget-packages"))
    probe = subprocess.run([dotnet, "--list-sdks"], cwd=build_root, env=env, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=20)
    sdks = [line.split()[0] for line in probe.stdout.splitlines() if line.startswith("6.")]
    if probe.returncode or not sdks:
        pytest.skip(".NET 6 SDK is required for plugin behavior tests")
    (build_root / "global.json").write_text(json.dumps({"sdk": {"version": sdks[-1], "rollForward": "disable"}}), encoding="utf-8")
    (build_root / "NuGet.Config").write_text("<configuration><packageSources><clear /></packageSources></configuration>", encoding="utf-8")
    sources = ["TranslationPack.cs", "PackClient.cs", "RuntimeInfo.cs", "UpdateClient.cs", "TranslationPatcher.cs", "LegacyCleanup.cs", "OverlayState.cs"]
    includes = "".join(f'<Compile Include="{escape(str(ROOT / "src/Plugin" / name), quote=True)}" />' for name in sources)
    project = build_root / "PluginLogic.csproj"
    project.write_text(f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable><LangVersion>latest</LangVersion><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup>
  <ItemGroup>{includes}<Compile Include="Program.cs" /></ItemGroup>
</Project>''', encoding="utf-8")
    (build_root / "Program.cs").write_text(HARNESS, encoding="utf-8")
    build = subprocess.run([dotnet, "build", str(project), "--nologo", "-v", "quiet", "-p:UseSharedCompilation=false"],
                           cwd=build_root, env=env, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=60)
    assert build.returncode == 0, build.stdout + build.stderr
    assembly = build_root / "bin/Debug/net6.0/PluginLogic.dll"

    def invoke(request):
        request_path = build_root / "request.json"
        request_path.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        completed = subprocess.run([dotnet, str(assembly), str(request_path)], cwd=build_root, env=env,
                                   capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
        assert completed.returncode == 0, completed.stdout + completed.stderr
        return json.loads(completed.stdout)

    return invoke


@pytest.mark.parametrize("process,data,route,lang,field", [
    ("AstralParty_INT.exe", "/unknown", "INT", "English", 3),
    ("AstralParty_CN", "/unknown", "CN", "Simplified Chinese", 2),
    ("unknown", "/game/AstralParty_INT_Data", "INT", "English", 3),
    ("unknown", "/game/AstralParty_CN_Data/", "CN", "Simplified Chinese", 2),
])
def test_route_detection(plugin_logic, process, data, route, lang, field):
    # Records expose their values as properties; the harness serializes production results directly.
    assert plugin_logic({"mode": "route", "process": process, "data": data}) == {
        "Name": route, "LangAsset": lang, "StrField": field,
    }


def test_unknown_route_is_unsupported(plugin_logic):
    assert plugin_logic({"mode": "route", "process": "OtherGame", "data": "/game/OtherGame_Data"}) is None


@pytest.mark.parametrize("left,right,comparison", [
    ("v3.0.0", "2.99.99", 1), ("3.0.0", "3.0.0+build.2", 0),
    ("3.0.0-rc.2", "3.0.0-rc.10", -1), ("3.0.0-rc.10", "3.0.0", -1),
    ("3.0.0-beta", "3.0.0-alpha.2", 1), ("3.0.1", "3.1.0", -1),
])
def test_plugin_versions_use_semver_precedence(plugin_logic, left, right, comparison):
    value = plugin_logic({"mode": "semver", "left": left, "right": right})["comparison"]
    assert (value > 0) - (value < 0) == comparison


@pytest.mark.parametrize("data,version,revision,route", [
    ({"version": "3.3.0", "sourceUrl": "http://seresjp.feimogames.com/INT_STEAM/3.3.0/026",
      "sdkVersion": "1.0.1", "route": "INT_STEAM"}, "3.3.0", "026", "INT_STEAM"),
    ({"version": "3.3.0", "sourceUrl": "https://example.com/CN_STEAM/3.3.0/0007/",
      "route": "CN_STEAM"}, "3.3.0", "0007", "CN_STEAM"),
    ({"version": "3.3.0", "sourceUrl": "https://example.com/cdn/INT_STEAM/3.3.0/026/resources?x=1#part",
      "route": "INT_STEAM"}, "3.3.0", "026", "INT_STEAM"),
    ({"version": "3.3.0", "sourceUrl": "https://example.com/game/026",
      "route": "INT_STEAM"}, "3.3.0", "026", "INT_STEAM"),
    ({"version": "3.3.0", "route": "INT_STEAM"}, "3.3.0", "-", "INT_STEAM"),
    ({"route": "INT_STEAM", "sourceUrl": "https://example.com/INT_STEAM/3.3.0/026"},
     "", "-", "INT_STEAM"),
])
def test_hot_update_game_info(plugin_logic, data, version, revision, route):
    assert plugin_logic({"mode": "game-info", "json": json.dumps(data)}) == {
        "parsed": True, "info": {"Version": version, "Revision": revision, "Route": route},
    }


@pytest.mark.parametrize("source", [
    None, 26, "", "not-a-url", "file:///INT_STEAM/3.3.0/026",
    "http://", "https://example.com/INT_STEAM/3.3.0/not-numeric",
    "https://example.com/INT_STEAM/3.3.0/０２６",
    "https://example.com/INT_STEAM/3.3.0/%30%32%36",
    "https://example.com/CN_STEAM/3.3.0/026",
    "https://example.com/INT_STEAM/3.2.0/026",
    "https://example.com/INT_STEAM//3.3.0/026",
    "https://example.com/INT_STEAM/3.3.0/../3.3.0/026",
    "https://example.com/INT_STEAM/3.3.0/026/a/b",
])
def test_untrustworthy_game_revision_is_unavailable(plugin_logic, source):
    # As in the builder, a version mismatch does not borrow a revision from a
    # different game version. The JSON version itself remains the display value.
    result = plugin_logic({"mode": "game-info", "json": json.dumps({
        "version": "3.3.0", "route": "INT_STEAM", "sourceUrl": source,
    })})
    assert result == {"parsed": True, "info": {
        "Version": "3.3.0", "Revision": "-", "Route": "INT_STEAM",
    }}


@pytest.mark.parametrize("raw", [None, "", " ", "{", "[]", "null", "1", "{}", '{"version": null}'])
def test_missing_or_invalid_hot_update_data_keeps_polling(plugin_logic, raw):
    assert plugin_logic({"mode": "game-info", "json": raw}) == {"parsed": False, "info": None}


@pytest.mark.parametrize("game_revision", ["확인 중", "-", "026"])
@pytest.mark.parametrize("latest", ["v2.1.1", "확인 중", "확인 실패"])
def test_overlay_formats_separate_game_pack_and_plugin_fields(plugin_logic, game_revision, latest):
    result = plugin_logic({
        "mode": "overlay", "gameVersion": "3.3.0", "gameRevision": game_revision,
        "installed": "2.1.1", "latest": latest, "checking": True,
    })
    assert result == {
        "GameVersion": "3.3.0", "GameRevision": game_revision,
        "PackVersion": "-", "PackRevision": "-", "PackNumber": "-",
        "InstalledVersion": "v2.1.1", "LatestVersion": latest,
        "Status": "번역 팩 확인 중", "Severity": 0,
    }


def test_legacy_cleanup_preserves_running_old_folder_except_known_paths(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    plugin = bepinex / "plugins/AstralPartyKoreanPatch"
    roots = [bepinex / "AstralPartyKoreanPatch", plugin]
    known_files = ["patched-data.unity3d", "data-unity3d-state.json", "preloader-session.json", "addressables-patch.jsonl"]
    for root in roots:
        for directory in ["cache", "payloads", "releases", "game-data", "translation-pack", "user-data"]:
            (root / directory).mkdir(parents=True)
            (root / directory / "keep-or-remove").write_bytes(b"data")
        for filename in known_files + ["AstralPartyKoreanPlugin.dll", "astralkorean_fonts.bundle", "custom.txt"]:
            (root / filename).write_bytes(b"data")
        for filename in known_files:
            (root / (filename + ".tmp-old")).write_bytes(b"temp")
    (plugin / "AstralParty.AddressablesInProcessPatch.dll").write_bytes(b"legacy")
    patchers = bepinex / "patchers"
    patchers.mkdir()
    for name in ["AstralPartyKoreanPlugin.dataUnity3dRedirect.dll", "AstralPartyKoreanPlugin.dataUnity3dRedirect.dll.removed",
                 "AstralParty.DataUnity3dRedirect.dll", "AstralParty.DataUnity3dRedirect.dll.removed", "Other.dll"]:
        (patchers / name).write_bytes(b"data")
    # The DLL may be installed into a shared folder; same-named folders there are not ours.
    shared = bepinex / "plugins/cache"
    shared.mkdir(parents=True)
    (shared / "other-plugin").write_bytes(b"data")
    normalized_alias = str(plugin / ".." / plugin.name) + os.sep
    if os.name == "nt":
        normalized_alias = normalized_alias.upper()
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex), "pluginDirectory": normalized_alias})
    assert result["failed"] is None
    for root in roots:
        assert all(not (root / name).exists() for name in known_files + ["cache", "payloads", "releases", "game-data"])
        assert not list(root.glob("*.tmp-*"))
        assert (root / "translation-pack/keep-or-remove").read_bytes() == b"data"
        assert (root / "user-data/keep-or-remove").read_bytes() == b"data"
        assert (root / "AstralPartyKoreanPlugin.dll").is_file()
        assert (root / "astralkorean_fonts.bundle").is_file()
        assert (root / "custom.txt").is_file()
    assert sorted(path.name for path in patchers.iterdir()) == ["Other.dll"]
    assert not (plugin / "AstralParty.AddressablesInProcessPatch.dll").exists()
    assert (shared / "other-plugin").read_bytes() == b"data"


@pytest.mark.parametrize("running_location", ["new", "shared", "similar-prefix"])
def test_legacy_cleanup_removes_old_plugin_folder_only(plugin_logic, tmp_path, running_location):
    bepinex = tmp_path / "BepInEx"
    old = bepinex / "plugins/AstralPartyKoreanPatch"
    for relative in ["AstralPartyKoreanPlugin.dll", "AstralParty.AddressablesInProcessPatch.dll",
                     "astralkorean_fonts.bundle", "translation-pack/packs/57.json.gz",
                     "translation-pack/latest.json", "nested/Old.DLL", "nested/Old.DLL.removed", "custom.txt"]:
        path = old / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"data")
    current = bepinex / "plugins/AstralPartyKoreanPlugin"
    unrelated = bepinex / "plugins/OtherPlugin"
    similar = bepinex / "plugins/AstralPartyKoreanPatchOther"
    shared = bepinex / "plugins/cache"
    for root in [current, unrelated, similar, shared]:
        root.mkdir(parents=True)
        (root / "keep.dll").write_bytes(b"keep")
    running = {"new": current, "shared": bepinex / "plugins", "similar-prefix": similar}[running_location]
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex), "pluginDirectory": str(running)})
    assert result["failed"] is None
    assert not old.exists()
    for root in [current, unrelated, similar, shared]:
        assert (root / "keep.dll").read_bytes() == b"keep"


def _directory_link(link: Path, target: Path) -> None:
    if os.name == "nt":  # Junctions need no symlink privilege.
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], check=True, capture_output=True)
        return
    try:
        link.symlink_to(target, target_is_directory=True)
    except OSError as error:
        pytest.skip(f"Directory symlinks are unavailable: {error}")


def test_legacy_cleanup_does_not_follow_links_to_sibling_plugin(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    old = bepinex / "plugins/AstralPartyKoreanPatch"
    other = bepinex / "plugins/OtherPlugin"
    old.mkdir(parents=True)
    other.mkdir()
    (other / "keep.dll").write_bytes(b"keep")
    _directory_link(old / "linked-plugin", other)
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex)})
    assert result["failed"] is None
    assert not old.exists()
    assert (other / "keep.dll").read_bytes() == b"keep"


def test_legacy_cleanup_keeps_old_folder_running_through_link_alias(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    old = bepinex / "plugins/AstralPartyKoreanPatch"
    old.mkdir(parents=True)
    (old / "AstralPartyKoreanPlugin.dll").write_bytes(b"current")
    (old / "astralkorean_fonts.bundle").write_bytes(b"fonts")
    alias = bepinex / "plugins/AstralPartyKoreanPlugin"
    _directory_link(alias, old)
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex), "pluginDirectory": str(alias)})
    assert result["failed"] is None
    assert (old / "AstralPartyKoreanPlugin.dll").read_bytes() == b"current"
    assert (old / "astralkorean_fonts.bundle").read_bytes() == b"fonts"


def test_legacy_cleanup_preserves_old_folder_when_running_in_subdirectory(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    old = bepinex / "plugins/AstralPartyKoreanPatch"
    current = old / "manual"
    current.mkdir(parents=True)
    (current / "AstralPartyKoreanPlugin.dll").write_bytes(b"current")
    (old / "translation-pack").mkdir()
    (old / "translation-pack/latest.json").write_bytes(b"cache")
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex), "pluginDirectory": str(current)})
    assert result["failed"] is None
    assert (current / "AstralPartyKoreanPlugin.dll").read_bytes() == b"current"
    assert (old / "translation-pack/latest.json").read_bytes() == b"cache"


@pytest.mark.skipif(os.name != "nt", reason="Windows mapped DLL deletion and rename semantics")
def test_legacy_cleanup_renames_loaded_dll_until_next_launch(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    old = bepinex / "plugins/AstralPartyKoreanPatch"
    dll = old / "nested/AstralPartyKoreanPlugin.dll"
    dll.parent.mkdir(parents=True)
    shutil.copyfile(sys.executable, dll)  # Any valid PE image; loaded as a mapped image below.
    image = dll.read_bytes()
    dll.with_suffix(".dll.removed").write_bytes(b"earlier launch")
    (old / "translation-pack").mkdir()
    (old / "translation-pack/latest.json").write_bytes(b"cache")
    result = plugin_logic({"mode": "cleanup", "bepinex": str(bepinex), "lockedDll": str(dll)})
    assert result["failed"] is None
    assert not dll.exists()
    assert dll.with_suffix(".dll.removed").read_bytes() == image
    assert not (old / "translation-pack").exists()
    assert any("Renamed loaded legacy DLL:" in message for message in result["logs"])
    assert plugin_logic({"mode": "cleanup", "bepinex": str(bepinex)})["failed"] is None
    assert not old.exists()


def test_legacy_cleanup_removes_preloader_log_only(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    bepinex.mkdir()
    (bepinex / "data-redirect.log").write_bytes(b"data")
    (bepinex / "LogOutput.log").write_bytes(b"data")
    assert plugin_logic({"mode": "cleanup", "bepinex": str(bepinex)})["failed"] is None
    assert sorted(path.name for path in bepinex.iterdir()) == ["LogOutput.log"]


def test_legacy_cleanup_removes_data_folder_only_when_emptied(plugin_logic, tmp_path):
    bepinex = tmp_path / "BepInEx"
    data = bepinex / "AstralPartyKoreanPatch"
    (data / "payloads").mkdir(parents=True)
    (data / "addressables-patch.jsonl").write_bytes(b"data")
    assert plugin_logic({"mode": "cleanup", "bepinex": str(bepinex)})["failed"] is None
    assert not data.exists()

    (data / "payloads").mkdir(parents=True)
    (data / "user-notes.txt").write_bytes(b"data")
    assert plugin_logic({"mode": "cleanup", "bepinex": str(bepinex)})["failed"] is None
    assert not (data / "payloads").exists()
    assert (data / "user-notes.txt").read_bytes() == b"data"
