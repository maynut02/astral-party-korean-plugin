"""Run Unity-free production plugin logic in a managed .NET harness; no game or network."""

import base64
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import zipfile
from html import escape
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
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
    private static byte[] Bytes(JsonElement root, string name) => Convert.FromBase64String(Text(root, name));
    private static PluginUpdateState UpdateState(JsonElement root) => new(Text(root, "latest"),
        root.TryGetProperty("updateMessage", out var message) ? message.GetString() : null,
        Flag(root, "updateWarning") ? StatusSeverity.Warning : StatusSeverity.Success, Flag(root, "restartRequired"));
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
                    Text(request, "installed"), UpdateState(request), !Flag(request, "unsupported"),
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
                var overlay = OverlayState.Create("3.3.0", "026", "3.0.0",
                    new PluginUpdateState("v3.0.0", null, StatusSeverity.Success, false), !Flag(request, "unsupported"), null, state);
                result = new { initial, candidate = state.Candidate?.Number, active = active?.Number,
                    state.Checking, state.Offline, state.UpdateRequired, state.Frozen,
                    first = first?.Number, activeText = active != null && active.Lang.TryGetValue("hello", out var text) ? text : null,
                    status = overlay.Status, severity = overlay.Severity.ToString(), overlay, logs, requests };
                break;
            case "plugin-update":
            {
                using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                var publicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
                var manifest = Bytes(request, "manifest");
                var signature = key.SignData(manifest, HashAlgorithmName.SHA256,
                    Flag(request, "derSignature") ? DSASignatureFormat.Rfc3279DerSequence : DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
                if (Flag(request, "invalidSignature")) signature[0] ^= 1;
                if (Flag(request, "untrustedKey"))
                {
                    using var wrongKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                    publicKey = Convert.ToBase64String(wrongKey.ExportSubjectPublicKeyInfo());
                }
                var updateLogs = new List<string>();
                var updateRequests = new List<object>();
                var pluginDirectory = Text(request, "directory");
                var lockedImage = request.TryGetProperty("lockedDll", out var imagePath)
                    ? LoadLibraryExW(imagePath.GetString()!, IntPtr.Zero, 0x20) : IntPtr.Zero;
                if (imagePath.ValueKind == JsonValueKind.String && lockedImage == IntPtr.Zero)
                    throw new IOException("Could not map test DLL: " + Marshal.GetLastWin32Error());
                FileStream? lockedBundle = Flag(request, "lockBundle")
                    ? new FileStream(Path.Combine(pluginDirectory, UpdateManifest.BundleName), FileMode.Open, FileAccess.Read, FileShare.Read) : null;
                FileStream? lockedDestination = Flag(request, "lockDll")
                    ? new FileStream(Path.Combine(pluginDirectory, UpdateManifest.DllName), FileMode.Open, FileAccess.Read, FileShare.Read) : null;
                try
                {
                    Task<byte[]> DownloadUpdate(Uri uri, int limit, bool noCache)
                    {
                        updateRequests.Add(new { url = uri.AbsoluteUri, limit, noCache });
                        if (Flag(request, "offline")) throw new IOException("test offline");
                        var response = uri == PluginUpdateClient.ManifestUrl
                            ? (request.TryGetProperty("servedManifest", out _) ? Bytes(request, "servedManifest") : manifest)
                            : uri == PluginUpdateClient.SignatureUrl
                                ? Encoding.ASCII.GetBytes(Convert.ToBase64String(signature))
                                : Bytes(request, "package");
                        // The production transport enforces this too; this fake deliberately lets the
                        // validation layer receive malicious over-limit and wrong-size responses.
                        return Task.FromResult(response);
                    }
                    var updater = new PluginUpdateClient(Text(request, "installed"), Text(request, "bepinexVersion"),
                        !Flag(request, "autoOff"), pluginDirectory, DownloadUpdate, updateLogs.Add,
                        publicKey: publicKey);
                    await updater.RefreshTask;
                    var updated = updater.Snapshot();
                    var staged = File.Exists(Path.Combine(pluginDirectory, UpdateManifest.BundleName) + ".new");
                    lockedBundle?.Dispose();
                    lockedBundle = null;
                    lockedDestination?.Dispose();
                    lockedDestination = null;
                    if (lockedImage != IntPtr.Zero) { FreeLibrary(lockedImage); lockedImage = IntPtr.Zero; }
                    if (Flag(request, "tamperStaged") && staged)
                        File.WriteAllBytes(Path.Combine(pluginDirectory, UpdateManifest.BundleName) + ".new", Encoding.UTF8.GetBytes("tampered"));
                    var startupFailure = Flag(request, "nextStartup")
                        ? new UpdateInstaller(pluginDirectory, updateLogs.Add, publicKey)
                            .PrepareStartup(request.TryGetProperty("startupInstalled", out var startupInstalled)
                                ? startupInstalled.GetString()! : "3.1.0") : null;
                    result = new { state = updated, staged, startupFailure, logs = updateLogs, requests = updateRequests };
                }
                finally
                {
                    lockedBundle?.Dispose();
                    lockedDestination?.Dispose();
                    if (lockedImage != IntPtr.Zero) FreeLibrary(lockedImage);
                }
                break;
            }
            case "update-startup":
                var startupLogs = new List<string>();
                var startupResult = new UpdateInstaller(Text(request, "directory"), startupLogs.Add)
                    .PrepareStartup(Flag(request, "devBuild") ? "3.1.0-dev.1" : "3.1.0");
                result = new { failure = startupResult, logs = startupLogs };
                break;
            case "restart-command":
                // Simulate the variables Doorstop leaves in the injected game process.
                Environment.SetEnvironmentVariable("DOORSTOP_DISABLE", "TRUE");
                Environment.SetEnvironmentVariable("DOORSTOP_INITIALIZED", "TRUE");
                Environment.SetEnvironmentVariable("SteamAppId", "2622000");
                var restart = GameRestart.CreateStartInfo(Text(request, "executable"), request.GetProperty("pid").GetInt32());
                var doorstop = new List<string>();
                foreach (var key in restart.Environment.Keys)
                    if (key.StartsWith("DOORSTOP_", StringComparison.OrdinalIgnoreCase)) doorstop.Add(key);
                result = new { restart.FileName, restart.Arguments, restart.UseShellExecute, restart.CreateNoWindow,
                    restart.WorkingDirectory, executable = restart.Environment["ASTRAL_RESTART_EXECUTABLE"],
                    directory = restart.Environment["ASTRAL_RESTART_DIRECTORY"], doorstop,
                    steamAppId = restart.Environment["SteamAppId"] };
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
    sources = ["TranslationPack.cs", "PackClient.cs", "RuntimeInfo.cs", "UpdateClient.cs", "UpdateManifest.cs",
               "UpdateInstaller.cs", "GameRestart.cs", "TranslationPatcher.cs", "LegacyCleanup.cs", "OverlayState.cs"]
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
        "Status": "번역 팩 확인 중", "Severity": 0, "RestartRequired": False,
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


UPDATE_PREFIX = "BepInEx/plugins/AstralPartyKoreanPlugin/"
UPDATE_DLL = "AstralPartyKoreanPlugin.dll"
UPDATE_BUNDLE = "astralkorean_fonts.bundle"
UPDATED_FILES = {UPDATE_DLL: b"verified new plugin DLL", UPDATE_BUNDLE: b"verified new font bundle"}


def _base64(data):
    return base64.b64encode(data).decode("ascii")


def _update_request(tmp_path, *, version="3.1.0", manifest_change=None, zip_entries=None):
    directory = tmp_path / "custom-location/plugin"
    directory.mkdir(parents=True)
    (directory / UPDATE_DLL).write_bytes(b"installed DLL")
    (directory / UPDATE_BUNDLE).write_bytes(b"installed bundle")
    archive = io.BytesIO()
    entries = zip_entries if zip_entries is not None else [(UPDATE_PREFIX + name, data) for name, data in UPDATED_FILES.items()]
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        for name, data in entries:
            output.writestr(name, data)
    package = archive.getvalue()
    name = f"update-v{version}.zip"
    manifest = {
        "schemaVersion": 1, "version": version,
        "package": {
            "name": name,
            "url": f"https://github.com/maynut02/astral-party-korean-plugin/releases/download/v{version}/{name}",
            "size": len(package), "sha256": hashlib.sha256(package).hexdigest(),
        },
        "files": [{"path": UPDATE_PREFIX + name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data in UPDATED_FILES.items()],
        "minimumBepInEx": "6.0.0-be.788",
    }
    if manifest_change:
        manifest_change(manifest)
    request = {
        "mode": "plugin-update", "directory": str(directory), "installed": "3.0.0",
        "bepinexVersion": "6.0.0-be.788+5b766a3", "manifest": _base64(json.dumps(manifest).encode()),
        "package": _base64(package),
    }
    return request, directory


def test_signed_plugin_update_installs_only_verified_files_beside_running_dll(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    (directory / "translation-pack").mkdir()
    (directory / "translation-pack/keep.json").write_bytes(b"cache")
    result = plugin_logic(request)
    assert result["state"] == {
        "Latest": "v3.1.0", "Message": "플러그인 v3.1.0 설치 완료 · 다시 시작하면 적용됩니다",
        "Severity": 1, "RestartRequired": True,
    }
    for name, data in UPDATED_FILES.items():
        assert (directory / name).read_bytes() == data
        assert (directory / (name + ".old")).is_file()
        assert not (directory / (name + ".new")).exists()
    assert (directory / "translation-pack/keep.json").read_bytes() == b"cache"
    assert len(result["requests"]) == 3
    assert result["requests"][0] == {
        "url": "https://github.com/maynut02/astral-party-korean-plugin/releases/latest/download/update.json",
        "limit": 64 * 1024, "noCache": True,
    }
    assert result["requests"][1]["url"].endswith("/update.json.sig")
    assert result["requests"][1]["limit"] == 256
    assert result["requests"][2]["limit"] == len(base64.b64decode(request["package"]))
    assert result["requests"][2]["noCache"] is False


@pytest.mark.parametrize("kind", ["invalid", "wrong-key", "tampered", "tampered-invalid-json", "der"])
def test_plugin_update_rejects_untrusted_signature_before_parsing(plugin_logic, tmp_path, kind):
    request, directory = _update_request(tmp_path)
    if kind == "invalid":
        request["invalidSignature"] = True
    elif kind == "der":
        request["derSignature"] = True
    elif kind == "wrong-key":
        request["untrustedKey"] = True
    else:
        raw = base64.b64decode(request["manifest"])
        request["servedManifest"] = _base64(b"{" if kind == "tampered-invalid-json" else raw.replace(b"3.1.0", b"9.1.0"))
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "확인 실패"
    assert result["state"]["RestartRequired"] is False
    assert any("CryptographicException" in message for message in result["logs"])
    assert len(result["requests"]) == 2
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"
    assert not list(directory.glob("*.new"))


@pytest.mark.parametrize("installed,bepinex,auto_off,expected_install", [
    ("3.0.0", "6.0.0-be.788", False, True),
    ("3.0.0", "6.0.0-be.789+build", False, True),
    ("3.0.0", "6.0.0", False, True),
    ("3.1.0", "6.0.0-be.788", False, False),
    ("3.1.0+local", "6.0.0-be.788", False, False),
    ("4.0.0", "6.0.0-be.788", False, False),
    ("3.0.1-dev.2", "6.0.0-be.788", False, False),
    ("3.1.0-rc.1", "6.0.0-be.788", False, False),
    ("9.0.0-dev.99", "6.0.0-be.788", False, False),
    ("3.0.0", "6.0.0-be.787+old", False, False),
    ("3.0.0", "5.4.23", False, False),
    ("3.0.0", "", False, False),
    ("3.0.0", "not-a-version", False, False),
    ("3.0.0", "6.0.0-be.788", True, False),
])
def test_plugin_update_version_loader_and_config_gates(plugin_logic, tmp_path, installed, bepinex, auto_off, expected_install):
    request, directory = _update_request(tmp_path)
    request.update(installed=installed, bepinexVersion=bepinex, autoOff=auto_off)
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "v3.1.0"
    assert result["state"]["RestartRequired"] is expected_install
    assert len(result["requests"]) == (3 if expected_install else 2)
    assert (directory / UPDATE_DLL).read_bytes() == (UPDATED_FILES[UPDATE_DLL] if expected_install else b"installed DLL")


@pytest.mark.parametrize("change", [
    lambda manifest: manifest.update(schemaVersion=2),
    lambda manifest: manifest.pop("minimumBepInEx"),
    lambda manifest: manifest.update(unknown=True),
    lambda manifest: manifest.update(version="3.1.0-rc.1"),
    lambda manifest: manifest["package"].update(name="another.zip"),
    # The installer package owns this name; 3.0.0 used it for the update package.
    lambda manifest: manifest["package"].update(
        name="AstralPartyKoreanPlugin-v3.1.0.zip", url=manifest["package"]["url"].replace("update-v", "AstralPartyKoreanPlugin-v")),
    lambda manifest: manifest["package"].update(url=manifest["package"]["url"].replace("github.com/", "github.com.evil.example/")),
    lambda manifest: manifest["package"].update(url=manifest["package"]["url"].replace("/maynut02/", "/someone-else/")),
    lambda manifest: manifest["package"].update(url=manifest["package"]["url"].replace("https:", "http:")),
    lambda manifest: manifest["package"].update(size=64 * 1024 * 1024 + 1),
    lambda manifest: manifest["package"].update(size=0),
    lambda manifest: manifest["package"].update(sha256="not-a-hash"),
    lambda manifest: manifest["files"].pop(),
    lambda manifest: manifest["files"].append(dict(manifest["files"][0])),
    lambda manifest: manifest["files"][1].update(path=manifest["files"][0]["path"]),
    lambda manifest: manifest["files"][0].update(path="../AstralPartyKoreanPlugin.dll"),
    lambda manifest: manifest["files"][0].update(path=UPDATE_PREFIX + "Unknown.dll"),
    lambda manifest: manifest["files"][0].update(size=64 * 1024 * 1024 + 1),
    lambda manifest: manifest["files"][0].update(size=-1),
])
def test_plugin_update_rejects_invalid_signed_manifest(plugin_logic, tmp_path, change):
    request, directory = _update_request(tmp_path, manifest_change=change)
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "확인 실패"
    assert result["state"]["RestartRequired"] is False
    assert len(result["requests"]) == 2
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"


@pytest.mark.parametrize("part", ["package-size", "package-hash", "file-size", "file-hash", "download-size", "download-hash"])
def test_plugin_update_rejects_size_and_hash_mismatches(plugin_logic, tmp_path, part):
    def change(manifest):
        if part == "package-size":
            manifest["package"]["size"] += 1
        elif part == "package-hash":
            manifest["package"]["sha256"] = "0" * 64
        elif part == "file-size":
            manifest["files"][0]["size"] += 1
        elif part == "file-hash":
            manifest["files"][1]["sha256"] = "0" * 64
    request, directory = _update_request(tmp_path, manifest_change=change)
    package = base64.b64decode(request["package"])
    if part == "download-size":
        request["package"] = _base64(package[:-1])
    elif part == "download-hash":
        request["package"] = _base64(bytes([package[0] ^ 1]) + package[1:])
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "v3.1.0"
    assert result["state"]["RestartRequired"] is False
    assert "업데이트 실패" in result["state"]["Message"]
    assert len(result["requests"]) == 3
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"
    assert not list(directory.glob("*.new"))


@pytest.mark.parametrize("kind", ["extra", "missing", "duplicate", "traversal", "directory"])
def test_plugin_update_rejects_nonexact_zip_entries(plugin_logic, tmp_path, kind):
    entries = [(UPDATE_PREFIX + name, data) for name, data in UPDATED_FILES.items()]
    if kind == "extra":
        entries.append((UPDATE_PREFIX + "extra.txt", b"extra"))
    elif kind == "missing":
        entries.pop()
    elif kind == "duplicate":
        entries[1] = entries[0]
    elif kind == "traversal":
        entries[1] = ("../outside", entries[1][1])
    else:
        entries[1] = (UPDATE_PREFIX, b"")
    request, directory = _update_request(tmp_path, zip_entries=entries)
    result = plugin_logic(request)
    assert result["state"]["RestartRequired"] is False
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"
    assert not (directory.parent / "outside").exists()


@pytest.mark.skipif(os.name != "nt", reason="Windows image mapping and file sharing semantics")
def test_plugin_update_swaps_loaded_image_without_deleting_it(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    dll = directory / UPDATE_DLL
    shutil.copyfile(sys.executable, dll)
    previous_image = dll.read_bytes()
    request["lockedDll"] = str(dll)
    result = plugin_logic(request)
    assert result["state"]["RestartRequired"] is True
    assert dll.read_bytes() == UPDATED_FILES[UPDATE_DLL]
    assert (directory / (UPDATE_DLL + ".old")).read_bytes() == previous_image
    cleanup = plugin_logic({"mode": "update-startup", "directory": str(directory)})
    assert cleanup["failure"] is None
    assert not list(directory.glob("*.old"))


@pytest.mark.skipif(os.name != "nt", reason="Windows file sharing semantics")
def test_plugin_update_keeps_installed_pair_when_dll_swap_is_denied(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    request["lockDll"] = True
    result = plugin_logic(request)
    assert result["state"]["RestartRequired"] is False
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"
    assert (directory / (UPDATE_DLL + ".new")).read_bytes() == UPDATED_FILES[UPDATE_DLL]
    # A newer bundle must never be left beside the old DLL once startup discards the failed staging.
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"
    assert plugin_logic({"mode": "update-startup", "directory": str(directory)})["failure"] is None
    assert sorted(path.name for path in directory.iterdir()) == sorted([UPDATE_DLL, UPDATE_BUNDLE])
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"


@pytest.mark.skipif(os.name != "nt", reason="Windows Unity-like bundle file sharing semantics")
def test_plugin_update_stages_locked_bundle_and_applies_before_next_font_load(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    request.update(lockBundle=True, nextStartup=True)
    result = plugin_logic(request)
    assert result["state"]["RestartRequired"] is True
    assert result["staged"] is True
    assert result["startupFailure"] is None
    for name, data in UPDATED_FILES.items():
        assert (directory / name).read_bytes() == data
    assert not list(directory.glob("*.new"))
    assert not list(directory.glob("*.old"))
    assert not (directory / ".update.json").exists()
    assert any("Font bundle is in use" in message for message in result["logs"])


@pytest.mark.skipif(os.name != "nt", reason="Windows Unity-like bundle file sharing semantics")
def test_staged_update_rechecks_signed_file_hash_before_applying(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    request.update(lockBundle=True, nextStartup=True, tamperStaged=True)
    result = plugin_logic(request)
    assert result["staged"] is True
    assert result["startupFailure"] is not None
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"
    assert not list(directory.glob("*.new"))
    assert not (directory / ".update.json").exists()


def test_plugin_update_cleans_only_own_backups_and_recovers_missing_bundle(plugin_logic, tmp_path):
    directory = tmp_path / "plugin"
    directory.mkdir()
    (directory / UPDATE_DLL).write_bytes(b"current")
    (directory / (UPDATE_DLL + ".old")).write_bytes(b"old")
    (directory / (UPDATE_BUNDLE + ".old")).write_bytes(b"last valid bundle")
    (directory / "other.dll.old").write_bytes(b"unrelated")
    result = plugin_logic({"mode": "update-startup", "directory": str(directory)})
    assert result["failure"] is None
    assert (directory / UPDATE_DLL).read_bytes() == b"current"
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"last valid bundle"
    assert not (directory / (UPDATE_DLL + ".old")).exists()
    assert (directory / "other.dll.old").read_bytes() == b"unrelated"


def test_plugin_update_never_applies_unauthenticated_staged_files(plugin_logic, tmp_path):
    directory = tmp_path / "plugin"
    directory.mkdir()
    (directory / UPDATE_DLL).write_bytes(b"current")
    (directory / (UPDATE_DLL + ".new")).write_bytes(b"unsigned")
    result = plugin_logic({"mode": "update-startup", "directory": str(directory)})
    assert result["failure"] is None
    assert (directory / UPDATE_DLL).read_bytes() == b"current"
    assert not (directory / (UPDATE_DLL + ".new")).exists()


def test_dev_startup_never_applies_staged_release(plugin_logic, tmp_path):
    directory = tmp_path / "plugin"
    directory.mkdir()
    (directory / UPDATE_DLL).write_bytes(b"dev build")
    (directory / (UPDATE_DLL + ".new")).write_bytes(b"pending release")
    result = plugin_logic({"mode": "update-startup", "directory": str(directory), "devBuild": True})
    assert result["failure"] is None
    assert (directory / UPDATE_DLL).read_bytes() == b"dev build"
    assert not (directory / (UPDATE_DLL + ".new")).exists()


@pytest.mark.parametrize("cleanup_failure", [None, "old.dll"])
def test_overlay_update_status_and_restart_do_not_hide_cleanup_errors(plugin_logic, cleanup_failure):
    result = plugin_logic({
        "mode": "overlay", "gameVersion": "3.3.0", "gameRevision": "026", "installed": "3.0.0",
        "latest": "v3.1.0", "updateMessage": "플러그인 v3.1.0 설치 완료 · 다시 시작하면 적용됩니다",
        "restartRequired": True, "cleanupFailure": cleanup_failure,
    })
    assert result["RestartRequired"] is True
    assert result["LatestVersion"] == "v3.1.0"
    assert result["Severity"] == (3 if cleanup_failure else 1)
    assert ("이전 파일 정리 실패" if cleanup_failure else "설치 완료") in result["Status"]


def test_overlay_update_failure_is_concise_warning(plugin_logic):
    result = plugin_logic({
        "mode": "overlay", "gameVersion": "3.3.0", "gameRevision": "026", "installed": "3.0.0",
        "latest": "v3.1.0", "updateMessage": "플러그인 업데이트 실패 · 게임 종료 후 수동 업데이트해 주세요",
        "updateWarning": True,
    })
    assert result["Severity"] == 2
    assert "수동 업데이트" in result["Status"]
    assert result["RestartRequired"] is False


@pytest.mark.skipif(os.name != "nt", reason="Windows restart command")
def test_restart_helper_waits_for_pid_without_powershell(plugin_logic, tmp_path):
    executable = tmp_path / "game & percent% and !/AstralParty_INT.exe"
    executable.parent.mkdir()
    executable.write_bytes(b"not executed by this test")
    result = plugin_logic({"mode": "restart-command", "executable": str(executable), "pid": 12345})
    assert Path(result["FileName"]).name.lower() == "cmd.exe"
    assert result["Arguments"].startswith('/d /v:off /c "')
    assert "PID eq 12345" in result["Arguments"]
    assert "tasklist.exe" in result["Arguments"]
    assert "start" in result["Arguments"]
    assert "powershell" not in result["Arguments"].lower()
    assert str(executable) not in result["Arguments"]
    assert result["executable"] == str(executable)
    assert result["directory"] == str(executable.parent)
    assert result["UseShellExecute"] is False
    assert result["CreateNoWindow"] is True
    # An inherited DOORSTOP_DISABLE makes the relaunched game skip BepInEx.
    assert result["doorstop"] == []
    assert result["steamAppId"] == "2622000"


@pytest.mark.parametrize("kind", ["oversized", "duplicate-root", "duplicate-package", "bom"])
def test_plugin_update_rejects_malformed_signed_manifest_bytes(plugin_logic, tmp_path, kind):
    request, directory = _update_request(tmp_path)
    raw = base64.b64decode(request["manifest"])
    if kind == "oversized":
        raw += b" " * (64 * 1024)
    elif kind == "duplicate-root":
        raw = raw.replace(b'"schemaVersion": 1', b'"schemaVersion": 1, "schemaVersion": 1')
    elif kind == "duplicate-package":
        raw = raw.replace(b'"size":', b'"unknown": 0, "size":', 1)
    else:
        raw = b"\xef\xbb\xbf" + raw
    request["manifest"] = _base64(raw)
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "확인 실패"
    assert result["state"]["RestartRequired"] is False
    assert len(result["requests"]) == 2
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"


@pytest.mark.skipif(os.name != "nt", reason="Windows Unity-like bundle file sharing semantics")
def test_staged_bundle_never_downgrades_a_manually_newer_plugin(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    request.update(lockBundle=True, nextStartup=True, startupInstalled="4.0.0")
    result = plugin_logic(request)
    assert result["staged"] is True
    assert result["startupFailure"] is None
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"
    assert not list(directory.glob("*.new"))
    assert not (directory / ".update.json").exists()
    assert any("Discarding staged plugin update v" in message for message in result["logs"])


def test_plugin_update_offline_failure_keeps_installed_files(plugin_logic, tmp_path):
    request, directory = _update_request(tmp_path)
    request["offline"] = True
    result = plugin_logic(request)
    assert result["state"]["Latest"] == "확인 실패"
    assert result["state"]["Severity"] == 2
    assert result["state"]["RestartRequired"] is False
    assert result["state"]["Message"] is None
    assert (directory / UPDATE_DLL).read_bytes() == b"installed DLL"
    assert (directory / UPDATE_BUNDLE).read_bytes() == b"installed bundle"
