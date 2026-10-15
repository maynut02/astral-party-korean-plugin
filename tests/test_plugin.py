from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_windows_plugin_uses_local_core_and_interop_references() -> None:
    projects = "\n".join(path.read_text(encoding="utf-8") for path in [
        ROOT / "src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj",
        ROOT / "src/Plugin/AstralPartyKoreanPlugin.csproj",
    ])
    props = (ROOT / "Directory.Build.props").read_text(encoding="utf-8")
    assert "AstralBepInExRoot" in projects
    assert "/core/" in projects and "/interop/" in projects
    assert "AstralRefsRoot" in props and "AstralGameRoot" in props
    assert "AstralDepsRoot" not in projects
    assert "<Private>false</Private>" in projects


def test_plugin_uses_game_ui_reference() -> None:
    source = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    project = (ROOT / "src/Plugin/AstralPartyKoreanPlugin.csproj").read_text(encoding="utf-8")
    assert "using UnityEngine.EventSystems;" not in source
    assert "/interop/UnityEngine.UI.dll" in project
    assert "UnityEngine.UI.Reference" not in project
    assert not (ROOT / "src/UnityEngine.UI.Reference").exists()
    assert "Resources.FindObjectsOfTypeAll<Font>()" not in source
    assert "MakeGenericMethod(typeof(Font)).Invoke" in source


