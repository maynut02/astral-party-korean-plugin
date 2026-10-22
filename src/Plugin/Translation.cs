using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Il2CppInterop.Runtime.InteropTypes.Arrays;
using UnityEngine;

namespace AstralParty.KoreanPatch;

internal static class Translation
{
    private readonly record struct CacheKey(string Name, int Length, ulong Hash);
    private static readonly object Sync = new();
    private static readonly Dictionary<CacheKey, Il2CppStructArray<byte>> BytesCache = new();
    private static readonly Dictionary<CacheKey, string> TextCache = new();
    private static readonly HashSet<CacheKey> Passthrough = new();
    private static readonly HashSet<string> FailedNames = new(StringComparer.Ordinal);

    internal static bool BytesPrefix(TextAsset __instance, ref Il2CppStructArray<byte> __result)
    {
        var route = Plugin.Route;
        if (route == null) return true;
        string? name = null;
        try
        {
            name = __instance.name;
            if (name == null || !name.StartsWith("STR", StringComparison.Ordinal)) return true;
            var pack = Plugin.Packs.Freeze();
            if (pack == null || !pack.Str.TryGetValue(name, out var map)) return true;
            lock (Sync)
            {
                if (FailedNames.Contains(name)) return true;
                var data = ReadData(__instance);
                if (data.Length == 0) return true;
                var key = Key(name, data);
                if (Passthrough.Contains(key)) return true;
                if (!BytesCache.TryGetValue(key, out var patched))
                {
                    var output = StrPatcher.Patch(data, map, route.StrField);
                    if (ReferenceEquals(output, data)) { Passthrough.Add(key); return true; }
                    patched = output;
                    BytesCache.Add(key, patched);
                }
                __result = patched;
                return false;
            }
        }
        catch (Exception ex) { ReportFailure(name, "STR", ex); return true; }
    }

    internal static bool TextPrefix(TextAsset __instance, ref string __result)
    {
        var route = Plugin.Route;
        if (route == null) return true;
        string? name = null;
        try
        {
            name = __instance.name;
            if (name != route.LangAsset) return true;
            var pack = Plugin.Packs.Freeze();
            if (pack == null) return true;
            lock (Sync)
            {
                if (FailedNames.Contains(name)) return true;
                var data = ReadData(__instance);
                if (data.Length == 0) return true;
                var key = Key(name, data);
                if (!TextCache.TryGetValue(key, out var patched))
                {
                    var offset = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
                    patched = LangPatcher.Patch(Encoding.UTF8.GetString(data, offset, data.Length - offset), pack.Lang);
                    TextCache.Add(key, patched);
                }
                __result = patched;
                return false;
            }
        }
        catch (Exception ex) { ReportFailure(name, "lang", ex); return true; }
    }

    private static void ReportFailure(string? name, string kind, Exception ex)
    {
        lock (Sync)
            if (FailedNames.Add(name ?? "<unknown>"))
                Plugin.Logger.LogError(kind + " translation failed; original kept for " + name + ": " + ex);
    }

    // Never call either hooked getter while reading original native bytes.
    private static byte[] ReadData(TextAsset asset)
    {
        var size = checked((int)asset.GetDataSize());
        var data = new byte[size];
        if (size > 0) Marshal.Copy(asset.GetDataPtr(), data, 0, size);
        return data;
    }

    private static CacheKey Key(string name, byte[] data)
    {
        ulong hash = 14695981039346656037UL;
        foreach (var b in data) hash = unchecked((hash ^ b) * 1099511628211UL);
        return new CacheKey(name, data.Length, hash);
    }
}
