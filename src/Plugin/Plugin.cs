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

[BepInPlugin(PluginGuid, PluginName, PluginVersion)]
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
    private Harmony harmony = null!;

    public override void Load()
    {
        var elapsed = Stopwatch.StartNew();
        Logger = Log;
        GameInfoReader.Initialize(Application.version);
        Route = GameRoute.Detect(Process.GetCurrentProcess().ProcessName, Application.dataPath);
        var pluginDirectory = Path.GetDirectoryName(typeof(Plugin).Assembly.Location)!;
        cleanupFailure = LegacyCleanup.Run(Paths.BepInExRootPath, pluginDirectory, message => Log.LogWarning(message));
        var http = new RuntimeHttp(PluginVersion);
        // Everything the plugin writes stays in its own folder, so deleting that folder uninstalls it fully.
        Packs = new PackClient(Path.Combine(pluginDirectory, "translation-pack"),
            http.DownloadAsync, message => Log.LogInfo(message), elapsed);
        Updates = new PluginUpdateClient(PluginVersion, http.DownloadAsync, message => Log.LogInfo(message));
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
        Log.LogInfo("Astral Party Korean Patch loaded; route=" + (Route?.Name ?? "unsupported"));
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
        GameInfoReader.Revision, PluginVersion, Updates.Latest, Route != null, cleanupFailure, Packs.Snapshot());

    internal static void Event(string name, string message) => Logger.LogInfo(name + ": " + message);
}
