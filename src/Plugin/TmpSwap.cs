using System;
using System.Collections.Generic;
using System.Text.Json;
using Il2CppInterop.Runtime.InteropTypes.Arrays;
using TMPro;
using UnityEngine;
using UnityEngine.TextCore;
using UnityEngine.TextCore.LowLevel;

namespace AstralParty.KoreanPatch;

// Retain the game's TMP_FontAsset objects so all existing FairyGUI/TMP references see the swap.
internal static class TmpSwap
{
    private static readonly HashSet<string> Targets = new(StringComparer.Ordinal)
        { "Afacad-Regular_TMP", "Impact_TMP", "dgo_TMP" };
    private static readonly HashSet<IntPtr> Seen = new();

    internal static void AwakePostfix(TMP_FontAsset __instance) => TrySwap(__instance);
    internal static void AtlasTexturePrefix(TMP_FontAsset __instance) => TrySwap(__instance);

    private static void TrySwap(TMP_FontAsset font)
    {
        if (Plugin.Route == null) return;
        try
        {
            if (font == null || !Seen.Add(font.Pointer) || !Targets.Contains(font.name)) return;
            if (!FontAssets.EnsureLoaded() || FontAssets.Atlas == null || FontAssets.TmpJson == null) return;
            Swap(font);
            Plugin.Logger.LogInfo("Replaced TMP font " + font.name);
        }
        catch (Exception ex) { Plugin.Logger.LogError("TMP font replacement failed: " + ex); }
    }

    private static void Swap(TMP_FontAsset font)
    {
        using var doc = JsonDocument.Parse(FontAssets.TmpJson!);
        var root = doc.RootElement;
        var f = root.GetProperty("faceInfo");
        float F(string key) => f.GetProperty(key).GetSingle();
        font.m_FaceInfo = new FaceInfo(
            f.GetProperty("familyName").GetString(), f.GetProperty("styleName").GetString(),
            f.GetProperty("pointSize").GetInt32(), F("scale"), f.GetProperty("unitsPerEM").GetInt32(),
            F("lineHeight"), F("ascentLine"), F("capLine"), F("meanLine"), F("baseline"), F("descentLine"),
            F("superscriptOffset"), F("superscriptSize"), F("subscriptOffset"), F("subscriptSize"),
            F("underlineOffset"), F("underlineThickness"), F("strikethroughOffset"), F("strikethroughThickness"),
            F("tabWidth"));
        font.m_AtlasPopulationMode = AtlasPopulationMode.Static;
        font.m_AtlasWidth = root.GetProperty("atlasWidth").GetInt32();
        font.m_AtlasHeight = root.GetProperty("atlasHeight").GetInt32();
        font.m_AtlasPadding = root.GetProperty("atlasPadding").GetInt32();
        font.m_AtlasRenderMode = (GlyphRenderMode)root.GetProperty("atlasRenderMode").GetInt32();
        font.normalStyle = root.GetProperty("normalStyle").GetSingle();
        font.normalSpacingOffset = root.GetProperty("normalSpacingOffset").GetSingle();
        font.boldStyle = root.GetProperty("boldStyle").GetSingle();
        font.boldSpacing = root.GetProperty("boldSpacing").GetSingle();
        font.italicStyle = (byte)root.GetProperty("italicStyle").GetInt32();
        font.tabSize = (byte)root.GetProperty("tabSize").GetInt32();
        var atlases = new Il2CppReferenceArray<Texture2D>(1);
        atlases[0] = FontAssets.Atlas!;
        font.m_AtlasTextures = atlases;
        // The atlasTexture getter returns this cache once populated.
        font.m_AtlasTexture = FontAssets.Atlas!;
        font.m_AtlasTextureIndex = 0;
        font.m_IsMultiAtlasTexturesEnabled = false;
        font.m_UsedGlyphRects?.Clear();
        font.m_FreeGlyphRects?.Clear();

        var glyphTable = font.m_GlyphTable;
        glyphTable.Clear();
        var glyphs = new Dictionary<uint, Glyph>();
        foreach (var g in root.GetProperty("glyphs").EnumerateArray())
        {
            var glyph = new Glyph(g[0].GetUInt32(),
                new GlyphMetrics(g[1].GetSingle(), g[2].GetSingle(), g[3].GetSingle(), g[4].GetSingle(), g[5].GetSingle()),
                new GlyphRect(g[6].GetInt32(), g[7].GetInt32(), g[8].GetInt32(), g[9].GetInt32()),
                g[10].GetSingle(), 0);
            glyphTable.Add(glyph);
            glyphs[glyph.index] = glyph;
        }
        var characterTable = font.m_CharacterTable;
        characterTable.Clear();
        foreach (var c in root.GetProperty("characters").EnumerateArray())
        {
            if (!glyphs.TryGetValue(c[1].GetUInt32(), out var glyph)) continue;
            characterTable.Add(new TMP_Character(c[0].GetUInt32(), font, glyph) { scale = c[2].GetSingle() });
        }
        // Old kerning records refer to the original glyph indices.
        try { font.m_FontFeatureTable?.glyphPairAdjustmentRecords?.Clear(); }
        catch (Exception ex) { Plugin.Logger.LogWarning("Font feature table not cleared: " + ex.Message); }
        var material = font.material;
        if (material != null)
        {
            material.SetTexture("_MainTex", FontAssets.Atlas);
            material.SetFloat("_TextureWidth", font.m_AtlasWidth);
            material.SetFloat("_TextureHeight", font.m_AtlasHeight);
            material.SetFloat("_GradientScale", font.m_AtlasPadding + 1);
            material.SetFloat("_WeightNormal", font.normalStyle);
            material.SetFloat("_WeightBold", font.boldStyle);
        }
        font.ReadFontAssetDefinition();
    }
}
