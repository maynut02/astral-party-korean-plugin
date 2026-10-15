"""Exercise the complete preloader offline, without initializing its UI or hooks."""

import hashlib
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from html import escape
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL_32 = b"UnityFS\0" + b"original-3.2" * 4096
ORIGINAL_33 = b"UnityFS\0" + b"original-3.3" * 4096
CATALOGS = {"3.2": "a" * 32, "3.3": "b" * 32}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


HARNESS = r'''
using System;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text.Json;

internal static class AstralBuildVersion { public const string Value = "1.0.0"; }
namespace BepInEx.Preloader.Core.Patching
{
    public abstract class BasePatcher
    { public object Log => new object(); public virtual void Initialize() { } }
    public sealed class PatcherPluginInfoAttribute : Attribute
    { public PatcherPluginInfoAttribute(string guid, string name, string version) { } }
}

internal sealed class OfflineProxy : IWebProxy
{
    public int Attempts;
    public ICredentials? Credentials { get; set; }
    public bool IsBypassed(Uri host) => false;
    public Uri GetProxy(Uri destination)
    {
        Attempts++;
        throw new InvalidOperationException("Network is forbidden in this harness");
    }
}

internal static class Program
{
    private const BindingFlags PrivateStatic = BindingFlags.NonPublic | BindingFlags.Static;

    private static void ThrowTlsFailure()
    {
        throw new HttpRequestException("The SSL connection could not be established, see inner exception.",
            new AuthenticationException("Simulated certificate chain failure",
                new Win32Exception(unchecked((int)0x800B0109), "Simulated untrusted root")));
    }

    public static void Main(string[] args)
    {
        var proxy = new OfflineProxy();
        HttpClient.DefaultProxy = proxy;
        var nativeCalls = 0;
        var preloader = typeof(DataUnity3dRedirect);
        NativeLibrary.SetDllImportResolver(preloader.Assembly, (name, assembly, searchPath) =>
        {
            nativeCalls++;
            throw new InvalidOperationException("Native calls are forbidden: " + name);
        });

        using var request = JsonDocument.Parse(File.ReadAllBytes(args[0]));
        foreach (var path in request.RootElement.GetProperty("paths").EnumerateObject())
            preloader.GetField(path.Name, PrivateStatic)!.SetValue(null, path.Value.GetString());
        var stateType = preloader.GetNestedType("RedirectState", BindingFlags.NonPublic)!;
        var state = JsonSerializer.Deserialize(
            request.RootElement.GetProperty("state").GetRawText(), stateType)!;
        var sourcePath = (string)preloader.GetField("sourcePath", PrivateStatic)!.GetValue(null)!;
        var results = new System.Collections.Generic.List<object>();

        foreach (var step in request.RootElement.GetProperty("steps").EnumerateArray())
        {
            if (step.TryGetProperty("sourceFixture", out var fixture))
                File.Copy(fixture.GetString()!, sourcePath, overwrite: true);
            if (step.TryGetProperty("stampSourceTime", out var stamp) && stamp.GetBoolean())
                stateType.GetProperty("SourceWriteTimeUtcTicks")!.SetValue(
                    state, File.GetLastWriteTimeUtc(sourcePath).Ticks);
            if (step.TryGetProperty("stampReplacementTime", out var replacementStamp) &&
                replacementStamp.GetBoolean())
            {
                var replacement = (string)preloader.GetMethod("StateReplacementPath", PrivateStatic)!
                    .Invoke(null, new object?[] { state })!;
                stateType.GetProperty("ReplacementWriteTimeUtcTicks")!.SetValue(
                    state, File.GetLastWriteTimeUtc(replacement).Ticks);
            }

            var name = step.GetProperty("method").GetString()!;
            if (name == "LogException")
            {
                try { ThrowTlsFailure(); }
                catch (Exception ex)
                {
                    var error = step.GetProperty("aggregate").GetBoolean()
                        ? new AggregateException(ex, new IOException("Simulated second failure")) : ex;
                    preloader.GetMethod(name, PrivateStatic)!.Invoke(null,
                        new object?[] { "online-update-failed", error });
                }
                results.Add(new { method = name, value = true });
                continue;
            }
            object?[] parameters = name switch
            {
                "VerifySource" => new object?[] { state },
                "EnsureCachedManifestCompatibility" => new object?[] { state, null },
                "EnsureStateReplacement" or "PrepareExistingState" => new object?[]
                    { state, step.GetProperty("allowDownload").GetBoolean() },
                _ => throw new InvalidOperationException("Unsupported test entry point: " + name)
            };
            var value = (bool)preloader.GetMethod(name, PrivateStatic)!.Invoke(null, parameters)!;
            if (nativeCalls != 0 || proxy.Attempts != 0)
                throw new InvalidOperationException("Preloader attempted native or network I/O");
            if (preloader.GetField("startupProgress", PrivateStatic)!.GetValue(null) != null ||
                preloader.GetField("createFileWHook", PrivateStatic)!.GetValue(null) != null)
                throw new InvalidOperationException("UI or file hook was initialized");
            results.Add(new { method = name, value,
                addressablesReady = (bool)stateType.GetProperty("AddressablesReady")!.GetValue(state)! });
        }
        Console.WriteLine(JsonSerializer.Serialize(results));
    }
}
'''