def test_preloader_restores_game_window_foreground_once() -> None:
    source = (ROOT / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    assert "WsExNoActivate" in source
    assert "SwShowNoActivate" in source
    assert "ScheduleGameForegroundRestore" in source
    assert '"UnityWndClass"' in source
    assert "TryActivateGameWindow" in source
    assert "AttachThreadInput" in source
    assert "SetForegroundWindow(gameWindow)" in source
    assert "HwndTopmost" in source
    assert "HwndNoTopmost" in source


def test_preloader_requires_matching_installed_data_unity3d() -> None:
    source = (ROOT / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    assert "AstralBuildVersion.Value" in source
    assert "installed data.unity3d does not match release source" in source
    assert '" action=" + (matchesManifestSource ? "accepted" : "rejected-mismatch")' in source
    source_check = source[source.index("private static bool VerifySource"):source.index("private static bool VerifyReplacement")]
    assert "return matchesManifestSource;" in source_check
    assert "SourceWriteTimeUtcTicks" not in source_check
    assert "if (info.Length != state.PayloadSize) return false;" in source
    assert "string.Equals(actual, state.PayloadSha256" in source


def test_overlay_close_glyph_uses_release_safe_image_icon() -> None:
    source = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    assert "CreateCloseGlyphBar" in source
    assert "GetSolidSprite" in source
    assert "texture.SetPixel(0, 0, Color.white)" in source
    assert "texture.SetPixels(" not in source
    assert 'glyph.text = "×"' not in source


def test_runtime_cache_font_and_window_lifetime(tmp_path: Path) -> None:
    """Run the full preloader and production font lookup with small framework stubs."""
    import os
    import shutil
    import subprocess
    from html import escape

    import pytest

    if os.name != "nt":
        pytest.skip("startup progress uses Win32")
    local_dotnet = ROOT / ".work/dotnet/dotnet.exe"
    dotnet = os.environ.get("ASTRAL_TEST_DOTNET") or (
        str(local_dotnet) if local_dotnet.exists() else shutil.which("dotnet")
    )
    if not dotnet:
        pytest.skip(".NET 6 SDK is required for the Win32 runtime test")
    sdk_probe = subprocess.run([dotnet, "--list-sdks"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=20)
    if sdk_probe.returncode or not any(line.startswith("6.") for line in sdk_probe.stdout.splitlines()):
        pytest.skip(".NET 6 SDK is required for the Win32 runtime test")

    source = escape(str(ROOT / "src/Preloader/DataUnity3dRedirect.cs"), quote=True)
    project = tmp_path / "ProgressTest.csproj"
    project.write_text(f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net6.0</TargetFramework>
    <Nullable>enable</Nullable><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup><Compile Include="{source}" /><Compile Include="Program.cs" /></ItemGroup>
</Project>''', encoding="utf-8")
    (tmp_path / "NuGet.Config").write_text(
        '<configuration><packageSources><clear /></packageSources></configuration>', encoding="utf-8"
    )
    plugin = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    # Compile these exact production methods: Unity's destroyed-object null
    # semantics are simulated below; this is not an IL2CPP integration test.
    font_methods = plugin[plugin.index("    private static Font GetOverlayFont()"):
                          plugin.index("    private static void RefreshPreferredFont()")]
    manifest_methods = plugin[plugin.index("    private static ReleaseManifest ParseManifest("):
                             plugin.index("    private static void EnsureUnityFs(")]
    manifest_helpers = plugin[plugin.index("    private static void EnsureGitHubUrl("):
                             plugin.index("    internal static void Event(")]
    manifest_models = plugin[plugin.index("    private sealed class ReleaseManifest"):
                            plugin.index("    private sealed class PayloadEntry")]
    manifest_limits = "\n".join(line for line in plugin.splitlines() if
                               line.startswith("    private const string Repository =") or
                               line.startswith("    private const long TransportLimit ="))
    (tmp_path / "Program.cs").write_text(r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using UnityEngine;

internal static class AstralBuildVersion { public const string Value = "1.0.0"; }
namespace BepInEx.Preloader.Core.Patching
{
    public abstract class BasePatcher { public object Log => new object(); public virtual void Initialize() { } }
    public sealed class PatcherPluginInfoAttribute : Attribute
    { public PatcherPluginInfoAttribute(string guid, string name, string version) { } }
}

internal static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode,
        uint flags, uint access, IntPtr security);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessageW(uint thread, uint message, IntPtr wParam, IntPtr lParam);

    private static void Require(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }

    public static void Main()
    {
        VerifyManifestSnapshot();
        FontLookupTest.Verify();
        VerifyProgressCleanup();
    }

    private static object? Invoke(string name, params object?[] args) =>
        typeof(DataUnity3dRedirect).GetMethod(name, BindingFlags.Static | BindingFlags.NonPublic)!
            .Invoke(null, args);

    private static void Set(string name, object value) =>
        typeof(DataUnity3dRedirect).GetField(name, BindingFlags.Static | BindingFlags.NonPublic)!
            .SetValue(null, value);

    private static void VerifyManifestSnapshot()
    {
        var root = Path.Combine(Environment.CurrentDirectory, "cache-test");
        var releases = Path.Combine(root, "releases");
        var payloads = Path.Combine(root, "payloads");
        Directory.CreateDirectory(payloads);
        Directory.CreateDirectory(root);
        var original = Encoding.ASCII.GetBytes("UnityFS-original-test-player");
        var originalSha = Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant();
        var sourcePath = Path.Combine(root, "data.unity3d");
        File.WriteAllBytes(sourcePath, original);
        var payload = Encoding.ASCII.GetBytes("UnityFS-valid-test-payload");
        var payloadSha = Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
        var catalogHash = new string('a', 32);
        var manifest = Encoding.UTF8.GetBytes("{\"schemaVersion\":2," +
            "\"patch\":{\"route\":\"INT_STEAM\",\"channel\":\"release\",\"version\":\"1.0.0\"}," +
            "\"game\":{\"version\":\"1.2.3\",\"revision\":\"456\",\"catalogHash\":\"" + catalogHash + "\"}," +
            "\"files\":[{\"target\":\"addressables\",\"path\":\"bundle/hash/__data\"," +
            "\"compression\":\"gzip\",\"operation\":\"replace\"," +
            "\"downloadUrl\":\"https://github.com/maynut02/astral-party-korean-patch/releases/download/v1/payload.gz\"," +
            "\"downloadSha256\":\"" + new string('b', 64) + "\",\"downloadSize\":12," +
            "\"sha256\":\"" + payloadSha + "\",\"size\":" + payload.Length + "}," +
            "{\"target\":\"game-data\",\"path\":\"data.unity3d\",\"compression\":\"gzip\",\"operation\":\"replace\"," +
            "\"downloadUrl\":\"https://github.com/maynut02/astral-party-korean-patch/releases/download/v1/data.gz\"," +
            "\"downloadSha256\":\"" + new string('b', 64) + "\",\"downloadSize\":12," +
            "\"sha256\":\"" + payloadSha + "\",\"size\":" + payload.Length + "," +
            "\"sourceSha256\":\"" + originalSha + "\",\"sourceSize\":" + original.Length + "}]}");
        var manifestSha = Convert.ToHexString(SHA256.HashData(manifest)).ToLowerInvariant();
        ManifestParserTest.Verify(Encoding.UTF8.GetString(manifest));
        var manifestPath = Path.Combine(releases, manifestSha, "manifest.json");
        Directory.CreateDirectory(Path.GetDirectoryName(manifestPath)!);
        File.WriteAllBytes(manifestPath, manifest);
        var stateType = typeof(DataUnity3dRedirect).GetNestedType("RedirectState", BindingFlags.NonPublic)!;
        Set("route", "INT_STEAM");
        Set("sourcePath", sourcePath);
        var state = Invoke("ParseGameDataManifest", manifest, "1.0.0", manifestSha,
            "https://github.com/maynut02/astral-party-korean-patch/releases/download/v1/manifest.json")!;
        Set("releaseRootPath", releases);
        Set("payloadRootPath", payloads);
        var args = new object?[] { state, null };
        Require((bool)Invoke("EnsureCachedManifestCompatibility", args)!, "valid manifest was rejected");
        var verified = (byte[])args[1]!;
        Require(manifest.AsSpan().SequenceEqual(verified), "verified snapshot differs from cached manifest");
        File.Delete(manifestPath);
        var payloadPath = Path.Combine(payloads, payloadSha + ".bundle");
        File.WriteAllBytes(payloadPath, payload);
        Require((bool)Invoke("EnsureAddressablesFromState", verified, false)!,
            "verified payload required another manifest read");
        payload[payload.Length - 1] ^= 1;
        File.WriteAllBytes(payloadPath, payload);
        Require(!(bool)Invoke("EnsureAddressablesFromState", verified, false)!,
            "same-size corrupted payload was accepted offline");
        File.Delete(payloadPath);
        Require(!(bool)Invoke("EnsureAddressablesFromState", verified, false)!,
            "missing payload was accepted offline");
        File.WriteAllBytes(manifestPath, Encoding.UTF8.GetBytes("{}"));
        Require(!(bool)Invoke("EnsureCachedManifestCompatibility", args)!, "corrupted manifest was accepted");
        Require(((byte[])args[1]!).Length == 0, "failed verification exposed manifest bytes");
    }

    private static void VerifyProgressCleanup()
    {
        // Never switch to this desktop: even ShowWindow stays invisible to the user.
        var desktop = CreateDesktopW("AstralProgressTest-" + Guid.NewGuid().ToString("N"),
            IntPtr.Zero, IntPtr.Zero, 0, 0x01ff, IntPtr.Zero);
        Require(desktop != IntPtr.Zero, "CreateDesktop failed: " + Marshal.GetLastWin32Error());
        var type = typeof(DataUnity3dRedirect).GetNestedType("StartupProgress", BindingFlags.NonPublic)!;
        var progress = Activator.CreateInstance(type, nonPublic: true)!;
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var sync = type.GetField("sync", flags)!.GetValue(progress)!;
        using var returned = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        Exception? error = null;
        var worker = new Thread(() =>
        {
            try
            {
                Require(SetThreadDesktop(desktop), "SetThreadDesktop failed: " + Marshal.GetLastWin32Error());
                type.GetMethod("Run", flags)!.Invoke(progress, null);
            }
            catch (Exception ex) { error = ex; }
            finally { returned.Set(); }
            // Keep the owning thread alive: thread-exit cleanup must not hide a leak in Run.
            release.Wait();
        }) { IsBackground = true };
        worker.Start();
        uint threadId = 0;
        IntPtr parent = IntPtr.Zero;
        var children = new IntPtr[3];
        try
        {
            var ready = SpinWait.SpinUntil(() =>
            {
                lock (sync)
                {
                    parent = (IntPtr)type.GetField("window", flags)!.GetValue(progress)!;
                    threadId = (uint)type.GetField("uiThreadId", flags)!.GetValue(progress)!;
                    children[0] = (IntPtr)type.GetField("statusLabel", flags)!.GetValue(progress)!;
                    children[1] = (IntPtr)type.GetField("detailLabel", flags)!.GetValue(progress)!;
                    children[2] = (IntPtr)type.GetField("progressBar", flags)!.GetValue(progress)!;
                }
                return parent != IntPtr.Zero || returned.IsSet;
            }, TimeSpan.FromSeconds(10));
            if (error != null) throw error;
            Require(ready && parent != IntPtr.Zero && IsWindow(parent), "progress window was not created");
            foreach (var child in children) Require(IsWindow(child), "progress child was not created");
            Require(PostThreadMessageW(threadId, 0x0012, IntPtr.Zero, IntPtr.Zero), "WM_QUIT failed");
            Require(returned.Wait(TimeSpan.FromSeconds(10)), "progress loop did not stop");
            if (error != null) throw error;
            Require(!IsWindow(parent), "progress parent survived Run cleanup");
            foreach (var child in children) Require(!IsWindow(child), "progress child survived Run cleanup");
        }
        finally
        {
            if (threadId != 0) PostThreadMessageW(threadId, 0x0012, IntPtr.Zero, IntPtr.Zero);
            release.Set();
            if (worker.Join(TimeSpan.FromSeconds(10))) CloseDesktop(desktop);
        }
    }
}
namespace UnityEngine
{
    internal sealed class Font
    {
        public string name = "";
        public bool Destroyed;
        public static Font CreateDynamicFontFromOSFont(string name, int size) => new Font { name = name };
        public static bool operator ==(Font? left, Font? right) =>
            ReferenceEquals(left, right) ||
            ((ReferenceEquals(left, null) || left.Destroyed) && (ReferenceEquals(right, null) || right.Destroyed));
        public static bool operator !=(Font? left, Font? right) => !(left == right);
        public override bool Equals(object? value) => ReferenceEquals(this, value);
        public override int GetHashCode() => base.GetHashCode();
    }
    internal static class Resources
    {
        public static Font? Available;
        public static int Searches;
        public static T[] FindObjectsOfTypeAll<T>()
        {
            Searches++;
            return Available == null ? Array.Empty<T>() : new[] { (T)(object)Available };
        }
        public static T GetBuiltinResource<T>(string name) where T : new() => new T();
    }
}

internal static class FontLookupTest
{
    private const string PreferredOverlayFontName = "Afacad-Regular";
    private static Font? overlayFont;
    private static Font? fallbackOverlayFont;
    private static void LogPreferredFont(Font font) { }
    private static void Require(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
    public static void Verify()
    {
        var fallback = GetOverlayFont();
        Require(fallback != null, "no fallback font before game font loads");
        var preferred = new Font { name = PreferredOverlayFontName };
        Resources.Available = preferred;
        Require(ReferenceEquals(GetOverlayFont(), preferred), "late-loaded game font was not selected");
        var searches = Resources.Searches;
        for (var i = 0; i < 10; i++)
            Require(ReferenceEquals(GetOverlayFont(), preferred), "live game font was not reused");
        Require(Resources.Searches == searches, "live font triggered repeated resource enumeration");
        preferred.Destroyed = true;
        var replacement = new Font { name = PreferredOverlayFontName };
        Resources.Available = replacement;
        Require(ReferenceEquals(GetOverlayFont(), replacement), "destroyed game font was not replaced");
        Require(Resources.Searches > searches, "destroyed font did not restart resource enumeration");
    }
''' + font_methods + "}\n" + r'''
internal static class ManifestParserTest
{
    public static void Verify(string manifest)
    {
        // A valid preloader download can exceed 64 MiB but stay below its
        // 128 MiB transport limit. The plugin only consumes that verified cache.
        var larger = manifest.Replace("\"downloadSize\":12", "\"downloadSize\":100663296");
        foreach (var route in new[] { "INT_STEAM", "CN_STEAM" })
        {
            var bytes = Encoding.UTF8.GetBytes(larger.Replace("INT_STEAM", route));
            if (ParseManifest(bytes, route).Files.Count != 2)
                throw new InvalidOperationException("supported route rejected verified manifest");
        }
        var oversized = Encoding.UTF8.GetBytes(larger.Replace("100663296", "134217729"));
        try { ParseManifest(oversized, "INT_STEAM"); }
        catch (InvalidDataException) { return; }
        throw new InvalidOperationException("oversized transport was accepted");
    }
''' + manifest_limits + manifest_methods + manifest_helpers + manifest_models + "}\n", encoding="utf-8")
    env = dict(os.environ, DOTNET_CLI_HOME=str(tmp_path / "cli-home"),
               DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1",
               DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
    build = subprocess.run(
        [dotnet, "build", str(project), "--nologo", "-v", "quiet", "-p:UseSharedCompilation=false"],
        cwd=tmp_path, env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=60,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    result = subprocess.run(
        [dotnet, str(tmp_path / "bin/Debug/net6.0/ProgressTest.dll")],
        cwd=tmp_path, env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=40,
    )
    assert result.returncode == 0, result.stdout + result.stderr
