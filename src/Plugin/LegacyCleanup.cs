using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace AstralParty.KoreanPatch;

internal static class LegacyCleanup
{
    internal static string? Run(string bepinexRoot, string pluginDirectory, Action<string> log)
    {
        var failures = new List<string>();
        var patcher = Path.Combine(bepinexRoot, "patchers", "AstralPartyKoreanPlugin.dataUnity3dRedirect.dll");
        RemoveAssembly(patcher, failures, log);
        // Earlier releases used this assembly filename before the project was renamed.
        RemoveAssembly(Path.Combine(bepinexRoot, "patchers", "AstralParty.DataUnity3dRedirect.dll"), failures, log);
        var pluginRoot = Path.Combine(bepinexRoot, "plugins", "AstralPartyKoreanPatch");
        var dataRoot = Path.Combine(bepinexRoot, "AstralPartyKoreanPatch");
        var runningInLegacyFolder = IsInside(pluginDirectory, pluginRoot);
        foreach (var root in new[] { dataRoot, pluginRoot })
        {
            if (root == pluginRoot && !runningInLegacyFolder) continue;
            foreach (var directory in new[] { "cache", "payloads", "releases", "game-data" })
                Remove(Path.Combine(root, directory), true, failures, log);
            foreach (var file in new[] { "patched-data.unity3d", "data-unity3d-state.json", "preloader-session.json", "addressables-patch.jsonl" })
            {
                Remove(Path.Combine(root, file), false, failures, log);
                try
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (var temp in Directory.EnumerateFiles(root, file + ".tmp-*", SearchOption.TopDirectoryOnly))
                        Remove(temp, false, failures, log);
                }
                catch (Exception ex) { Failed(Path.Combine(root, file + ".tmp-*"), ex, failures, log); }
            }
        }
        if (runningInLegacyFolder)
            Remove(Path.Combine(pluginRoot, "AstralParty.AddressablesInProcessPatch.dll"), false, failures, log);
        else
            RemovePluginDirectory(pluginRoot, failures, log);
        // The 2.x preloader logged directly into the BepInEx folder.
        Remove(Path.Combine(bepinexRoot, "data-redirect.log"), false, failures, log);
        // 3.x keeps everything in the plugin folder; drop the 2.x data folder once nothing else is in it.
        RemoveEmptyDirectory(dataRoot, failures, log);
        return failures.Count == 0 ? null : string.Join(", ", failures);
    }

    private static void RemoveAssembly(string path, List<string> failures, Action<string> log)
    {
        var removed = path + ".removed";
        Remove(removed, false, failures, log);
        try
        {
            if (!File.Exists(path)) return;
            try { File.Delete(path); }
            catch (Exception)
            {
                File.Move(path, removed);
                log("Renamed loaded legacy DLL: " + path + " -> " + removed);
                return;
            }
            log("Removed legacy DLL: " + path);
        }
        catch (Exception ex) { Failed(path, ex, failures, log); }
    }

    private static bool IsInside(string directory, string root)
    {
        var fullDirectory = ResolveLinks(directory);
        var fullRoot = ResolveLinks(root);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return fullDirectory.Equals(fullRoot, comparison) ||
            fullDirectory.StartsWith(fullRoot + Path.DirectorySeparatorChar, comparison);
    }

    // A junction alias of the old folder must count as the old folder, or cleanup would delete the running install.
    private static string ResolveLinks(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var resolved = Path.GetPathRoot(full)!;
        foreach (var part in full[resolved.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            resolved = Path.Combine(resolved, part);
            try
            {
                if (Directory.Exists(resolved) && Directory.ResolveLinkTarget(resolved, returnFinalTarget: true) is { } target)
                    resolved = target.FullName;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return resolved.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static void RemovePluginDirectory(string path, List<string> failures, Action<string> log)
    {
        try
        {
            if (!Directory.Exists(path)) return;
            // Delete directory links themselves, never files in another plugin's target folder.
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                Directory.Delete(path);
                log("Removed legacy patch data: " + path);
                return;
            }
            // Snapshot names so a loaded DLL renamed to .removed waits until the next launch.
            var files = Directory.GetFiles(path);
            foreach (var file in files)
                if (!Path.GetExtension(file).Equals(".dll", StringComparison.OrdinalIgnoreCase))
                    Remove(file, false, failures, log);
            foreach (var file in files)
                if (Path.GetExtension(file).Equals(".dll", StringComparison.OrdinalIgnoreCase))
                    RemoveAssembly(file, failures, log);
            foreach (var directory in Directory.GetDirectories(path))
                RemovePluginDirectory(directory, failures, log);
            RemoveEmptyDirectory(path, failures, log);
        }
        catch (Exception ex) { Failed(path, ex, failures, log); }
    }

    private static void RemoveEmptyDirectory(string path, List<string> failures, Action<string> log)
    {
        try
        {
            if (!Directory.Exists(path) || Directory.EnumerateFileSystemEntries(path).Any()) return;
            Directory.Delete(path);
            log("Removed legacy patch data: " + path);
        }
        catch (Exception ex) { Failed(path, ex, failures, log); }
    }

    private static void Remove(string path, bool directory, List<string> failures, Action<string> log)
    {
        try
        {
            if (directory)
            {
                if (!Directory.Exists(path)) return;
                Directory.Delete(path, recursive: true);
            }
            else
            {
                if (!File.Exists(path)) return;
                File.Delete(path);
            }
            log("Removed legacy patch data: " + path);
        }
        catch (Exception ex) { Failed(path, ex, failures, log); }
    }

    private static void Failed(string path, Exception ex, List<string> failures, Action<string> log)
    {
        failures.Add(path);
        log("Legacy cleanup failed: " + path + ": " + ex.GetType().Name + ": " + ex.Message);
    }
}