@pytest.fixture(scope="module")
def preloader_runtime(tmp_path_factory):
    build_root = tmp_path_factory.mktemp("rt")
    candidates = [ROOT / ".work/dotnet/dotnet.exe"] + [
        parent / "astral-party-korean-plugin/.work/dotnet/dotnet.exe"
        for parent in ROOT.parents
    ]
    local_dotnet = next((path for path in candidates if path.is_file()), None)
    dotnet = os.environ.get("ASTRAL_TEST_DOTNET") or (
        str(local_dotnet) if local_dotnet else shutil.which("dotnet")
    )
    if not dotnet:
        pytest.skip(".NET 6 SDK is required for preloader compatibility runtime tests")
    dotnet = str(Path(dotnet).resolve())
    env = dict(
        os.environ,
        DOTNET_ROOT=str(Path(dotnet).parent),
        DOTNET_MULTILEVEL_LOOKUP="0",
        DOTNET_CLI_HOME=str(build_root / "cli-home"),
        DOTNET_CLI_TELEMETRY_OPTOUT="1",
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1",
        DOTNET_GENERATE_ASPNET_CERTIFICATE="false",
        NUGET_PACKAGES=str(build_root / "nuget-packages"),
    )
    probe = subprocess.run(
        [dotnet, "--list-sdks"], cwd=build_root, env=env,
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
    )
    sdks = [line.split()[0] for line in probe.stdout.splitlines() if line.startswith("6.")]
    if probe.returncode or not sdks:
        pytest.skip(".NET 6 SDK is required for preloader compatibility runtime tests")
    (build_root / "global.json").write_text(
        json.dumps({"sdk": {"version": sdks[-1], "rollForward": "disable"}}), encoding="utf-8"
    )
    (build_root / "NuGet.Config").write_text(
        "<configuration><packageSources><clear /></packageSources></configuration>",
        encoding="utf-8",
    )
    source = escape(str(ROOT / "src/Preloader/DataUnity3dRedirect.cs"), quote=True)
    project = build_root / "UpdateCompatibility.csproj"
    project.write_text(f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup><Compile Include="{source}" /><Compile Include="Program.cs" /></ItemGroup>
</Project>''', encoding="utf-8")
    (build_root / "Program.cs").write_text(HARNESS, encoding="utf-8")
    build = subprocess.run(
        [dotnet, "build", str(project), "--nologo", "-v", "quiet", "-p:UseSharedCompilation=false"],
        cwd=build_root, env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=60,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    assembly = build_root / "bin/Debug/net6.0/UpdateCompatibility.dll"

    def invoke(cache, state, *steps):
        request = cache.root / "invocation.json"
        request.write_text(json.dumps({
            "paths": cache.paths, "state": state, "steps": steps,
        }), encoding="utf-8")
        result = subprocess.run(
            [dotnet, str(assembly), str(request)], cwd=cache.root, env=env,
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return json.loads(result.stdout)

    return invoke


@dataclass
class CachedRelease:
    state: dict
    replacement: Path
    addressables: Path


@dataclass
class Cache:
    root: Path
    route: str
    source: Path
    paths: dict

    def catalog(self, version: str) -> None:
        root = self.root / "LocalLow/com.unity.addressables"
        root.mkdir(parents=True, exist_ok=True)
        (root / f"catalog_{version}.hash").write_text(CATALOGS[version], encoding="ascii")

    def release(self, version: str, original: bytes) -> CachedRelease:
        payload = b"UnityFS\0patched-game-data-" + version.encode("ascii")
        addressables = b"UnityFS\0translated-addressables-" + version.encode("ascii")
        tag = "1.0.0" if version == "3.2" else "1.1.0"
        url = "https://github.com/maynut02/astral-party-korean-patch/releases/download/"
        common = {
            "compression": "gzip", "operation": "replace",
            "downloadSha256": "c" * 64, "downloadSize": 12,
        }
        manifest = json.dumps({
            "schemaVersion": 2,
            "patch": {"route": self.route, "channel": "release", "version": tag},
            "game": {"version": version, "revision": version.replace(".", "") + "00",
                     "catalogHash": CATALOGS[version]},
            "files": [
                dict(common, target="game-data", path="data.unity3d",
                     downloadUrl=url + tag + "/game-data.gz", sha256=sha256(payload),
                     size=len(payload), sourceSha256=sha256(original), sourceSize=len(original)),
                dict(common, target="addressables", path="bundle/hash/__data",
                     downloadUrl=url + tag + "/addressables.gz", sha256=sha256(addressables),
                     size=len(addressables)),
            ],
        }).encode("utf-8")
        manifest_sha = sha256(manifest)
        manifest_path = Path(self.paths["releaseRootPath"]) / manifest_sha / "manifest.json"
        replacement = Path(self.paths["gameDataRootPath"]) / (sha256(payload) + ".unity3d")
        addressables_path = Path(self.paths["payloadRootPath"]) / (sha256(addressables) + ".bundle")
        for path, content in [(manifest_path, manifest), (replacement, payload),
                              (addressables_path, addressables)]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        state = {
            "Route": self.route, "ReleaseTag": tag,
            "ManifestUrl": url + tag + "/" + self.route + "_manifest.json",
            "ManifestSha256": manifest_sha, "GameVersion": version,
            "Revision": version.replace(".", "") + "00", "CatalogHash": CATALOGS[version],
            "DownloadUrl": url + tag + "/game-data.gz", "DownloadSha256": "c" * 64,
            "DownloadSize": 12, "PayloadSha256": sha256(payload), "PayloadSize": len(payload),
            "SourceSha256": sha256(original), "SourceSize": len(original),
            "SourceWriteTimeUtcTicks": 0, "ReplacementWriteTimeUtcTicks": 0,
            "AddressablesReady": False,
        }
        return CachedRelease(state, replacement, addressables_path)


@pytest.fixture(params=["INT_STEAM", "CN_STEAM"])
def cache(tmp_path_factory, request):
    # Pytest's default per-test directory includes long parameterized test names.
    # Keep all generated .NET paths comfortably below Windows MAX_PATH instead.
    tmp_path = tmp_path_factory.mktemp("c")
    route = request.param
    data_dir = "AstralParty_INT_Data" if route == "INT_STEAM" else "AstralParty_CN_Data"
    source = tmp_path / data_dir / "data.unity3d"
    source.parent.mkdir()
    source.write_bytes(ORIGINAL_32)
    paths = {name: str(tmp_path / directory) for name, directory in {
        "releaseRootPath": "releases", "gameDataRootPath": "game-data",
        "payloadRootPath": "payloads",
        "legacyReplacementPath": "patched-data.unity3d",
    }.items()}
    paths.update(route=route, sourcePath=str(source), logPath=str(tmp_path / "data-redirect.log"))
    result = Cache(tmp_path, route, source, paths)
    result.catalog("3.2")
    return result


def step(method: str, allow_download: bool = False, **changes) -> dict:
    return dict(method=method, allowDownload=allow_download, **changes)


@pytest.mark.parametrize("aggregate", [False, True])
def test_failure_log_contains_nested_tls_exceptions_and_stack_traces(
    preloader_runtime, cache, aggregate
):
    release = cache.release("3.2", ORIGINAL_32)
    results = preloader_runtime(cache, release.state, dict(method="LogException", aggregate=aggregate))
    assert results[0]["value"] is True
    log = Path(cache.paths["logPath"]).read_text(encoding="utf-8")
    assert "online-update-failed type=System." in log
    assert "System.Net.Http.HttpRequestException" in log
    assert "hresult=0x" in log
    assert "System.Security.Authentication.AuthenticationException: Simulated certificate chain failure" in log
    assert "System.ComponentModel.Win32Exception" in log
    assert "Simulated untrusted root" in log
    assert "at Program.ThrowTlsFailure" in log
    if aggregate:
        assert "System.IO.IOException: Simulated second failure" in log


def test_exact_original_source_and_cached_replacement_are_accepted(preloader_runtime, cache):
    release = cache.release("3.2", ORIGINAL_32)
    assert cache.source.read_bytes() != release.replacement.read_bytes()
    results = preloader_runtime(cache, release.state,
        step("VerifySource"), step("EnsureStateReplacement"),
        step("EnsureStateReplacement", allow_download=True))
    assert [result["value"] for result in results] == [True, True, True]


@pytest.mark.parametrize("change", [
    "same-size-hash", "different-size", "matching-hash-wrong-size", "forged-timestamp", "missing",
])
def test_incompatible_source_rejects_even_valid_cached_payload(preloader_runtime, cache, change):
    release = cache.release("3.2", ORIGINAL_32)
    if change == "missing":
        cache.source.unlink()
    elif change in ("different-size", "matching-hash-wrong-size"):
        updated = ORIGINAL_33 + b"extra-bytes"
        cache.source.write_bytes(updated)
        if change == "matching-hash-wrong-size":
            # Isolate the size requirement even when the content digest matches.
            release.state["SourceSha256"] = sha256(updated)
    else:
        assert len(ORIGINAL_32) == len(ORIGINAL_33)
        cache.source.write_bytes(ORIGINAL_33)
    results = preloader_runtime(cache, release.state,
        step("VerifySource", stampSourceTime=change == "forged-timestamp"),
        step("EnsureStateReplacement"), step("EnsureStateReplacement", allow_download=True))
    assert [result["value"] for result in results] == [False, False, False]


def test_cached_replacement_rechecks_original_on_every_call(preloader_runtime, cache):
    release = cache.release("3.2", ORIGINAL_32)
    updated = cache.root / "updated-source.unity3d"
    restored = cache.root / "original-source.unity3d"
    updated.write_bytes(ORIGINAL_33)
    restored.write_bytes(ORIGINAL_32)
    results = preloader_runtime(cache, release.state,
        step("EnsureStateReplacement", stampReplacementTime=True),
        step("EnsureStateReplacement", sourceFixture=str(updated), stampSourceTime=True),
        step("EnsureStateReplacement", allow_download=True),
        step("EnsureStateReplacement", sourceFixture=str(restored), stampSourceTime=True))
    assert [result["value"] for result in results] == [True, False, False, True]


def test_old_patch_rejected_and_latest_patch_accepted_on_first_updated_launch(preloader_runtime, cache):
    old = cache.release("3.2", ORIGINAL_32)
    assert preloader_runtime(cache, old.state, step("PrepareExistingState"))[0]["value"] is True

    # Steam updated the original, while LocalLow and all old cached payloads remain valid.
    cache.source.write_bytes(ORIGINAL_33)
    old.state["AddressablesReady"] = True
    results = preloader_runtime(cache, old.state,
        step("EnsureCachedManifestCompatibility"),
        step("VerifySource", stampSourceTime=True),
        step("PrepareExistingState"), step("PrepareExistingState", allow_download=True))
    assert [result["value"] for result in results] == [False, False, False, False]

    # The latest patch is accepted immediately, even while only the old catalog exists.
    fresh = cache.release("3.3", ORIGINAL_33)
    results = preloader_runtime(cache, fresh.state,
        step("VerifySource"), step("PrepareExistingState"),
        step("PrepareExistingState", allow_download=True))
    assert [result["value"] for result in results] == [True, True, True]
    assert results[-1]["addressablesReady"] is True


def test_prepare_checks_installed_source_before_migrating_replacement(preloader_runtime, cache):
    release = cache.release("3.2", ORIGINAL_32)
    legacy = Path(cache.paths["legacyReplacementPath"])
    release.replacement.replace(legacy)
    cache.source.write_bytes(ORIGINAL_33)
    results = preloader_runtime(cache, release.state, step("PrepareExistingState"))
    assert results[0]["value"] is False
    assert not release.replacement.exists(), "incompatible source must be checked before migration"
    assert legacy.exists()


@pytest.mark.parametrize("catalog_state", ["absent", "old-version", "different-hash"])
def test_latest_patch_does_not_require_a_previous_successful_game_run(
    preloader_runtime, cache, catalog_state
):
    cache.source.write_bytes(ORIGINAL_33)
    fresh = cache.release("3.3", ORIGINAL_33)
    catalogs = cache.root / "LocalLow/com.unity.addressables"
    if catalog_state == "absent":
        for path in catalogs.iterdir():
            path.unlink()
        catalogs.rmdir()
    elif catalog_state == "different-hash":
        cache.catalog("3.3")
        (catalogs / "catalog_3.3.hash").write_text("f" * 32, encoding="ascii")
    before = {str(path.relative_to(cache.root)): path.read_bytes()
              for path in catalogs.rglob("*") if path.is_file()}
    results = preloader_runtime(cache, fresh.state,
        step("EnsureCachedManifestCompatibility"), step("PrepareExistingState"))
    assert [result["value"] for result in results] == [True, True]
    assert results[-1]["addressablesReady"] is True
    after = {str(path.relative_to(cache.root)): path.read_bytes()
             for path in catalogs.rglob("*") if path.is_file()}
    assert before == after, "plugin must leave the game's catalog cache untouched"


def test_cached_state_cannot_substitute_another_installed_source(preloader_runtime, cache):
    old = cache.release("3.2", ORIGINAL_32)
    cache.source.write_bytes(ORIGINAL_33)
    old.state["SourceSize"] = len(ORIGINAL_33)
    old.state["SourceSha256"] = sha256(ORIGINAL_33)
    results = preloader_runtime(cache, old.state,
        step("VerifySource"), step("EnsureCachedManifestCompatibility"),
        step("PrepareExistingState"))
    assert [result["value"] for result in results] == [True, False, False]


def test_prepare_requires_addressables_after_source_and_replacement(preloader_runtime, cache):
    release = cache.release("3.2", ORIGINAL_32)
    release.addressables.unlink()
    results = preloader_runtime(cache, release.state,
        step("VerifySource"), step("EnsureStateReplacement"), step("PrepareExistingState"))
    assert [result["value"] for result in results] == [True, True, False]
    assert results[-1]["addressablesReady"] is False

    # A source rejection must also precede Addressables cache processing.
    release.addressables.parent.rmdir()
    cache.source.write_bytes(ORIGINAL_33)
    results = preloader_runtime(cache, release.state, step("PrepareExistingState"))
    assert results[0]["value"] is False
    assert not release.addressables.parent.exists()
