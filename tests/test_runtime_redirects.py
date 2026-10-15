"""Compile production redirect methods with managed stubs; no game, hooks or network."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "characters_assets_all.bundle"
OTHER_BUNDLE = "ui_assets_all.bundle"
HASH = "0123456789abcdef0123456789abcdef"
OTHER_HASH = "fedcba9876543210fedcba9876543210"
ROUTES = ("INT_STEAM", "CN_STEAM")


HARNESS = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;
using Environment = TestProfile;

namespace UnityEngine
{
    internal static class Application { public static string? version; }
}

// Never consult the machine's real user profile, even if a regression brings
// back the LocalLow lookup. Tests supply an isolated, empty or stale profile.
internal static class TestProfile
{
    public enum SpecialFolder { UserProfile }
    public static string Root = "";
    public static int Reads;
    public static string GetFolderPath(SpecialFolder folder) { Reads++; return Root; }
}

internal static class OverlayUi
{
    public static int Refreshes;
    public static void TryRefresh() { Refreshes++; }
}

internal enum LoadType { Local, Web }
internal sealed class Hash128
{
    private readonly string value;
    public Hash128(string value) { this.value = value; }
    public override string ToString() => value;
}
internal sealed class Options
{
    public string? BundleName { get; set; }
    public object? Hash { get; set; }
}
internal sealed class LegacyOptions
{
    public string? m_BundleName;
    public object? m_Hash;
}
internal sealed class FakeIResourceLocation
{
    public string? PrimaryKey { get; set; }
    public string? InternalId { get; set; }
}
internal sealed class FakeProvideHandle { public object? Location; }
internal sealed class ResourceFields
{
    public object? m_Options;
    public object? m_ProvideHandle;
    public string? m_TransformedInternalId;
}
internal sealed class ResourceProperties
{
    public object? Options { get; set; }
    public object? ProvideHandle { get; set; }
    public string? TransformedInternalId { get; set; }
}
internal sealed class ResourceGetters
{
    public object? OptionsValue;
    public object? HandleValue;
    public string? TransformedValue;
    public object? get_Options() => OptionsValue;
    public object? get_ProvideHandle() => HandleValue;
    public string? get_TransformedInternalId() => TransformedValue;
}

internal static class RuntimeRedirectTest
{
    private const int PreparationTimeoutSeconds = 45;
    private static readonly object Sync = new object();
    private static readonly List<PayloadEntry> Entries = new List<PayloadEntry>();
    private static readonly HashSet<string> ConnectedEntries =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private static int PreparationState;
    private static Task? PreparationTask = null;
    private static string PreparedGameVersion = "";
    private static string PreparedRevision = "";
    private static string ActiveRoute = "";
    private static string ExpectedGameVersion = "";
    private static int RuntimeRedirectDisabled;
    private static readonly List<string> Events = new List<string>();
    private static void Event(string name, string message) { Events.Add(name + ":" + message); }
    private static void SetUi(string status, string? latest, string? installed, string? game) { }

    private static string? Text(JsonElement obj, string key, string? fallback = null) =>
        obj.TryGetProperty(key, out var value) ? value.GetString() : fallback;

    public static void Main(string[] args)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(args[0]));
        var request = document.RootElement;
        ActiveRoute = Text(request, "route")!;
        PreparedGameVersion = ExpectedGameVersion = "3.3.0";
        PreparedRevision = "012";
        PreparationState = 1;
        TestProfile.Root = Text(request, "profile")!;
        Application.version = ExpectedGameVersion;
        foreach (var entry in request.GetProperty("entries").EnumerateArray())
            Entries.Add(new PayloadEntry(Text(entry, "bundleName")!, Text(entry, "hash")!,
                Text(entry, "path")!));

        var results = new List<object>();
        foreach (var step in request.GetProperty("steps").EnumerateArray())
        {
            if (step.TryGetProperty("applicationVersion", out var appVersion))
                Application.version = appVersion.GetString();
            var bundleName = Text(step, "bundleName");
            var hashText = Text(step, "hash");
            object? hash = hashText == null ? null : new Hash128(hashText);
            object? options = Text(step, "optionMembers") == "legacy"
                ? new LegacyOptions { m_BundleName = bundleName, m_Hash = hash }
                : new Options { BundleName = bundleName, Hash = hash };
            if (step.TryGetProperty("nullOptions", out var nullOptions) && nullOptions.GetBoolean())
                options = null;
            var location = new FakeIResourceLocation {
                PrimaryKey = Text(step, "primaryKey"), InternalId = Text(step, "internalId") };
            var handle = new FakeProvideHandle { Location = location };
            var locationSource = Text(step, "locationSource", "resource");
            var resourceHandle = locationSource == "resource" ? handle : null;
            var transformed = Text(step, "transformedInternalId");
            object resource = Text(step, "resourceMembers", "fields") switch
            {
                "properties" => new ResourceProperties { Options = options,
                    ProvideHandle = resourceHandle, TransformedInternalId = transformed },
                "getters" => new ResourceGetters { OptionsValue = options,
                    HandleValue = resourceHandle, TransformedValue = transformed },
                _ => new ResourceFields { m_Options = options,
                    m_ProvideHandle = resourceHandle, m_TransformedInternalId = transformed }
            };
            var originalPath = Text(step, "originalPath", "original-provider-path")!;
            var values = new List<object>();
            if (locationSource == "argument-location") values.Add(location);
            if (locationSource == "argument-handle") values.Add(handle);
            values.Add(LoadType.Web);
            values.Add(originalPath);
            var arguments = values.ToArray();
            var identity = ReadIdentity(resource, arguments);
            var found = FindEntry(identity);
            var allowOriginal = GetLoadInfoPrefix(resource, arguments);
            results.Add(new {
                allowOriginal, loadType = arguments[^2].ToString(), path = arguments[^1], originalPath,
                matchedHash = found?.Hash, matchedPath = found?.PayloadPath,
                identity = new { bundleName = identity.BundleName, hash = identity.Hash,
                    primaryKey = identity.PrimaryKey, internalId = identity.InternalId,
                    transformedInternalId = identity.TransformedInternalId },
                disabled = RuntimeRedirectDisabled, preparationState = PreparationState,
                entryCount = Entries.Count, connectedCount = ConnectedEntries.Count,
                compatibilityFailures = Events.Count(e => e.StartsWith("RUNTIME_COMPATIBILITY_FAILED:"))
            });
        }
        Console.WriteLine(JsonSerializer.Serialize(new { steps = results, events = Events,
            profileReads = TestProfile.Reads, overlayRefreshes = OverlayUi.Refreshes }));
    }

__PRODUCTION_METHODS__
__PRODUCTION_MODELS__
}
'''


@pytest.fixture(scope="module")
def runtime_redirects(tmp_path_factory):
    build_root = tmp_path_factory.mktemp("rdr")
    candidates = [ROOT / ".work/dotnet/dotnet.exe"] + [
        parent / "astral-party-korean-plugin/.work/dotnet/dotnet.exe"
        for parent in ROOT.parents
    ]
    local_dotnet = next((path for path in candidates if path.is_file()), None)
    dotnet = os.environ.get("ASTRAL_TEST_DOTNET") or (
        str(local_dotnet) if local_dotnet else shutil.which("dotnet")
    )
    if not dotnet:
        pytest.skip(".NET 6 SDK is required for runtime redirect behavior tests")
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
        pytest.skip(".NET 6 SDK is required for runtime redirect behavior tests")
    (build_root / "global.json").write_text(
        json.dumps({"sdk": {"version": sdks[-1], "rollForward": "disable"}}), encoding="utf-8"
    )
    (build_root / "NuGet.Config").write_text(
        "<configuration><packageSources><clear /></packageSources></configuration>",
        encoding="utf-8",
    )
    project = build_root / "RuntimeRedirects.csproj"
    project.write_text('''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup><Compile Include="Program.cs" /></ItemGroup>
</Project>''', encoding="utf-8")
    plugin = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    # Extract exact production bodies, including reflection, build matching,
    # hash fallback and the permanent-disable path. Only framework state/UI is stubbed.
    methods = plugin[plugin.index("    private static bool GetLoadInfoPrefix("):
                     plugin.index("    private static bool EventSystemUpdatePrefix(")]
    methods += plugin[plugin.index("    private static void WaitForPreparation("):
                      plugin.index("    private static string MethodKey(")]
    models = plugin[plugin.index("    private sealed class PayloadEntry"):
                    plugin.index("\n}\n\ninternal static class OverlayUi")]
    (build_root / "Program.cs").write_text(
        HARNESS.replace("__PRODUCTION_METHODS__", methods).replace("__PRODUCTION_MODELS__", models),
        encoding="utf-8",
    )
    build = subprocess.run(
        [dotnet, "build", str(project), "--nologo", "-v", "quiet", "-p:UseSharedCompilation=false"],
        cwd=build_root, env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=60,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    assembly = build_root / "bin/Debug/net6.0/RuntimeRedirects.dll"

    def invoke(root, *steps, route="INT_STEAM", catalog=None, missing_payload=False):
        profile = root / "profile"
        profile.mkdir()
        if catalog is not None:
            route_directory = "AstralParty_INT" if route == "INT_STEAM" else "AstralParty_CN"
            catalog_path = (profile / "AppData/LocalLow/feimo" / route_directory /
                            "com.unity.addressables/catalog_3.3.0.hash")
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(catalog, encoding="ascii")
        entries = []
        for index, (name, hash_value) in enumerate(((BUNDLE, HASH), (OTHER_BUNDLE, OTHER_HASH))):
            payload = root / f"verified-{index}.bundle"
            if not missing_payload:
                payload.write_bytes(b"UnityFS\0verified-local-payload")
            entries.append({"bundleName": name, "hash": hash_value, "path": str(payload)})
        request = root / "request.json"
        request.write_text(json.dumps({
            "route": route, "profile": str(profile), "entries": entries, "steps": steps,
        }), encoding="utf-8")
        result = subprocess.run(
            [dotnet, str(assembly), str(request)], cwd=root, env=env,
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        response = json.loads(result.stdout)
        assert response["profileReads"] == 0, "runtime consulted LocalLow catalog authority"
        assert not any(event.startswith("REDIRECT_FAILED:") for event in response["events"])
        return response

    return invoke


def cdn_path(route="INT_STEAM", version="3.3.0", revision="012", hash_value=HASH):
    return f"http://seresjp.feimogames.com/{route}/{version}/{revision}/TmvW1l\\{hash_value}.bundle"


def assert_redirect(step, hash_value=HASH):
    assert step["matchedHash"] == hash_value
    assert step["allowOriginal"] is False
    assert step["loadType"] == "Local"
    assert step["path"] == step["matchedPath"]
    assert step["disabled"] == 0
    assert step["preparationState"] == 1
    assert step["connectedCount"] == 1


def assert_original(step):
    assert step["allowOriginal"] is True
    assert step["loadType"] == "Web"
    assert step["path"] == step["originalPath"]


@pytest.mark.parametrize("route", ROUTES)
@pytest.mark.parametrize("path_kind", ("cdn", "local"))
@pytest.mark.parametrize("identity_kind", ("options", "internalId", "transformedInternalId", "primaryKey"))
def test_first_launch_redirects_without_local_catalog(
    runtime_redirects, tmp_path, route, path_kind, identity_kind,
):
    path = cdn_path(route) if path_kind == "cdn" else (
        f"C:/Games/AstralParty/StreamingAssets/aa/StandaloneWindows64/{HASH}.bundle"
    )
    step = ({"bundleName": BUNDLE, "hash": HASH, "internalId": path}
            if identity_kind == "options" else {identity_kind: path, "nullOptions": True})
    result = runtime_redirects(tmp_path, step, route=route)
    assert_redirect(result["steps"][0])
    assert not list((tmp_path / "profile").rglob("catalog_*.hash"))
    fallback = any(event.startswith("IDENTITY_HASH_FALLBACK:") for event in result["events"])
    assert fallback is (identity_kind != "options")


@pytest.mark.parametrize("route", ROUTES)
@pytest.mark.parametrize("catalog", (OTHER_HASH, "invalid-stale-catalog"))
def test_stale_local_catalog_does_not_control_runtime(runtime_redirects, tmp_path, route, catalog):
    result = runtime_redirects(tmp_path, {"internalId": cdn_path(route)}, route=route, catalog=catalog)
    assert_redirect(result["steps"][0])


@pytest.mark.parametrize("resource_members,option_members", (
    ("fields", "modern"), ("fields", "legacy"), ("properties", "modern"), ("getters", "modern"),
))
def test_read_identity_preserves_exact_options_without_path(
    runtime_redirects, tmp_path, resource_members, option_members,
):
    result = runtime_redirects(tmp_path, {
        "bundleName": BUNDLE.upper(), "hash": HASH.upper(),
        "resourceMembers": resource_members, "optionMembers": option_members,
    })
    step = result["steps"][0]
    assert step["identity"]["bundleName"] == BUNDLE.upper()
    assert step["identity"]["hash"] == HASH.upper()
    assert_redirect(step)
    assert not any(event.startswith("IDENTITY_HASH_FALLBACK:") for event in result["events"])


@pytest.mark.parametrize("resource_members", ("fields", "properties", "getters"))
@pytest.mark.parametrize("location_source", ("resource", "argument-location", "argument-handle"))
def test_read_identity_handles_null_wrappers_and_location_overloads(
    runtime_redirects, tmp_path, resource_members, location_source,
):
    path = cdn_path()
    result = runtime_redirects(tmp_path, {
        "internalId": path, "primaryKey": HASH + ".bundle", "nullOptions": True,
        "resourceMembers": resource_members, "locationSource": location_source,
    })
    step = result["steps"][0]
    assert step["identity"]["bundleName"] is None
    assert step["identity"]["hash"] is None
    assert step["identity"]["internalId"] == path
    assert step["identity"]["primaryKey"] == HASH + ".bundle"
    assert_redirect(step)


@pytest.mark.parametrize("route", ROUTES)
@pytest.mark.parametrize("mismatch", ("route", "version", "revision"))
@pytest.mark.parametrize("field", ("internalId", "transformedInternalId", "primaryKey"))
@pytest.mark.parametrize("with_options", (False, True))
def test_explicit_cdn_build_mismatch_never_redirects(
    runtime_redirects, tmp_path, route, mismatch, field, with_options,
):
    path = cdn_path(
        route=("CN_STEAM" if route == "INT_STEAM" else "INT_STEAM") if mismatch == "route" else route,
        version="3.2.0" if mismatch == "version" else "3.3.0",
        revision="999" if mismatch == "revision" else "012",
    )
    options = {"bundleName": BUNDLE, "hash": HASH} if with_options else {}
    result = runtime_redirects(tmp_path, {field: path, **options}, route=route)
    step = result["steps"][0]
    assert_original(step)
    assert step["matchedHash"] is None
    assert step["disabled"] == 0


@pytest.mark.parametrize("field", ("internalId", "transformedInternalId", "primaryKey"))
def test_conflicting_cdn_field_cannot_hide_behind_matching_field(runtime_redirects, tmp_path, field):
    paths = {"internalId": cdn_path(), "transformedInternalId": cdn_path(), "primaryKey": cdn_path()}
    paths[field] = cdn_path(version="3.2.0")
    result = runtime_redirects(tmp_path, paths, {"internalId": cdn_path()})
    assert_original(result["steps"][0])
    assert result["steps"][0]["matchedHash"] is None
    assert_redirect(result["steps"][1])


@pytest.mark.parametrize("options", (
    {"bundleName": OTHER_BUNDLE},
    {"bundleName": "unrelated.bundle", "hash": "0" * 32},
    {"hash": OTHER_HASH},
    {"hash": OTHER_HASH.upper()},
    {"bundleName": BUNDLE, "hash": OTHER_HASH},
))
def test_populated_options_cannot_be_overridden_by_filename(runtime_redirects, tmp_path, options):
    result = runtime_redirects(tmp_path, {"internalId": cdn_path(), **options})
    step = result["steps"][0]
    assert_original(step)
    assert step["matchedHash"] is None
    assert step["disabled"] == 0


@pytest.mark.parametrize("bundle_name", (None, BUNDLE))
@pytest.mark.parametrize("hash_value", (None, "", "0" * 32, "unavailable-wrapper-hash"))
def test_unavailable_hash128_allows_filename_fallback(
    runtime_redirects, tmp_path, bundle_name, hash_value,
):
    result = runtime_redirects(tmp_path, {
        "bundleName": bundle_name, "hash": hash_value, "internalId": cdn_path(),
    })
    step = result["steps"][0]
    assert step["identity"]["hash"] == hash_value
    assert_redirect(step)
    assert any(event.startswith("IDENTITY_HASH_FALLBACK:") for event in result["events"])


@pytest.mark.parametrize("field", ("internalId", "transformedInternalId", "primaryKey"))
@pytest.mark.parametrize("token", (
    "a" + HASH, HASH + "0", "a" + HASH + "f", HASH + HASH, "g" + HASH, HASH + "z", "g" + HASH + "z",
))
def test_hash_substring_of_longer_hex_is_rejected(runtime_redirects, tmp_path, field, token):
    result = runtime_redirects(tmp_path, {field: f"StreamingAssets/aa/StandaloneWindows64/{token}.bundle"})
    step = result["steps"][0]
    assert_original(step)
    assert step["matchedHash"] is None


@pytest.mark.parametrize("field", ("internalId", "transformedInternalId", "primaryKey"))
@pytest.mark.parametrize("path", (
    "http://example.invalid/other.bundle?unrelated=" + HASH,
    "http://example.invalid/other.bundle#" + HASH,
    "http://example.invalid/" + HASH + "/other.bundle",
    "http://example.invalid/" + HASH + "/nested/other.bundle?hash=" + HASH,
    "http://example.invalid/other.bundle?file=/" + HASH + ".bundle",
    "http://example.invalid/other.bundle#file=/" + HASH + ".bundle",
))
def test_query_fragment_and_directory_hash_decoys_are_rejected(
    runtime_redirects, tmp_path, field, path,
):
    result = runtime_redirects(tmp_path, {field: path})
    assert_original(result["steps"][0])
    assert result["steps"][0]["matchedHash"] is None


@pytest.mark.parametrize("path", (
    HASH + ".bundle",
    "prefix_" + HASH + ".bundle",
    "cache/" + HASH + "/__data",
    HASH.upper() + ".bundle",
    "cache/a" + HASH + "/" + HASH + ".bundle",
    "a" + HASH + "_" + HASH + ".bundle",
    HASH + ".bundle?download=1#payload",
))
def test_exact_hash_token_boundaries_allow_fallback(runtime_redirects, tmp_path, path):
    result = runtime_redirects(tmp_path, {"internalId": path})
    assert_redirect(result["steps"][0])


@pytest.mark.parametrize("step", (
    {"bundleName": BUNDLE},
    {"primaryKey": BUNDLE},
    {"hash": HASH},
    {"internalId": cdn_path(hash_value="1" * 32)},
    {"internalId": f"StreamingAssets/aa/StandaloneWindows64/{HASH[:-1]}.bundle"},
))
def test_name_only_or_unknown_path_hash_does_not_redirect(runtime_redirects, tmp_path, step):
    result = runtime_redirects(tmp_path, step)
    assert_original(result["steps"][0])
    assert result["steps"][0]["matchedHash"] is None


def test_missing_prepared_payload_uses_original_provider(runtime_redirects, tmp_path):
    result = runtime_redirects(tmp_path, {"internalId": cdn_path()}, missing_payload=True)
    step = result["steps"][0]
    assert step["matchedHash"] == HASH
    assert_original(step)


@pytest.mark.parametrize("route", ROUTES)
@pytest.mark.parametrize("wrong_version", (None, "", "3.2.0", "3.3.0.1"))
def test_application_version_mismatch_permanently_disables_redirects(
    runtime_redirects, tmp_path, route, wrong_version,
):
    target = {"internalId": cdn_path(route)}
    result = runtime_redirects(tmp_path, target,
        {**target, "applicationVersion": wrong_version},
        {**target, "applicationVersion": "3.3.0"}, route=route)
    ready, mismatch, restored = result["steps"]
    assert_redirect(ready)
    assert_original(mismatch)
    assert_original(restored)
    for step in (mismatch, restored):
        assert step["disabled"] == 1
        assert step["preparationState"] == 2
        assert step["entryCount"] == 0
        assert step["connectedCount"] == 0
        assert step["compatibilityFailures"] == 1
    assert restored["matchedHash"] is None
