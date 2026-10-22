using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
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
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        client.DefaultRequestHeaders.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
    }

    internal async Task<byte[]> DownloadAsync(Uri url, int limit, bool noCache)
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
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

internal sealed class PluginUpdateClient
{
    private static readonly Uri LatestUrl = new("https://api.github.com/repos/maynut02/astral-party-korean-plugin/releases/latest");
    private string latest = "확인 중";
    private int revision;
    internal int Revision => Volatile.Read(ref revision);
    internal string Latest => Volatile.Read(ref latest);

    internal PluginUpdateClient(string installed, Func<Uri, int, bool, Task<byte[]>> download, Action<string> log)
    { _ = Task.Run(() => CheckAsync(installed, download, log)); }

    private async Task CheckAsync(string installed, Func<Uri, int, bool, Task<byte[]>> download, Action<string> log)
    {
        try
        {
            var bytes = await download(LatestUrl, 1024 * 1024, true).ConfigureAwait(false);
            using var document = JsonDocument.Parse(bytes);
            var version = SemanticVersion.Parse(document.RootElement.GetProperty("tag_name").GetString() ?? "");
            var newer = version.CompareTo(SemanticVersion.Parse(installed)) > 0;
            Volatile.Write(ref latest, "v" + version.Text);
            log(newer ? "Plugin update available: v" + version.Text : "Installed plugin is up to date");
        }
        catch (Exception ex)
        {
            Volatile.Write(ref latest, "확인 실패");
            log("Plugin update check failed: " + ex.GetType().Name + ": " + ex.Message);
        }
        finally { Interlocked.Increment(ref revision); }
    }
}
