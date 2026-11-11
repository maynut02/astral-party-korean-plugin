using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using BepInEx;
using BepInEx.Logging;
using BepInEx.Unity.IL2CPP;
using HarmonyLib;
using TMPro;
using UnityEngine;
using UnityEngine.EventSystems;

namespace AstralParty.KoreanPatch;

[BepInPlugin(PluginGuid, PluginName, AstralBuildVersion.Core)]
public sealed class Plugin : BasePlugin
{
    public const string PluginGuid = "astral-party.korean-patch";
    public const string PluginName = "Astral Party Korean Patch";
    public const string PluginVersion = AstralBuildVersion.Value;
    internal static ManualLogSource Logger = null!;
    internal static GameRoute? Route { get; private set; }
    internal static PackClient Packs = null!;
    internal static PluginUpdateClient Updates = null!;
    private static int lastUiFrame = -1;
    private static string? cleanupFailure;
    private static bool restartRequested;
    private Harmony harmony = null!;

    public override void Load()
    {
        var elapsed = Stopwatch.StartNew();
        Logger = Log;
        GameInfoReader.Initialize(Application.version);
        Route = GameRoute.Detect(Process.GetCurrentProcess().ProcessName, Application.dataPath);
        var pluginDirectory = Path.GetDirectoryName(typeof(Plugin).Assembly.Location)!;
        cleanupFailure = LegacyCleanup.Run(Paths.BepInExRootPath, pluginDirectory, message => Log.LogWarning(message));
        var startupFailure = new UpdateInstaller(pluginDirectory, message => Log.LogInfo(message))
            .PrepareStartup(PluginVersion);
        var autoUpdate = Config.Bind("Update", "AutoUpdate", true,
            "게임 시작 시 서명된 최신 플러그인을 자동 설치합니다. 적용하려면 게임을 다시 시작해야 합니다.");
        string bepinexVersion;
        try
        {
            // The API returns SemanticVersioning.Version; avoid adding that DLL to the plugin references.
            bepinexVersion = typeof(Paths).GetProperty("BepInExVersion", BindingFlags.Public | BindingFlags.Static)?
                .GetValue(null)?.ToString() ?? "";
        }
        catch (Exception ex)
        {
            bepinexVersion = "";
            Log.LogWarning("Could not read running BepInEx version; plugin auto-install disabled: " + ex);
        }
        var http = new RuntimeHttp(PluginVersion);
        // Everything the plugin writes stays in its own folder, so deleting that folder uninstalls it fully.
        Packs = new PackClient(Path.Combine(pluginDirectory, "translation-pack"),
            http.DownloadAsync, message => Log.LogInfo(message), elapsed);
        Updates = new PluginUpdateClient(PluginVersion, bepinexVersion, autoUpdate.Value, pluginDirectory,
            http.DownloadAsync, message => Log.LogInfo(message), startupFailure);
        harmony = new Harmony(PluginGuid);
        Patch("SystemConfig.GetFontAsset", () => AccessTools.Method(typeof(SystemConfig), nameof(SystemConfig.GetFontAsset)),
            typeof(FontAssets), nameof(FontAssets.GetFontAssetPostfix), postfix: true);
        Patch("TextAsset.get_bytes", () => AccessTools.PropertyGetter(typeof(TextAsset), nameof(TextAsset.bytes)),
            typeof(Translation), nameof(Translation.BytesPrefix));
        Patch("TextAsset.get_text", () => AccessTools.PropertyGetter(typeof(TextAsset), nameof(TextAsset.text)),
            typeof(Translation), nameof(Translation.TextPrefix));
        Patch("TMP_FontAsset.Awake", () => AccessTools.Method(typeof(TMP_FontAsset), nameof(TMP_FontAsset.Awake)),
            typeof(TmpSwap), nameof(TmpSwap.AwakePostfix), postfix: true);
        Patch("TMP_FontAsset.get_atlasTexture", () => AccessTools.PropertyGetter(typeof(TMP_FontAsset), nameof(TMP_FontAsset.atlasTexture)),
            typeof(TmpSwap), nameof(TmpSwap.AtlasTexturePrefix));
        // HybridCLR cannot inject plugin MonoBehaviours or managed UnityEvent delegates.
        Patch("EventSystem.Update", () => AccessTools.Method(typeof(EventSystem), "Update"),
            typeof(Plugin), nameof(EventSystemUpdatePrefix));
        Log.LogInfo("Astral Party Korean Patch v" + PluginVersion + " loaded; route=" + (Route?.Name ?? "unsupported") +
            "; BepInEx=" + bepinexVersion + "; AutoUpdate=" + autoUpdate.Value);
    }

    private void Patch(string label, Func<MethodBase?> resolve, Type owner, string hook, bool postfix = false)
    {
        try
        {
            var target = resolve() ?? throw new MissingMethodException(label);
            var method = AccessTools.Method(owner, hook) ?? throw new MissingMethodException(owner.FullName, hook);
            var patch = new HarmonyMethod(method);
            harmony.Patch(target, prefix: postfix ? null : patch, postfix: postfix ? patch : null);
            Log.LogInfo("Patched " + label);
        }
        catch (Exception ex) { Log.LogError("Patch failed for " + label + ": " + ex); }
    }

    private static void EventSystemUpdatePrefix()
    {
        var frame = Time.frameCount;
        if (frame == lastUiFrame) return;
        lastUiFrame = frame;
        GameInfoReader.Tick(frame);
        StatusOverlay.Tick();
    }

    internal static OverlaySnapshot GetUiSnapshot() => OverlayState.Create(GameInfoReader.Version,
        GameInfoReader.Revision, PluginVersion, Updates.Snapshot(), Route != null, cleanupFailure, Packs.Snapshot());

    internal static void Restart()
    {
        if (restartRequested || !Updates.Snapshot().RestartRequired) return;
        try
        {
            using var current = Process.GetCurrentProcess();
            var executable = Paths.ExecutablePath;
            if (string.IsNullOrEmpty(executable)) executable = current.MainModule?.FileName ?? "";
            GameRestart.Start(executable, current.Id);
            restartRequested = true;
            Logger.LogInfo("Restart helper waiting for game PID " + current.Id + "; executable=" + executable);
            Application.Quit();
        }
        catch (Exception ex) { Updates.RestartFailed(ex); }
    }

    internal static void Event(string name, string message) => Logger.LogInfo(name + ": " + message);
}
