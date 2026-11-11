using System;
using System.Collections.Generic;
using System.IO;

namespace AstralParty.KoreanPatch;

internal sealed class UpdateInstaller
{
    private const string ManifestName = ".update.json";
    private const string SignatureName = ".update.json.sig";
    private static readonly string[] FileNames = { UpdateManifest.BundleName, UpdateManifest.DllName };
    private readonly string directory;
    private readonly Action<string> log;
    private readonly string publicKey;

    internal UpdateInstaller(string directory, Action<string> log, string publicKey = UpdateManifest.PublicKey)
    {
        this.directory = Path.GetFullPath(directory);
        this.log = log;
        this.publicKey = publicKey;
    }

    internal void Install(UpdateManifest manifest, byte[] manifestBytes, byte[] signature, Dictionary<string, byte[]> files)
    {
        log("Preparing plugin update v" + manifest.Version.Text + " in " + directory);
        // Save authentication first; no unauthenticated .new file is ever applied at startup.
        WriteComplete(PathFor(ManifestName), manifestBytes);
        WriteComplete(PathFor(SignatureName), signature);
        foreach (var name in FileNames)
        {
            // Extract validated every entry before this installer was called.
            WriteComplete(PathFor(name) + ".new", files[UpdateManifest.FilePrefix + name]);
            log("Staged verified update file: " + name);
        }
        // The DLL is the commit point: if its swap fails, nothing installed has changed and startup discards the
        // staging. Only then is the bundle replaced; one held open by Unity stays staged for the updated plugin.
        Apply(UpdateManifest.DllName, allowStaging: false);
        Apply(UpdateManifest.BundleName, allowStaging: true);
        RemoveMetadataIfComplete();
        log("Plugin update v" + manifest.Version.Text + " installed; restart required");
    }

    internal string? PrepareStartup(string installed)
    {
        var failures = new List<string>();
        log("Checking staged plugin update files in " + directory);
        if (HasStagedState())
        {
            // Startup only finishes an update whose DLL commit already succeeded, i.e. the running plugin is
            // that release. Anything else (uncommitted DLL, partial staging, stale or prerelease state) is
            // discarded; the online check re-downloads a newer release under the normal installation gates.
            UpdateManifest? manifest = null;
            try
            {
                manifest = UpdateManifest.Verify(ReadLimited(PathFor(ManifestName), UpdateManifest.ManifestLimit),
                    ReadLimited(PathFor(SignatureName), UpdateManifest.SignatureLimit), publicKey);
            }
            catch (Exception ex) { log("Staged plugin update metadata is unusable: " + ex.GetType().Name + ": " + ex.Message); }
            var committed = manifest != null && manifest.Version.CompareTo(SemanticVersion.Parse(installed)) == 0 &&
                !File.Exists(PathFor(UpdateManifest.DllName) + ".new");
            if (!committed)
            {
                log("Discarding staged plugin update" + (manifest == null ? "" : " v" + manifest.Version.Text) +
                    " that does not match running plugin v" + installed);
                DiscardStagedState();
            }
            else if (File.Exists(PathFor(UpdateManifest.BundleName) + ".new"))
            {
                string? staged = PathFor(UpdateManifest.BundleName) + ".new";
                var expected = manifest!.Files[UpdateManifest.FilePrefix + UpdateManifest.BundleName];
                try
                {
                    UpdateManifest.VerifyBytes(ReadLimited(staged, UpdateManifest.FileLimit), expected.Size, expected.Sha256, UpdateManifest.BundleName);
                    log("Verified staged plugin update file: " + UpdateManifest.BundleName);
                }
                catch (Exception ex)
                {
                    log("Discarding unverifiable staged " + UpdateManifest.BundleName + ": " + ex.GetType().Name + ": " + ex.Message);
                    DiscardStagedState();
                    failures.Add("폰트 업데이트 검증 실패 · 게임 종료 후 수동 업데이트해 주세요");
                    staged = null;
                }
                if (staged != null)
                {
                    try
                    {
                        Apply(UpdateManifest.BundleName, allowStaging: false);
                        RemoveMetadataIfComplete();
                    }
                    catch (Exception ex)
                    {
                        // Keep the authenticated staging so the next startup can retry.
                        log("Staged plugin update failed: " + ex.GetType().Name + ": " + ex.Message);
                        failures.Add("예약된 폰트 업데이트 적용 실패 · 게임 종료 후 수동 업데이트해 주세요");
                    }
                }
            }
            else RemoveMetadataIfComplete();
        }
        foreach (var name in FileNames)
        {
            var path = PathFor(name);
            try
            {
                // Never delete the only recoverable installed file after an interrupted replacement.
                if (!File.Exists(path) && File.Exists(path + ".old"))
                {
                    File.Move(path + ".old", path);
                    log("Restored interrupted plugin update: " + name);
                }
                else if (File.Exists(path + ".old"))
                {
                    File.Delete(path + ".old");
                    log("Removed previous plugin update file: " + name + ".old");
                }
            }
            catch (Exception ex)
            {
                log("Plugin update cleanup failed: " + name + ": " + ex.GetType().Name + ": " + ex.Message);
                failures.Add(name + ".old 정리 실패");
            }
        }
        return failures.Count == 0 ? null : string.Join(" · ", failures);
    }

