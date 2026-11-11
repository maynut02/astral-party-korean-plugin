using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace AstralParty.KoreanPatch;

internal sealed class RuntimeHttp
{
    private readonly HttpClient client;
    internal RuntimeHttp(string version)
    {
        // Use platform TLS validation and stream responses within the caller's size limit.
        // Do not disable certificate checks or force an obsolete TLS protocol.
        client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("astral-party-korean-patch/" + version);
        client.DefaultRequestHeaders.Accept.ParseAdd("*/*");
    }

    internal async Task<byte[]> DownloadAsync(Uri url, int limit, bool noCache)
    {
        // Allow at least 64 KiB/s for large bodies; the per-read idle timeout still catches stalls.
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(Math.Max(15, limit / (64 * 1024))));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (noCache) request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is long length && length > limit)
            throw new InvalidDataException("HTTP response exceeds size limit: " + url);
        using var input = await response.Content.ReadAsStreamAsync(cancellation.Token).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
            idle.CancelAfter(TimeSpan.FromSeconds(5));
            int read;
            try { read = await input.ReadAsync(buffer.AsMemory(), idle.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            { throw new TimeoutException("HTTP download stalled: " + url); }
            if (read == 0) break;
            if (output.Length + read > limit) throw new InvalidDataException("HTTP response exceeds size limit: " + url);
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }
}

internal sealed record PluginUpdateState(string Latest, string? Message, StatusSeverity Severity, bool RestartRequired);

internal sealed class PluginUpdateClient
{
    internal static readonly Uri ManifestUrl = new("https://github.com/maynut02/astral-party-korean-plugin/releases/latest/download/update.json");
    internal static readonly Uri SignatureUrl = new(ManifestUrl.AbsoluteUri + ".sig");
    private PluginUpdateState state;
    private int revision;
    private readonly Action<string> log;
    internal int Revision => Volatile.Read(ref revision);
    internal PluginUpdateState Snapshot() => Volatile.Read(ref state);
    internal Task RefreshTask { get; }

    internal PluginUpdateClient(string installed, string runningBepInEx, bool autoUpdate, string directory,
        Func<Uri, int, bool, Task<byte[]>> download, Action<string> log,
        string? startupFailure = null, string publicKey = UpdateManifest.PublicKey)
    {
        this.log = log;
        state = new PluginUpdateState("확인 중", startupFailure, StatusSeverity.Warning, false);
        RefreshTask = Task.Run(() => CheckAsync(installed, runningBepInEx, autoUpdate && startupFailure == null,
            directory, download, publicKey));
    }

    private void Publish(PluginUpdateState next)
    {
        Volatile.Write(ref state, next);
        Interlocked.Increment(ref revision);
    }

    internal void RestartFailed(Exception ex)
    {
        log("Plugin restart failed: " + ex.GetType().Name + ": " + ex.Message);
        Publish(Snapshot() with { Message = "다시 시작 실패 · 게임을 종료한 뒤 다시 실행해 주세요", Severity = StatusSeverity.Warning });
    }

    private async Task CheckAsync(string installed, string runningBepInEx, bool autoUpdate, string directory,
        Func<Uri, int, bool, Task<byte[]>> download, string publicKey)
    {
        var manifestVerified = false;
        try
        {
            log("Downloading signed plugin update manifest");
            var bytes = await download(ManifestUrl, UpdateManifest.ManifestLimit, true).ConfigureAwait(false);
            var signature = await download(SignatureUrl, UpdateManifest.SignatureLimit, true).ConfigureAwait(false);
            var manifest = UpdateManifest.Verify(bytes, signature, publicKey);
            manifestVerified = true;
            log("Verified plugin update manifest: v" + manifest.Version.Text);
            Publish(Snapshot() with { Latest = "v" + manifest.Version.Text });
            var current = SemanticVersion.Parse(installed);
            if (current.IsPrerelease)
            {
                log("Development/prerelease plugin v" + installed + ": automatic installation is disabled");
                return;
            }
            if (manifest.Version.CompareTo(current) <= 0)
            {
                log("Installed plugin v" + installed + " is up to date; no downgrade");
                return;
            }
            if (!autoUpdate)
            {
                log("Plugin update v" + manifest.Version.Text + " available; automatic installation disabled");
                if (Snapshot().Message == null)
                    Publish(Snapshot() with { Message = "새 플러그인 v" + manifest.Version.Text + " · 자동 업데이트 꺼짐 (수동 업데이트해 주세요)", Severity = StatusSeverity.Warning });
                return;
            }
            if (string.IsNullOrEmpty(runningBepInEx) || SemanticVersion.Parse(runningBepInEx).CompareTo(manifest.MinimumBepInEx) < 0)
            {
                log("Plugin update requires BepInEx >= " + manifest.MinimumBepInEx.Text + "; running=" + runningBepInEx);
                Publish(Snapshot() with { Message = "업데이트에 BepInEx " + manifest.MinimumBepInEx.Text + " 이상이 필요합니다 · 수동 업데이트해 주세요", Severity = StatusSeverity.Warning });
                return;
            }
            Publish(Snapshot() with { Message = "플러그인 v" + manifest.Version.Text + " 다운로드 중", Severity = StatusSeverity.Checking });
            log("Downloading plugin update package: " + manifest.PackageUrl);
            var package = await download(manifest.PackageUrl, manifest.PackageSize, false).ConfigureAwait(false);
            var files = manifest.Extract(package);
            log("Verified update ZIP size, SHA-256, exact entries and all file hashes");
            new UpdateInstaller(directory, log, publicKey).Install(manifest, bytes, signature, files);
            Publish(new PluginUpdateState("v" + manifest.Version.Text,
                "플러그인 v" + manifest.Version.Text + " 설치 완료 · 다시 시작하면 적용됩니다", StatusSeverity.Success, true));
        }
        catch (Exception ex)
        {
            log("Plugin update failed: " + ex.GetType().Name + ": " + ex.Message);
            // An unreachable or unverifiable manifest (offline, GitHub outage) only marks the latest version
            // unknown, so translation-pack status stays visible. Failures after verification need user action.
            if (!manifestVerified) Publish(Snapshot() with { Latest = "확인 실패" });
            else Publish(Snapshot() with { Message = "플러그인 업데이트 실패 · 게임 종료 후 수동 업데이트해 주세요", Severity = StatusSeverity.Warning });
        }
    }
}
