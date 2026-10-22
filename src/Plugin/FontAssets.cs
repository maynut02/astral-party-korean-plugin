using System;
using System.Collections.Generic;
using System.IO;
using Il2CppInterop.Runtime;
using UnityEngine;

namespace AstralParty.KoreanPatch;

internal static class FontAssets
{
    private const string BundleFile = "astralkorean_fonts.bundle";
    private static readonly HashSet<string> LegacyTargets = new(StringComparer.Ordinal)
        { "Afacad-Regular", "Impact", "SIMHEI", "VonwaonBitmap" };
    private static AssetBundle? bundle;
    private static bool attempted;
    internal static Font? KoreanFont { get; private set; }
    internal static Texture2D? Atlas { get; private set; }
    internal static string? TmpJson { get; private set; }

    internal static void GetFontAssetPostfix(string fontName, ref Font __result)
    {
        if (Plugin.Route == null || fontName == null || !LegacyTargets.Contains(fontName)) return;
        try
        {
            if (EnsureLoaded() && KoreanFont != null) __result = KoreanFont;
        }
        catch (Exception ex) { Plugin.Logger.LogError("Legacy font replacement failed: " + ex); }
    }

    internal static bool EnsureLoaded()
    {
        if (attempted) return bundle != null;
        attempted = true;
        var path = Path.Combine(Path.GetDirectoryName(typeof(Plugin).Assembly.Location)!, BundleFile);
        try
        {
            bundle = AssetBundle.LoadFromFile(path);
            if (bundle == null) throw new InvalidDataException("AssetBundle.LoadFromFile returned null: " + path);
            KoreanFont = bundle.LoadAsset("assets/astralkorean/onemobilepop.ttf", Il2CppType.Of<Font>())?.TryCast<Font>();
            Atlas = bundle.LoadAsset("assets/astralkorean/tmp-atlas.asset", Il2CppType.Of<Texture2D>())?.TryCast<Texture2D>();
            var data = bundle.LoadAsset("assets/astralkorean/tmp-data.json", Il2CppType.Of<TextAsset>())?.TryCast<TextAsset>();
            TmpJson = data?.text;
            if (KoreanFont != null) KoreanFont.hideFlags |= HideFlags.DontUnloadUnusedAsset;
            if (Atlas != null) Atlas.hideFlags |= HideFlags.DontUnloadUnusedAsset;
            if (KoreanFont == null || Atlas == null || TmpJson == null)
                throw new InvalidDataException("Korean font bundle is missing required assets");
            Plugin.Logger.LogInfo("Korean font bundle loaded");
        }
        catch (Exception ex) { Plugin.Logger.LogError("Korean font bundle could not be loaded: " + ex); }
        return bundle != null;
    }
}