    private void Apply(string name, bool allowStaging)
    {
        var path = PathFor(name);
        var staged = path + ".new";
        if (!File.Exists(staged)) return;
        try
        {
            if (File.Exists(path + ".old"))
            {
                if (!File.Exists(path)) File.Move(path + ".old", path);
                else File.Delete(path + ".old");
            }
            if (File.Exists(path))
            {
                // ReplaceFileW renames the image-mapped DLL to the backup, rather than deleting it.
                // Keeping the backup also permits recovery if the OS cannot complete the second rename.
                try { File.Replace(staged, path, path + ".old"); }
                catch
                {
                    if (!File.Exists(path) && File.Exists(path + ".old"))
                    {
                        File.Move(path + ".old", path);
                        log("Restored installed file after failed replacement: " + name);
                    }
                    throw;
                }
            }
            else File.Move(staged, path);
            log("Installed plugin update file: " + name + " (previous file retained as .old)");
        }
        catch (Exception ex) when (allowStaging && (ex is IOException || ex is UnauthorizedAccessException) && File.Exists(path) && File.Exists(staged))
        {
            log("Font bundle is in use; applying verified " + name + ".new before fonts load next startup: " + ex.Message);
        }
    }

    private void WriteComplete(string path, byte[] bytes)
    {
        var temporary = path + ".tmp";
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: true);
    }

    private void RemoveMetadataIfComplete()
    {
        foreach (var name in FileNames)
            if (File.Exists(PathFor(name) + ".new")) return;
        // Authentication is no longer needed once all staged files have been committed.
        foreach (var name in new[] { ManifestName, SignatureName })
        {
            try { File.Delete(PathFor(name)); }
            catch (Exception ex) { log("Could not remove completed update metadata " + name + ": " + ex.Message); }
        }
    }

    private IEnumerable<string> StagedStatePaths()
    {
        foreach (var name in FileNames)
        {
            yield return PathFor(name) + ".new";
            yield return PathFor(name) + ".new.tmp";
        }
        foreach (var name in new[] { ManifestName, SignatureName })
        {
            yield return PathFor(name);
            yield return PathFor(name) + ".tmp";
        }
    }

    private bool HasStagedState()
    {
        foreach (var path in StagedStatePaths())
            if (File.Exists(path)) return true;
        return false;
    }

    private void DiscardStagedState()
    {
        foreach (var path in StagedStatePaths())
        {
            try { File.Delete(path); }
            catch (Exception ex) { log("Could not remove staged update file " + Path.GetFileName(path) + ": " + ex.Message); }
        }
    }

    private string PathFor(string name) => Path.Combine(directory, name);

    private static byte[] ReadLimited(string path, int limit)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length <= 0 || stream.Length > limit) throw new InvalidDataException("Staged update exceeds size limit: " + path);
        var bytes = new byte[(int)stream.Length];
        var offset = 0;
        while (offset < bytes.Length)
        {
            var count = stream.Read(bytes, offset, bytes.Length - offset);
            if (count == 0) throw new InvalidDataException("Truncated staged update: " + path);
            offset += count;
        }
        if (stream.ReadByte() != -1) throw new InvalidDataException("Staged update changed while reading: " + path);
        return bytes;
    }
}
