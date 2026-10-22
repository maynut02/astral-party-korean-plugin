using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AstralParty.KoreanPatch;

internal sealed record PackState(TranslationPack? Candidate, TranslationPack? Active, bool Frozen,
    bool Checking, bool Offline, bool UpdateRequired);

// The candidate can advance in the background. Only Freeze chooses the session's immutable pack.
internal sealed class PackClient
{
    internal static readonly Uri PointerUrl = new("https://file.maynutlab.com/translation-pack/latest.json");
    private readonly object sync = new();
    private readonly object freezeSync = new();
    private readonly string directory;
    private readonly Func<Uri, int, bool, Task<byte[]>> download;
    private readonly Action<string> log;
    private readonly Stopwatch elapsed;
    private readonly TimeSpan deadline;
    private TranslationPack? candidate;
    private TranslationPack? active;
    private bool frozen, checking = true, offline, updateRequired;
    private int revision;
    internal int Revision => Volatile.Read(ref revision);
    internal Task RefreshTask { get; }

    internal PackClient(string directory, Func<Uri, int, bool, Task<byte[]>> download,
        Action<string> log, Stopwatch? elapsed = null, TimeSpan? deadline = null)
    {
        this.directory = directory;
        this.download = download;
        this.log = log;
        this.elapsed = elapsed ?? Stopwatch.StartNew();
        this.deadline = deadline ?? TimeSpan.FromSeconds(10);
        LoadCache();
        RefreshTask = Task.Run(RefreshAsync);
    }

    internal PackState Snapshot()
    {
        lock (sync) return new PackState(candidate, active, frozen, checking, offline, updateRequired);
    }

    internal TranslationPack? Freeze()
    {
        lock (freezeSync)
        {
            lock (sync) if (frozen) return active;
            var remaining = deadline - elapsed.Elapsed;
            if (remaining > TimeSpan.Zero)
            {
                try { RefreshTask.Wait(remaining); }
                catch (Exception ex) { log("Translation pack wait failed: " + ex.GetBaseException().Message); }
            }
            lock (sync)
            {
                active = candidate;
                frozen = true;
                Interlocked.Increment(ref revision);
                log(active == null ? "Session uses original text (no translation pack ready)" :
                    "Session translation pack frozen at #" + active.Number);
                return active;
            }
        }
    }

    private string PackFile(long number) => Path.Combine(directory, number.ToString(CultureInfo.InvariantCulture) + ".json.gz");

    private void LoadCache()
    {
        var path = Path.Combine(directory, "latest.json");
        try
        {
            if (!File.Exists(path)) return;
            if (new FileInfo(path).Length > 64 * 1024) throw new InvalidDataException("Cached pointer exceeds size limit");
            var pointer = PackPointer.Parse(File.ReadAllBytes(path));
            var packPath = PackFile(pointer.Number);
            if (new FileInfo(packPath).Length != pointer.Size) throw new InvalidDataException("Cached pack size mismatch");
            candidate = TranslationPack.Parse(pointer, File.ReadAllBytes(packPath));
            log("Loaded saved translation pack #" + candidate.Number);
            PrunePacks(candidate.Number);
        }
        catch (UnsupportedPackSchemaException ex)
        {
            updateRequired = true;
            log("Saved translation pack ignored: " + ex.Message);
        }
        catch (Exception ex) { log("Saved translation pack ignored: " + ex.GetType().Name + ": " + ex.Message); }
    }

    private async Task RefreshAsync()
    {
        try
        {
            var pointerBytes = await download(PointerUrl, 64 * 1024, true).ConfigureAwait(false);
            var pointer = PackPointer.Parse(pointerBytes);
            long previous;
            lock (sync) previous = candidate?.Number ?? 0;
            if (pointer.Number < previous)
                log("Ignoring older translation pack #" + pointer.Number + " (saved #" + previous + ")");
            else if (pointer.Number > previous)
            {
                var bytes = await download(new Uri(PointerUrl, pointer.Path), pointer.Size, false).ConfigureAwait(false);
                var pack = TranslationPack.Parse(pointer, bytes);
                SaveCache(pointer, pointerBytes, bytes);
                lock (sync)
                {
                    candidate = pack;
                    updateRequired = false;
                    Interlocked.Increment(ref revision);
                }
                log("Downloaded translation pack #" + pack.Number);
            }
            lock (sync) updateRequired = false;
        }
        catch (UnsupportedPackSchemaException ex)
        {
            lock (sync) updateRequired = true;
            log("Plugin update required: " + ex.Message);
        }
        catch (Exception ex)
        {
            lock (sync) offline = true;
            log("Translation pack check failed; saved pack retained: " + ex.GetType().Name + ": " + ex.Message);
        }
        finally
        {
            lock (sync)
            {
                checking = false;
                Interlocked.Increment(ref revision);
            }
        }
    }

    private void SaveCache(PackPointer pointer, byte[] pointerBytes, byte[] packBytes)
    {
        Directory.CreateDirectory(directory);
        // Commit the pointer last: an interrupted update still leaves the previous pair readable.
        AtomicWrite(PackFile(pointer.Number), packBytes);
        AtomicWrite(Path.Combine(directory, "latest.json"), pointerBytes);
        PrunePacks(pointer.Number);
    }

    private void PrunePacks(long current)
    {
        try
        {
            foreach (var path in Directory.EnumerateFiles(directory, "*.json.gz"))
            {
                if (string.Equals(path, PackFile(current), StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(path); }
                catch (Exception ex) { log("Old translation pack could not be removed: " + path + ": " + ex.Message); }
            }
        }
        catch (Exception ex) { log("Old translation packs could not be listed: " + ex.Message); }
    }

    private static void AtomicWrite(string path, byte[] bytes)
    {
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temp, path, null);
            else File.Move(temp, path);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
